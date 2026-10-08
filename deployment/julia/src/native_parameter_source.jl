"""Cold parameter-only control and sparse ndarray output; WirePlumber owns session policy."""
module NativeParameterSource

using PipeWireAO
import ..Common
import ..NativeControlCodec
import ..NativeControlClient
import ..NativeControlEndpoint
import ..NativeRunnerCodec
import ..NativeOwnerBootstrapRuntime

const Envelope = NativeControlCodec
const Client = NativeControlClient
const Endpoint = NativeControlEndpoint
const Runner = NativeRunnerCodec
const Bootstrap = NativeOwnerBootstrapRuntime
const SPA = PipeWireAO.SPA
const MAX_BYTES = 512 * 1024 * 1024
const MAX_SOURCES = 32
const IDLE = UInt8(0)
const PENDING = UInt8(1)
const SUBMITTED = UInt8(2)

export Profile, PROFILE, Lifecycle, Preparing, Prepared, Connected, Fault, Stopped,
    Command, Completion, Rejection, run_owner, read_declarations

struct Profile <: Client.Profile end
const PROFILE = Profile()
@enum Lifecycle::UInt32 Preparing=1 Prepared=2 Connected=3 Fault=4 Stopped=5
const Command = Runner.RunnerCommand{:parameter}
Client.profile_name(::Profile) = "pipewireao.rtc.parameter-source/1"
Client.capability_names(::Profile) = Tuple("pipewireao.rtc.parameter-source." * name for name in
    ("version", "instance", "owner-pid", "lifecycle", "last-token", "controllers"))
Client.lifecycle_type(::Profile) = Lifecycle
Client.operation_id(::Profile, ::Command) = UInt32(14)
Client.encode_request(::Profile, header::Envelope.RequestHeader, command::Command) =
    Runner.encode_request(header, command)
function Client.decode_request(::Profile, header::Envelope.RequestHeader, payload::SPA.Struct)
    header.operation == 14 || throw(ArgumentError("parameter source accepts only operation 14"))
    return Runner.decode_request(header, payload)
end
function Client.decode_request(profile::Profile, input::Union{Pod,AbstractVector{UInt8}})
    header, payload = Envelope.decode_request(input)
    return header, Client.decode_request(profile, header, payload)
end

struct Completion
    header::Envelope.ReplyHeader
    graph::String
    inlet::String
    sequence::Int64
    submitted::Bool
    active_adoption_observed::Bool
    message::String
end
struct Rejection
    header::Envelope.ReplyHeader
    lifecycle::Lifecycle
    message::String
end
Client.completion_type(::Profile) = Completion
Client.rejection_type(::Profile) = Rejection
_struct(values::Pod...) = SPA.Struct(Pod[values...])
function _string(value; empty=false, maximum=8192)
    value isa AbstractString && isvalid(value) && ncodeunits(value) <= maximum &&
        (empty || !isempty(value)) && !occursin('\0', value) ||
        throw(ArgumentError("invalid or oversized parameter string"))
    return String(value)
end
_message(error) = replace(first(sprint(showerror, error), 2048), '\0' => '?')
function _scalar(pod, type, ::Type{T}) where T
    pod_type(pod) == type && sizeof(pod) == 8 + (T === Bool ? 4 : sizeof(T)) ||
        throw(ArgumentError("wrong parameter reply scalar type or width"))
    return pod_value(T, pod)
end
function _text(pod; empty=false, maximum=8192)
    pod_type(pod) == SPA.POD_STRING || throw(ArgumentError("expected parameter reply String"))
    return _string(pod_value(String, pod); empty, maximum)
end
function Client.encode_completion(::Profile, header::Envelope.ReplyHeader,
        graph::AbstractString, inlet::AbstractString, sequence::Int64,
        submitted::Bool, active::Bool, message::AbstractString)
    header.controller !== nothing && header.operation == 14 && header.result <= 0 ||
        throw(ArgumentError("invalid parameter completion header"))
    sequence >= 0 && (!submitted || sequence > 0) && !active ||
        throw(ArgumentError("parameter source cannot claim active adoption"))
    header.result != 0 || submitted || throw(ArgumentError("successful parameter completion requires submission"))
    return Envelope.encode_completion(header, _struct(Pod(_string(graph; maximum=16 * 1024)), Pod(_string(inlet; maximum=16 * 1024)),
        Pod(sequence), Pod(submitted), Pod(active), Pod(_string(message; empty=true))); endpoint=:lifecycle)
