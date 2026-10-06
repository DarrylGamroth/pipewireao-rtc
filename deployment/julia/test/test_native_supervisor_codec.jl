module NativeSupervisorCodecTests
using Test, PipeWireAO, PipeWireAODeployment
const C = PipeWireAODeployment.NativeSupervisorCodec
const N = PipeWireAODeployment.NativeControlClient
const E = PipeWireAODeployment.NativeControlCodec
const R = PipeWireAODeployment.NativeRunnerCodec
const A = PipeWireAODeployment.NativeAcquisitionLifecycleCodec
const H = PipeWireAODeployment.NativeHeartCodec
const SPA = PipeWireAO.SPA
const Pod = PipeWireAO.Pod
const identity = E.ControllerIdentity(UInt32(7), typemax(UInt64), Int64(11))
request(op) = E.RequestHeader(identity, Int64(42), Int64(op), UInt32(op), typemax(Int64))
reply(op; result=Int32(0)) = E.ReplyHeader(identity, Int64(42), Int64(op), UInt32(op), result)
ps(fields...) = SPA.Struct(Pod[fields...])
id(value) = Pod(SPA.Id(UInt32(value)))
const fixtures = normpath(joinpath(@__DIR__, "../../../tests/fixtures/native-supervisor"))
function fixture(name, pod)
    bytes = copy(pod.data)
    if get(ENV, "RTC_GENERATE_SUPERVISOR_FIXTURES", "") == "1"
        mkpath(fixtures); write(joinpath(fixtures, name * ".pod"), bytes)
    end
    @test bytes == read(joinpath(fixtures, name * ".pod"))
    return bytes
end
binding(name, profile, pid, gid, instance) = C.Binding(name, profile, UInt32(pid), UInt32(gid), typemax(UInt64), Int64(instance))
const runner_binding = binding("runner", "pipewireao.rtc.runner/1", 101, 21, 51)
const sim_binding = binding("source", "pipewireao.source-control/1", 102, 22, 1)
const heart_binding = binding("heart", "pipewireao.rtc.heart/1", 103, 23, 53)
const processes = [C.OwnedProcess("rtc", UInt32(101)), C.OwnedProcess("source", UInt32(102)), C.OwnedProcess("heart", UInt32(103))]
const empty_snapshot = C.Snapshot(C.OwnedProcess[], nothing, nothing, nothing)
function runner_record(op, outcome, details; lifecycle=R.Ready)
    pod = E.encode_completion(reply(op), ps(id(lifecycle), id(outcome), Pod(details)))
    decoded = R.decode_completion(pod)
    return C.RunnerRecord(decoded.lifecycle, decoded.result)
end
const status_record = runner_record(3, R.Observed,
    ps(Pod(true), Pod(Int64(-1)), Pod(Int64(2)), Pod(typemin(Int64)), Pod(ps(Pod(ps(Pod("sink"), Pod(Int64(-1))))))); lifecycle=R.Running)
const runner = C.RunnerObservation(runner_binding, Int64(91), "native-runner-instance:51", status_record)
const sim = C.SourceObservation(sim_binding, Int64(92), nothing, C.SimulatorSnapshot(
    Int32(1), Int64(1), Int32(3), Int64(92), Int32(0), Int64(4), Int64(5), true, false, Int64(4), Int64(3)))
const heart = C.HeartObservation(heart_binding, Int64(93), H.Ready,
    H.HeartSnapshot(Int64(1), UInt32(105), nothing, true, H.Streaming, true, true, "report.json", repeat("a",64)))
const admitted = C.Snapshot(processes, runner, sim, heart)
const cursor = A.AcquisitionCursor(typemax(UInt64), UInt64(1)<<63, typemax(UInt64), UInt64(1)<<63)

