module MediaSessionTests
using Test, PipeWireAORTC
import Hsm, Clocks
const S = PipeWireAORTC.MediaSession
const LAUNCHER = S.Identity(11, 12, 13, 14)
const SECOND = Int64(1_000_000_000)
const R = PipeWireAORTC.RunnerCodec
zero_clock() = Clocks.CachedNanoClock(Int64(0))

function acknowledge!(m, result = nothing; submitted = true)
    ticket = something(m.effect)
    submitted && S.submitted!(m, ticket)
    S.complete!(m, ticket, result)
    return ticket
end
function sequence!(m, types)
    tickets = S.EffectTicket[]
    for type in types
        @test m.effect !== nothing
        @test typeof(m.effect.effect) <: type
        push!(tickets, acknowledge!(m))
    end
    return tickets
end
const PREPARATION = (
    S.CaptureOwners,
    S.ConnectOwners,
    S.CaptureParameters,
    S.CaptureSources,
    S.PrepareSources,
    S.DiscoverGraphs,
    S.HoldSources,
    S.ConnectLinks,
    S.HoldGraphs,
)
const SHUTDOWN = (
    S.HoldSources,
    S.HoldGraphs,
    S.ShutdownGraphOwners,
    S.WithdrawLinks,
    S.ShutdownSources,
    S.ShutdownOwners,
    S.RemoveControls,
    S.PublishQuit,
)
function ready(; clock = zero_clock(), source_end_supported = true)
    m = S.Machine(101; clock, source_end_supported)
    sequence!(m, PREPARATION)
    S.submit!(m, S.Request(S.InspectWarmup(); controller = LAUNCHER))
    S.take_replies!(m)
    S.submit!(m, S.Request(S.Admit(); controller = LAUNCHER))
    S.take_replies!(m)
    @test Hsm.current(m) === :Ready
    return m
end
function running(; kwargs...)
    m = ready(; kwargs...)
    S.submit!(m, S.Request(S.Start(); token = 1))
    sequence!(m, (S.RunGraphs, S.RunSources))
    S.take_replies!(m)
    @test Hsm.current(m) === :Running
    return m
end

@testset "ordinary Stop drains while a required loss revokes admission" begin
    m = running()
    S.submit!(m, S.Request(S.Stop(); token=10))
    @test m.effect.effect isa S.HoldSources && !m.effect.effect.revoke
    S.required_lost!(m, "Required Link removed")
    @test m.effect.effect isa S.HoldSources && m.effect.effect.revoke
    m = running()
    S.submit!(m, S.Request(S.Stop(); token=10))
    S.fail!(m, m.effect, "uncorrelated acknowledgement"; submitted=true)
    @test m.effect.effect isa S.HoldSources && !m.effect.effect.revoke
end

@testset "Warmup retains Configuring until exact launcher admission" begin
    m = S.Machine(101; clock = zero_clock())
    @test m.lifecycle == R.Configuring && !m.warmed
    startup, deadline = m.effect, m.deadline
    S.observe!(
        m,
        S.Observation(("science"=>false,), (; cohort = 0, observed_at = Int64(0))),
    )
    S.submit!(m, S.Request(S.Status(); token = 1))
    @test only(S.take_replies!(m)).details.cohort == 0
    @test m.effect === startup && m.deadline == deadline
    S.submit!(m, S.Request(S.InspectWarmup(); controller = LAUNCHER))
    @test only(S.take_replies!(m)).details === false
    @test m.effect === startup && m.deadline == deadline
    S.submit!(m, S.Request(S.Admit(); controller = LAUNCHER))
    @test only(S.take_replies!(m)).outcome === :Failed
    sequence!(m, PREPARATION)
    @test Hsm.current(m) === :AwaitingAdmission
    @test m.effect === nothing && m.warmed && m.lifecycle == R.Configuring
    S.submit!(m, S.Request(S.Admit(); controller = S.Identity(11, 12, 13, 15)))
    @test only(S.take_replies!(m)).outcome === :Failed
    @test m.lifecycle == R.Configuring
    S.submit!(m, S.Request(S.Admit(); controller = LAUNCHER))
    reply = only(S.take_replies!(m))
    @test reply.outcome === :Warmup && reply.lifecycle == R.Ready
    @test Hsm.current(m) === :Ready