end
function Client.decode_completion(profile::Profile, input::Union{Pod,AbstractVector{UInt8}})
    header, payload = Envelope.decode_completion(input; endpoint=:lifecycle)
    length(payload.values) == 6 || throw(ArgumentError("wrong parameter completion arity"))
    graph, inlet, sequence, submitted, active, message = payload.values
    value = Completion(header, _text(graph; maximum=16 * 1024), _text(inlet; maximum=16 * 1024),
        _scalar(sequence, SPA.POD_LONG, Int64), _scalar(submitted, SPA.POD_BOOL, Bool),
        _scalar(active, SPA.POD_BOOL, Bool), _text(message; empty=true))
    Client.encode_completion(profile, header, value.graph, value.inlet, value.sequence,
        value.submitted, value.active_adoption_observed, value.message)
    return value
end
Client.encode_rejection(::Profile, header::Envelope.ReplyHeader, lifecycle::Lifecycle) =
    Envelope.encode_rejection(header, _struct(Pod(SPA.Id(UInt32(lifecycle))), Pod("request rejected")); endpoint=:lifecycle)
function Client.decode_rejection(::Profile, input::Union{Pod,AbstractVector{UInt8}})
    header, payload = Envelope.decode_rejection(input; endpoint=:lifecycle)
    length(payload.values) == 2 && header.result < 0 || throw(ArgumentError("invalid parameter rejection"))
    lifecycle = Lifecycle(_scalar(payload.values[1], SPA.POD_ID, SPA.Id).value)
    return Rejection(header, lifecycle, _text(payload.values[2]; empty=true))
end
function Client.encode_failure(profile::Profile, header::Envelope.ReplyHeader,
        ::Lifecycle, command::Command)
    graph, inlet = command.args[1:2]
    return Client.encode_completion(profile, header, graph, inlet, Int64(0), false, false,
        "request expired or controller removed")
end

"The exact applying ingress ticket that authorizes one requested publication."
struct Publication{E<:Endpoint.Endpoint,T<:Endpoint.Ticket}
    endpoint::E
    ticket::T
end

"One immutable declared mapping and one privately owned preallocated payload slot."
mutable struct Source
    node_name::String
    graph::String
    inlet::String
    shape::Vector{UInt32}
    schema::String
    format::NdArrayFormat
    bytes::Vector{UInt8}
    initial::Bool
    buffer::StreamBuffer
    stride::Int32
    phase::UInt8                 # ThreadLoop lock, including native callbacks
    initial_pending::Bool        # Explicit preload, which has no controller ticket
    publication::Union{Nothing,Publication}
    bootstrap::Union{Nothing,Bootstrap.Runtime}
    revoked::Union{Nothing,Exception}
    sequence::Int64
    failure::Union{Nothing,Exception}
    stream::Union{Nothing,Stream}
    parameters::Tuple{Pod,Pod}
    wake::Base.Event
end

