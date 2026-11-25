# Run with the RTC test workspace and a private registered seed Project/Manifest.
# Requires a reachable Linux systemd user manager and a matching PipeWireAO SDK.
module PortableDirectSessionTests

using Test, PipeWireAO, PipeWireAORTC, UUIDs

include(joinpath(@__DIR__, "..", "control_private_core.jl"))

const RTC = PipeWireAORTC
const Runtime = RTC.SessionRuntime
const Systemd = RTC.SystemdOwners
const D = RTC.DeploymentConfiguration
const Discovery = RTC.SessionDiscovery
const SOURCE = "portable.detector"
const SINK = "portable.sink"
const SCHEMA = "test/portable-detector-f32/1"

systemctl(args...) = `systemctl --user $args`

function start_unit(unit, cpu, command, environment)
    settings = ["--setenv=$key=$value" for (key, value) in environment]
    run(`systemd-run --user --quiet --collect --unit=$unit --property=Type=exec
        --property=CPUAffinity=$cpu --property=TimeoutStopSec=10s $settings $command`)
    return nothing
end

function native_config(directory, socket, cpu, paths)
    remote = basename(socket)
    write(joinpath(directory, "core.conf"), """
context.properties = { core.daemon = true core.name = $remote support.dbus = false library.use-fallback = false }
context.spa-libs = { support.* = support/libspa-support }
context.data-loops = [
    { loop.name = rtc-data-loop loop.class = data.rt loop.rt-prio = 0 thread.affinity = [$cpu] }
    { loop.name = telemetry-loop loop.class = [] loop.rt-prio = 0 thread.affinity = [$cpu] }
]
context.modules = [
    { name = libpipewire-module-scheduler-v1 }
    { name = libpipewire-module-protocol-native }
    { name = libpipewire-module-client-node }
    { name = libpipewire-module-link-factory args = { allow.link.passive = true } }
    { name = libpipewire-module-metadata }
    { name = libpipewire-module-access }
]
""")
    write(joinpath(directory, "client.conf"), """
context.properties = { support.dbus = false library.use-fallback = false }
context.spa-libs = { support.* = support/libspa-support }
context.modules = [
    { name = libpipewire-module-protocol-native }
    { name = libpipewire-module-client-node }
]
""")
    return Dict(
        "PIPEWIREAO_RUNTIME_DIR" => dirname(socket),
        "PIPEWIREAO_CONFIG_DIR" => directory,
        "PIPEWIREAO_MODULE_DIR" => paths["modules"],
        "PIPEWIREAO_SPA_PLUGIN_DIR" => paths["spa"],
        "LD_LIBRARY_PATH" => paths["library"],
    )
end

function native_registry(socket, prefix, environment)
    dump = joinpath(prefix, "bin", "pwao-dump")
    result = RTC.Common.run_checked([dump, "-N", "-r", socket];
        env = Dict(environment), timeout = 5)
    result.returncode == 0 || error(result.stderr)
    return RTC.Common.parse_json(result.stdout)
end

function exported_port(objects, node, direction)
    nodes = filter(objects) do item
        item["type"] == "PipeWire:Interface:Node" &&
            get(item["info"]["props"], "node.name", nothing) == node
    end
    isempty(nodes) && return nothing
    id = only(nodes)["id"]
    ports = filter(objects) do item
        item["type"] == "PipeWire:Interface:Port" &&
            string(get(item["info"]["props"], "node.id", nothing)) == string(id) &&
            get(item["info"]["props"], "port.direction", nothing) == direction
    end
    isempty(ports) && return nothing
    return only(ports)["info"]["props"]["port.name"]
end

