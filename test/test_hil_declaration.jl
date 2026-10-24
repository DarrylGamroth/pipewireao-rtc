using Test, PipeWireAORTC
const HILDeclaration = PipeWireAORTC.InstrumentConfiguration

@testset "Named HIL authoring contracts" begin
    inputs=Dict(mode=>Set(["woofer","tweeter","tiptilt"]) for mode in ("calibration","production"))
    outputs=Dict(mode=>Set(["frame"]) for mode in keys(inputs))
    hil=Dict("command_input"=>["woofer","tweeter","tiptilt"],"frame_output"=>"frame")
    @test isnothing(HILDeclaration._validate_hil(hil,inputs,outputs))
    @test isnothing(HILDeclaration._validate_hil(Dict("command_input"=>"woofer","frame_output"=>"frame"),inputs,outputs))
    for invalid in ([],["woofer","woofer"],["missing"],[false],fill("woofer",17))
        @test_throws ArgumentError HILDeclaration._validate_hil(merge(hil,Dict("command_input"=>invalid)),inputs,outputs)
    end
    incomplete=deepcopy(inputs)
    delete!(incomplete["calibration"],"tiptilt")
    @test_throws ArgumentError HILDeclaration._validate_hil(hil,incomplete,outputs)
    schemas=Dict("woofer"=>"test.woofer/1","tweeter"=>"test.tweeter/1","tiptilt"=>"test.tiptilt/1")
    scales=Dict{String,Any}(name=>1 for name in keys(schemas))
    @test isnothing(HILDeclaration.validate_command_contract(schemas,scales))
    @test isnothing(HILDeclaration.validate_boundary_contract(hil["command_input"],schemas))
    @test_throws ArgumentError HILDeclaration.validate_boundary_contract(["woofer"],schemas)
    @test_throws ArgumentError HILDeclaration.validate_boundary_contract("woofer",schemas)
    for invalid in (true,0,-1,Inf,1e100,1e-100)
        @test_throws ArgumentError HILDeclaration.validate_command_contract(schemas,merge(scales,Dict("tiptilt"=>invalid)))
    end
    @test_throws ArgumentError HILDeclaration.validate_command_contract(schemas,Dict("woofer"=>1))
    @test_throws ArgumentError HILDeclaration.validate_command_contract(schemas,1)
    @test_throws ArgumentError HILDeclaration.validate_command_contract(Dict("woofer"=>schemas),Dict("woofer"=>scales))
    @test_throws ArgumentError HILDeclaration.validate_command_contract(Dict("bad name"=>"test/1"),Dict("bad name"=>1))
end
