#!/usr/bin/env julia
# Development qualification through the same public installed deployment path.
# No scientific operations or PipeWire callbacks run on this coordinator.
module SustainedQualification
using PipeWireAODeployment
const D = PipeWireAODeployment.Deployment
const C = PipeWireAODeployment.Common
const N = PipeWireAODeployment.NativeSupervisorClient
const Commands = PipeWireAODeployment.RunnerCommands

function native_control(client,argv;timeout=30,deadline=time_ns()/1e9+min(timeout,30))
    reply=N.request!(client,Commands.parse(argv);deadline=Float64(deadline))
    rendered=N.render(reply;owner_pid=client.observation.owner_pid)
    rendered["ok"] || error("native control failed: $(rendered["error"])")
    return rendered
end
# The supervisor's serial owner cleanup and service stop allowance use 300 s.
# Permit that bound before interruption for cleanup already underway, and again
# after interruption before stopping the launcher itself.
const SUPERVISOR_CLEANUP_GRACE_SECONDS = 300.0

mutable struct SampleRing{T}
    values::Vector{T}
    count::Int
    capacity::Int
end
function SampleRing(capacity::Integer)
    capacity > 0 || throw(ArgumentError("sample capacity must be positive"))
    SampleRing{Any}(Any[],0,Int(capacity))
end
Base.length(ring::SampleRing) = length(ring.values)
function retain_sample!(ring::SampleRing,sample)
    ring.count += 1
    if length(ring) < ring.capacity
        push!(ring.values,sample)
    else
        ring.values[mod1(ring.count,ring.capacity)] = sample
    end
    return ring
end
function retained_samples(ring::SampleRing)
    first = ring.count <= ring.capacity ? 1 : mod1(ring.count+1,ring.capacity)
    return [ring.values[mod1(first+i-1,length(ring))] for i in 1:length(ring)]
end

function process_identity(pid::Integer)
    pid > 0 && !(pid isa Bool) || return nothing
    line = try read("/proc/$pid/stat",String) catch; return nothing end
    closing = findlast(==(')'),line)
    closing === nothing && return nothing
    fields = split(strip(line[closing+1:end]))
    length(fields) >= 20 || return nothing
    try
        return (; pid=Int(pid),state=String(fields[1]),parent_pid=parse(Int,fields[2]),
            group_pid=parse(Int,fields[3]),session_pid=parse(Int,fields[4]),
            start_ticks=parse(UInt64,fields[20]))
    catch
        return nothing
    end
end

function owned_process_identities(processes,launcher_pid)
    identities = Dict{String,Any}()
    for (role,entry) in processes
        pid = entry["pid"]
        observed = pid isa Integer ? process_identity(pid) : nothing
        confirmed = observed !== nothing && observed.parent_pid == launcher_pid &&
            observed.group_pid == observed.session_pid == pid
        identities[role] = Dict("pid"=>pid,"ownership_confirmed"=>confirmed,
            "identity"=>observed === nothing ? nothing : Dict(string(k)=>v for (k,v) in pairs(observed)))
    end
    return identities
end

function observed_cleanup(process,identities)
    members = Any[]
    for name in readdir("/proc")
        pid = tryparse(Int,name)
        pid === nothing && continue
        observed = process_identity(pid)
        observed === nothing || push!(members,observed)
    end
    groups = Dict{String,Any}()
    for (role,entry) in identities
        if !entry["ownership_confirmed"]
            groups[role] = Dict("status"=>"unknown","pid"=>entry["pid"],
                "reason"=>"leader ownership was not confirmed before cleanup")
            continue
        end
        identity = entry["identity"]
        pid = identity["pid"]
        group = filter(p -> p.group_pid == p.session_pid == pid,members)
        leader = findfirst(p -> p.pid == pid,group)
        changed = leader !== nothing && group[leader].start_ticks != identity["start_ticks"]
        status = isempty(group) ? "complete" : changed ? "identity_changed" : "unresolved"
        groups[role] = Dict("status"=>status,"leader_pid"=>pid,
            "leader_start_ticks"=>identity["start_ticks"],
            "observed_members"=>[Dict(string(k)=>v for (k,v) in pairs(p)) for p in group],
            "observation"=>"group/session observations only; no numeric owner PID or group was signalled")
    end
    launcher_running = process_running(process)
    complete = !launcher_running && !isempty(groups) && all(g -> g["status"] == "complete",values(groups))
    return Dict("status"=>complete ? "complete" : isempty(groups) ? "unknown" : "unresolved",
        "launcher_exited"=>!launcher_running,"groups"=>groups,
        "scope"=>"tracked detached groups at the final observation; unknown identities cannot confirm cleanup")
