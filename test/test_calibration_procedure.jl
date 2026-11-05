module CalibrationProcedureTests
using Test, PipeWireAORTC
import Hsm
import Clocks
const A = PipeWireAORTC.CalibrationAcquisition
const SECOND = Int64(1_000_000_000)
const C = PipeWireAORTC.CalibrationActionCodec
const D = Float32[2 1; -1 3; 4 -2]
const TIMEOUTS = A.Timeouts(ntuple(_ -> 1_000_000_000, 5)...)
function plan()
    A.Plan(
        91,
        zeros(Float32, 2),
        [Float32[0.1, 0], Float32[-0.1, 0], Float32[0, 0.1], Float32[0, -0.1]],
        3,
        2,
        C.DiscardExposures(UInt32(1)),
        TIMEOUTS,
    )
end

# Independent linear sensor oracle, with explicit adopted figures and exposures.
mutable struct Sensor
    figure::Vector{Float32}
    cursor::C.AcquisitionCursor
end
Sensor() = Sensor(zeros(Float32, 2), C.AcquisitionCursor(11, 1, 0, 0))
response(s, ::C.Hold) = C.Held(s.cursor)
function response(s, a::C.Adopt)
    s.figure .= a.figure
    C.Adopted(s.cursor, copy(s.figure), false)
end
function response(s, a::C.Settle)
    c = s.cursor
    s.cursor = C.AcquisitionCursor(c.domain, c.generation, c.sequence + 1, c.model_ns + 10)
    C.Settled(s.cursor)
end
function response(s, a::C.Collect)
    exposures = C.Exposure[]
    for _ in 1:a.frames
        c = s.cursor
        push!(exposures, C.Exposure(c.domain, c.generation, c.sequence + 1, c.model_ns, 10))
        s.cursor = C.AcquisitionCursor(
            c.domain, c.generation, c.sequence + 1, c.model_ns + 10
        )
    end
    C.Responses(D * s.figure, exposures, true)
end
response(s, a::C.Restore) = (s.figure .= a.figure; C.Restored(copy(s.figure), false))
response(s, ::C.Release) = C.Released()
function deliver!(p, result; run = p.command.run, serial = p.command.serial)
    A.complete!(p, run, serial, result)
end
function run!(p, sensor = Sensor())
    events = []
    while p.command !== nothing
        c = p.command
        result = response(sensor, c.action)
        push!(events, (c.run, c.serial, result))
        deliver!(p, result)
    end
    events
end

function procedure_at(action; kwargs...)
    p = A.Procedure(plan(); kwargs...)
    sensor = Sensor()
    while !(p.command.action isa action)
        deliver!(p, response(sensor, p.command.action))
    end
    return p, sensor
end

@testset "Cached clocks retain known completion versus unknown exact expiry" begin
    clock = Clocks.CachedNanoClock(2_000_000_000)
    p = A.Procedure(plan(); clock)
    @test p.clock === clock && p.deadline == 3 * SECOND
    command = p.command
    Clocks.advance!(clock, 999_999_999)
    @test A.expire!(p) === nothing && p.command === command
    Clocks.advance!(clock, 1)
    @test A.expire!(p) === nothing && p.command === nothing
    @test p.result.failure == "TimedOut(Holding)" && !p.result.resume_permitted
    clock = Clocks.CachedNanoClock(2_000_000_000)
    p = A.Procedure(plan(); clock)
    Clocks.update!(clock, 3_000_000_000)
    next = deliver!(p, C.Held(Sensor().cursor))
    @test next === p.command && next.action isa C.Restore && next.serial == 2
    @test p.failure == "TimedOut(Holding)" && p.deadline == 4 * SECOND
    @test length(run!(p)) == 2
    @test p.result.phase == "aborted" && p.result.resume_permitted
end

@testset "signed procedure clocks and checked action budgets" begin
    for origin in (typemin(Int64), -Int64(2)^60, Int64(2)^53 + 1, typemax(Int64) - SECOND)
        clock = Clocks.CachedNanoClock(origin)
        p = A.Procedure(plan(); clock)
        @test p.deadline === Base.Checked.checked_add(origin, SECOND)
        @test length(run!(p)) == 15
        @test p.result.phase == "complete" && p.result.resume_permitted
    end
    p = A.Procedure(plan(); clock = Clocks.CachedNanoClock(typemax(Int64)))
    @test p.command === nothing && p.serial == 0
    @test Hsm.current(p) === :Fault && p.result.failure == "Clock deadline overflow"
    @test !p.result.resume_permitted
    for action in (C.Hold, C.Adopt, C.Settle, C.Collect, C.Restore)
        clock = Clocks.CachedNanoClock(Int64(0))
        p, sensor = procedure_at(action; clock)
        command = p.command
        Clocks.update!(clock, typemax(Int64))
        A.complete!(
            p, command.run, command.serial, response(sensor, command.action); at = Int64(0)
        )
        @test p.command === nothing && p.serial == command.serial
        @test Hsm.current(p) === :Fault && p.result.failure == "Clock deadline overflow"
        @test !p.result.resume_permitted && p.result.recovery_failure == "Endpoint"
    end