"""Read saved JSON declarations, checking all mappings before opening any payload.

The root object has exactly `version=1` and `sources`. Each source declares
`node_name`, `graph`, `inlet`, `element_type="F32_LE"`, positive `shape`,
`layout` (`row-major` or `column-major`), `schema` (empty means absent), and
an optional absolute `initial_payload_path` (absent/null means no initial publication).
There are at most 32 mappings and their
aggregate packed extent is at most 512 MiB. Files contain raw packed wire bytes.
"""
function read_declarations(path::AbstractString, wake::Base.Event; check=()->nothing)
    Base.ENDIAN_BOM == 0x04030201 || throw(ArgumentError("parameter owner requires a little-endian host"))
    config = Common.read_json(path; maximum=1024 * 1024)
    config isa AbstractDict && Set(keys(config)) == Set(("version", "sources")) &&
        config["version"] === Int64(1) || throw(ArgumentError("invalid parameter source configuration"))
    rows = config["sources"]
    rows isa AbstractVector && 1 <= length(rows) <= MAX_SOURCES ||
        throw(ArgumentError("parameter source count must be between 1 and 32"))
    declarations = []
    mappings = Set{Tuple{String,String}}()
    names = Set{String}()
    total = 0
    fields = Set(("node_name", "graph", "inlet", "element_type", "shape", "layout", "schema"))
    for row in rows
        check()
        row isa AbstractDict && fields ⊆ Set(keys(row)) &&
            Set(keys(row)) ⊆ union(fields, Set(("initial_payload_path",))) ||
            throw(ArgumentError("invalid parameter declaration fields"))
        name = _string(row["node_name"]; maximum=128)
        occursin(r"^[a-zA-Z0-9_.-]+$", name) || throw(ArgumentError("invalid parameter node name"))
        graph, inlet = _string(row["graph"]; maximum=16 * 1024), _string(row["inlet"]; maximum=16 * 1024)
        row["element_type"] == "F32_LE" || throw(ArgumentError("parameter source supports only F32_LE"))
        dimensions = row["shape"]
        dimensions isa AbstractVector && 1 <= length(dimensions) <= 4096 &&
            all(x -> x isa Integer && !(x isa Bool) && 0 < x <= typemax(Int32), dimensions) ||
            throw(ArgumentError("invalid parameter shape"))
        shape = UInt32.(dimensions)
        extent = 4
        for dimension in shape
            extent = Base.checked_mul(extent, Int(dimension))
            extent <= MAX_BYTES || throw(ArgumentError("parameter payload exceeds 512 MiB"))
        end
        total = Base.checked_add(total, extent)
        total <= MAX_BYTES || throw(ArgumentError("aggregate parameter payload exceeds 512 MiB"))
        layout = row["layout"] == "row-major" ? NdArray.ROW_MAJOR :
            row["layout"] == "column-major" ? NdArray.COLUMN_MAJOR : throw(ArgumentError("invalid parameter layout"))
        schema = _string(row["schema"]; empty=true, maximum=16 * 1024)
        initial = get(row, "initial_payload_path", nothing)
        if initial !== nothing
            initial = _string(initial; maximum=16 * 1024)
            isabspath(initial) || throw(ArgumentError("initial parameter path must be absolute"))
        end
        name in names && throw(ArgumentError("duplicate parameter node name"))
        (graph, inlet) in mappings && throw(ArgumentError("duplicate parameter mapping"))
        push!(names, name); push!(mappings, (graph, inlet))
        format = NdArrayFormat(NdArray.F32_LE, shape; layout)
        push!(declarations, (; name, graph, inlet, shape, schema, initial, format, extent))
    end
    sources = Source[]
    for declaration in declarations
        check()
        bytes = Vector{UInt8}(undef, declaration.extent)
        declaration.initial === nothing || _read_payload!(bytes, declaration.initial; check)
        axis = declaration.format.layout == NdArray.ROW_MAJOR ? length(declaration.shape) : 1
        stride = Int32(4 * Int(declaration.shape[axis]))
        parameters = (Pod(buffers_param(buffers=2, blocks=1, size=length(bytes))), Pod(header_metadata_param()))
        push!(sources, Source(declaration.name, declaration.graph, declaration.inlet,
            declaration.shape, declaration.schema, declaration.format, bytes, declaration.initial !== nothing, StreamBuffer(),
            stride, IDLE, false, nothing, nothing, nothing, 0, nothing, nothing, parameters, wake))
    end
    return sources
end

"Read into an idle slot outside the PipeWire lock; reject symlink and inode/extent changes."
function _read_payload!(bytes::Vector{UInt8}, path::AbstractString; check)
    isabspath(path) || throw(ArgumentError("parameter payload path must be absolute"))
    check()
    before = lstat(path)
    isfile(before) && before.size == length(bytes) || throw(ArgumentError("parameter payload must be a regular file of the declared extent"))
    flags = Base.Filesystem.JL_O_RDONLY | Base.Filesystem.JL_O_NOFOLLOW | Base.Filesystem.JL_O_NONBLOCK
    file = Base.Filesystem.open(path, flags)
    try
        opened = stat(file)
        isfile(opened) && opened.device == before.device && opened.inode == before.inode &&
            opened.size == length(bytes) || throw(ArgumentError("parameter payload changed before open"))
        offset = 0
        while offset < length(bytes)
            check()
            count = min(1024 * 1024, length(bytes) - offset)
            read!(file, @view bytes[(offset + 1):(offset + count)])
            offset += count
        end
        after = stat(file)
        after.size == length(bytes) && after.mtime == opened.mtime && after.ctime == opened.ctime ||
            throw(ArgumentError("parameter payload changed while reading"))
        check()
    finally
        close(file)
    end
    return nothing
end

struct Process
    source::Source
