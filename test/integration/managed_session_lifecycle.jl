# Opt-in functional validation of a newly installed development application.
# Every native connection and destructive fault targets this harness's exact cohort.
module ManagedSessionLifecycle
using Test, PipeWireAO, PipeWireAORTC
module Faults
include("session_faults.jl")
end
module Observation
include("classic_observation.jl")
end
const R = PipeWireAORTC
const W = R.SessionRuntime
const C = R.Common
const D = R.DeploymentConfiguration
const SOURCE_SHA256 = C.sha256_file(@__FILE__)

function request(handle, stage, name, fields)
    reply = W.control!(handle, R.RunnerCommands.parse(fields); deadline=W.monotonic()+30)
    C.write_json(joinpath(stage, name*".json"), reply)
    Faults.checked(reply["ok"] === true, "native lifecycle request rejected: $name")
    return reply
end

function dump_graph(handle, prefix)
    ledger = W._ledger(handle)
    paths = D.installed_paths(prefix)
    result = C.run_checked([joinpath(prefix,"bin/pwao-dump"), "-N", "-r", ledger["remote"]];
        env=merge(Dict(ENV), Dict("LD_LIBRARY_PATH"=>paths["library"])), timeout=20,
        maximum_output_bytes=16*1024*1024)
    result.returncode == 0 || error("exact cohort graph inspection failed: $(result.stderr)")
    return C.parse_json(result.stdout)
end

function inspect_source(handle, application, prefix, stage, name)
    spec = D.profile(joinpath(application,"deployment.conf"), prefix)
    ledger = W._ledger(handle)
    source = Faults.qualification_source(spec)
    graph = dump_graph(handle, prefix)
    node = only(filter(graph) do object
        get(get(get(object,"info",Dict()),"props",Dict()),"node.name",nothing) == source["control-node"]
    end)
    identity = (; id=UInt32(node["id"]), serial=parse(UInt64,string(node["info"]["props"]["object.serial"])))
    value = Faults.decode_aos_source(graph, source, ledger["owners"][spec["source-owner"]], identity)
    report = C.read_json(joinpath(dirname(ledger["remote"]),source["control-node"]*"-report.json"))
    Faults.validate_source_report(report,value)
    value["report"] = report
    C.write_json(joinpath(stage,name*"-source.json"),value)
    return value
end

# Read exact queue playback metadata and its declared input Port from the sealed package.
function observation_spec(application, session, queue_input, name, prefix)
    core = D.decode(joinpath(application,"rtc/core.conf"),prefix)
    queue = only(filter(core["context.modules"]) do item
        item["name"] == "libpipewire-module-queue" &&
            get(get(item["args"],"capture.props",Dict()),"node.name",nothing) == queue_input
    end)
    playback = queue["args"]["playback.props"]
    sink = only(filter(item -> item["node.name"] == queue_input,session["sinks"]))
    port = only(sink["ports"])
    wire = getproperty(NdArray,Symbol(port["element-type"]))
    element = port["element-type"] == "U16_LE" ? UInt16 :
        port["element-type"] == "U8" ? UInt8 :
        port["element-type"] == "F32_LE" ? Float32 : error("unsupported observation element type")
    rate = if haskey(port,"rate")
        fraction = parse.(UInt32,split(port["rate"],'/'))
        SPA.Fraction(fraction...)
    else
        nothing
    end
    return (name=String(name),node=playback["node.name"],media=playback["media.name"],
        type=element,wire,shape=Tuple(Int.(port["shape"])),schema=port["schema"],rate)
end