end

@testset "decision regression and retained receipt time are distinct" begin
    for action in (C.Hold, C.Restore, C.Release), event in (:complete, :expire)
        clock = Clocks.CachedNanoClock(5 * SECOND)
        p, sensor = procedure_at(action; clock)
        command = p.command
        Clocks.advance!(clock, Int64(-1))
        if event === :complete
            deliver!(p, response(sensor, command.action))
        else
            A.expire!(p)
        end
        @test p.command === nothing && p.serial == command.serial
        @test p.result.failure == "Invalid monotonic clock"
        @test !p.result.resume_permitted
    end
    origin = Int64(2)^53 + 1
    clock = Clocks.CachedNanoClock(origin)
    p = A.Procedure(plan(); clock)
    command = p.command
    Clocks.advance!(clock, SECOND ÷ 2)
    A.expire!(p)
    Clocks.update!(clock, origin + 2 * SECOND)
    A.complete!(p, command.run, command.serial, C.Held(Sensor().cursor); at = origin + 1)
    @test p.command.action isa C.Adopt
    @test p.deadline === origin + 3 * SECOND
    p = A.Procedure(plan(); clock)
    command = p.command
    A.complete!(
        p,
        command.run,
        command.serial,
        C.Held(Sensor().cursor);
        at = Clocks.time_nanos(clock) + 1,
    )
    @test p.result.failure == "Invalid monotonic clock" && p.command === nothing
end

@testset "Acquisition events use shared active, recovery and terminal handlers" begin
    p = A.Procedure(plan(); clock = Clocks.CachedNanoClock(Int64(0)))
    @test Hsm.current(p) === :Holding
    @test Hsm.ancestor(p, :Holding) === :Acquiring
    @test Hsm.ancestor(p, :Acquiring) === :Active
    command, deadline = p.command, p.deadline
    @test Hsm.dispatch!(p, :Cancelled) === Hsm.EventHandled
    @test p.command === command && p.deadline == deadline
    event = (;
        run = command.run,
        serial = command.serial,
        result = C.Held(Sensor().cursor),
        at = Int64(0),
        current = Int64(0),
    )
    @test Hsm.dispatch!(p, :Completed, event) === Hsm.EventHandled
    @test Hsm.current(p) === :Restoring
    @test Hsm.ancestor(p, :Restoring) === :Recovery
    @test p.failure == "Cancelled"
    run!(p)
    @test Hsm.current(p) === :Aborted
    @test Hsm.ancestor(p, :Aborted) === :Terminal
    terminal = p.result
    @test A.cancel!(p) === nothing
    @test A.expire!(p) === nothing
    @test p.command === nothing && p.result === terminal
    @test_throws ArgumentError A.fail!(p, "late"; known = true)
    initially_cancelled = A.Procedure(
        plan(); clock = Clocks.CachedNanoClock(Int64(0)), cancelled = () -> true
    )
    @test Hsm.current(initially_cancelled) === :Restoring
    @test initially_cancelled.command.action isa C.Restore
    @test initially_cancelled.command.serial == 1
end

@testset "Known late completion and unknown expiry differ in every action" begin
    for (action, phase) in (
        (C.Hold, "Holding"),
        (C.Adopt, "Adopting"),
        (C.Settle, "Settling"),
        (C.Collect, "Collecting"),
        (C.Restore, "Restoring"),
        (C.Release, "Releasing"),
    )
        now = Clocks.CachedNanoClock(Int64(0))
        p, sensor = procedure_at(action; clock = now)
        command = p.command
        Clocks.update!(now, p.deadline)
        next = A.complete!(
            p,
            command.run,
            command.serial,
            response(sensor, command.action);
            at = p.deadline,
        )
        @test p.failure == "TimedOut($phase)"
        if action in (C.Restore, C.Release)
            @test next === nothing
            @test Hsm.current(p) === :Fault
            @test p.result.recovery_failure == "TimedOut($phase)"
        else
            @test next === p.command && next.action isa C.Restore
            @test next.serial == command.serial + 1
            @test Hsm.current(p) === :Restoring
        end
        Clocks.update!(now, Int64(0))
        p, _ = procedure_at(action; clock = now)
        serial = p.command.serial
        Clocks.update!(now, p.deadline)
        @test A.expire!(p) === nothing
        @test p.command === nothing && p.serial == serial
        @test Hsm.current(p) === :Fault
        @test p.result.failure == "TimedOut($phase)"
        @test p.result.recovery_failure == "Endpoint"
        @test !p.result.resume_permitted
    end
