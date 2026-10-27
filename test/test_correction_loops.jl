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

function correction_status(props::PipeWireAO.SPA.Props, name, ::Type{T}) where {T}
    return PipeWireAO.pod_value(T, only(pod for (key, pod) in props.values
        if key == "pipewireao.correction-control." * name))
end

@testset "Correction-control publication reuses exact graph properties" begin
    now = Ref(UInt64(100))
    observer = CL.Observer(["correction:closed"], OWNER; clock=() -> now[])
    infos = CL.property_info(observer)
    names = [info.name for info in infos]
    @test names == ["pipewireao.correction-control.version",
        "pipewireao.correction-control.owner-instance",
        "pipewireao.correction-control.correction:closed.state",
        "pipewireao.correction-control.correction:closed.fault",
        "pipewireao.correction-control.correction:closed.requested"]
    @test all(info -> info.flags == PipeWireAO.SPA.PROPERTY_READONLY, infos)
    @test all(info -> info.params, infos)
    @test getfield.(infos, :group) == ["Correction control", "Correction control",
        "Correction control/correction:closed", "Correction control/correction:closed",
        "Correction control/correction:closed"]
    @test getfield.(infos, :display_name) ==
        ["Control version", "Owner instance", "State", "Fault", "Requested closed"]
    @test PipeWireAO.pod_value(Int32, infos[1].type) === Int32(1)
    @test PipeWireAO.pod_value(Int64, infos[2].type) === OWNER
    @test PipeWireAO.pod_value(String, infos[3].type) == "Unknown"
    @test PipeWireAO.pod_value(String, infos[4].type) == ""
    @test PipeWireAO.pod_value(Bool, infos[5].type) === false

    initial = observer(loop_props(true), true)
    @test first.(initial.values) == names
    @test correction_status(initial, "version", Int32) === Int32(1)
    @test correction_status(initial, "owner-instance", Int64) === OWNER
    @test correction_status(initial, "correction:closed.state", String) == "Closed"
    @test correction_status(initial, "correction:closed.fault", String) == ""
    @test correction_status(initial, "correction:closed.requested", Bool) === true
    @test CL.check_ready(observer) === nothing
    observer(Val(:requested), loop_props(false; requested=1, active=0))
    pending = observer(loop_props(true; requested=1, active=0), true)
    @test correction_status(pending, "correction:closed.state", String) == "Opening"
    @test correction_status(pending, "correction:closed.requested", Bool) === false
    @test_throws ArgumentError CL.check_ready(observer)
    # The getter reconciles this supplied applied snapshot; it must not publish
    # cached Opening after the target has coherently adopted this generation.
    applied = observer(loop_props(false; requested=1), true)
    @test correction_status(applied, "correction:closed.state", String) == "Open"
    @test correction_status(applied, "correction:closed.fault", String) == ""
    @test all(name -> !startswith(name, "correction:"), first.(applied.values))
end

@testset "Closure adoption expires before late confirmation" begin
    for (initial, desired, pending) in ((false, true, :Closing), (true, false, :Opening))
        now = Ref(UInt64(70))
        observer = CL.Observer(["correction:closed"], OWNER;
            timeout_ms=5, clock=() -> now[])
        observer(Val(:observed), loop_props(initial))
        observer(Val(:requested), loop_props(desired; requested=1, active=0))
        sm = only(observer.loops)
        @test CL.state(sm) === pending
        @test sm.pending_since_ns == 70
        now[] += UInt64(4_000_000)
        observer(Val(:requested), loop_props(desired; requested=1, active=0))
        @test sm.pending_since_ns == 70
        observer(Val(:observed), loop_props(initial; requested=1, active=0))
        @test CL.state(sm) === pending
        now[] += UInt64(1_000_000)
        late = observer(loop_props(desired; requested=1), true)
        @test sm.failure === :adoption_timeout
        @test CL.state(sm) === :Unknown
        @test Hsm.current(sm) === :Unknown
        @test sm.active_generation == 0
        @test correction_status(late, "correction:closed.state", String) == "Unknown"
        @test correction_status(late, "correction:closed.fault", String) ==
            "Applied correction did not confirm before the adoption timeout"
        @test correction_status(late, "correction:closed.requested", Bool) === desired
        now[] += UInt64(1)
        observer(Val(:observed), loop_props(desired; requested=1))
        observer(Val(:requested), loop_props(initial; requested=2, active=1))
        @test CL.state(sm) === :Unknown
        @test sm.failure === :adoption_timeout
        @test_throws ArgumentError CL.check_ready(observer)
    end
end