end
"Check current owner and exact request authority at the publication boundary."
function _publication_valid!(source::Source)
    try
        runtime = something(source.bootstrap)
        Bootstrap.cancelled(runtime) && throw(InterruptException())
        bootstrap_endpoint = runtime.transport.endpoint
        Endpoint.operational(bootstrap_endpoint)
        retained = bootstrap_endpoint.retained_controller
        if retained === nothing
            # Initial buffers can arrive while Connect is still applying.
            pending = bootstrap_endpoint.pending
            pending !== nothing && bootstrap_endpoint.applying &&
                Client.operation_id(Bootstrap.Codec.PROFILE, pending.command) == UInt32(2) ||
                throw(ArgumentError("bootstrap Connect authority is unavailable"))
            Endpoint.check_ticket(bootstrap_endpoint, pending)
        else
            Endpoint.controller_present(bootstrap_endpoint, retained) ||
                throw(ArgumentError("retained bootstrap controller was revoked"))
        end
        if source.initial_pending
            source.publication === nothing ||
                throw(ArgumentError("initial parameter publication has a request ticket"))
        else
            authority = something(source.publication)
            Endpoint.check_ticket(authority.endpoint, authority.ticket)
        end
        Bootstrap.cancelled(runtime) && throw(InterruptException())
        return true
    catch error
        if source.initial_pending
            source.failure = error
        else
            source.revoked = error
        end
        source.phase = IDLE
        source.initial_pending = false
        source.publication = nothing
        notify(source.wake)
        return false
    end
end

"Queue a staged payload from the loop thread when an output buffer is available."
function _publish_pending!(source::Source, stream)
    source.phase == PENDING && source.failure === nothing || return nothing
    _publication_valid!(source) || return nothing
    try
        dequeue_buffer!(source.buffer, stream) || return nothing
        queued = false
        try
            data = buffer_data(source.buffer)
            capacity(data) >= length(source.bytes) || throw(ArgumentError("parameter buffer is too small"))
            chunk_info(data).flags == 0 || throw(ArgumentError("parameter buffer carries invalid chunk flags"))
            copyto!(buffer_memory(data, length(source.bytes)), source.bytes)
            set_chunk!(data; size=length(source.bytes), stride=source.stride)
            set_buffer_size!(source.buffer, length(source.bytes) ÷ 4)
            set_buffer_header!(source.buffer, BufferHeader(0, 0, 0, 0, UInt64(source.sequence)))
            _publication_valid!(source) || return nothing
            queue_buffer!(source.buffer, stream)
            queued = true
            source.phase = SUBMITTED
            source.initial_pending = false
        finally
            queued || return_buffer!(source.buffer, stream)
        end
    catch error
        source.failure = error
    end
    notify(source.wake)
    return nothing
end
(callback::Process)(stream) = _publish_pending!(callback.source, stream)

function _fixed_format(parameter::Pod)
    object = pod_value(SPA.Parameter, parameter).object
    properties = SPA.Property[]
    for property in object.properties
        value = property.value
        if pod_type(value) == SPA.POD_CHOICE
            # Fixation selects the default but can retain trailing alternatives.
            data = value.data
            length(data) >= 24 || throw(ArgumentError("truncated parameter format Choice"))
            words = reinterpret(UInt32, @view data[9:24])
            child_size = Int(words[3])
            extent = length(data) - 24
            words[1] == UInt32(SPA.CHOICE_NONE) && words[2] == 0 &&
                child_size > 0 && extent >= child_size && extent % child_size == 0 ||
                throw(ArgumentError("parameter format is not fixed"))
            value = Pod(copy(@view data[17:24+child_size]))
        end
        push!(properties, SPA.Property(property.key, value; flags=property.flags))
    end
    return SPA.Parameter(SPA.Object(object.type, object.id, properties))
end

