using Test
using JSON3
using SHA
include("calibration_method_analysis.jl")
const CMA = CalibrationMethodAnalysis
const Client = CMA.CalibrationClient

function fixture(root; order="reverse", profile="classic", engine="fgn", backend="cpu")
    output, package = joinpath(root, "output"), joinpath(root, "package")
    mkpath(joinpath(output, "analysis"))
    mkpath(joinpath(package, "hil"))
    for (source, destination) in (("calibration_method_analysis.jl", joinpath(output, "analysis")),
            ("calibration_client.jl", joinpath(output, "analysis")),
            ("calibration_client.jl", joinpath(package, "hil")))
        cp(joinpath(@__DIR__, source), joinpath(destination, source))
    end
    recipe = (; reference=zeros(Float32, 277), amplitudes=fill(0.25f0, 277),
        frames_per_probe=1, settling=profile == "copper" ? (; kind="discard_exposures", frames=1) : (; kind="immediate"),
        adc_upper_rail=profile == "copper" ? 16383 : 4095, request_timeout_ns=100000)
    positive = zeros(Float32, 2, 277)
    positive[1,139], positive[2,139] = 0.25f0, 0.5f0
    method = (; version=1, run=73, order,
        probe_basis=(; kind="modal", positive_commands=[collect(row) for row in eachrow(positive)],
            mode_amplitudes=Float32[0.25,0.5]))
    CMA.write_new(joinpath(output, "recipe.json"), recipe)
    CMA.write_new(joinpath(output, "method.json"), method)
    selected = (; profile, engine, mode="frame", backend)
    CMA.write_new(joinpath(output, "base-identity.json"), (; selected_profile=selected,
        files=Dict("deployment.conf" => repeat("a",64), "provenance.json" => repeat("b",64)),
        startup_snapshot=(; background_sha256=repeat("c",64))))
    CMA.write_new(joinpath(package, "provenance.json"), (; profile, engine, mode="frame",
        calibration_stage="interaction", illumination="lamp", source_provenance=(; profile,
            engine, mode="frame", hil=(; backend))))
    CMA.prepare_method(output, package)
    measurements = profile == "copper" ? 3600 : 376
    canonical = Client.prepare_plan(CMA.prepared_specification(recipe, method; measurements))
    chronological, permutation = CMA.ordered_plan(canonical, order)
    physical = zeros(Float32, measurements, 277)
    physical[1,139], physical[2,139], physical[end,139] = 2, -3, 7
    observations = chronological.figures * permutedims(physical)
    batches = map(enumerate(eachrow(observations))) do (i, row)
        (; values=collect(row), valid=true, exposures=[(; domain=1, generation=1,
            sequence=i, start_model_ns=i * 100, duration_ns=100)])
    end
    mkpath(joinpath(output, "evidence"))
    CMA.write_new(joinpath(output, "evidence/rtc-calibrate.json"), (; version=1, run=73,
        phase="complete", restoration_confirmed=true, resume_permitted=true,
        failure=nothing, recovery_failure=nothing, responses=batches))
    stage = (; restoration_confirmed=true, release_confirmed=true, shutdown_confirmed=true,
        launcher_exit=0, final=(; phase="stopped", error=nothing, cleanup_errors=String[]))
    CMA.write_new(joinpath(output, "evidence/stage-result.json"), stage)
    files = Dict(relpath(joinpath(directory, file), output) => CMA.digest(joinpath(directory, file))
        for (directory, _, names) in walkdir(output) for file in names if !occursin("evidence", relpath(directory, output)))
    package_files = Dict(relative => CMA.digest(joinpath(package, relative))
        for relative in ("hil/calibration_client.jl", "provenance.json"))
    CMA.write_new(joinpath(output, "prepared-identity.json"), (; files, package_files))
    seal = CMA.digest(joinpath(output, "prepared-identity.json"))
    return (; output, package, seal, canonical, chronological, permutation,
        observations, stage, expected=hcat(physical[:,139], physical[:,139]))
end

