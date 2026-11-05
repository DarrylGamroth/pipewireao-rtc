module MediaSessionTests
using Test, PipeWireAORTC
import Hsm, Clocks
const S = PipeWireAORTC.MediaSession
const LAUNCHER = S.Identity(11,12,13,14)
zero_clock() = 0.0

function acknowledge!(m,result=nothing;submitted=true)
    ticket = something(m.effect)
    submitted && S.submitted!(m,ticket)
    S.complete!(m,ticket,result)
    return ticket
end
function sequence!(m,types)
    tickets = S.EffectTicket[]
    for type in types
        @test m.effect !== nothing
        @test typeof(m.effect.effect) <: type
        push!(tickets,acknowledge!(m))
    end
    return tickets
end
const PREPARATION = (S.CaptureOwners,S.ConnectOwners,S.CaptureParameters,
    S.CaptureSources,S.PrepareSources,S.DiscoverGraphs,S.HoldSources,S.ConnectLinks,S.HoldGraphs)
const SHUTDOWN = (S.HoldSources,S.HoldGraphs,S.WithdrawLinks,S.ShutdownSources,
    S.ShutdownOwners,S.RemoveControls,S.PublishQuit)
function ready(;clock=zero_clock)
    m = S.Machine(101;clock)
    sequence!(m,PREPARATION)
    S.submit!(m,S.Request(15;controller=LAUNCHER))
    S.take_replies!(m)
    S.submit!(m,S.Request(16;controller=LAUNCHER))
    S.take_replies!(m)
    @test Hsm.current(m) === :Ready
    return m
end
function running(;kwargs...)
    m = ready(;kwargs...)
    S.submit!(m,S.Request(10;token=1))
    sequence!(m,(S.RunGraphs,S.RunSources))
    S.take_replies!(m)
    @test Hsm.current(m) === :Running
    return m
end

@testset "Warmup retains Configuring until exact launcher admission" begin
    m = S.Machine(101;clock=zero_clock)
    @test m.lifecycle == 2 && !m.warmed
    startup,deadline = m.effect,m.deadline
    S.observe!(m,S.Observation(("science"=>false,), (;cohort=0,observed_at=0.0)))
    S.submit!(m,S.Request(3;token=1))
    @test only(S.take_replies!(m)).details.cohort == 0
    @test m.effect === startup && m.deadline == deadline
    S.submit!(m,S.Request(15;controller=LAUNCHER))
    @test only(S.take_replies!(m)).details === false
    @test m.effect === startup && m.deadline == deadline
    S.submit!(m,S.Request(16;controller=LAUNCHER))
    @test only(S.take_replies!(m)).outcome === :Failed
    sequence!(m,PREPARATION)
    @test Hsm.current(m) === :AwaitingAdmission
    @test m.effect === nothing && m.warmed && m.lifecycle == 2
    S.submit!(m,S.Request(16;controller=S.Identity(11,12,13,15)))
    @test only(S.take_replies!(m)).outcome === :Failed
    @test m.lifecycle == 2
    S.submit!(m,S.Request(16;controller=LAUNCHER))
    reply = only(S.take_replies!(m))
    @test reply.outcome === :Warmup && reply.lifecycle == 3
    @test Hsm.current(m) === :Ready
end

