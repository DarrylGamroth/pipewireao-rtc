module OwnerEntrypointTests
using Test, PipeWireAORTC
import Hsm
import Agent
import Clocks
const Bootstrap = PipeWireAORTC.OwnerBootstrapRuntime
const Parameters = PipeWireAORTC.ParameterSource

const OPTIONS = (;
    config = "/tmp/parameters.conf",
    remote = "/tmp/rtc-core",
    bootstrap_node = "parameters.bootstrap",
    bootstrap_instance = "7",
    control_node = "parameters.control",
    control_instance = "9",
)
arguments(options = OPTIONS) = reduce(
    vcat,
    (["--" * replace(string(key), "_" => "-"), value] for (key, value) in pairs(options)),
)

@testset "parameter owner arguments preserve endpoint contract" begin
    admitted = Parameters._owner_options(arguments())
    @test Dict(pairs(admitted)) == Dict(
        pairs(
            merge(OPTIONS, (; bootstrap_instance = Int64(7), control_instance = Int64(9)))
        ),
    )
    @test Parameters._owner_options([
        "--" * replace(string(key), "_" => "-") * "=" * value for
        (key, value) in pairs(OPTIONS)
    ]) == admitted
    for key in keys(OPTIONS)
        missing = (; (name => value for (name, value) in pairs(OPTIONS) if name != key)...)
        @test_throws ArgumentError Parameters._owner_options(arguments(missing))
    end
    for extra in (
        ["--unknown", "value"],
        ["--config", "/tmp/other.conf"],
        ["positional"],
        ["--control-node"],
    )
        @test_throws ArgumentError Parameters._owner_options(vcat(arguments(), extra))
    end
    for changed in (
        (; config = "relative.conf"),
        (; remote = "relative-core"),
        (; bootstrap_node = "invalid/name"),
        (; control_node = ""),
        (; control_node = repeat("n", 129)),
        (; control_node = OPTIONS.bootstrap_node),
        (; bootstrap_instance = "0"),
        (; bootstrap_instance = "-1"),
        (; bootstrap_instance = "9223372036854775808"),
        (; control_instance = "1.0"),
    )
        @test_throws ArgumentError Parameters._owner_options(
            arguments(merge(OPTIONS, changed))
        )
    end
    maximal = Parameters._owner_options(
        arguments(
            merge(
                OPTIONS,
                (;
                    bootstrap_instance = string(typemax(Int64)),
                    control_instance = string(typemax(Int64)),
                ),
            ),
        ),
    )
    @test maximal.bootstrap_instance == maximal.control_instance == typemax(Int64)
    @test_throws ArgumentError Parameters.main(["--unknown", "value"])
end

mutable struct OwnerRuntime
    events::Vector{Symbol}
    cancelled::Bool
    preparation_failure::Union{Nothing,Exception}
    finish_failure::Union{Nothing,Exception}
    close_failure::Union{Nothing,Exception}
    fault::Union{Nothing,Exception}
end
OwnerRuntime(;
    cancelled = false,
    preparation_failure = nothing,
    finish_failure = nothing,
    close_failure = nothing,
) = OwnerRuntime(
    Symbol[], cancelled, preparation_failure, finish_failure, close_failure, nothing
)
Bootstrap.cancelled(runtime::OwnerRuntime) = runtime.cancelled
function Bootstrap.preparation_check!(runtime::OwnerRuntime)
    push!(runtime.events, :check)
    runtime.preparation_failure === nothing || throw(runtime.preparation_failure)
    runtime.cancelled && throw(InterruptException())
    return nothing
end
function Bootstrap.fault!(runtime::OwnerRuntime, error::Exception)
    push!(runtime.events, :fault)
    runtime.fault = error
    return nothing
end
function Bootstrap.finish!(runtime::OwnerRuntime)
    push!(runtime.events, :finish)
    runtime.finish_failure === nothing || throw(runtime.finish_failure)
    return nothing
end
function Base.close(runtime::OwnerRuntime)
    push!(runtime.events, :close)
    runtime.close_failure === nothing || throw(runtime.close_failure)
    return nothing
end
caught(f) =
    try
        f()
        nothing
    catch error
        error
    end

