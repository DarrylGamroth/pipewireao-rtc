using Test, JSON, PipeWireAORTC
include_string(Main,first(split(read("test/test_instrument_definition.jl",String),"@testset")),"test/test_instrument_definition.jl")
baseline=read(`git show 054da19:src/instrument_definition.jl`,String)
include_string(PipeWireAORTC,replace(baseline,"module InstrumentDefinition\n"=>"module InstrumentDefinitionBefore\n";count=1),joinpath(pwd(),"src/instrument_definition.jl"))
before=PipeWireAORTC.InstrumentDefinitionBefore
@testset "same-case baseline numeric and source identity comparisons" begin
    for mutation in (dm->(dm["pupil"]["inner_radius"]=1e-100),
            dm->(dm["pupil_coordinates"][1]=[1e100,0]))
        invalid=operational_instrument()
        mutation(invalid["deformable_mirrors"]["dm"])
        @test before.validate(invalid) === invalid
        @test_throws ArgumentError Instrument.validate(invalid)
    end
    mktempdir() do root
        path=joinpath(root,"instrument.json")
        invalid=operational_instrument()
        invalid["deformable_mirrors"]["dm"]["pupil"]["inner_radius"]=0.5
        write(path,JSON.json(invalid))
        options=(;instrument=path,calibration_identity=invalid["calibration_identity"],
            command_count=3,frame_shape=(2,3),command_scale=1f-6,
            frame_schema="pipewireao/raw-detector-pixels-u16/1",plant=(;settings=NamedTuple()))
        @test before.verify_plant(options,InstrumentPlantForTest) === nothing
        @test_throws ArgumentError Instrument.verify_plant(options,InstrumentPlantForTest)
    end
end
