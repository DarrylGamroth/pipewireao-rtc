module Placement

using ..Common
import PipeWireAO

export PlacementError, cpu_set, credentials, snapshot, inherited_cpus, pin_supervisor

struct PlacementError <: Exception
    message::String
end
Base.showerror(io::IO, error::PlacementError) = print(io, error.message)
fail(message) = throw(PlacementError(message))

function cpu_set(values)
    values isa AbstractVector && !isempty(values) &&
        all(cpu -> typeof(cpu) === Int && cpu >= 2, values) &&
        length(unique(values)) == length(values) ||
        fail("CPU lists must be distinct integers excluding CPUs 0 and 1")
    Set(values)
end

function cpus_from_list(value::AbstractString)
    result = Int[]
    for field in split(strip(value), ',')
        endpoints = split(field, '-')
        if length(endpoints) == 1
            push!(result, parse(Int, endpoints[1]))
        elseif length(endpoints) == 2
            append!(result, parse(Int, endpoints[1]):parse(Int, endpoints[2]))
        else
            fail("invalid Linux CPU list: $value")
        end
    end
    sort!(result)
end

function proc_field(path, key)
    for line in eachline(path)
        startswith(line, key * ":") && return strip(split(line, ':'; limit=2)[2])
    end
    fail("missing $key in $path")
end

inherited_cpus() = Set(cpus_from_list(proc_field("/proc/self/status", "Cpus_allowed_list")))

function pin_supervisor(cpu::Integer)
    cpu >= 2 || fail("supervisor housekeeping CPU must exclude CPUs 0 and 1")
    process = string(getpid())
    result = Common.run_checked(["taskset", "-apc", string(cpu), process]; timeout=3)
    result.returncode == 0 || fail("cannot pin all supervisor threads on housekeeping CPU $cpu: $(result.stderr)")
    task = "/proc/self/task"
    before = sort!(parse.(Int, readdir(task)))
    for tid in before
        observed = cpus_from_list(proc_field("$task/$tid/status", "Cpus_allowed_list"))
        observed == [cpu] || fail("supervisor thread $tid affinity $observed differs from housekeeping CPU $cpu")
    end
    before == sort!(parse.(Int, readdir(task))) ||
        fail("supervisor thread set changed during placement verification")
    Dict("pid" => getpid(), "threads" => before, "cpus" => [cpu])
end

"""Pin one running, caller-owned native loop during cold preparation.

An event dispatched by the exact loop publishes its Linux TID. The caller must
retain the loop and serialize its lifetime until this operation returns. Call
outside its native callback and without holding its loop lock.
"""
function pin_loop!(loop::PipeWireAO.ThreadLoop, cpu::Int; check=()->nothing, timeout::Real=5.0)
    cpu >= 2 || fail("native loop CPU must exclude CPUs 0 and 1")
    isfinite(timeout) && timeout > 0 || throw(ArgumentError("loop placement timeout must be positive and finite"))
    PipeWireAO.isrunning(loop) || fail("native loop must be running before placement")
    PipeWireAO.in_thread(loop) && fail("native loop placement must run outside its callback")
    started = time_ns()
    remaining() = Float64(timeout) - (time_ns() - started) / 1e9
    tid = Threads.Atomic{Int}(0)
    check()
    event = PipeWireAO.EventSource(loop, (_source, _count) -> begin
        tid[] = Int(ccall(:gettid, Cint, ()))
        nothing
    end)
    errors = Any[]
    placement = nothing
    try
        check()
        PipeWireAO.signal!(event)
        while tid[] == 0
            check()
            remaining() > 0 || fail("native loop did not publish its thread ID before the placement deadline")
            GC.safepoint()
            yield()
        end
        check()
        thread = tid[]
        status = "/proc/self/task/$thread/status"
        parse(Int, proc_field(status, "Tgid")) == getpid() &&
            parse(Int, proc_field(status, "Pid")) == thread ||
            fail("native loop thread $thread does not belong to the owner process")
        check()
        available = remaining()
        available > 0 || fail("native loop placement deadline expired before affinity assignment")
        result = Common.run_checked(["taskset", "-pc", string(cpu), string(thread)];
            timeout=available, maximum_output_bytes=64 * 1024)
        result.returncode == 0 || fail("cannot pin native loop thread $thread on CPU $cpu: $(result.stderr)")
        check()
        remaining() > 0 || fail("native loop placement deadline expired during affinity assignment")
        observed = cpus_from_list(proc_field(status, "Cpus_allowed_list"))
        observed == [cpu] || fail("native loop thread $thread affinity $observed differs from CPU $cpu")
        check()
        remaining() > 0 || fail("native loop placement deadline expired during verification")
        placement = Dict("pid" => getpid(), "tid" => thread, "cpus" => [cpu])
    catch error
        push!(errors, error)
    finally
        try close(event) catch error; push!(errors, error) end
    end
    isempty(errors) || throw(length(errors) == 1 ? only(errors) : CompositeException(errors))
    return placement
