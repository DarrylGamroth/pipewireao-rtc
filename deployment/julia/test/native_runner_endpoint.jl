using Test
using SHA
using PipeWireAO
using PipeWireAODeployment.NativeControlCodec

include(joinpath(@__DIR__, "native_control_private_core.jl"))

const RunnerSPA = PipeWireAO.SPA
const RUNNER_INSTANCE = Int64(23)
const RUNNER_NAME = "rtc.native.runner"
const RUNNER_CAP_NAMES = (
    "pipewireao.rtc.runner.version", "pipewireao.rtc.runner.instance",
    "pipewireao.rtc.runner.owner-pid", "pipewireao.rtc.runner.lifecycle",
    "pipewireao.rtc.runner.last-token", "pipewireao.rtc.runner.controllers",
)

struct RunnerCapability
    version::Int32
    instance::Int64
    owner_pid::UInt32
    lifecycle::UInt32
    last_token::Int64
    controllers::Vector{ControllerIdentity}
end

# These are cold integration observations. All callback writes and reads use
# the connection's ThreadLoop lock; ordinary Node callbacks own their PODs.
mutable struct RunnerFixtureConnection
    loop::ThreadLoop
    context::Any
    core::Any
    registry::Any
    marker::Any
    marker_node::Any
    owner_node::Any
    marker_info::Union{Nothing,NodeInfo}
    owner_info::Union{Nothing,NodeInfo}
    failure::Union{Nothing,String}
    removed::Bool
    capability::Union{Nothing,RunnerCapability}
    completions::Vector{Tuple{ReplyHeader,RunnerSPA.Struct}}
    rejections::Vector{Tuple{ReplyHeader,RunnerSPA.Struct}}
end

function runner_connection(socket, suffix)
    client = RunnerFixtureConnection(ThreadLoop("fixture.runner.$suffix"),
        nothing, nothing, nothing, nothing, nothing, nothing, nothing, nothing,
        nothing, false, nothing, Tuple{ReplyHeader,RunnerSPA.Struct}[],
        Tuple{ReplyHeader,RunnerSPA.Struct}[])
    try
        with_thread_loop_lock(client.loop) do _
            client.context = Context(client.loop)
            client.core = CoreConnection(client.context;
                properties=Dict("remote.name" => socket),
                on_error=(core, id, sequence, error) -> begin
                    client.failure = sprint(showerror, error)
                    nothing
                end)
            client.registry = Registry(client.core)
        end
        start!(client.loop)
        return client
    catch
        close_runner_connection(client)
        rethrow()
    end
end

runner_read(f, client) = with_thread_loop_lock(f, client.loop)

function close_runner_connection(client)
    # Attempt every resource even after a failed constructor or observation.
    failures = String[]
    with_thread_loop_lock(client.loop) do _
        for resource in (client.owner_node, client.marker_node, client.marker,
                client.registry, client.core, client.context)
            resource === nothing && continue
            try
                close(resource)
            catch error
                push!(failures, sprint(showerror, error))
            end
        end
    end
    try
        close(client.loop)
    catch error
        push!(failures, sprint(showerror, error))
    end
    isempty(failures) || error("fixture resource cleanup failed: $(join(failures, "; "))")
    return nothing
end

function runner_wait(predicate, clients, deadline, label; check=()->nothing)
    stop = min(deadline, time_ns() / 1e9 + 15)
    while time_ns() / 1e9 < stop
        check()
        for client in clients
            failure = runner_read(client) do _; client.failure; end
            failure === nothing || error("$label: client callback failed: $failure")
        end
        predicate() && return nothing
        sleep(0.002)
    end
    error("native runner fixture deadline expired: $label")
end

function runner_global(client, name)
    return runner_read(client) do _
        globals = find_globals(client.registry; interface="PipeWire:Interface:Node",
            properties=("node.name" => name,))
        length(globals) == 1 ? only(globals) : nothing
    end
end