end

function wait_for_launcher(process,seconds,poll_interval)
    started = time_ns()
    deadline = started+UInt64(round(Int,seconds*1e9))
    while process_running(process) && time_ns()<deadline
        sleep(poll_interval)
    end
    return Dict("limit_seconds"=>seconds,"elapsed_seconds"=>Float64(time_ns()-started)/1e9,
        "launcher_exited"=>!process_running(process))
end

function fallback_cleanup(process,identities; initial_wait=SUPERVISOR_CLEANUP_GRACE_SECONDS,
                          post_interrupt_grace=SUPERVISOR_CLEANUP_GRACE_SECONDS,
                          kill_grace=5.0,poll_interval=0.05)
    all(value -> isfinite(value) && value > 0,(initial_wait,post_interrupt_grace,kill_grace,poll_interval)) ||
        throw(ArgumentError("cleanup intervals must be finite and positive"))
    errors = String[]
    interrupted = false
    killed = false
    # A failed public wait may follow a successful quit request. Let cleanup
    # already executing in the supervisor's finally block finish uninterrupted.
    initial = wait_for_launcher(process,initial_wait,poll_interval)
    post_interrupt = Dict("limit_seconds"=>post_interrupt_grace,"elapsed_seconds"=>0.0,
        "attempted"=>false,"launcher_exited"=>!process_running(process))
    after_kill = Dict("limit_seconds"=>kill_grace,"elapsed_seconds"=>0.0,
        "attempted"=>false,"launcher_exited"=>!process_running(process))
    if process_running(process)
        try
            # Only this coordinator's still-owned Base.Process is signalled.
            # Detached owners remain under their supervisor's cleanup policy.
            kill(process,Base.SIGINT)
            interrupted = true
        catch exception
            push!(errors,sprint(showerror,exception))
        end
        post_interrupt = wait_for_launcher(process,post_interrupt_grace,poll_interval)
        post_interrupt["attempted"] = true
        if process_running(process)
            try
                kill(process,Base.SIGKILL)
                killed = true
            catch exception
                push!(errors,sprint(showerror,exception))
            end
            after_kill = wait_for_launcher(process,kill_grace,poll_interval)
            after_kill["attempted"] = true
        end
    end
    process_running(process) || wait(process)
    result = observed_cleanup(process,identities)
    result["fallback"] = true
    result["initial_wait"] = initial
    result["post_interrupt_wait"] = post_interrupt
    result["post_kill_wait"] = after_kill
    result["launcher_interrupted"] = interrupted
    result["launcher_killed"] = killed
    result["errors"] = errors
    return result
end

function shutdown_qualification!(record,runtime,process,identities; shutdown=D.shutdown,
                                 initial_wait=SUPERVISOR_CLEANUP_GRACE_SECONDS,
                                 post_interrupt_grace=SUPERVISOR_CLEANUP_GRACE_SECONDS,kill_grace=5.0)
    try
        record["final"] = shutdown(runtime,process;timeout=55)
        record["shutdown_confirmed"] = true
        record["cleanup"] = observed_cleanup(process,identities)
        record["cleanup"]["fallback"] = false
    catch exception
        record["shutdown_confirmed"] = false
        record["shutdown_failure"] = sprint(showerror,exception)
        record["cleanup"] = fallback_cleanup(process,identities;initial_wait,post_interrupt_grace,kill_grace)
    end
    record["success"] = qualification_exit_code(record) == 0
    return record
end
qualification_exit_code(record) = get(record,"success",false) &&
    get(record,"shutdown_confirmed",false) && get(get(record,"cleanup",Dict()),"status","unknown") == "complete" ? 0 : 1

