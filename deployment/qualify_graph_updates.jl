#!/usr/bin/env julia
# Closed-loop functional update continuity through the installed native owner.
module GraphUpdateQualification
include("qualify_sustained.jl")
const S = SustainedQualification
const D = S.D
const C = S.C
const N = S.N
const Commands = S.Commands
const ROWS = 253
const COLUMNS = 3600
const GAIN = Float32(0.0125)
const SCHEMA = "org.calculon.ao.pwfs-reconstructor/1"

require(value, message) = value || error(message)
isinteger(value) = value isa Integer && !(value isa Bool)
function qualification_mode(args)
    length(args) in (6,7) || error("expected PACKAGE FRESH_RUNTIME FRESH_EVIDENCE GRAPH PROPERTY_NODE PARAMETER_PORT [baseline|updates]")
    mode = length(args) == 6 ? "updates" : args[7]
    mode in ("baseline","updates") || error("expected baseline or updates")
    return Symbol(mode)
end

parameter_node(port) = occursin(':',port) ? String(first(split(port,':';limit=2))) : "reconstruct"

function prepare_reconstructor(package, evidence)
    spec = D.decode(joinpath(package,"deployment.conf"),"/opt/pipewireao")
    original = get(spec["environment"],"PIPEWIREAO_RTC_PARAMETER_RECONSTRUCTOR",nothing)
    original isa String || error("installed reconstructor environment binding missing")
    original = D.substitute(original,Dict("PACKAGE"=>package,"PREFIX"=>"/opt/pipewireao"))
    isabspath(original) && isfile(original) || error("reconstructor must resolve to an existing absolute file")
    filesize(original) == ROWS*COLUMNS*4 || error("reconstructor byte extent differs from 253x3600 Float32")
    words = reinterpret(UInt32,read(original))
    values = reinterpret(Float32,ltoh.(words))
    all(isfinite,values) || error("original reconstructor contains nonfinite values")
    alternate = values .* Float32(0.99)
    all(isfinite,alternate) || error("alternate reconstructor contains nonfinite values")
    target = joinpath(evidence,"reconstructor-0.99.f32le")
    open(target,"w") do io
        write(io,htol.(reinterpret(UInt32,alternate)))
    end
    return Dict("original_file"=>original,"original_sha256"=>C.sha256_file(original),
        "alternate_file"=>target,"alternate_sha256"=>C.sha256_file(target),
        "shape"=>[ROWS,COLUMNS],"layout"=>"ROW_MAJOR","element_type"=>"F32_LE",
        "scale_float32_bits"=>reinterpret(UInt32,Float32(0.99)),"schema"=>SCHEMA)
end

function continuing(status, generation)
    require(get(status,"ok",false) === true && get(status,"state",nothing) == "Running" &&
        get(status,"admitted",false) === true,"fresh native status is not admitted Running")
    source = status["source"]
    require(source["generation"] == generation,"source generation changed during updates")
    require(source["completed"] === false,"source completed before update acknowledgement")
    require(isinteger(source["sequence"]) && source["sequence"] >= 0,"source sequence missing")
    return source
end
function generations(reply)
    result = reply["result"]
    requested,active = result["requested"],result["active"]
    require(isinteger(requested) && isinteger(active) && 0 <= active <= requested,"native generations invalid or unknown")
    return (requested,active)
end
function adopted(reply, previous)
    requested,active = generations(reply)
    return requested > first(previous) && requested == active
end
function gain_readback(reply,node,expected)
    value = reply["result"]["properties"]["$node:gain"]
    require(value == Dict("type"=>"float","bits"=>reinterpret(UInt32,Float32(expected))),"gain Float32 readback differs")
    return value
end

completion_presence(completion::N.Codec.Completion) = (completion.snapshot !== nothing,completion.result !== nothing)
completion_presence(::N.Codec.Rejection) = (false,false)
function completion_fields(completion,reply)
    snapshot_present,result_present = completion_presence(completion)
    return Dict("result_code"=>completion.header.result,"operation"=>completion.header.operation,
        "endpoint_instance"=>completion.header.endpoint_instance,"token"=>completion.header.token,
        "lifecycle"=>string(completion.lifecycle),"admitted"=>completion.admitted,
        "snapshot_present"=>snapshot_present,
        "runner_result_present"=>result_present,
        "error"=>reply["error"])
