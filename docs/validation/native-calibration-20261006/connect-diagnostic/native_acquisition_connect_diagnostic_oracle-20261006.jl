using Test,PipeWireAODeployment,SHA
const Native=PipeWireAODeployment.NativeAcquisitionLifecycleClient
const Codec=PipeWireAODeployment.NativeAcquisitionLifecycleCodec
const Envelope=PipeWireAODeployment.NativeControlCodec
const Source="/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-native-calibration-consumer/docs/validation/native-calibration-20261006/actual-four-functional/native_acquisition_lifecycle_client-e01.jl"
text=read(Source,String)
found=match(r"function connect_owner!.*?\n    reply = request!.*?\n(.*?)\nend"s,text)
found===nothing && error("retained original Connect body not found")
Core.eval(@__MODULE__,Meta.parse("function retained_require_connected(reply)\n"*found.captures[1]*"\nend"))
selected=only(ARGS)=="before" ? retained_require_connected : Native._require_connected
identity=Envelope.ControllerIdentity(UInt32(7),UInt64(9),Int64(11))
header=Envelope.ReplyHeader(identity,Int64(42),Int64(19),UInt32(5),Int32(-5))
reply=Codec.Completion(header,Codec.Fault,nothing,"owned Connect effect: original failure")
@testset "same injected failed Connect preserves known native evidence" begin
    failure=try selected(reply);nothing catch err;err end
    @test failure isa ErrorException
    message=sprint(showerror,failure)
    println("retained_source_sha256=",bytes2hex(sha256(read(Source))))
    println("failure=",message)
    @test occursin("result=-5",message)
    @test occursin("lifecycle=Fault",message)
    @test occursin("instance=42",message)
    @test occursin("token=19",message)
    @test occursin("operation=5",message)
    @test occursin(reply.message,message)
end
