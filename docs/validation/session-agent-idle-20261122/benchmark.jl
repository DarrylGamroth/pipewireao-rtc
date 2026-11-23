using PipeWireAO, PipeWireAORTC, SHA
import Clocks, Hsm

const S = PipeWireAORTC.MediaSession
const C = PipeWireAORTC.ControlClient
const R = PipeWireAORTC.RunnerCodec
const CLOCK = Clocks.SystemNanoClock()
const SECOND = 1_000_000_000
const PROJECT = dirname(Base.active_project())

now_ns() = Clocks.time_nanos(CLOCK)

mutable struct StartupProbe
    deadline::Int64
    fault_turn::Int64
    fault_transition::Int64
    settled_transition::Int64
    overdue_state::Symbol
    settled::Base.Event
end

const STARTUP_PROBE = Ref{Union{Nothing,StartupProbe}}(nothing)

# Hsm's transition hook observes the real owner dispatch without adding a
# timed task, polling the machine or modifying either checkout's runtime.
function Hsm.trace_transition_end(machine::S.Machine, from::Symbol, to::Symbol)
    if to === :HoldingFaultSources
        probe = STARTUP_PROBE[]
        if probe !== nothing
            probe.fault_transition = now_ns()
            probe.fault_turn = Clocks.time_nanos(machine.clock)
            probe.overdue_state = from
        end
    elseif to === :HeldFault
        probe = STARTUP_PROBE[]
        if probe !== nothing
            probe.settled_transition = now_ns()
            notify(probe.settled)
        end
    end
    return nothing
end

function check_expiry(probe, session)
    @assert probe.overdue_state === :CapturingSources probe.overdue_state
    @assert probe.deadline <= probe.fault_turn <= probe.fault_transition <= probe.settled_transition
    @assert occursin("expired", lowercase(something(session.machine.failure)))
    @assert session.machine.cleanup_failure === nothing
end

function serve(path; receipt = nothing)
    session = S.Session(path)
    probe = StartupProbe(session.machine.deadline, 0, 0, 0, :none, Base.Event())
    STARTUP_PROBE[] = probe
    observer = @async begin
        wait(probe.settled)
        try
            check_expiry(probe, session)
            if receipt !== nothing
                path = receipt * ".tmp"
                write(path, join((
                    probe.deadline, probe.fault_turn, probe.fault_transition,
                    probe.settled_transition, probe.overdue_state,
                ), '\t') * "\n")
                mv(path, receipt)
            end
        finally
            # Close the warm-up session after its real expiry, and allow an
            # invalid measured expiry to surface as a failed child.
            if receipt === nothing || !isfile(receipt)
                S.stage!(session.queue, S.ShutdownRequested())
            end
        end
    end
    try
        result = S.serve!(session)
        wait(observer)
        @assert session.machine.lifecycle === R.Offline
        return result
    finally
        STARTUP_PROBE[] = nothing
        close(session)
    end
end

function configure(socket, directory, daemon, name, instance)
    uuid = "e10d4214-9c5f-4a61-b584-69b65b2193f6"
    policy = Dict(
        "instance" => string(instance),
        "controller.instance" => string(instance + 1),
        "admission.controller-instance" => string(instance + 2),
        "node.name" => name,
        "controller.node.name" => name * "-controller",
        "startup.timeout-ms" => 3500,
        "session.uuid" => uuid,
        "properties" => Dict("pipewireao.rtc.session.session-uuid" => uuid),
        "core.owner" => Dict("pid" => getpid(daemon), "nodes" => String[]),
        "owners" => [],
        "node.pids" => Dict{String,Int}(),
        "source" => Dict(
            "role" => "missing-source",
            "control-node" => "not-published",
            "pid" => getpid(),
        ),
        "session" => Dict(
            "sources" => [],
            "graphs" => [],
            "sinks" => [],
            "links" => [
                Dict("output" => "not-published:output", "input" => "not-published-sink:input"),
            ],
        ),
    )
    config = Dict(
        "context.properties" => Dict(
            "remote.name" => socket,
            "library.use-fallback" => false,
            "support.dbus" => false,
        ),
        "context.modules" => [
            Dict("name" => "libpipewire-module-protocol-native"),
            Dict("name" => "libpipewire-module-client-node"),
        ],
        "pipewireao.session" => policy,
    )
    path = joinpath(directory, name * ".conf")
    PipeWireAORTC.ScienceExport.write_spa_config(path, config)
    return path