@testset "canonical permutation and public reduction" begin
    for order in ("forward", "reverse")
        mktempdir() do root
            f = fixture(root; order)
            @test f.permutation == (order == "forward" ? [1,2,3,4] : [4,3,2,1])
            values = Client.validate_result(read(joinpath(f.output, "evidence/rtc-calibrate.json"), String), f.chronological)
            canonical_values = CMA.canonical_responses(values, f.permutation)
            @test Client.estimate_interaction_matrix(f.canonical, canonical_values) == f.expected
            report_path = CMA.reduce_method(f.output, f.package, f.seal)
            report = CMA.document(report_path)
            @test report.coordinate_kind == "mode_direction"
            @test collect(report.shape) == [376,2]
            @test report.layout == "ROW_MAJOR" && report.element_type == "F32_LE"
            @test report.status == "complete-unaccepted-candidate"
            bytes = read(joinpath(f.output, report.path))
            @test length(bytes) == 376 * 2 * sizeof(Float32)
            matrix = permutedims(reshape(collect(reinterpret(Float32, bytes)), 2, 376))
            @test matrix == f.expected
            @test report.sha256 == CMA.digest(joinpath(f.output, report.path))
            @test report.basis.positive_commands_shape == [2,277]
            @test report.basis.positive_commands_layout == "column_major"
            @test_throws ArgumentError CMA.reduce_method(f.output, f.package, f.seal)
        end
    end
end

@testset "chronology is validated before reordering" begin
    mktempdir() do root
        f = fixture(root)
        path = joinpath(f.output, "evidence/rtc-calibrate.json")
        document = CMA.document(path)
        # Swapping exposure-associated batches breaks the chronological contract,
        # even though the numerical values could otherwise be inverse-permuted.
        bad = (; version=1, run=73, phase="complete", restoration_confirmed=true,
            resume_permitted=true, failure=nothing, recovery_failure=nothing,
            responses=collect(document.responses)[[2,1,3,4]])
        open(path, "w") do io
            JSON3.write(io, bad)
        end
        @test_throws ArgumentError CMA.reduce_method(f.output, f.package, f.seal)
        @test !ispath(joinpath(f.output, "candidate-response.f32le"))
    end
    @test_throws ArgumentError CMA.canonical_responses(zeros(4,2), [1,1,3,4])
end

@testset "lifecycle, hashes, dimensions and output admission" begin
    for changed in ("interaction-plan.json", "method.json", "analysis/calibration_client.jl",
            "analysis/calibration_method_analysis.jl", "prepared-identity.json")
        mktempdir() do root
            f = fixture(root)
            open(joinpath(f.output, changed), "a") do io
                write(io, "changed")
            end
            @test_throws ArgumentError CMA.reduce_method(f.output, f.package, f.seal)
            @test !ispath(joinpath(f.output, "candidate-response.f32le"))
        end
    end
    for patch in ((; shutdown_confirmed=false), (; release_confirmed=1), (; launcher_exit=true),
            (; failure="failed"), (; recovery_failure="failed"),
            (; final=(; phase="running", error=nothing, cleanup_errors=[])),
            (; final=(; phase="stopped", error="error", cleanup_errors=[])),
            (; final=(; phase="stopped", error=nothing, cleanup_errors=["error"])))
        mktempdir() do root
            f = fixture(root)
            @test_throws ArgumentError CMA.validate_stage(merge(f.stage, patch))
        end
    end
    recipe = (; reference=zeros(2), amplitudes=ones(2), frames_per_probe=1,
        settling=(; kind="immediate"), request_timeout_ns=100)
    method = (; version=1, run=1, order="forward")
    @test_throws DimensionMismatch CMA.prepared_specification(recipe, method)
    @test_throws ArgumentError CMA.prepared_specification(recipe, merge(method,(; run=true)); physical_count=2)
    @test_throws ArgumentError CMA.prepared_specification(recipe, merge(method,(; version=1.0)); physical_count=2)
    @test_throws ArgumentError CMA.prepared_specification(recipe, merge(method,(; order="random")); physical_count=2)
    @test Client.prepare_plan(CMA.prepared_specification(recipe, method; physical_count=2, measurements=3)).measurements == 3
    canonical = Client.prepare_plan(CMA.prepared_specification(recipe, method; physical_count=2, measurements=3))
    @test CMA.basis_metadata(canonical).coordinate_kind == "physical_actuator"
    @test CMA.basis_metadata(canonical).kind == "zonal_push_pull"
    hadamard = Client.prepare_plan(CMA.prepared_specification(recipe,
        merge(method,(; probe_basis=(; kind="hadamard"))); physical_count=2, measurements=3))
    @test CMA.basis_metadata(hadamard).coordinate_kind == "physical_actuator"
    @test CMA.basis_metadata(hadamard).positive_commands_shape == (4,2)
    @test CMA.basis_metadata(hadamard).amplitudes == ones(Float32,2)
    @test_throws ArgumentError CMA.bound_path(@__DIR__, "../outside")
