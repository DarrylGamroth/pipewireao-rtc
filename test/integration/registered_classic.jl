# Opt-in non-actuating application integration. Only fresh owned units are used.
using Test, PipeWireAORTC, PipeWireAO, TOML

include("classic_observation.jl")

const R = PipeWireAORTC
const W = R.SessionRuntime
const C = R.Common
const Commands = R.RunnerCommands

function checked(condition, message)
    @test condition
    condition || error(message)
end

function request(handle, stage, name, fields)
    reply = W.control!(handle, Commands.parse(fields); deadline=W.monotonic()+15)
    C.write_json(joinpath(stage,name*".json"),reply)
    checked(reply["ok"] === true, "$name rejected")
    println("CLASSIC_CHECK ",name," state=",reply["state"])
    flush(stdout)
    return reply
end

function dump_graph(handle, stage, prefix, name)
    ledger = C.read_json(joinpath(handle.runtime_root,handle.invocation,"launch.json"))
    result = C.run_checked([joinpath(prefix,"bin/pwao-dump"),"-N","-r",ledger["remote"]];
        env=merge(Dict(ENV),Dict("LD_LIBRARY_PATH"=>R.DeploymentConfiguration.installed_paths(prefix)["library"])),
        timeout=20, maximum_output_bytes=16*1024*1024)
    checked(result.returncode == 0,"native graph inspection failed")
    path=joinpath(stage,name*".json")
    write(path,result.stdout)
    return C.read_json(path; maximum=16*1024*1024)
end

function simulator_node(graph)
    return only(filter(graph) do object
        info = get(object, "info", Dict())
        get(get(info, "props", Dict()), "node.name", nothing) == "simulator-wfs"
    end)
end

function source_snapshot(graph)
    source = simulator_node(graph)
    records = source["info"]["params"]["Props"]
    fields = only(filter(records) do record
        params = get(record, "params", Any[])
        !isempty(params) && first(params) == "pipewireao.source-snapshot.version"
    end)["params"]
    return Dict(replace(fields[index], "pipewireao.source-snapshot." => "") => fields[index+1]
        for index in 1:2:length(fields))
end

function saved_report(handle, stage, name, snapshot)
    ledger = C.read_json(joinpath(handle.runtime_root, handle.invocation, "launch.json"))
    path = joinpath(dirname(ledger["remote"]), "simulator-wfs-report.json")
    report = C.read_json(path)
    checked(report["generation"] == snapshot["generation"] &&
        report["sequence"] == snapshot["sequence"], "saved report cursor differs from native acknowledgement")
    checked(report["source_instance"] == snapshot["instance"], "saved report source incarnation differs")
    C.write_json(joinpath(stage, name*"-report.json"), report)
end

function check_simulator_metadata(application, stage, graph)
    config_path = joinpath(stage, "installed", "simulation.conf")
    checked(C.sha256_file(config_path) == C.sha256_file(joinpath(application, "simulation.conf")),
        "installed simulator configuration differs from selected application")
    options = R.AOSOwner.configuration(config_path)
    checked(options.version == 2 && options.plant.package === :REVOLTClassicSim,
        "application does not select the managed Classic builder")
    manifest = TOML.parsefile(joinpath(stage, "installed", "Manifest.toml"))
    classic = only(manifest["deps"]["REVOLTClassicSim"])
    checked(classic["version"] == "0.2.1", "application does not select the Classic 0.2.1 candidate")
    checked(options.calibration_identity !== nothing, "startup calibration identity is missing")
    expected = Dict(
        "aos.simulation.package" => string(options.plant.package),
        "aos.simulation.package-version" => classic["version"],
        "aos.simulation.profile" => options.plant.settings.profile,
        "aos.simulation.backend" => string(options.backend),
        "aos.simulation.device" => string(options.device),
        "aos.simulation.model-period-ns" => string(options.period_ns),
        "aos.simulation.exposure-ns" => string(options.exposure_ns),
        "aos.simulation.configuration-sha256" => C.sha256_file(config_path),
        "aos.simulation.calibration-identity" => options.calibration_identity,
        # Classic 0.2.1's prepared atmosphere/CMOS construction seeds.
        "aos.simulation.atmosphere-rng-seed" => "1",
        "aos.simulation.detector-rng-seed" => "0")
    properties = simulator_node(graph)["info"]["props"]
    # pwao-dump presents numeric node-info strings as JSON numbers.
    observed = Dict(key => haskey(properties, key) ? string(properties[key]) : nothing
        for key in keys(expected))
    C.write_json(joinpath(stage, "simulator-metadata.json"), Dict(
        "configuration" => config_path, "expected" => expected, "observed" => observed,
        "calibration_identity_scope" => "declared startup identity; not live adoption"))
    for (key, value) in expected
        checked(observed[key] == value, "simulator metadata differs for $key")
    end
    return nothing
end