end

# Every request has a total native deadline. Retain actual typed completion
# fields, including rejection without a runner snapshot, and local timing.
function request!(record,client,argv,deadline;allow_rejection=false)
    start = time_ns()
    require(start < deadline,"qualification deadline expired")
    event = Dict{String,Any}("argv"=>argv,"query_started_monotonic_ns"=>start)
    push!(record["requests"],event)
    completion = try
        N.request!(client,Commands.parse(argv);deadline=Float64(min(deadline/1e9,start/1e9+30)))
    catch exception
        stop = time_ns()
        event["query_completed_monotonic_ns"] = stop
        event["command_duration_ns"] = stop-start
        event["transport_or_parse_failure"] = sprint(showerror,exception)
        rethrow()
    end
    stop = time_ns()
    reply = N.render(completion;owner_pid=client.observation.owner_pid)
    event["query_completed_monotonic_ns"] = stop
    event["command_duration_ns"] = stop-start
    event["typed_completion"] = completion_fields(completion,reply)
    event["reply"] = reply
    allow_rejection || require(reply["ok"] === true,"native control rejected: $(reply["error"])")
    return reply,event
end
function status!(record,client,deadline)
    reply,event = request!(record,client,["status"],deadline)
    event["source_sequence"] = reply["source"]["sequence"]
    return reply
end
function bracketed!(record,client,argv,deadline,generation;allow_rejection=false)
    before = status!(record,client,deadline)
    continuing(before,generation)
    reply,event = request!(record,client,argv,deadline;allow_rejection)
    after = status!(record,client,deadline)
    continuing(after,generation)
    event["source_before"] = before["source"]
    event["source_after"] = after["source"]
    require(after["source"]["sequence"] >= before["source"]["sequence"],"source sequence regressed")
    return reply
end
function wait_adoption!(record,client,argv,deadline,generation,previous)
    while true
        reply = bracketed!(record,client,argv,deadline,generation)
        adopted(reply,previous) && return reply
        sleep(0.05)
    end
end

# Admission starts the installed source. Stop that unmeasured preparation run
# before warming the coordinator's read-only requests and compilation. Do not
# pre-submit scientific updates: their preparation remains part of the trial.
function prepare_coordinator!(record,client,ready,process,evidence,graph,node,port,mode,total)
    deadline = time_ns()+UInt64(900_000_000_000)
    stopped,_ = request!(record,client,["session-stop"],deadline)
    record["preparation_stop"] = stopped
    observed = status!(record,client,deadline)
    require(observed["state"] == "Ready" && observed["source"]["state"] == "paused",
        "coordinator preparation requires a stopped session")
    previous_generation = observed["source"]["generation"]
    record["preparation_stopped_status"] = observed
    for argv in (["property-generation",graph,node],
                 ["parameter-generation",graph,parameter_node(port)],
                 ["properties",graph])
        request!(record,client,argv,deadline)
    end
    # Compile the concrete coordinator call before releasing the source. This
    # does not execute an update or warm the owner's update preparation path.
    precompile(cohort!,(typeof(record),typeof(client),typeof(ready),typeof(process),
        typeof(evidence),typeof(graph),typeof(node),typeof(port),typeof(mode),typeof(total)))
    for argv in (["properties-set",graph,"$node:gain","float",string(GAIN)],
                 ["properties-set",graph,"$node:gain","int","1"],
                 ["parameter",graph,port,"F32_LE","253x3600",SCHEMA,
                  record["reconstructor"]["alternate_file"]])
        Commands.parse(argv)
    end
    record["preparation_reset"],_ = request!(record,client,["reset"],deadline)
    reset = status!(record,client,deadline)
    source = reset["source"]
    require(reset["state"] == "Ready" && source["state"] == "paused" &&
        source["sequence"] == 0 && source["completed"] === false &&
        source["generation"] > previous_generation && source["report-ready"] === true &&
        source["report-generation"] == source["generation"] && source["report-sequence"] == 0,
        "coordinator preparation reset differs")
    record["measurement_initial_status"] = reset
    record["measurement_start"],_ = request!(record,client,["session-start"],deadline)
    return nothing
end

