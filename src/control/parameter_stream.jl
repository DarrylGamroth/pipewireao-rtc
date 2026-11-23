# A transfer Link belongs only to one admitted parameter request. It never
# connects the producer to a configured scientific graph or execution group.
function parameter_output(registry, controller, output::Runner.ParameterStream)
    client = parameter_controller(registry, controller)
    node = parameter_global(
        registry, output.node, output.node_serial, "PipeWire:Interface:Node",
    )
    port = parameter_global(
        registry, output.port, output.port_serial, "PipeWire:Interface:Port",
    )
    get(node.properties, "client.id", "") == string(client) &&
        get(port.properties, "node.id", "") == string(output.node) &&
        get(port.properties, "port.direction", "") == "out" ||
        throw(ArgumentError("parameter producer is not an output of the admitted controller client"))
    return nothing
end

function parameter_input_port(registry, stream)
    node = node_id(stream)
    node in (UInt32(0), typemax(UInt32)) && return nothing
    inputs = filter(find_globals(registry; interface = "PipeWire:Interface:Port")) do port
        get(port.properties, "node.id", "") == string(node) &&
            get(port.properties, "port.direction", "") == "in"
    end
    isempty(inputs) && return nothing
    length(inputs) == 1 || throw(ArgumentError("parameter input stream must have one port"))
    return only(inputs).id
end

parameter_input_links(registry, port) =
    filter(find_globals(registry; interface = "PipeWire:Interface:Link")) do link
        get(link.properties, "link.input.port", "") == string(port)
    end

function parameter_link(registry, link, name, output, node, input_port)
    links = parameter_input_links(registry, input_port)
    length(links) <= 1 || throw(ArgumentError("ambiguous parameter input Links"))
    isempty(links) && return false
    peer = only(links)
    peer.id == bound_id(link) &&
        get(peer.properties, "object.path", "") == name &&
        get(peer.properties, "link.output.node", "") == string(output.node) &&
        get(peer.properties, "link.output.port", "") == string(output.port) &&
        get(peer.properties, "link.input.node", "") == string(node) ||
        throw(ArgumentError("parameter input Link differs from the admitted producer"))
    return true
end

function verify_parameter_withdrawal!(runtime, endpoint, active, prefix)
    Endpoint.flush_terminal!(
        runtime.transport, active.deadline;
        check = () -> check_parameter_ticket(runtime, endpoint, active),
    )
    registry = something(endpoint.registry)
    with_thread_loop_lock(endpoint.loop) do _
        for (interface, key) in (
            ("PipeWire:Interface:Node", "node.name"), ("PipeWire:Interface:Link", "object.path"),
        )
            objects = find_globals(registry; interface)
            any(object -> startswith(get(object.properties, key, ""), prefix), objects) &&
                throw(ArgumentError("a prior parameter transfer is still present"))
        end
    end
    return nothing
end

function wait_parameter(f, runtime, endpoint, active)
    while true
        check_parameter_ticket(runtime, endpoint, active)
        result = with_thread_loop_lock(f, endpoint.loop)
        result === nothing || return result
        sleep(0.001)
    end
end

# Linux <linux/fcntl.h>. PipeWire's shared buffer allocator seals the backing
# MemFd against shrinking. A mapping must not outlive an unsealed extent.
const F_GET_SEALS = Cint(1034)
const F_SEAL_SHRINK = Cint(0x0002)

function map_parameter_payload(data, extent, stride)
    chunk = chunk_info(data)
    chunk.flags == 0 && chunk.size == extent &&
        chunk.offset <= capacity(data) - extent &&
        iszero(chunk.offset % sizeof(Float32)) && chunk.stride in (0, stride) ||
        throw(ArgumentError("parameter ndarray frame differs from its packed extent"))
    data_type(data) == SPA.DATA_MEM_FD ||
        throw(ArgumentError("parameter ndarray requires PipeWire MemFd buffers"))
    fd = data_fd(data)
    0 <= fd <= typemax(Cint) || throw(ArgumentError("invalid parameter buffer descriptor"))
    seals = ccall(:fcntl, Cint, (Cint, Cint), fd, F_GET_SEALS)
    seals >= 0 && seals & F_SEAL_SHRINK != 0 ||
        throw(ArgumentError("parameter ndarray buffer must be sealed against shrinking"))
    backing = stat(Base.RawFD(fd))
    isfile(backing) && Int64(data_map_offset(data)) + capacity(data) <= backing.size ||
        throw(ArgumentError("parameter ndarray exceeds its backing extent"))
    return map_data(data), Int(chunk.offset)
end

function copy_parameter_payload!(destination::Vector{UInt8}, mapping, offset::Int)
    input = PipeWireAO.bytes(mapping)
    extent = length(destination)
    extent % sizeof(Float32) == 0 && 0 <= offset <= length(input) - extent ||
        throw(ArgumentError("invalid packed parameter payload"))
    values = reinterpret(Float32, @view input[(offset + 1):(offset + extent)])
    slot = reinterpret(Float32, destination)
    finite = true
    # The target and source views have the same checked packed extent.
    @inbounds @simd for i in eachindex(values, slot)
        value = values[i]
        slot[i] = value
        finite &= isfinite(value)
    end
    finite || throw(ArgumentError("parameter ndarray frame contains a nonfinite value"))
    return nothing
end

