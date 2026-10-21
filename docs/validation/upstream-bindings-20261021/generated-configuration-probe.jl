using Test, PipeWireAORTC, PipeWireAO, JSON3
const root = ARGS[1]
const wp = ARGS[2]
const rtc = ARGS[3]
const evidence = ARGS[4]
const expected = ARGS[5]
include(joinpath(root, "test/native_control_private_core.jl"))
mkpath(evidence)
with_control_private_core() do socket, _, daemon
    chmod(dirname(socket), 0o700)
    spec = Dict("name" => "upstream-cpu", "source-owner" => "simulator",
        "owners" => [Dict("role" => "simulator",
            "control-protocol" => "pipewireao.source-control/1",
            "control-node" => "simulator-wfs")])
    session = Dict("authority" => "none", "profile" => "development",
        "sources" => [Dict("node.name" => "simulator-wfs")],
        "sinks" => [Dict("node.name" => "core-sink")], "graphs" => [],
        "links" => [Dict("output" => "simulator-wfs:out", "input" => "core-sink:in")])
    bindings = Dict("RUNTIME" => dirname(socket), "REMOTE" => basename(socket),
        "SESSION_UUID" => "00000000-0000-0000-0000-000000000001",
        "SESSION_SCRIPT" => joinpath(rtc, "share/pipewireao-rtc/scripts/ao/session.lua"),
        "SESSION_CONTROL_INSTANCE" => "21", "SESSION_CONTROLLER_INSTANCE" => "22",
        "ADMISSION_CONTROLLER_INSTANCE" => "23")
    records = Dict(role => Dict{String,Any}("role" => role, "pid" => pid,
        "state" => "running", "start-ticks" => 1, "invocation" => role * "-probe",
        "cgroup" => "/owners/" * role)
        for (role, pid) in (("simulator", getpid()), ("core", getpid(daemon))))
    records["simulator"]["control-instance"] = "24"
    config = PipeWireAORTC.SessionConfiguration.write_session_config(spec, session,
        bindings, records, dirname(socket); node_owners=Dict("simulator-wfs" => "simulator",
            "core-sink" => "core"), configuration_store_root=nothing)
    cp(config, joinpath(evidence, "rtc.conf"))
    environment = Dict("LD_LIBRARY_PATH" => joinpath(wp, "lib") * ":" *
            "/home/dgamroth/.local/opt/pipewireao-wp-reuse-20261021/lib",
        "WIREPLUMBER_MODULE_DIR" => joinpath(rtc, "lib/pipewireao-rtc/modules") * ":" * joinpath(wp, "lib/wireplumber-0.5"),
        "WIREPLUMBER_DATA_DIR" => joinpath(rtc, "share/pipewireao-rtc") * ":" * joinpath(wp, "share/wireplumber"))
    logfile = open(joinpath(evidence, "rtc.log"), "w+")
    binary = joinpath(rtc, "bin/pipewireao-rtc")
    process = run(pipeline(addenv(`$binary -c $config`, environment); stdout=logfile, stderr=logfile); wait=false)
    rtc_pid = getpid(process)
    client = nothing
    try
        if expected == "dependency-failure"
            @test timedwait(() -> process_exited(process), 10) == :ok
            @test process.exitcode != 0
            flush(logfile); seekstart(logfile)
            @test occursin("component", read(logfile, String))
        else
            health() = process_exited(process) ? error("RTC exited: $(process.exitcode)") : nothing
            client = PipeWireAORTC.NativeControlClient.connect(PipeWireAORTC.NativeSessionProfile.Profile(),
                socket, "pipewireao.rtc.session.upstream-cpu", rtc_pid, 21;
                deadline=time_ns()/1e9+60, check=health)
            reply = PipeWireAORTC.NativeControlClient.request!(client,
                PipeWireAORTC.NativeSessionCodec.RunnerCommand(:status);
                deadline=time_ns()/1e9+10, check=health)
            @test PipeWireAORTC.NativeSessionClient.lifecycle(reply) === :configuring
            @test !process_exited(process)
        end
    finally
        client === nothing || close(client)
        stop_proof_child!(process, "generated-config RTC")
        close(logfile)
    end
    write(joinpath(evidence, "receipt.json"), JSON3.write(Dict("expected"=>expected,
        "result"=>"passed", "rtc_pid"=>rtc_pid, "exitcode"=>process.exitcode,
        "wp_prefix"=>wp, "rtc_prefix"=>rtc, "cleanup"=>"owned RTC child stopped; private-core helper owns daemon"))*"\n")
end