function observation_specs(application, prefix)
    configuration = C.read_json(joinpath(application,"simulation.conf"))
    configuration["frame_encoding"] == "uint16" || error("functional observer requires declared UInt16 camera transport")
    configuration["command_count"] isa AbstractDict || error("functional observer requires a named command set")
    configuration["detector_observation"] && configuration["command_observation"] ||
        error("functional observer requires declared detector and command queues")
    spec = D.profile(joinpath(application,"deployment.conf"),prefix)
    session = D.decode(D.relative_asset(application,spec["session"]),prefix)
    detector = observation_spec(application,session,"simulator-detector-queue-input","detector",prefix)
    commands = map(sort!(collect(keys(configuration["command_count"])))) do key
        product = observation_spec(application,session,"rtc-"*key*"-command-queue-input",key,prefix)
        product.shape == (configuration["command_count"][key],) || error("command queue extent differs from plant declaration")
        product.schema == configuration["command_schema"][key] || error("command queue schema differs from plant declaration")
        product
    end
    return (detector,commands...)
end

function common_identity(captures; after_sequence=0)
    groups = map(captures) do capture
        Set(identity for identity in capture.identities
            if identity !== nothing && identity.sequence > after_sequence)
    end
    common = reduce(intersect,groups)
    return isempty(common) ? nothing : last(sort!(collect(common);by=identity->identity.sequence))
end

function observe_progress(handle,application,prefix,stage;start=false,after_sequence=0)
    specs = observation_specs(application,prefix)
    common = Ref{Union{Nothing,AcquisitionIdentity}}(nothing)
    record = Observation.observe_classic(W._ledger(handle)["remote"];timeout=120,
        stream_specs=specs,drive_interval=0.005,
        on_ready=start ? () -> begin
            Faults.checked(request(handle,stage,"start-"*string(after_sequence),["session-start"])["state"] == "Running",
                "session Start did not reach Running")
        end : nothing,
        finished=captures -> begin
            common[] = common_identity(captures;after_sequence)
            common[] !== nothing
        end)
    record["coherent_identity"] = Observation._classic_identity_record(something(common[]))
    record["scope"] = "Finite delivery through unchanged capacity-one queues; no cadence, latency or optical-performance claim"
    C.write_json(joinpath(stage,"progress-"*string(after_sequence)*".json"),record)
    return record
end

function shutdown(handle,stage)
    started = time_ns()
    final = W.shutdown!(handle;deadline=W.monotonic()+320)
    Faults.checked(handle.shutdown_accepted,"native Quit was not acknowledged")
    Faults.observe_cleanup!(handle,stage;failed=false)
    return Dict("elapsed_seconds"=>(time_ns()-started)/1e9,"quit_deadline_seconds"=>320,
        "native_quit_accepted"=>true,"final"=>final)
end