function memory_sample(processes)
    Dict(role => begin
        pid = entry["pid"]
        fields = Dict{String,Int}()
        for line in eachline("/proc/$pid/status")
            matched = match(r"^(VmRSS|VmHWM|VmLck):\s+(\d+)\s+kB$",line)
            matched === nothing || (fields[matched[1]] = parse(Int,matched[2]) * 1024)
        end
        Dict("pid"=>pid,"bytes"=>fields)
    end for (role,entry) in processes)
end

function device_sample(processes)
    pids = Set(entry["pid"] for entry in values(processes))
    # Boundary-only driver telemetry; no device kernel or array operation.
    output = read(`nvidia-smi --query-compute-apps=pid,used_gpu_memory --format=csv,noheader,nounits`,String)
    records = Any[]
    for line in split(strip(output),'\n')
        isempty(line) && continue
        fields = strip.(split(line,','))
        length(fields) == 2 || error("unexpected NVIDIA telemetry")
        pid = parse(Int,fields[1])
        pid in pids || continue
        bytes = tryparse(Int,fields[2])
        push!(records,Dict("pid"=>pid,"used_bytes"=>bytes === nothing ? nothing : bytes * 1024^2))
    end
    return Dict("scope"=>"owned NVIDIA processes at boundary; driver memory includes retained pools", "processes"=>records)
end

"Accept completion only from a fresh successful ordinary source Status."
function native_completed_source(source, generation::Int64)
    integer(value)=value isa Integer && !(value isa Bool)
    get(source,"ok",nothing) === true && get(source,"operation",nothing) == "status" &&
        integer(get(source,"id",nothing)) && source["id"] > 0 &&
        integer(get(source,"instance",nothing)) && source["instance"] > 0 ||
        error("source completion requires a successful native query")
    integer(get(source,"generation",nothing)) && source["generation"] == generation || error("source generation changed")
    get(source,"completed",nothing) === true || return nothing
    get(source,"report-ready",nothing) === true &&
        integer(get(source,"report-generation",nothing)) && integer(get(source,"report-sequence",nothing)) &&
        get(source,"report-generation",nothing) == generation &&
        get(source,"report-sequence",nothing) == get(source,"sequence",nothing) || return nothing
    source["state"] == "paused" && integer(source["sequence"]) && source["sequence"] > 0 ||
        error("completed source cursor is invalid")
    return (generation,Int64(source["sequence"]))
end

function verify_report_cursor(summary, cursor)
    generation,sequence=cursor
    get(summary,"acquisition_generation",nothing) == generation &&
        get(summary,"sequence",nothing) == sequence ||
        error("saved report differs from native committed cursor")
    return nothing
end

function preserve_report(instance,evidence,number,cursor)
    destination = joinpath(evidence,"run-$number"); mkdir(destination)
    prefix = C.read_json(joinpath(instance,"simulator-result.json");maximum=256*1024)
    summary = C.read_json(joinpath(instance,"simulator-result.json.sustained.json");maximum=256*1024)
    verify_report_cursor(summary,cursor)
    prefix["acquisition_generation"] == first(cursor) || error("prefix generation differs")
    summary["version"] == 2 && summary["completed"] === true && summary["failure"] === nothing || error("sustained run incomplete")
    summary["completed_frames"] == summary["completed_commands"] == summary["sequence"] == summary["requested_exchanges"] || error("sustained delivery differs")
    summary["metrics"]["count"] == summary["sequence"] || error("observer count differs")
    prefix["completed_frames"] == summary["retained_prefix_frames"] == prefix["requested_frames"] || error("retained prefix differs")
    prefix["sequences"] == collect(1:prefix["completed_frames"]) || error("prefix chronology differs")
    for key in ("frame","command")
        product = prefix[key]
        C.sha256_file(product["file"]) == product["sha256"] || error("retained payload differs")
        target = joinpath(destination,basename(product["file"]));cp(product["file"],target)
        product["runtime_file"] = product["file"];product["file"] = target
    end
    prefix["sustained_report"] = joinpath(destination,"sustained-result.json")
    summary["prefix_report"] = joinpath(destination,"simulator-result.json")
    C.write_json(summary["prefix_report"],prefix)
    C.write_json(prefix["sustained_report"],summary)
    return prefix,summary
end

