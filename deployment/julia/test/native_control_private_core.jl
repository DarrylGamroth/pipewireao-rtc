using Test
using PipeWireAO

function wait_proof(predicate, seconds::Real, label::AbstractString; check=()->nothing)
    deadline = time_ns() / 1e9 + seconds
    while true
        check()
        predicate() && return nothing
        time_ns() / 1e9 < deadline || error("finite private-core fixture deadline expired: $label")
        sleep(0.002)
    end
end

function stop_proof_child!(process::Base.Process, label::AbstractString)
    if !Base.process_exited(process)
        kill(process)
        if timedwait(() -> Base.process_exited(process), 5; pollint=0.005) != :ok
            kill(process, Base.SIGKILL)
            timedwait(() -> Base.process_exited(process), 5; pollint=0.005) == :ok ||
                error("$label did not exit after SIGKILL")
        end
    end
    Base.process_exited(process) || error("$label exit was not observed")
    wait(process)
    return nothing
end

function with_control_private_core(f; check_running=true)
    prefix = String(PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir)
    libdir = isdir(joinpath(prefix, "lib", "x86_64-linux-gnu")) ?
        joinpath(prefix, "lib", "x86_64-linux-gnu") : joinpath(prefix, "lib")
    daemon_path = joinpath(prefix, "bin", "pipewire-ao")
    mktempdir(prefix="pipewireao-native-envelope-") do directory
        runtime = joinpath(directory, "runtime")
        config = joinpath(directory, "configuration")
        mkpath(runtime)
        mkpath(config)
        remote = "native-envelope-$(getpid())-$(time_ns())"
        socket = joinpath(runtime, remote)
        write(joinpath(config, "private-core.conf"), """
        context.properties = { core.daemon = true core.name = $remote support.dbus = false library.use-fallback = false }
        context.spa-libs = { support.* = support/libspa-support }
        context.modules = [
            { name = libpipewire-module-scheduler-v1 }
            { name = libpipewire-module-protocol-native }
            { name = libpipewire-module-client-node }
            { name = libpipewire-module-link-factory }
            { name = libpipewire-module-metadata }
            { name = libpipewire-module-access }
        ]
        """)
        write(joinpath(config, "client.conf"), """
        context.properties = { support.dbus = false }
        context.spa-libs = { support.* = support/libspa-support }
        context.modules = [
            { name = libpipewire-module-protocol-native }
            { name = libpipewire-module-client-node }
            { name = libpipewire-module-metadata }
        ]
        """)
        environment = Dict(
            "XDG_RUNTIME_DIR" => runtime,
            "PIPEWIREAO_RUNTIME_DIR" => runtime,
            "PIPEWIREAO_CONFIG_DIR" => config,
            "PIPEWIREAO_MODULE_DIR" => joinpath(libdir, "pipewire-ao-0.3"),
            "PIPEWIREAO_SPA_PLUGIN_DIR" => joinpath(libdir, "spa-ao-0.2"),
            "PIPEWIREAO_DEBUG" => "0",
            "LD_LIBRARY_PATH" => libdir * ":" * get(ENV, "LD_LIBRARY_PATH", ""),
        )
        core_log = open(joinpath(directory, "private-core.log"), "w+")
        daemon = nothing
        try
            daemon = run(pipeline(addenv(`$daemon_path -c private-core.conf`, environment);
                stdout=core_log, stderr=core_log); wait=false)
            timedwait(() -> ispath(socket), 10; pollint=0.01) == :ok ||
                error("private PipeWire core socket startup timed out")
            withenv(environment...) do
                f(socket, directory, daemon)
            end
            check_running && @test !Base.process_exited(daemon)
        catch
            flush(core_log)
            seekstart(core_log)
            print(stderr, read(core_log, String))
            rethrow()
        finally
            if daemon !== nothing
                stop_proof_child!(daemon, "private PipeWire daemon")
            end
            close(core_log)
        end
    end
end