end

@testset "selected Copper profile reduction" begin
    for order in ("forward", "reverse")
        mktempdir() do root
            f = fixture(root; profile="copper", order)
            report = CMA.document(CMA.reduce_method(f.output, f.package, f.seal))
            @test collect(report.shape) == [3600,2]
            @test report.measurement_units == "normalized pixel"
            @test report.response_units == "normalized pixel per micrometre OPD of estimated coordinate"
            bytes = read(joinpath(f.output, report.path))
            @test length(bytes) == 3600 * 2 * sizeof(Float32)
            @test permutedims(reshape(collect(reinterpret(Float32, bytes)), 2, 3600)) == f.expected
            @test report.profile == "copper"
        end
    end
end

@testset "profile identity and contract admission" begin
    for profile in ("classic", "copper")
        mktempdir() do root
            f = fixture(root; profile)
            selected = CMA.selected_profile(f.output, f.package)
            recipe = (; pairs(CMA.document(joinpath(f.output,"recipe.json")))...)
            method = CMA.document(joinpath(f.output,"method.json"))
            supplied = merge(recipe,(; measurements=1))
            @test CMA.profile_specification(supplied,method,selected).measurements ==
                (profile == "copper" ? 3600 : 376)
            @test selected.physical_count == 277
            provenance = JSON3.read(read(joinpath(f.package,"provenance.json"),String),Dict{String,Any})
            for mutate in (p->(p["profile"]="unknown"),
                    p->(p["source_provenance"]["profile"]="unknown"),
                    p->delete!(p,"profile"), p->delete!(p,"source_provenance"),
                    p->(p["source_provenance"]["hil"]["backend"]="unknown"))
                bad = deepcopy(provenance); mutate(bad)
                open(joinpath(f.package,"provenance.json"),"w") do io
                    JSON3.write(io,bad)
                end
                @test_throws ArgumentError CMA.selected_profile(f.output,f.package)
                @test_throws ArgumentError CMA.reduce_method(f.output,f.package,f.seal)
                @test !ispath(joinpath(f.output,"candidate-response.f32le"))
            end
            open(joinpath(f.package,"provenance.json"),"w") do io
                JSON3.write(io,provenance)
            end
            base = JSON3.read(read(joinpath(f.output,"base-identity.json"),String),Dict{String,Any})
            for mutate in (p->delete!(p,"selected_profile"), p->delete!(p["files"],"provenance.json"),
                    p->(p["selected_profile"]["profile"]="unknown"),
                    p->delete!(p["selected_profile"],"backend"))
                bad=deepcopy(base); mutate(bad)
                open(joinpath(f.output,"base-identity.json"),"w") do io
                    JSON3.write(io,bad)
                end
                @test_throws ArgumentError CMA.selected_profile(f.output,f.package)
            end
            if profile == "copper"
                for settling in ((; kind="immediate"),(; kind="model_time",duration_ns=1),
                        (; kind="discard_exposures",frames=0),(; kind="discard_exposures",frames=true))
                    @test_throws ArgumentError CMA.profile_specification(merge(recipe,(; settling)),method,selected)
                end
                for rail in (4095,16383.0,true)
                    @test_throws ArgumentError CMA.profile_specification(merge(recipe,(; adc_upper_rail=rail)),method,selected)
                end
            end
        end
    end
end

@testset "generic helper preserves known backend and engine metadata" begin
    for profile in ("classic","copper"), engine in ("fgn","jfg"), backend in ("cpu","cuda","amdgpu")
        mktempdir() do root
            f=fixture(root;profile,engine,backend)
            selected=CMA.selected_profile(f.output,f.package)
            @test selected.profile==profile && selected.backend==backend
            @test selected.measurements==(profile=="copper" ? 3600 : 376)
            @test CMA.document(joinpath(f.output,"preparation.json")).backend==backend
        end
    end
end