function require_allocation_free(summary)
    allocation = get(summary,"allocation",nothing)
    allocation isa AbstractDict || error("simulator allocation evidence missing")
    measured = get(allocation,"completed_exchanges",nothing)
    measured isa Integer && !(measured isa Bool) && measured > 0 ||
        error("simulator allocation evidence has no measured exchanges")
    total = get(summary,"requested_exchanges",nothing)
    prefix = get(summary,"retained_prefix_frames",nothing)
    total isa Integer && !(total isa Bool) && prefix isa Integer && !(prefix isa Bool) &&
        0 <= prefix < total && measured == total - prefix ||
        error("simulator allocation interval differs from requested exchanges")
    metric_count = get(summary["metrics"],"measured_count",nothing)
    metric_count isa Integer && !(metric_count isa Bool) && measured == metric_count ||
        error("simulator allocation interval differs from metrics")
    for key in ("allocated_bytes","gc_time_ns","gc_pauses","full_sweeps")
        value = get(allocation,key,nothing)
        value isa Integer && !(value isa Bool) && value == 0 ||
            error("simulator allocation gate failed: $key=$(repr(value))")
    end
    counts = get(allocation,"allocations",nothing)
    counts isa AbstractDict || error("simulator allocation counts missing")
    for key in ("pool","big","malloc","realloc")
        value = get(counts,key,nothing)
        value isa Integer && !(value isa Bool) && value == 0 ||
            error("simulator allocation gate failed: $key=$(repr(value))")
    end
    return nothing
end

function qualification_mode(args)
    length(args) == 3 && return :continuous
    length(args) == 4 && args[4] == "lifecycle" && return :lifecycle
    length(args) == 4 && args[4] == "reset" && return :reset
    error("expected PACKAGE FRESH_RUNTIME FRESH_EVIDENCE [lifecycle|reset]")
end