end

@testset "In-flight collection precedes cancellation and restoration" begin
    for valid in (true, false)
        consumed = Ref(0)
        p, sensor = procedure_at(
            C.Collect;
            clock = Clocks.CachedNanoClock(Int64(0)),
            consume = (_i, _batch) -> (consumed[] += 1),
        )
        A.cancel!(p)
        batch = response(sensor, p.command.action)
        deliver!(p, C.Responses(batch.values, batch.exposures, valid))
        @test consumed[] == (valid ? 1 : 0)
        @test length(p.responses) == (valid ? 1 : 0)
        @test p.command.action isa C.Restore
        @test p.failure == (valid ? "Cancelled" : "InvalidEvidence")
        @test length(run!(p, sensor)) == 2
        @test p.result.phase == "aborted" && p.result.resume_permitted
    end
end

@testset "Consumers can request cancellation between Hsm dispatch steps" begin
    for consumer_error in (false, true)
        holder = Ref{Union{Nothing,A.Procedure}}(nothing)
        consumed = Ref(0)
        consume = function (_probe, _batch)
            consumed[] += 1
            A.cancel!(something(holder[]))
            consumer_error && error("consumer failed after cancellation")
        end
        p = A.Procedure(plan(); clock = Clocks.CachedNanoClock(Int64(0)), consume)
        holder[] = p
        sensor = Sensor()
        while !(p.command.action isa C.Collect)
            deliver!(p, response(sensor, p.command.action))
        end
        serial = p.command.serial
        deliver!(p, response(sensor, p.command.action))
        @test consumed[] == 1 && p.cancelled
        @test p.failure == (consumer_error ? "Processing" : "Cancelled")
        @test p.command.action isa C.Restore && p.command.serial == serial + 1
        @test p.delivery === nothing
        @test length(run!(p, sensor)) == 2
        @test p.result.phase == "aborted" && p.result.resume_permitted
    end
end

@testset "Failure precedence and command ownership survive event dispatch" begin
    p = A.Procedure(plan(); clock = Clocks.CachedNanoClock(Int64(0)))
    @test A.fail!(p, "First"; known = true) === p.command
    serial = p.command.serial
    @test A.fail!(p, "Second"; known = true) === nothing
    @test p.serial == serial && p.result.failure == "First"
    @test p.result.recovery_failure == "Second" && Hsm.current(p) === :Fault
    p = A.Procedure(plan(); clock = Clocks.CachedNanoClock(Int64(0)))
    A.complete!(p, UInt64(92), p.command.serial, C.Held(Sensor().cursor); at = Int64(0))
    @test p.result.failure == "Endpoint"
    p = A.Procedure(plan(); clock = Clocks.CachedNanoClock(Int64(0)))
    command = p.command
    @test_throws TypeError A.complete!(
        p, command.run, command.serial, C.Held(Sensor().cursor); at = NaN
    )
    @test p.command === command && Hsm.current(p) === :Holding
    @test p.failure === nothing
    input = plan()
    p = A.Procedure(input; clock = Clocks.CachedNanoClock(Int64(0)))
    expected = copy(input.probes[1])
    fill!(input.reference, 99)
    fill!(input.probes[1], 99)
    sensor = Sensor()
    next = deliver!(p, response(sensor, p.command.action))
    @test next === p.command && next.action.figure == expected
    run!(p, sensor)
    @test sensor.figure == zeros(Float32, 2)
    @test p.result.phase == "complete"
end

@testset "online response calculation and exact typed replay" begin
    rows = zeros(Float32, 4, 3)
    interaction = zeros(Float32, 3, 2)
    processed = Int[]
    consume = function (probe, batch)
        push!(processed, probe)
        rows[probe, :] .= batch.values
        if iseven(probe)
            interaction[:, probe÷2] .= (rows[probe-1, :] - rows[probe, :]) / 0.2f0
        end
        fill!(batch.values, NaN) # Consumer-owned storage cannot corrupt the receipt.
    end
    p = A.Procedure(plan(); clock = Clocks.CachedNanoClock(Int64(0)), consume)
    sensor = Sensor()
    events = []
    while p.command !== nothing
        c = p.command
        batch = response(sensor, c.action)
        push!(events, (c.run, c.serial, batch))
        deliver!(p, batch)
        if c.action isa C.Collect
            @test last(processed) == Int(c.action.probe) + 1
            @test p.command.action isa Union{C.Adopt,C.Restore}
        end
    end
    @test interaction ≈ D
    @test processed == 1:4
    @test p.result.phase == "complete" && p.result.resume_permitted
    @test all(b -> all(isfinite, b.values), p.result.responses)
    @test sensor.figure == zeros(Float32, 2)
    replay_rows = zeros(Float32, 4, 3)
    replay = A.Procedure(
        plan();
        clock = Clocks.CachedNanoClock(Int64(0)),
        consume = (i, b) -> copyto!(view(replay_rows, i, :), b.values),
    )
    for (run, serial, result) in events
        A.complete!(replay, run, serial, result)
    end
    @test replay_rows == rows
    @test A.document(replay.result) == A.document(p.result)
    @test_throws ArgumentError A.complete!(replay, UInt64(91), UInt64(1), C.Released())
