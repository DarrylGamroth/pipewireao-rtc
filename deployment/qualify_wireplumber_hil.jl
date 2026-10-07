#!/usr/bin/env julia
# Development-only coexistence qualification; existing runtime retains links.
module WirePlumberHILQualification
include("qualify_sustained.jl")
const S = SustainedQualification
const D, C = S.D, S.C
require(value, message) = value || error(message)

function registry(remote)
    command=addenv(`/opt/pipewireao/bin/pwao-dump -r $remote`,
        "LD_LIBRARY_PATH"=>"/opt/pipewireao/lib/x86_64-linux-gnu")
    C.parse_json(read(command, String))
end
properties(object) = object["info"]["props"]
identity(object) = (object["id"], properties(object)["object.serial"])
links(objects) = filter(object -> object["type"] == "PipeWire:Interface:Link", objects)
function verify_links(objects, original)
    actual = links(objects)
    require(Set(identity.(actual)) == Set(identity.(original)), "Runtime link cohort changed")
    for previous in original
        current = only(filter(object -> identity(object) == identity(previous), actual))
        require(current["info"]["state"] in ("active", "paused"), "Runtime link is not negotiated")
        require(current["info"]["format"] == previous["info"]["format"], "Negotiated format changed")
        require(properties(current)["client.id"] == properties(previous)["client.id"], "Link owner changed")
    end
end

function manifest(objects, ready, package)
    session = D.decode(joinpath(package,"session.conf.in"),"/opt/pipewireao")
    names = Set(v["node.name"] for group in ("sources","graphs","sinks") for v in session[group])
    nodes = filter(object -> object["type"] == "PipeWire:Interface:Node" &&
        get(properties(object),"node.name",nothing) in names, objects)
    require(length(nodes)==length(names) && Set(properties(object)["node.name"] for object in nodes) == names,
        "Declared nodes were not discovered exactly")
    clients = Dict(object["id"] => properties(object) for object in objects
        if object["type"] == "PipeWire:Interface:Client")
    expected_pids = Dict(v["node.name"] => ready["processes"][
        group=="graphs" && get(v,"ownership",nothing)=="external" ? "julia" :
        group in ("sources","sinks") && get(v,"ownership",nothing)=="external" ? "simulator" : "rtc"]["pid"]
        for group in ("sources","graphs","sinks") for v in session[group])
    for object in nodes
        pid = clients[properties(object)["client.id"]]["application.process.id"]
        require(pid == expected_pids[properties(object)["node.name"]], "Endpoint belongs to the wrong role owner")
    end
    required = links(objects)
    require(length(required) == length(session["links"]), "Unexpected runtime link count")
    node_ids = Dict(properties(v)["node.name"]=>v["id"] for v in nodes)
    ports = filter(v->v["type"]=="PipeWire:Interface:Port",objects)
    function endpoint(value, direction)
        name,port_name=split(value,':';limit=2)
        node=node_ids[name]
        port=only(filter(v->properties(v)["node.id"]==node &&
            properties(v)["port.name"]==port_name && properties(v)["port.direction"]==direction,ports))
        return node,port["id"]
    end
    declared=Set((endpoint(v["output"],"out")...,endpoint(v["input"],"in")...,get(v,"passive",false))
        for v in session["links"])
    observed=Set((v["info"]["output-node-id"],v["info"]["output-port-id"],
        v["info"]["input-node-id"],v["info"]["input-port-id"],
        string(get(properties(v),"link.passive",false))=="true") for v in required)
    require(declared==observed,"Runtime links differ from declared endpoints or passive policy")
    entries = Any[]
    port_entries = Dict{Int,Any}()
    for object in required
        require(clients[properties(object)["client.id"]]["application.process.id"]==ready["processes"]["rtc"]["pid"],
            "Link is not owned by the RTC runner")
        require(object["info"]["state"] in ("active","paused"), "Link negotiation incomplete")
        info = object["info"]
        require(info["format"]["mediaSubtype"] == "ndarray", "Non-NDArray link")
        for direction in ("output","input")
            port = only(filter(v -> v["id"] == info[direction*"-port-id"], objects))
            require(port["type"] == "PipeWire:Interface:Port", "Link endpoint is not a port")
            entry=Dict("role"=>"port-$(port["id"])","kind"=>"port",
                "id"=>port["id"],"serial"=>properties(port)["object.serial"],
                "node"=>info[direction*"-node-id"],"direction"=>direction,"format"=>info["format"])
            if haskey(port_entries,port["id"])
                require(port_entries[port["id"]]==entry,"Shared port has inconsistent contracts")
            else
                port_entries[port["id"]]=entry
                push!(entries,entry)
            end
        end
        push!(entries,Dict("role"=>"link-$(object["id"])","kind"=>"link",
            "id"=>object["id"],"serial"=>properties(object)["object.serial"],
            "properties"=>Dict(key=>properties(object)[key] for key in
                ("link.output.node","link.output.port","link.input.node","link.input.port","client.id"))))
    end
    return Dict("objects"=>entries),required,nodes