end

@testset "Connect failure prevents admission and retains the failure" begin
    m = S.Machine(101; clock = zero_clock())
    sequence!(m, (S.CaptureOwners,))
    ticket = m.effect
    @test ticket.effect isa S.ConnectOwners
    S.submitted!(m, ticket)
    S.fail!(m, ticket, "first owner rejected Connect")
    @test m.lifecycle === R.Fault
    @test m.failure == "first owner rejected Connect"
    @test !m.warmed
    S.complete!(m, ticket)
    S.submit!(m, S.Request(S.Admit(); controller = LAUNCHER))
    @test only(S.take_replies!(m)).outcome === :Failed
    @test m.lifecycle === R.Fault
end

@testset "Lifecycle effect order, source-end proof and unchanged wire IDs" begin
    m = ready()
    S.submit!(m, S.Request(S.Start(); token = 2))
    @test m.lifecycle == R.Ready
    first = sequence!(m, (S.RunGraphs,)) |> only
    @test first.effect.group === nothing && first.effect.running
    @test m.lifecycle == R.Ready
    sequence!(m, (S.RunSources,))
    @test m.lifecycle == R.Running
    @test only(S.take_replies!(m)).outcome === :Lifecycle
    S.submit!(m, S.Request(S.SourceEnded(); token = 3))
    @test m.effect.effect === S.QuerySourceEnd()
    acknowledge!(m, S.SourceEnd(true, false); submitted = false)
    sequence!(m, (S.HoldSources,))
    @test m.lifecycle == R.Ready
    sequence!(m, (S.HoldGraphs,))
    @test m.effect === nothing && Hsm.current(m) === :Ready
    S.take_replies!(m)
    S.submit!(m, S.Request(S.Reset(); token = 4))
    sequence!(m, (S.HoldSources, S.HoldGraphs, S.ResetSources, S.ResetGraphs))
    @test m.lifecycle == R.Ready && m.effect === nothing
    @test only(S.take_replies!(m)).outcome === :Lifecycle
    S.submit!(m, S.Request(S.Quit(); token = 5))
    sequence!(m, SHUTDOWN)
    @test m.lifecycle == R.Offline && Hsm.current(m) === :Offline && m.effect === nothing
    @test only(S.take_replies!(m)).outcome === :Quit

    m = running()
    S.submit!(m, S.Request(S.SourceEnded()))
    acknowledge!(m, S.SourceEnd(false, false); submitted = false)
    @test m.lifecycle == R.Fault && m.effect.effect === S.HoldSources()
    @test m.failure == "Source end is not confirmed"
end

@testset "External stream End leaves the admitted session available" begin
    for machine in (ready, running)
        m = machine(; source_end_supported = false)
        lifecycle = m.lifecycle
        S.submit!(m, S.Request(S.SourceEnded(); token = 2))
        result = only(S.take_replies!(m))
        @test result.outcome === :Failed && !result.unknown
        @test result.lifecycle === lifecycle
        @test m.failure === nothing && m.effect === nothing
    end
end

