# Run with --threads=3,0 in a matching PipeWireAO and FilterGraphPipeWire environment.
using Test, PipeWireAO, PipeWireAORTC, FilterGraphPipeWire, FilterGraphs, FilterGraphAlgorithms
import ThreadPinning

include("control_private_core.jl")

const Bootstrap = PipeWireAORTC.OwnerBootstrapRuntime
const Client = PipeWireAORTC.OwnerBootstrapClient
const GraphExtension = Base.get_extension(PipeWireAORTC, :PipeWireAORTCGraphExt)
const Codec = PipeWireAORTC.OwnerBootstrapCodec
const Format = NdArrayFormat(NdArray.F32_LE, (2,); layout = NdArray.ROW_MAJOR,
    rate = SPA.Fraction(100, 1))
const Schema = "test.persistent-graph-fifo/1"

function fifo_port(registry, name, direction)
    nodes = find_globals(registry; interface = "PipeWire:Interface:Node",
        properties = ("node.name" => name,))
    isempty(nodes) && return nothing
    node = only(nodes)
    ports = find_globals(registry; interface = "PipeWire:Interface:Port",
        properties = ("node.id" => string(node.id), "port.direction" => direction))
    return isempty(ports) ? nothing : (node.id, only(ports).id)
end

function wait_fifo(check, label)
    deadline = PipeWireAORTC.ControlClient.monotonic() + 10
    while !check()
        PipeWireAORTC.ControlClient.monotonic() < deadline || error("deadline expired for $label")
        # Julia's timer can depend on the main thread, which is in native run!.
        @ccall gc_safe = true usleep(Cuint(5_000)::Cuint)::Cint
        yield()
    end
end

function fifo_link(core, registry, output_name, input_name)
    loop = main_loop(core)
    wait_fifo("FIFO Link ports") do
        with_thread_loop_lock(loop) do _
            fifo_port(registry, output_name, "out") !== nothing &&
                fifo_port(registry, input_name, "in") !== nothing
        end
    end
    return with_thread_loop_lock(loop) do _
        output, output_port = fifo_port(registry, output_name, "out")
        input, input_port = fifo_port(registry, input_name, "in")
        create_object(core, "link-factory", Link; properties = Dict(
            "link.output.node" => string(output), "link.output.port" => string(output_port),
            "link.input.node" => string(input), "link.input.port" => string(input_port),
            "object.linger" => "false",
        ))
    end
end

function remove_retained_route!(core, registry, source, sink, seen)
    loop = main_loop(core)
    output = fifo_link(core, registry, "fifo.graph", "fifo.sink")
    input = fifo_link(core, registry, "fifo.source", "fifo.graph")
    try
        roundtrip(core)
        start!(sink)
        start!(source)
        wait_fifo("streaming FIFO source driver") do
            with_thread_loop_lock(loop) do _
                stream_state(source.stream) == PipeWireAO.LibPipeWire.PW_STREAM_STATE_STREAMING &&
                    is_driving(source.stream)
            end
        end
        header = BufferHeader(UInt32(0), UInt32(0), Int64(0), Int64(0), UInt64(1))
        submit_array!(source, Float32[1, 2], header)
        wait_fifo("retained FIFO output") do
            seen[] && return true
            with_thread_loop_lock(loop) do _
                trigger_process!(source.stream)
            end
            return false
        end
    finally
        with_thread_loop_lock(loop) do _
            close(output)
            close(input)
        end
    end
    return nothing
end

function prove_fifo_revocation(remote, directory, daemon; persistent, remove_controller)
    chmod(dirname(remote), 0o700)
    runtime = Bootstrap.Runtime(remote, "fifo.bootstrap", Int64(81); persistent)
    loop = ThreadLoop("fifo.fixture")
    context, core, registry = with_thread_loop_lock(loop) do _
        context = Context(loop)
        core = CoreConnection(context; properties = Dict("remote.name" => remote))
        context, core, Registry(core)
    end
    start!(loop)
    seen = Threads.Atomic{Bool}(false)
    ports = (
        NdArrayFilterPort("input", PipeWireAO.DIRECTION_INPUT, Format; schema = Schema),
        NdArrayFilterPort("output", PipeWireAO.DIRECTION_OUTPUT, Format; schema = Schema),
    )
    filter = NdArrayFilter("fifo.graph", ports; remote, fifo_inputs = true,
        on_process = (_, inputs, outputs) -> begin
            set_output_available!(outputs[1], false)
            seen[] = true
            nothing
        end)
    source = NdArraySource(core, "fifo.source", zeros(Float32, 2), Format; schema = Schema)
    sink = NdArraySink(core, "fifo.sink", zeros(Float32, 2), Format; schema = Schema)
    claimant = nothing
    failure_seen = Threads.Atomic{Bool}(false)
    peer = nothing
    deadline() = PipeWireAORTC.ControlClient.monotonic() + 15
    try
        connect!(filter)
        claimant = Client.connect(remote, "fifo.bootstrap", getpid(), 81; deadline = deadline())
        Bootstrap.prepared!(runtime)
        connecting = @async Client.connect_owner!(claimant; deadline = deadline())
        ticket = Bootstrap.take_connect!(runtime)
        Bootstrap.connecting!(runtime, ticket; ready = () -> false, quit = () -> quit!(filter))
        Bootstrap.connected!(runtime, ticket)
        fetch(connecting).lifecycle === Codec.Connected || error("Connect did not complete")
        peer = ThreadPinning.@spawnat 3 try
            remove_retained_route!(core, registry, source, sink, seen)
            wait_fifo(() -> failure_seen[], "FIFO run failure after Link removal")
            if remove_controller
                sleep(0.05)
                close(claimant)
            end
        finally
            quit!(filter)
        end
        failure = try
            run!(filter)
            nothing
        catch error
            error
        end
        @test failure isa PipeWireAO.PipeWireError
        @test failure.operation === :pw_ndarray_filter_run && failure.code == -Base.Libc.EPIPE
        @test runtime.failure === nothing
        failure_seen[] = true
        @test GraphExtension.owner_cancelled(failure, runtime) == (persistent && remove_controller)
        fetch(peer)
    finally
        if peer !== nothing && !istaskdone(peer)
            failure_seen[] = true
            wait(peer)
        end
        Bootstrap.finishing!(runtime)
        close(filter)
        with_thread_loop_lock(loop) do _
            foreach(close, (sink, source, registry, core, context))
        end
        close(loop)
        close(runtime)
        claimant === nothing || close(claimant)
    end
end

@testset "real retained FIFO removal and exact controller loss" begin
    for (persistent, remove_controller) in ((true, true), (true, false), (false, true))
        with_control_private_core() do remote, directory, daemon
            prove_fifo_revocation(remote, directory, daemon; persistent, remove_controller)
        end
    end
end
