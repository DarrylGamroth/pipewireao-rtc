using Test
using FITSIO
using JSON
using PipeWireAORTC

const Owner = PipeWireAORTC.AOSOwner

function owner_configuration(directory; backend="cpu")
    write(joinpath(directory, "simulation.yaml"), "schema_version: 1\nname: declared_test\n")
    return Dict{String,Any}(
        "version" => 1, "graph" => "simulation.yaml", "command_input" => "pdm_command",
        "frame_output" => "detector_frame", "command_count" => 3, "frame_shape" => [2, 3],
        "rate" => 500, "exposure_ns" => 1_896_000, "pacing_rate_hz" => 10,
        "backend" => backend, "device" => 0,
        "artifacts" => [Dict{String,Any}("binding" => "grid", "path" => "grid.fits",
            "hdu" => 1, "axes" => [2, 1], "type" => "UInt32", "shape" => [3, 2])])
end

@testset "AOS operational report records a saved cursor atomically" begin
    mktempdir() do directory
        graph = joinpath(directory, "simulation.yaml")
        write(graph, "schema_version = 1\nname = \"report_test\"\n")
        options = (; remote=joinpath(directory, "native"), control_node="simulator-wfs",
            bootstrap_instance=Int64(7), backend=:cpu, graph,
            graph_sha256=PipeWireAORTC.Common.sha256_file(graph))
        state = (; sequence=UInt64(0), running=false, completed=false)
        path = Owner.report_path(options)
        @test path == joinpath(directory, "simulator-wfs-report.json")
        @test Owner.write_report(options, state, Int64(1), Int64(9)) === nothing
        initial = PipeWireAORTC.Common.read_json(path)
        @test initial["generation"] == 1
        @test initial["sequence"] == 0
        @test initial["source_instance"] == 9
        @test initial["bootstrap_instance"] == 7
        @test initial["owner_pid"] == getpid()
        @test initial["graph"] == graph
        @test initial["graph_sha256"] == options.graph_sha256
        @test initial["backend"] == "cpu"
        @test !haskey(initial, "startup_calibration_identity")
        @test !initial["running"] && !initial["completed"]
        @test isempty(initial["failures"])
        original = read(path, String)
        open(path, "r") do prior
            advanced = (; sequence=UInt64(12), running=false, completed=true)
            Owner.write_report(options, advanced, Int64(2), Int64(9);
                failures=[ErrorException("exchange failed after the last adoption")])
            @test read(prior, String) == original
        end
        final = PipeWireAORTC.Common.read_json(path)
        @test final["generation"] == 2 && final["sequence"] == 12
        @test final["completed"] && !final["running"]
        @test final["failures"] == ["exchange failed after the last adoption"]
        @test_throws ArgumentError Owner.write_report(options, state, nothing, Int64(9))
        Owner.write_report(options, state, nothing, Int64(9);
            failures=[ErrorException("cannot query the final generation")])
        unknown = PipeWireAORTC.Common.read_json(path)
        @test unknown["generation"] === nothing
        @test unknown["failures"] == ["cannot query the final generation"]
        @test sort(readdir(directory)) == ["simulation.yaml", "simulator-wfs-report.json"]
        rm(path)
        mkdir(path)
        write(joinpath(path, "retained"), "preserve the conflicting directory")
        @test_throws Base.IOError Owner.write_report(options, state, Int64(3), Int64(9))
        @test isdir(path)
        @test read(joinpath(path, "retained"), String) == "preserve the conflicting directory"
        @test sort(readdir(directory)) == ["simulation.yaml", "simulator-wfs-report.json"]
        @test_throws ArgumentError Owner.write_report(options,
            (; sequence=typemax(UInt64), running=false, completed=false), Int64(3), Int64(9))
    end
end