@testset "supervisor exact typed requests and shared fixtures" begin
    commands = [R.RunnerCommand(:quit), R.RunnerCommand(:groups), R.RunnerCommand(:status),
        R.RunnerCommand(:properties,"graph"), R.RunnerCommand(:property_generation,"graph","node"),
        R.RunnerCommand(:parameter_generation,"graph","node"), R.RunnerCommand(:stop_group,"group"),
        R.RunnerCommand(:start_group,"group"), R.RunnerCommand(:session_stop), R.RunnerCommand(:session_start),
        R.RunnerCommand(:source_ended), R.RunnerCommand(:reset), R.RunnerCommand(:properties_set,"graph",
            Dict("node.float"=>R.RunnerScalar(:float,UInt32(0x80000000)), "node.double"=>R.RunnerScalar(:double,UInt64(0x8000000000000000)),
                "node.long"=>R.RunnerScalar(:long,typemin(Int64)), "node.id"=>R.RunnerScalar(:id,typemax(UInt32)),
                "node.bool"=>R.RunnerScalar(:bool,true), "node.int"=>R.RunnerScalar(:int,typemin(Int32)), "node.string"=>R.RunnerScalar(:string,""))),
        R.RunnerCommand(:parameter,"graph","node.parameter","F32_LE",UInt32[2,3],"","matrix.f32")]
    for (op, command) in enumerate(commands)
        pod = N.encode_request(C.PROFILE, request(op), command)
        fixture("request-" * string(op), pod)
        header, decoded = N.decode_request(C.PROFILE, pod)
        @test header == request(op)
        @test N.encode_request(C.PROFILE, header, decoded).data == pod.data
    end
    @test N.profile_name(C.PROFILE) != N.profile_name(PipeWireAODeployment.NativeRunnerClient.RunnerProfile())
    @test N.lifecycle_type(C.PROFILE) === C.Phase
end
@testset "fresh typed combined status" begin
    for (name, phase, snapshot) in (("preparing", C.Preparing, empty_snapshot), ("simulator", C.Admitted, admitted))
        pod = C.encode_completion(reply(3), phase, phase === C.Admitted, snapshot)
        fixture("reply-status-" * name, pod)
        decoded = C.decode_completion(pod)
        @test decoded.lifecycle == phase
        @test C.encode_completion(decoded.header, decoded.lifecycle, decoded.admitted, decoded.snapshot).data == pod.data
        @test C.completion_size(reply(3), phase, phase === C.Admitted, snapshot) == sizeof(pod)
    end
    observed = C.decode_completion(C.encode_completion(reply(3),C.Admitted,true,admitted))
    @test observed.snapshot.runner.status.result.details.owned_nodes == typemax(UInt64)
    @test observed.snapshot.runner.status.result.details.discarded_buffers == UInt64(1)<<63
    @test observed.snapshot.source.snapshot.instance == 1
    @test observed.snapshot.source.snapshot.report_sequence == 3
    @test observed.snapshot.heart.snapshot.child_pid == 105
    for (kind, profile, phase, window) in (("calibration", A.CALIBRATION_PROFILE, "collected", nothing),
            ("correction", A.CORRECTION_PROFILE, "correcting", UInt64(1)<<63))
        b = binding("source", N.profile_name(profile),102,22,52)
        source = C.SourceObservation(b,Int64(92),A.Connected,A.Snapshot(A.Classic,cursor,cursor,true,false,phase,false,true,window))
        snapshot = C.Snapshot(processes,runner,source,heart)
        pod = C.encode_completion(reply(3),C.Admitted,true,snapshot)
        fixture("reply-status-" * kind,pod)
        decoded = C.decode_completion(pod)
        @test decoded.snapshot.source.snapshot.cursor.domain == typemax(UInt64)
        @test C.encode_completion(decoded.header,decoded.lifecycle,decoded.admitted,decoded.snapshot).data == pod.data
    end
