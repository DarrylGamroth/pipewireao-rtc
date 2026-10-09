module NativeCalibrationActionClientTests
using Test, PipeWireAODeployment
const Native = PipeWireAODeployment.NativeCalibrationActionClient
const Generic = PipeWireAODeployment.NativeControlClient
const Codec = PipeWireAODeployment.NativeCalibrationActionCodec
const Lifecycle = PipeWireAODeployment.NativeAcquisitionLifecycleCodec
const Envelope = PipeWireAODeployment.NativeControlCodec
mutable struct FakeNative
    answer::Any
    failure::Any
    commands::Vector{Any}
    closed::Bool
end
function Generic.request!(fake::FakeNative,command;deadline,check)
    check()
    fake.closed && throw(Generic.UnknownOutcome("closed fake client"))
    push!(fake.commands,command)
    fake.failure === nothing || throw(fake.failure)
    return fake.answer
end
Base.close(fake::FakeNative) = (fake.closed=true;nothing)
struct OversizedFigure <: AbstractVector{Float64} end
Base.size(::OversizedFigure) = (4096,)
Base.getindex(::OversizedFigure, ::Int) = error("oversized figure was read before capacity validation")
const binding = Native.Binding("/tmp/private-core","owner.actions",UInt32(7),Int64(42))
const identity = Envelope.ControllerIdentity(UInt32(7),typemax(UInt64),Int64(11))
header(op,result=Int32(0)) = Envelope.ReplyHeader(identity,Int64(42),Int64(1),UInt32(op),result)
function connection(result;op=1,run=typemax(UInt64),serial=UInt64(1),transport=Int32(0))
    reply = Codec.Completion(header(op,transport),Lifecycle.Connected,run,serial,result,"")
    fake = FakeNative(reply,nothing,Any[],false)
    return Native.Connection(fake,binding,typemax(UInt64),UInt64(0),Int64(1_000_000_000),2,Any[],false)
end
@testset "native calibration action client preserves correlation and known outcomes" begin
    cursor = Codec.AcquisitionCursor(typemax(UInt64),UInt64(1)<<63,UInt64(0),UInt64(0))
    client = connection(Codec.Held(cursor))
    answer = Native.request!(client,Dict("kind"=>"hold"),"held")
    @test answer["cursor"]["domain"]==typemax(UInt64)
    @test only(client.client.commands).run==typemax(UInt64)
    @test only(client.client.commands).serial==1
    @test client.can_restore && length(client.records)==1
    @test client.records[1]["reply"]["run"]==typemax(UInt64)
    for reason in (Codec.Endpoint,Codec.Cancelled,Codec.ProbeClipped,Codec.InvalidEvidence)
        client=connection(Codec.Failed(reason))
        @test_throws ArgumentError Native.request!(client,Codec.Hold(),"held")
        @test client.can_restore==(reason===Codec.InvalidEvidence)
        @test !client.client.closed
    end
    client=connection(Codec.Released();op=7)
    @test Native.request!(client,Codec.Release(),"released")["kind"]=="released"
    @test length(client.records)==1
    close(client)
    @test client.client.closed
end
@testset "unknown native outcomes retire the action client" begin
    cursor=Codec.AcquisitionCursor(1,1,0,0)
    for client in (connection(Codec.Held(cursor);run=UInt64(2)),
            connection(Codec.Held(cursor);serial=UInt64(2)),
            connection(nothing;transport=Int32(-110)),
            connection(Codec.Released()),
            connection(Codec.Adopted(cursor,Float32[1],false);op=2))
        requested=client.client.answer.header.operation==2 ? Codec.Adopt(UInt32(0),Float32[1,2]) : Codec.Hold()
        @test_throws Generic.UnknownOutcome Native.request!(client,requested,"held")
        @test !client.can_restore && client.client.closed
    end
    client=connection(Codec.Held(cursor))
    client.client.failure=Generic.UnknownOutcome("private core disconnected")
    @test_throws Generic.UnknownOutcome Native.request!(client,Codec.Hold(),"held")
    @test client.client.closed && !client.can_restore
    @test_throws Generic.UnknownOutcome Native.request!(client,Codec.Hold(),"held")
    @test length(client.client.commands)==1 # Never submit a retry.
end
@testset "local validation does not consume or submit native requests" begin
    client=connection(Codec.Released();op=7)
    for value in (Dict("kind"=>"adopt","probe"=>0,"figure"=>[NaN]),
            Dict("kind"=>"adopt","probe"=>true,"figure"=>[1]),
            Dict("kind"=>"hold","extra"=>1),Dict("kind"=>"unknown"),
            Dict("kind"=>"restore","figure"=>[1],"rule"=>Dict("kind"=>"model_time","duration_ns"=>0)))
        @test_throws ArgumentError Native.request!(client,value,"released")
    end
    @test client.serial==0 && isempty(client.client.commands)
    for value in (Dict("kind"=>"adopt","probe"=>0,"figure"=>OversizedFigure()),
            Dict("kind"=>"restore","figure"=>OversizedFigure(),"rule"=>Dict("kind"=>"immediate")))
        @test_throws ArgumentError Native.request!(client,value,"released")
    end
    @test client.serial==0 && isempty(client.client.commands)
    client.serial=typemax(UInt64)
    @test_throws OverflowError Native.request!(client,Codec.Release(),"released")
    @test isempty(client.client.commands)
    for values in (("remote","node",0,1),("remote","node",1,0))
        @test_throws ArgumentError Native.Binding(values...)
    end
end
end