@testset "AOS cold declarations and bootstrap load order" begin
    mktempdir() do directory
        path = joinpath(directory, "owner.conf")
        document = owner_configuration(directory)
        write(path, JSON.json(document))
        argv = ["--config", path, "--remote", "/tmp/aos-private", "--control-node", "simulator-wfs",
            "--bootstrap-node", "rtc.bootstrap.aos", "--bootstrap-instance", "7"]
        default_timing = Owner.arguments(argv)
        @test default_timing.pipewire_cpu === nothing
        @test default_timing.observation_cpu === nothing
        @test Owner.arguments([argv; ["--observation-cpu", "8"]]).observation_cpu == 8
        @test_throws ArgumentError Owner.arguments([argv; ["--transport-cpu", "7"]])
        @test Owner.arguments([argv; ["--pipewire-cpu", "7"]]).pipewire_cpu == 7
        for cpu in ("-1", "0", "1", "many", "1.5")
            @test_throws ArgumentError Owner.arguments([argv; ["--pipewire-cpu", cpu]])
            @test_throws ArgumentError Owner.arguments([argv; ["--observation-cpu", cpu]])
        end
        @test default_timing.phase_timing_directory === nothing
        @test default_timing.phase_timing_frames == 0
        @test default_timing.phase_timing_warmup == 0
        timing_directory = joinpath(directory, "phase-timing")
        timing_argv = [argv; ["--phase-timing-directory", timing_directory,
            "--phase-timing-frames", "64"]]
        timing_options = Owner.arguments(timing_argv)
        @test timing_options.phase_timing_directory == timing_directory
        @test timing_options.phase_timing_frames == 64
        @test timing_options.phase_timing_warmup == 512
        explicit_warmup = Owner.arguments([timing_argv; ["--phase-timing-warmup", "0"]])
        @test explicit_warmup.phase_timing_warmup == 0
        for invalid_timing in (
            [argv; ["--phase-timing-directory", timing_directory]],
            [argv; ["--phase-timing-frames", "64"]],
            [argv; ["--phase-timing-warmup", "5"]],
            [argv; ["--phase-timing-directory", "relative", "--phase-timing-frames", "64"]],
            [argv; ["--phase-timing-directory", timing_directory, "--phase-timing-frames", "0"]],
            [argv; ["--phase-timing-directory", timing_directory, "--phase-timing-frames", "65537"]],
            [argv; ["--phase-timing-directory", timing_directory, "--phase-timing-frames", "many"]],
            [timing_argv; ["--phase-timing-warmup", "-1"]],
            [timing_argv; ["--phase-timing-warmup", "65537"]],
            [timing_argv; ["--phase-timing-warmup", "many"]],
            [timing_argv; ["--phase-timing-frames", "64"]],
        )
            @test_throws ArgumentError Owner.arguments(invalid_timing)
        end
        options = Owner.configuration(path)
        @test options.graph == joinpath(directory, "simulation.yaml")
        @test options.frame_shape == (2, 3)
        @test options.period_ns == 2_000_000
        @test options.exposure_ns == 1_896_000
        @test options.pacing_period_ns == 100_000_000
        @test options.pacing_rate_hz == 10
        for (pacing, period) in ((0, 0), (3, 333_333_333), (6, 166_666_667), (500, 2_000_000))
            paced = deepcopy(document)
            paced["pacing_rate_hz"] = pacing
            write(path, JSON.json(paced))
            parsed = Owner.configuration(path)
            @test parsed.pacing_rate_hz == pacing
            @test parsed.pacing_period_ns == UInt64(period)
            @test parsed.period_ns == options.period_ns
            @test parsed.exposure_ns == options.exposure_ns
        end
        legacy = deepcopy(document)
        legacy["wall_rate"] = pop!(legacy, "pacing_rate_hz")
        write(path, JSON.json(legacy))
        @test_throws ArgumentError Owner.configuration(path)
        write(path, JSON.json(document))
        @test options.total_exchanges === nothing
        @test options.calibration_identity === nothing
        @test only(options.artifacts).source.path == joinpath(directory, "grid.fits")
        for invalid in ([argv; ["--config", path]], [argv; ["--profile", "classic"]], argv[1:end-1],
            replace(argv, "/tmp/aos-private" => "relative"),
            replace(argv, "rtc.bootstrap.aos" => "simulator-wfs"),
            replace(argv, "7" => "0"))
            @test_throws ArgumentError Owner.arguments(invalid)
        end
        events = Symbol[]
        with_owner = function (f, options)
            push!(events, :preparing)
            try
                f(merge(options, (; owner_check=() -> push!(events, :check), bootstrap_runtime=:runtime)))
            finally
                push!(events, :cleanup)
            end
        end
        @test Owner._main(argv; with_owner,
            load_science=() -> push!(events, :science),
            load_cuda=() -> push!(events, :cuda),
            run=options -> begin
                @test options.bootstrap_runtime === :runtime
                push!(events, :run)
            end) == 0
        @test events == [:preparing, :check, :science, :check, :check, :run, :cleanup]
        empty!(events)
        document["backend"] = "cuda"
        write(path, JSON.json(document))
        @test Owner._main(argv; with_owner, load_science=() -> push!(events, :science),
            load_cuda=() -> push!(events, :cuda), run=options -> push!(events, :run)) == 0
        @test events == [:preparing, :check, :science, :check, :cuda, :check, :run, :cleanup]
        empty!(events)
        document["backend"] = "amdgpu"
        document["device"] = 1
        write(path, JSON.json(document))
        @test Owner.configuration(path).backend === :amdgpu
        @test Owner._main(argv; with_owner, load_science=() -> push!(events, :science),
            load_cuda=() -> error("CUDA must not load for AMDGPU"),
            load_amdgpu=() -> push!(events, :amdgpu), run=options -> push!(events, :run)) == 0
        @test events == [:preparing, :check, :science, :check, :amdgpu, :check, :run, :cleanup]
        document["device"] = 0
        write(path, JSON.json(document))
        @test_throws ArgumentError Owner.configuration(path)
        document["device"] = 1
        write(path, JSON.json(document))
        empty!(events)
        cancelled = (f, options) -> begin
            push!(events, :preparing)
            try
                f(merge(options, (; owner_check=() -> throw(InterruptException()))))
            finally
                push!(events, :cleanup)
            end
        end
        @test_throws InterruptException Owner._main(argv; with_owner=cancelled,
            load_science=() -> push!(events, :science))
        @test events == [:preparing, :cleanup]
        @test !any(id -> id.name in ("AdaptiveOpticsSim", "AdaptiveOpticsSimPipeWireHIL", "CUDA", "AMDGPU", "REVOLTClassicSim"), keys(Base.loaded_modules))
        for (key, value) in (("version", true), ("command_count", false), ("frame_shape", [2, 0]),
            ("backend", "automatic"), ("device", -1), ("pacing_rate_hz", 501), ("pacing_rate_hz", -1),
            ("pacing_rate_hz", true), ("pacing_rate_hz", 1.5), ("rate", 0),
            ("exposure_ns", 2_000_001), ("command_scale", 1e-100), ("total_exchanges", 0),
            ("optical_observation", "true"), ("unexpected", 1))
            invalid = deepcopy(document)
            invalid[key] = value
            write(path, JSON.json(invalid))
            @test_throws ArgumentError Owner.configuration(path)
        end
        for mutation in (
            item -> delete!(item, "axes"),
            item -> (item["axes"] = [1, 1]),
            item -> (item["axes"] = [1]),
            item -> (item["type"] = "Int64"),
            item -> (item["binding"] = "pdm_command"),
            item -> (item["hdu"] = false),
        )
            invalid = deepcopy(document)
            mutation(only(invalid["artifacts"]))
            write(path, JSON.json(invalid))
            @test_throws Exception Owner.configuration(path)
        end
        document["artifacts"] = repeat(document["artifacts"], 2)
        write(path, JSON.json(document))
        @test_throws ArgumentError Owner.configuration(path)
    end
