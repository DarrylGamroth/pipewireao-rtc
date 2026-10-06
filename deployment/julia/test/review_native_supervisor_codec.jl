# Independent review discriminators for foundation revision 2a78a31.
# Run explicitly; this file does not require a PipeWire core or owner effects.
module NativeSupervisorReview
using Test, PipeWireAO, PipeWireAODeployment
const C = PipeWireAODeployment.NativeSupervisorCodec
const N = PipeWireAODeployment.NativeControlClient
const E = PipeWireAODeployment.NativeControlCodec
const R = PipeWireAODeployment.NativeRunnerCodec
const fixture_dir = joinpath(@__DIR__, "../../../tests/fixtures/native-supervisor")
const status = C.decode_completion(read(joinpath(fixture_dir, "reply-status-simulator.pod")))
const snapshot = status.snapshot
const h = status.header

@testset "supervisor profile exact reply selection" begin
    pending = E.RequestHeader(h.controller, h.endpoint_instance, h.token, h.operation, Int64(1000))
    c = h.controller
    wrong_headers = [
        E.ReplyHeader(E.ControllerIdentity(c.global_id + UInt32(1), c.serial, c.instance), h.endpoint_instance, h.token, h.operation, Int32(0)),
        E.ReplyHeader(E.ControllerIdentity(c.global_id, c.serial - UInt64(1), c.instance), h.endpoint_instance, h.token, h.operation, Int32(0)),
        E.ReplyHeader(E.ControllerIdentity(c.global_id, c.serial, c.instance + 1), h.endpoint_instance, h.token, h.operation, Int32(0)),
        E.ReplyHeader(c, h.endpoint_instance, h.token - 1, h.operation, Int32(0)),
    ]
    now = N.monotonic()
    for wrong in wrong_headers
        observation = N.Observation(C.PROFILE, h.endpoint_instance, UInt32(101))
        observation.pending = pending
        N.observe!(observation, C.encode_completion(wrong, C.Admitted, true, snapshot); at=now)
        @test observation.fatal_failure === nothing
        @test observation.matched_completion === nothing
        @test N.matching_reply(observation, now + 60) === nothing
    end
    changed = E.ReplyHeader(c, h.endpoint_instance + 1, h.token, h.operation, Int32(0))
    observation = N.Observation(C.PROFILE, h.endpoint_instance, UInt32(101))
    observation.pending = pending
    N.observe!(observation, C.encode_completion(changed, C.Admitted, true, snapshot); at=now)
    @test_throws N.UnknownOutcome N.matching_reply(observation, now + 60)
    observation = N.Observation(C.PROFILE, h.endpoint_instance, UInt32(101))
    observation.pending = pending
    pod = C.encode_completion(h, C.Admitted, true, snapshot)
    N.observe!(observation, pod; at=now)
    N.observe!(observation, pod; at=now + 1)
    @test observation.matched_completion.at == now
    @test N.matching_reply(observation, now + 0.5).header == h
    late = N.Observation(C.PROFILE, h.endpoint_instance, UInt32(101))
    late.pending = pending
    late_start = N.monotonic()
    N.observe!(late, pod; at=late_start + 120)
    @test N.matching_reply(late, late_start + 60) === nothing
end

@testset "actual maximal property result fits reservation" begin
    nodes = [repeat("μ", 50) * string(i) for i in 1:42]
    command = R.RunnerCommand(:properties_set, "graph", Dict(n * ":gain" => R.RunnerScalar(:long, Int64(1)) for n in nodes))
    rows = [(node=n, requested=Int64(9), active=Int64(9)) for n in nodes]
    result = C.RunnerRecord(R.Running, R._result(UInt32(13), R.Active,
        (graph="graph", generations=rows, active_adoption_observed=true)))
    header = E.ReplyHeader(h.controller, h.endpoint_instance, h.token, UInt32(13), Int32(0))
    # Increase a real encoded Status catalog; do not rely solely on the helper's
    # own arithmetic to calculate a synthetic future bound.
    old = snapshot.runner
    details = merge(old.status.result.details, (discarded_by_sink=Dict(repeat("s", 55000) => UInt64(1)),))
    large_runner = C.RunnerObservation(old.binding, old.token, old.session_id,
        C.RunnerRecord(R.Running, R._result(UInt32(3), R.Observed, details)))
    large = C.Snapshot(snapshot.processes, large_runner, snapshot.source, snapshot.heart)
    pod = C.encode_completion(header, C.Admitted, true, large, result)
    reserved = C.preflight_mutation_reply(command, large)
    @test reserved == sizeof(pod)
    @test C.completion_size(header, C.Admitted, true, large, result) == sizeof(pod)
    @test C.decode_completion(pod).result.result.outcome == R.Active
    @test length(C.decode_completion(pod).result.result.details.generations) == 42
    @test_throws ArgumentError C.preflight_mutation_reply(command, large; snapshot_bound=C._snapshot_size(large)-1)
end
end
