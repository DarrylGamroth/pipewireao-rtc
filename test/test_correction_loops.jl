using Test, PipeWireAORTC
import Hsm
import PipeWireAO

const CL = PipeWireAORTC.CorrectionLoops
const OWNER = Int64(1701)

function loop_at(closed::Bool; generation=Int64(0))
    sm = CL.Loop("correction:closed", OWNER)
    CL.observed!(sm, OWNER, generation, generation, closed)
    return sm
end

function loop_props(closed; requested=Int64(0), active=requested,
        property="correction:closed", node="correction")
    return PipeWireAO.SPA.Props(property => closed,
        node * ":requested-generation" => requested,
        node * ":active-generation" => active)
end

@testset "Correction loop starts from applied owner readback" begin
    @test_throws ArgumentError CL.Loop("closed", OWNER)
    @test_throws ArgumentError CL.Loop(":closed", OWNER)
    @test_throws ArgumentError CL.Loop("node:", OWNER)
    @test_throws ArgumentError CL.Loop("node:property:extra", OWNER)
    @test_throws ArgumentError CL.Loop("correction:closed", Int64(0))
    @test_throws ArgumentError CL.Observer(["correction:closed", "correction:closed"], OWNER)
    for (closed, expected) in ((false, :Open), (true, :Closed))
        sm = CL.Loop("correction:closed", OWNER)
        @test CL.state(sm) === :Unknown
        @test Hsm.current(sm) === :Unknown
        @test !sm.initialized
        @test sm.failure === nothing
        @test CL.observed!(sm, OWNER + 1, 0, 0, !closed) === nothing
        @test !sm.initialized
        @test CL.observed!(sm, OWNER, 0, 0, closed) === nothing
        @test CL.state(sm) === expected
        @test Hsm.current(sm) === expected
        @test sm.initialized
        @test sm.applied_closed === closed
    end
    sm = CL.Loop("correction:closed", OWNER)
    CL.observed!(sm, OWNER, 1, 0, true)
    @test CL.state(sm) === :Unknown
    @test sm.failure === :uninitialized_pending
    CL.observed!(sm, OWNER, 1, 1, true)
    @test CL.state(sm) === :Unknown
end

@testset "Accepted requests remain pending until exact adoption" begin
    for (initial, requested, pending, applied) in
            ((false, true, :Closing, :Closed), (true, false, :Opening, :Open))
        sm = loop_at(initial)
        @test CL.requested!(sm, OWNER, 1, 0, requested) === nothing
        @test CL.state(sm) === pending
        @test Hsm.current(sm) === pending
        @test sm.applied_closed === initial
        @test sm.requested_closed === requested
        @test sm.active_generation == 0
        CL.observed!(sm, OWNER, 1, 0, initial)
        @test CL.state(sm) === pending
        CL.observed!(sm, OWNER + 1, 1, 1, requested)
        @test CL.state(sm) === pending
        CL.observed!(sm, OWNER, 0, 0, initial)
        @test CL.state(sm) === pending
        @test sm.active_generation == 0
        CL.observed!(sm, OWNER, 1, 1, requested)
        @test CL.state(sm) === applied
        @test Hsm.current(sm) === applied
        @test sm.active_generation == sm.requested_generation == 1
        CL.observed!(sm, OWNER, 1, 1, requested)
        @test CL.state(sm) === applied
        @test sm.failure === nothing
    end
end

@testset "Duplicate requests and unrelated property generations" begin
    sm = loop_at(false)
    CL.requested!(sm, OWNER, 1, 0, true)
    CL.requested!(sm, OWNER, 1, 0, true)
    @test CL.state(sm) === :Closing
    @test sm.failure === nothing
    CL.requested!(sm, OWNER + 1, 2, 1, false)
    @test CL.state(sm) === :Closing
    CL.observed!(sm, OWNER, 1, 1, true)
    # Another property write on this node advances its generation but does not
    # mean that correction is opening or closing.
    CL.requested!(sm, OWNER, 2, 1, true)
    @test CL.state(sm) === :Closed
    @test sm.active_generation == 1
    CL.observed!(sm, OWNER, 2, 1, true)
    @test CL.state(sm) === :Closed
    CL.observed!(sm, OWNER, 2, 2, true)
    @test CL.state(sm) === :Closed
    CL.requested!(sm, OWNER, 3, 2, true)
    CL.observed!(sm, OWNER, 3, 3, true)
    @test CL.state(sm) === :Closed
    @test sm.active_generation == 3
    CL.requested!(sm, OWNER, 1, 0, false)
    CL.observed!(sm, OWNER, 1, 1, false)
    @test CL.state(sm) === :Closed
    @test sm.failure === nothing
    sm = loop_at(false)
    CL.requested!(sm, OWNER, 1, 0, false)
    @test CL.state(sm) === :Open
    CL.observed!(sm, OWNER, 1, 1, false)
    @test CL.state(sm) === :Open