@testset "All public command effects and state-dependent admission" begin
    m = ready()
    for (operation, effect) in (
        (S.GROUPS_OPERATION, S.QueryGroups),
        (S.STATUS_OPERATION, S.QueryStatus),
        (S.PROPERTIES_OPERATION, S.QueryProperties),
        (S.PROPERTY_GENERATION_OPERATION, S.QueryPropertyGeneration),
        (S.PARAMETER_GENERATION_OPERATION, S.QueryParameterGeneration),
        (S.PROPERTIES_SET_OPERATION, S.UpdateProperties),
        (S.PARAMETER_OPERATION, S.SubmitParameter),
    )
        payload = ("science", operation)
        S.submit!(m, S.Request(operation; token = operation, payload))
        @test typeof(m.effect.effect) <: effect
        acknowledge!(
            m,
            (; observed = operation);
            submitted = operation>=S.PROPERTIES_SET_OPERATION,
        )
        reply = only(S.take_replies!(m))
        @test reply.details.observed == operation && reply.lifecycle == R.Ready
        @test Hsm.current(m) === :Ready
    end
    S.submit!(m, S.Request(S.StopGroup(); payload = "science"))
    @test only(S.take_replies!(m)).outcome === :Failed && m.effect === nothing
    S.submit!(m, S.Request(S.Start()))
    sequence!(m, (S.RunGraphs, S.RunSources))
    S.take_replies!(m)
    for (operation, running) in
        ((S.STOP_GROUP_OPERATION, false), (S.START_GROUP_OPERATION, true))
        S.submit!(m, S.Request(operation; payload = "science"))
        @test m.effect.effect == S.RunGraphs("science", running)
        acknowledge!(m, (; group = "science", running))
        @test only(S.take_replies!(m)).outcome === :Group
        @test m.lifecycle == R.Running
    end
    S.submit!(m, S.Request(S.Reset()))
    @test only(S.take_replies!(m)).outcome === :Failed
    S.submit!(m, S.Request(S.Start()))
    @test only(S.take_replies!(m)).outcome === :Failed
    S.submit!(m, S.Request(S.Stop()))
    sequence!(m, (S.HoldSources, S.HoldGraphs))
    @test m.lifecycle == R.Ready
end

@testset "Single effect slot, exact correlation and stale completion fencing" begin
    m = ready()
    S.submit!(m, S.Request(S.Start(); token = 1))
    original = something(m.effect)
    S.submit!(m, S.Request(S.Stop(); token = 2))
    @test m.effect === original
    @test only(S.take_replies!(m)).outcome === :Failed
    for changed in (
        S.EffectTicket(
            original.session+1,
            original.epoch,
            original.serial,
            original.operation,
            original.origin,
            original.deadline,
            original.effect,
            original.target,
        ),
        S.EffectTicket(
            original.session,
            original.epoch+1,
            original.serial,
            original.operation,
            original.origin,
            original.deadline,
            original.effect,
            original.target,
        ),
        S.EffectTicket(
            original.session,
            original.epoch,
            original.serial+1,
            original.operation,
            original.origin,
            original.deadline,
            original.effect,
            original.target,
        ),
        S.EffectTicket(
            original.session,
            original.epoch,
            original.serial,
            original.operation+UInt32(1),
            original.origin,
            original.deadline,
            original.effect,
            original.target,
        ),
    )
        S.complete!(m, changed)
        @test m.effect === original
    end
    acknowledge!(m)
    next = m.effect
    S.complete!(m, original)
    S.fail!(m, original, "late failure")
    @test m.effect === next && m.failure === nothing
    S.submitted!(m, next)
    S.submit!(m, S.Request(S.Quit(); token = 3))
    @test S.take_cancelled!(m) === next
    @test S.take_cancelled!(m) === nothing
    cancelled_reply = only(S.take_replies!(m))
    @test cancelled_reply.token == 1 && cancelled_reply.unknown
    @test m.effect.effect === S.HoldSources() && m.effect.epoch > original.epoch
    replacement = m.effect
    S.complete!(m, next)
    @test m.effect === replacement
    sequence!(m, SHUTDOWN)
    @test only(S.take_replies!(m)).token == 3
end