end

@testset "event correlation, timer and cancellation boundaries" begin
    for corrupt in (:run, :serial, :operation)
        p = A.Procedure(plan(); clock = Clocks.CachedNanoClock(Int64(0)))
        result = corrupt == :operation ? C.Released() : C.Held(Sensor().cursor)
        deliver!(
            p,
            result;
            run = UInt64(corrupt == :run ? 92 : 91),
            serial = UInt64(corrupt == :serial ? 2 : 1),
        )
        @test p.command === nothing && p.result.phase == "fault"
        @test !p.result.resume_permitted
    end
    p = A.Procedure(plan(); clock = Clocks.CachedNanoClock(Int64(0)))
    old = p.command
    deliver!(p, C.Held(Sensor().cursor))
    A.complete!(p, old.run, old.serial, C.Held(Sensor().cursor))
    @test p.result.phase == "fault" # Duplicate completion cannot advance a probe.

    clock = Clocks.CachedNanoClock(Int64(0))
    p = A.Procedure(plan(); clock = clock)
    @test A.expire!(p) === nothing && p.command.action isa C.Hold
    Clocks.update!(clock, SECOND)
    A.expire!(p)
    @test p.result.phase == "fault" && p.result.failure == "TimedOut(Holding)"
    @test !p.result.restoration_confirmed

    Clocks.update!(clock, Int64(0))
    p = A.Procedure(plan(); clock = clock)
    Clocks.update!(clock, SECOND)
    deliver!(p, C.Held(Sensor().cursor)) # Known late outcome permits restoration.
    @test p.command.action isa C.Restore
    run!(p)
    @test p.result.phase == "aborted" && p.result.resume_permitted

    p = A.Procedure(plan(); clock = Clocks.CachedNanoClock(Int64(0)))
    A.cancel!(p)
    @test p.command.action isa C.Hold # Do not overlap an in-flight action.
    deliver!(p, C.Held(Sensor().cursor))
    @test p.command.action isa C.Restore
    run!(p)
    @test p.result.failure == "Cancelled" && p.result.resume_permitted

    cancel = Ref(false)
    p = A.Procedure(
        plan();
        clock = Clocks.CachedNanoClock(Int64(0)),
        cancelled = () -> cancel[],
        consume = (i, b) -> (cancel[] = true),
    )
    events = run!(p)
    @test count(e -> e[3] isa C.Adopted, events) == 1
    @test p.result.failure == "Cancelled" && p.result.resume_permitted
end

@testset "invalid batches and consumer failure restore exactly once" begin
    for fault in (:invalid, :processing)
        count = Ref(0)
        p = A.Procedure(
            plan();
            clock = Clocks.CachedNanoClock(Int64(0)),
            consume = (i, b) -> begin
                count[] += 1
                error("numerical worker rejected response")
            end,
        )
        s = Sensor()
        while !(p.command.action isa C.Collect)
            deliver!(p, response(s, p.command.action))
        end
        batch = response(s, p.command.action)
        fault == :invalid && (batch = C.Responses(batch.values, batch.exposures, false))
        deliver!(p, batch)
        @test count[] == (fault == :invalid ? 0 : 1)
        @test p.command.action isa C.Restore
        events = run!(p, s)
        @test length(events) == 2
        @test p.result.phase == "aborted" && isempty(p.result.responses)
        @test p.result.failure == (fault == :invalid ? "InvalidEvidence" : "Processing")
        @test p.result.resume_permitted
    end
    p = A.Procedure(plan(); clock = Clocks.CachedNanoClock(Int64(0)))
    A.fail!(p, "Endpoint"; known = true)
    deliver!(p, C.Restored(zeros(Float32, 2), true))
    @test p.command === nothing && p.result.phase == "fault"
    @test !p.result.resume_permitted && p.result.recovery_failure == "InvalidEvidence"
end
end