function check_invalid_control(handle, stage, graph, properties)
    key = "closed-loop-correction:gain"
    checked(properties["result"]["properties"][key]["type"] == "float", "gain is not Float32")
    baseline = request(handle, stage, "invalid-control-baseline",
        ["property-generation", graph, "closed-loop-correction"])
    # The supported CLI accepts Bool, but PropInfo declares this property Float.
    # The headless RTC rejects this mismatch before issuing a property transaction.
    fields = ["property", graph, key, "bool", "true"]
    reply = W.control!(handle, Commands.parse(fields); deadline=W.monotonic()+15)
    C.write_json(joinpath(stage, "invalid-control.json"), Dict("argv" => fields, "reply" => reply))
    checked(reply["ok"] === false && reply["state"] == "Running" && reply["error"] !== nothing,
        "incompatible scalar control was not rejected while preserving Running")
    checked(occursin("incompatible property", reply["error"]["message"]),
        "control rejection did not identify incompatible property declaration")
    after = request(handle, stage, "invalid-control-generation",
        ["property-generation", graph, "closed-loop-correction"])
    checked(after["result"]["requested"] == baseline["result"]["requested"] &&
        after["result"]["active"] == baseline["result"]["active"],
        "rejected control changed the property generation")
    current = request(handle, stage, "properties-after-invalid-control", ["properties", graph])
    checked(current["result"]["properties"][key] == properties["result"]["properties"][key],
        "rejected control changed the gain")
    checked(request(handle, stage, "survived-invalid-control", ["status"])["state"] == "Running",
        "session did not survive rejected control")
    return nothing
end

function save_cadence_window(stage, initial, stopped, start_before, start_after, stop_before, stop_after, options)
    checked(initial["instance"] == stopped["instance"] && initial["generation"] == stopped["generation"],
        "cadence cursor identities differ")
    completed = stopped["sequence"] - initial["sequence"]
    checked(completed >= 0, "cadence cursor regressed")
    # The owner starts and holds within the already-required command bounds.
    # Retained source Props are ACK cursors, not continuous counter telemetry.
    maximum_elapsed = (stop_after - start_before) / 1e9
    minimum_elapsed = (stop_before - start_after) / 1e9
    record = Dict(
        "method" => "completed owner ACK cursor delta over existing Start/Stop command bounds",
        "qualification" => false, "initial_cursor" => initial, "stopped_cursor" => stopped,
        "completed_exchanges" => completed, "declared_model_rate_hz" => options.rate,
        "configured_wall_rate_hz" => options.pacing_rate_hz,
        "start_command_before_ns" => start_before, "start_command_after_ns" => start_after,
        "stop_command_before_ns" => stop_before, "stop_command_after_ns" => stop_after,
        "maximum_elapsed_s" => maximum_elapsed, "minimum_elapsed_s" => minimum_elapsed,
        "mean_rate_lower_bound_hz" => maximum_elapsed > 0 ? completed / maximum_elapsed : nothing,
        "mean_rate_upper_bound_hz" => minimum_elapsed > 0 ? completed / minimum_elapsed : nothing,
        "scope" => "single local functional window; no deadline, tail latency or 500 Hz qualification")
    C.write_json(joinpath(stage, "cadence-window.json"), record)
    return record
end

function adopted(handle, stage, name, kind, graph, node; baseline=0)
    deadline = W.monotonic()+10
    while true
        reply = W.control!(handle,Commands.parse([kind,graph,node]);deadline)
        checked(reply["ok"] === true,"generation query rejected")
        generations = reply["result"]
        if generations["requested"] > baseline && generations["active"] == generations["requested"]
            C.write_json(joinpath(stage,name*".json"),reply)
            return reply
        end
        W.monotonic()<deadline || error("active adoption was not observed")
        sleep(0.05)
    end
end

function check_updates(handle, application, stage, graph, properties)
    key="closed-loop-correction:gain"
    scalar=properties["result"]["properties"][key]
    checked(scalar["type"] == "float","unexpected gain type")
    gain=reinterpret(Float32,UInt32(scalar["bits"]))
    # Submit the existing exact value as a scalar transaction; no gain is tuned.
    request(handle,stage,"same-gain-transaction",["properties-set",graph,key,"float",string(gain)])
    adopted(handle,stage,"gain-active","property-generation",graph,"closed-loop-correction")
    baseline=R.Artifacts.prepare(R.Artifacts.FITSArtifact(
        joinpath(application,"artifacts/engineering-offset.fits")),Float32,(277,))
    original=R.Artifacts.pack(baseline)
    baseline.data[1]+=0.001f0
    probe=R.Artifacts.pack(baseline)
    path,io=mktemp(stage)
    close(io)
    try
        # Native v1 live replacement still accepts transient packed wire bytes.
        # The application stores only its original FITS artifact; this temporary
        # native payload is removed after observed adoption/restoration.
        for (name,bytes) in (("offset-probe",probe),("offset-restore",original))
            previous = request(handle,stage,name*"-baseline",
                ["parameter-generation",graph,"engineering-offset"])
            write(path,bytes)
            request(handle,stage,name,["parameter",graph,"engineering-offset","F32_LE",
                "277","pipewireao/dm-offset-opd-um-f32/1",path])
            adopted(handle,stage,name*"-active","parameter-generation",graph,"engineering-offset";
                baseline=previous["result"]["requested"])
            sleep(0.15)
        end
    finally
        rm(path;force=true)
    end
