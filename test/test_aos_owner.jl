using Test
using FITSIO
using JSON3
using PipeWireAORTC

const Owner = PipeWireAORTC.AOSOwner

function owner_configuration(directory; backend="cpu")
    write(joinpath(directory, "simulation.toml"), "schema_version = 1\nname = \"declared_test\"\n")
    return Dict{String,Any}(
        "version" => 1, "graph" => "simulation.toml", "command_input" => "pdm_command",
        "frame_output" => "detector_frame", "command_count" => 3, "frame_shape" => [2, 3],
        "rate" => 500, "exposure_ns" => 1_896_000, "wall_rate" => 10,
        "backend" => backend, "device" => 0,
        "artifacts" => [Dict{String,Any}("binding" => "grid", "path" => "grid.fits",
            "hdu" => 1, "axes" => [2, 1], "type" => "UInt32", "shape" => [3, 2])])
end

@testset "AOS cold declarations and bootstrap load order" begin
    mktempdir() do directory
        path = joinpath(directory, "owner.conf")
        document = owner_configuration(directory)
        write(path, JSON3.write(document))
        argv = ["--config", path, "--remote", "/tmp/aos-private", "--control-node", "simulator-wfs",
            "--bootstrap-node", "rtc.bootstrap.aos", "--bootstrap-instance", "7"]
        options = Owner.configuration(path)
        @test options.graph == joinpath(directory, "simulation.toml")
        @test options.frame_shape == (2, 3)
        @test options.period_ns == 2_000_000
        @test options.exposure_ns == 1_896_000
        @test options.wall_period_ns == 100_000_000
        @test options.total_exchanges === nothing
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
        write(path, JSON3.write(document))
        @test Owner._main(argv; with_owner, load_science=() -> push!(events, :science),
            load_cuda=() -> push!(events, :cuda), run=options -> push!(events, :run)) == 0
        @test events == [:preparing, :check, :science, :check, :cuda, :check, :run, :cleanup]
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
        @test !any(id -> id.name in ("AdaptiveOpticsSim", "AdaptiveOpticsSimPipeWireHIL", "CUDA", "REVOLTClassicSim"), keys(Base.loaded_modules))
        for (key, value) in (("version", true), ("command_count", false), ("frame_shape", [2, 0]),
            ("backend", "automatic"), ("device", -1), ("wall_rate", 501), ("rate", 0),
            ("exposure_ns", 2_000_001), ("command_scale", 1e-100), ("total_exchanges", 0),
            ("optical_observation", "true"), ("unexpected", 1))
            invalid = deepcopy(document)
            invalid[key] = value
            write(path, JSON3.write(invalid))
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
            write(path, JSON3.write(invalid))
            @test_throws Exception Owner.configuration(path)
        end
        document["artifacts"] = repeat(document["artifacts"], 2)
        write(path, JSON3.write(document))
        @test_throws ArgumentError Owner.configuration(path)
    end
end

@testset "AOS FITS binding ownership, order and cancellation" begin
    mktempdir() do directory
        path = joinpath(directory, "owner.conf")
        document = owner_configuration(directory)
        write(path, JSON3.write(document))
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
        @test sort(readdir(directory)) == ["grid.fits", "owner.conf", "simulation.toml"]
        # Selection is exact, and the square case still requires explicit axes.
        document["artifacts"][1]["shape"] = [2, 3]
        write(path, JSON3.write(document))
        @test_throws DimensionMismatch Owner.prepare_bindings(Owner.configuration(path).artifacts)
    end
end
