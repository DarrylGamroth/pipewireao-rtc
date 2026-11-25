# Run against the matching PipeWireAO SDK with the core test workspace.
module ParameterOwnerPrivateCoreTests

using Test, PipeWireAO, PipeWireAORTC

include("control_private_core.jl")

const Bootstrap = PipeWireAORTC.OwnerBootstrapClient
const Lifecycle = PipeWireAORTC.OwnerBootstrapCodec
const Client = PipeWireAORTC.ControlClient
const Parameter = PipeWireAORTC.ParameterSource
const Runner = PipeWireAORTC.RunnerCodec
const SOURCE = "test.parameter.reference"
const SINK = "test.graph"
const CONTROL = "test.parameter.control"
const BOOTSTRAP = "test.parameter.bootstrap"
const SCHEMA = "test/reference-f32/1"
const FORMAT = NdArrayFormat(NdArray.F32_LE, (2,); layout = NdArray.ROW_MAJOR)
const SHAPE = UInt32[2]
const STRIDE = 2 * sizeof(Float32)

deadline(seconds = 20) = Client.monotonic() + seconds

function data_port(registry, name, direction)
    nodes = find_globals(registry; interface = "PipeWire:Interface:Node",
        properties = ("node.name" => name,))
    isempty(nodes) && return nothing
    node = only(nodes)
    ports = find_globals(registry; interface = "PipeWire:Interface:Port",
        properties = ("node.id" => string(node.id), "port.direction" => direction))
    return isempty(ports) ? nothing : (node.id, only(ports).id)
end

function with_parameter_sink(f, socket)
    loop = ThreadLoop("parameter-inlet-test")
    context = core = registry = driver = sink = link = nothing
    receipts = Tuple{UInt64,NTuple{2,Float32}}[]
    try
        with_thread_loop_lock(loop) do _
            context = Context(loop)
            core = CoreConnection(context; properties = Dict("remote.name" => socket))
            registry = Registry(core)
            driver = create_object(core, "spa-node-factory", Node; properties = Dict(
                "factory.name" => "support.node.driver", "node.name" => "test.parameter.driver",
                "priority.driver" => "200000", "node.group" => "test.parameter.driver",
            ))
            parameters = (
                Pod(buffers_param(buffers = 2, blocks = 1, size = STRIDE)),
                Pod(header_metadata_param()),
            )
            sink = Stream(core, SINK; properties = Dict(
                "node.name" => SINK, "media.type" => "Application", "node.want-driver" => "true",
            ), on_param_changed = (stream, id, pod) -> begin
                id == SPA.PARAM_FORMAT && pod !== nothing && update_params!(stream, parameters)
                nothing
            end, on_process = stream -> begin
                buffer = dequeue_buffer(stream)
                buffer === nothing && return nothing
                try
                    memory = buffer_memory(buffer_data(buffer), STRIDE)
                    payload = Tuple(reinterpret(Float32, memory))
                    # Bound storage even if a broken source starts publishing continuously.
                    length(receipts) < 4 &&
                        push!(receipts, (buffer_header(buffer).sequence, payload))
                finally
                    queue_buffer!(buffer, stream)
                end
                nothing
            end)
            connect!(
                sink, :input;
                flags = STREAM_MAP_BUFFERS | STREAM_DONT_RECONNECT | STREAM_NO_CONVERT,
                params = (ndarray_format(FORMAT; schema = SCHEMA), parameters...),
            )
        end
        start!(loop)
        wait_proof(15, "parameter source and graph inlet Ports") do
            with_thread_loop_lock(loop) do _
                data_port(registry, SOURCE, "out") !== nothing &&
                    data_port(registry, SINK, "in") !== nothing
            end
        end
        link = with_thread_loop_lock(loop) do _
            output_node, output_port = data_port(registry, SOURCE, "out")
            input_node, input_port = data_port(registry, SINK, "in")
            create_object(core, "link-factory", Link; properties = Dict(
                "link.output.node" => string(output_node),
                "link.output.port" => string(output_port),
                "link.input.node" => string(input_node),
                "link.input.port" => string(input_port),
                "object.linger" => "false",
            ))
        end
        return f(loop, registry, receipts)
    finally
        with_thread_loop_lock(loop) do _
            for resource in (link, sink, driver, registry, core, context)
                resource === nothing || close(resource)
            end
        end
        close(loop)
    end
end