end

@testset "AOS FITS binding ownership, order and cancellation" begin
    mktempdir() do directory
        path = joinpath(directory, "owner.conf")
        document = owner_configuration(directory)
        write(path, JSON.json(document))
        values = UInt32[1 2 3; 4 5 6]
        FITS(joinpath(directory, "grid.fits"), "w") do fits
            write(fits, values)
        end
        options = Owner.configuration(path)
        prepared = Owner.prepare_bindings(options.artifacts)
        @test only(prepared).data == permutedims(values)
        @test only(prepared).data isa Matrix{UInt32}
        @test only(prepared).provenance["axes"] == [2, 1]
        @test only(prepared).provenance["target_shape"] == [3, 2]
        @test_throws InterruptException Owner.prepare_bindings(options.artifacts;
            check=() -> throw(InterruptException()))
        @test sort(readdir(directory)) == ["grid.fits", "owner.conf", "simulation.yaml"]
        # Selection is exact, and the square case still requires explicit axes.
        document["artifacts"][1]["shape"] = [2, 3]
        write(path, JSON.json(document))
        @test_throws DimensionMismatch Owner.prepare_bindings(Owner.configuration(path).artifacts)
    end
end

@testset "Instrument builders remain cold declarations until Preparing" begin
    mktempdir() do directory
        path = joinpath(directory, "owner.conf")
        document = owner_configuration(directory)
        document["version"] = 2
        document["frame_encoding"] = "uint16"
        document["frame_schema"] = "org.calculon.ao.raw-detector-pixels/1"
        document["command_schema"] = "org.calculon.ao.demanded-pdm-command/1"
        document["command_scale"] = 1e-6
        document["calibration_identity"] = "classic-test-startup-calibration"
        delete!(document, "graph")
        delete!(document, "artifacts")
        document["plant"] = Dict("package" => "REVOLTClassicSim",
            "settings" => Dict("profile" => "grid_gaussian"))
        write(path, JSON.json(document))
        options = Owner.configuration(path)
        @test options.version == 2
        @test options.graph === nothing
        @test isempty(options.artifacts)
        @test options.config_path == path
        @test options.plant == (; package=:REVOLTClassicSim, settings=(; profile="grid_gaussian"))
        @test isconcretetype(typeof(options.plant))
        @test options.frame_encoding === :uint16
        @test options.calibration_identity == "classic-test-startup-calibration"
        @test Owner.plant_settings(Dict("value" => "")) == (; value="")
        @test_throws ArgumentError Owner.plant_settings(Dict("value" => "\0"))
        @test_throws ArgumentError Owner.plant_settings(Dict("value" => repeat("a", 16 * 1024 + 1)))
        @test Owner.plant_settings(Dict("nested" => [1, true, nothing, Dict("value" => 2.0)])) ==
            (; nested=(1, true, nothing, (; value=2.0)))
        @test_throws ArgumentError Owner.plant_settings(Dict("value" => Inf))
        @test_throws ArgumentError Owner.plant_settings(Dict("value" => :symbol))
        @test_throws ArgumentError Owner.plant_settings(Dict("value" => zeros(4096)))
        deep = Dict{String,Any}("value" => 1)
        for _ in 1:17
            deep = Dict{String,Any}("nested" => deep)
        end
        @test_throws ArgumentError Owner.plant_settings(deep)
        for mutation in (
            item -> (item["frame_encoding"] = "float32"),
            item -> (item["graph"] = "simulation.yaml"),
            item -> (item["artifacts"] = []),
            item -> (item["plant"]["package"] = "REVOLTClassicSim.path"),
            item -> (item["plant"]["package"] = "../REVOLTClassicSim"),
            item -> (item["plant"]["package"] = ""),
            item -> (item["plant"]["settings"] = []),
            item -> (item["plant"]["settings"] = Dict("bad-name" => 1)),
            item -> (item["plant"]["extra"] = 1),
            item -> delete!(item["plant"], "settings"),
            item -> delete!(item["plant"], "package"),
        )
            invalid = deepcopy(document)
            mutation(invalid)
            write(path, JSON.json(invalid))
            @test_throws ArgumentError Owner.configuration(path)
        end
        for key in ("version", "plant", "command_input", "frame_output", "command_count",
                "frame_shape", "rate", "exposure_ns", "pacing_rate_hz", "backend", "device",
                "frame_encoding", "frame_schema", "command_schema", "command_scale")
            invalid = deepcopy(document)
            delete!(invalid, key)
            write(path, JSON.json(invalid))
            @test_throws ArgumentError Owner.configuration(path)
        end
        for identity in (nothing, true, 42, "", "invalid\0identity", repeat("a", 16 * 1024 + 1))
            invalid = deepcopy(document)
            invalid["calibration_identity"] = identity
            write(path, JSON.json(invalid))
            @test_throws ArgumentError Owner.configuration(path)
        end
        write(path, JSON.json(document))
        args = ["--config", path, "--remote", "/tmp/aos-private", "--control-node", "simulator-wfs",
            "--bootstrap-node", "rtc.bootstrap.aos", "--bootstrap-instance", "7"]
        events = Symbol[]
        with_owner = function (f, admitted)
            push!(events, :preparing)
            f(merge(admitted, (; owner_check=() -> push!(events, :check))))
        end
        @test Owner._main(args; with_owner,
            load_science=() -> push!(events, :science),
            load_plant=package -> begin
                @test package === :REVOLTClassicSim
                push!(events, :plant)
                :instrument_module
            end,
            run=admitted -> begin
                @test admitted.plant_module === :instrument_module
                push!(events, :run)
            end) == 0
        @test events == [:preparing, :check, :science, :check, :check, :plant, :check, :run]
        empty!(events)
        @test_throws InterruptException Owner._main(args;
            with_owner=(f, admitted) -> f(merge(admitted, (; owner_check=() -> throw(InterruptException())))),
            load_science=() -> push!(events, :science),
            load_plant=package -> push!(events, :plant))
        @test isempty(events)
        report_options = merge(options, (; remote=joinpath(directory, "native"),
            control_node="simulator-wfs", bootstrap_instance=Int64(7),
            configuration_sha256=PipeWireAORTC.Common.sha256_file(path)))
        Owner.write_report(report_options, (; sequence=UInt64(0), running=false, completed=false), 1, 9)
        report = PipeWireAORTC.Common.read_json(Owner.report_path(report_options))
        @test report["graph"] === nothing && report["graph_sha256"] === nothing
        @test report["configuration"] == path
        @test report["configuration_sha256"] == report_options.configuration_sha256
        @test report["plant"]["package"] == "REVOLTClassicSim"
        @test report["plant"]["settings"]["profile"] == "grid_gaussian"
        @test report["startup_calibration_identity"] == "classic-test-startup-calibration"
        @test !any(id -> id.name in ("AdaptiveOpticsSim", "AdaptiveOpticsSimPipeWireHIL", "CUDA", "AMDGPU", "REVOLTClassicSim"), keys(Base.loaded_modules))
    end
end

Base.include(@__MODULE__, joinpath(@__DIR__, "test_aos_plant_loading.jl"))