@testset "cold owner options and deterministic cleanup" begin
    runtime = OwnerRuntime()
    options = merge(OPTIONS, (; bootstrap_instance = Int64(7)))
    result = Bootstrap._with_owner(options, runtime) do admitted
        push!(runtime.events, :cold)
        @test admitted.bootstrap_runtime === runtime
        @test all(getproperty(admitted, name) == value for (name, value) in pairs(options))
        admitted.owner_check()
        return :ignored_owner_result
    end
    @test result === nothing
    @test runtime.events == [:cold, :check, :finish, :close]
    @test runtime.fault === nothing

    primary, finishing, closing = ErrorException.([
        "preparation failed", "finish failed", "close failed"
    ])
    runtime = OwnerRuntime(; finish_failure = finishing, close_failure = closing)
    failure = caught() do
        Bootstrap._with_owner(options, runtime) do admitted
            push!(runtime.events, :cold)
            throw(primary)
        end
    end
    @test failure isa CompositeException
    @test failure.exceptions == [primary, finishing, closing]
    @test runtime.fault === primary
    @test runtime.events == [:cold, :fault, :finish, :close]

    runtime = OwnerRuntime(; preparation_failure = primary)
    failure = caught(
        () -> Bootstrap._with_owner(admitted -> admitted.owner_check(), options, runtime)
    )
    @test failure === primary
    @test runtime.fault === primary
    @test runtime.events == [:check, :fault, :finish, :close]

    runtime = OwnerRuntime(; finish_failure = finishing, close_failure = closing)
    failure = caught(() -> Bootstrap._with_owner(_ -> nothing, options, runtime))
    @test failure isa CompositeException
    @test failure.exceptions == [finishing, closing]
    @test runtime.events == [:finish, :close]
    @test runtime.fault === nothing
end

@testset "cooperative cancellation preserves cleanup failures" begin
    options = merge(OPTIONS, (; bootstrap_instance = Int64(7)))
    runtime = OwnerRuntime(; cancelled = true)
    @test Bootstrap._with_owner(admitted -> admitted.owner_check(), options, runtime) ===
        nothing
    @test runtime.fault === nothing
    @test runtime.events == [:check, :finish, :close]

    interrupt = InterruptException()
    runtime = OwnerRuntime()
    failure = caught(() -> Bootstrap._with_owner(_ -> throw(interrupt), options, runtime))
    @test failure === interrupt
    @test runtime.fault === interrupt
    @test runtime.events == [:fault, :finish, :close]

    closing = ErrorException("close failed after cancellation")
    runtime = OwnerRuntime(; cancelled = true, close_failure = closing)
    failure = caught(
        () -> Bootstrap._with_owner(admitted -> admitted.owner_check(), options, runtime)
    )
    @test failure === closing
    @test runtime.fault === nothing
    @test runtime.events == [:check, :finish, :close]
end

# No native core or science: mailbox acceptance, reply/exclusion, immutable
# observations, and the Agent duty clock are tested at the transport boundary.
mutable struct MonitorTransport
    publications::Vector{PipeWireAORTC.OwnerBootstrapCodec.Lifecycle}
    flushes::Vector{Int64}
    failure::Union{Nothing,Exception}
end
Bootstrap.lifecycle!(transport::MonitorTransport, lifecycle) =
    (push!(transport.publications, lifecycle); nothing)
Bootstrap.flush_terminal!(transport::MonitorTransport, deadline; check = () -> nothing) =
    (push!(transport.flushes, deadline); nothing)
function Bootstrap._poll_ready!(transport::MonitorTransport)
    transport.failure === nothing || throw(transport.failure)
    return false
end
Bootstrap.poll!(::MonitorTransport) = nothing
Bootstrap.take!(::MonitorTransport) = nothing
mutable struct CountingNanoClock <: Clocks.AbstractNanoClock
    at::Int64
    reads::Int
end
Clocks.time_nanos(clock::CountingNanoClock) = (clock.reads += 1; clock.at)
function monitor_runtime(; clock = Clocks.CachedNanoClock(10_000_000_000))
    runtime = Bootstrap.Runtime(
        MonitorTransport(PipeWireAORTC.OwnerBootstrapCodec.Lifecycle[], Int64[], nothing)
    )
    monitor = Bootstrap.Monitor(runtime; clock)
    invoker = Agent.AgentInvoker(monitor)
    Agent.start(invoker)
    return runtime, monitor, invoker
