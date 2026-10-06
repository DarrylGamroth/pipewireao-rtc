using Test
using JSON3
using PipeWireAODeployment

const DeploymentTest = PipeWireAODeployment.Deployment

const DEPLOYMENT_RUNNER_CONFIG = raw"""
profile = development
execution = external-rtc
authority = none
claim = development-characterization
rate = 100/1
sources = [
  { ownership = external run-control = application node.name = fixture.plant-frame
    ports = [ { name = output_1 direction = output element-type = U16_LE shape = [ 2 ] schema = org.test.frame/1 } ] }
  { ownership = external run-control = application node.name = fixture.controller-command
    ports = [ { name = output_1 direction = output element-type = F32_LE shape = [ 2 ] schema = org.test.command/1 } ] }
]
graphs = []
sinks = [
  { ownership = external node.name = fixture.controller-frame
    ports = [ { name = input_1 direction = input element-type = U16_LE shape = [ 2 ] schema = org.test.frame/1 } ] }
  { ownership = external node.name = fixture.plant-command
    ports = [ { name = input_1 direction = input element-type = F32_LE shape = [ 2 ] schema = org.test.command/1 } ] }
]
execution-groups = []
properties = {}
parameters = {}
observations = []
links = [
  { output = "fixture.plant-frame:output_1" input = "fixture.controller-frame:input_1" passive = false }
  { output = "fixture.controller-command:output_1" input = "fixture.plant-command:input_1" passive = false }
]
"""

const DEPLOYMENT_TOY_OWNER = raw"""
using PipeWireAO

const runtime = ENV["PIPEWIREAO_RUNTIME_DIR"]
const remote = joinpath(runtime, ENV["PIPEWIREAO_REMOTE"])
const frame = NdArrayFormat(NdArray.U16_LE, (2,); layout=NdArray.ROW_MAJOR,
    rate=PipeWireAO.SPA.Fraction(100, 1))
const command = NdArrayFormat(NdArray.F32_LE, (2,); layout=NdArray.ROW_MAJOR,
    rate=PipeWireAO.SPA.Fraction(100, 1))
touch(name) = open(joinpath(runtime, name), "w") do _; nothing; end

loop = ThreadLoop("fixture.deployment.endpoints")
context = core = nothing
endpoints = Any[]
try
    with_thread_loop_lock(loop) do _
        context = Context(loop)
        core = CoreConnection(context; properties=Dict("remote.name" => ENV["PIPEWIREAO_REMOTE"]))
        push!(endpoints, NdArraySource(core, "fixture.plant-frame", zeros(UInt16, 2), frame;
            schema="org.test.frame/1"))
        push!(endpoints, NdArraySink(core, "fixture.controller-frame", zeros(UInt16, 2), frame;
            schema="org.test.frame/1"))
        push!(endpoints, NdArraySource(core, "fixture.controller-command", zeros(Float32, 2), command;
            schema="org.test.command/1"))
        push!(endpoints, NdArraySink(core, "fixture.plant-command", zeros(Float32, 2), command;
            schema="org.test.command/1"))
    end
    start!(loop)
    deadline = time_ns() / 1e9 + 60
    while !all(endpoint -> node_id(endpoint) != typemax(UInt32), endpoints)
        time_ns() / 1e9 < deadline || error("toy ndarray nodes did not register")
        sleep(0.01)
    end
    touch("toy.prepared")
    while !isfile(joinpath(runtime, "toy.connect"))
        time_ns() / 1e9 < deadline || error("supervisor did not release toy endpoint connection")
        sleep(0.01)
    end
    foreach(start!, endpoints)
    all(isrunning, endpoints) || error("toy ndarray endpoints did not become active")
    touch("toy.connected")
    while !isfile(joinpath(runtime, "toy.quit")) && ispath(remote)
        time_ns() / 1e9 < deadline + 360 || error("toy endpoint owner exceeded lifecycle bound")
        sleep(0.02)
    end
finally
    for endpoint in reverse(endpoints)
        try close(endpoint) catch end
    end
    for resource in (core, context)
        resource === nothing && continue
        try close(resource) catch end
    end
    try close(loop) catch end
end
"""

