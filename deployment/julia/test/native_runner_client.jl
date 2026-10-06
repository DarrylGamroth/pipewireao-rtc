using Test
using PipeWireAO
using SHA

# Exercise the new modules before package wiring is selected by the parent.
module RunnerClientModules
include(joinpath(@__DIR__, "..", "src", "native_control_codec.jl"))
include(joinpath(@__DIR__, "..", "src", "native_runner_codec.jl"))
include(joinpath(@__DIR__, "..", "src", "native_runner_client.jl"))
end
const ClientEnvelope = RunnerClientModules.NativeControlCodec
const ClientCodec = RunnerClientModules.NativeRunnerCodec
const RunnerClient = RunnerClientModules.NativeRunnerClient
const ClientSPA = PipeWireAO.SPA

include(joinpath(@__DIR__, "native_control_private_core.jl"))

const TEST_CONTROLLER = ClientEnvelope.ControllerIdentity(UInt32(42), typemax(UInt64), Int64(9))
test_header(token=1, operation=3) = ClientEnvelope.RequestHeader(TEST_CONTROLLER, Int64(23),
    Int64(token), UInt32(operation), Int64(1_000_000_000))
test_observation() = RunnerClient.Observation(Int64(23), UInt32(getpid()))

function test_capability(; version=Int32(1), instance=Int64(23), token=Int64(0),
        controllers=[TEST_CONTROLLER])
    rows = ClientSPA.Struct(Pod[Pod(ClientSPA.Struct(Pod(ClientSPA.Id(identity.global_id)),
        Pod(reinterpret(Int64, identity.serial)), Pod(identity.instance))) for identity in controllers])
    return Pod(props_param(ClientSPA.Props(
        RunnerClient.CAP_NAMES[1] => version, RunnerClient.CAP_NAMES[2] => instance,
        RunnerClient.CAP_NAMES[3] => ClientSPA.Id(getpid()),
        RunnerClient.CAP_NAMES[4] => ClientSPA.Id(3), RunnerClient.CAP_NAMES[5] => token,
        RunnerClient.CAP_NAMES[6] => rows)))
end

function test_completion(; token=1, links=Int64(2), controller=TEST_CONTROLLER)
    header = ClientEnvelope.ReplyHeader(controller, Int64(23), Int64(token), UInt32(3), Int32(0))
    details = ClientSPA.Struct(Pod(false), Pod(Int64(0)), Pod(links), Pod(Int64(0)), Pod(ClientSPA.Struct()))
    payload = ClientSPA.Struct(Pod(ClientSPA.Id(3)), Pod(ClientSPA.Id(2)), Pod(details))
    return ClientEnvelope.encode_completion(header, payload)
end

function test_rejection(; token=1)
    header = ClientEnvelope.ReplyHeader(TEST_CONTROLLER, Int64(23), Int64(token), UInt32(3), Int32(-114))
    return ClientEnvelope.encode_rejection(header,
        ClientSPA.Struct(Pod("token"), Pod("collision"), Pod(ClientSPA.Id(3))))
end