function lifecycle_case(application,stage,prefix;running)
    spec = D.profile(joinpath(application,"deployment.conf"),prefix)
    handle = nothing
    receipt = Dict{String,Any}("completed"=>false,"running_case"=>running,
        "deployment_sha256"=>C.sha256_file(joinpath(application,"deployment.conf")),
        "manifest_sha256"=>C.sha256_file(joinpath(application,"Manifest.toml")),"harness_sha256"=>SOURCE_SHA256,
        "prefix"=>abspath(prefix),"startup_budget_seconds"=>Faults.startup_budget(spec),
        "native_sha256"=>Dict(relative=>C.sha256_file(joinpath(prefix,relative)) for relative in
            ("bin/pipewireao-rtc","lib/pipewireao-rtc/modules/libwireplumber-module-ao-control-endpoint.so")),
        "scope"=>"Private functional lifecycle and complete named-command delivery; no optical, cadence, latency, or hardware qualification")
    try
        handle = W.start!(application,stage;prefix,deadline=W.monotonic()+Faults.startup_budget(spec))
        Faults.checked(request(handle,stage,"ready",["status"])["state"] == "Ready","session is not Ready")
        initial = inspect_source(handle,application,prefix,stage,"ready")
        Faults.checked(!initial["snapshot"]["running"] && initial["snapshot"]["sequence"] == 0,
            "new source was not held at sequence zero")
        if running
            receipt["first_progress"] = observe_progress(handle,application,prefix,stage;start=true)
            before = inspect_source(handle,application,prefix,stage,"before-stop")
            Faults.checked(request(handle,stage,"stop",["session-stop"])["state"] == "Ready","session Stop did not reach Ready")
            held = inspect_source(handle,application,prefix,stage,"stopped")
            Faults.require_aos_hold(before,held)
            Faults.checked(held["snapshot"]["sequence"] >= receipt["first_progress"]["coherent_identity"]["sequence"],
                "held source cursor predates completed command-set observation")
            receipt["restart_progress"] = observe_progress(handle,application,prefix,stage;start=true,
                after_sequence=held["snapshot"]["sequence"])
            restarted = inspect_source(handle,application,prefix,stage,"before-second-stop")
            Faults.checked(request(handle,stage,"second-stop",["session-stop"])["state"] == "Ready","second Stop did not reach Ready")
            final = inspect_source(handle,application,prefix,stage,"second-stopped")
            Faults.require_aos_hold(restarted,final)
            Faults.checked(final["instance"] == initial["instance"] &&
                final["snapshot"]["generation"] == initial["snapshot"]["generation"] &&
                final["snapshot"]["sequence"] > held["snapshot"]["sequence"],"restart did not advance the same source generation")
            receipt["held"] = held
            receipt["restarted"] = final
        end
        receipt["shutdown"] = shutdown(handle,stage)
        receipt["completed"] = true
    catch error
        receipt["failure"] = sprint(showerror,error)
        rethrow()
    finally
        if handle !== nothing && !get(receipt,"completed",false)
            try Faults.cleanup!(handle,stage;failed=true)
            catch error; receipt["cleanup_failure"] = sprint(showerror,error) end
        end
        mkpath(stage)
        C.write_json(joinpath(stage,"lifecycle-result.json"),receipt)
    end
    return receipt
end

function main(application,stage,prefix;controller_node,command=nothing,case="all")
    !ispath(stage) && !islink(stage) || error("validation stage must be fresh")
    application = realpath(application)
    spec = D.profile(joinpath(application,"deployment.conf"),prefix)
    session = D.decode(D.relative_asset(application,spec["session"]),prefix)
    session["profile"] == "development" && session["authority"] == "none" || error("development authority=none is required")
    graph = only(filter(item -> item["node.name"] == controller_node,session["graphs"]))
    controller_role = spec["node-owners"][graph["node.name"]]
    configuration = C.read_json(joinpath(application,"simulation.conf"))
    selected_command = command === nothing ? first(sort!(collect(keys(configuration["command_node"])))) : command
    sink = configuration["command_node"][selected_command]
    case in ("all","ready-quit","stop-start","link-removal","controller-exit") || error("unknown lifecycle case")
    mkpath(stage;mode=0o700)
    @testset "private managed application lifecycle: $case" begin
        case in ("all","ready-quit") && lifecycle_case(application,joinpath(stage,"ready-quit"),prefix;running=false)
        case in ("all","stop-start") && lifecycle_case(application,joinpath(stage,"stop-start"),prefix;running=true)
        for fault in ("link-removal","controller-exit")
            case in ("all",fault) || continue
            selected = (;package=application,stage=joinpath(stage,fault),case=fault,prefix,sink=nothing,
                controller=controller_role,link_nodes=(controller_node,sink))
            Faults.run_case(selected;progress=(handle,destination,ledger)->
                observe_progress(handle,application,prefix,destination))
        end
    end
end

if abspath(PROGRAM_FILE) == (@__FILE__)
    length(ARGS) in (4,5) || error("usage: managed_session_lifecycle.jl APPLICATION FRESH_STAGE PREFIX CONTROLLER_NODE [CASE]")
    main(ARGS[1:3]...;controller_node=ARGS[4],case=length(ARGS)==5 ? ARGS[5] : "all")
end
end