end
function bootstrap_ticket(operation)
    envelope = PipeWireAORTC.ControlCodec
    codec = PipeWireAORTC.OwnerBootstrapCodec
    controller = envelope.ControllerIdentity(UInt32(7), UInt64(8), Int64(9))
    command = codec.Command(operation)
    header = envelope.RequestHeader(
        controller,
        Int64(1),
        Int64(1),
        PipeWireAORTC.ControlClient.operation_id(codec.PROFILE, command),
        Int64(1_000_000_000),
    )
    PipeWireAORTC.ControlEndpoint.Ticket{Bootstrap.Commands}(
        header, command, UInt8[], typemax(Int64)
    )
end
function owner_message(f, monitor)
    task = @async f()
    yield()
    Bootstrap._drain_owner!(monitor)
    @test timedwait(() -> istaskdone(task), 1; pollint = 0.001) === :ok
    return fetch(task)
end
reply() = Channel{Bootstrap.OwnerReply}(1)
status_read_allocations(runtime) = (
    (@allocated Bootstrap.preparation_check!(runtime)),
    (@allocated Bootstrap.cancelled(runtime)),
)

@testset "bootstrap Active Object facts and hierarchy" begin
    codec = PipeWireAORTC.OwnerBootstrapCodec
    runtime, monitor, invoker = monitor_runtime()
    @test Hsm.current(monitor) === :Preparing
    task = @async Bootstrap.prepared!(runtime)
    yield()
    @test Hsm.current(monitor) === :Preparing
    @test !Bootstrap._status(runtime).prepared
    @test isempty(runtime.transport.publications)
    @test Agent.invoke_unchecked(invoker) == 1
    @test fetch(task) === nothing
    @test Hsm.current(monitor) === :Prepared
    Agent.invoke_unchecked(invoker)
    @test runtime.transport.publications == [codec.Prepared]
    @test Bootstrap._status(runtime).prepared
    Bootstrap.preparation_check!(runtime)
    Bootstrap.cancelled(runtime)
    status_read_allocations(runtime)
    @test status_read_allocations(runtime) == (0, 0)

    ticket = bootstrap_ticket(:connect)
    Hsm.dispatch!(monitor, :ConnectRequested, ticket)
    @test Hsm.current(monitor) === :ConnectPending
    @test runtime.connect_ticket === ticket === monitor.active
    first, later = ErrorException("first owner failure"), ErrorException("later failure")
    owner_message(() -> Bootstrap.fault!(runtime, first), monitor)
    owner_message(() -> Bootstrap.fault!(runtime, later), monitor)
    @test Hsm.current(monitor) === :ConnectPending
    Hsm.dispatch!(monitor, :OwnerObserved, Bootstrap._facts(monitor))
    @test Hsm.current(monitor) === :FaultConnectPending
    @test runtime.main_error === first
    @test monitor.active === ticket
    @test runtime.transport.publications == [codec.Prepared, codec.Fault]
    close(invoker)

    runtime, monitor, invoker = monitor_runtime()
    # Inject an achieved Connected boundary without a native core; owner-fault
    # delivery must immediately invalidate its immutable completion observation.
    Hsm.transition!(monitor, :Connected)
    Bootstrap._publish!(monitor, codec.Connected)
    @test Bootstrap._status(runtime).connected
    owner_message(() -> Bootstrap.fault!(runtime, first), monitor)
    @test !Bootstrap._status(runtime).connected
    Hsm.dispatch!(monitor, :OwnerObserved, Bootstrap._facts(monitor))
    @test Hsm.current(monitor) === :Fault
    @test !Bootstrap._status(runtime).connected
    close(invoker)
end

