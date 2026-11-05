module CalibrationEndpointTests

using Test, PipeWireAORTC
import Hsm

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
        A.Capture(UInt32(0), CURSOR, UInt32(1)),
        A.Restore(Float32[0], A.Immediate()),
        A.Release(),
    )
end
result(::A.Hold) = A.Held(CURSOR)
result(action::A.Adopt) = A.Adopted(CURSOR, copy(action.figure), false)
result(::A.Settle) = A.Settled(CURSOR)
result(::A.Collect) = A.Responses(Float32[1], A.Exposure[], true)
result(::A.Capture) =
    A.Captured(CURSOR, "/tmp/calibration-capture", "a"^64, UInt32(1), UInt64(4), UInt64(8))
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
        :Captured,
        :Restored,
        :Released,
        :Fault,
    )
    # Columns are Hold, Adopt, Settle, Collect, Capture, Restore and Release.
    # This is the retained native action contract, independently of the Hsm hierarchy.
    allowed = (
        (true, false, false, false, false, true, false),
        (false, true, false, false, false, true, false),
        (false, false, true, false, false, true, false),
        (false, false, false, true, true, true, false),
        (false, true, false, false, false, true, false),
        (false, true, false, false, false, true, false),
        (false, false, false, false, false, true, true),
        (false, false, false, false, false, false, false),
        (false, false, false, false, false, true, false),
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

end