end
@testset "typed operation results and failures" begin
    cases = [(1,R.Accepted,ps(Pod(true)),R.Ready), (2,R.Observed,ps(Pod(ps(Pod(ps(Pod("g"),id(1)))))),R.Ready),
        (4,R.Observed,ps(Pod("graph"),Pod(ps(Pod(ps(Pod("node.nan"),Pod(reinterpret(Float32,UInt32(0x7fc00001)))))))),R.Ready),
        (5,R.Observed,ps(Pod("graph"),Pod("node"),Pod(Int64(2)),Pod(nothing)),R.Ready),
        (6,R.Observed,ps(Pod("graph"),Pod("node"),Pod(Int64(2)),Pod(Int64(1))),R.Ready),
        (7,R.Requested,ps(Pod("g"),id(1),Pod(nothing)),R.Ready),
        (8,R.Requested,ps(Pod("g"),id(2),id(2)),R.Running),
        (9,R.Completed,ps(id(R.Ready)),R.Ready), (10,R.Completed,ps(id(R.Running)),R.Running),
        (11,R.Completed,ps(id(R.Ready)),R.Ready),(12,R.Completed,ps(id(R.Ready)),R.Ready),
        (13,R.Active,ps(Pod("graph"),Pod(ps(Pod(ps(Pod("node"),Pod(Int64(2)),Pod(Int64(2)))))),Pod(true)),R.Running),
        (14,R.Submitted,ps(Pod("graph"),Pod("node.param"),Pod(ps(Pod(Int64(3)),Pod(Int64(2)))),Pod(false)),R.Running)]
    for (op,outcome,details,lifecycle) in cases
        result = runner_record(op,outcome,details;lifecycle)
        pod = C.encode_completion(reply(op),C.Admitted,true,admitted,result)
        fixture("reply-operation-" * string(op),pod)
        decoded = C.decode_completion(pod)
        @test decoded.result.result.outcome == outcome
        @test C.completion_size(reply(op),C.Admitted,true,admitted,result) == sizeof(pod)
        @test C.encode_completion(decoded.header,decoded.lifecycle,decoded.admitted,decoded.snapshot,decoded.result).data == pod.data
    end
    negative = reply(10;result=Int32(-110))
    failure = C.encode_completion(negative,C.Failed,false,nothing,nothing,R.RunnerError("source","unknown outcome"))
    fixture("reply-failed",failure)
    @test C.decode_completion(failure).error.message == "unknown outcome"
    inner=runner_record(10,R.Completed,ps(id(R.Running));lifecycle=R.Running)
    partial=C.encode_completion(negative,C.Admitted,true,nothing,inner,R.RunnerError("source.state","resume rejected"))
    fixture("reply-failed-partial",partial)
    decoded=C.decode_completion(partial)
    @test decoded.result==inner&&decoded.snapshot===nothing&&decoded.error.field=="source.state"
    @test C.completion_size(negative,C.Admitted,true,nothing,inner,decoded.error)==sizeof(partial)
    with_snapshot=C.encode_completion(negative,C.Admitted,true,admitted,inner,decoded.error)
    @test C.decode_completion(with_snapshot).snapshot.runner.status.result.details==admitted.runner.status.result.details
    old=E.encode_completion(negative,ps(id(C.Admitted),Pod(true),Pod("source.state"),Pod("old grammar")))
    fixture("bad-reply-negative-old-grammar",old)
    @test_throws ArgumentError C.decode_completion(old)
    wrongphase=E.encode_completion(negative,ps(id(C.Preparing),Pod(false),Pod(nothing),
        Pod(ps(Pod("source"),Pod("bad phase"),Pod(C._record_pod(inner,UInt32(10)))))))
    fixture("bad-reply-partial-phase",wrongphase)
    @test_throws ArgumentError C.decode_completion(wrongphase)
    wrongop=E.encode_completion(reply(9;result=Int32(-5)),C._completion_payload(negative,C.Admitted,true,nothing,inner,decoded.error))
    fixture("bad-reply-partial-operation",wrongop)
    @test_throws ArgumentError C.decode_completion(wrongop)
    rejected = C.encode_rejection(reply(10;result=Int32(-16)),C.Preparing,false)
    fixture("rejection",rejected)
    @test C.decode_rejection(rejected).lifecycle == C.Preparing
    sentinel = C.encode_rejection(E.ReplyHeader(Int64(42),Int32(-22)),C.Preparing,false)
    fixture("rejection-sentinel",sentinel)
    @test C.decode_rejection(sentinel).header.controller === nothing