@testset "Absolute deadlines distinguish no-effect refusal and unknown submission" begin
    clock = Clocks.CachedNanoClock(2_000_000_000)
    m = ready(; clock)
    S.submit!(
        m,
        S.Request(
            S.SetProperties();
            token = 1,
            deadline = 6 * SECOND,
            payload = ("science",),
        ),
    )
    ticket = m.effect
    @test ticket.deadline == 6 * SECOND
    Clocks.update!(clock, 5_999_999_999)
    S.tick!(m)
    @test m.effect === ticket
    Clocks.advance!(clock, 1)
    S.tick!(m)
    @test Hsm.current(m) === :Ready && m.failure === nothing
    @test !only(S.take_replies!(m)).unknown
    @test S.take_cancelled!(m) === ticket
    S.submit!(m, S.Request(S.SetParameter(); token = 2, payload = ("science",)))
    @test m.effect.deadline == 11 * SECOND
    S.submitted!(m, m.effect)
    Clocks.update!(clock, 11_000_000_000)
    S.tick!(m)
    @test m.lifecycle == R.Fault && m.deadline == 16 * SECOND
    @test S.take_cancelled!(m) !== nothing
    @test isempty(S.take_replies!(m))
    sequence!(m, (S.HoldSources, S.HoldGraphs, S.WithdrawLinks))
    @test only(S.take_replies!(m)).unknown
    @test Hsm.current(m) === :HeldFault

    m = ready(; clock = zero_clock())
    S.submit!(m, S.Request(S.Properties(); deadline = 2 * SECOND, payload = "science"))
    S.complete!(m, m.effect; at = 2 * SECOND)
    @test Hsm.current(m) === :Ready && m.failure === nothing
    @test only(S.take_replies!(m)).outcome === :Failed
end

@testset "First fault, source-first compensation and explicit Quit recovery" begin
    m = running()
    S.submit!(m, S.Request(S.SetProperties(); token = 8, payload = "science"))
    S.submitted!(m, m.effect)
    before = m.effect
    S.required_lost!(m, "required sink lost")
    @test m.failure == "required sink lost" && m.lifecycle == R.Fault
    @test S.take_cancelled!(m) === before
    hold, deadline = m.effect, m.deadline
    S.required_lost!(m, "second loss")
    @test m.effect === hold && m.deadline == deadline && m.failure == "required sink lost"
    @test isempty(S.take_replies!(m))
    sequence!(m, (S.HoldSources,))
    S.fail!(m, m.effect, "graph hold failed"; submitted = true)
    @test m.effect.effect === S.WithdrawLinks()
    acknowledge!(m)
    @test Hsm.current(m) === :HeldFault && m.lifecycle == R.Fault
    @test only(S.take_replies!(m)).unknown
    @test m.cleanup_failure == "graph hold failed"
    S.submit!(m, S.Request(S.Quit(); token = 9))
    sequence!(m, SHUTDOWN)
    @test m.lifecycle == R.Offline && only(S.take_replies!(m)).outcome === :Quit

    m = running()
    S.required_lost!(m, "source disappeared")
    S.take_cancelled!(m)
    S.fail!(m, m.effect, "source Hold unknown"; submitted = true)
    @test Hsm.current(m) === :EmergencyDisconnect
    @test m.effect.effect === S.Disconnect()
    acknowledge!(m)
    @test m.lifecycle == R.Fault && m.effect === nothing

    m = S.Machine(101; clock = zero_clock())
    startup = m.effect
    S.submit!(m, S.Request(S.Quit(); token = 10))
    @test S.take_cancelled!(m) === startup
    sequence!(m, SHUTDOWN)
    @test m.lifecycle == R.Offline && only(S.take_replies!(m)).token == 10
end