@testset "bootstrap bounded mailboxes and cleanup reservation" begin
    runtime, monitor, invoker = monitor_runtime()
    # Several owner tasks share thread 1. Check+enqueue must remain atomic, with
    # a full ordinary mailbox rejected before acceptance rather than blocked.
    tasks = [
        @async caught(() -> Bootstrap.prepared!(runtime)) for
        _ in 1:(Bootstrap.MAILBOX_CAPACITY+1)
    ]
    yield()
    @test Base.n_avail(runtime.mailbox.owner) == Bootstrap.MAILBOX_CAPACITY
    @test count(istaskdone, tasks) == 1
    failure = only(fetch(task) for task in tasks if istaskdone(task))
    @test failure isa InvalidStateException && failure.state === :full
    exclusion = Bootstrap.HooksExcluded(reply())
    Bootstrap._enqueue!(runtime.mailbox, exclusion; cleanup = true)
    @test Bootstrap._drain_owner!(monitor) == Bootstrap.MAILBOX_CAPACITY + 1
    @test take!(exclusion.reply).error === nothing
    @test Bootstrap._status(runtime).hooks_excluded
    @test all(task -> timedwait(() -> istaskdone(task), 1; pollint = 0.001) === :ok, tasks)
    @test all(task -> fetch(task) isa InvalidStateException, tasks)
    close(invoker)
    @test_throws InvalidStateException Bootstrap._enqueue!(
        runtime.mailbox, Bootstrap.OwnerPrepared(reply())
    )

    runtime, monitor, invoker = monitor_runtime()
    for _ in 1:Bootstrap.MAILBOX_CAPACITY
        Bootstrap._enqueue!(
            runtime.mailbox, Bootstrap.HooksExcluded(reply()); cleanup = true
        )
    end
    waiting = @async caught(() -> Bootstrap.cancel!(runtime))
    yield()
    @test !istaskdone(waiting)
    @test Base.n_avail(runtime.mailbox.cleanup) == Bootstrap.MAILBOX_CAPACITY
    close(invoker)
    @test timedwait(() -> istaskdone(waiting), 1; pollint = 0.001) === :ok
    @test fetch(waiting) === nothing
    @test Bootstrap._status(runtime).done
end

@testset "bootstrap exclusion ACK fences queued and future capabilities" begin
    runtime, monitor, invoker = monitor_runtime()
    ticket = bootstrap_ticket(:connect)
    hooks = Bootstrap.Hooks(() -> false, () -> nothing)
    registration = Bootstrap.ConnectionRegistered(reply(), ticket, hooks)
    exclusion = Bootstrap.HooksExcluded(reply())
    Bootstrap._enqueue!(runtime.mailbox, registration)
    Bootstrap._enqueue!(runtime.mailbox, exclusion; cleanup = true)
    @test Bootstrap._drain_owner!(monitor) == 2
    @test take!(exclusion.reply).error === nothing
    @test take!(registration.reply).error isa InvalidStateException
    @test monitor.hooks === nothing
    @test Bootstrap._status(runtime).hooks_excluded
    late = Bootstrap.ConnectionRegistered(reply(), ticket, hooks)
    Bootstrap._enqueue!(runtime.mailbox, late)
    Bootstrap._drain_owner!(monitor)
    @test take!(late.reply).error isa InvalidStateException
    @test monitor.hooks === nothing
    close(invoker)

    runtime, monitor, invoker = monitor_runtime()
    calls = Ref(0)
    # Hooks are owned by this direct test monitor, never by the Runtime proxy.
    monitor.hooks = Bootstrap.Hooks(() -> false, () -> (calls[] += 1; nothing))
    owner_message(() -> Bootstrap.cancel!(runtime), monitor)
    @test Bootstrap.cancelled(runtime)
    @test calls[] == 1
    @test_throws InterruptException Bootstrap.preparation_check!(runtime)
    Hsm.dispatch!(monitor, :CancellationObserved)
    @test calls[] == 2
    owner_message(() -> Bootstrap.finishing!(runtime), monitor)
    @test Bootstrap._status(runtime).hooks_excluded
    Hsm.dispatch!(monitor, :CancellationObserved)
    @test calls[] == 2
    close(invoker)
end

@testset "bootstrap monitor close/failure releases accepted owner calls" begin
    runtime, monitor, invoker = monitor_runtime()
    task = @async caught(() -> Bootstrap.prepared!(runtime))
    yield()
    @test !istaskdone(task)
    first = ErrorException("monitor failure before owner reply")
    Hsm.dispatch!(monitor, :MonitorFailed, first)
    close(invoker)
    @test timedwait(() -> istaskdone(task), 1; pollint = 0.001) === :ok
    @test fetch(task) === first
    @test runtime.failure === first
    @test Bootstrap._status(runtime).hooks_excluded
    @test Bootstrap.finishing!(runtime) === nothing
    @test_throws first Bootstrap.finish!(runtime)

    runtime, monitor, invoker = monitor_runtime()
    task = @async caught(() -> Bootstrap.prepared!(runtime))
    yield()
    close(invoker)
    @test timedwait(() -> istaskdone(task), 1; pollint = 0.001) === :ok
    @test fetch(task) isa InvalidStateException
    @test Bootstrap.fault!(runtime, first) === nothing
    @test Bootstrap.finishing!(runtime) === nothing
end