end

function process_counters(pid)
    counters = Dict{Int,NTuple{4,Int64}}()
    task_root = "/proc/$pid/task"
    for thread in readdir(task_root)
        task = joinpath(task_root, thread)
        cpu, _, slices = parse.(Int64, split(read(joinpath(task, "schedstat"), String)))
        status = read(joinpath(task, "status"), String)
        voluntary = match(r"(?m)^voluntary_ctxt_switches:\s+(\d+)", status)
        involuntary = match(r"(?m)^nonvoluntary_ctxt_switches:\s+(\d+)", status)
        counters[parse(Int, thread)] = (
            cpu, slices, parse(Int64, voluntary[1]), parse(Int64, involuntary[1]),
        )
    end
    return counters
end

function idle_sample(io, pid, seconds)
    before = process_counters(pid)
    start = now_ns()
    sleep(seconds)
    stop = now_ns()
    after = process_counters(pid)
    @assert keys(before) == keys(after)
    row(io, "idle", stop - start, length(before))
    for tid in sort!(collect(keys(after)))
        row(io, "idle_thread", tid == pid ? "owner" : "helper", tid,
            (after[tid] .- before[tid])...)
    end
end

const STATUS = R.RunnerCommand(:status)
const GROUPS = R.RunnerCommand(:groups)

function check_ack(reply, command)
    @assert reply isa R.Completion
    @assert reply.lifecycle === R.Fault && reply.error === nothing
    @assert reply.result !== nothing && reply.result.outcome === R.Observed
    if command === STATUS
        @assert !reply.result.details.running
    else
        @assert isempty(reply.result.details.groups)
    end
end

function request_sample(client, command, budget = 2 * SECOND)
    started = now_ns()
    reply = C.request!(client, command; deadline = started + budget)
    ended = now_ns()
    check_ack(reply, command)
    return started, ended, reply.header.token
end

function samples(client, bursts, burst_size, gap_ns; budget = 2 * SECOND)
    observations = Matrix{Int64}(undef, 6, bursts * burst_size)
    target = now_ns()
    for burst in 1:bursts
        delay_ns = target - now_ns()
        delay_ns > 0 && sleep(delay_ns / SECOND)
        for position in 1:burst_size
            j = (burst - 1) * burst_size + position
            started, ended, token = request_sample(client, isodd(j) ? STATUS : GROUPS, budget)
            observations[:, j] .= (burst, position, target, started, ended, token)
        end
        # Light traffic retains scheduled arrival times. Bursts are explicitly
        # completion paced with a quiet gap before the next burst.
        target = burst_size == 1 ? target + gap_ns : now_ns() + gap_ns
    end
    return observations
end

function shutdown_sample(io, client, child, signal)
    for _ in 1:100
        request = @async begin
            try
                request_sample(client, STATUS)
                "acknowledged"
            catch error
                error isa C.UnknownOutcome || rethrow()
                replace(sprint(showerror, error), '\t' => ' ', '\n' => ' ')
            end
        end
        yield()
        submitted = PipeWireAO.with_thread_loop_lock(client.loop) do _
            observation = client.observation
            observation.pending !== nothing &&
                observation.matched_completion === nothing &&
                observation.matched_rejection === nothing
        end
        if submitted && !istaskdone(request)
            sent = now_ns()
            kill(child, signal)
            disposition = fetch(request)
            timedwait(() -> process_exited(child), 10; pollint = 0.001) == :ok ||
                error("session did not exit after signal $signal")
            exited = now_ns()
            wait(child)
            row(io, "shutdown", sent, exited, disposition, child.exitcode, child.termsignal)
            @assert success(child)
            return nothing
        end
        fetch(request)
    end
    error("could not observe an outstanding native Status submission before shutdown")