@testset "Pre-effect validation does not fault and outboxes are bounded" begin
    m = running()
    S.submit!(m, S.Request(S.StopGroup(); token = 11, payload = "undeclared"))
    S.fail!(m, m.effect, "undeclared execution group"; submitted = false)
    @test m.lifecycle == R.Running && m.failure === nothing && m.effect === nothing
    @test !only(S.take_replies!(m)).unknown
    m = S.Machine(101; clock = zero_clock())
    ticket = m.effect
    S.submit!(m, S.Request(S.Start()))
    S.submit!(m, S.Request(S.Reset()))
    @test length(m.replies) == 2
    @test_throws ArgumentError S.submit!(m, S.Request(S.SetParameter()))
    @test m.effect === ticket && length(m.replies) == 2
    @test_throws ArgumentError S.Request(17)
    @test_throws ArgumentError S.Machine(0)
end

@testset "Emergency disconnect outlives the expired source-Hold budget" begin
    clock = Clocks.CachedNanoClock(0)
    m = running(; clock)
    S.required_lost!(m, "required source lost")
    held, deadline = m.effect, m.deadline
    Clocks.update!(clock, deadline)
    S.tick!(m)
    @test S.take_cancelled!(m) === held
    disconnect = m.effect
    @test disconnect.effect === S.Disconnect()
    @test !S.budgeted(disconnect.effect) && disconnect.deadline == typemax(Int64)
    @test Hsm.current(m) === :EmergencyDisconnect
    for _ = 1:3
        Clocks.advance!(clock, 5_000_000_000)
        S.tick!(m)
        S.required_lost!(m, "late required loss")
        S.complete!(m, held)
        S.fail!(m, held, "late source failure")
        @test m.effect === disconnect
        @test S.take_cancelled!(m) === nothing
    end
    S.complete!(m, disconnect)
    @test m.effect === nothing && Hsm.current(m) === :HeldFault
    S.complete!(m, disconnect)
    S.tick!(m)
    @test m.effect === nothing && m.failure == "required source lost"
end

@testset "Local Quit disconnects after an unsubmitted Hold expires" begin
    for cleanup in (:complete, :fail, :expire)
        clock = zero_clock()
        m = S.Machine(101; clock)
        S.submit!(m, S.Request(S.InspectWarmup(); controller = LAUNCHER))
        S.take_replies!(m)
        Hsm.dispatch!(
            m, :AdmissionControllerRemoved, (; id = LAUNCHER.global_id, LAUNCHER.serial)
        )
        S.take_cancelled!(m)
        first_hold = m.effect
        @test first_hold.effect === S.HoldSources()
        Clocks.update!(clock, m.deadline)
        S.tick!(m)
        @test S.take_cancelled!(m) === first_hold
        @test m.quit_failure.ticket === first_hold && !m.quit_failure.submitted
        sequence!(m, (S.HoldSources, S.HoldGraphs))
        @test m.effect.effect === S.WithdrawLinks()
        if cleanup === :complete
            acknowledge!(m)
        elseif cleanup === :fail
            S.fail!(m, m.effect, "Link withdrawal failed")
        else
            Clocks.update!(clock, m.deadline)
            S.tick!(m)
            S.take_cancelled!(m)
        end
        @test Hsm.current(m) === :EmergencyDisconnect
        @test m.effect !== nothing && m.effect.effect === S.Disconnect()
        if m.effect !== nothing
            acknowledge!(m)
            @test only(S.take_replies!(m)).outcome === :Failed
        end
    end
end

@testset "Quit budget starts at admission and respects the client's deadline" begin
    for client_deadline in (9SECOND, 5SECOND + SECOND ÷ 2)
        clock = zero_clock()
        m = running(; clock)
        request = S.Request(S.Quit(); token = 2, deadline = client_deadline)
        admitted_at = SECOND
        expected = min(client_deadline, admitted_at + S.SESSION_EFFECT_TIMEOUT_NS)
        S.submit!(m, request, admitted_at)
        @test Clocks.time_nanos(clock) == 0
        @test m.deadline == expected
        Clocks.update!(clock, 5SECOND + 1)
        tickets = sequence!(m, SHUTDOWN)
        @test all(ticket -> ticket.deadline == expected, tickets)
        @test only(S.take_replies!(m)).outcome === :Quit
        @test Hsm.current(m) === :Offline
    end