function main(args)
    mode = qualification_mode(args)
    package,runtime,evidence = abspath.(args[1:3])
    lifecycle = mode === :lifecycle
    repeated = mode !== :continuous
    all(path -> !ispath(path) && !islink(path),(runtime,evidence,evidence*".lifecycle.json")) || error("fresh outputs required")
    mkpath(evidence;mode=0o700)
    sdk = joinpath(package,"julia")
    retained_prefix_frames = C.read_json(joinpath(package,"provenance.json"))["hil"]["frames"]
    command = `$(Base.julia_cmd()) --startup-file=no --project=$sdk $(joinpath(sdk,"deploy_cli.jl")) run --deployment $(joinpath(package,"deployment.conf")) --pipewire-prefix /opt/pipewireao --runtime $runtime --owner-preparation-timeout-seconds 900`
    record = Dict{String,Any}("version"=>1,"package"=>package,"descriptor_sha256"=>C.sha256_file(joinpath(package,"deployment.conf")),
        "coordinator_sha256"=>C.sha256_file(@__FILE__),"success"=>false,"shutdown_confirmed"=>false,"lifecycle_test"=>lifecycle,
        "qualification_mode"=>string(mode))
    samples = SampleRing(64)
    boundaries = Any[]
    identities = Dict{String,Any}()
    open(evidence*".deployment.log","w") do log
        process = run(pipeline(command;stdout=log,stderr=log);wait=false)
        launcher_pid = getpid(process)
        client = nothing
        try
            ready = D.wait_state(runtime,state -> get(state,"admitted",false);timeout=900,process)
            record["ready"] = ready; instance = ready["private_runtime"]
            client=N.connect_locator(ready["socket"];deadline=time_ns()/1e9+30)
            client.observation.owner_pid == launcher_pid || error("qualification bound another supervisor")
            identities = owned_process_identities(ready["processes"],launcher_pid)
            record["owned_process_identities"] = identities
            record["runtime_libraries"] = Dict(role=>filter(line->occursin("libpipewire-ao",line)||occursin("libspa-ao",line),readlines("/proc/$(entry["pid"])/maps")) for (role,entry) in ready["processes"])
            push!(boundaries,Dict("phase"=>"admitted","monotonic_ns"=>time_ns(),"processes"=>memory_sample(ready["processes"]),"device"=>device_sample(ready["processes"])))
            sample_interval = 2.0
            for number in 1:(repeated ? 2 : 1)
                initial=native_control(client,["status"];timeout=30)
                generation=Int64(initial["source"]["generation"])
                deadline = time_ns() + UInt64(900_000_000_000)
                sample_deadline = time_ns()
                paused = false
                while true
                    process_running(process) || error("launcher exited before completion")
                    time_ns() < deadline || error("sustained completion timed out")
                    if time_ns() >= sample_deadline
                        sample = Dict("monotonic_ns"=>time_ns(),"run"=>number,"processes"=>memory_sample(ready["processes"]))
                        retain_sample!(samples,sample)
                        sample_deadline = time_ns()+UInt64(round(Int,sample_interval*1e9))
                    end
                    observed=native_control(client,["status"];
                        deadline=Float64(min(deadline/1e9,time_ns()/1e9+30)))
                    cursor=native_completed_source(observed["source"],generation)
                    if cursor !== nothing
                        lifecycle && number == 1 && !paused && error("run completed before the requested midrun lifecycle check")
                        prefix,summary = preserve_report(instance,evidence,number,cursor)
                        push!(boundaries,Dict("phase"=>"completed-$number","monotonic_ns"=>time_ns(),"processes"=>memory_sample(ready["processes"]),"device"=>device_sample(ready["processes"])))
                        record["run-$number"] = Dict("summary"=>summary,"native_completion"=>observed,
                            "prefix_frame_sha256"=>prefix["frame"]["sha256"],"prefix_command_sha256"=>prefix["command"]["sha256"])
                        require_allocation_free(summary)
                        break
                    end
                    if lifecycle && number == 1 && !paused && length(samples) >= 12
                        record["midrun_stop"] = native_control(client,["session-stop"];timeout=48)
                        first_status = native_control(client,["status"];timeout=48)
                        held = first_status["source"]
                        !held["completed"] && held["sequence"] > retained_prefix_frames ||
                            error("pause did not observe a continuing run")
                        first_status["source"]["state"] == "paused" || error("source pause not observed")
                        sleep(0.1)
                        still = native_control(client,["status"];timeout=48)
                        still["source"]["state"] == "paused" && still["source"]["sequence"] == first_status["source"]["sequence"] == held["sequence"] || error("source advanced while held")
                        record["held_status_before"] = first_status
                        record["held_status_after"] = still
                        record["held_sequence"] = held["sequence"]
                        record["midrun_resume"] = native_control(client,["session-start"];timeout=48)
                        paused = true
                    end
                    sleep(0.05)
                end
                if repeated && number == 1
                    record["stop"] = native_control(client,["session-stop"];timeout=48)
                    record["reset"] = native_control(client,["reset"];timeout=48)
                    reset = native_control(client,["status"];timeout=30)["source"]
                    reset["sequence"] == 0 && !reset["completed"] &&
                        reset["generation"] > generation && reset["report-ready"] &&
                        reset["report-generation"] == reset["generation"] && reset["report-sequence"] == 0 ||
                        error("native source reset differs")
                    push!(boundaries,Dict("phase"=>"reset","monotonic_ns"=>time_ns(),"processes"=>memory_sample(ready["processes"]),"device"=>device_sample(ready["processes"])))
                    record["restart"] = native_control(client,["session-start"];timeout=48)
                end
            end
            if repeated
                a,b = record["run-1"],record["run-2"]
                a["prefix_frame_sha256"] == b["prefix_frame_sha256"] && a["prefix_command_sha256"] == b["prefix_command_sha256"] || error("reset prefix differs")
                a["summary"]["truth"] == b["summary"]["truth"] || error("continuous truth differs across reset")
            end
            record["success"] = true
        catch exception
            record["failure"] = sprint(showerror,exception)
        finally
            client === nothing || close(client)
            shutdown_qualification!(record,runtime,process,identities)
            record["memory_samples"] = retained_samples(samples)
            record["memory_sample_count"] = samples.count
            record["memory_boundaries"] = boundaries
            C.write_json(evidence*".lifecycle.json",record)
        end
    end
    println(evidence*".lifecycle.json")
    return qualification_exit_code(record)
end
end
abspath(PROGRAM_FILE) == (@__FILE__) && exit(SustainedQualification.main(ARGS))
