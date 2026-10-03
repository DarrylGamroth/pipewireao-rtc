using Test
using JSON3
using SHA
include("calibration_method_analysis.jl")
const CMA = CalibrationMethodAnalysis
const Client = CMA.CalibrationClient

function fixture(root; order="reverse")
    output, package = joinpath(root, "output"), joinpath(root, "package")
    mkpath(joinpath(output, "analysis"))
    mkpath(joinpath(package, "hil"))
    for (source, destination) in (("calibration_method_analysis.jl", joinpath(output, "analysis")),
            ("calibration_client.jl", joinpath(output, "analysis")),
            ("calibration_client.jl", joinpath(package, "hil")))
        cp(joinpath(@__DIR__, source), joinpath(destination, source))
    end
    recipe = (; reference=zeros(Float32, 277), amplitudes=fill(0.25f0, 277),
        frames_per_probe=1, settling=(; kind="immediate"), request_timeout_ns=100000)
    positive = zeros(Float32, 2, 277)
    positive[1,139], positive[2,139] = 0.25f0, 0.5f0
    method = (; version=1, run=73, order,
        probe_basis=(; kind="modal", positive_commands=[collect(row) for row in eachrow(positive)],
            mode_amplitudes=Float32[0.25,0.5]))
    CMA.write_new(joinpath(output, "recipe.json"), recipe)
    CMA.write_new(joinpath(output, "method.json"), method)
    CMA.write_new(joinpath(output, "base-identity.json"), (; files=(;)))
    CMA.prepare_method(output, package)
    canonical = Client.prepare_plan(CMA.prepared_specification(recipe, method))
    chronological, permutation = CMA.ordered_plan(canonical, order)
    physical = zeros(Float32, 376, 277)
    physical[1,139], physical[2,139], physical[376,139] = 2, -3, 7
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
    package_files = Dict("hil/calibration_client.jl" => CMA.digest(joinpath(package, "hil/calibration_client.jl")))
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
