# Diagnostic for the candidate's managed lockstep duty on a private software core.
using AdaptiveOpticsSimPipeWireHIL, AdaptiveOpticsSim.AlgorithmGraphs, PipeWireAO
using AdaptiveOpticsSim.AlgorithmGraphs: graph_port_contract
using PipeWireAORTC, Test
import PipeWireAO_jll, ThreadPinning

const HIL = AdaptiveOpticsSimPipeWireHIL
const Ext = Base.get_extension(HIL, :PipeWireAORTCExt)
const Boot = PipeWireAORTC.OwnerBootstrapRuntime
const Client = PipeWireAORTC.OwnerBootstrapClient
const Codec = PipeWireAORTC.OwnerBootstrapCodec
const Source = PipeWireAORTC.SourceControl
const Session = PipeWireAORTC.MediaSession
const Fixtures = joinpath(pkgdir(HIL), "test")
const Faults = Module(:ReleasedRTCFaultTests)
Base.include(Faults, joinpath(pkgdir(PipeWireAORTC), "test", "integration", "session_faults.jl"))

# Use the same prepared plant and native three-output producer as healthy_hold.jl.
function include_declarations(name, first_marker, last_marker)
    path = joinpath(Fixtures, name)
    text = read(path, String)
    first_byte = first(something(findfirst(first_marker, text)))
    last_byte = first(something(findnext(last_marker, text, first_byte)))
    include_string(Main, text[first_byte:prevind(text, last_byte)], path)
end
include_declarations("live_private_core.jl", "struct LiveTransportTestDeclaration",
    "include(\"live_exchange_private_core.jl\")")
include_declarations("multi_command.jl", "struct MultiCommandTestDeclaration",
    "function outstanding_multi_command")
include(joinpath(Fixtures, "private_core_helpers.jl"))
include(joinpath(Fixtures, "live_multi_command_private_core.jl"))

function bind_source(client, name)
    prototype = Source.snapshot_values(1, Source.INITIAL, 0, Int32(0),
        1, 0, false, false, 1, 0)
    codec = PropsBuffer(Source.SNAPSHOT_NAMES, prototype)
    observed = Ref(prototype)
    registry = something(client.client.registry)
    roundtrip(registry)
    node = with_thread_loop_lock(client.client.loop) do _
        object = only(find_globals(registry; interface="PipeWire:Interface:Node",
            properties=("node.name" => name,)))
        node = bind(registry, object, Node; on_param=(node, seq, id, index, next, pod) -> begin
            id == SPA.PARAM_PROPS && pod !== nothing && parse_props!(observed, codec, pod)
            nothing
        end)
        subscribe_params!(node, (SPA.PARAM_PROPS,))
        node
    end
    return node, observed
end

function control(client, node, observed, kind, token, request)
    with_thread_loop_lock(client.client.loop) do _
        set_param!(node, SPA.PARAM_PROPS, request)
    end
    _wait_for_hil_condition(; timeout=30) do
        with_thread_loop_lock(client.client.loop) do _
            observed[][3] == kind && observed[][4] == token
        end
    end
    return with_thread_loop_lock(client.client.loop) do _
        snapshot = observed[]
        Dict(replace(name, "pipewireao.source-snapshot." => "") => snapshot[i]
            for (i, name) in enumerate(Source.SNAPSHOT_NAMES))
    end
end

function session_snapshot(snapshot)
    prefix = "pipewireao.source-snapshot."
    values = Dict(prefix * name => Pod(value) for (name, value) in snapshot)
    return Session.source_control_snapshot(values, snapshot["instance"])
end

function session_accepts(snapshot, prior, kind, state)
    current = session_snapshot(snapshot)
    records = Session.ControlRecords(nothing, nothing, current, nothing, current.details.token)
    return Session.matching_source_control_record(records, kind, current.details.token,
        state, session_snapshot(prior))
end

