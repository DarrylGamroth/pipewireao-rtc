#!/usr/bin/env julia
using Test, PipeWireAO, JSON3

include(joinpath(@__DIR__, "..", "native_control_private_core.jl"))

length(ARGS) == 3 || error("usage: session_items.jl WIREPLUMBER_LIBRARY_PREFIX RTC_PREFIX FRESH_EVIDENCE_DIRECTORY")
const WP_PREFIX = realpath(ARGS[1])
const RTC_PREFIX = realpath(ARGS[2])
const EVIDENCE_DIRECTORY = abspath(ARGS[3])
const SCRIPT_SOURCE = joinpath(@__DIR__, "..", "data", "session_items", "validation.lua")
const SOURCE_NAME = "fixture.session-items.ndarray-source"
const SINK_NAME = "fixture.session-items.ndarray-sink"
const SCHEMA = "org.pipewireao.test.session-items/1"
const PORT_NAME = "output_1"
const INPUT_NAME = "input_1"

function wait_until(predicate, seconds, label; check=()->nothing)
    deadline = time_ns() / 1e9 + seconds
    while true
        check() === false && error("health check failed while waiting for: $label")
        predicate() && return nothing
        time_ns() / 1e9 < deadline || error("deadline expired: $label")
        sleep(0.01)
    end
end

function module_directory(prefix)
    for path in (joinpath(prefix, "lib/wireplumber-0.5"),
            joinpath(prefix, "lib/x86_64-linux-gnu/wireplumber-0.5"))
        isdir(path) && return path
    end
    error("candidate WirePlumber module directory is missing under $prefix")
end

function prepare_script_data(directory)
    data_dir = joinpath(directory, "wireplumber-data")
    scripts = joinpath(data_dir, "scripts")
    mkpath(scripts)
    symlink(joinpath(RTC_PREFIX, "share/pipewireao-rtc/scripts/lib"), joinpath(scripts, "lib"))
    source = read(SCRIPT_SOURCE, String)
    occursin("__EXPECTED_PIPEWIREAO_CLIENT_PID__", source) ||
        error("session-items Lua expected-PID placeholder is missing")
    validation_script = replace(source,
        "__EXPECTED_PIPEWIREAO_CLIENT_PID__" => string(getpid()))
    write(joinpath(scripts, "session-items-validation.lua"), validation_script)
    return data_dir
end

function write_application_files(directory, socket, data_dir)
    config = joinpath(directory, "rtc.conf")
    write(config, """
        context.properties = {
          remote.name = "$socket"
          support.dbus = false
          library.use-fallback = false
        }
        context.modules = [
          { name = libpipewire-module-protocol-native }
          { name = libpipewire-module-client-node }
        ]
        wireplumber.profiles = {
          ao-rtc = {
            support.lua-scripting = required
            rtc.transport = required
            fixture.session-items = required
          }
        }
        wireplumber.components = [
          { name = libwireplumber-module-lua-scripting, type = module
            provides = support.lua-scripting }
          { name = libwireplumber-module-ao-control-endpoint, type = module
            provides = rtc.transport
            arguments = { plugin.name = ao-session-control
              node.name = test-link-controller profile = pipewireao.rtc.controller/1 instance = 404 } }
          { name = "$(joinpath(data_dir, "scripts/session-items-validation.lua"))", type = script/lua
            provides = fixture.session-items
            requires = [ support.lua-scripting rtc.transport ] }
        ]
        """)
    return config
end

function registry_snapshot(loop, registry)
    return with_thread_loop_lock(loop) do _
        [(; interface=object.type, id=object.id, properties=copy(object.properties))
            for object in globals(registry)]
    end
end

function one_object(objects, interface, name)
    values = filter(objects) do object
        object.interface == interface && get(object.properties, "node.name", "") == name
    end
    return only(values)
end

function one_port(objects, node_id, direction, name)
    values = filter(objects) do object
        object.interface == "PipeWire:Interface:Port" &&
            get(object.properties, "node.id", "") == string(node_id) &&
            get(object.properties, "port.direction", "") == direction &&
            get(object.properties, "port.name", "") == name
    end
    return only(values)
end