function _connect_source!(source::Source, transport, runtime::Bootstrap.Runtime)
    source.bootstrap = runtime
    source.stream = Stream(transport.core, source.node_name;
        properties=Dict("node.name" => source.node_name, "media.type" => "Application",
            "media.category" => "Playback", "media.role" => "DSP", "node.virtual" => "true",
            "object.linger" => "false"),
        on_process=Process(source),
        on_buffer_added=(stream, _buffer) -> (_publish_pending!(source, stream); nothing),
        on_state_changed=(stream, old, current, message) -> begin
            if current == PipeWireAO.LibPipeWire.PW_STREAM_STATE_ERROR ||
                    (current == PipeWireAO.LibPipeWire.PW_STREAM_STATE_UNCONNECTED && old != current)
                source.failure = ErrorException(something(message, "parameter stream disconnected"))
            elseif current == PipeWireAO.LibPipeWire.PW_STREAM_STATE_STREAMING && source.phase == PENDING
                _publish_pending!(source, stream)
                if source.phase == PENDING && source.failure === nothing
                    try trigger_process!(stream) catch error; source.failure = error end
                end
            end
            notify(source.wake)
            nothing
        end,
        on_param_changed=(stream, id, parameter) -> begin
            id == SPA.PARAM_FORMAT && parameter !== nothing || return nothing
            try
                fixed = _fixed_format(parameter)
                format = NdArrayFormat(fixed)
                # An undeclared rate is unconstrained; the graph may fix its rate.
                # Sparse payload publication remains request driven.
                format.element_type == source.format.element_type && format.shape == source.format.shape &&
                    format.layout == source.format.layout &&
                    (source.format.rate === nothing || format.rate == source.format.rate) &&
                    something(ndarray_schema(fixed), "") == source.schema ||
                    throw(ArgumentError("negotiated parameter format differs from declaration: " *
                        "received $(repr((format.element_type, format.shape, format.layout, format.rate, ndarray_schema(fixed)))); " *
                        "expected $(repr((source.format.element_type, source.format.shape, source.format.layout, source.format.rate, source.schema)))"))
                update_params!(stream, source.parameters)
            catch error
                source.failure = error
            end
            notify(source.wake)
            nothing
        end)
    # Compile callbacks without executing payload copies or graph/science work.
    precompile(source.stream.callbacks.on_process, (typeof(source.stream),))
    precompile(source.stream.callbacks.on_param_changed, (typeof(source.stream), UInt32, Pod))
    source.sequence = source.initial ? 1 : 0
    source.initial_pending = source.initial
    source.publication = nothing
    source.revoked = nothing
    source.phase = source.initial ? PENDING : IDLE
    connect!(source.stream, :output;
        flags=STREAM_MAP_BUFFERS | STREAM_INACTIVE | STREAM_DONT_RECONNECT | STREAM_NO_CONVERT,
        params=(ndarray_format(source.format; schema=isempty(source.schema) ? nothing : source.schema), source.parameters...))
    # Ordinary sparse transport registration; no driver, links, or session decisions.
    set_active!(source.stream, true)
    return nothing
end

function _completion!(endpoint, ticket, source, result::Int32, message)
    graph, inlet = ticket.command.args[1:2]
    sequence, submitted = source === nothing ? (Int64(0), false) :
        (source.sequence, source.phase == SUBMITTED)
    header = Envelope.ReplyHeader(ticket.header.controller, endpoint.instance,
        ticket.header.token, ticket.header.operation, result)
    completion = Client.encode_completion(PROFILE, header, graph, inlet, sequence, submitted, false, message)
    Endpoint.complete!(endpoint, ticket, completion)
    return nothing
end

