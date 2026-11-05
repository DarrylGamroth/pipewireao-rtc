module RecoveryObservationTests
using Test, PipeWireAORTC
const R = PipeWireAORTC.CorrectionRecovery

# A native adapter may store the same evidence in another layout. Exercise the
# documented interface through the actual Hsm rather than forwarding its fields.
struct Readback{I,G,A,V} <: R.AbstractLoopObservation
    identity::I
    requested::G
    applied::A
    value::V
end
R.owner_instance(o::Readback) = o.identity[1]
R.operation_token(o::Readback) = o.identity[2]
R.observation_serial(o::Readback) = o.identity[3]
R.requested_generation(o::Readback) = o.requested
R.active_generation(o::Readback) = o.applied
R.closed(o::Readback) = o.value
readback(serial, requested, active, closed; token=UInt64(17)) =
    Readback((Int64(801), token, UInt64(serial)), requested, active, closed)

@testset "Controller scope validates evidence without depending on record storage" begin
    for o in (R.LoopObservation(Int64(801), UInt64(0), UInt64(1), UInt64(3), UInt64(3), true),
            R.LoopObservation{Any,Any}(801, 0, 1, UInt64(3), UInt64(3), true),
            readback(1, UInt64(3), UInt64(3), true; token=UInt64(0)))
        @test R.controller_scope(o) === R.SingleController()
        @test R.generations_match(o) && R.all_closed(o) && !R.all_open(o)
        sm = R.Coordinator(Int64(801); clock=()->UInt64(100))
        R.qualify!(sm, o)
        @test R.state(sm) === :Closed && sm.serial == 1
    end
    group = readback(1, (UInt64(3), UInt64(9)), (UInt64(3), UInt64(9)), (true, false))
    @test R.controller_scope(group) === R.CoupledControllers{2}()
    @test !R.all_open(group) && !R.all_closed(group)
    one = readback(1, (UInt64(3),), (UInt64(3),), (true,))
    @test !R.same_scope(one, readback(1, UInt64(3), UInt64(3), true))
    for o in (readback(1, UInt64(3), Int64(3), true),
            readback(1, (UInt64(3), UInt64(9)), (UInt64(3),), (true, false)),
            readback(1, (UInt64(3), UInt64(9)), (UInt64(3), UInt64(9)), (true,)),
            readback(1, UInt64(3), UInt64(3), 1))
        @test R.controller_scope(o) === nothing
        @test !R.generations_match(o) && !R.all_open(o) && !R.all_closed(o)
    end
    malformed = R.LoopObservation{Any,Any}(801, 0, 1, UInt64(3), Int64(3), true)
    sm = R.Coordinator(Int64(801); clock=()->UInt64(100))
    R.qualify!(sm, malformed)
    @test R.state(sm) === :Unverified && sm.failure === :loop_scope_mismatch
    @test sm.serial == 0
end

@testset "Coupled ordering is partial, including crossed and boundary generations" begin
    bound = (UInt64(4), UInt64(10))
    cases = (
        ((3, 9), true, true, false),
        ((4, 9), true, true, false),
        ((4, 10), false, true, true),
        ((5, 10), false, false, true),
        ((5, 9), false, false, false),
        ((3, 11), false, false, false),
        ((0, 0), true, true, false),
        ((typemax(UInt64), typemax(UInt64)), false, false, true))
    for (values, before, at_most, at_least) in cases
        generations = map(UInt64, values)
        o = readback(2, generations, generations, (false, false))
        @test R.requested_before(o, bound) == before
        @test R.active_before(o, bound) == before
        @test R.active_at_most(o, bound) == at_most
        @test R.active_at_least(o, bound) == at_least
    end
    o = readback(2, UInt64(3), UInt64(4), false)
    @test R.requested_before(o, UInt64(4))
    @test !R.active_before(o, UInt64(4))
    @test R.active_at_most(o, UInt64(4)) && R.active_at_least(o, UInt64(4))
end

@testset "Accessor-backed observations drive the full recovery protocol" begin
    sm = R.Coordinator(Int64(801); clock=()->UInt64(100))
    R.qualify!(sm, readback(1, UInt64(3), UInt64(3), true; token=UInt64(0)))
    stage = R.request_protection!(sm, Int64(801), UInt64(17))
    R.recovery_staged!(sm, stage, UInt64(11); loop_generation=UInt64(4))
    R.observe_loop!(sm, readback(2, UInt64(4), UInt64(4), false))
    @test R.state(sm) === :RestoringReference
    R.observe_recovery!(sm, R.RecoveryObservation(801, 17, 3, 11, 11, :applied, true))
    R.observe_reference!(sm, R.ReferenceObservation(801, 17, 4, 11, true, true, true))
    @test R.state(sm) === :Holding
    @test R.request_close!(sm, Int64(801), UInt64(17)) isa R.ReleaseRecovery
    close = R.observe_release!(sm, R.ReleaseObservation(Int64(801), UInt64(17), UInt64(5), UInt64(11), true, false, true, true, true))
    R.staged!(sm, close, UInt64(5))
    R.observe_loop!(sm, readback(6, UInt64(5), UInt64(5), true))
    @test R.state(sm) === :Closed && sm.failure === nothing && sm.serial == 6
end

@testset "Malformed loop evidence and release preserve distinct serial boundaries" begin
    sm = R.Coordinator(Int64(801); clock=()->UInt64(100))
    R.qualify!(sm, readback(1, UInt64(3), UInt64(3), true; token=UInt64(0)))
    stage = R.request_protection!(sm, Int64(801), UInt64(17))
    R.recovery_staged!(sm, stage, UInt64(11); loop_generation=UInt64(4))
    R.observe_loop!(sm, readback(2, UInt64(4), Int64(4), false))
    @test sm.failure === :loop_scope_mismatch && sm.serial == 1

    sm = R.Coordinator(Int64(801); clock=()->UInt64(100))
    R.qualify!(sm, readback(1, UInt64(3), UInt64(3), true; token=UInt64(0)))
    stage = R.request_protection!(sm, Int64(801), UInt64(17))
    R.recovery_staged!(sm, stage, UInt64(11); loop_generation=UInt64(4))
    R.observe_loop!(sm, readback(2, UInt64(4), UInt64(4), false))
    R.observe_recovery!(sm, R.RecoveryObservation(801, 17, 3, 11, 11, :applied, true))
    R.observe_reference!(sm, R.ReferenceObservation(801, 17, 4, 11, true, true, true))
    R.request_close!(sm, Int64(801), UInt64(17))
    R.observe_release!(sm, R.ReleaseObservation(Int64(801), UInt64(17), UInt64(5), UInt64(11), true, (false,), true, true, true))
    @test sm.failure === :loop_scope_mismatch && sm.serial == 5
end
end