end

@testset "Accepted Quit precedes publication fence and survives fence failure" begin
    for disposition in (:complete, :fail, :expire)
        clock = Clocks.CachedNanoClock(0)
        m = S.Machine(101; clock)
        S.submit!(m, S.Request(S.Quit(); token = 23))
        S.take_cancelled!(m)
        sequence!(m, SHUTDOWN[1:(end-1)])
        @test m.lifecycle == R.Offline && Hsm.current(m) === :PublishingQuit
        reply = only(S.take_replies!(m))
        @test reply.outcome === :Quit && reply.details === true && !reply.unknown
        fence = m.effect
        @test fence.effect === S.PublishQuit() && fence.operation == S.QUIT_OPERATION
        S.submit!(m, S.Request(S.Quit(); token = 23))
        @test only(S.take_replies!(m)).outcome === :Failed
        @test m.effect === fence
        S.required_lost!(m, "expected owner disappearance")
        @test m.effect === fence && m.lifecycle == R.Offline
        S.observe!(m, S.Observation(nothing, (; closed = true)))
        S.submit!(m, S.Request(S.Status()))
        @test only(S.take_replies!(m)).lifecycle == R.Offline
        @test m.effect === fence
        if disposition === :complete
            S.complete!(m, fence)
        elseif disposition === :fail
            S.fail!(m, fence, "publication unavailable"; submitted = false)
        else
            Clocks.update!(clock, 5_000_000_000)
            S.tick!(m)
            @test S.take_cancelled!(m) === fence
        end
        @test m.lifecycle == R.Offline &&
              Hsm.current(m) === :Offline &&
              m.effect === nothing
        @test isempty(S.take_replies!(m)) && m.failure === nothing
        if disposition === :complete
            @test m.quit_failure === nothing
        else
            @test m.quit_failure.ticket === fence
            @test m.quit_failure.reason == m.cleanup_failure
            @test !m.quit_failure.submitted
        end
        S.complete!(m, fence)
        S.fail!(m, fence, "late publication failure")
        @test m.lifecycle == R.Offline && isempty(S.take_replies!(m))
    end
end

@testset "Signed nanosecond clocks and named protocol interfaces" begin
    clock = Clocks.CachedNanoClock(Int64(-2_000_000_000))
    m = S.Machine(101; clock)
    @test m.clock === clock
    @test m.deadline === Int64(298_000_000_000)
    @test m.lifecycle === R.Configuring
    @test m.effect.deadline === m.deadline
    @test S.AbstractOrigin === supertype(S.ReadyOrigin)
    @test S.AbstractCommand === supertype(S.Start)
    @test S.AbstractEffect === supertype(S.HoldSources)
    @test !isdefined(S, :Origin) && !isdefined(S, :Command) && !isdefined(S, :Effect)
    @test S.operation(S.InspectWarmup()) === PipeWireAORTC.SessionCodec.operation_id(
        PipeWireAORTC.SessionCodec.WarmupCommand(),
    )
    @test S.operation(S.Admit()) ===
          PipeWireAORTC.SessionCodec.operation_id(PipeWireAORTC.SessionCodec.AdmitCommand())
    @test S.operation(S.Start()) === R.operation_id(R.RunnerCommand(:session_start))
    @test S.Request(S.SESSION_START_OPERATION).command === S.Start()
    @test S.Request(S.Start(); deadline = Int64(-1)).deadline === Int64(-1)
    @test_throws TypeError S.Request(S.Start(); deadline = 1.0)
    @test_throws TypeError S.Request(S.Start(); deadline = UInt64(1))
    @test_throws TypeError S.Machine(101; clock = ()->0.0)
    @test_throws TypeError S.Machine(101; startup_timeout_ns = 300.0)
    ticket = m.effect
    @test_throws TypeError S.complete!(m, ticket; at = UInt64(1))
    @test m.effect === ticket
    @test_throws OverflowError S.Machine(
        101;
        clock = Clocks.CachedNanoClock(typemax(Int64)),
    )

    m = ready(; clock = Clocks.CachedNanoClock(Int64(-2_000_000_000)))
    S.submit!(m, S.Request(S.Properties(); deadline = Int64(-1), payload = "science"))
    @test m.deadline === Int64(-1)
    Clocks.update!(m.clock, Int64(-2))
    S.tick!(m)
    @test m.effect !== nothing
    Clocks.update!(m.clock, Int64(-1))
    S.tick!(m)
    @test m.lifecycle === R.Ready && m.failure === nothing
    @test only(S.take_replies!(m)).lifecycle === R.Ready
    S.take_cancelled!(m)
    epoch = m.epoch
    Clocks.update!(m.clock, typemax(Int64)-S.SESSION_EFFECT_TIMEOUT_NS+Int64(1))
    @test_throws OverflowError S.submit!(m, S.Request(S.Properties(); payload = "science"))
    @test m.effect === nothing && m.request === nothing && m.epoch == epoch
    @test m.lifecycle === R.Ready