function runner_capability(pod)
    props = RunnerSPA.Props(pod)
    length(props.values) == length(RUNNER_CAP_NAMES) || error("wrong capability arity")
    values = Dict{String,Pod}()
    for (name, value) in props.values
        name in RUNNER_CAP_NAMES || error("unknown capability field $name")
        haskey(values, name) && error("duplicate capability field $name")
        values[name] = value
    end
    identities = ControllerIdentity[]
    rows = pod_value(RunnerSPA.Struct, values[RUNNER_CAP_NAMES[6]])
    length(rows.values) <= 32 || error("too many admitted controllers")
    for row in rows.values
        fields = pod_value(RunnerSPA.Struct, row).values
        length(fields) == 3 || error("wrong controller identity arity")
        identity = ControllerIdentity(pod_value(RunnerSPA.Id, fields[1]).value,
            reinterpret(UInt64, pod_value(Int64, fields[2])), pod_value(Int64, fields[3]))
        identity in identities && error("duplicate controller identity")
        push!(identities, identity)
    end
    return RunnerCapability(pod_value(Int32, values[RUNNER_CAP_NAMES[1]]),
        pod_value(Int64, values[RUNNER_CAP_NAMES[2]]),
        pod_value(RunnerSPA.Id, values[RUNNER_CAP_NAMES[3]]).value,
        pod_value(RunnerSPA.Id, values[RUNNER_CAP_NAMES[4]]).value,
        pod_value(Int64, values[RUNNER_CAP_NAMES[5]]), identities)
end

function runner_parameter!(client, pod)
    props = RunnerSPA.Props(pod)
    isempty(props.values) && error("empty retained Props")
    first_name = first(props.values).first
    if first_name == "pipewireao.rtc.control.completion.header"
        push!(client.completions, decode_completion(pod; endpoint=:lifecycle))
    elseif first_name == "pipewireao.rtc.control.rejection.header"
        push!(client.rejections, decode_rejection(pod; endpoint=:lifecycle))
    elseif first_name in RUNNER_CAP_NAMES
        client.capability = runner_capability(pod)
    else
        error("unexpected runner Props record: $first_name")
    end
    return nothing
end

function export_runner_controller!(client, suffix, instance, deadline)
    name = "pipewireao.rtc.controller.$suffix"
    runner_read(client) do _
        client.marker = Filter(client.core, name; properties=Dict(
            "node.name" => name, "media.class" => "Control",
            "pipewireao.rtc-control.protocol" => "pipewireao.rtc-control/1",
            "pipewireao.rtc-control.profile" => "pipewireao.rtc.controller/1",
            "pipewireao.rtc-control.instance" => string(instance),
            "pipewireao.rtc-control.owner-pid" => string(getpid())))
        connect!(client.marker; flags=FILTER_ASYNC | FILTER_INACTIVE)
    end
    runner_wait(() -> runner_global(client, name) !== nothing, (client,), deadline,
        "controller registry announcement")
    global_object = runner_global(client, name)
    runner_read(client) do _
        client.marker_node = bind(client.registry, global_object, Node;
            on_info=(proxy, info) -> begin
                isempty(info.properties) || (client.marker_info = info)
                nothing
            end,
            on_error=(proxy, sequence, error) -> begin
                client.failure = sprint(showerror, error)
                nothing
            end)
    end
    runner_wait(() -> runner_read(client) do _; client.marker_info !== nothing; end,
        (client,), deadline, "controller bound NodeInfo")
    info = runner_read(client) do _; something(client.marker_info); end
    @test info.id == global_object.id
    @test info.properties["object.serial"] == global_object.properties["object.serial"]
    @test info.properties["node.name"] == name
    @test info.properties["pipewireao.rtc-control.protocol"] == "pipewireao.rtc-control/1"
    @test info.properties["pipewireao.rtc-control.profile"] == "pipewireao.rtc.controller/1"
    @test info.properties["pipewireao.rtc-control.instance"] == string(instance)
    @test info.properties["pipewireao.rtc-control.owner-pid"] == string(getpid())
    @test info.n_input_ports == 0 && info.n_output_ports == 0
    return ControllerIdentity(global_object.id,
        parse(UInt64, global_object.properties["object.serial"]), Int64(instance))
end