function controller(options, pipewire, producer, hold_final)
    deadline() = time_ns() / 1e9 + 90
    client = Client.connect(options.remote, options.bootstrap_node, getpid(),
        options.bootstrap_instance; deadline=deadline())
    node = nothing
    try
        @test Client.connect_owner!(client; deadline=deadline()).lifecycle === Codec.Connected
        node, snapshot = bind_source(client, options.control_node)
        running = control(client, node, snapshot, Source.RUN, 1, run_control_request(1, :running))
        @test running["result"] == 0 && running["running"]
        report_path = Ext.report_path(options)
        if hold_final
            _wait_for_hil_condition(; timeout=15) do
                # Withhold only the final port. The two other commands must
                # really reach the owner for its final published frame.
                with_thread_loop_lock(pipewire.loop) do _
                    producer.received[] == 1 && pipewire.state.woofer.command_ready[] == 1 &&
                        pipewire.state.tweeter.command_ready[] == 1
                end
            end
        else
            _wait_for_hil_condition(; timeout=15) do
                PipeWireAORTC.Common.read_json(report_path)["completed"]
            end
        end
        held = control(client, node, snapshot, Source.RUN, 2, run_control_request(2, :stopped))
        report = PipeWireAORTC.Common.read_json(report_path)
        @test held["result"] == 0
        @test held["sequence"] == held["report-sequence"] == 1
        @test held["generation"] == held["report-generation"] == 1
        @test held["completed"] && !held["running"]
        @test report["completed"] && !report["running"] && isempty(report["failures"])
        observation = Dict("owner_pid" => getpid(), "instance" => held["instance"],
            "snapshot" => held)
        @test Faults.validate_source_report(report, observation) === nothing
        accepted = session_accepts(held, running, :run, "stopped")
        @test Session.validate_source_operation(accepted, :run, false) === nothing
        queried = control(client, node, snapshot, Source.QUERY, 3,
            Session.control_request(:query, Int64(3), nothing, held["instance"]))
        ended = session_accepts(queried, held, :query, nothing)
        @test Session._source_ended(Session.SourceEnd(ended.completed, ended.running))
        label = hold_final ? "final-hold" : "normal"
        cp(report_path, joinpath(@__DIR__, label * "-report.json"); force=true)
        PipeWireAORTC.Common.write_json(joinpath(@__DIR__, label * "-snapshot.json"), held)
        PipeWireAORTC.Common.write_json(joinpath(@__DIR__, label * "-query.json"), queried)
        println("hold_final=", hold_final, " released_validator=accepted", " snapshot=", held)
        @test Client.quit!(client; deadline=deadline()).lifecycle === Codec.Stopped
    finally
        with_thread_loop_lock(client.client.loop) do _
            node === nothing || close(node)
        end
        close(client)
    end
    return nothing
end

function trial(remote, hold_final)
    absolute_remote = joinpath(ENV["PIPEWIREAO_RUNTIME_DIR"], remote)
    boundary = multi_command_boundary()
    initial = deepcopy(boundary.command_input)
    wire = multi_command_configuration(; remote=absolute_remote, timeout_ns=UInt64(30_000_000_000))
    state = Ext.Cursor()
    mailbox = Source.Mailbox(Int64(31))
    options = (; remote=absolute_remote, bootstrap_node="finite-bootstrap",
        bootstrap_instance=Int64(51), control_node=wire.frame_node_name,
        total_exchanges=UInt64(1), backend=:cpu, graph=nothing, pacing_period_ns=Int64(0))
    task = nothing
    Boot.with_owner(options) do admitted
        runtime = admitted.bootstrap_runtime
        producer = LiveMultiCommandProducer(; release_last=!hold_final)
        pipewire = prepare_pipewire_hil(boundary, wire;
            frame_properties=Source.source_properties(mailbox),
            frame_params=mailbox.parameters.params,
            on_frame_param_changed=Source.ParameterChanged(mailbox),
            frame_param_buffer=PodBuffer(4096),
            on_frame_param_overflow=Source.ParameterOverflow(mailbox))
        native = nothing
        try
            Ext.report!(admitted, mailbox, state)
            native = _prepare_live_multi_producer(pipewire, producer)
            science = (; driver=FixedStepModelTimeDriver(PeriodicSchedule(; period_ns=1_000_000)))
            Boot.prepared!(runtime)
            task = errormonitor(@async try
                controller(options, pipewire, producer, hold_final)
            catch
                Boot.cancel!(runtime)
                rethrow()
            end)
            Ext.run_prepared!(admitted, science, pipewire, nothing, mailbox, state)
            cursor = hil_boundary_status(boundary)
            println("hold_final=", hold_final, " exposure=", cursor.frame_sequence,
                " active_command=", cursor.active_command_sequence, " command=", boundary.command_input,
                " model_sequence=", model_time_sequence(science.driver))
            @test cursor.frame_sequence == model_time_sequence(science.driver) == 1
            @test !cursor.command_response_required
            @test cursor.active_command_sequence == (hold_final ? 0 : 1)
            @test (boundary.command_input == initial) == hold_final
        finally
            if native !== nothing
                with_thread_loop_lock(pipewire.loop) do _
                    foreach(close, reverse(native.links))
                    close(native.producer)
                    close(native.registry)
                end
            end
            close(pipewire)
        end
    end
    fetch(task)
end

println("Julia ", VERSION, " candidate=", pathof(HIL), " RTC=", pathof(PipeWireAORTC),
    " native=", PipeWireAO_jll.artifact_dir)
@testset "finite managed lockstep report" begin
    _with_private_core() do remote
        trial(remote, false)
        trial(remote, true)
    end
end