@testset "Lifecycle effect order, source-end proof and unchanged wire IDs" begin
    m = ready()
    S.submit!(m,S.Request(10;token=2))
    @test m.lifecycle == 3
    first = sequence!(m,(S.RunGraphs,)) |> only
    @test first.effect.group === nothing && first.effect.running
    @test m.lifecycle == 3
    sequence!(m,(S.RunSources,))
    @test m.lifecycle == 4
    @test only(S.take_replies!(m)).outcome === :Lifecycle
    S.submit!(m,S.Request(11;token=3))
    @test m.effect.effect === S.QuerySourceEnd()
    acknowledge!(m,S.SourceEnd(true,false);submitted=false)
    sequence!(m,(S.HoldSources,))
    @test m.lifecycle == 3
    sequence!(m,(S.HoldGraphs,))
    @test m.effect === nothing && Hsm.current(m) === :Ready
    S.take_replies!(m)
    S.submit!(m,S.Request(12;token=4))
    sequence!(m,(S.HoldSources,S.HoldGraphs,S.ResetSources,S.ResetGraphs))
    @test m.lifecycle == 3 && m.effect === nothing
    @test only(S.take_replies!(m)).outcome === :Lifecycle
    S.submit!(m,S.Request(1;token=5))
    sequence!(m,SHUTDOWN)
    @test m.lifecycle == 1 && Hsm.current(m) === :Offline && m.effect === nothing
    @test only(S.take_replies!(m)).outcome === :Quit

    m = running()
    S.submit!(m,S.Request(11))
    acknowledge!(m,S.SourceEnd(false,false);submitted=false)
    @test m.lifecycle == 5 && m.effect.effect === S.HoldSources()
    @test m.failure == "Source end is not confirmed"
end

@testset "All public command effects and state-dependent admission" begin
    m = ready()
    for (operation,effect) in ((2,S.QueryGroups),(3,S.QueryStatus),
            (4,S.QueryProperties),(5,S.QueryPropertyGeneration),(6,S.QueryParameterGeneration),
            (13,S.UpdateProperties),(14,S.SubmitParameter))
        payload = ("science",operation)
        S.submit!(m,S.Request(operation;token=operation,payload))
        @test typeof(m.effect.effect) <: effect
        acknowledge!(m,(;observed=operation);submitted=operation>=13)
        reply = only(S.take_replies!(m))
        @test reply.details.observed == operation && reply.lifecycle == 3
        @test Hsm.current(m) === :Ready
    end
    S.submit!(m,S.Request(7;payload="science"))
    @test only(S.take_replies!(m)).outcome === :Failed && m.effect === nothing
    S.submit!(m,S.Request(10))
    sequence!(m,(S.RunGraphs,S.RunSources))
    S.take_replies!(m)
    for (operation,running) in ((7,false),(8,true))
        S.submit!(m,S.Request(operation;payload="science"))
        @test m.effect.effect == S.RunGraphs("science",running)
        acknowledge!(m,(;group="science",running))
        @test only(S.take_replies!(m)).outcome === :Group
        @test m.lifecycle == 4
    end
    S.submit!(m,S.Request(12))
    @test only(S.take_replies!(m)).outcome === :Failed
    S.submit!(m,S.Request(10))
    @test only(S.take_replies!(m)).outcome === :Failed
    S.submit!(m,S.Request(9))
    sequence!(m,(S.HoldSources,S.HoldGraphs))
    @test m.lifecycle == 3
end

@testset "Single effect slot, exact correlation and stale completion fencing" begin
    m = ready()
    S.submit!(m,S.Request(10;token=1))
    original = something(m.effect)
    S.submit!(m,S.Request(9;token=2))
    @test m.effect === original
    @test only(S.take_replies!(m)).outcome === :Failed
    for changed in (
            S.EffectTicket(original.session+1,original.epoch,original.serial,original.operation,
                original.origin,original.deadline,original.effect,original.target),
            S.EffectTicket(original.session,original.epoch+1,original.serial,original.operation,
                original.origin,original.deadline,original.effect,original.target),
            S.EffectTicket(original.session,original.epoch,original.serial+1,original.operation,
                original.origin,original.deadline,original.effect,original.target),
            S.EffectTicket(original.session,original.epoch,original.serial,original.operation+UInt32(1),
                original.origin,original.deadline,original.effect,original.target))
        S.complete!(m,changed)
        @test m.effect === original
    end
    acknowledge!(m)
    next = m.effect
    S.complete!(m,original)
    S.fail!(m,original,"late failure")
    @test m.effect === next && m.failure === nothing
    S.submitted!(m,next)
    S.submit!(m,S.Request(1;token=3))
    @test S.take_cancelled!(m) === next
    @test S.take_cancelled!(m) === nothing
    cancelled_reply = only(S.take_replies!(m))
    @test cancelled_reply.token == 1 && cancelled_reply.unknown
    @test m.effect.effect === S.HoldSources() && m.effect.epoch > original.epoch
    replacement = m.effect
    S.complete!(m,next)
    @test m.effect === replacement
    sequence!(m,SHUTDOWN)
    @test only(S.take_replies!(m)).token == 3