function bind_runner_owner!(client, owner_pid, deadline; check=()->nothing)
    runner_wait(() -> runner_global(client, RUNNER_NAME) !== nothing, (client,),
        deadline, "runner registry announcement"; check)
    global_object = runner_global(client, RUNNER_NAME)
    runner_read(client) do _
        client.owner_node = bind(client.registry, global_object, Node;
            on_info=(proxy, info) -> begin
                isempty(info.properties) || (client.owner_info = info)
                nothing
            end,
            on_removed=proxy -> (client.removed = true; nothing),
            on_error=(proxy, sequence, error) -> begin
                client.failure = sprint(showerror, error)
                nothing
            end,
            on_param=(proxy, sequence, id, index, next, pod) -> begin
                if id == RunnerSPA.PARAM_PROPS && pod !== nothing
                    try
                        runner_parameter!(client, pod)
                    catch error
                        client.failure = sprint(showerror, error)
                    end
                end
                nothing
            end)
    end
    runner_wait(() -> runner_read(client) do _; client.owner_info !== nothing; end,
        (client,), deadline, "runner bound NodeInfo"; check)
    info = runner_read(client) do _; something(client.owner_info); end
    @test info.id == global_object.id
    @test info.properties["object.serial"] == global_object.properties["object.serial"]
    @test parse(UInt64, info.properties["object.serial"]) > 0
    @test info.properties["pipewireao.rtc-control.protocol"] == "pipewireao.rtc-control/1"
    @test info.properties["pipewireao.rtc-control.profile"] == "pipewireao.rtc.runner/1"
    @test info.properties["pipewireao.rtc-control.instance"] == string(RUNNER_INSTANCE)
    @test info.properties["pipewireao.rtc-control.owner-pid"] == string(owner_pid)
    @test info.n_input_ports == 0 && info.n_output_ports == 0
    runner_read(client) do _
        subscribe_params!(client.owner_node, (RunnerSPA.PARAM_PROPS,))
        # Async enum sequence numbers are transport bookkeeping. Readiness is
        # the complete retained schema, then fresh replies match full headers.
        enum_params!(client.owner_node, RunnerSPA.PARAM_PROPS; count=UInt32(8))
    end
    runner_wait(() -> runner_read(client) do _
            client.capability !== nothing && !isempty(client.completions) &&
                !isempty(client.rejections)
        end, (client,), deadline, "three initial retained Props"; check)
    return global_object
end

function runner_send!(client, pod)
    runner_read(client) do _; set_param!(client.owner_node, RunnerSPA.PARAM_PROPS, pod); end
    return nothing
end

function runner_reply!(client, identity, token, operation, payload, deadline;
        endpoint_instance=RUNNER_INSTANCE, rejection=false, check=()->nothing)
    header = RequestHeader(identity, endpoint_instance, Int64(token), UInt32(operation),
        Int64(10_000_000_000))
    before = runner_read(client) do _
        length(rejection ? client.rejections : client.completions)
    end
    runner_send!(client, encode_request(header, payload))
    matches(record) = record[1].controller == identity && record[1].token == token &&
        record[1].operation == operation && record[1].endpoint_instance == RUNNER_INSTANCE
    runner_wait(() -> runner_read(client) do _
            records = rejection ? client.rejections : client.completions
            any(matches, @view records[(before + 1):end])
        end, (client,), deadline, "fresh $(rejection ? "rejection" : "completion") token=$token"; check)
    return runner_read(client) do _
        records = rejection ? client.rejections : client.completions
        first(filter(matches, @view records[(before + 1):end]))
    end
end

function runner_success(reply, identity, token, operation, lifecycle, outcome)
    header, payload = reply
    @test header == ReplyHeader(identity, RUNNER_INSTANCE, Int64(token), UInt32(operation), Int32(0))
    if header.result < 0
        error("expected successful operation $operation token $token; got result $(header.result), field=$(pod_value(String, payload.values[1])), message=$(pod_value(String, payload.values[2])), lifecycle=$(pod_value(RunnerSPA.Id, payload.values[3]).value)")
    end
    @test length(payload.values) == 3
    @test pod_value(RunnerSPA.Id, payload.values[1]).value == lifecycle
    @test pod_value(RunnerSPA.Id, payload.values[2]).value == outcome
    return pod_value(RunnerSPA.Struct, payload.values[3])
end

function runner_error(reply, lifecycle)
    header, payload = reply
    @test header.result < 0
    @test length(payload.values) == 3
    @test !isempty(pod_value(String, payload.values[1]))
    @test !isempty(pod_value(String, payload.values[2]))
    @test pod_value(RunnerSPA.Id, payload.values[3]).value == lifecycle
    return nothing
end