@testset "Native parameter owner publication and Quit" begin
    modules = "{ name = libpipewire-module-spa-node-factory }"
    with_control_private_core(; modules) do socket, directory, _
        chmod(dirname(socket), 0o700)
        initial_values = Float32[1.25, -2.5]
        live_values = Float32[-4.5, 8.25]
        initial = joinpath(directory, "initial.f32")
        update = joinpath(directory, "update.f32")
        write(initial, initial_values)
        write(update, live_values)
        config = joinpath(directory, "parameters.json")
        PipeWireAORTC.Common.write_json(config, Dict("version" => 1, "sources" => [Dict(
            "node_name" => SOURCE, "graph" => SINK, "inlet" => "reference",
            "element_type" => "F32_LE", "shape" => SHAPE,
            "layout" => "row-major", "schema" => SCHEMA,
            "initial_payload_path" => initial,
        )]))
        project = dirname(Base.active_project())
        code = "using PipeWireAORTC; PipeWireAORTC.ParameterSource.main(ARGS)"
        command = `$(Base.julia_cmd()) --startup-file=no --threads=2,0 --project=$project
            -e $code --
            --config $config --remote $socket --bootstrap-node $BOOTSTRAP --bootstrap-instance 41
            --control-node $CONTROL --control-instance 42`
        open(joinpath(directory, "parameter-owner.log"), "w+") do log
            child = run(pipeline(command; stdout = log, stderr = log); wait = false)
            bootstrap = control = nothing
            check() = process_exited(child) && error("parameter owner exited before Quit")
            try
                bootstrap = Bootstrap.connect(socket, BOOTSTRAP, getpid(child), 41;
                    deadline = deadline(120), check)
                connected = Bootstrap.connect_owner!(bootstrap; deadline = deadline(120), check)
                @test connected.lifecycle === Lifecycle.Connected
                control = Client.connect(Parameter.PROFILE, socket, CONTROL, getpid(child), 42;
                    deadline = deadline(), check)
                with_parameter_sink(socket) do loop, registry, receipts
                    wait_proof(15, "initial reference sample"; check) do
                        with_thread_loop_lock(_ -> !isempty(receipts), loop)
                    end
                    with_thread_loop_lock(loop) do _
                        @test receipts == [(UInt64(1), Tuple(initial_values))]
                    end
                    invalid = Runner.RunnerCommand(
                        :parameter, SINK, "undeclared", "F32_LE", SHAPE, SCHEMA, update,
                    )
                    rejection = Client.request!(control, invalid; deadline = deadline(), check)
                    @test rejection isa Parameter.Completion
                    @test rejection.header.result == -Base.Libc.EINVAL
                    @test (rejection.graph, rejection.inlet, rejection.sequence) ==
                        (SINK, "undeclared", 0)
                    @test !rejection.submitted && !rejection.active_adoption_observed
                    @test occursin("no declared parameter mapping", rejection.message)
                    valid = Runner.RunnerCommand(
                        :parameter, SINK, "reference", "F32_LE", SHAPE, SCHEMA, update,
                    )
                    completion = Client.request!(control, valid; deadline = deadline(), check)
                    @test completion isa Parameter.Completion
                    @test completion.header.result == 0
                    @test completion.header.token > rejection.header.token
                    @test (completion.graph, completion.inlet, completion.sequence) ==
                        (SINK, "reference", 2)
                    @test completion.submitted && !completion.active_adoption_observed
                    wait_proof(15, "submitted reference sample"; check) do
                        with_thread_loop_lock(_ -> length(receipts) >= 2, loop)
                    end
                    stopped = Bootstrap.quit!(bootstrap; deadline = deadline())
                    @test stopped.lifecycle === Lifecycle.Stopped
                    @test !process_exited(child)
                    close(bootstrap)
                    bootstrap = nothing
                    wait_proof(() -> process_exited(child), 15, "parameter owner exit")
                    @test success(child)
                    wait_proof(15, "parameter source and control withdrawal") do
                        with_thread_loop_lock(loop) do _
                            all((SOURCE, CONTROL, BOOTSTRAP)) do name
                                isempty(find_globals(registry; interface = "PipeWire:Interface:Node",
                                    properties = ("node.name" => name,)))
                            end
                        end
                    end
                    with_thread_loop_lock(loop) do _
                        @test receipts == [
                            (UInt64(1), Tuple(initial_values)), (UInt64(2), Tuple(live_values)),
                        ]
                    end
                end
            catch
                flush(log)
                seekstart(log)
                print(stderr, read(log, String))
                rethrow()
            finally
                control === nothing || close(control)
                bootstrap === nothing || close(bootstrap)
                stop_proof_child!(child, "parameter owner")
            end
        end
    end
end

end
