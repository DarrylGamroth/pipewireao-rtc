# External callers keep their registry/client allocations outside the owner oracle.
pushfirst!(LOAD_PATH, ARGS[1])
using PipeWireAO
pushfirst!(LOAD_PATH, ARGS[2])
using PipeWireAODeployment
const B = PipeWireAODeployment.NativeOwnerBootstrapClient
const C = PipeWireAODeployment.NativeControlClient

function primary(remote, name, pid, instance)
    client = B.connect(remote, name, pid, instance; deadline=C.monotonic() + 20)
    try
        println("READY")
        flush(stdout)
        readline(stdin) == "connect" || error("phase")
        B.connect_owner!(client; deadline=C.monotonic() + 20)
        println("CONNECTED")
        flush(stdout)
        readline(stdin) == "quit" || error("phase")
        B.quit!(client; deadline=C.monotonic() + 20)
        println("STOPPED")
        flush(stdout)
    finally
        close(client)
    end
end
function foreign(remote)
    loop = ThreadLoop("test.foreign.controller")
    context = core = registry = marker = nothing
    name = "pipewireao.rtc.controller.qualifier.$(getpid()).1"
    try
        with_thread_loop_lock(loop) do _
            context = Context(loop)
            core = CoreConnection(context; properties=Dict("remote.name" => remote))
            registry = Registry(core)
            marker = Filter(core, name; properties=Dict("node.name" => name,
                "media.class" => "Control", "pipewireao.rtc-control.protocol" => C.PROTOCOL,
                "pipewireao.rtc-control.profile" => C.CONTROLLER_PROFILE,
                "pipewireao.rtc-control.instance" => "1",
                "pipewireao.rtc-control.owner-pid" => string(getpid())))
        end
        start!(loop)
        println("READY")
        flush(stdout)
        readline(stdin) == "publish" || error("phase")
        @ccall gc_safe=true usleep(Cuint(200_000)::Cuint)::Cint
        with_thread_loop_lock(loop) do _
            connect!(marker; flags=FILTER_INACTIVE | FILTER_ASYNC)
        end
        roundtrip(core)
        found = only(find_globals(registry; properties=("node.name" => name,)))
        println("PUBLISHED ", found.id, " ", get(found.properties, "object.serial", "missing"),
            " ", time_ns())
        flush(stdout)
        @ccall gc_safe=true usleep(Cuint(1_000_000)::Cuint)::Cint
        with_thread_loop_lock(loop) do _
            close(marker)
        end
        marker = nothing
        roundtrip(core)
        println("REMOVED ", time_ns())
        flush(stdout)
    finally
        with_thread_loop_lock(loop) do _
            for resource in (marker, registry, core, context)
                resource === nothing || close(resource)
            end
        end
        close(loop)
    end
end
if ARGS[3] == "primary"
    primary(ARGS[4], ARGS[5], parse(Int, ARGS[6]), parse(Int64, ARGS[7]))
elseif ARGS[3] == "foreign"
    foreign(ARGS[4])
else
    error("unsupported peer mode")
end
