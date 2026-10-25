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

@testset "named simulator command declarations seal concrete counts and wire contracts" begin
    owner = PipeWireAORTC.AOSOwner
    names = owner.command_inputs(["woofer", "tweeter", "tiptilt"])
    @test names == (:woofer, :tweeter, :tiptilt)
    counts = owner.command_values(owner.command_count,
        Dict("tiptilt" => 2, "woofer" => 97, "tweeter" => 2304), names, "command_count")
    @test counts === (; woofer=97, tweeter=2304, tiptilt=2)
    @test owner.command_shapes(counts) === (; woofer=(97,), tweeter=(2304,), tiptilt=(2,))
    @test isconcretetype(typeof(counts))
    nodes = owner.command_values(owner.node_name,
        Dict(string(name) => "simulator-" * string(name) for name in names), names, "command_node")
    @test keys(nodes) === names
    scales = owner.command_values(owner.command_scale,
        Dict(string(name) => 1 for name in names), names, "command_scale")
    @test scales === (; woofer=1.0f0, tweeter=1.0f0, tiptilt=1.0f0)
    @test owner.command_inputs("command") === :command
    @test owner.command_shapes(owner.command_count(277, "count")) === (277,)
    for invalid in ([], ["woofer", "woofer"], ["bad name"], [true], fill("woofer", 17), nothing)
        @test_throws ArgumentError owner.command_inputs(invalid)
    end
    for invalid in (97, Dict("woofer" => 97), Dict("woofer" => 97, "tweeter" => 2304, "tiptilt" => 2, "extra" => 1))
        @test_throws ArgumentError owner.command_values(owner.command_count, invalid, names, "command_count")
    end
    for invalid in (0, -1, true, 2.5)
        @test_throws ArgumentError owner.command_values(owner.command_count,
            merge(Dict{String,Any}(string(name) => 1 for name in names), Dict{String,Any}("tiptilt" => invalid)), names, "command_count")
    end
    for invalid in (true, 0, -1, Inf, 1e100, 1e-100)
        @test_throws ArgumentError owner.command_values(owner.command_scale,
            merge(Dict{String,Any}(string(name) => 1 for name in names), Dict{String,Any}("tiptilt" => invalid)), names, "command_scale")
    end
    mirrors = Dict(name => Dict("layout" => Dict("command_positions" => fill([1, 1], counts[Symbol(name)])),
        "command_scale_m" => 1) for name in ("woofer", "tweeter"))
    @test isnothing(PipeWireAORTC.InstrumentDefinition.verify_mirror_commands(mirrors, counts, scales))
    @test_throws DimensionMismatch PipeWireAORTC.InstrumentDefinition.verify_mirror_commands(mirrors,
        merge(counts, (; woofer=96)), scales)
    @test_throws ArgumentError PipeWireAORTC.InstrumentDefinition.verify_mirror_commands(mirrors,
        (; tweeter=2304, tiptilt=2), (; tweeter=1.0f0, tiptilt=1.0f0))
    @test_throws ArgumentError PipeWireAORTC.InstrumentDefinition.verify_mirror_commands(mirrors,
        counts, merge(scales, (; woofer=1.0f-6)))
end