@testset "Pending-state entry and exit own the adoption deadline" begin
    now = Ref(UInt64(70))
    for (initial, desired) in ((false, true), (true, false))
        sm = CL.Loop("correction:closed", OWNER; clock=() -> now[], timeout_ms=5)
        CL.observed!(sm, OWNER, 0, 0, initial)
        @test sm.pending_since_ns == 0
        # Direct machine events, without the Observer callback, must run the
        # same entry/exit behaviors as RTC property observation.
        CL.requested!(sm, OWNER, 1, 0, desired)
        @test sm.pending_since_ns == now[]
        now[] += UInt64(1)
        CL.requested!(sm, OWNER, 1, 0, desired)
        @test sm.pending_since_ns == now[] - 1
        CL.observed!(sm, OWNER, 1, 1, desired)
        @test sm.pending_since_ns == 0
        CL.requested!(sm, OWNER, 2, 1, desired)
        @test sm.pending_since_ns == 0
        CL.observed!(sm, OWNER, 2, 2, desired)
        CL.requested!(sm, OWNER, 3, 2, initial)
        @test sm.pending_since_ns == now[]
        CL.unknown!(sm, :observer_error)
        @test sm.pending_since_ns == 0
    end
end

@testset "Timely adoption and same-Boolean updates do not expire" begin
    now = Ref(UInt64(0))
    observer = CL.Observer(["correction:closed"], OWNER;
        timeout_ms=1, clock=() -> now[])
    observer(Val(:observed), loop_props(false))
    observer(Val(:requested), loop_props(true; requested=1, active=0))
    now[] = UInt64(999_999)
    timely = observer(loop_props(true; requested=1), true)
    @test correction_status(timely, "correction:closed.state", String) == "Closed"
    now[] = UInt64(10_000_000)
    @test correction_status(observer(loop_props(true; requested=1), true),
        "correction:closed.state", String) == "Closed"
    observer(Val(:requested), loop_props(true; requested=2, active=1))
    now[] = UInt64(100_000_000)
    gain_pending = observer(loop_props(true; requested=2, active=1), true)
    @test correction_status(gain_pending, "correction:closed.state", String) == "Closed"
    @test only(observer.loops).failure === nothing
    observer(Val(:observed), loop_props(true; requested=2))
    @test CL.check_ready(observer) === nothing
    # UInt64 elapsed subtraction also covers the monotonic clock wrapping.
    now[] = typemax(UInt64) - UInt64(50)
    observer(Val(:requested), loop_props(false; requested=3, active=2))
    now[] += UInt64(999_999)
    @test correction_status(observer(loop_props(true; requested=3, active=2), true),
        "correction:closed.state", String) == "Opening"
    now[] += UInt64(1)
    @test correction_status(observer(loop_props(false; requested=3), true),
        "correction:closed.state", String) == "Unknown"
    @test only(observer.loops).failure === :adoption_timeout
end

@testset "Unavailable or malformed observation publishes a latched fault" begin
    now = Ref(UInt64(0))
    observer = CL.Observer(["correction:closed"], OWNER; clock=() -> now[])
    observer(Val(:observed), loop_props(true))
    unavailable = observer(loop_props(true), false)
    @test correction_status(unavailable, "correction:closed.state", String) == "Unknown"
    @test correction_status(unavailable, "correction:closed.fault", String) ==
        "Authoritative property observation is unavailable"
    @test correction_status(unavailable, "correction:closed.requested", Bool) === true
    @test only(observer.loops).failure === :observer_unavailable
    @test correction_status(observer(loop_props(true), true),
        "correction:closed.state", String) == "Unknown"
    for props in (loop_props(Int64(1)), loop_props(true; active=Int32(0)),
            PipeWireAO.SPA.Props("correction:closed" => true))
        malformed = CL.Observer(["correction:closed"], OWNER; clock=() -> now[])
        malformed(Val(:observed), loop_props(false))
        status = malformed(props, true)
        @test correction_status(status, "correction:closed.state", String) == "Unknown"
        @test correction_status(status, "correction:closed.fault", String) ==
            "Authoritative property observation failed or was malformed"
        @test correction_status(status, "correction:closed.requested", Bool) === false
        @test only(malformed.loops).failure === :observer_error
    end
end

@testset "Adoption timeout and clock contracts are bounded" begin
    for timeout_ms in (0, -1, 60_001, true, typemax(Int128))
        @test_throws ArgumentError CL.Observer(["correction:closed"], OWNER; timeout_ms)
    end
    @test CL.Observer(["correction:closed"], OWNER).timeout_ns == UInt64(5_000_000_000)
    @test CL.Observer(["correction:closed"], OWNER; timeout_ms=60_000).timeout_ns ==
        UInt64(60_000_000_000)
    for clock in (() -> -1, () -> true, () -> 1.5, () -> typemax(UInt128))
        @test_throws ArgumentError CL.Observer(["correction:closed"], OWNER; clock)
    end
    now = Ref(Int64(0))
    observer = CL.Observer(["correction:closed"], OWNER; clock=() -> now[])
    observer(Val(:observed), loop_props(true))
    now[] = -1
    @test observer(Val(:requested), loop_props(false; requested=1, active=0)) === nothing
    @test only(observer.loops).failure === :observer_error
    @test correction_status(observer(loop_props(true), true),
        "correction:closed.state", String) == "Unknown"
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