function cohort!(record,client,ready,process,evidence,graph,node,port,mode,total)
    deadline = time_ns()+UInt64(900_000_000_000)
    initial = status!(record,client,deadline)
    generation = Int64(initial["source"]["generation"])
    continuing(initial,generation)
    parameter_owner = parameter_node(port)
    property_query = ["property-generation",graph,node]
    parameter_query = ["parameter-generation",graph,parameter_owner]
    phase = 0
    property_before = parameter_before = nothing
    while true
        require(process_running(process),"launcher exited before source completion")
        observed = status!(record,client,deadline)
        cursor = S.native_completed_source(observed["source"],generation)
        if cursor !== nothing
            require(phase == 2,"source completed before required update observation points")
            prefix,summary = S.preserve_report(ready["private_runtime"],evidence,1,cursor)
            require(summary["sequence"] == total,"completed total differs from installed requested exchanges")
            record["run-1"] = Dict("summary"=>summary,"native_completion"=>observed,
                "prefix_frame_sha256"=>prefix["frame"]["sha256"],"prefix_command_sha256"=>prefix["command"]["sha256"])
            S.require_allocation_free(summary)
            return
        end
        source = continuing(observed,generation)
        if phase == 0 && source["sequence"] >= 64
            property_initial = bracketed!(record,client,property_query,deadline,generation)
            parameter_initial = bracketed!(record,client,parameter_query,deadline,generation)
            property_before,parameter_before = generations(property_initial),generations(parameter_initial)
            require(first(property_before) == last(property_before) && first(parameter_before) == last(parameter_before),"initial generation has a pending update")
            initial_values = bracketed!(record,client,["properties",graph],deadline,generation)
            record["initial_property_generation"] = property_initial
            record["initial_parameter_generation"] = parameter_initial
            record["initial_properties"] = initial_values
            if mode === :updates
                record["gain_submission"] = bracketed!(record,client,["properties-set",graph,"$node:gain","float",string(GAIN)],deadline,generation)
                record["gain_adoption"] = wait_adoption!(record,client,property_query,deadline,generation,property_before)
                gain_readback(bracketed!(record,client,["properties",graph],deadline,generation),node,GAIN)
                require(generations(bracketed!(record,client,parameter_query,deadline,generation)) == parameter_before,"gain update changed parameter generation")
            else
                require(generations(bracketed!(record,client,property_query,deadline,generation)) == property_before,"baseline property generation changed")
            end
            phase = 1
        elseif phase == 1 && source["sequence"] >= 128
            if mode === :updates
                record["parameter_submission"] = bracketed!(record,client,["parameter",graph,port,"F32_LE","253x3600",SCHEMA,record["reconstructor"]["alternate_file"]],deadline,generation)
                record["parameter_adoption"] = wait_adoption!(record,client,parameter_query,deadline,generation,parameter_before)
                require(generations(bracketed!(record,client,property_query,deadline,generation)) == generations(record["gain_adoption"]),"parameter update changed property generation")
            else
                require(generations(bracketed!(record,client,parameter_query,deadline,generation)) == parameter_before,"baseline parameter generation changed")
            end
            prop = generations(bracketed!(record,client,property_query,deadline,generation))
            param = generations(bracketed!(record,client,parameter_query,deadline,generation))
            values = bracketed!(record,client,["properties",graph],deadline,generation)
            if mode === :updates
                rejected = bracketed!(record,client,["properties-set",graph,"$node:gain","int","1"],deadline,generation;allow_rejection=true)
                require(rejected["ok"] === false && rejected["error"] isa AbstractDict,"invalid gain lacked native typed rejection")
                record["invalid_gain_rejection"] = rejected
                require(generations(bracketed!(record,client,property_query,deadline,generation)) == prop,"rejection changed property generation")
                require(generations(bracketed!(record,client,parameter_query,deadline,generation)) == param,"rejection changed parameter generation")
                after_values = bracketed!(record,client,["properties",graph],deadline,generation)
                gain_readback(after_values,node,GAIN)
                require(after_values["result"]["properties"] == values["result"]["properties"],"rejection changed active properties")
            else
                require(bracketed!(record,client,["properties",graph],deadline,generation)["result"]["properties"] == values["result"]["properties"],"baseline properties changed")
            end
            record["post_controls_running"] = status!(record,client,deadline)
            continuing(record["post_controls_running"],generation)
            phase = 2
        end
        sleep(0.05)
    end