function export_detector(
    directory, seed, prefix, cpu, output, input, environment; detector_threads = []
)
    authored = mkpath(joinpath(directory, "detector"))
    mkpath(joinpath(authored, "rtc"))
    for name in ("Project.toml", "Manifest.toml")
        cp(joinpath(seed, name), joinpath(authored, name))
    end
    session_environment = Dict(key => environment[key] for key in
        ("JULIA_DEPOT_PATH", "JULIA_LOAD_PATH", "OPENBLAS_NUM_THREADS", "TMPDIR"))
    spec = Dict(
        "version" => 1, "name" => "portable-detector", "session" => "session.conf",
        "core" => "shared-runtime/core.conf.in", "environment" => Dict(),
        "cpu-latency-us" => nothing,
        "client" => Dict(role => "shared-runtime/client-simulator.conf.in" for role in
            ("core", "session", "detector")),
        "owners" => [Dict("role" => "detector", "control-protocol" => "external-stream")],
        "source-owner" => "detector", "node-owners" => Dict(SOURCE => "detector", SINK => "detector"),
        "session-runtime" => Dict(
            "argv" => ["@PACKAGE@/rtc/bin/pipewireao-rtc", "-c", "@RUNTIME@/rtc/rtc.conf"],
            "environment" => session_environment,
        ),
        "runtime" => Dict("kind" => "registered", "project" => "."),
        "runtime-configurations" => [
            Dict("source" => "rtc/session.yaml", "path" => "session.conf", "format" => "spa-json"),
        ],
    )
    spec["client"]["rtc"] = "shared-runtime/client-rtc.conf.in"
    node(name, port, direction) = Dict("node.name" => name, "ownership" => "external",
        "ports" => [Dict("name" => port, "direction" => direction, "element-type" => "F32_LE",
            "shape" => [2], "schema" => SCHEMA, "layout" => "ROW_MAJOR")])
    for (file, document) in (
        "instrument.yaml" => Dict("schema_version" => 1, "id" => "portable-detector",
            "deformable_mirrors" => Dict(), "wavefront_sensors" => Dict("camera" => Dict(
                "kind" => "scc", "expected_schema" => SCHEMA, "detector" => Dict(
                    "name" => "camera", "rows" => 1, "columns" => 2,
                    "pixel_sampling_m" => [1e-6, 1e-6],
                ),
            ))),
        "rtc/configuration.yaml" => Dict("schema_version" => 1, "instrument" => "../instrument.yaml",
            "dimensions" => Dict(), "mirror_controls" => "rtc/mirror-controls.yaml",
            "publication" => "instrument.json", "calibration_identity" => "sha256:" * "0"^64),
        "rtc/mirror-controls.yaml" => Dict("schema_version" => 1, "deformable_mirrors" => Dict()),
        "rtc/application.yaml" => spec,
        "rtc/session.yaml" => Dict("sources" => [node(SOURCE, output, "output")],
            "sinks" => [node(SINK, input, "input")], "graphs" => [],
            "links" => [Dict("output" => "$SOURCE:$output", "input" => "$SINK:$input")]),
    )
        RTC.Common.write_yaml(joinpath(authored, file), document)
    end
    RTC.ScienceExport.write_spa_config(joinpath(authored, "rtc/core.conf"), Dict("context.modules" => []))
    processes = Dict(role => Dict{String,Any}("cpus" => [cpu], "leader-cpu" => cpu) for role in
        ("core", "rtc", "session", "detector"))
    processes["detector"]["threads"] = detector_threads
    processes["core"]["data-loops"] = Dict("rtc-data-loop" => [cpu], "telemetry-loop" => [cpu])
    processes["rtc"]["data-loops"] = Dict("rtc-data-loop" => [cpu])
    profile = Dict("scheduling" => Dict("processes" => processes))
    return RTC.InstrumentExport.prepare(authored, joinpath(directory, "application"); profile, prefix)
end

deadline(seconds) = RTC.ControlClient.monotonic() + seconds

function published_session(directory, id)
    return filter(Discovery.list_sessions(directory)) do entry
        entry.record !== nothing && entry.record.session_id == id
    end
end

function operator_cli(args...)
    return mktemp() do _, io
        exitcode = redirect_stdout(() -> RTC.SessionCLI.main(collect(args)), io)
        @test exitcode == 0
        seekstart(io)
        return RTC.Common.parse_json(read(io, String))
    end
end

