# Opt-in non-actuating application integration. Only fresh owned units are used.
using Test, PipeWireAORTC, PipeWireAO

include("classic_observation.jl")

const R = PipeWireAORTC
const W = R.WirePlumberSessionRuntime
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

function source_snapshot(graph)
    source = only(filter(graph) do object
        info = get(object, "info", Dict())
        get(get(info, "props", Dict()), "node.name", nothing) == "simulator-wfs"
    end)
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
                "277","org.calculon.ao.pdm-engineering-offset/1",path])
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
        initial = source_snapshot(dump_graph(handle,stage,prefix,"graph-ready"))
        checked(!initial["running"] && initial["sequence"] == 0,
            "source published frames before explicit release")
        saved_report(handle, stage, "initial", initial)
        graph = "revolt-classic-jfg-frame-graph"
        properties=request(handle,stage,"properties",["properties",graph])
        start = request(handle,stage,"start",["session-start"])
        checked(start["state"] == "Running","source did not start")
        sleep(2)
        running = request(handle,stage,"running",["status"])
        checked(running["state"] == "Running","session faulted during exchanges")
        check_updates(handle,application,stage,graph,properties)
        dump_graph(handle,stage,prefix,"graph-running")
        stopped = request(handle,stage,"stop",["session-stop"])
        checked(stopped["state"] == "Ready","source did not stop")
        before_reset = source_snapshot(dump_graph(handle,stage,prefix,"graph-stopped"))
        checked(!before_reset["running"] && before_reset["sequence"] > 0,
            "source did not adopt a frame/command exchange")
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
