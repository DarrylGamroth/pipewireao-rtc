using Test, YAML, PipeWireAORTC

@testset "Generated binding files remain separate and unambiguous" begin
    IC=PipeWireAORTC.InstrumentConfiguration
    mktempdir() do directory
        write_yaml(name, value) = YAML.write_file(joinpath(directory, name), value)
        write_yaml(
            "instrument.yaml",
            Dict(
                "schema_version"=>1,
                "id"=>"binding_test",
                "deformable_mirrors"=>Dict(),
                "wavefront_sensors"=>Dict(
                    "scc"=>Dict("kind"=>"scc", "detector"=>Dict("name"=>"synthetic")),
                ),
            ),
        )
        binding=Dict("kind"=>"zeros", "type"=>"Float32", "shape"=>[1])
        write_yaml("bindings.yaml", Dict("command"=>binding))
        model=Dict{String,Any}(
            "schema_version"=>1,
            "id"=>"binding_test",
            "instrument"=>"instrument.yaml",
            "defaults"=>Dict(),
            "settings_schema"=>Dict(),
            "profiles"=>Dict(),
            "frame_period_s"=>0.001,
            "graphs"=>Dict(),
            "binding_files"=>["bindings.yaml"],
        )
        path=joinpath(directory, "definition.yaml")
        write_yaml("definition.yaml", model)
        resolved=IC.simulation_documents(path)
        @test resolved.document["bindings"]["command"]==binding
        @test !haskey(resolved.authoring, "bindings")
        @test model["binding_files"]==["bindings.yaml"]
        model["bindings"]=Dict("command"=>binding)
        write_yaml("definition.yaml", model)
        @test_throws ArgumentError IC.simulation_documents(path)
        delete!(model, "bindings")
        for files in (
            ["bindings.yaml", "bindings.yaml"],
            ["../outside.yaml"],
            [joinpath(directory, "bindings.yaml")],
            fill("bindings.yaml", 9),
            [1],
        )
            model["binding_files"]=files
            write_yaml("definition.yaml", model)
            @test_throws ArgumentError IC.simulation_documents(path)
        end
    end
end
