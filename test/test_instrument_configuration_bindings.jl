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

@testset "grid-index binding rejects nonidentity pupil registration" begin
    mktempdir() do directory
        description = Dict("schema_version"=>1,"id"=>"registered-mirror",
            "manufacturer"=>"Example","model"=>"Test mirror",
            "layout"=>Dict("schema_version"=>1,"name"=>"Physical command grid",
                "grid_shape"=>[3,3],"axis_labels"=>["source column","source row"],
                "command_order"=>"physical","command_positions"=>[[3,1],[1,3],[2,2]]))
        path = joinpath(directory,"mirror.json")
        PipeWireAORTC.Common.write_json(path,description)
        registration = Dict{String,Any}("actuator_pitch_pupil_radius"=>0.125)
        mirror = Dict{String,Any}("description"=>"mirror.json","pupil_registration"=>registration)
        declaration = (;directory,document=Dict("deformable_mirrors"=>Dict("dm"=>mirror)))
        grid = Dict("kind"=>"mirror_grid_indices","mirror"=>"dm")
        coordinates = Dict("kind"=>"mirror_coordinates","mirror"=>"dm")
        expected = Int32[9,1,5]
        @test IC.binding_values(declaration,NamedTuple(),grid) == expected
        for rotation_deg in (0.0,360.0,-720.0)
            mirror["pupil_registration"] = merge(registration,Dict("rotation_deg"=>rotation_deg,
                "flip_y"=>false,"offset_actuators"=>[0.0,0.0]))
            @test IC.binding_values(declaration,NamedTuple(),grid) == expected
        end
        for change in (Dict("rotation_deg"=>31.2),Dict("flip_y"=>true),
                Dict("offset_actuators"=>[0.73,0.37]))
            mirror["pupil_registration"] = merge(registration,change)
            @test_throws r"nonidentity pupil registration.*grid_gaussian" IC.binding_values(
                declaration,NamedTuple(),grid)
            # Coordinate-based consumers still receive the registered P values.
            geometry = IC.mirror(declaration,NamedTuple(),"dm")
            @test IC.binding_values(declaration,NamedTuple(),coordinates) ==
                IC.actuator_coordinates(geometry.description;pupil_registration=geometry.registration)
        end
    end
    @test !any(id -> id.name in ("AdaptiveOpticsSim","AdaptiveOpticsSimPipeWireHIL","CUDA","AMDGPU"),keys(Base.loaded_modules))
end
