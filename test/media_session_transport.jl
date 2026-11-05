module MediaSessionTransportTests
using Test, PipeWireAORTC, PipeWireAO, Clocks
const S = PipeWireAORTC.MediaSession

struct OpenCore end
Base.isopen(::OpenCore) = true
mutable struct Runtime
    clock::Clocks.CachedNanoClock
    source_clock::Clocks.CachedNanoClock
    core::OpenCore
    transport_error::Union{Nothing,String}
    parameters_io::Dict{Tuple{UInt32,Cint},S.Parameters}
    barriers::Dict{Cint,S.Barrier}
    machine::S.Machine{Clocks.CachedNanoClock}
end
function runtime()
    clock = Clocks.CachedNanoClock(-100)
    return Runtime(
        clock,
        Clocks.CachedNanoClock(-100),
        OpenCore(),
        nothing,
        Dict{Tuple{UInt32,Cint},S.Parameters}(),
        Dict{Cint,S.Barrier}(),
        S.Machine(1; clock),
    )
end

@testset "Owned observation queue bounds and order" begin
    first = S.CoreDone(UInt32(0), Cint(1))
    second = S.CoreError(UInt32(0), Cint(2), "remote failure")
    queue = S.EventQueue(2)
    @test S.next_event!(queue) === nothing
    @test S.stage!(queue, first)
    @test S.stage!(queue, second)
    @test !S.stage!(queue, first)
    @test queue.overflow
    @test S.next_event!(queue) === first
    @test S.stage!(queue, first)
    @test S.next_event!(queue) === second
    @test S.next_event!(queue) === first
    @test queue.count == queue.bytes == 0
    @test queue.overflow

    large = S.ParamReceived(UInt32(1), Cint(1), SPA.PARAM_PROPS, Pod("x"^4096))
    queue = S.EventQueue(2; byte_limit = S.event_size(first))
    @test !S.stage!(queue, large)
    @test queue.count == queue.bytes == 0 && queue.overflow
    @test S.stage!(queue, first)
    @test queue.bytes == S.event_size(first)
    @test S.next_event!(queue) === first
    @test queue.bytes == 0
    @test_throws ArgumentError S.EventQueue(0)
    @test_throws ArgumentError S.EventQueue(1; byte_limit = 0)
end

@testset "Enumeration and core barriers require exact sequences" begin
    r = runtime()
    pending = S.Parameters(SPA.PARAM_PROPS, Pod[], 0, nothing)
    r.parameters_io[(UInt32(4), Cint(7))] = pending
    pod = Pod(Int32(5))
    S.update!(r, S.ParamReceived(UInt32(4), Cint(8), SPA.PARAM_PROPS, pod))
    @test isempty(pending.records)
    S.update!(r, S.ParamReceived(UInt32(4), Cint(7), SPA.PARAM_PROPS, pod))
    @test only(pending.records) === pod
    @test pending.bytes == sizeof(pod)
    @test !S.parameter_error!(r, UInt32(5), Cint(7), "other object")
    @test S.parameter_error!(r, UInt32(4), Cint(7), "refused")
    @test pending.error == "refused"
    S.update!(r, S.ParamReceived(UInt32(4), Cint(7), SPA.PARAM_FORMAT, pod))
    @test pending.error == "parameter enumeration identity changed"

    barrier = S.Barrier(false, nothing)
    r.barriers[Cint(9)] = barrier
    S.update!(r, S.CoreDone(UInt32(1), Cint(9)))
    S.update!(r, S.CoreDone(UInt32(0), Cint(10)))
    @test !barrier.done
    S.update!(r, S.CoreDone(UInt32(0), Cint(9)))
    @test barrier.done
    S.update!(r, S.CoreError(UInt32(0), Cint(9), "sync refused"))
    @test barrier.error == "sync refused" && r.transport_error === nothing
end

@testset "Transport sends validate fresh signed time and cancellation" begin
    r = runtime()
    ticket = something(r.machine.effect)
    job = S.Job(ticket, false)
    @test S.now(r) == -100
    @test S.check_job(r, job) === nothing
    # Advancing only the source clock proves that a cached duty-cycle timestamp
    # cannot authorize a send after the absolute request deadline.
    Clocks.update!(r.source_clock, ticket.deadline)
    @test_throws ArgumentError S.check_job(r, job)
    Clocks.update!(r.source_clock, Int64(-100))
    job.cancelled = true
    @test_throws S.Cancelled S.check_job(r, job)
    job.cancelled = false
    r.transport_error = "core disconnected"
    @test_throws ArgumentError S.check_job(r, job)
end

struct SendingProxy
    sent::Base.RefValue{Bool}
end
struct SendingRuntime{M}
    clock::Clocks.CachedNanoClock
    source_clock::Clocks.CachedNanoClock
    core::OpenCore
    transport_error::Nothing
    machine::M
    proxy::SendingProxy
end
S.find_object(runtime::SendingRuntime, ::UInt64) = (; runtime.proxy)
S.assert_identity!(runtime::SendingRuntime, ::UInt64) =
    Clocks.update!(runtime.source_clock, something(runtime.machine.effect).deadline)
PipeWireAO.set_param!(proxy::SendingProxy, ::UInt32, ::Pod) = (proxy.sent[] = true; nothing)

@testset "Expiry during identity validation prevents the native send" begin
    for send in (S.setparam!, S.queryparam!)
        clock = Clocks.CachedNanoClock(-100)
        machine = S.Machine(1; clock)
        runtime = SendingRuntime(
            clock,
            Clocks.CachedNanoClock(-100),
            OpenCore(),
            nothing,
            machine,
            SendingProxy(Ref(false)),
        )
        job = S.Job(something(machine.effect), false)
        @test_throws ArgumentError send(runtime, job, UInt64(1), "Props", Pod(nothing))
        @test Clocks.time_nanos(runtime.source_clock) == job.ticket.deadline
        @test !runtime.proxy.sent[]
    end
end
end