end

row(io, fields...) = println(io, join(fields, '\t'))
file_hash(path) = bytes2hex(open(sha256, path))
source_hash(project) = bytes2hex(sha256(read(`git -C $project diff HEAD -- src`)))

function run_trial(io, label, cpu, count, signal)
    prefix = String(PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir)
    row(io, "trial", label, VERSION, Sys.KERNEL, Sys.ARCH, Threads.nthreads(),
        Threads.ngcthreads(), getpid(), cpu, now_ns())
    row(io, "meta", "julia", realpath(Base.julia_cmd().exec[1]))
    row(io, "meta", "project", PROJECT)
    row(io, "meta", "revision", readchomp(`git -C $PROJECT rev-parse HEAD`))
    row(io, "meta", "source_diff_sha256", source_hash(PROJECT))
    row(io, "meta", "benchmark_sha256", file_hash(@__FILE__))
    row(io, "meta", "manifest_sha256", file_hash(joinpath(PROJECT, "Manifest.toml")))
    row(io, "meta", "native_prefix", prefix)
    row(io, "meta", "client_affinity", readchomp(`taskset -pc $(getpid())`))
    row(io, "meta", "shutdown_signal", signal)
    row(io, "meta", "hostname", gethostname())
    row(io, "meta", "loadavg", strip(read("/proc/loadavg", String)))
    with_control_private_core(; temporary_prefix = "rtc-session-idle-", prefix) do socket, directory, daemon
        chmod(dirname(socket), 0o700)
        warmup = configure(socket, directory, daemon, "warmup-session", 201)
        config = configure(socket, directory, daemon, "timed-session", 101)
        receipt = joinpath(directory, "expiry.tsv")
        command = `taskset -c $cpu $(Base.julia_cmd()) --threads=1,0 --gcthreads=1,0 --startup-file=no --project=$PROJECT $(@__FILE__) --child $warmup $config $receipt`
        log = open(joinpath(directory, "session.log"), "w+")
        child = run(pipeline(command; stdout = log, stderr = log); wait = false)
        client = nothing
        check_child = () -> process_exited(child) && error("session exited early")
        try
            wait_proof(() -> isfile(receipt), 180, "warmed startup expiry"; check = check_child)
            row(io, "expiry", split(readchomp(receipt), '\t')...)
            client = C.connect(
                PipeWireAORTC.SessionProfile.Profile(), socket, "timed-session", getpid(child), 101;
                deadline = now_ns() + 30 * SECOND, controller_instance = 103, check = check_child,
            )
            samples(client, 4, 16, 0; budget = 30 * SECOND)
            # Compile and exercise the shared sampler and process reader before timing.
            idle_sample(devnull, getpid(child), 0.25)
            idle_sample(io, getpid(child), 5)
            light = samples(client, count, 1, 10_000_000)
            burst = samples(client, cld(count * 2, 32), 32, 20_000_000)
            for (phase, observations) in (("light", light), ("burst", burst))
                for (j, record) in enumerate(eachcol(observations))
                    row(io, "request", phase, isodd(j) ? "status" : "groups", record...)
                end
            end
            shutdown_sample(io, client, child, signal)
        catch
            flush(log)
            seekstart(log)
            print(stderr, read(log, String))
            rethrow()
        finally
            try
                client === nothing || close(client)
            finally
                try
                    stop_proof_child!(child, "benchmark-owned session")
                finally
                    close(log)
                end
            end
        end
    end
end

if first(ARGS) == "--child"
    Base.exit_on_sigint(false)
    _, warmup, config, receipt = ARGS
    @assert serve(warmup) == 0
    exit(serve(config; receipt))
else
    include(joinpath(PROJECT, "test", "control_private_core.jl"))
    label, cpu, output = ARGS[1:3]
    count = length(ARGS) >= 4 ? parse(Int, ARGS[4]) : 512
    signal = length(ARGS) == 5 && ARGS[5] == "SIGTERM" ? Base.SIGTERM : Base.SIGINT
    open(output, "w") do io
        run_trial(io, label, cpu, count, signal)
    end
end