end

function limit_value(line)
    fields = split(strip(line), r"\s{2,}")
    length(fields) >= 3 || fail("invalid process limit: $line")
    convert(value) = value == "unlimited" ? -1 : parse(Int, value)
    (convert(fields[2]), convert(fields[3]))
end

function credentials(priority::Integer, locked_bytes::Integer, latency_us)
    limits = read("/proc/self/limits", String)
    rt = mem = nothing
    for line in split(limits, '\n')
        startswith(line, "Max realtime priority") && (rt = limit_value(line))
        startswith(line, "Max locked memory") && (mem = limit_value(line))
    end
    rt === nothing && fail("realtime priority limit unavailable")
    mem === nothing && fail("memlock limit unavailable")
    priority > 0 && rt[1] != -1 && rt[1] < priority &&
        fail("effective RT priority limit $(rt[1]) is below $priority; user units cannot exceed inherited rights")
    locked_bytes > 0 && mem[1] != -1 && mem[1] < locked_bytes &&
        fail("effective memlock limit $(mem[1]) is below $locked_bytes bytes")
    if latency_us !== nothing
        try
            open("/dev/cpu_dma_latency", "r+") do _ end
        catch
            fail("cpu_dma_latency access requested but unavailable to effective credentials")
        end
    end
    Dict{String,Any}("uid" => ccall(:getuid, Cuint, ()),
        "groups" => parse.(Int, split(strip(read(`id -G`, String)))),
        "rtprio" => collect(rt), "memlock" => collect(mem),
        "cpu_latency_us" => latency_us)
end

function scheduler(tid)
    output = read(`chrt -p $tid`, String)
    policy = match(r"scheduling policy: SCHED_(\w+)", output)
    priority = match(r"scheduling priority: (\d+)", output)
    policy === nothing && fail("scheduler policy unavailable for thread $tid")
    priority === nothing && fail("scheduler priority unavailable for thread $tid")
    return get(Dict("OTHER" => 0, "FIFO" => 1), policy.captures[1], -1), parse(Int, priority.captures[1])
end

function snapshot(pid::Integer, contract::AbstractDict)
    envelope = cpu_set(contract["cpus"])
    task = "/proc/$pid/task"
    before = sort(parse.(Int, readdir(task)))
    threads = Dict{String,Any}[]
    for tid in before
        status = "$task/$tid/status"
        affinity = cpus_from_list(proc_field(status, "Cpus_allowed_list"))
        policy, priority = scheduler(tid)
        name = strip(read("$task/$tid/comm", String))
        Set(affinity) ⊆ envelope || fail("thread $tid ($name) affinity $affinity exceeds deployment envelope")
        (policy == 0 && priority == 0 || policy == 1 && priority == contract["rt-priority"]) ||
            fail("thread $tid ($name) has unrequested scheduler policy=$policy priority=$priority")
        tid == pid && (policy != 0 || affinity != [contract["leader-cpu"]]) &&
            fail("process leader $tid must remain SCHED_OTHER on housekeeping CPU $(contract["leader-cpu"])")
        push!(threads, Dict("tid" => tid, "name" => name, "cpus" => affinity,
            "policy" => policy, "priority" => priority))
    end
    before == sort(parse.(Int, readdir(task))) || fail("process $pid changed threads during readiness inspection")
    for required in contract["threads"]
        matches = count(thread -> thread["cpus"] == required["cpus"] &&
            thread["policy"] == (required["policy"] == "fifo" ? 1 : 0) &&
            thread["priority"] == required["priority"] &&
            (!haskey(required, "name") || thread["name"] == required["name"]), threads)
        matches == required["count"] || fail("process $pid requires $(required["count"]) thread(s) matching $required, observed $matches")
    end
    locked_kb = parse(Int, split(proc_field("/proc/$pid/status", "VmLck"))[1])
    locked = locked_kb * 1024
    locked >= contract["locked-bytes"] || fail("process $pid locked $locked bytes, below requested $(contract["locked-bytes"])")
    Dict{String,Any}("pid" => pid, "threads" => threads, "locked_bytes" => locked)
end

end