end

function start_observer(ready, package, evidence, source, build)
    remote = joinpath(ready["private_runtime"],ready["remote"])
    snapshot = registry(remote)
    root = joinpath(evidence,"wireplumber"); mkpath(joinpath(root,"scripts");mode=0o700)
    C.write_json(joinpath(root,"registry-before.json"),snapshot)
    args,required,nodes = manifest(snapshot,ready,package)
    C.write_json(joinpath(root,"arguments.json"),args)
    cp(joinpath(@__DIR__,"wireplumber/hil-observer.lua"),joinpath(root,"scripts/hil-observer.lua"))
    configuration = """
    context.properties = { library.use-fallback = false }
    context.modules = [ { name = libpipewire-module-protocol-native } ]
    wireplumber.profiles = {
        ao-hil = { support.lua-scripting = required ao.hil-observer = required }
    }
    wireplumber.components = [
        { name = libwireplumber-module-lua-scripting type = module
          provides = support.lua-scripting }
        { name = hil-observer.lua type = script/lua
          provides = ao.hil-observer requires = [ support.lua-scripting ]
          arguments = $(strip(read(joinpath(root,"arguments.json"),String))) }
    ]
    """
    write(joinpath(root,"wireplumber.conf"),configuration)
    lib = "/opt/pipewireao/lib/x86_64-linux-gnu"
    environment = ["PIPEWIRE_REMOTE"=>remote,"PIPEWIREAO_REMOTE"=>remote,
        "PIPEWIREAO_RUNTIME_DIR"=>ready["private_runtime"],
        "PIPEWIREAO_MODULE_DIR"=>joinpath(lib,"pipewire-ao-0.3"),
        "PIPEWIREAO_SPA_PLUGIN_DIR"=>joinpath(lib,"spa-ao-0.2"),
        "WIREPLUMBER_MODULE_DIR"=>joinpath(build,"modules"),
        "WIREPLUMBER_CONFIG_DIR"=>root,"WIREPLUMBER_DATA_DIR"=>root*":"*joinpath(source,"src"),
        "WIREPLUMBER_DEBUG"=>"W",
        "LD_LIBRARY_PATH"=>joinpath(build,"lib/wp")*":"*lib,"NOTIFY_SOCKET"=>""]
    library_selection = read(addenv(`ldd $(joinpath(build,"src/wireplumber"))`,environment...),String)
    require(occursin("libpipewire-ao-0.3",library_selection) &&
        !occursin("libpipewire-0.3.so",library_selection),"Wrong WirePlumber library selection")
    write(joinpath(root,"libraries.log"),library_selection)
    logfile = joinpath(root,"wireplumber.log")
    process = open(logfile,"w") do log
        run(pipeline(addenv(`taskset -c 6 stdbuf -oL $(joinpath(build,"src/wireplumber")) -c wireplumber.conf -p ao-hil`,
            environment...);stdout=log,stderr=log);wait=false)
    end
    try
        deadline = time_ns()+UInt64(30_000_000_000)
        while !occursin("HIL_COHORT_READY",read(logfile,String))
            require(process_running(process),"WirePlumber exited before discovery")
            require(!occursin("_wplua_errhandler",read(logfile,String)),"WirePlumber Lua probe rejected discovery; see its retained log")
            require(time_ns()<deadline,"WirePlumber discovery timed out")
            sleep(0.05)
        end
        verify_links(registry(remote),required)
    catch
        process_running(process) && kill(process,Base.SIGKILL)
        wait(process)
        rethrow()
    end
    return process,remote,required,nodes