@testset "native runner client bounded observations" begin
    observation = test_observation()
    RunnerClient.observe!(observation, test_capability())
    RunnerClient.observe!(observation, ClientEnvelope.encode_completion(
        ClientEnvelope.ReplyHeader(Int64(23), Int32(0)), ClientSPA.Struct()))
    RunnerClient.observe!(observation, ClientEnvelope.encode_rejection(
        ClientEnvelope.ReplyHeader(Int64(23), Int32(-61)),
        ClientSPA.Struct(Pod("initial"), Pod("no rejected request"), Pod(ClientSPA.Id(3)))))
    @test observation.failure === nothing
    @test observation.completion_seen && observation.rejection_seen
    @test observation.capability.controllers == [TEST_CONTROLLER]
    @test observation.completion === nothing
    @test observation.matched_completion === nothing

    for pod in (test_capability(version=Int64(1)), test_capability(instance=Int64(24)),
            test_capability(token=Int64(-1)), test_capability(controllers=fill(TEST_CONTROLLER, 2)),
            test_capability(controllers=fill(TEST_CONTROLLER, 33)))
        invalid = test_observation()
        RunnerClient.observe!(invalid, pod)
        @test invalid.fatal_failure !== nothing
    end
    pairs = ClientSPA.Props(test_capability()).values
    duplicate = copy(pairs)
    duplicate[2] = pairs[1]
    wrong_pid = copy(pairs)
    wrong_pid[3] = RunnerClient.CAP_NAMES[3] => Pod(Int64(getpid()))
    wrong_state = copy(pairs)
    wrong_state[4] = RunnerClient.CAP_NAMES[4] => Pod(ClientSPA.Id(6))
    bad_rows = copy(pairs)
    bad_rows[6] = RunnerClient.CAP_NAMES[6] => Pod(ClientSPA.Struct(Pod(Int64(42))))
    for fields in (pairs[1:end-1], [pairs; "unexpected" => Pod(Int32(1))],
            duplicate, wrong_pid, wrong_state, bad_rows)
        invalid = test_observation()
        RunnerClient.observe!(invalid, Pod(props_param(ClientSPA.Props(fields))))
        @test invalid.fatal_failure !== nothing
    end
    identities = [ClientEnvelope.ControllerIdentity(UInt32(i), UInt64(i), Int64(i)) for i in 1:32]
    bound = test_observation()
    RunnerClient.observe!(bound, test_capability(controllers=identities))
    @test length(bound.capability.controllers) == 32
    RunnerClient.observe!(bound, test_capability(token=Int64(9)))
    RunnerClient.observe!(bound, test_capability(token=Int64(8)))
    @test bound.max_accepted == 9 && bound.capability.last_token == 9

    now = RunnerClient.monotonic()
    observation = test_observation()
    observation.pending = test_header()
    RunnerClient.observe!(observation, test_completion(); at=now)
    RunnerClient.observe!(observation, test_completion(); at=now + 3)
    @test observation.matched_completion.at == now
    @test RunnerClient.matching_reply(observation, now + 1) isa ClientCodec.Completion
    RunnerClient.observe!(observation, test_rejection(); at=now + 4)
    @test RunnerClient.matching_reply(observation, now + 1) isa ClientCodec.Completion

    observed_then_removed = test_observation()
    observed_then_removed.pending = test_header()
    RunnerClient.observe!(observed_then_removed, test_completion(); at=now)
    RunnerClient.fail!(observed_then_removed, "removed"; at=now + 1, retirement=true)
    @test RunnerClient.matching_reply(observed_then_removed, now + 2) isa ClientCodec.Completion
    removed_then_observed = test_observation()
    removed_then_observed.pending = test_header()
    RunnerClient.fail!(removed_then_observed, "removed"; at=now, retirement=true)
    RunnerClient.observe!(removed_then_observed, test_completion(); at=now + 1)
    @test removed_then_observed.matched_completion === nothing
    @test_throws RunnerClient.UnknownOutcome RunnerClient.matching_reply(removed_then_observed, now + 2)

    for retired in (false, true)
        conflict = test_observation()
        conflict.pending = test_header()
        RunnerClient.observe!(conflict, test_completion(); at=now)
        retired && RunnerClient.fail!(conflict, "removed"; at=now + 1, retirement=true)
        RunnerClient.observe!(conflict, test_completion(links=Int64(3)); at=now + 2)
        @test conflict.fatal_failure !== nothing
        @test_throws RunnerClient.UnknownOutcome RunnerClient.matching_reply(conflict, now + 3)
        malformed = test_observation()
        malformed.pending = test_header()
        RunnerClient.observe!(malformed, test_completion(); at=now)
        retired && RunnerClient.fail!(malformed, "removed"; at=now + 1, retirement=true)
        broken = Pod(props_param(ClientSPA.Props(
            "pipewireao.rtc.control.completion.header" => ClientSPA.Struct(),
            "pipewireao.rtc.control.completion.payload" => ClientSPA.Struct())))
        RunnerClient.observe!(malformed, broken; at=now + 2)
        @test_throws RunnerClient.UnknownOutcome RunnerClient.matching_reply(malformed, now + 3)
    end
    rejected = test_observation()
    rejected.pending = test_header()
    RunnerClient.observe!(rejected, test_rejection(); at=now)
    RunnerClient.observe!(rejected, test_rejection(); at=now + 3)
    @test rejected.matched_rejection.at == now
    @test RunnerClient.matching_reply(rejected, now + 1) isa ClientCodec.Rejection
    wrong_caller = test_observation()
    wrong_caller.pending = test_header()
    other = ClientEnvelope.ControllerIdentity(UInt32(43), UInt64(2), Int64(10))
    RunnerClient.observe!(wrong_caller, test_completion(controller=other); at=now)
    @test wrong_caller.matched_completion === nothing
    @test_throws RunnerClient.UnknownOutcome RunnerClient.matching_reply(wrong_caller, now - 1)

    instance = RunnerClient.next_instance()
    @test instance > 0
    @test RunnerClient.next_instance() == instance + 1

    # ReentrantLock alone does not reject the same task. Explicit active state
    # must preserve the outer operation's exact pending record and resources.
    gate = RunnerClient.Client(ThreadLoop("test.runner.reentry"), nothing, nothing,
        nothing, nothing, nothing, nothing, test_observation(), "owner", "marker",
        Int64(9), 0, 0, TEST_CONTROLLER, false, false, 0, false, false, ReentrantLock())
    gate.observation.pending = test_header()
    RunnerClient.observe!(gate.observation, test_completion(); at=now)
    outer_reply = gate.observation.matched_completion
    lock(gate.request_lock)
    gate.active = true
    try
        @test_throws ArgumentError RunnerClient.request!(gate, ClientCodec.RunnerCommand(:status); deadline=now + 10)
        @test gate.observation.pending == test_header()
        @test gate.observation.matched_completion === outer_reply
        @test_throws ArgumentError close(gate)
        @test !gate.closed && gate.active
        @test gate.observation.pending == test_header()
        @test gate.observation.matched_completion === outer_reply
    finally
        gate.active = false
        unlock(gate.request_lock)
        close(gate)
    end
    @test gate.closed
    @test_throws RunnerClient.UnknownOutcome RunnerClient.request!(gate,
        ClientCodec.RunnerCommand(:status); deadline=now + 10)
    @test_throws ArgumentError RunnerClient.private_remote("relative.socket")