end

function preserve_failed_completion!(record,evidence)
    haskey(record,"ready") || return nothing
    for event in Iterators.reverse(record["requests"])
        get(event,"argv",nothing) == ["status"] || continue
        reply = get(event,"reply",nothing)
        reply isa AbstractDict && get(reply,"ok",false) === true || continue
        source = get(reply,"source",nothing)
        source isa AbstractDict && get(source,"completed",false) === true || continue
        cursor = S.native_completed_source(source,Int64(source["generation"]))
        cursor === nothing && continue
        # Preserve a known committed report without issuing another request or
        # retrying a mutation whose outcome may have become unknown.
        ispath(joinpath(evidence,"run-1")) && return nothing
        prefix,summary = S.preserve_report(record["ready"]["private_runtime"],evidence,1,cursor)
        record["failed_run"] = Dict("summary"=>summary,"native_completion"=>reply,
            "prefix_frame_sha256"=>prefix["frame"]["sha256"],
            "prefix_command_sha256"=>prefix["command"]["sha256"])
        return nothing
    end
    return nothing
end

function main(args)
    mode = qualification_mode(args)
    package,runtime,evidence = abspath.(args[1:3])
    graph,node,port = args[4:6]
    all(path -> !ispath(path) && !islink(path),(runtime,evidence,evidence*".graph-updates.json",evidence*".deployment.log")) || error("fresh outputs required")
    provenance = C.read_json(joinpath(package,"provenance.json"))
    hil = provenance["hil"]
    require(hil["frames"] == 256 && hil["total_exchanges"] >= 512 && hil["wall_rate_hz"] == 100,"qualification requires retained256, total512+, wall100Hz")
    mkpath(evidence;mode=0o700)
    record = Dict{String,Any}("version"=>1,"package"=>package,"runtime"=>runtime,
        "qualification_mode"=>string(mode),"graph"=>graph,"property_node"=>node,"parameter_port"=>port,
        "descriptor_sha256"=>C.sha256_file(joinpath(package,"deployment.conf")),"coordinator_sha256"=>C.sha256_file(@__FILE__),
        "scope"=>"closed-loop functional live-update continuity; no fixed-arrival throughput or hard-deadline claim",
        "allocation_scope"=>"inclusive simulator source exchange counters; not JFG callback allocations",
        "requests"=>Any[],"success"=>false,"shutdown_confirmed"=>false)
    record["reconstructor"] = prepare_reconstructor(package,evidence)
    sdk = joinpath(package,"julia")
    command = `$(Base.julia_cmd()) --startup-file=no --project=$sdk $(joinpath(sdk,"deploy_cli.jl")) run --deployment $(joinpath(package,"deployment.conf")) --pipewire-prefix /opt/pipewireao --runtime $runtime --owner-preparation-timeout-seconds 900`
    identities = Dict{String,Any}()
    open(evidence*".deployment.log","w") do log
        process = run(pipeline(command;stdout=log,stderr=log);wait=false)
        launcher_pid = getpid(process)
        try
            D.wait_state(runtime,state -> get(state,"admitted",false);timeout=900,process) do ready,client
                record["ready"] = ready
                S.verify_admission_client(client,ready,launcher_pid)
                identities = S.owned_process_identities(ready["processes"],launcher_pid)
                record["owned_process_identities"] = identities
                prepare_coordinator!(record,client,ready,process,evidence,graph,node,port,mode,hil["total_exchanges"])
                cohort!(record,client,ready,process,evidence,graph,node,port,mode,hil["total_exchanges"])
            end
            record["success"] = true
        catch exception
            record["failure"] = sprint(showerror,exception)
            try
                preserve_failed_completion!(record,evidence)
            catch preservation_error
                record["failure_report_preservation_error"] = sprint(showerror,preservation_error)
            end
        finally
            S.shutdown_qualification!(record,runtime,process,identities)
            C.write_json(evidence*".graph-updates.json",record)
        end
    end
    println(evidence*".graph-updates.json")
    return S.qualification_exit_code(record)
end
end
abspath(PROGRAM_FILE) == (@__FILE__) && exit(GraphUpdateQualification.main(ARGS))
