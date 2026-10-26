using Test, PipeWireAORTC

const IC = PipeWireAORTC.InstrumentConfiguration

@testset "node construction bindings are explicit cold metadata" begin
    specs = Dict("calibration" => Dict("kind" => "fits", "path" => "transfer.fits"))
    node = Dict("name" => "response", "config" => Dict("input_shape" => [3, 5]),
        "bindings" => Dict("transfer" => "calibration"))
    @test IC.node_configuration_bindings(node, specs) == Dict("transfer" => "calibration")
    @test isempty(IC.node_configuration_bindings(Dict("config" => Dict()), specs))
    for invalid in (Dict("transfer" => "absent"), Dict("" => "calibration"),
            Dict("transfer" => 1), Dict("../transfer" => "calibration"), "calibration")
        @test_throws ArgumentError IC.node_configuration_bindings(merge(node, Dict("bindings" => invalid)), specs)
    end
    @test_throws ArgumentError IC.node_configuration_bindings(
        merge(node, Dict("config" => Dict("transfer" => "calibration"))), specs)

    # Pure source metadata selects construction arrays in both graph modes and
    # hashes their files without inspecting arbitrary strings inside config.
    graph = Dict("schema_version" => 1, "name" => "declared", "nodes" => [node],
        "inputs" => [], "outputs" => [])
    document = Dict("profiles" => Dict("basic" => Dict("nodes" => [], "parameters" => [])),
        "settings_bindings" => [], "bindings" => specs)
    physical = (; document=Dict("deformable_mirrors" => Dict(), "wavefront_sensors" => Dict()))
    declaration = (; directory=@__DIR__, instrument=physical, document,
        graphs=Dict("production" => graph, "calibration" => graph))
    @test IC.selected_binding_names(declaration, Dict("profile" => "basic")) == Set(["calibration"])
    @test IC.artifact_paths(declaration, Dict("profile" => "basic")) == Set(["transfer.fits"])

    mktempdir() do directory
        artifact = Dict("path" => "not-on-this-host.fits", "hdu" => 1,
            "axes" => [1, 2], "type" => "Float32", "shape" => [7, 9])
        @test IC._validate_artifact_values(artifact, directory, "calibration"; check_file=false) === nothing
        @test_throws Base.IOError IC._validate_artifact_values(artifact, directory, "calibration")
        for path in ("../outside.fits", "/outside.fits", "", "bad\0.fits")
            @test_throws ArgumentError IC._validate_artifact_values(
                merge(artifact, Dict("path" => path)), directory, "calibration"; check_file=false)
        end
    end
    @test !any(id -> id.name in ("AdaptiveOpticsSim", "AdaptiveOpticsSimPipeWireHIL", "CUDA", "AMDGPU"), keys(Base.loaded_modules))
end