@testset "bootstrap samples its source clock once per duty cycle" begin
    source = CountingNanoClock(10_000_000_000, 0)
    runtime, monitor, invoker = monitor_runtime(; clock = source)
    @test source.reads == 0
    task = @async Bootstrap.prepared!(runtime)
    yield()
    Agent.invoke_unchecked(invoker)
    @test fetch(task) === nothing
    @test source.reads == 1
    @test Bootstrap._now(monitor) == 10_000_000_000
    @test Bootstrap._now(monitor) == 10_000_000_000
    @test source.reads == 1
    Agent.invoke_unchecked(invoker)
    @test source.reads == 2
    first = ErrorException("native observation failed")
    runtime.transport.failure = first
    failure = caught(() -> Agent.invoke_unchecked(invoker))
    @test failure === first
    @test source.reads == 3
    Hsm.dispatch!(monitor, :MonitorFailed, failure)
    @test source.reads == 3
    @test monitor.cleanup_deadline == 15_000_000_000
    source.at = 14_999_999_999
    Agent.invoke_unchecked(invoker)
    @test Hsm.current(monitor) === :Cleanup
    @test source.reads == 4
    source.at = 15_000_000_000
    Agent.invoke_unchecked(invoker)
    @test Hsm.iscomplete(monitor)
    @test source.reads == 5
    @test runtime.transport.flushes == [15_000_000_000]
    close(invoker)

    source = Clocks.CachedNanoClock(20_000_000_000)
    runtime, monitor, invoker = monitor_runtime(; clock = source)
    Agent.invoke_unchecked(invoker)
    @test Bootstrap._now(monitor) == 20_000_000_000
    Clocks.advance!(source, 1_000_000_000)
    Agent.invoke_unchecked(invoker)
    @test Bootstrap._now(monitor) == 21_000_000_000
    close(invoker)
end
@testset "bootstrap signed cleanup budgets and source regression" begin
    for origin in (typemin(Int64), -Int64(2)^60, Int64(2)^53 + 1)
        source = CountingNanoClock(origin, 0)
        runtime, monitor, invoker = monitor_runtime(; clock = source)
        Agent.invoke_unchecked(invoker)
        @test Bootstrap._now(monitor) == origin && source.reads == 1
        failure = ErrorException("observed transport failure")
        Hsm.dispatch!(monitor, :MonitorFailed, failure)
        @test monitor.cleanup_deadline == origin + 5_000_000_000
        @test source.reads == 1
        source.at = monitor.cleanup_deadline - 1
        Agent.invoke_unchecked(invoker)
        @test Hsm.current(monitor) === :Cleanup
        source.at += 1
        Agent.invoke_unchecked(invoker)
        @test Hsm.iscomplete(monitor)
        @test runtime.transport.flushes == [source.at] && source.reads == 3
        close(invoker)
    end
    source = CountingNanoClock(-10, 0)
    runtime, monitor, invoker = monitor_runtime(; clock = source)
    @test monitor.source_clock === source && monitor.clock !== source
    Agent.invoke_unchecked(invoker)
    source.at -= 1
    @test_throws PipeWireAORTC.ControlClient.UnknownOutcome Agent.invoke_unchecked(invoker)
    @test source.reads == 2 && Bootstrap._now(monitor) == -10
    @test monitor.last_at == -10
    close(invoker)

    source = CountingNanoClock(typemax(Int64) - 4_999_999_999, 0)
    runtime, monitor, invoker = monitor_runtime(; clock = source)
    Agent.invoke_unchecked(invoker)
    Hsm.dispatch!(monitor, :MonitorFailed, ErrorException("transport failure"))
    @test Hsm.iscomplete(monitor) && isempty(runtime.transport.flushes)
    @test length(monitor.failure.exceptions) == 2
    @test typeof(monitor.failure.exceptions[2]) === OverflowError
    @test source.reads == 1
    close(invoker)
    runtime, monitor, invoker = monitor_runtime()
    @test typeof(monitor.source_clock) === Clocks.CachedNanoClock
    @test monitor.source_clock !== monitor.clock
    close(invoker)
    runtime = Bootstrap.Runtime(
        MonitorTransport(PipeWireAORTC.OwnerBootstrapCodec.Lifecycle[], Int64[], nothing)
    )
    monitor = Bootstrap.Monitor(runtime)
    @test typeof(monitor.source_clock) === Clocks.SystemNanoClock
    @test typeof(monitor.clock) === Clocks.CachedNanoClock
end

end