end
function bad_status(name, payload)
    pod = E.encode_completion(reply(3),payload)
    fixture("bad-reply-" * name,pod)
    @test_throws ArgumentError C.decode_completion(pod)
end
@testset "semantic rejection before effects" begin
    raw = C._completion_payload(reply(3),C.Admitted,true,admitted,nothing,nothing)
    wrong = copy(raw.values); wrong[2]=Pod(false); bad_status("phase",SPA.Struct(wrong))
    wrong = copy(raw.values); wrong[1]=id(99); bad_status("phase-id",SPA.Struct(wrong))
    no_runner=C._snapshot_pod(C.Snapshot(processes,nothing,nothing,nothing))
    bad_status("missing-runner",ps(id(C.Admitted),Pod(true),Pod(no_runner),Pod(nothing)))
    dup=C._snapshot_pod(C.Snapshot([processes[1],processes[1]],runner,nothing,nothing))
    bad_status("duplicate-process",ps(id(C.Admitted),Pod(true),Pod(dup),Pod(nothing)))
    bad_status("preparing-owners",ps(id(C.Preparing),Pod(false),raw.values[3],Pod(nothing)))
    nested = C._snapshot_pod(admitted).values
    source = C._source_pod(sim).values
    source[2] = Pod(Int64(90)); nested[3]=Pod(SPA.Struct(source))
    bad_status("source-token",ps(id(C.Admitted),Pod(true),Pod(SPA.Struct(nested)),Pod(nothing)))
    nested=C._snapshot_pod(admitted).values
    r=C._runner_pod(runner).values;r[2]=Pod(Int64(0));nested[2]=Pod(SPA.Struct(r))
    bad_status("runner-token",ps(id(C.Admitted),Pod(true),Pod(SPA.Struct(nested)),Pod(nothing)))
    nested=C._snapshot_pod(admitted).values
    r=C._runner_pod(runner).values;b=C._binding_pod(runner_binding).values;b[2]=Pod(N.profile_name(C.PROFILE));r[1]=Pod(SPA.Struct(b));nested[2]=Pod(SPA.Struct(r))
    bad_status("runner-profile",ps(id(C.Admitted),Pod(true),Pod(SPA.Struct(nested)),Pod(nothing)))
    @test_throws ArgumentError C.validate_snapshot(C.Admitted,true,C.Snapshot([C.OwnedProcess("rtc",UInt32(999))],runner,nothing,nothing))
    @test_throws ArgumentError C.encode_completion(reply(3),C.Admitted,true,admitted,status_record)
    @test_throws ArgumentError C.encode_completion(reply(10),C.Preparing,false,empty_snapshot)
    @test C.validate_admission(C.Preparing,R.RunnerCommand(:status)) isa R.RunnerCommand{:status}
    @test_throws ArgumentError C.validate_admission(C.Preparing,R.RunnerCommand(:session_start))
    @test_throws ArgumentError C.encode_completion(reply(3),C.Preparing,true,empty_snapshot)
    @test_throws ArgumentError C.encode_completion(E.ReplyHeader(Int64(42),Int32(0)),C.Preparing,false,empty_snapshot)
    many=C.Snapshot([C.OwnedProcess("role$i",UInt32(i)) for i in 1:33],nothing,nothing,nothing)
    @test_throws ArgumentError C.validate_snapshot(C.Failed,false,many)
    enormous=runner_record(4,R.Observed,ps(Pod("g"),Pod(ps(Pod(ps(Pod("text"),Pod(repeat("x",64_500))))))))
    @test_throws ArgumentError C.encode_completion(reply(4),C.Admitted,true,admitted,enormous)
    long_record=runner_record(4,R.Observed,ps(Pod("g"),Pod(ps(Pod(ps(Pod("text"),Pod(repeat("x",20_000))))))))
    long_reply=C.encode_completion(reply(4),C.Admitted,true,admitted,long_record)
    @test C.decode_completion(long_reply).result.result.details.properties["text"].value == repeat("x",20_000)
    @test C.completion_size(reply(4),C.Admitted,true,admitted,long_record) == sizeof(long_reply)
    malformed=E.encode_request(request(14),ps(Pod("g"),Pod("p"),Pod("F32_LE"),Pod(SPA.Array(Float32[1])),Pod(""),Pod("matrix")))
    fixture("bad-request-dimension-type",malformed)
    @test_throws ArgumentError N.decode_request(C.PROFILE,malformed)
    malformed=E.encode_request(request(13),ps(Pod("g"),Pod(ps(Pod(ps(Pod("p"),Pod(Float32(Inf))))))))
    fixture("bad-request-nonfinite",malformed)
    @test_throws ArgumentError N.decode_request(C.PROFILE,malformed)