end

function stop_observer(process; signal=Base.SIGTERM)
    process_running(process) && kill(process,signal)
    deadline=time_ns()+UInt64(10_000_000_000)
    while process_running(process) && time_ns()<deadline; sleep(0.05); end
    if process_running(process)
        kill(process,Base.SIGKILL); wait(process)
        error("WirePlumber failed to exit after requested signal")
    end
    wait(process)
    require(signal == Base.SIGKILL ? process.termsignal == Base.SIGKILL : success(process),
        "Unexpected WirePlumber termination")
end

function main(args)
    length(args)==5 || error("expected PACKAGE FRESH_RUNTIME FRESH_EVIDENCE WIREPLUMBER_SOURCE WIREPLUMBER_BUILD")
    package,runtime,evidence,source,build=abspath.(args)
    require(all(path->!ispath(path)&&!islink(path),(runtime,evidence)),"Fresh outputs required")
    hil=C.read_json(joinpath(package,"provenance.json"))["hil"]
    require(hil["frames"]==256 && hil["total_exchanges"]==512 && hil["wall_rate_hz"]==100,
        "Coexistence fixture requires retained256, total512, wall100Hz")
    mkpath(evidence;mode=0o700)
    sdk=joinpath(package,"julia")
    command=`$(Base.julia_cmd()) --startup-file=no --project=$sdk $(joinpath(sdk,"deploy_cli.jl")) run --deployment $(joinpath(package,"deployment.conf")) --pipewire-prefix /opt/pipewireao --runtime $runtime --owner-preparation-timeout-seconds 900`
    record=Dict{String,Any}("scope"=>"Copper AOS/RTC coexistence; runtime retains admission and links; no timing claim",
        "package"=>package,"descriptor_sha256"=>C.sha256_file(joinpath(package,"deployment.conf")),
        "coordinator_sha256"=>C.sha256_file(@__FILE__),
        "policy_sha256"=>C.sha256_file(joinpath(@__DIR__,"wireplumber/hil-observer.lua")),
        "wireplumber_sha256"=>C.sha256_file(joinpath(build,"src/wireplumber")),
        "success"=>false,"shutdown_confirmed"=>false)
    observer=nothing; identities=Dict{String,Any}()
    open(joinpath(evidence,"deployment.log"),"w") do log
        process=run(pipeline(command;stdout=log,stderr=log);wait=false)
        try
            # The launcher first inherits the full admitted CPU envelope.
            # Confine only this development coordinator after spawning it.
            run(pipeline(`taskset -apc 6 $(getpid())`;stdout=devnull))
            D.wait_state(runtime,state->get(state,"admitted",false);timeout=900,process) do ready,client
                record["ready"]=ready
                S.verify_admission_client(client,ready,getpid(process))
                identities=S.owned_process_identities(ready["processes"],getpid(process))
                record["owned_process_identities"]=identities
                record["initial_stop"]=S.native_control(client,["session-stop"])
                record["initial_reset"]=S.native_control(client,["reset"])
                observer,remote,required,nodes=start_observer(ready,package,evidence,source,build)
                record["nodes"]=nodes;record["runtime_links"]=required;record["observer_pid"]=getpid(observer)
                held=S.native_control(client,["status"])
                require(held["state"]=="Ready" && held["source"]["state"]=="paused" && held["source"]["sequence"]==0,
                    "Source advanced during WirePlumber discovery")
                record["held_after_discovery"]=held
                for number in 1:2
                    initial=S.native_control(client,["status"])
                    generation=Int64(initial["source"]["generation"])
                    record["start-$number"]=S.native_control(client,["session-start"])
                    deadline=time_ns()+UInt64(900_000_000_000);paused=false
                    while true
                        require(process_running(process),"Runtime exited before completion")
                        (number==1 || !paused) && require(process_running(observer),"WirePlumber exited before the planned death check")
                        (number==1 || !paused) && require(!occursin("HIL_COHORT_LOST",read(joinpath(evidence,"wireplumber/wireplumber.log"),String)),
                            "WirePlumber observed withdrawal before the planned death check")
                        (number==1 || !paused) && require(!occursin("_wplua_errhandler",read(joinpath(evidence,"wireplumber/wireplumber.log"),String)),
                            "WirePlumber Lua callback failed before the planned death check")
                        require(time_ns()<deadline,"HIL completion timed out")
                        observed=S.native_control(client,["status"])
                        cursor=S.native_completed_source(observed["source"],generation)
                        if cursor!==nothing
                            require(number==1 || paused,"Second run completed before pause/death check")
                            prefix,summary=S.preserve_report(ready["private_runtime"],evidence,number,cursor)
                            require(summary["requested_exchanges"]==512 && summary["retained_prefix_frames"]==256,
                                "Completed cohort extent differs from the sealed fixture")
                            S.require_allocation_free(summary)
                            record["run-$number"]=Dict("summary"=>summary,"completion"=>observed,
                                "frame_sha256"=>prefix["frame"]["sha256"],"command_sha256"=>prefix["command"]["sha256"])
                            break
                        end
                        # Kill the optional observer within the retained prefix,
                        # so byte equality covers commands after its death too.
                        if number==2 && !paused && S.midrun_ready(observed["source"],hil["frames"]÷2)
                            record["midrun_stop"]=S.native_control(client,["session-stop"])
                            before=S.native_control(client,["status"])
                            require(!before["source"]["completed"] && before["source"]["state"]=="paused", "Midrun source not held")
                            require(before["source"]["sequence"]<hil["frames"], "Pause missed the retained numerical comparison window")
                            stop_observer(observer;signal=Base.SIGKILL)
                            record["observer_killed"]=true
                            verify_links(registry(remote),required)
                            sleep(0.1)
                            after=S.native_control(client,["status"])
                            require(after["state"]=="Ready" && after["source"]["sequence"]==before["source"]["sequence"] &&
                                after["source"]["generation"]==generation && after["source"]["state"]=="paused", "Held source changed after observer death")
                            record["held_before_death"]=before;record["held_after_death"]=after
                            record["midrun_resume"]=S.native_control(client,["session-start"])
                            paused=true
                        end
                        sleep(0.05)
                    end
                    verify_links(registry(remote),required)
                    record["stop-$number"]=S.native_control(client,["session-stop"])
                    if number==1
                        record["reset"]=S.native_control(client,["reset"])
                        reset=S.native_control(client,["status"])
                        require(reset["source"]["sequence"]==0 && reset["source"]["generation"]>generation &&
                            reset["source"]["state"]=="paused" && !reset["source"]["completed"] &&
                            reset["source"]["report-ready"] && reset["source"]["report-generation"]==reset["source"]["generation"] &&
                            reset["source"]["report-sequence"]==0,"Reset cursor differs")
                        record["reset_status"]=reset
                    end
                end
                a,b=record["run-1"],record["run-2"]
                require(a["frame_sha256"]==b["frame_sha256"] && a["command_sha256"]==b["command_sha256"],"Reset prefixes differ")
                require(a["summary"]["truth"]==b["summary"]["truth"],"Sparse truth samples differ across reset")
                record["success"]=true
            end
        catch exception
            record["failure"]=sprint(showerror,exception)
        finally
            if observer!==nothing && process_running(observer)
                try stop_observer(observer) catch exception
                    record["observer_cleanup_failure"]=sprint(showerror,exception);record["success"]=false
                end
            end
            S.shutdown_qualification!(record,runtime,process,identities)
            C.write_json(joinpath(evidence,"receipt.json"),record)
        end
    end
    println(joinpath(evidence,"receipt.json"))
    return S.qualification_exit_code(record)
end
end
abspath(PROGRAM_FILE)==(@__FILE__) && exit(WirePlumberHILQualification.main(ARGS))
