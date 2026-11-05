# Explicit user-systemd acceptance; only uniquely named test-owned units are changed.
using Test, PipeWireAORTC, JSON, Sockets
const MC = PipeWireAORTC.ManagementCLI
const BINARY = get(ENV, "PIPEWIREAO_MANAGEMENT_BINARY", "")
isfile(BINARY) || error("set PIPEWIREAO_MANAGEMENT_BINARY to the built companion")

function systemctl(args...)
    run(Cmd(["systemctl", "--user", args...]))
end
function wait_until(predicate; seconds = 15)
    deadline=time()+seconds
    while !predicate()
        time()<deadline || error("test-owned systemd acceptance deadline")
        sleep(0.05)
    end
end
function identities(units)
    Dict(
        unit=>read(
            Cmd([
                "systemctl",
                "--user",
                "show",
                unit,
                "--property=MainPID,InvocationID,ActiveState",
            ]),
            String,
        ) for unit in units
    )
end
function rpc(
    path,
    domain,
    operation,
    arguments;
    id = replace(string(Base.UUID(rand(UInt128))), "-"=>""),
)
    socket=connect(path)
    request=Dict(
        "protocol"=>"pipewireao.management/1",
        "id"=>id,
        "request"=>Dict("protocol"=>domain, "op"=>operation, "arguments"=>arguments),
    )
    write(socket, JSON.json(request)*"\n")
    flush(socket)
    return socket
end

@testset "installed activation, executable dollar path and cgroup crash cleanup" begin
    mktempdir() do root
        token=replace(string(Base.UUID(rand(UInt128))), "-"=>"")
        base="pipewireao-management-validation-$token"
        service=base*".service"
        socket_unit=base*".socket"
        job=base*"-independent-job.service"
        endpoint=joinpath(root, "management.sock")
        prefix=joinpath(root, "native \$value")
        mkpath(joinpath(prefix, "bin"))
        runtime=get(
            ENV,
            "PIPEWIREAO_MANAGEMENT_NATIVE_PREFIX",
            String(PipeWireAORTC.Common.PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir),
        )
        symlink(joinpath(runtime, "lib"), joinpath(prefix, "lib"))
        cp(BINARY, joinpath(prefix, "bin", "pipewireao-management"))
        chmod(joinpath(prefix, "bin", "pipewireao-management"), 0o700)
        state=joinpath(root, "receipts")
        units=MC.install(
            prefix;
            project = pkgdir(PipeWireAORTC),
            unit_directory = joinpath(root, "units"),
            root = state,
            configuration_root = joinpath(root, "catalog"),
            simulator_root = joinpath(root, "jobs"),
        )
        marker=joinpath(root, "worker-pids")
        script=joinpath(root, "worker \$value.jl")
        write(
            script,
            """
readline(stdin)
child=run(`sleep 60`;wait=false)
run(Cmd(["systemd-run","--user","--quiet","--collect","--unit="*$(repr(job)),"/usr/bin/sleep","60"]))
write($(repr(marker)),string(getpid())*" "*string(getpid(child)))
sleep(60)
""",
        )
        # Reuse the generated executable/argv quoting. Only replace the trusted
        # owner worker for deterministic crash injection; no scientific work runs.
        original=[
            Base.julia_cmd().exec[1],
            "--startup-file=no",
            "--heap-size-hint=256M",
            "--project=$(pkgdir(PipeWireAORTC))",
            "-e",
            "using PipeWireAORTC; PipeWireAORTC.ManagementCLI.serve()",
        ]
        fixture=[Base.julia_cmd().exec[1], "--startup-file=no", script]
        source=read(units["pipewireao-management.service"], String)
        @test occursin(MC.unit_argument(JSON.json(original)), source)
        source=replace(
            source,
            MC.unit_argument(JSON.json(original))=>MC.unit_argument(JSON.json(fixture)),
        )
        source=replace(
            source,
            "pipewireao-management.socket"=>socket_unit,
            "%t/pipewireao/management.sock"=>endpoint,
        )
        service_path=joinpath(root, service)
        write(service_path, source)
        socket_source=replace(
            read(units["pipewireao-management.socket"], String),
            "%t/pipewireao/management.sock"=>endpoint,
        )
        socket_path=joinpath(root, socket_unit)
        write(socket_path, socket_source)
        # The operator's existing units are read only throughout this test.
        observed=filter(
            !isempty,
            split(get(ENV, "PIPEWIREAO_MANAGEMENT_OBSERVE_UNITS", ""), ','),
        )
        before=identities(observed)
        connected=nothing
        try
            systemctl("link", "--runtime", service_path, socket_path)
            systemctl("daemon-reload")
            systemctl("start", socket_unit)
            wait_until(()->ispath(endpoint))
            id="d"^32
            connected=rpc(
                endpoint,
                "pipewireao.configuration/1",
                "get",
                Dict("id"=>"test-owned");
                id,
            )
            wait_until(()->isfile(marker))
            pids=parse.(Int, split(read(marker, String)))
            @test length(pids)==2
            @test all(pid->isdir("/proc/$pid"), pids)
            @test isfile(joinpath(state, id*".json"))
            @test success(Cmd(["systemctl", "--user", "is-active", "--quiet", job]))
            # Killing this service's main process must also remove the cached
            # worker and its spawned child through the installed KillMode policy.
            systemctl("kill", "--kill-whom=main", "--signal=SIGKILL", service)
            close(connected)
            connected=nothing
            wait_until(()->all(pid->!isdir("/proc/$pid"), pids))
            @test all(pid->!isdir("/proc/$pid"), pids)
            @test success(Cmd(["systemctl", "--user", "is-active", "--quiet", job]))
            systemctl("reset-failed", service)
            receipt=rpc(endpoint, "pipewireao.management/1", "receipt", Dict("id"=>id))
            reply=JSON.parse(readline(receipt))
            close(receipt)
            @test reply["ok"]
            @test reply["result"]["state"]=="unknown"
            @test !haskey(reply["result"], "response")
            @test identities(observed)==before
        finally
            connected===nothing || close(connected)
            # Names are unique to this test; no installed RTC/owner unit is stopped.
            for unit in (service, socket_unit, job)
                success(Cmd(["systemctl", "--user", "stop", unit]))
                success(Cmd(["systemctl", "--user", "reset-failed", unit]))
            end
            success(
                Cmd(["systemctl", "--user", "disable", "--runtime", service, socket_unit]),
            )
            systemctl("daemon-reload")
        end
    end
end
