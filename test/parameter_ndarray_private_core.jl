using Test, PipeWireAO, PipeWireAORTC, Clocks

include("control_private_core.jl")

const RTC = PipeWireAORTC
const Parameter = RTC.ParameterSource
const Runner = RTC.RunnerCodec
const Codec = RTC.ControlCodec
const Endpoint = RTC.ControlEndpoint
const Bootstrap = RTC.OwnerBootstrapCodec

struct PrivateParameterTransfer{T}
    transport::T
end

function Parameter.check_parameter_ticket(::PrivateParameterTransfer, _, active)
    Int64(time_ns()) < active.deadline || error("private parameter transfer expired")
    return nothing
end

@testset "Native ndarray parameter data path beyond SPA request capacity" begin
    modules = "{ name = libpipewire-module-spa-node-factory }"
    with_control_private_core(; modules) do socket, directory, _
        chmod(dirname(socket), 0o700)
        registry_type = "PipeWire:Interface:Port"
        transport = Endpoint.Transport(Bootstrap.PROFILE, socket, "parameter-transport-test", Int64(17), Bootstrap.Preparing)
        runtime = PrivateParameterTransfer(transport)
        registry = something(transport.endpoint.registry)
        endpoint = (; loop = transport.loop, registry, instance = Int64(42))
        sender_loop = ThreadLoop("parameter-test-sender")
        driver = controller = stream = core = context = nothing
        format = NdArrayFormat(NdArray.F32_LE, (8192,); layout = NdArray.ROW_MAJOR)
        schema = "pipewireao/private-parameter-transport/1"
        values = Float32[mod(i, 293) for i in 1:8192]
        values[1] = -0.0f0
        data = reinterpret(UInt8, values)
        sent = Ref(false)
        buffer = StreamBuffer()
        parameters = (Pod(buffers_param(buffers = 2, blocks = 1, size = length(data))), Pod(header_metadata_param()))
        control_name = "pipewireao.rtc.controller.parameter-test"
        try
            with_thread_loop_lock(sender_loop) do _
                context = Context(sender_loop)
                core = CoreConnection(context; properties = Dict("remote.name" => socket))
                driver = create_object(core, "spa-node-factory", Node; properties = Dict(
                    "factory.name" => "support.node.driver", "node.name" => "test-parameter-driver",
                    "priority.driver" => "200000", "node.group" => "test-parameter-driver",
                ))
                controller = Filter(core, control_name; properties = RTC.MediaSession.endpoint_properties(
                    RTC.ControlClient.CONTROLLER_PROFILE, Int64(43), control_name,
                ))
                connect!(controller; flags = FILTER_INACTIVE)
                stream = Stream(core, "private-parameter-producer";
                    properties = Dict(
                        "node.name" => "private-parameter-producer", "node.want-driver" => "true",
                        "media.type" => "Application", "media.category" => "Playback",
                    ),
                    on_param_changed = (stream, id, pod) -> begin
                        id == SPA.PARAM_FORMAT && pod !== nothing && update_params!(stream, parameters)
                        nothing
                    end,
                    on_process = stream -> begin
                        sent[] && return nothing
                        dequeue_buffer!(buffer, stream) || return nothing
                        plane = buffer_data(buffer)
                        copyto!(buffer_memory(plane, length(data)), data)
                        set_chunk!(plane; size = length(data), stride = length(data))
                        set_buffer_size!(buffer, length(values))
                        set_buffer_header!(buffer, BufferHeader(0, 0, 0, 0, UInt64(1)))
                        queue_buffer!(buffer, stream)
                        sent[] = true
                        nothing
                    end,
                )
                connect!(stream, :output; flags = STREAM_MAP_BUFFERS | STREAM_DONT_RECONNECT | STREAM_NO_CONVERT,
                    params = (ndarray_format(format; schema), parameters...))
            end
            start!(sender_loop)
            selected = Ref{Any}(nothing)
            wait_proof(15, "parameter output producer and controller") do
                with_thread_loop_lock(transport.loop) do _
                    node = PipeWireAO.find_global(registry, node_id(stream))
                    controller_global = PipeWireAO.find_global(registry, node_id(controller))
                    (node === nothing || controller_global === nothing) && return false
                    ports = filter(find_globals(registry; interface = registry_type)) do port
                        get(port.properties, "node.id", "") == string(node.id) &&
                            get(port.properties, "port.direction", "") == "out"
                    end
                    length(ports) == 1 || return false
                    port = only(ports)
                    serial(object) = parse(UInt64, object.properties["object.serial"])
                    selected[] = (
                        Codec.ControllerIdentity(controller_global.id, serial(controller_global), Int64(43)),
                        Runner.ParameterStream(node.id, serial(node), port.id, serial(port)),
                    )
                    return true
                end
            end
            origin, output = selected[]
            declaration = joinpath(directory, "parameter-source.json")
            RTC.Common.write_json(declaration, Dict("version" => 1, "sources" => [Dict(
                "node_name" => "test-declared-parameter", "graph" => "graph", "inlet" => "reference",
                "element_type" => "F32_LE", "shape" => [8192], "layout" => "row-major", "schema" => schema,
            )]))
            wake = Base.Event(true)
            source = only(Parameter.read_declarations(declaration, wake))
            clock = Clocks.SystemNanoClock()
            live_type = Endpoint.Endpoint{
                Parameter.Profile,Parameter.ParameterCommand,Parameter.Lifecycle,
                Parameter.ParameterPublisher,typeof(clock),
            }
            retained_completion = copy(transport.endpoint.completion.data)
            retained_payload = copy(source.bytes)
            Parameter.prepare_parameter_ndarrays!(
                runtime, live_type, Endpoint.Ticket{Parameter.ParameterCommand}, [source], wake, clock,
            )
            @test transport.endpoint.completion.data == retained_completion
            @test source.bytes == retained_payload
            @test source.phase == Parameter.IDLE && source.sequence == 0 && source.publication === nothing
            rejected = Runner.ParameterStream(output.node, output.node_serial, output.port, output.port_serial + UInt64(1))
            active = (; header = (; token = Int64(1)), deadline = Int64(time_ns()) + 15_000_000_000)
            @test_throws ArgumentError Parameter.receive_parameter!(runtime, endpoint, active, source, origin, rejected)
            Parameter.receive_parameter!(runtime, endpoint, active, source, origin, output)
            @test length(data) > Codec._MAX_REQUEST
            @test source.bytes == data
            expired = (; header = (; token = Int64(2)), deadline = Int64(time_ns()) + 300_000_000)
            # The one-shot producer intentionally has no frame for this Link.
            @test_throws ErrorException Parameter.receive_parameter!(runtime, endpoint, expired, source, origin, output)
            wait_proof(3, "withdrawal of expired parameter transfer") do
                with_thread_loop_lock(transport.loop) do _
                    for (interface, key) in (
                        ("PipeWire:Interface:Node", "node.name"), ("PipeWire:Interface:Link", "object.path"),
                    )
                        any(find_globals(registry; interface)) do object
                            startswith(get(object.properties, key, ""), "pipewireao.rtc.parameter-input.")
                        end && return false
                    end
                    return true
                end
            end
            @test source.bytes == data
        finally
            with_thread_loop_lock(sender_loop) do _
                for resource in (stream, controller, driver, core, context)
                    resource === nothing || close(resource)
                end
            end
            close(sender_loop)
            close(transport)
        end
    end
end
