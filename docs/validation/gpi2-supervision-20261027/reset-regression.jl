# Generated regression reproducer; no source or service mutation.
using PipeWireAORTC, Test
root=get(ENV,"RTC_SOURCE_ROOT",normpath(joinpath(@__DIR__,"../../..")))
if ARGS == ["before"]
    core=read(joinpath(root,"src/owners/correction_supervision.jl"),String)
    core=replace(core,"module CorrectionSupervision"=>"module BeforeSupervision",
        "include(\"correction_supervision_observer.jl\")"=>"",
        "include(\"correction_supervision_client.jl\")"=>"")
    Base.include_string(PipeWireAORTC,core)
    original=read(`git -C $root show b0f5593:src/owners/correction_supervision_observer.jl`,String)
    Base.include_string(PipeWireAORTC.BeforeSupervision,original)
    global CS=PipeWireAORTC.BeforeSupervision
else
    global CS=PipeWireAORTC.CorrectionSupervision
end
clock=Ref(UInt64(1000))
format=(element_type=Float32,shape=(4,),layout=:row_major,schema=CS.FEEDBACK_SCHEMA)
policy=(configuration=CS.Configuration(trip_fraction=.5,clear_fraction=0.,
    persistence_ns=100,max_gap_ns=1000),tolerance=0.,schema=format.schema,
    shape=format.shape,layout=format.layout)
observer=CS.Observer((feedback=format,),(feedback=policy,);owner_instance=7,clock=()->clock[])
function frame(sequence,now)
    clock[]=now
    observer(Val(:frame),(feedback=zeros(Float32,4),),
        (feedback=(sequence=UInt64(sequence),offset=0,corrupted=false,discontinuity=false),))
    only(CS.snapshot(observer))
end
@testset "Reset remains unavailable even after old sequence high-water" begin
    @test frame(1000,1000).state===:Clear
    observer(Val(:reset))
    @test frame(1,1050).state===:Unknown
    @test frame(1001,1100).state===:Unknown
    @test CS.request_rearm!(observer,7)==0
end
