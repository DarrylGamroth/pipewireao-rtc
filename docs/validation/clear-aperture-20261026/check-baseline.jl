using Test, JSON, PipeWireAORTC
include_string(Main,first(split(read("test/test_instrument_definition.jl",String),"@testset")),"test/test_instrument_definition.jl")
baseline=read(`git show 23db2ab:src/instrument_definition.jl`,String)
include_string(PipeWireAORTC,replace(baseline,"module InstrumentDefinition\n"=>"module InstrumentDefinitionBeforeAperture\n";count=1),joinpath(pwd(),"src/instrument_definition.jl"))
before=PipeWireAORTC.InstrumentDefinitionBeforeAperture
@testset "same-input aperture regression before and after" begin
    invalid=operational_instrument()
    invalid["deformable_mirrors"]["dm"]["clear_aperture"]["radius"]=1e-100
    @test before.validate(invalid) === invalid
    @test_throws ArgumentError Instrument.validate(invalid)
    mktempdir() do root
        path=joinpath(root,"instrument.json")
        changed=operational_instrument()
        changed["deformable_mirrors"]["dm"]["clear_aperture"]["radius"]=1.3
        write(path,JSON.json(changed))
        options=(;instrument=path,calibration_identity=changed["calibration_identity"],
            command_count=3,frame_shape=(2,3),command_scale=1f-6,
            frame_schema="pipewireao/raw-detector-pixels-u16/1",plant=(;settings=NamedTuple()))
        @test before.verify_plant(options,InstrumentPlantForTest) === nothing
        @test_throws ArgumentError Instrument.verify_plant(options,InstrumentPlantForTest)
    end
end