end

# Same four-node/two-leg external-rtc configuration as native_runner_endpoint.jl.
const CLIENT_RUNNER_CONFIG = raw"""
profile = development execution = external-rtc authority = none
claim = development-characterization rate = 100/1
sources = [
 { ownership = external run-control = application node.name = fixture.plant-frame
   ports = [ { name = output_1 direction = output element-type = U16_LE shape = [ 2 ] schema = org.test.frame/1 } ] }
 { ownership = external run-control = application node.name = fixture.controller-command
   ports = [ { name = output_1 direction = output element-type = F32_LE shape = [ 2 ] schema = org.test.command/1 } ] }
]
graphs = []
sinks = [
 { ownership = external node.name = fixture.controller-frame
   ports = [ { name = input_1 direction = input element-type = U16_LE shape = [ 2 ] schema = org.test.frame/1 } ] }
 { ownership = external node.name = fixture.plant-command
   ports = [ { name = input_1 direction = input element-type = F32_LE shape = [ 2 ] schema = org.test.command/1 } ] }
]
execution-groups = [] properties = {} parameters = {} observations = []
links = [
 { output = "fixture.plant-frame:output_1" input = "fixture.controller-frame:input_1" passive = false }
 { output = "fixture.controller-command:output_1" input = "fixture.plant-command:input_1" passive = false }
]
"""

