module CalibrationEndpointTests

using Test, PipeWireAORTC
import Hsm
import Clocks

const E = PipeWireAORTC.CalibrationEndpoint
const A = PipeWireAORTC.CalibrationActionCodec
const CURSOR = A.AcquisitionCursor(typemax(UInt64), UInt64(1) << 63, 0, 0)
const RUN = typemax(UInt64)
const SERIAL = UInt64(1) << 63

function actions()
    (
        A.Hold(),
        A.Adopt(UInt32(0), Float32[1]),
        A.Settle(UInt32(0), CURSOR, A.Immediate()),
        A.Collect(UInt32(0), CURSOR, UInt32(1), UInt32(1)),
        A.Restore(Float32[0], A.Immediate()),
        A.Release(),
    )
end
result(::A.Hold) = A.Held(CURSOR)
result(action::A.Adopt) = A.Adopted(CURSOR, copy(action.figure), false)
result(::A.Settle) = A.Settled(CURSOR)
result(::A.Collect) = A.Responses(Float32[1], A.Exposure[], true)
result(action::A.Restore) = A.Restored(copy(action.figure), false)
result(::A.Release) = A.Released()

function at_phase(phase)
    sm = E.Protocol()
    Hsm.transition!(sm, phase)
    return sm
end

@testset "Calibration action/phase admission and result adoption" begin
    phases = (
        :Prepared,
        :Held,
        :Adopted,
        :Settled,
        :Responses,
        :Restored,
        :Released,
        :Fault,
    )
    # Columns are Hold, Adopt, Settle, Collect, Restore and Release.
    # This is the retained native action contract, independently of the Hsm hierarchy.
    allowed = (
        (true, false, false, false, true, false),
        (false, true, false, false, true, false),
        (false, false, true, false, true, false),
        (false, false, false, true, true, false),
        (false, true, false, false, true, false),
        (false, false, false, false, true, true),
        (false, false, false, false, false, false),
        (false, false, false, false, true, false),
    )
    for (row, phase) in enumerate(phases), (column, action) in enumerate(actions())
        sm = at_phase(phase)
        command = A.Command(RUN, SERIAL, action)
        admitted = Hsm.dispatch!(sm, :Requested, command)
        @test (admitted == Hsm.EventHandled) == allowed[row][column]
        @test (sm.run, sm.serial, Hsm.current(sm)) == (0, 0, phase)
        if allowed[row][column]
            @test sm.command === command
            @test Hsm.dispatch!(sm, :Accepted, command) == Hsm.EventHandled
            @test (sm.run, sm.serial) == (RUN, SERIAL)
            @test Hsm.dispatch!(sm, :Completed, result(action)) == Hsm.EventHandled
            @test Hsm.current(sm) == nameof(typeof(result(action)))
            @test sm.command === nothing
        else
            @test sm.command === nothing
        end
    end
    sm = E.Protocol()
    @test Hsm.ancestor(sm, :Settled) === :Acquisition
    @test Hsm.ancestor(sm, :Acquisition) === :Active
end

@testset "Accepted identities, failed results and one-shot adoption" begin
    sm = E.Protocol()
    hold = A.Command(RUN, SERIAL, A.Hold())
    @test Hsm.dispatch!(sm, :Requested, hold) == Hsm.EventHandled
    @test Hsm.dispatch!(sm, :Requested, hold) == Hsm.EventNotHandled
    @test Hsm.dispatch!(sm, :Accepted, hold) == Hsm.EventHandled
    @test Hsm.dispatch!(sm, :Accepted, hold) == Hsm.EventNotHandled
    @test Hsm.dispatch!(sm, :Completed, A.Failed(A.InvalidEvidence)) == Hsm.EventHandled
    @test Hsm.current(sm) === :Prepared && sm.command === nothing
    for command in (
        hold,
        A.Command(RUN - UInt64(1), SERIAL + UInt64(1), A.Hold()),
        A.Command(RUN, SERIAL - UInt64(1), A.Hold()),
    )
        @test Hsm.dispatch!(sm, :Requested, command) == Hsm.EventNotHandled
        @test (sm.run, sm.serial, Hsm.current(sm)) == (RUN, SERIAL, :Prepared)
        @test sm.command === nothing
    end
    next = A.Command(RUN, SERIAL + UInt64(1), A.Hold())
    @test Hsm.dispatch!(sm, :Requested, next) == Hsm.EventHandled
    @test Hsm.dispatch!(sm, :Accepted, next) == Hsm.EventHandled
    @test_throws ErrorException Hsm.dispatch!(sm, :Completed, A.Released())
    @test Hsm.current(sm) === :Prepared && sm.command === next
    @test Hsm.dispatch!(sm, :Faulted) == Hsm.EventHandled
    @test Hsm.current(sm) === :Fault && sm.command === nothing
    @test (sm.run, sm.serial) == (RUN, SERIAL + UInt64(1))
end

@testset "Results cannot adopt before controller retention and acceptance" begin
    sm = E.Protocol()
    command = A.Command(RUN, SERIAL, A.Hold())
    Hsm.dispatch!(sm, :Requested, command)
    @test_throws ErrorException Hsm.dispatch!(sm, :Completed, A.Held(CURSOR))
    @test (sm.run, sm.serial, Hsm.current(sm)) == (0, 0, :Prepared)
    @test sm.command === command
    Hsm.dispatch!(sm, :Faulted)
    @test sm.command === nothing
end

mutable struct WaitClock <: Clocks.AbstractNanoClock
    at::Int64
    reads::Int
end
Clocks.time_nanos(clock::WaitClock) = (clock.reads += 1; clock.at)

@testset "calibration waits use one signed sample per decision" begin
    for origin in (typemin(Int64), -Int64(2)^60, Int64(2)^53 + 1, typemax(Int64) - 1)
        condition = Base.AsyncCondition()
        guard = ReentrantLock()
        clock = WaitClock(origin, 0)
        try
            @test E.await(() -> :ready, condition, guard, origin + 1; clock) === :ready
            @test clock.reads == 1
            clock.at = origin + 1
            called = Ref(false)
            @test_throws PipeWireAORTC.ControlClient.UnknownOutcome E.await(
                () -> (called[] = true), condition, guard, origin + 1; clock
            )
            @test !called[] && clock.reads == 2
        finally
            close(condition)
        end
    end
    condition = Base.AsyncCondition()
    guard = ReentrantLock()
    clock = WaitClock(-10, 0)
    calls = Ref(0)
    try
        @test_throws PipeWireAORTC.ControlClient.UnknownOutcome E.await(
            condition, guard, Int64(10); clock
        ) do
            calls[] += 1
            clock.at -= 1
            E.wake!(condition, guard)
            false
        end
        @test clock.reads == 2 && calls[] == 1
        clock.at = 1_000_000_000
        @test E.await(() -> true, condition, guard, 2.0; clock)
        @test_throws ArgumentError E.await(() -> true, condition, guard, Inf; clock)
        # Timer conversion also spans signed origins without subtracting Int64s.
        clock.at = typemin(Int64)
        @test E.await(() -> true, condition, guard, typemax(Int64); clock)
    finally
        close(condition)
    end
end

end