end

@testset "Failed Quit preserves its first effect and supervises partially retired owners" begin
    for (step, trigger) in (
        (S.ShutdownOwners, :error),
        (S.ShutdownOwners, :tick),
        (S.ShutdownOwners, :late_completion),
        (S.ShutdownOwners, :required_loss),
        (S.RemoveControls, :error),
    )
        clock = zero_clock()
        m = running(; clock)
        S.required_lost!(m, "Required woofer Link removed")
        sequence!(m, (S.HoldSources, S.HoldGraphs, S.WithdrawLinks))
        @test Hsm.current(m) === :HeldFault

        Clocks.update!(clock, SECOND)
        S.submit!(m, S.Request(S.Quit(); token = 47, controller = LAUNCHER))
        index = findfirst(==(step), SHUTDOWN)
        sequence!(m, SHUTDOWN[1:(index-1)])
        failed = m.effect
        @test failed.effect isa step

        source_id, first_owner_id, second_owner_id = UInt32.((9, 10, 11))
        source_serial, first_owner_serial, second_owner_serial = UInt64.((275, 280, 290))
        objects = Dict(source_id => (; serial = source_serial))
        runtime = (;
            machine = m, objects,
            captured = Dict(
                source_id => objects[source_id],
                first_owner_id => (; serial = first_owner_serial),
                second_owner_id => (; serial = second_owner_serial),
            ),
            retired = Dict{UInt32,UInt64}(),
        )
        job = S.Job(failed, false)
        S.retire_object!(runtime, source_id)
        @test runtime.retired[source_id] == source_serial
        @test !haskey(runtime.captured, source_id)

        if step === S.ShutdownOwners
            S.quit_target!(
                runtime, job, :bootstrap, "source bootstrap", first_owner_id;
                pid = 325, instance = 60,
            )
            S.submitted!(m, failed)
            S.quit_acknowledge!(runtime, job)
            S.quit_target!(
                runtime, job, :bootstrap, "parameter bootstrap", second_owner_id;
                pid = 326, instance = 70,
            )
            S.submitted!(m, failed)
        else
            S.quit_target!(
                runtime, job, :retired_global, "registry withdrawal", source_id;
                serial = source_serial,
            )
        end

        reason = if trigger === :error
            message = step === S.RemoveControls ? "inventory unavailable" : "bootstrap rejected"
            S.fail!(m, failed, message; submitted = false)
            message
        elseif trigger === :required_loss
            message = "remote core incarnation changed"
            S.required_lost!(m, message)
            message
        else
            Clocks.update!(clock, failed.deadline)
            trigger === :tick ? S.tick!(m) : S.complete!(m, failed)
            "Session effect expired"
        end
        @test m.lifecycle == R.Fault && Hsm.current(m) === :EmergencyDisconnect
        disconnect = m.effect
        @test disconnect.effect === S.Disconnect()
        @test disconnect.deadline == typemax(Int64)
        @test m.failure == "Required woofer Link removed"
        first = m.quit_failure
        @test first.ticket === failed && first.reason == reason
        @test first.admitted_at == SECOND && first.failed_at == Clocks.time_nanos(clock)
        @test first.ticket.deadline == SECOND + S.SESSION_EFFECT_TIMEOUT_NS
        @test first.submitted == (step === S.ShutdownOwners)
        if step === S.ShutdownOwners
            source, parameter = first.targets
            @test source.target.serial == first_owner_serial
            @test source.submitted && source.acknowledged
            @test parameter.target.name == "parameter bootstrap"
            @test parameter.target.id == second_owner_id
            @test parameter.target.serial == second_owner_serial
            @test parameter.target.pid == UInt32(326) && parameter.target.instance == 70
            @test parameter.submitted && !parameter.acknowledged
        else
            @test only(first.targets).target.serial == source_serial
        end
        S.take_cancelled!(m)
        S.quit_acknowledge!(runtime, job)
        S.fail!(m, failed, "stale error")
        S.submit!(m, S.Request(S.Quit(); token = 48, controller = LAUNCHER))
        @test only(S.take_replies!(m)).outcome === :Failed
        @test m.effect === disconnect && m.quit_failure === first
        S.fail!(m, disconnect, "supervised transport close failed")
        reply = only(S.take_replies!(m))
        @test reply.token == 47 && reply.outcome === :Failed && reply.unknown
        @test occursin(string(nameof(step)), reply.error)
        @test occursin(reason, reply.error)
        @test m.failure == "Required woofer Link removed"
        @test m.quit_failure === first
        @test m.quit_cleanup_failure == "supervised transport close failed"
    end