end

@testset "Absolute deadlines distinguish no-effect refusal and unknown submission" begin
    clock = Clocks.CachedNanoClock(2_000_000_000)
    m = ready(;clock)
    S.submit!(m,S.Request(13;token=1,deadline=6.0,payload=("science",)))
    ticket = m.effect
    @test ticket.deadline == 6.0
    Clocks.update!(clock,5_999_999_999)
    S.tick!(m)
    @test m.effect === ticket
    Clocks.advance!(clock,1)
    S.tick!(m)
    @test Hsm.current(m) === :Ready && m.failure === nothing
    @test !only(S.take_replies!(m)).unknown
    @test S.take_cancelled!(m) === ticket
    S.submit!(m,S.Request(14;token=2,payload=("science",)))
    @test m.effect.deadline == 11.0
    S.submitted!(m,m.effect)
    Clocks.update!(clock,11_000_000_000)
    S.tick!(m)
    @test m.lifecycle == 5 && m.deadline == 16.0
    @test S.take_cancelled!(m) !== nothing
    @test isempty(S.take_replies!(m))
    sequence!(m,(S.HoldSources,S.HoldGraphs,S.WithdrawLinks))
    @test only(S.take_replies!(m)).unknown
    @test Hsm.current(m) === :HeldFault

    m = ready(;clock=zero_clock)
    S.submit!(m,S.Request(4;deadline=2.0,payload="science"))
    S.complete!(m,m.effect;at=2.0)
    @test Hsm.current(m) === :Ready && m.failure === nothing
    @test only(S.take_replies!(m)).outcome === :Failed
end

@testset "First fault, source-first compensation and explicit Quit recovery" begin
    m = running()
    S.submit!(m,S.Request(13;token=8,payload="science"))
    S.submitted!(m,m.effect)
    before = m.effect
    S.required_lost!(m,"required sink lost")
    @test m.failure == "required sink lost" && m.lifecycle == 5
    @test S.take_cancelled!(m) === before
    hold,deadline = m.effect,m.deadline
    S.required_lost!(m,"second loss")
    @test m.effect === hold && m.deadline == deadline && m.failure == "required sink lost"
    @test isempty(S.take_replies!(m))
    sequence!(m,(S.HoldSources,))
    S.fail!(m,m.effect,"graph hold failed";submitted=true)
    @test m.effect.effect === S.WithdrawLinks()
    acknowledge!(m)
    @test Hsm.current(m) === :HeldFault && m.lifecycle == 5
    @test only(S.take_replies!(m)).unknown
    @test m.cleanup_failure == "graph hold failed"
    S.submit!(m,S.Request(1;token=9))
    sequence!(m,SHUTDOWN)
    @test m.lifecycle == 1 && only(S.take_replies!(m)).outcome === :Quit

    m = running()
    S.required_lost!(m,"source disappeared")
    S.take_cancelled!(m)
    S.fail!(m,m.effect,"source Hold unknown";submitted=true)
    @test Hsm.current(m) === :EmergencyDisconnect
    @test m.effect.effect === S.Disconnect()
    acknowledge!(m)
    @test m.lifecycle == 5 && m.effect === nothing

    m = S.Machine(101;clock=zero_clock)
    startup = m.effect
    S.submit!(m,S.Request(1;token=10))
    @test S.take_cancelled!(m) === startup
    sequence!(m,SHUTDOWN)
    @test m.lifecycle == 1 && only(S.take_replies!(m)).token == 10