function links_for_fixture(objects)
    return filter(objects) do object
        object.interface == "PipeWire:Interface:Link" &&
            startswith(get(object.properties, "object.path", ""),
                "pipewireao/session/validation/1/")
    end
end

function client_identity(loop, core, registry, node)
    client_id = parse(UInt32, node.properties["client.id"])
    info = Ref{Union{Nothing,ClientInfo}}(nothing)
    client = with_thread_loop_lock(loop) do _
        global_object = only(filter(object -> object.id == client_id &&
            object.type == "PipeWire:Interface:Client", globals(registry)))
        bind(registry, global_object, Client; on_info=(_, value)->(info[] = value))
    end
    try
        roundtrip(core)
        return with_thread_loop_lock(loop) do _
            info[] === nothing && error("client information was not observed")
            (; pid=parse(Int, info[].properties["application.process.id"]),
                name=get(info[].properties, "application.name", ""),
                daemon=get(info[].properties, "wireplumber.daemon", ""))
        end
    finally
        with_thread_loop_lock(loop) do _
            close(client)
        end
    end
end

function start_application(directory, socket, logfile, data_dir)
    config = write_application_files(directory, socket, data_dir)
    prefix = realpath(WP_PREFIX)
    candidate_lib = isdir(joinpath(prefix, "lib/x86_64-linux-gnu")) ?
        joinpath(prefix, "lib/x86_64-linux-gnu") : joinpath(prefix, "lib")
    environment = Dict(
        "WIREPLUMBER_MODULE_DIR" => joinpath(RTC_PREFIX, "lib/pipewireao-rtc/modules") * ":" * module_directory(prefix),
        "WIREPLUMBER_DATA_DIR" => data_dir,
        "WIREPLUMBER_DEBUG" => "W,session-items-validation:W",
        "LD_LIBRARY_PATH" => candidate_lib * ":" * get(ENV, "LD_LIBRARY_PATH", ""),
    )
    binary = joinpath(RTC_PREFIX, "bin/pipewireao-rtc")
    isfile(binary) || error("candidate headless RTC executable is missing: $binary")
    return run(pipeline(addenv(`$binary -c $config`, environment);
        stdout=logfile, stderr=logfile); wait=false)
end

function start_device_policy_peer(directory, socket, logfile)
    # An independent WirePlumber daemon exercises coexistence on the private
    # core. No device monitors or desktop routing are loaded by this test.
    config = joinpath(directory, "device-policy-peer.conf")
    write(config, """
        context.properties = { remote.name = "$socket" support.dbus = false
          library.use-fallback = false }
        context.modules = [ { name = libpipewire-module-protocol-native } ]
        wireplumber.profiles = { device-policy-peer = {} }
        wireplumber.components = []
        """)
    binary = joinpath(WP_PREFIX, "bin/wireplumber")
    isfile(binary) || error("coexistence WirePlumber executable is missing: $binary")
    library = dirname(module_directory(WP_PREFIX))
    environment = Dict("LD_LIBRARY_PATH" => library * ":" * get(ENV, "LD_LIBRARY_PATH", ""))
    return run(pipeline(addenv(`$binary -c $config -p device-policy-peer`, environment);
        stdout=logfile, stderr=logfile); wait=false)
end

function verify_registry_link(loop, core, registry, source_id, sink_id)
    objects = registry_snapshot(loop, registry)
    source = one_object(objects, "PipeWire:Interface:Node", SOURCE_NAME)
    sink = one_object(objects, "PipeWire:Interface:Node", SINK_NAME)
    @test source.id == source_id
    @test sink.id == sink_id
    out = one_port(objects, source_id, "out", PORT_NAME)
    input = one_port(objects, sink_id, "in", INPUT_NAME)
    link = only(links_for_fixture(objects))
    @test client_identity(loop, core, registry, source).pid == getpid()
    @test client_identity(loop, core, registry, sink).pid == getpid()
    @test link.properties["link.output.node"] == string(source_id)
    @test link.properties["link.output.port"] == string(out.id)
    @test link.properties["link.input.node"] == string(sink_id)
    @test link.properties["link.input.port"] == string(input.id)
    return link
end