end

@testset "An unsubmitted Quit Hold still checks the exact source identity" begin
    m = running()
    S.submit!(m, S.Request(S.Quit(); token = 53, controller = LAUNCHER))
    first_hold = m.effect
    source_id = UInt64(9)
    source = S.SourceControlBinding(source_id, UInt32(21), Int64(52), nothing)
    runtime = (;
        sources = [source], machine = m, captured = Dict{UInt32,S.Captured}(),
    )
    job = S.Job(first_hold, false)
    err = try
        S.perform!(runtime, job, first_hold.effect)
        nothing
    catch failure
        failure
    end
    @test err == ArgumentError("object is not captured")
    S.fail!(m, first_hold, sprint(showerror, err); submitted = false)
    first = m.quit_failure
    @test first.ticket === first_hold && !first.submitted
    @test only(first.targets).target.instance == source.instance
    @test m.effect.effect === S.HoldSources()
    @test Hsm.current(m) === :HoldingFaultSources
    @test_throws ArgumentError S.perform!(runtime, S.Job(m.effect, false), m.effect.effect)
    S.fail!(m, m.effect, "source identity was lost"; submitted = false)
    @test m.effect.effect === S.Disconnect()
    @test m.quit_failure === first
    @test m.quit_cleanup_failure == "source identity was lost"
end

@testset "A submitted Quit Hold is never repeated after expiry" begin
    m = running()
    S.submit!(m, S.Request(S.Quit(); token = 54, controller = LAUNCHER))
    first_hold = m.effect
    S.submitted!(m, first_hold)
    Clocks.update!(m.clock, m.deadline)
    S.tick!(m)
    @test S.take_cancelled!(m) === first_hold
    @test m.quit_failure.ticket === first_hold && m.quit_failure.submitted
    @test m.effect.effect === S.Disconnect()
    @test m.fault_unknown
end
end