end
@testset "mutation reply capacity before effects" begin
    commands = [R.RunnerCommand(:quit), R.RunnerCommand(:groups), R.RunnerCommand(:status),
        R.RunnerCommand(:properties,"graph"), R.RunnerCommand(:property_generation,"graph","node"),
        R.RunnerCommand(:parameter_generation,"graph","node"), R.RunnerCommand(:stop_group,"group"),
        R.RunnerCommand(:start_group,"group"), R.RunnerCommand(:session_stop), R.RunnerCommand(:session_start),
        R.RunnerCommand(:source_ended), R.RunnerCommand(:reset), R.RunnerCommand(:properties_set,"graph",
            Dict("node:gain"=>R.RunnerScalar(:float,UInt32(0)), "node:pole"=>R.RunnerScalar(:float,UInt32(0)),
                "second:gain"=>R.RunnerScalar(:float,UInt32(0)))),
        R.RunnerCommand(:parameter,"graph","node:parameter","F32_LE",UInt32[2,3],"","matrix.f32")]
    for (op, command) in enumerate(commands)
        if op in (2,3,4,5,6)
            @test_throws ArgumentError C.preflight_mutation_reply(command,admitted)
        else
            @test C.preflight_mutation_reply(command,admitted) <= 64*1024
            probe_bound=64*1024-24576
            reserve=C.preflight_mutation_reply(command,admitted;snapshot_bound=probe_bound)
            overhead=reserve-probe_bound
            max_bound=64*1024-overhead
            @test C.preflight_mutation_reply(command,admitted;snapshot_bound=max_bound) == 64*1024
            @test_throws ArgumentError C.preflight_mutation_reply(command,admitted;snapshot_bound=max_bound+1)
            @test_throws ArgumentError C.preflight_mutation_reply(command,admitted;snapshot_bound=1)
        end
    end
    @test_throws ArgumentError C.preflight_mutation_reply(R.RunnerCommand(:quit),empty_snapshot)
    @test_throws ArgumentError C.preflight_mutation_reply(R.RunnerCommand(:properties_set,"g",
        Dict("unqualified"=>R.RunnerScalar(:float,UInt32(0)))),admitted)
    wide=R.RunnerCommand(:properties_set,"g",Dict("node$i:gain"=>R.RunnerScalar(:float,UInt32(0)) for i in 1:42))
    @test C.preflight_mutation_reply(wide,admitted) <= 64*1024
    oversized=R.RunnerCommand(:properties_set,"g",Dict("node$i:gain"=>R.RunnerScalar(:float,UInt32(0)) for i in 1:43))
    @test_throws ArgumentError C.preflight_mutation_reply(oversized,admitted)
end

end