const DEPLOYMENT_CORE_CONFIG = raw"""
context.properties = {
    core.daemon = true
    core.name = "@REMOTE@"
    support.dbus = false
    library.use-fallback = false
    mem.mlock-all = false
    default.clock.min-quantum = 1
    default.clock.quantum-floor = 1
}
context.spa-libs = {
    support.* = support/libspa-support
    api.ndarray.* = ndarray/libspa-ndarray
}
context.modules = [
    { name = libpipewire-module-scheduler-v1 }
    { name = libpipewire-module-protocol-native }
    { name = libpipewire-module-spa-node-factory }
    { name = libpipewire-module-client-node }
    { name = libpipewire-module-metadata }
    { name = libpipewire-module-access }
    { name = libpipewire-module-link-factory args = { allow.link.passive = true } }
]
"""

const DEPLOYMENT_CLIENT_CONFIG = raw"""
context.properties = {
    support.dbus = false
    library.use-fallback = false
    mem.mlock-all = false
}
context.spa-libs = { support.* = support/libspa-support }
context.modules = [
    { name = libpipewire-module-protocol-native }
    { name = libpipewire-module-client-node }
    { name = libpipewire-module-spa-node-factory }
    { name = libpipewire-module-metadata }
]
"""

function deployment_artifact(path)
    DeploymentTest.digest(path)
end

function deployment_placement(cpu)
    Dict("cpus" => [cpu], "leader-cpu" => cpu, "rt-priority" => 0,
        "threads" => Any[], "locked-bytes" => 0)
end

function deployment_toy_script(package)
    path = joinpath(package, "toy_owner.jl")
    write(path, DEPLOYMENT_TOY_OWNER)
    return path
end

function deployment_proc_identity(pid::Integer)
    line = try read("/proc/$pid/stat", String) catch; return nothing end
    closing = findlast(==(')'), line)
    closing === nothing && return nothing
    fields = split(strip(line[closing + 1:end]))
    length(fields) >= 20 || return nothing
    starttime = try parse(UInt64, fields[20]) catch; return nothing end
    pgrp = try parse(Int, fields[3]) catch; return nothing end
    session = try parse(Int, fields[4]) catch; return nothing end
    return (; starttime, pgrp, session)
end

function deployment_owned_identities(state)
    identities = NamedTuple[]
    for process in values(get(state, "processes", Dict{String,Any}()))
        leader = Int(process["pid"])
        for member in DeploymentTest._owned_group_members(leader)
            identity = deployment_proc_identity(member.pid)
            identity === nothing && continue
            identity.pgrp == leader && identity.session == leader || continue
            push!(identities, (; pid=member.pid, identity))
        end
    end
    return identities
end

function kill_owned_identities!(identities)
    # Last-resort cleanup is PID-reuse safe: signal only individual processes
    # whose start time and owned session/group still match the admitted snapshot.
    for item in identities
        pid = item.pid
        expected = item.identity
        current = deployment_proc_identity(pid)
        current == expected || continue
        current.pgrp == expected.pgrp == expected.session || continue
        ccall(:kill, Cint, (Cint, Cint), pid, Base.SIGKILL)
    end
    deadline = time() + 10
    while time() < deadline && any(item -> deployment_proc_identity(item.pid) == item.identity,
            identities)
        sleep(0.02)
    end
    return nothing
end

function kill_fixture_tree!(runtime, supervisor, identities)
    # First give the owned supervisor its ordinary public quit path. If that is
    # unavailable, interrupt only this exact child process and its finally path.
    state_path = joinpath(runtime, "state.json")
    if !process_exited(supervisor) && process_running(supervisor) && isfile(state_path)
        state = JSON3.read(read(state_path, String), Dict{String,Any})
        socket = get(state, "socket", nothing)
        if get(state, "admitted", false) && socket isa String && ispath(socket)
            try DeploymentTest.control(socket, ["quit"]; timeout=8, allow_rejection=true) catch end
        end
    end
    if !process_exited(supervisor)
        timedwait(() -> process_exited(supervisor), 20; pollint=0.02)
        process_exited(supervisor) || kill(supervisor, Base.SIGINT)
        timedwait(() -> process_exited(supervisor), 12; pollint=0.02)
        process_exited(supervisor) || kill(supervisor, Base.SIGKILL)
        timedwait(() -> process_exited(supervisor), 10; pollint=0.02)
        process_exited(supervisor) && wait(supervisor)
    end
    kill_owned_identities!(identities)
    return nothing
end