function run_native_runner_client(socket, directory, _daemon)
    binary = get(ENV, "NATIVE_RUNNER_BINARY", "")
    isfile(binary) && isexecutable(binary) || error("set NATIVE_RUNNER_BINARY to the production runner")
    chmod(dirname(socket), 0o700)
    evidence = mkpath(joinpath(get(ENV, "NATIVE_RUNNER_EVIDENCE",
        "/home/dgamroth/.cache/rtc-live-controls-20261005"), "native-runner-client-$(time_ns())"))
    digest = bytes2hex(open(sha256, binary))
    write(joinpath(evidence, "binary.sha256"), "$digest  $binary\n")
    config = joinpath(directory, "client-runner.conf")
    write(config, CLIENT_RUNNER_CONFIG)
    logfile = joinpath(directory, "client-runner.log")
    log = open(logfile, "w+")
    loop = ThreadLoop("fixture.runner-client.arrays")
    context = core = owner = nothing
    arrays = Any[]
    clients = RunnerClient.Client[]
    try
        with_thread_loop_lock(loop) do _
            context = Context(loop)
            core = CoreConnection(context; properties=Dict("remote.name" => socket))
        end
        start!(loop)
        frame = NdArrayFormat(NdArray.U16_LE, (2,); layout=NdArray.ROW_MAJOR, rate=ClientSPA.Fraction(100, 1))
        command = NdArrayFormat(NdArray.F32_LE, (2,); layout=NdArray.ROW_MAJOR, rate=ClientSPA.Fraction(100, 1))
        push!(arrays, NdArraySource(core, "fixture.plant-frame", zeros(UInt16, 2), frame; schema="org.test.frame/1"))
        push!(arrays, NdArraySink(core, "fixture.controller-frame", zeros(UInt16, 2), frame; schema="org.test.frame/1"))
        push!(arrays, NdArraySource(core, "fixture.controller-command", zeros(Float32, 2), command; schema="org.test.command/1"))
        push!(arrays, NdArraySink(core, "fixture.plant-command", zeros(Float32, 2), command; schema="org.test.command/1"))
        wait_proof(() -> all(endpoint -> node_id(endpoint) != typemax(UInt32), arrays), 15, "client fixture array nodes")
        @test all(endpoint -> !isrunning(endpoint), arrays)
        @test RunnerClient.private_remote(socket) == socket
        owner = run(pipeline(Cmd([binary, "--config", config, "--remote", socket,
            "--control-node", "rtc.native.runner", "--control-instance", "23", "--start-paused"]);
            stdout=log, stderr=log); wait=false)
        pid = getpid(owner)
        check_owner() = Base.process_exited(owner) ? error("supervised runner exited") : nothing
        first_client = RunnerClient.connect(socket, "rtc.native.runner", pid, 23;
            deadline=RunnerClient.monotonic() + 30, check=check_owner)
        push!(clients, first_client)
        @test first_client.owner_ready && first_client.marker_ready
        @test first_client.observation.capability.lifecycle == ClientCodec.Ready
        @test first_client.observation.max_accepted == 0
        @test first_client.identity in first_client.observation.capability.controllers
        @test_throws RunnerClient.UnknownOutcome RunnerClient.connect(socket, "rtc.native.runner", pid + 1, 23;
            deadline=RunnerClient.monotonic() + 15, check=check_owner)
        @test_throws RunnerClient.UnknownOutcome RunnerClient.connect(socket, "rtc.native.runner", pid, 24;
            deadline=RunnerClient.monotonic() + 15, check=check_owner)

        function ask(client, operation, args...; check=check_owner)
            return RunnerClient.request!(client, ClientCodec.RunnerCommand(operation, args...);
                deadline=RunnerClient.monotonic() + 15, check)
        end
        status = ask(first_client, :status)
        @test status isa ClientCodec.Completion && status.error === nothing
        @test status.header.controller == first_client.identity && status.header.token == 1
        @test status.lifecycle == ClientCodec.Ready
        @test status.result.details.owned_nodes == 0 && status.result.details.owned_links == 2
        @test !status.result.details.running
        groups = ask(first_client, :groups)
        @test groups.result.outcome == ClientCodec.Observed
        @test isempty(groups.result.details.groups)
        second_client = RunnerClient.connect(socket, "rtc.native.runner", pid, 23;
            deadline=RunnerClient.monotonic() + 30, check=check_owner)
        push!(clients, second_client)
        @test second_client.identity != first_client.identity
        @test second_client.marker_instance != first_client.marker_instance
        @test second_client.observation.max_accepted >= groups.header.token
        second_status = ask(second_client, :status)
        @test second_status.header.controller == second_client.identity
        @test second_status.header.token > groups.header.token
        wait_proof(() -> with_thread_loop_lock(first_client.loop) do _
                first_client.observation.max_accepted >= second_status.header.token
            end, 15, "first client observes second caller accepted token")

        failed = ask(first_client, :properties, "fixture.missing-graph")
        @test failed isa ClientCodec.Completion && failed.header.result < 0
        @test failed.result === nothing && failed.error isa ClientCodec.RunnerError
        @test failed.lifecycle == ClientCodec.Ready
        @test failed.header.token > second_status.header.token
        foreach(start!, arrays)
        @test all(isrunning, arrays)
        started = ask(first_client, :session_start)
        @test started.lifecycle == ClientCodec.Running
        @test started.result.outcome == ClientCodec.Completed
        stopped = ask(first_client, :session_stop)
        @test stopped.lifecycle == ClientCodec.Ready

        nested_checks = Ref(0)
        function nested_check()
            nested_checks[] += 1
            pending = first_client.observation.pending
            @test_throws ArgumentError RunnerClient.request!(first_client,
                ClientCodec.RunnerCommand(:status); deadline=RunnerClient.monotonic() + 15)
            @test_throws ArgumentError close(first_client)
            @test first_client.observation.pending === pending
            @test !first_client.closed && first_client.active
            check_owner()
        end
        nested_reply = ask(first_client, :status; check=nested_check)
        @test nested_reply isa ClientCodec.Completion && nested_reply.error === nothing
        @test nested_checks[] > 0
        @test !first_client.active && first_client.observation.pending === nothing

        @test_throws RunnerClient.UnknownOutcome RunnerClient.request!(first_client,
            ClientCodec.RunnerCommand(:status); deadline=RunnerClient.monotonic() - 1)
        @test_throws RunnerClient.UnknownOutcome ask(first_client, :status)
        identity = first_client.identity
        close(first_client)
        wait_proof(() -> with_thread_loop_lock(second_client.loop) do _
                !(identity in second_client.observation.capability.controllers) &&
                    second_client.observation.max_accepted >= nested_reply.header.token
            end, 15, "client close removes actual marker incarnation")
        fresh = ask(second_client, :status)
        @test fresh.header.token > nested_reply.header.token && fresh.error === nothing
        quit = ask(second_client, :quit; check=()->nothing)
        @test quit isa ClientCodec.Completion && quit.error === nothing
        @test quit.result.outcome == ClientCodec.Accepted
        wait_proof(() -> with_thread_loop_lock(second_client.loop) do _
                second_client.observation.failure !== nothing
            end, 15, "client observes actual owner retirement after Quit")
        @test_throws RunnerClient.UnknownOutcome ask(second_client, :status; check=()->nothing)
        wait_proof(() -> Base.process_exited(owner), 10, "native client owner exit")
        wait(owner)
        @test owner.exitcode == 0
        for sink in (arrays[2], arrays[4])
            @test_throws InvalidStateException with_thread_loop_lock(loop) do _; array_receipt(sink); end
        end
        println("NATIVE_RUNNER_CLIENT typed=true two_actual_clients=true source_submissions=0 sink_arms=0 nested_checks=$(nested_checks[]) binary_sha256=$digest evidence=$evidence")
    finally
        failures = Any[]
        for client in reverse(clients)
            try close(client) catch error; push!(failures, error); end
        end
        try owner === nothing || stop_proof_child!(owner, "native client runner") catch error; push!(failures, error); end
        flush(log)
        close(log)
        for file in (config, logfile, joinpath(directory, "private-core.log"))
            isfile(file) && cp(file, joinpath(evidence, basename(file)); force=true)
        end
        println("NATIVE_RUNNER_CLIENT_EVIDENCE=$evidence")
        for array in reverse(arrays)
            try close(array) catch error; push!(failures, error); end
        end
        with_thread_loop_lock(loop) do _
            for resource in (core, context)
                try resource === nothing || close(resource) catch error; push!(failures, error); end
            end
        end
        try close(loop) catch error; push!(failures, error); end
        isempty(failures) || throw(CompositeException(failures))
    end
end

@testset "typed native runner client actual private endpoint" begin
    @test Base.pkgversion(PipeWireAO) == v"0.6.16"
    with_control_private_core(run_native_runner_client)
end
