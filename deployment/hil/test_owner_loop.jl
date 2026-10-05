using Test, PipeWireAO
include("owner_protocol.jl")
include("source_control.jl")

# Exercise the actual serialized-loop helpers without preparing optical models.
module OwnerLoopFixture
using PipeWireAO
const Protocol = Main.HILOwnerProtocol
const SourceControl = Main.HILSourceControl
struct Endpoint{S}
    stream::S
    generation::Int64
end
with_frame_stream(f, endpoint::Endpoint) = f(endpoint.stream)
frame_acquisition_generation(endpoint::Endpoint) = endpoint.generation
end

function owner_helper_definition(expression, name)
    expression isa Expr && expression.head === :function || return false
    signature = expression.args[1]
    signature isa Expr && signature.head === :where && (signature = signature.args[1])
    return signature isa Expr && signature.head === :call && signature.args[1] === name
end
source = Meta.parseall(read(joinpath(@__DIR__,"simulator.jl"),String))
for name in (:consume_native_control!, :pace_owner!)
    definitions = filter(expression -> owner_helper_definition(expression,name), source.args)
    Core.eval(OwnerLoopFixture,only(definitions))
end
owner_noop() = nothing
function poll_bytes(mailbox,endpoint,state)
    OwnerLoopFixture.consume_native_control!(mailbox,endpoint,state,UInt64(1),owner_noop,owner_noop)
    return @allocated OwnerLoopFixture.consume_native_control!(mailbox,endpoint,state,
        UInt64(1),owner_noop,owner_noop)
end

@testset "native controls at adopted owner boundaries" begin
    context = Context()
    core = CoreConnection(context;self=true)
    stream = Stream(core,"native-owner-loop-fixture")
    try
        mailbox = HILSourceControl.Mailbox(Int64(73))
        endpoint = OwnerLoopFixture.Endpoint(stream,Int64(1))
        state = HILOwnerProtocol.OwnerState()
        reports = Ref(0)
        resets = Ref(0)
        report!() = (reports[] += 1; nothing)
        reset!() = (resets[] += 1; nothing)
        consume!() = OwnerLoopFixture.consume_native_control!(mailbox,endpoint,state,
            UInt64(2_000_000),reset!,report!)
        @test poll_bytes(mailbox,endpoint,state) == 0
        HILSourceControl.stage!(mailbox,HILSourceControl.RUN,Int64(1),true)
        @test !state.running # delivery is not adoption
        @test consume!() === nothing
        @test state.running && reports[] == 0
        # Model the caller's outstanding exchange. A callback may stage pause;
        # the real owner consumes only once exchange_frame! has adopted command.
        HILSourceControl.stage!(mailbox,HILSourceControl.RUN,Int64(2),false)
        @test state.running && state.sequence == 0
        state.sequence = 7 # matching command adoption before consume
        @test consume!() === nothing
        @test !state.running && state.sequence == 7 && reports[] == 0
        destination = Ref(mailbox.snapshot.prototype)
        @test parse_props!(destination,mailbox.snapshot,mailbox.snapshot.pod) == 0
        @test destination[][7] == 7 && !destination[][8]
        @test destination[][11] == 0 # pause did not publish a saved checkpoint
        HILSourceControl.stage!(mailbox,HILSourceControl.QUERY,Int64(3))
        @test consume!() === nothing
        @test reports[] == 0 && !state.running && state.sequence == 7
        HILSourceControl.stage!(mailbox,HILSourceControl.RESET,Int64(4))
        @test consume!() === nothing
        @test resets[] == reports[] == 1
        @test !state.running && !state.completed && state.sequence == 0
        @test state.last_request_id == 4 && mailbox.last_token == 4
        @test mailbox.report_generation == 1 && mailbox.report_sequence == 0
        OwnerLoopFixture.pace_owner!()
        @test (@allocated OwnerLoopFixture.pace_owner!()) == 0
    finally
        close(stream); close(core); close(context)
    end
end