function run_native_runner_deployment()
    @testset "supervised native runner deployment" begin
        current_identity = deployment_proc_identity(getpid())
        @test current_identity !== nothing
        # A stale snapshot for this live test process must be ignored safely.
        stale_identity = (; current_identity..., starttime=current_identity.starttime + 1)
        @test_nowarn kill_owned_identities!([(; pid=getpid(), identity=stale_identity)])

        binary = get(ENV, "NATIVE_RUNNER_BINARY", "")
        isfile(binary) && isexecutable(binary) || error(
            "set NATIVE_RUNNER_BINARY to E/native-filter-target/debug/pipewireao-rtc")
        prefix = "/opt/pipewireao"
        cpu = 14
        cpu in PipeWireAODeployment.Placement.inherited_cpus() ||
            error("CPU 14 is not available in the inherited affinity")
        evidence_root = get(ENV, "NATIVE_RUNNER_EVIDENCE",
            joinpath(homedir(), ".cache", "rtc-live-controls-20261005"))
        evidence = mkpath(joinpath(evidence_root, "native-runner-deployment-$(time_ns())"))
        package = mkpath(joinpath(evidence, "package"))
        mkdir(joinpath(package, "bin"))
        cp(binary, joinpath(package, "bin", "pipewireao-rtc"))
        chmod(joinpath(package, "bin", "pipewireao-rtc"), 0o755)
        toy = deployment_toy_script(package)
        project = PipeWireAODeployment.package_root()
        julia = Base.julia_cmd().exec[1]
        owner = Dict{String,Any}("role"=>"toy", "argv"=>[julia, "--startup-file=no",
            "--threads=1", "--project=$project", toy], "environment"=>Dict{String,String}(),
            "prepared"=>"toy.prepared", "connect"=>"toy.connect", "connected"=>"toy.connected",
            "quit"=>"toy.quit")
        files = Dict("session.conf.in"=>DEPLOYMENT_RUNNER_CONFIG,
            "core.conf.in"=>DEPLOYMENT_CORE_CONFIG,
            "client.conf.in"=>DEPLOYMENT_CLIENT_CONFIG)
        for (name, content) in files
            write(joinpath(package, name), content)
        end
        dummy_fits = joinpath(evidence, "unused.fits")
        write(dummy_fits, UInt8[])
        clients = Dict("core"=>"client.conf.in", "rtc"=>"client.conf.in", "toy"=>"client.conf.in")
        placements = Dict(role=>deployment_placement(cpu) for role in ("core", "rtc", "toy"))
        artifacts = Dict(name=>deployment_artifact(joinpath(package, name)) for name in keys(files))
        artifacts["toy_owner.jl"] = deployment_artifact(toy)
        artifacts["bin/pipewireao-rtc"] = deployment_artifact(joinpath(package, "bin/pipewireao-rtc"))
        spec = Dict{String,Any}("version"=>1, "name"=>"native-runner-deployment",
            "session"=>"session.conf.in", "core"=>"core.conf.in", "client"=>clients,
            "placement"=>placements, "owners"=>[owner], "environment"=>Dict{String,String}(),
            "cpu-latency-us"=>nothing, "artifacts"=>artifacts)
        deployment_path = joinpath(package, "deployment.conf")
        DeploymentTest.atomic_record(deployment_path, spec)
        @test DeploymentTest.profile(deployment_path, prefix) == spec

        # Retain package, process and report evidence under the requested E/.
        runtime = mktempdir("/tmp"; prefix="nrd-")
        chmod(runtime, 0o700)
        supervisor_log_path = joinpath(evidence, "supervisor.log")
        supervisor_log = open(supervisor_log_path, "w+")
        code = "using PipeWireAODeployment; " *
            "D=PipeWireAODeployment.Deployment; " *
            "D.run(D.DeploymentRunner((; deployment=ARGS[1], pipewire_prefix=ARGS[2], " *
            "runtime=ARGS[3], fits=ARGS[4], owner_preparation_timeout_seconds=120)))"
        command = Cmd([julia, "--startup-file=no", "--threads=14",
            "--project=$project", "-e", code, deployment_path, prefix, runtime, dummy_fits])
        supervisor = nothing
        owned_identities = NamedTuple[]
        try
            supervisor = Base.run(pipeline(command; stdout=supervisor_log, stderr=supervisor_log); wait=false)
            admitted = DeploymentTest.wait_state(runtime,
                state -> get(state, "phase", nothing) == "running" && get(state, "admitted", false);
                timeout=180, process=supervisor)
            owned_identities = deployment_owned_identities(admitted)
            @test admitted["runner"]["node"] == "pipewireao.rtc.runner.native-runner-deployment"
            @test admitted["runner"]["instance"] isa Integer && admitted["runner"]["instance"] > 0
            run_directory = joinpath(runtime, admitted["instance"])
            @test isfile(joinpath(run_directory, "toy.prepared"))
            @test isfile(joinpath(run_directory, "toy.connected"))
            @test !ispath(joinpath(run_directory, "native-control.sock"))
            @test !ispath(joinpath(run_directory, "control.sock"))
            @test isfile(admitted["control_locator"])

            socket = admitted["socket"]
            invalid = DeploymentTest.control(socket, ["session-start", "extra"];
                request_id="native-invalid-command", timeout=30, allow_rejection=true)
            @test invalid["id"] == "native-invalid-command"
            @test invalid["ok"] === false
            after_invalid = DeploymentTest.control(socket, ["status"];
                request_id="native-status-after-invalid", timeout=30)
            @test after_invalid["ok"] && after_invalid["state"] == "Running"
            first_status = DeploymentTest.control(socket, ["status"]; request_id="native-status-1", timeout=30)
            second_status = DeploymentTest.control(socket, ["status"]; request_id="native-status-2", timeout=30)
            for status in (first_status, second_status)
                @test status["ok"]
                @test status["state"] == "Running"
                @test status["result"]["lifecycle_state"] == "Running"
                @test status["result"]["owned_nodes"] == 0
                @test status["result"]["owned_links"] == 2
            end
            @test first_status["id"] == "native-status-1"
            @test second_status["id"] == "native-status-2"

            stopped = DeploymentTest.control(socket, ["session-stop"]; request_id="native-stop", timeout=30)
            @test stopped["ok"] && stopped["state"] == "Ready"
            reset = DeploymentTest.control(socket, ["reset"]; request_id="native-reset", timeout=30)
            @test reset["ok"] && reset["state"] == "Ready"
            started = DeploymentTest.control(socket, ["session-start"]; request_id="native-start", timeout=30)
            @test started["ok"] && started["state"] == "Running"
            quit = DeploymentTest.control(socket, ["quit"]; request_id="native-quit", timeout=30)
            @test quit["ok"] && quit["result"]["shutdown"]

            final = DeploymentTest.wait_final_report(runtime, supervisor; timeout=180)
            @test final["phase"] == "stopped" && !final["admitted"]
            wait(supervisor)
            @test success(supervisor)
            @test final["runner"] == admitted["runner"]
            @test !ispath(joinpath(runtime, admitted["instance"]))
            for (role, record) in final["processes"]
                pid = Int(record["pid"])
                @test !ispath("/proc/$pid")
                @test isempty(DeploymentTest._live_owned_orphans(pid))
            end
            @test !ispath(joinpath(run_directory, "control.sock"))
            @test !ispath(joinpath(run_directory, "native-control.sock"))
            @test isempty(get(final, "cleanup_errors", Any[]))
            flush(supervisor_log)
            seekstart(supervisor_log)
            log_text = read(supervisor_log, String)
            @test occursin("DEPLOYMENT_READY", log_text)
            write(joinpath(evidence, "summary.json"), JSON3.write(Dict(
                "runner_binary"=>binary, "runner_sha256"=>artifacts["bin/pipewireao-rtc"],
                "endpoint"=>admitted["runner"], "processes"=>final["processes"],
                "controls"=>["status", "session-stop", "reset", "session-start", "quit"],
                "ndarray_frames_submitted"=>0, "ndarray_sinks_armed"=>0,
                "science_or_rate_claim"=>false)))
            println("NATIVE_RUNNER_DEPLOYMENT_EVIDENCE=$evidence")
        finally
            supervisor === nothing || kill_fixture_tree!(runtime, supervisor, owned_identities)
            flush(supervisor_log)
            close(supervisor_log)
            runtime_state = joinpath(runtime, "state.json")
            isfile(runtime_state) && cp(runtime_state, joinpath(evidence, "state.json"); force=true)
            ispath(runtime) && rm(runtime; recursive=true, force=true)
            println("NATIVE_RUNNER_DEPLOYMENT_EVIDENCE=$evidence")
        end
    end
end

run_native_runner_deployment()