"""Run one ordinary owner; no links, graph state, science, or adoption decisions."""
function run_owner(options, runtime)
    transport = runtime.transport
    wake = Base.Event(true)
    endpoint = listener = timer = nothing
    sources = Source[]
    active = selected = nothing
    failures = Exception[]
    try
        sources = read_declarations(options.config, wake;
            check=() -> Bootstrap.preparation_check!(runtime))
        all(source -> source.node_name != options.control_node && source.node_name != options.bootstrap_node, sources) ||
            throw(ArgumentError("parameter data and control endpoint names must be distinct"))
        Bootstrap.prepared!(runtime)
        connect_ticket = Bootstrap.take_connect!(runtime)
        Bootstrap.connecting!(runtime, connect_ticket;
            ready=() -> with_thread_loop_lock(transport.loop) do _
                all(source -> source.stream !== nothing && source.failure === nothing &&
                    node_id(source.stream) ∉ (UInt32(0), typemax(UInt32)), sources) &&
                    endpoint !== nothing && node_id(something(endpoint.filter)) ∉ (UInt32(0), typemax(UInt32))
            end,
            quit=() -> notify(wake))
        Bootstrap.check_connect!(runtime, connect_ticket)
        with_thread_loop_lock(transport.loop) do _
            for source in sources
                _connect_source!(source, transport, runtime)
            end
            endpoint = Endpoint.Endpoint(PROFILE, Command, transport.loop, transport.core,
                options.control_node, options.control_instance, Connected;
                publisher=(filter, params) -> begin
                    update_params!(filter, params)
                    notify(wake)
                    nothing
                end)
            listener = add_listener!(something(endpoint.registry);
                on_global_added=(registry, object) -> (notify(wake); nothing),
                on_global_removed=(registry, id) -> (notify(wake); nothing))
        end
        Bootstrap.await_connected!(runtime, connect_ticket)
        while true
            Bootstrap.preparation_check!(runtime)
            with_thread_loop_lock(transport.loop) do _
                for source in sources
                    source.failure === nothing || throw(source.failure)
                    if source.phase == SUBMITTED && source !== selected
                        source.phase = IDLE
                        source.publication = nothing
                        source.revoked = nothing
                    end
                end
            end
            Endpoint.poll!(endpoint)
            if active === nothing
                active = Endpoint.take!(endpoint)
                if active !== nothing
                    selected = nothing
                    timer = Timer(max(0.000001, active.deadline - Client.monotonic())) do _
                        notify(wake)
                    end
                    staged = false
                    try
                        graph, inlet, element_type, shape, schema, path = active.command.args
                        index = findfirst(source -> source.graph == graph && source.inlet == inlet, sources)
                        index === nothing && throw(ArgumentError("no declared parameter mapping"))
                        selected = sources[index]
                        element_type == "F32_LE" && shape == selected.shape && schema == selected.schema ||
                            throw(ArgumentError("parameter request differs from declared type, shape, or schema"))
                        with_thread_loop_lock(transport.loop) do _
                            selected.phase == IDLE || throw(ArgumentError("parameter publication already pending"))
                        end
                        _read_payload!(selected.bytes, path;
                            check=() -> begin
                                Bootstrap.preparation_check!(runtime)
                                Endpoint.check_ticket(endpoint, active)
                            end)
                        with_thread_loop_lock(transport.loop) do _
                            Endpoint.check_ticket(endpoint, active)
                            selected.sequence < typemax(Int64) || throw(ArgumentError("parameter sequence exhausted"))
                            selected.sequence += 1
                            selected.initial_pending = false
                            selected.publication = Publication(endpoint, active)
                            selected.revoked = nothing
                            selected.phase = PENDING
                            staged = true
                            stream = something(selected.stream)
                            # A paused stream has no process callback. Queue an
                            # available output buffer now; callbacks retry later.
                            _publish_pending!(selected, stream)
                            selected.failure === nothing || throw(selected.failure)
                            selected.revoked === nothing || throw(selected.revoked)
                            if selected.phase == PENDING && selected.failure === nothing &&
                                    stream_state(stream) == PipeWireAO.LibPipeWire.PW_STREAM_STATE_STREAMING
                                trigger_process!(stream)
                            end
                        end
                    catch error
                        with_thread_loop_lock(transport.loop) do _
                            if staged && selected.phase == PENDING
                                selected.phase = IDLE
                                selected.publication = nothing
                            end
                            expired_or_revoked = (selected !== nothing && selected.revoked !== nothing) ||
                                Client.monotonic() >= active.deadline
                            result = expired_or_revoked ? Int32(-110) : Int32(-22)
                            _completion!(endpoint, active, staged ? selected : nothing, result, _message(error))
                        end
                        close(timer); timer = nothing
                        active = selected = nothing
                    end
                end
            end
            if active !== nothing
                with_thread_loop_lock(transport.loop) do _
                    result = Int32(0)
                    message = ""
                    if selected.revoked !== nothing
                        result = Int32(-110)
                        message = _message(selected.revoked)
                    else
                        try Endpoint.check_ticket(endpoint, active) catch error
                            result = Int32(-110)
                            message = _message(error)
                        end
                    end
                    if result < 0 || selected.phase == SUBMITTED
                        _completion!(endpoint, active, selected, result, message)
                        selected.phase = IDLE
                        selected.publication = nothing
                        selected.revoked = nothing
                        close(timer); timer = nothing
                        active = selected = nothing
                    end
                end
            end
            wait(wake)
        end
    catch error
        push!(failures, error)
    finally
        try Bootstrap.finishing!(runtime) catch error; push!(failures, error) end
        try timer === nothing || close(timer) catch error; push!(failures, error) end
        try
            with_thread_loop_lock(transport.loop) do _
                # Exclude callbacks before releasing slots; teardown never applies a pending payload.
                for source in sources
                    source.phase = IDLE
                    source.publication = nothing
                    source.initial_pending = false
                    try source.stream === nothing || close(source.stream) catch error; push!(failures, error) end
                end
                for resource in (listener, endpoint)
                    try resource === nothing || close(resource) catch error; push!(failures, error) end
                end
            end
        catch error
            push!(failures, error)
        end
    end
    isempty(failures) || throw(length(failures) == 1 ? only(failures) : CompositeException(failures))
    return nothing
end

end # module NativeParameterSource