end

function main(application, stage, prefix)
    handle = W.start!(application,stage;prefix,deadline=W.monotonic()+1030)
    try
        ready = request(handle,stage,"ready",["status"])
        checked(ready["state"] == "Ready","source was not held at startup")
        ready_graph = dump_graph(handle,stage,prefix,"graph-ready")
        initial = source_snapshot(ready_graph)
        check_simulator_metadata(application, stage, ready_graph)
        checked(!initial["running"] && initial["sequence"] == 0,
            "source published frames before explicit release")
        saved_report(handle, stage, "initial", initial)
        graph = "revolt-classic-jfg-frame-graph"
        properties=request(handle,stage,"properties",["properties",graph])
        start_before = time_ns()
        start = request(handle,stage,"start",["session-start"])
        start_after = time_ns()
        checked(start["state"] == "Running","source did not start")
        sleep(2)
        running = request(handle,stage,"running",["status"])
        checked(running["state"] == "Running","session faulted during exchanges")
        check_invalid_control(handle,stage,graph,properties)
        check_updates(handle,application,stage,graph,properties)
        dump_graph(handle,stage,prefix,"graph-running")
        stop_before = time_ns()
        stopped = request(handle,stage,"stop",["session-stop"])
        stop_after = time_ns()
        checked(stopped["state"] == "Ready","source did not stop")
        before_reset = source_snapshot(dump_graph(handle,stage,prefix,"graph-stopped"))
        checked(!before_reset["running"] && before_reset["sequence"] > 0,
            "source did not adopt a frame/command exchange")
        options = R.AOSOwner.configuration(joinpath(stage, "installed", "simulation.conf"))
        save_cadence_window(stage, initial, before_reset,
            start_before, start_after, stop_before, stop_after, options)
        request(handle,stage,"reset",["reset"])
        reset = source_snapshot(dump_graph(handle,stage,prefix,"graph-reset"))
        checked(reset["generation"] == before_reset["generation"] + 1 &&
            reset["sequence"] == 0 && !reset["running"] && !reset["completed"],
            "reset did not establish a fresh held acquisition")
        checked(reset["report-generation"] == reset["generation"] && reset["report-sequence"] == 0,
            "reset acknowledged before report publication")
        saved_report(handle, stage, "reset", reset)
        request(handle,stage,"restart",["session-start"])
        sleep(1)
        checked(request(handle,stage,"running-after-reset",["status"])["state"] == "Running",
            "session did not resume after reset")
        ledger = C.read_json(joinpath(handle.runtime_root, handle.invocation, "launch.json"))
        observation = observe_classic(ledger["remote"]; timeout=45)
        C.write_json(joinpath(stage, "observation.json"), observation)
        checked(all(stream["distinct_sequences"] >= 2 for stream in values(observation["streams"])),
            "an observation queue did not deliver advancing samples")
        checked(observation["matching_wfs_identity"] !== nothing,
            "SHWFS observation group has no common acquisition identity")
        request(handle,stage,"final-stop",["session-stop"])
        resumed = source_snapshot(dump_graph(handle,stage,prefix,"graph-resumed"))
        checked(resumed["generation"] == reset["generation"] && resumed["sequence"] > 0 &&
            !resumed["running"], "source did not resume exchanges in the new generation")
    finally
        try
            W.shutdown!(handle;deadline=W.monotonic()+320)
        catch quit_error
            failures = Exception[quit_error]
            try
                C.write_json(joinpath(stage, "quit-failure.json"),
                    Dict("error" => sprint(showerror, quit_error)))
            catch diagnostic_error
                push!(failures, diagnostic_error)
            end
            # Failed tests still own their exact unit. Revoke that unit through
            # the bounded emergency cleanup API; never repeat the native Quit.
            try
                W.stop!(handle;deadline=W.monotonic()+320)
            catch cleanup_error
                push!(failures, cleanup_error)
            end
            throw(length(failures) == 1 ? only(failures) : CompositeException(failures))
        end
    end
    record = W.final_record(stage)
    checked(record["cleanup_complete"] === true,"exact owner cleanup was not established")
    checked(isempty(get(record,"cleanup_errors",Any[])),"cleanup retained errors")
    C.write_json(joinpath(stage,"qualification.json"),Dict("complete"=>true,
        "profile"=>"classic-cpu-jfg-cuda-aos", "application"=>application,
        "unit"=>handle.unit, "invocation"=>handle.invocation,
        "cleanup_complete"=>true))
end

@testset "registered Classic session lifecycle" begin
    length(ARGS)==3 || error("usage: registered_classic.jl APPLICATION FRESH_STAGE NATIVE_PREFIX")
    main(ARGS...)
end
