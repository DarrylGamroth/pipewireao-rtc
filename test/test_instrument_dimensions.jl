using Test, PipeWireAORTC
const I = PipeWireAORTC.InstrumentConfiguration
const C = PipeWireAORTC.Common

@testset "controller dimensions follow declared coordinates and mirror geometry" begin
    mktempdir() do directory
        document = Dict("schema_version"=>1, "id"=>"shared-mirror", "manufacturer"=>"Example",
            "model"=>"Three commands", "layout"=>Dict("schema_version"=>1,
                "name"=>"Ordered commands", "grid_shape"=>[3,1], "axis_labels"=>["column","row"],
                "command_positions"=>[[1,1],[2,1],[3,1]], "command_order"=>"listed",
                "provenance"=>"synthetic contract test"))
        C.write_yaml(joinpath(directory,"mirror.yaml"), document)
        instrument = (;directory, document=Dict("deformable_mirrors"=>Dict(
            "mirror-a"=>Dict("description"=>"mirror.yaml"),
            "mirror-b"=>Dict("description"=>"mirror.yaml"))))
        authoring = Dict("controller"=>Dict("command_count"=>5, "hidden_modes"=>["mean-command"]),
            "dimensions"=>Dict{String,Any}("active_vdm_count"=>Dict("\$ref"=>"/rtc/controller/command_count"),
                "full_vdm_count"=>Dict("\$ref"=>"/instrument/deformable_mirrors/mirror-b/actuator_count")))
        original = deepcopy(authoring)
        @test I.controller_dimensions(authoring,instrument) == Dict("controller_command_count"=>5,
            "hidden_mode_count"=>1, "active_vdm_count"=>5, "full_vdm_count"=>3)
        @test authoring == original
        @test !haskey(instrument.document["deformable_mirrors"]["mirror-b"], "actuator_count")
        authoring["controller"]["command_count"] = 8
        authoring["controller"]["hidden_modes"] = ["mode-a", "mode-b"]
        @test I.controller_dimensions(authoring,instrument)["active_vdm_count"] == 8
        @test I.controller_dimensions(authoring,instrument)["hidden_mode_count"] == 2
        empty!(authoring["controller"]["hidden_modes"])
        @test I.controller_dimensions(authoring,instrument)["hidden_mode_count"] == 0
        for count in (0,-1,true,2.5)
            invalid = deepcopy(original); invalid["controller"]["command_count"] = count
            @test_throws ArgumentError I.controller_dimensions(invalid,instrument)
        end
        for modes in (["a","a"],[""],[true],"a")
            invalid = deepcopy(original); invalid["controller"]["hidden_modes"] = modes
            @test_throws ArgumentError I.controller_dimensions(invalid,instrument)
        end
        for name in ("controller_command_count", "hidden_mode_count")
            invalid = deepcopy(original); invalid["dimensions"][name] = 5
            @test_throws ArgumentError I.controller_dimensions(invalid,instrument)
        end
        invalid = deepcopy(original)
        invalid["dimensions"]["active_vdm_count"] = Dict("\$ref"=>"/rtc/dimensions/active_vdm_count")
        @test_throws ArgumentError I.controller_dimensions(invalid,instrument)
        # An arbitrary graph may declare dimensions without a correction controller.
        @test I.controller_dimensions(Dict("dimensions"=>Dict("mode_count"=>7)),instrument) == Dict("mode_count"=>7)
    end
end