end

@testset "Impossible accepted requests latch unknown rather than admit writes" begin
    for (generation, active, desired) in ((1, 0, false), (2, 0, false), (2, 1, false))
        sm = loop_at(false)
        CL.requested!(sm, OWNER, 1, 0, true)
        # Native busy rejection occurs before this observer. Seeing another
        # conflicting accepted request is an owner-observation inconsistency.
        @test CL.requested!(sm, OWNER, generation, active, desired) === nothing
        @test CL.state(sm) === :Unknown
        @test Hsm.current(sm) === :Unknown
        @test sm.failure !== nothing
        CL.observed!(sm, OWNER, 2, 2, false)
        CL.requested!(sm, OWNER, 3, 2, true)
        @test CL.state(sm) === :Unknown
    end
    sm = CL.Loop("correction:closed", OWNER)
    CL.requested!(sm, OWNER, 1, 0, true)
    @test sm.failure === :uninitialized_request
end

@testset "Contradictory applied snapshots cannot confirm closure" begin
    for (requested, active, closed) in
            ((1, 1, false), (2, 2, true), (1, 2, true), (-1, 0, true), (1, 0, true))
        sm = loop_at(false)
        CL.requested!(sm, OWNER, 1, 0, true)
        CL.observed!(sm, OWNER, requested, active, closed)
        @test CL.state(sm) === :Unknown
        @test Hsm.current(sm) === :Unknown
        @test sm.failure !== nothing
        CL.observed!(sm, OWNER, 1, 1, true)
        @test CL.state(sm) === :Unknown
    end
    sm = loop_at(true)
    CL.unknown!(sm)
    @test sm.failure === :unknown
    CL.unknown!(sm, :later_error)
    @test sm.failure === :unknown
    CL.observed!(sm, OWNER, 0, 0, true)
    @test CL.state(sm) === :Unknown
    # A replacement incarnation has its own independent initial observation.
    replacement = CL.Loop("correction:closed", OWNER + 1)
    CL.observed!(replacement, OWNER, 0, 0, true)
    @test CL.state(replacement) === :Unknown
    CL.observed!(replacement, OWNER + 1, 0, 0, true)
    @test CL.state(replacement) === :Closed
end

@testset "Typed native observer selects exact qualified Boolean properties" begin
    observer = CL.Observer(["tip-tilt:enabled", "woofer:enabled"], OWNER)
    @test_throws ArgumentError CL.check_ready(observer)
    initial = PipeWireAO.SPA.Props("tip-tilt:enabled" => true,
        "tip-tilt:requested-generation" => Int64(0), "tip-tilt:active-generation" => Int64(0),
        "woofer:enabled" => false,
        "woofer:requested-generation" => Int64(3), "woofer:active-generation" => Int64(3))
    @test observer(Val(:observed), initial) === nothing
    @test CL.check_ready(observer) === nothing
    @test CL.state.(observer.loops) == [:Closed, :Open]
    pending = PipeWireAO.SPA.Props("tip-tilt:enabled" => false,
        "tip-tilt:requested-generation" => Int64(1), "tip-tilt:active-generation" => Int64(0),
        "woofer:enabled" => false,
        "woofer:requested-generation" => Int64(3), "woofer:active-generation" => Int64(3))
    @test observer(Val(:requested), pending) === nothing
    @test CL.state.(observer.loops) == [:Opening, :Open]
    applied = PipeWireAO.SPA.Props("tip-tilt:enabled" => false,
        "tip-tilt:requested-generation" => Int64(1), "tip-tilt:active-generation" => Int64(1),
        "woofer:enabled" => false,
        "woofer:requested-generation" => Int64(3), "woofer:active-generation" => Int64(3))
    @test observer(Val(:observed), applied) === nothing
    @test CL.state.(observer.loops) == [:Open, :Open]
    for props in (loop_props(Int64(1)), loop_props(true; requested=Int32(0)),
            PipeWireAO.SPA.Props("correction:closed" => true),
            PipeWireAO.SPA.Props("correction:closed" => true, "correction:closed" => false,
                "correction:requested-generation" => Int64(0),
                "correction:active-generation" => Int64(0)))
        malformed = CL.Observer(["correction:closed"], OWNER)
        @test malformed(Val(:observed), props) === nothing
        @test CL.state(only(malformed.loops)) === :Unknown
        @test only(malformed.loops).failure === :observer_error
        @test_throws ArgumentError CL.check_ready(malformed)
        @test malformed(Val(:observed), loop_props(true)) === nothing
        @test CL.state(only(malformed.loops)) === :Unknown
    end
end