function runner_status(reply, identity, token)
    details = runner_success(reply, identity, token, 3, 3, 2)
    @test length(details.values) == 5
    @test !pod_value(Bool, details.values[1])
    @test reinterpret(UInt64, pod_value(Int64, details.values[2])) == 0
    @test reinterpret(UInt64, pod_value(Int64, details.values[3])) == 2
    @test reinterpret(UInt64, pod_value(Int64, details.values[4])) == 0
    @test isempty(pod_value(RunnerSPA.Struct, details.values[5]).values)
    return nothing
end

const RUNNER_FIXTURE_CONFIG = raw"""
profile = development
execution = external-rtc
authority = none
claim = development-characterization
rate = 100/1
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
execution-groups = []
properties = {}
parameters = {}
observations = []
links = [
  { output = "fixture.plant-frame:output_1" input = "fixture.controller-frame:input_1" passive = false }
  { output = "fixture.controller-command:output_1" input = "fixture.plant-command:input_1" passive = false }
]
"""

function run_native_runner_endpoint(socket::String, directory::String, _daemon::Base.Process)
    binary = get(ENV, "NATIVE_RUNNER_BINARY", "")
    isfile(binary) && isexecutable(binary) || error("set NATIVE_RUNNER_BINARY to the built production runner")
    binary_sha256 = bytes2hex(open(sha256, binary))
    println("NATIVE_RUNNER_BINARY=$binary sha256=$binary_sha256 PipeWireAO_VERSION=$(Base.pkgversion(PipeWireAO)) CPU=$(get(ENV, "NATIVE_RUNNER_CPU", "externally-pinned"))")
    # Native admission uses the runner's existing private-runtime guard.
    chmod(dirname(socket), 0o700)
    evidence_root = get(ENV, "NATIVE_RUNNER_EVIDENCE", "/home/dgamroth/.cache/rtc-live-controls-20261005")
    evidence = mkpath(joinpath(evidence_root, "native-runner-endpoint-$(time_ns())"))
    write(joinpath(evidence, "binary.sha256"), "$binary_sha256  $binary\n")
    config_path = joinpath(directory, "runner.conf")
    write(config_path, RUNNER_FIXTURE_CONFIG)
    owner_log_path = joinpath(directory, "runner.log")
    owner_log = open(owner_log_path, "w+")
    owner = nothing
    connections = RunnerFixtureConnection[]
    endpoints = Any[]
    deadline = time_ns() / 1e9 + 150
    try
        arrays = runner_connection(socket, "external-arrays")
        push!(connections, arrays)
        frame = NdArrayFormat(NdArray.U16_LE, (2,); layout=NdArray.ROW_MAJOR,
            rate=RunnerSPA.Fraction(100, 1))
        command = NdArrayFormat(NdArray.F32_LE, (2,); layout=NdArray.ROW_MAJOR,
            rate=RunnerSPA.Fraction(100, 1))
        push!(endpoints, NdArraySource(arrays.core, "fixture.plant-frame", zeros(UInt16, 2), frame;
            schema="org.test.frame/1"))
        push!(endpoints, NdArraySink(arrays.core, "fixture.controller-frame", zeros(UInt16, 2), frame;
            schema="org.test.frame/1"))
        push!(endpoints, NdArraySource(arrays.core, "fixture.controller-command", zeros(Float32, 2), command;
            schema="org.test.command/1"))
        push!(endpoints, NdArraySink(arrays.core, "fixture.plant-command", zeros(Float32, 2), command;
            schema="org.test.command/1"))
        runner_wait(() -> all(endpoint -> node_id(endpoint) != typemax(UInt32), endpoints),
            (arrays,), deadline, "four external ndarray nodes")
        @test all(endpoint -> !isrunning(endpoint), endpoints)

        first_client = runner_connection(socket, "controller-one")
        push!(connections, first_client)
        second_client = runner_connection(socket, "controller-two")
        push!(connections, second_client)
        first_identity = export_runner_controller!(first_client, "fixture-one", 9, deadline)
        second_identity = export_runner_controller!(second_client, "fixture-two", 10, deadline)
        @test first_identity.global_id != second_identity.global_id
        @test first_identity.serial != second_identity.serial

        owner = run(pipeline(Cmd([binary, "--config", config_path, "--remote", socket,
            "--control-node", RUNNER_NAME, "--control-instance", string(RUNNER_INSTANCE),
            "--start-paused"]); stdout=owner_log, stderr=owner_log); wait=false)
        owner_pid = getpid(owner)
        check_owner() = Base.process_exited(owner) ? error("runner exited before requested observations") : nothing
        owner_global = bind_runner_owner!(first_client, owner_pid, deadline; check=check_owner)
        other_global = bind_runner_owner!(second_client, owner_pid, deadline; check=check_owner)
        @test owner_global.id == other_global.id
        @test owner_global.properties["object.serial"] == other_global.properties["object.serial"]
        for client in (first_client, second_client)
            runner_wait(() -> runner_read(client) do _
                    cap = client.capability
                    cap !== nothing && first_identity in cap.controllers && second_identity in cap.controllers
                end, (client,), deadline, "actual controller capability membership"; check=check_owner)
            cap, initial = runner_read(client) do _
                something(client.capability), last(client.completions)
            end
            @test cap.version == 1 && cap.instance == RUNNER_INSTANCE
            @test cap.owner_pid == owner_pid
            @test cap.lifecycle == 3 && cap.last_token == 0
            @test length(cap.controllers) == 2
            @test initial[1] == ReplyHeader(RUNNER_INSTANCE, Int32(0))
        end

        empty_payload = RunnerSPA.Struct()
        runner_status(runner_reply!(first_client, first_identity, 1, 3, empty_payload,
            deadline; check=check_owner), first_identity, 1)
        groups = runner_success(runner_reply!(first_client, first_identity, 2, 2,
            empty_payload, deadline; check=check_owner), first_identity, 2, 2, 3, 2)
        @test length(groups.values) == 1
        @test isempty(pod_value(RunnerSPA.Struct, only(groups.values)).values)
        # External application-owned streams must be connected and active
        # before RTC Start. Activation does not submit a source frame or arm a
        # sink; this fixture performs neither operation.
        foreach(start!, endpoints)
        @test all(isrunning, endpoints)
        for sink in (endpoints[2], endpoints[4])
            @test_throws InvalidStateException runner_read(arrays) do _
                array_receipt(sink)
            end
        end
        start_reply = runner_reply!(first_client, first_identity, 3, 10,
            empty_payload, deadline; check=check_owner)
        started = runner_success(start_reply, first_identity, 3, 10, 4, 4)
        @test length(started.values) == 1 && pod_value(RunnerSPA.Id, only(started.values)).value == 4
        @test all(isrunning, endpoints)
        # A second dispatch of Start while Running would fail lifecycle
        # validation. A matching successful retained reply proves suppression.
        @test runner_reply!(first_client, first_identity, 3, 10, empty_payload,
            deadline; check=check_owner) == start_reply
        @test runner_read(first_client) do _
            first_client.capability.lifecycle == 4 && first_client.capability.last_token == 3
        end
        stopped = runner_success(runner_reply!(first_client, first_identity, 4, 9,
            empty_payload, deadline; check=check_owner), first_identity, 4, 9, 3, 4)
        @test length(stopped.values) == 1 && pod_value(RunnerSPA.Id, only(stopped.values)).value == 3
        @test all(isrunning, endpoints)

        missing_graph = RunnerSPA.Struct(Pod("fixture.missing-graph"))
        failed = runner_reply!(first_client, first_identity, 5, 4, missing_graph,
            deadline; check=check_owner)
        @test failed[1].controller == first_identity && failed[1].token == 5 && failed[1].operation == 4
        runner_error(failed, 3)
        duplicate = runner_reply!(first_client, first_identity, 5, 4, missing_graph,
            deadline; check=check_owner)
        @test duplicate == failed
        collision = runner_reply!(second_client, second_identity, 5, 4, missing_graph,
            deadline; rejection=true, check=check_owner)
        runner_error(collision, 3)
        runner_wait(() -> runner_read(second_client) do _
                last(second_client.completions) == failed && second_client.capability.last_token == 5
            end, (second_client,), deadline, "collision preserves accepted failure"; check=check_owner)
        @test runner_read(first_client) do _; first_client.capability.last_token == 5; end

        fresh = runner_reply!(first_client, first_identity, 6, 3, empty_payload,
            deadline; check=check_owner)
        runner_status(fresh, first_identity, 6)
        runner_error(runner_reply!(first_client, first_identity, 1, 3, empty_payload,
            deadline; rejection=true, check=check_owner), 3)
        runner_error(runner_reply!(first_client, first_identity, 7, 3, empty_payload,
            deadline; endpoint_instance=Int64(24), rejection=true, check=check_owner), 3)
        before = runner_read(first_client) do _; length(first_client.rejections); end
        # Preserve the native Props carrier so the owner's envelope parser
        # receives the malformed header. Native transport may discard a
        # scalar submitted with a Props parameter ID before that callback.
        malformed = Pod(props_param(RunnerSPA.Props(
            "pipewireao.rtc.control.request.header" => RunnerSPA.Struct(),
            "pipewireao.rtc.control.request.payload" => RunnerSPA.Struct())))
        runner_send!(first_client, malformed)
        runner_wait(() -> runner_read(first_client) do _
                any(record -> record[1].controller === nothing && record[1].result < 0,
                    @view first_client.rejections[(before + 1):end])
            end, (first_client,), deadline, "malformed input independent rejection"; check=check_owner)
        @test runner_read(first_client) do _
            last(first_client.completions) == fresh && first_client.capability.last_token == 6
        end

        runner_read(first_client) do _
            close(first_client.marker_node)
            first_client.marker_node = nothing
            close(first_client.marker)
            first_client.marker = nothing
        end
        runner_wait(() -> runner_read(second_client) do _
                !(first_identity in second_client.capability.controllers) &&
                    second_identity in second_client.capability.controllers
            end, (second_client,), deadline, "removed actual controller incarnation fenced"; check=check_owner)
        @test runner_global(second_client, "pipewireao.rtc.controller.fixture-one") === nothing
        runner_error(runner_reply!(second_client, first_identity, 7, 3, empty_payload,
            deadline; rejection=true, check=check_owner), 3)
        @test runner_read(second_client) do _
            last(second_client.completions) == fresh && second_client.capability.last_token == 6
        end
        runner_status(runner_reply!(second_client, second_identity, 7, 3, empty_payload,
            deadline; check=check_owner), second_identity, 7)
        quit = runner_success(runner_reply!(second_client, second_identity, 8, 1,
            empty_payload, deadline), second_identity, 8, 1, 3, 1)
        @test length(quit.values) == 1 && pod_value(Bool, only(quit.values))
        runner_wait(() -> all(client -> runner_read(client) do _; client.removed; end,
                (first_client, second_client)), (first_client, second_client), deadline,
            "actual runner node removal after quit")
        runner_wait(() -> Base.process_exited(owner), (), deadline, "production runner exit")
        wait(owner)
        @test owner.exitcode == 0
        @test runner_global(second_client, RUNNER_NAME) === nothing
        @test all(isrunning, endpoints)
        for sink in (endpoints[2], endpoints[4])
            @test_throws InvalidStateException runner_read(arrays) do _
                array_receipt(sink)
            end
        end
        println("NATIVE_RUNNER_ENDPOINT owner_pid=$owner_pid callers=$(first_identity),$(second_identity) two_actual_connections=true owned_nodes=0 owned_links=2 initial_held=true application_active=true source_submissions=0 sink_arms=0 duplicate=true collision=true stale=true removed_caller=true quit_removed=true evidence=$evidence")
    finally
        cleanup_failures = String[]
        try
            owner === nothing || stop_proof_child!(owner, "production native runner")
        catch error
            push!(cleanup_failures, "runner: $(sprint(showerror, error))")
        end
        try
            flush(owner_log)
            close(owner_log)
        catch error
            push!(cleanup_failures, "log: $(sprint(showerror, error))")
        end
        for file in (config_path, owner_log_path, joinpath(directory, "private-core.log"))
            try
                isfile(file) && cp(file, joinpath(evidence, basename(file)); force=true)
            catch error
                push!(cleanup_failures, "evidence: $(sprint(showerror, error))")
            end
        end
        println("NATIVE_RUNNER_ENDPOINT_EVIDENCE=$evidence")
        for endpoint in reverse(endpoints)
            try
                close(endpoint)
            catch error
                push!(cleanup_failures, "ndarray: $(sprint(showerror, error))")
            end
        end
        for client in reverse(connections)
            try
                close_runner_connection(client)
            catch error
                push!(cleanup_failures, "connection: $(sprint(showerror, error))")
            end
        end
        isempty(cleanup_failures) || error("fixture cleanup failures: $(join(cleanup_failures, "; "))")
    end
    return nothing
end

@testset "production native runner private-core endpoint" begin
    @test Base.pkgversion(PipeWireAO) == v"0.6.16"
    with_control_private_core(run_native_runner_endpoint)
end