end

@testset "Pre-effect validation does not fault and outboxes are bounded" begin
    m = running()
    S.submit!(m,S.Request(7;token=11,payload="undeclared"))
    S.fail!(m,m.effect,"undeclared execution group";submitted=false)
    @test m.lifecycle == 4 && m.failure === nothing && m.effect === nothing
    @test !only(S.take_replies!(m)).unknown
    m = S.Machine(101;clock=zero_clock)
    ticket = m.effect
    S.submit!(m,S.Request(10))
    S.submit!(m,S.Request(12))
    @test length(m.replies) == 2
    @test_throws ArgumentError S.submit!(m,S.Request(14))
    @test m.effect === ticket && length(m.replies) == 2
    @test_throws ArgumentError S.Request(17)
    @test_throws ArgumentError S.Machine(0)
end

@testset "Emergency disconnect outlives the expired source-Hold budget" begin
    clock = Clocks.CachedNanoClock(0)
    m = running(;clock)
    S.required_lost!(m,"required source lost")
    held,deadline = m.effect,m.deadline
    Clocks.update!(clock,round(Int,deadline*1e9))
    S.tick!(m)
    @test S.take_cancelled!(m) === held
    disconnect = m.effect
    @test disconnect.effect === S.Disconnect()
    @test !S.budgeted(disconnect.effect) && disconnect.deadline == Inf
    @test Hsm.current(m) === :EmergencyDisconnect
    for _ in 1:3
        Clocks.advance!(clock,5_000_000_000)
        S.tick!(m)
        S.required_lost!(m,"late required loss")
        S.complete!(m,held)
        S.fail!(m,held,"late source failure")
        @test m.effect === disconnect
        @test S.take_cancelled!(m) === nothing
    end
    S.complete!(m,disconnect)
    @test m.effect === nothing && Hsm.current(m) === :HeldFault
    S.complete!(m,disconnect)
    S.tick!(m)
    @test m.effect === nothing && m.failure == "required source lost"
end

@testset "Accepted Quit precedes publication fence and survives fence failure" begin
    for disposition in (:complete,:fail,:expire)
        clock = Clocks.CachedNanoClock(0)
        m = S.Machine(101;clock)
        S.submit!(m,S.Request(1;token=23))
        S.take_cancelled!(m)
        sequence!(m,SHUTDOWN[1:end-1])
        @test m.lifecycle == 1 && Hsm.current(m) === :PublishingQuit
        reply = only(S.take_replies!(m))
        @test reply.outcome === :Quit && reply.details === true && !reply.unknown
        fence = m.effect
        @test fence.effect === S.PublishQuit() && fence.operation == 1
        S.submit!(m,S.Request(1;token=23))
        @test only(S.take_replies!(m)).outcome === :Failed
        @test m.effect === fence
        S.required_lost!(m,"expected owner disappearance")
        @test m.effect === fence && m.lifecycle == 1
        S.observe!(m,S.Observation(nothing,(;closed=true)))
        S.submit!(m,S.Request(3))
        @test only(S.take_replies!(m)).lifecycle == 1
        @test m.effect === fence
        if disposition === :complete
            S.complete!(m,fence)
        elseif disposition === :fail
            S.fail!(m,fence,"publication unavailable";submitted=false)
        else
            Clocks.update!(clock,5_000_000_000)
            S.tick!(m)
            @test S.take_cancelled!(m) === fence
        end
        @test m.lifecycle == 1 && Hsm.current(m) === :Offline && m.effect === nothing
        @test isempty(S.take_replies!(m)) && m.failure === nothing
        S.complete!(m,fence)
        S.fail!(m,fence,"late publication failure")
        @test m.lifecycle == 1 && isempty(S.take_replies!(m))
    end
end
end