function check_attachment(seed, root; reject_placement = false)
    prefix = get(ENV, "PIPEWIREAO_PREFIX", String(PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir))
    paths = D.installed_paths(prefix)
    cpu = maximum(RTC.Placement.inherited_cpus())
    cpu >= 2 || error("a usable CPU above CPU 1 is required by installed RTC placement")
    tag = first(replace(string(uuid4()), "-" => ""), 12)
    core_unit = "portable-rtc-core-$tag.service"
    provider_unit = "portable-rtc-provider-$tag.service"
    socket = joinpath(root, "core")
    environment = native_config(root, socket, cpu, paths)
    environment["JULIA_DEPOT_PATH"] = join(DEPOT_PATH, ':')
    environment["JULIA_LOAD_PATH"] = "@:@stdlib"
    environment["OPENBLAS_NUM_THREADS"] = "1"
    environment["TMPDIR"] = "/var/tmp"
    julia = D.selected_julia_executable(Base.julia_cmd().exec[1])
    project = dirname(Base.active_project())
    provider = joinpath(@__DIR__, "portable_direct_provider.jl")
    stage = joinpath(root, "stage")
    handle = nothing
    # Resolve the cold package image before the start helper's installer budget.
    run(addenv(`$julia --startup-file=no --threads=1,0 --project=$seed -e 'using PipeWireAORTC'`,
        "JULIA_DEPOT_PATH" => environment["JULIA_DEPOT_PATH"],
        "JULIA_LOAD_PATH" => environment["JULIA_LOAD_PATH"]))
    try
        start_unit(core_unit, cpu, `$(paths["daemon"]) -c core.conf`, environment)
        wait_proof(() -> ispath(socket), 10, "independent core socket")
        start_unit(provider_unit, cpu, `$julia --startup-file=no --threads=1,0 --project=$project
            $provider $socket $SOURCE $SINK $SCHEMA`, environment)
        ports = Ref{Tuple{String,String}}()
        wait_proof(40, "independent detector and sink Ports") do
            objects = native_registry(socket, prefix, environment)
            output = exported_port(objects, SOURCE, "out")
            input = exported_port(objects, SINK, "in")
            (output === nothing || input === nothing) && return false
            ports[] = (output, input)
            return true
        end
        core = Systemd.properties(core_unit)
        provider_identity = Systemd.properties(provider_unit)
        required_thread = Dict(
            "name" => "required-probe", "cpus" => [cpu],
            "policy" => "other", "priority" => 0, "count" => 1,
        )
        application = export_detector(
            root, seed, prefix, cpu, ports[]..., environment;
            detector_threads = reject_placement ? [required_thread] : [],
        )
        withenv("JULIA_NUM_THREADS" => "1,0", "JULIA_LOAD_PATH" => environment["JULIA_LOAD_PATH"],
            "PIPEWIREAORTC_CORE_UNIT" => core_unit, "PIPEWIREAORTC_CORE_SOCKET" => socket,
            "PIPEWIREAORTC_SOURCE_UNIT" => provider_unit) do
            if reject_placement
                unexpected = nothing
                try
                    @test_throws "systemd session operation failed" unexpected =
                        Runtime.start!(application, stage; prefix, deadline = deadline(300))
                finally
                    unexpected === nothing || Runtime.stop!(unexpected; deadline = deadline(60))
                end
                failure = RTC.Common.read_json(joinpath(stage, "start-failure.json"))
                @test failure["cleanup_confirmed"] === true
                @test !isfile(joinpath(stage, "session.json"))
                registry = Discovery.existing_registry_directory()
                @test registry === nothing || !any(Discovery.list_sessions(registry)) do entry
                    entry.record !== nothing && entry.record.remote == socket
                end
                rejected_unit = failure["unit"]
                journal = read(`journalctl --user --unit=$rejected_unit --no-pager -o cat`, String)
                @test occursin("requires 1 thread(s) matching", journal) &&
                    occursin(required_thread["name"], journal) && occursin("observed 0", journal)
                @test Systemd.quiescent_unit(rejected_unit)
                run(pipeline(ignorestatus(systemctl("reset-failed", rejected_unit)); stderr = devnull))
                @test Systemd.properties(provider_unit)["InvocationID"] ==
                    provider_identity["InvocationID"]
                bus = native_registry(socket, prefix, environment)
                @test !any(item -> item["type"] == "PipeWire:Interface:Link", bus)
                @test exported_port(bus, SOURCE, "out") == ports[][1]
                return nothing
            end
            handle = Runtime.start!(application, stage; prefix, deadline = deadline(300))
        end
        reject_placement && return nothing
        attached = Runtime.attach(stage; deadline = deadline(20))
        @test attached.invocation == handle.invocation
        @test Runtime.attach(handle.unit; deadline = deadline(20)).main_pid == attached.main_pid
        ready = Runtime.ready(attached; deadline = deadline(20))
        @test ready["phase"] == "ready" && ready["admitted"] === true
        @test ready["source_endpoint"] == Dict("profile" => "external-stream")
        @test ready["observation_remote"] == socket
        @test ready["processes"]["core"]["pid"] == parse(Int, core["MainPID"])
        @test ready["processes"]["detector"]["pid"] == parse(Int, provider_identity["MainPID"])
        @testset "Ready retains observed owner placement" begin
            record = RTC.Common.read_json(joinpath(attached.runtime_root, "launch.json"))
            placement = record["placement_snapshot"]
            @test Set(keys(placement)) == Set(("core", "detector", "session"))
            for (role, pid) in (
                ("core", parse(Int, core["MainPID"])),
                ("detector", parse(Int, provider_identity["MainPID"])),
                ("session", attached.main_pid),
            )
                observed = placement[role]
                @test observed["pid"] == pid
                leader = only(filter(thread -> thread["tid"] == pid, observed["threads"]))
                @test (leader["cpus"], leader["policy"], leader["priority"]) == ([cpu], 0, 0)
                @test all(thread -> thread["cpus"] == [cpu], observed["threads"])
                contract = role == "session" ? record["admission"]["placement"] :
                    record["owners"][role]["placement"]
                live = RTC.Placement.snapshot(pid, contract)
                @test leader == only(filter(thread -> thread["tid"] == pid, live["threads"]))
                @test observed["locked_bytes"] >= contract["locked-bytes"]
            end
        end
        registry = native_registry(socket, prefix, environment)
        link = only(filter(item -> item["type"] == "PipeWire:Interface:Link", registry))
        @test startswith(link["info"]["props"]["object.path"], "pipewireao/session/")
        id = ready["ready"]["session_id"]
        directory = Discovery.existing_registry_directory()
        locator = joinpath(directory, "session-$id.pod")
        @testset "Installed process binding rejects extra Julia arguments" begin
            launch = RTC.Common.read_json(joinpath(attached.runtime_root, "launch.json"))
            binding = launch["session_process"]
            argv = insert!(copy(binding["argv"]), 2, "--code-coverage=user")
            @test_throws r"invalid headless RTC process arguments" D.verify_session_process(
                attached.main_pid, merge(binding, Dict("argv" => argv)),
            )
        end
        @testset "A second process cannot claim an admitted installation" begin
            receipt_path = joinpath(attached.runtime_root, "launch.json")
            before = read(receipt_path)
            record = RTC.Common.parse_json(String(copy(before)))
            package = record["admission"]["package"]
            activation = RTC.Common.read_json(joinpath(package, "systemd", RTC.SessionLaunch.ACTIVATION_FILE))
            observe = _ -> error("unexpected second admission")
            withenv("PIPEWIREAORTC_CORE_UNIT" => core_unit, "PIPEWIREAORTC_CORE_SOCKET" => socket,
                "PIPEWIREAORTC_SOURCE_UNIT" => provider_unit) do
                @test_throws "unexpected startup policy" RTC.SessionAdmission.with_direct_attachment(
                    observe, record["config"], activation, handle.unit, attached.runtime_root, handle.invocation,
                )
                withenv("PIPEWIREAORTC_SOURCE_UNIT" => "other-provider-$tag.service") do
                    @test_throws "service bindings differ" RTC.SessionAdmission.with_direct_attachment(
                        observe, record["config"], activation, handle.unit, attached.runtime_root, handle.invocation,
                    )
                end
            end
            # Delayed cleanup for an earlier incarnation must preserve this locator.
            stale = merge(record, Dict("session_control_instance" => record["session_control_instance"] - 1))
            RTC.SessionAdmission.retire_record!(stale, locator)
            @test isfile(locator) && read(receipt_path) == before
        end
        @testset "Installed MediaSession publishes a live Ready locator" begin
            @test isfile(locator)
            entry = only(published_session(directory, id))
            @test entry.record.owner_pid == attached.main_pid
            @test entry.record.remote == socket
            @test entry.record.node_name == "pipewireao.rtc.session.portable-detector"
            client = RTC.SessionClient.select_direct_session(entry; deadline = deadline(20))
            @test client isa RTC.SessionClient.Connection
            if client isa RTC.SessionClient.Connection
                try
                    status = client.selected.status
                    @test status.session_id == id && status.lifecycle === :ready
                    @test status.owner_pid == attached.main_pid
                    @test status.incarnation == entry.record.incarnation
                finally
                    close(client)
                end
            end
        end
        @testset "Operator CLI selects, restarts and holds the software RTC" begin
            selected = operator_cli("select-session", "--session", id)
            @test (selected["session_id"], selected["owner_pid"], selected["lifecycle"]) ==
                  (id, attached.main_pid, "ready")
            command(args...) = operator_cli("control", "--session", id, "--", args...)
            started = command("session-start")
            @test started["ok"] && started["state"] == "Running"
            restarted = operator_cli("restart", "--session", id)
            @test all(restarted[k]["session_id"] == id for k in ("hold", "reset", "start"))
            @test [restarted[k]["state"] for k in ("hold", "reset", "start")] ==
                  ["Ready", "Ready", "Running"]
            held = command("session-stop")
            @test held["ok"] && held["state"] == "Ready"
        end
        stopped = Runtime.stop!(attached; deadline = deadline(60))
        @test stopped["direct_attach"] && stopped["phase"] == "stopped"
        @test stopped["cleanup_complete"] && stopped["service_result"] == "success"
        @test Runtime.final_record(stage)["invocation"] == handle.invocation
        @test Systemd.quiescent_unit(handle.unit)
        @testset "Native Quit withdraws installed discovery" begin
            @test stopped["discovery_locator"] == locator
            @test !ispath(locator)
            @test isempty(published_session(directory, id))
        end
        for (unit, before) in ((core_unit, core), (provider_unit, provider_identity))
            after = Systemd.properties(unit)
            @test after["ActiveState"] == "active"
            @test after["MainPID"] == before["MainPID"]
            @test after["InvocationID"] == before["InvocationID"]
        end
        registry = native_registry(socket, prefix, environment)
        @test !any(item -> item["type"] == "PipeWire:Interface:Link", registry)
        @test exported_port(registry, SOURCE, "out") == ports[][1]
    catch
        session_unit = if handle !== nothing
            handle.unit
        else
            pending = joinpath(stage, "pending-session.json")
            isfile(pending) ? RTC.Common.read_json(pending)["unit"] : nothing
        end
        units = session_unit === nothing ? (core_unit, provider_unit) :
                (core_unit, provider_unit, session_unit)
        for unit in units
            run(ignorestatus(`journalctl --user --unit=$unit --no-pager -n 40`))
        end
        rethrow()
    finally
        if handle !== nothing
            run(pipeline(ignorestatus(systemctl("stop", handle.unit)); stderr = devnull))
            run(pipeline(ignorestatus(systemctl("disable", "--runtime", handle.unit)); stderr = devnull))
            isdir(handle.runtime_root) && rm(handle.runtime_root; recursive = true)
        end
        for unit in (provider_unit, core_unit)
            run(pipeline(ignorestatus(systemctl("stop", unit)); stderr = devnull))
        end
    end
end

length(ARGS) == 1 || error("usage: portable_direct_session.jl REGISTERED_SEED_DIRECTORY")
@testset "Installed RTC direct attachment and native Quit" begin
    seed = realpath(only(ARGS))
    mktempdir("/var/tmp"; prefix = "rtc-direct-") do directory
        check_attachment(seed, directory)
    end
    @testset "Installed admission rejects a missing provider thread" begin
        mktempdir("/var/tmp"; prefix = "rtc-direct-") do directory
            check_attachment(seed, directory; reject_placement = true)
        end
    end
end

end