function receive_parameter!(
    runtime, endpoint, active, source, controller, output::Runner.ParameterStream
)
    registry = something(endpoint.registry)
    core = runtime.transport.core
    failure = Ref{Union{Nothing,Exception}}(nothing)
    format_ready = Ref(false)
    buffer_generation = Ref(UInt64(0))
    input_buffers = Pod(buffers_param(
        buffers = 2, blocks = 1, size = length(source.bytes),
        data_types = 1 << Int(SPA.DATA_MEM_FD),
    ))
    buffer = StreamBuffer()
    stream = link = input_port = nothing
    prefix = "pipewireao.rtc.parameter-input.$(endpoint.instance)."
    name = prefix * string(active.header.token)
    # Fence any asynchronous teardown from an earlier expired request before
    # allocating or binding a new transfer, using this request's deadline.
    verify_parameter_withdrawal!(runtime, endpoint, active, prefix)
    try
        with_thread_loop_lock(endpoint.loop) do _
            parameter_output(registry, controller, output)
            stream = Stream(
                core, name;
                properties = Dict(
                    "node.name" => name, "node.virtual" => "true",
                    # The producer's isolated driver schedules this temporary Link.
                    "node.want-driver" => "false",
                    "media.type" => "Application", "media.category" => "Capture",
                    "object.linger" => "false",
                    "pipewireao.rtc.parameter-input" => "1",
                    "pipewireao.rtc.parameter-input.node-serial" => string(output.node_serial),
                    "pipewireao.rtc.parameter-input.port-serial" => string(output.port_serial),
                    "pipewireao.rtc.parameter-input.controller-serial" => string(controller.serial),
                ),
                on_process = _ -> nothing,
                on_buffer_removed = (_, _) -> (buffer_generation[] += 1; nothing),
                on_state_changed = (_, previous, current, message) -> begin
                    disconnected = current == PipeWireAO.LibPipeWire.PW_STREAM_STATE_UNCONNECTED &&
                        previous != current
                    if current == PipeWireAO.LibPipeWire.PW_STREAM_STATE_ERROR || disconnected
                        buffer_generation[] += 1
                        failure[] = ArgumentError(something(message, "parameter input disconnected"))
                    end
                    nothing
                end,
                on_param_changed = (receiver, id, pod) -> begin
                    id == SPA.PARAM_FORMAT || return nothing
                    buffer_generation[] += 1
                    format_ready[] = false
                    pod === nothing && return nothing
                    try
                        _validate_format(pod, source.format, source.schema)
                        update_params!(receiver, (input_buffers, last(source.parameters)))
                        format_ready[] = true
                    catch error
                        failure[] = error
                    end
                    nothing
                end,
            )
            connect!(
                stream, :input;
                flags = STREAM_DONT_RECONNECT | STREAM_NO_CONVERT,
                params = (
                    ndarray_format(
                        source.format; schema = isempty(source.schema) ? nothing : source.schema,
                    ),
                    input_buffers, last(source.parameters),
                ),
            )
        end
        input_port = wait_parameter(runtime, endpoint, active) do _
            failure[] === nothing || throw(failure[])
            parameter_output(registry, controller, output)
            return parameter_input_port(registry, stream)
        end
        with_thread_loop_lock(endpoint.loop) do _
            parameter_output(registry, controller, output)
            isempty(parameter_input_links(registry, input_port)) ||
                throw(ArgumentError("parameter input already has a Link"))
            link = create_object(
                core, "link-factory", PipeWireAO.Link;
                properties = Dict(
                    "link.output.node" => string(output.node), "link.output.port" => string(output.port),
                    "link.input.node" => string(node_id(stream)),
                    "link.input.port" => string(input_port),
                    "object.linger" => "false", "object.path" => name,
                ),
                on_error = (_, _, error) -> (failure[] = error; nothing),
            )
        end
        mapping, offset, generation = wait_parameter(runtime, endpoint, active) do _
            failure[] === nothing || throw(failure[])
            parameter_output(registry, controller, output)
            parameter_link(registry, link, name, output, node_id(stream), input_port) ||
                return nothing
            format_ready[] && dequeue_buffer!(buffer, stream) || return nothing
            try
                lease, position = map_parameter_payload(
                    buffer_data(buffer), length(source.bytes), source.stride,
                )
                return lease, position, buffer_generation[]
            catch
                queue_buffer!(buffer, stream)
                rethrow()
            end
        end
        valid = false
        try
            # PipeWire may revoke its buffer mapping while its loop is
            # unlocked. The independent MemFd mapping remains mapped until
            # we close it. Discard the copy if the native lease was revoked.
            copy_parameter_payload!(source.bytes, mapping, offset)
        finally
            try
                close(mapping)
            finally
                valid = with_thread_loop_lock(endpoint.loop) do _
                    current = buffer_generation[] == generation && failure[] === nothing
                    current && queue_buffer!(buffer, stream)
                    return current
                end
            end
        end
        valid || throw(ArgumentError("parameter ndarray buffer changed while copying"))
        check_parameter_ticket(runtime, endpoint, active)
        with_thread_loop_lock(endpoint.loop) do _
            parameter_output(registry, controller, output)
            parameter_link(registry, link, name, output, node_id(stream), input_port) ||
                throw(ArgumentError("parameter input Link disappeared during transfer"))
        end
    finally
        with_thread_loop_lock(endpoint.loop) do _
            try
                link === nothing || destroy_object!(core, link)
            finally
                stream === nothing || close(stream)
            end
        end
    end
    # The data-bearing Link is withdrawn before the ordinary parameter output
    # can publish. This barrier shares the admitted command deadline.
    verify_parameter_withdrawal!(runtime, endpoint, active, prefix)
    with_thread_loop_lock(endpoint.loop) do _
        parameter_controller(registry, controller)
    end
    check_parameter_ticket(runtime, endpoint, active)
    return nothing
end