function main()
    directory = EVIDENCE_DIRECTORY
    !ispath(directory) && !islink(directory) || error("evidence directory must be fresh")
    mkpath(directory; mode=0o700)
    receipt_path = joinpath(directory, "receipt.json")
    receipt = Dict{String,Any}("result" => "running", "run_directory" => directory,
        "cleanup" => Dict{String,Any}(), "samples" => Vector{Vector{Float32}}())
    try
        @testset "CPU-only headless RTC standard Link" begin
        with_control_private_core() do socket, runtime, daemon
            receipt["private_core_pid"] = getpid(daemon)
            loop = ThreadLoop("session-items-validation")
            context = core = registry = nothing
            source = sink = unrelated = nothing
            manager = nothing
            peer = nothing
            manager_log_path = joinpath(directory, "rtc.log")
            manager_log = open(manager_log_path, "w+")
            peer_log = open(joinpath(directory, "device-policy-peer.log"), "w+")
            try
                with_thread_loop_lock(loop) do _
                    context = Context(loop)
                    core = CoreConnection(context; properties=Dict("remote.name" => socket))
                    registry = Registry(core)
                end
                start!(loop)
                format = NdArrayFormat(NdArray.F32_LE, (2,);
                    layout=NdArray.ROW_MAJOR, rate=PipeWireAO.SPA.Fraction(100, 1))
                source = NdArraySource(core, SOURCE_NAME, zeros(Float32, 2), format;
                    schema=SCHEMA)
                sink = NdArraySink(core, SINK_NAME, zeros(Float32, 2), format;
                    schema=SCHEMA)
                start!(source)
                start!(sink)
                unrelated = NdArraySource(core, "unrelated.ndarray-source", zeros(Float32, 2), format;
                    schema=SCHEMA)
                start!(unrelated)
                # Dispatch source/sink creation and protocol negotiation before
                # The headless RTC starts, so first-use Julia work is outside the
                # 30-second native-link exchange window.
                roundtrip(core)
                wait_until(10, "source and sink nodes published") do
                    node_id(source) != typemax(UInt32) && node_id(sink) != typemax(UInt32) &&
                        node_id(unrelated) != typemax(UInt32)
                end
                data_dir = prepare_script_data(directory)
                peer = start_device_policy_peer(runtime, socket, peer_log)
                receipt["wireplumber_peer_pid"] = getpid(peer)
                manager = start_application(runtime, socket, manager_log, data_dir)
                receipt["rtc_pid"] = getpid(manager)
                healthy() = !Base.process_exited(daemon) && !Base.process_exited(manager) &&
                    !Base.process_exited(peer) && isrunning(loop)
                wait_until(20, "production ao-connections realized a native NDArray link"; check=healthy) do
                    occursin("session-items-validation: REALIZED validation/1",
                        read(joinpath(directory, "rtc.log"), String))
                end
                source_node, sink_node = node_id(source), node_id(sink)
                receipt["source"] = Dict("name" => SOURCE_NAME, "node_id" => source_node,
                    "client_pid" => getpid(), "port_name" => PORT_NAME,
                    "schema" => SCHEMA, "shape" => [2], "element_type" => "F32_LE")
                receipt["sink"] = Dict("name" => SINK_NAME, "node_id" => sink_node,
                    "client_pid" => getpid(), "port_name" => INPUT_NAME,
                    "schema" => SCHEMA, "shape" => [2], "element_type" => "F32_LE")
                wait_until(5, "realized link visible in client registry"; check=healthy) do
                    !isempty(links_for_fixture(registry_snapshot(loop, registry)))
                end
                link = verify_registry_link(loop, core, registry, source_node, sink_node)
                @test link.properties["client.id"] !== nothing
                identity = client_identity(loop, core, registry, link)
                @test identity.pid == getpid(manager)
                @test identity.name == "PipeWireAO RTC"
                @test identity.daemon != "true"
                receipt["link_owner"] = Dict("pid" => identity.pid,
                    "application_name" => identity.name, "wireplumber_daemon" => identity.daemon)
                receipt["link"] = Dict("global_id" => link.id,
                    "client_id" => link.properties["client.id"],
                    "output_node" => link.properties["link.output.node"],
                    "output_port" => link.properties["link.output.port"],
                    "input_node" => link.properties["link.input.node"],
                    "input_port" => link.properties["link.input.port"])
                for sequence in UInt64(1):UInt64(3)
                    sample = Float32(sequence)
                    values = Float32[sample, -sample]
                    arm_array_sink!(sink, sequence)
                    token = submit_array!(source, values,
                        BufferHeader(UInt32(0), UInt32(0), Int64(0), Int64(0), sequence))
                    wait_array_sink!(sink; timeout_ns=2_000_000_000)
                    wait_array_source!(source, token; timeout_ns=2_000_000_000)
                    @test array_values(sink) == values
                    push!(receipt["samples"], copy(array_values(sink)))
                end
                wait_until(45, "production ao-connections withdrew and retired the link"; check=healthy) do
                    occursin("session-items-validation: WITHDRAWN validation/1",
                        read(joinpath(directory, "rtc.log"), String))
                end
                wait_until(5, "retired link absent from client registry"; check=healthy) do
                    isempty(links_for_fixture(registry_snapshot(loop, registry)))
                end
                @test one_object(registry_snapshot(loop, registry), "PipeWire:Interface:Node",
                    "unrelated.ndarray-source").id == node_id(unrelated)
                @test !Base.process_exited(peer)
                peer_clients = filter(object -> object.interface == "PipeWire:Interface:Client",
                    registry_snapshot(loop, registry))
                peer_identities = [client_identity(loop, core, registry,
                    (; properties=Dict("client.id" => string(object.id)))) for object in peer_clients]
                @test any(identity -> identity.pid == getpid(peer) && identity.daemon == "true",
                    peer_identities)
            finally
                cleanup_errors = String[]
                if manager !== nothing
                    try
                        stop_proof_child!(manager, "isolated headless RTC application")
                        receipt["cleanup"]["rtc_exited"] = true
                    catch error
                        push!(cleanup_errors, "RTC: $(sprint(showerror, error))")
                    end
                end
                if peer !== nothing
                    try
                        stop_proof_child!(peer, "isolated WirePlumber policy peer")
                        receipt["cleanup"]["wireplumber_peer_exited"] = true
                    catch error
                        push!(cleanup_errors, "WirePlumber peer: $(sprint(showerror, error))")
                    end
                end
                close(peer_log)
                try
                    with_thread_loop_lock(loop) do _
                        for endpoint in (unrelated, sink, source, registry, core, context)
                            if endpoint !== nothing
                                try
                                    close(endpoint)
                                    push!(get!(receipt["cleanup"], "closed_resources", String[]),
                                        string(typeof(endpoint)))
                                catch error
                                    push!(cleanup_errors,
                                        "$(typeof(endpoint)): $(sprint(showerror, error))")
                                end
                            end
                        end
                    end
                catch error
                    push!(cleanup_errors, "PipeWire client: $(sprint(showerror, error))")
                end
                try
                    close(loop)
                    receipt["cleanup"]["thread_loop_closed"] = true
                catch error
                    push!(cleanup_errors, "thread loop: $(sprint(showerror, error))")
                end
                flush(manager_log)
                receipt["rtc_log"] = read(manager_log_path, String)
                receipt["private_core_log"] = read(joinpath(runtime, "private-core.log"), String)
                receipt["cleanup"]["rtc_exited"] = manager === nothing || Base.process_exited(manager)
                receipt["cleanup"]["pipewire_daemon_running_before_owned_stop"] = !Base.process_exited(daemon)
                receipt["cleanup"]["errors"] = cleanup_errors
                isopen(manager_log) && close(manager_log)
                isempty(cleanup_errors) || error("fixture cleanup failed: $(join(cleanup_errors, "; "))")
            end
        end
        end # Outermost testset throws before a failed run can be recorded as passed.
        receipt["cleanup"]["private_core_stopped_by_owned_helper"] = true
        receipt["result"] = "passed"
    catch error
        receipt["result"] = "failed"
        receipt["error"] = sprint(showerror, error)
        rethrow()
    finally
        write(receipt_path, JSON3.write(receipt))
    end
end

if abspath(PROGRAM_FILE) == (@__FILE__)
    main()
end
