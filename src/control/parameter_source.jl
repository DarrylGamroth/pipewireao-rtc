"""Cold parameter control and sparse ndarray publication; RTC owns session policy."""
module ParameterSource

using PipeWireAO
using SHA
using PrecompileTools: @compile_workload
import Clocks
import Hsm
import ..Common
import ..Artifacts
import ..ControlCodec
import ..ControlClient
import ..ControlEndpoint
import ..RunnerCodec
import ..OwnerBootstrapRuntime

export Profile,
    PROFILE,
    Lifecycle,
    Preparing,
    Prepared,
    Connected,
    Fault,
    Stopped,
    Command,
    Completion,
    Rejection,
    run_owner,
    read_declarations,
    main

const Envelope = ControlCodec
const Client = ControlClient
const Endpoint = ControlEndpoint
const Runner = RunnerCodec
const Bootstrap = OwnerBootstrapRuntime
const SPA = PipeWireAO.SPA
const MAX_BYTES = 512 * 1024 * 1024
const MAX_SOURCES = 32
const IDLE = UInt8(0)
const PENDING = UInt8(1)
const SUBMITTED = UInt8(2)

"""Native `pipewireao.rtc.parameter-source/1` control profile."""
struct Profile <: Client.AbstractProfile end
"""Shared stateless parameter-source control profile instance."""
const PROFILE = Profile()
"""Parameter-source bootstrap states, encoded as native UInt32 identifiers."""
@enum Lifecycle::UInt32 Preparing = 1 Prepared = 2 Connected = 3 Fault = 4 Stopped = 5
@doc "The parameter source is loading and validating its cold declarations." Preparing
@doc "The parameter source is prepared and awaits owner connection." Prepared
@doc "The parameter source has completed its owner connection." Connected
@doc "The parameter source has failed; successful submission cannot be assumed." Fault
@doc "The parameter source has stopped." Stopped
"""Released path-based parameter command."""
const Command = Runner.RunnerCommand{:parameter}

"The admitted session request and original native controller forwarded by the RTC."
struct NdArrayParameter{P<:Runner.ParameterNdArray}
    graph::String
    inlet::String
    parameter::P
    controller::Envelope.ControllerIdentity
end

const ParameterCommand = Union{Command,NdArrayParameter}
const Arguments = Tuple{String,String,String,Vector{UInt32},String,String}
Client.profile_name(::Profile) = "pipewireao.rtc.parameter-source/1"
Client.capability_names(::Profile) = Tuple(
    "pipewireao.rtc.parameter-source." * name for name in
    ("version", "instance", "owner-pid", "lifecycle", "last-token", "controllers")
)
Client.lifecycle_type(::Profile) = Lifecycle
Client.operation_id(::Profile, ::Command) = UInt32(14)
Client.operation_id(::Profile, ::NdArrayParameter) = Runner.PARAMETER_NDARRAY_OPERATION
Client.encode_request(::Profile, header::Envelope.RequestHeader, command::Command) =
    Runner.encode_request(header, command)
function Client.encode_request(
    profile::Profile, header::Envelope.RequestHeader, command::NdArrayParameter
)
    base = Runner.RunnerCommand(:parameter_ndarray, command.graph, command.inlet, command.parameter)
    header.operation == Client.operation_id(profile, command) ||
        throw(ArgumentError("parameter owner operation differs from command"))
    Runner._preflight_request(base, sizeof(Envelope.encode_request(header, _struct())))
    fields = Runner._request_fields(base, base.args).values
    controller = command.controller
    push!(fields, Pod(_struct(
        Pod(SPA.Id(controller.global_id)), Pod(reinterpret(Int64, controller.serial)),
        Pod(controller.instance),
    )))
    return Envelope.encode_request(header, SPA.Struct(fields))
end
function Client.decode_request(
    ::Profile, header::Envelope.RequestHeader, payload::SPA.Struct
)
    header.operation == 14 && return Runner.decode_request(header, payload)
    header.operation == Runner.PARAMETER_NDARRAY_OPERATION && length(payload.values) == 5 ||
        throw(ArgumentError("unknown parameter owner request"))
    base = Runner.decode_request(header, SPA.Struct(payload.values[1:4]))
    identity = Runner._arity(Runner._fields(payload.values[5]), 3)
    controller = Envelope.ControllerIdentity(
        Runner._id(identity[1]), reinterpret(UInt64, Runner._long(identity[2])),
        Runner._long(identity[3]),
    )
    return NdArrayParameter(base.args..., controller)
end
function Client.decode_request(profile::Profile, input::Union{Pod,AbstractVector{UInt8}})
    header, payload = Envelope.decode_request(input)
    return header, Client.decode_request(profile, header, payload)
end

"""Correlated parameter-submission reply.

`sequence` identifies submission to the named graph inlet. `submitted` records
transport submission; this source cannot establish active graph adoption, so
`active_adoption_observed` is always false for a valid encoded reply.
"""
struct Completion
    header::Envelope.ReplyHeader
    graph::String
    inlet::String
    sequence::Int64
    submitted::Bool
    active_adoption_observed::Bool
    message::String
end
"""Rejected parameter request with its correlation header, lifecycle and reason."""
struct Rejection
    header::Envelope.ReplyHeader
    lifecycle::Lifecycle
    message::String
end
Client.completion_type(::Profile) = Completion
Client.rejection_type(::Profile) = Rejection
_struct(values::Pod...) = SPA.Struct(Pod[values...])
_string(value; empty = false, maximum = 8192) =
    throw(ArgumentError("invalid or oversized parameter string"))
function _string(value::AbstractString; empty = false, maximum = 8192)
    isvalid(value) &&
    ncodeunits(value) <= maximum &&
    (empty || !isempty(value)) &&
    !occursin('\0', value) || throw(ArgumentError("invalid or oversized parameter string"))
    return String(value)
end
_message(error) = replace(first(sprint(showerror, error), 2048), '\0' => '?')
function _scalar(pod, type, ::Type{T}) where {T}
    pod_type(pod) == type && sizeof(pod) == 8 + (T === Bool ? 4 : sizeof(T)) ||
        throw(ArgumentError("wrong parameter reply scalar type or width"))
    return pod_value(T, pod)
end
function _text(pod; empty = false, maximum = 8192)
    pod_type(pod) == SPA.POD_STRING ||
        throw(ArgumentError("expected parameter reply String"))
    return _string(pod_value(String, pod); empty, maximum)
end
function Client.encode_completion(
    ::Profile,
    header::Envelope.ReplyHeader,
    graph::AbstractString,
    inlet::AbstractString,
    sequence::Int64,
    submitted::Bool,
    active::Bool,
    message::AbstractString,
)
    header.controller !== nothing &&
        header.operation in (14, Runner.PARAMETER_NDARRAY_OPERATION) && header.result <= 0 ||
        throw(ArgumentError("invalid parameter completion header"))
    sequence >= 0 && (!submitted || sequence > 0) && !active ||
        throw(ArgumentError("parameter source cannot claim active adoption"))
    header.result != 0 ||
        submitted ||
        throw(ArgumentError("successful parameter completion requires submission"))
    return Envelope.encode_completion(
        header,
        _struct(
            Pod(_string(graph; maximum = 16 * 1024)),
            Pod(_string(inlet; maximum = 16 * 1024)),
            Pod(sequence),
            Pod(submitted),
            Pod(active),
            Pod(_string(message; empty = true)),
        );
        endpoint = :lifecycle,
    )
end
function Client.decode_completion(profile::Profile, input::Union{Pod,AbstractVector{UInt8}})
    header, payload = Envelope.decode_completion(input; endpoint = :lifecycle)
    length(payload.values) == 6 || throw(ArgumentError("wrong parameter completion arity"))
    graph, inlet, sequence, submitted, active, message = payload.values
    value = Completion(
        header,
        _text(graph; maximum = 16 * 1024),
        _text(inlet; maximum = 16 * 1024),
        _scalar(sequence, SPA.POD_LONG, Int64),
        _scalar(submitted, SPA.POD_BOOL, Bool),
        _scalar(active, SPA.POD_BOOL, Bool),
        _text(message; empty = true),
    )
    Client.encode_completion(
        profile,
        header,
        value.graph,
        value.inlet,
        value.sequence,
        value.submitted,
        value.active_adoption_observed,
        value.message,
    )
    return value
end
Client.encode_rejection(::Profile, header::Envelope.ReplyHeader, lifecycle::Lifecycle) =
    Envelope.encode_rejection(
        header,
        _struct(Pod(SPA.Id(UInt32(lifecycle))), Pod("request rejected"));
        endpoint = :lifecycle,
    )
function Client.decode_rejection(::Profile, input::Union{Pod,AbstractVector{UInt8}})
    header, payload = Envelope.decode_rejection(input; endpoint = :lifecycle)
    length(payload.values) == 2 && header.result < 0 ||
        throw(ArgumentError("invalid parameter rejection"))
    lifecycle = Lifecycle(_scalar(payload.values[1], SPA.POD_ID, SPA.Id).value)
    return Rejection(header, lifecycle, _text(payload.values[2]; empty = true))
end
function Client.encode_failure(
    profile::Profile, header::Envelope.ReplyHeader, ::Lifecycle, command::ParameterCommand
)
    graph, inlet = parameter_address(command)
    return Client.encode_completion(
        profile,
        header,
        graph,
        inlet,
        Int64(0),
        false,
        false,
        "request expired or controller removed",
    )
end

parameter_address(command::Command) = command.args[1:2]
parameter_address(command::NdArrayParameter) = (command.graph, command.inlet)

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
    initial_provenance::Union{Nothing,Dict{String,Any}}
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

_declaration_config(config) = throw(ArgumentError("invalid parameter source configuration"))
function _declaration_config(config::AbstractDict)
    Set(keys(config)) == Set(("version", "sources")) ||
        throw(ArgumentError("invalid parameter source configuration"))
    _declaration_version(config["version"])
    return nothing
end
_declaration_version(version) =
    throw(ArgumentError("invalid parameter source configuration"))
_declaration_version(version::Int64) =
    version in (1, 2) || throw(ArgumentError("invalid parameter source configuration"))
_declaration_rows(rows) =
    throw(ArgumentError("parameter source count must be between 1 and 32"))
_declaration_rows(rows::AbstractVector) =
    1 <= length(rows) <= MAX_SOURCES ||
    throw(ArgumentError("parameter source count must be between 1 and 32"))
_declaration_fields(row, fields, fits_initial) =
    throw(ArgumentError("invalid parameter declaration fields"))
_declaration_fields(row::AbstractDict, fields, fits_initial) =
    fields ⊆ Set(keys(row)) &&
    Set(keys(row)) ⊆
    union(fields, Set((fits_initial ? "initial_artifact" : "initial_payload_path",))) ||
    throw(ArgumentError("invalid parameter declaration fields"))
_declaration_shape(dimensions) = throw(ArgumentError("invalid parameter shape"))
function _declaration_shape(dimensions::AbstractVector)
    1 <= length(dimensions) <= 4096 || throw(ArgumentError("invalid parameter shape"))
    foreach(_declaration_dimension, dimensions)
    return nothing
end
_declaration_dimension(value) = throw(ArgumentError("invalid parameter shape"))
_declaration_dimension(::Bool) = throw(ArgumentError("invalid parameter shape"))
_declaration_dimension(value::Integer) =
    0 < value <= typemax(Int32) || throw(ArgumentError("invalid parameter shape"))
_initial_selection(value) = throw(ArgumentError("invalid initial FITS artifact selection"))
_initial_selection(value::AbstractDict) =
    haskey(value, "path") && Set(keys(value)) ⊆ Set(("path", "hdu", "axes")) ||
    throw(ArgumentError("invalid initial FITS artifact selection"))
function _initial_payload(initial::Artifacts.FITSArtifact, declaration; check)
    prepared = Artifacts.prepare(initial, Float32, declaration.shape; check)
    # Sparse publication copies privately owned bytes. FITS decoding and layout
    # conversion remain outside the PipeWire lock/callback.
    bytes =
        declaration.format.layout == NdArray.ROW_MAJOR ? Artifacts.pack(prepared; check) :
        copy(reinterpret(UInt8, vec(prepared.data)))
    return bytes, prepared.provenance
end
function _initial_payload(initial::Union{Nothing,AbstractString}, declaration; check)
    bytes = Vector{UInt8}(undef, declaration.extent)
    initial === nothing || _read_payload!(bytes, initial; check)
    return bytes, nothing
end

"""
    read_declarations(path, wake; check=()->nothing)

Read saved JSON declarations, checking all mappings before opening any artifact.

The root object has exactly `version=1` and `sources`. Each source declares
`node_name`, `graph`, `inlet`, `element_type="F32_LE"`, positive `shape`,
`layout` (`row-major` or `column-major`), `schema` (empty means absent), and
an optional absolute `initial_payload_path` (absent/null means no initial publication).
There are at most 32 mappings and their
aggregate packed extent is at most 512 MiB. Files contain raw packed wire bytes.

Version 2 instead accepts optional `initial_artifact` with `path`, `hdu` and
`axes`. Paths resolve relative to this configuration. Multidimensional images
require explicit axes. These FITS files are decoded into owned memory before
publication; no packed files are written. Legacy version 1 and native v1 live
requests retain their raw-file semantics. A FITS preload is not a live update.
"""
function read_declarations(path::AbstractString, wake::Base.Event; check = () -> nothing)
    Base.ENDIAN_BOM == 0x04030201 ||
        throw(ArgumentError("parameter owner requires a little-endian host"))
    config = Common.read_json(path; maximum = 1024 * 1024)
    _declaration_config(config)
    fits_initial = config["version"] == 2
    rows = config["sources"]
    _declaration_rows(rows)
    declarations = []
    mappings = Set{Tuple{String,String}}()
    names = Set{String}()
    total = 0
    fields = Set((
        "node_name", "graph", "inlet", "element_type", "shape", "layout", "schema"
    ))
    for row in rows
        check()
        _declaration_fields(row, fields, fits_initial)
        name = _string(row["node_name"]; maximum = 128)
        occursin(r"^[a-zA-Z0-9_.-]+$", name) ||
            throw(ArgumentError("invalid parameter node name"))
        graph, inlet = _string(row["graph"]; maximum = 16 * 1024),
        _string(row["inlet"]; maximum = 16 * 1024)
        row["element_type"] == "F32_LE" ||
            throw(ArgumentError("parameter source supports only F32_LE"))
        dimensions = row["shape"]
        _declaration_shape(dimensions)
        shape = UInt32.(dimensions)
        extent = 4
        for dimension in shape
            extent = Base.checked_mul(extent, Int(dimension))
            extent <= MAX_BYTES || throw(ArgumentError("parameter payload exceeds 512 MiB"))
        end
        total = Base.checked_add(total, extent)
        total <= MAX_BYTES ||
            throw(ArgumentError("aggregate parameter payload exceeds 512 MiB"))
        layout = if row["layout"] == "row-major"
            NdArray.ROW_MAJOR
        elseif row["layout"] == "column-major"
            NdArray.COLUMN_MAJOR
        else
            throw(ArgumentError("invalid parameter layout"))
        end
        schema = _string(row["schema"]; empty = true, maximum = 16 * 1024)
        initial = get(
            row, fits_initial ? "initial_artifact" : "initial_payload_path", nothing
        )
        if initial !== nothing
            if fits_initial
                _initial_selection(initial)
                artifact_path = _string(initial["path"]; maximum = 16 * 1024)
                initial = Artifacts.FITSArtifact(
                    joinpath(dirname(abspath(path)), artifact_path);
                    hdu = get(initial, "hdu", 1),
                    axes = get(initial, "axes", nothing),
                )
                length(shape) == 1 ||
                    initial.axes !== nothing ||
                    throw(
                        ArgumentError(
                            "multidimensional FITS artifacts require explicit axes"
                        ),
                    )
                initial.axes === nothing ||
                    length(initial.axes) == length(shape) ||
                    throw(ArgumentError("FITS axes rank differs from parameter shape"))
                extent <= Artifacts.MAX_IMAGE_BYTES ||
                    throw(ArgumentError("initial FITS parameter exceeds 256 MiB"))
            else
                initial = _string(initial; maximum = 16 * 1024)
                isabspath(initial) ||
                    throw(ArgumentError("initial parameter path must be absolute"))
            end
        end
        name in names && throw(ArgumentError("duplicate parameter node name"))
        (graph, inlet) in mappings && throw(ArgumentError("duplicate parameter mapping"))
        push!(names, name)
        push!(mappings, (graph, inlet))
        format = NdArrayFormat(NdArray.F32_LE, shape; layout)
        push!(declarations, (; name, graph, inlet, shape, schema, initial, format, extent))
    end
    sources = Source[]
    for declaration in declarations
        check()
        bytes, provenance = _initial_payload(declaration.initial, declaration; check)
        if provenance !== nothing
            provenance["publication_storage_order"] =
                declaration.format.layout == NdArray.ROW_MAJOR ? "row-major" :
                "column-major"
            provenance["publication_sha256"] = bytes2hex(SHA.sha256(bytes))
        end
        check()
        axis =
            declaration.format.layout == NdArray.ROW_MAJOR ? length(declaration.shape) : 1
        stride = Int32(4 * Int(declaration.shape[axis]))
        parameters = (
            Pod(buffers_param(buffers = 2, blocks = 1, size = length(bytes))),
            Pod(header_metadata_param()),
        )
        push!(
            sources,
            Source(
                declaration.name,
                declaration.graph,
                declaration.inlet,
                declaration.shape,
                declaration.schema,
                declaration.format,
                bytes,
                declaration.initial !== nothing,
                provenance,
                StreamBuffer(),
                stride,
                IDLE,
                false,
                nothing,
                nothing,
                nothing,
                0,
                nothing,
                nothing,
                parameters,
                wake,
            ),
        )
    end
    return sources
end

"Read into an idle slot outside the PipeWire lock; reject symlink and inode/extent changes."
function _read_payload!(bytes::Vector{UInt8}, path::AbstractString; check)
    isabspath(path) || throw(ArgumentError("parameter payload path must be absolute"))
    check()
    before = lstat(path)
    isfile(before) && before.size == length(bytes) || throw(
        ArgumentError("parameter payload must be a regular file of the declared extent")
    )
    flags =
        Base.Filesystem.JL_O_RDONLY | Base.Filesystem.JL_O_NOFOLLOW |
        Base.Filesystem.JL_O_NONBLOCK
    file = Base.Filesystem.open(path, flags)
    try
        opened = stat(file)
        isfile(opened) &&
        opened.device == before.device &&
        opened.inode == before.inode &&
        opened.size == length(bytes) ||
            throw(ArgumentError("parameter payload changed before open"))
        offset = 0
        while offset < length(bytes)
            check()
            count = min(1024 * 1024, length(bytes) - offset)
            read!(file, @view bytes[(offset+1):(offset+count)])
            offset += count
        end
        after = stat(file)
        after.size == length(bytes) &&
        after.mtime == opened.mtime &&
        after.ctime == opened.ctime ||
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
            pending !== nothing &&
            bootstrap_endpoint.applying &&
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
            command = authority.ticket.command
            if command isa NdArrayParameter
                parameter_controller(something(authority.endpoint.registry), command.controller)
            end
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
            capacity(data) >= length(source.bytes) ||
                throw(ArgumentError("parameter buffer is too small"))
            chunk_info(data).flags == 0 ||
                throw(ArgumentError("parameter buffer carries invalid chunk flags"))
            copyto!(buffer_memory(data, length(source.bytes)), source.bytes)
            set_chunk!(data; size = length(source.bytes), stride = source.stride)
            set_buffer_size!(source.buffer, length(source.bytes) ÷ 4)
            set_buffer_header!(
                source.buffer, BufferHeader(0, 0, 0, 0, UInt64(source.sequence))
            )
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

function _validate_format(parameter::Pod, declared::NdArrayFormat, schema::String)
    format = NdArrayFormat(
        parameter; expected_rank = length(declared.shape), require_fixed = true
    )
    received_schema = ndarray_schema(parameter)
    # An undeclared rate is unconstrained. Sparse publication remains request driven.
    format.element_type == declared.element_type &&
    format.shape == declared.shape &&
    format.layout == declared.layout &&
    (declared.rate === nothing || format.rate == declared.rate) &&
    something(received_schema, "") == schema || throw(
        ArgumentError(
            "negotiated parameter format differs from declaration: " *
            "received $(repr((format.element_type, format.shape, format.layout, format.rate, received_schema))); " *
            "expected $(repr((declared.element_type, declared.shape, declared.layout, declared.rate, schema)))",
        ),
    )
    return nothing
end

function _prepare_source!(source::Source, transport, runtime::Bootstrap.Runtime)
    source.bootstrap = runtime
    source.stream = Stream(
        transport.core,
        source.node_name;
        properties = Dict(
            "node.name" => source.node_name,
            "media.type" => "Application",
            "media.category" => "Playback",
            "media.role" => "DSP",
            "node.virtual" => "true",
            "pipewireao.header.pts.clock" => "unavailable",
            "object.linger" => "false",
        ),
        on_process = Process(source),
        on_buffer_added = (stream, _buffer) -> (_publish_pending!(source, stream); nothing),
        on_state_changed = (stream, old, current, message) -> begin
            if current == PipeWireAO.LibPipeWire.PW_STREAM_STATE_ERROR || (
                current == PipeWireAO.LibPipeWire.PW_STREAM_STATE_UNCONNECTED &&
                old != current
            )
                source.failure = ErrorException(
                    something(message, "parameter stream disconnected")
                )
            elseif current == PipeWireAO.LibPipeWire.PW_STREAM_STATE_STREAMING &&
                source.phase == PENDING
                _publish_pending!(source, stream)
                if source.phase == PENDING && source.failure === nothing
                    try
                        trigger_process!(stream)
                    catch error
                        source.failure = error
                    end
                end
            end
            notify(source.wake)
            nothing
        end,
        on_param_changed = (stream, id, parameter) -> begin
            id == SPA.PARAM_FORMAT && parameter !== nothing || return nothing
            try
                _validate_format(parameter, source.format, source.schema)
                update_params!(stream, source.parameters)
            catch error
                source.failure = error
            end
            notify(source.wake)
            nothing
        end,
    )
    # Compile callbacks without executing payload copies or graph/science work.
    precompile(source.stream.callbacks.on_process, (typeof(source.stream),))
    precompile(
        source.stream.callbacks.on_param_changed, (typeof(source.stream), UInt32, Pod)
    )
    source.sequence = source.initial ? 1 : 0
    source.initial_pending = source.initial
    source.publication = nothing
    source.revoked = nothing
    source.phase = source.initial ? PENDING : IDLE
    connect!(
        source.stream,
        :output;
        flags = STREAM_MAP_BUFFERS | STREAM_INACTIVE | STREAM_DONT_RECONNECT |
                STREAM_NO_CONVERT,
        params = (
            ndarray_format(
                source.format; schema = isempty(source.schema) ? nothing : source.schema
            ),
            source.parameters...,
        ),
    )
    return nothing
end

struct ParameterPublisher
    wake::Base.Event
    enabled::Bool
end

const ParameterEndpoint{C} = Endpoint.Endpoint{Profile,ParameterCommand,Lifecycle,ParameterPublisher,C}
const ParameterTicket = Endpoint.Ticket{ParameterCommand}

function (publisher::ParameterPublisher)(filter, params)
    if publisher.enabled
        update_params!(filter, params)
        notify(publisher.wake)
    end
    return nothing
end

function _control_endpoint(options, transport, clock, wake)
    return Endpoint.Endpoint(
        PROFILE,
        ParameterCommand,
        transport.loop,
        transport.core,
        options.control_node,
        options.control_instance,
        Connected;
        clock,
        publisher = ParameterPublisher(wake, true),
    )
end

parameter_timer(loop, wake) = TimerSource(loop, (_, _) -> notify(wake))

function precompile_parameter_timer!(timer_type)
    for delay in (Float64, Nothing)
        precompile(
            Core.kwcall,
            (NamedTuple{(:delay,),Tuple{delay}}, typeof(update_timer!), timer_type),
        )
    end
    precompile(close, (timer_type,))
    return nothing
end

function _completion!(endpoint, ticket, source, result::Int32, message)
    graph, inlet = parameter_address(ticket.command)
    sequence, submitted =
        source === nothing ? (Int64(0), false) :
        (source.sequence, source.phase == SUBMITTED)
    header = Envelope.ReplyHeader(
        ticket.header.controller,
        endpoint.instance,
        ticket.header.token,
        ticket.header.operation,
        result,
    )
    completion = Client.encode_completion(
        PROFILE, header, graph, inlet, sequence, submitted, false, message
    )
    previous = endpoint.completion
    try
        Endpoint.complete!(endpoint, ticket, completion)
    catch error
        # The exact ticket may expire after the caller's check but before
        # Completed rechecks it. Preserve the actual submitted state and
        # report a negative completion rather than losing the parameter owner.
        result == 0 && endpoint.pending === ticket && endpoint.completion === previous &&
            error isa ErrorException && error.msg in (
                "native owner request deadline expired", "native controller disappeared",
            ) || rethrow()
        return _completion!(endpoint, ticket, source, Int32(-Base.Libc.ETIMEDOUT), _message(error))
    end
    return nothing
end

function check_parameter_ticket(runtime, endpoint, active)
    Bootstrap.preparation_check!(runtime)
    Endpoint.check_ticket(endpoint, active)
    return nothing
end

function read_parameter!(runtime, endpoint, active, source, command::Command, _)
    _, _, element_type, shape, schema, path = command.args::Arguments
    element_type == "F32_LE" && shape == source.shape && schema == source.schema ||
        throw(ArgumentError("parameter request differs from declared type, shape, or schema"))
    _read_payload!(
        source.bytes, path; check = () -> check_parameter_ticket(runtime, endpoint, active),
    )
    return nothing
end

function read_parameter!(
    runtime, endpoint, active, source, command::NdArrayParameter, session_controller
)
    active.header.controller == session_controller ||
        throw(ArgumentError("parameter ndarray requires the admitted session controller"))
    parameter = command.parameter
    parameter.format.element_type == source.format.element_type &&
        parameter.format.shape == source.format.shape &&
        parameter.format.layout == source.format.layout &&
        something(parameter.schema, "") == source.schema ||
        throw(ArgumentError("parameter ndarray differs from its declared format"))
    receive_parameter!(runtime, endpoint, active, source, command.controller, parameter.data)
    return nothing
end

function receive_parameter!(runtime, endpoint, active, source, controller, data::Vector{Float32})
    with_thread_loop_lock(endpoint.loop) do _
        parameter_controller(endpoint.registry, controller)
    end
    check_parameter_ticket(runtime, endpoint, active)
    copyto!(source.bytes, reinterpret(UInt8, data))
    check_parameter_ticket(runtime, endpoint, active)
    return nothing
end

function parameter_global(registry, id, serial, interface)
    global_object = PipeWireAO.find_global(registry, id)
    global_object !== nothing && global_object.type == interface &&
        tryparse(UInt64, get(global_object.properties, "object.serial", "")) == serial ||
        throw(ArgumentError("parameter transfer registry incarnation changed"))
    return global_object
end

function parameter_controller(registry, controller::Envelope.ControllerIdentity)
    object = parameter_global(
        registry, controller.global_id, controller.serial, "PipeWire:Interface:Node",
    )
    # MediaSession proved the original controller profile and instance from
    # bound NodeInfo. Its authenticated forward pins that Node incarnation.
    client_id = tryparse(UInt32, get(object.properties, "client.id", ""))
    client_id !== nothing && client_id != 0 ||
        throw(ArgumentError("parameter controller client is unavailable"))
    client = PipeWireAO.find_global(registry, client_id)
    client !== nothing && client.type == "PipeWire:Interface:Client" &&
        tryparse(UInt64, get(client.properties, "object.serial", "")) !== nothing ||
        throw(ArgumentError("parameter controller client incarnation is unavailable"))
    return client_id
end

include("parameter_stream.jl")

function parameter_source(sources, graph, inlet)
    index = findfirst(source -> source.graph == graph && source.inlet == inlet, sources)
    index === nothing && throw(ArgumentError("no declared parameter mapping"))
    return sources[index]
end

# Caller holds the owner loop lock and has filled the idle source slot.
function stage_publication!(source::Source, endpoint, ticket)
    Endpoint.check_ticket(endpoint, ticket)
    source.sequence < typemax(Int64) || throw(ArgumentError("parameter sequence exhausted"))
    source.sequence += 1
    source.initial_pending = false
    source.publication = Publication(endpoint, ticket)
    source.revoked = nothing
    source.phase = PENDING
    return nothing
end

function stage_parameter!(runtime, endpoint, active, sources, session_controller)
    selected = nothing
    staged = false
    try
        graph, inlet = parameter_address(active.command)
        selected = parameter_source(sources, graph, inlet)
        with_thread_loop_lock(endpoint.loop) do _
            selected.phase == IDLE || throw(
                ArgumentError("parameter publication already pending")
            )
        end
        read_parameter!(runtime, endpoint, active, selected, active.command, session_controller)
        with_thread_loop_lock(endpoint.loop) do _
            stage_publication!(selected, endpoint, active)
            staged = true
            stream = something(selected.stream)
            # A paused stream has no process callback. Queue an
            # available output buffer now; callbacks retry later.
            _publish_pending!(selected, stream)
            selected.failure === nothing || throw(selected.failure)
            selected.revoked === nothing || throw(selected.revoked)
            if selected.phase == PENDING &&
                selected.failure === nothing &&
                stream_state(stream) ==
                PipeWireAO.LibPipeWire.PW_STREAM_STATE_STREAMING
                trigger_process!(stream)
            end
        end
    catch error
        with_thread_loop_lock(endpoint.loop) do _
            if staged && selected.phase == PENDING
                selected.phase = IDLE
                selected.publication = nothing
            end
            expired_or_revoked =
                (selected !== nothing && selected.revoked !== nothing) ||
                Endpoint._now!(endpoint) >= active.deadline
            result = expired_or_revoked ?
                Int32(-Base.Libc.ETIMEDOUT) : Int32(-Base.Libc.EINVAL)
            _completion!(
                endpoint,
                active,
                staged ? selected : nothing,
                result,
                _message(error),
            )
        end
        return nothing
    end
    return selected
end

function precompile_parameter_dispatch!(runtime_type, endpoint_type, ticket_type)
    transport_type = fieldtype(runtime_type, :transport)
    bootstrap_type = fieldtype(transport_type, :endpoint)
    registry_type = Registry{fieldtype(transport_type, :core)}
    command_type = Runner.RunnerCommand{:parameter,Arguments}
    precompile(Runner.encode_request, (Envelope.RequestHeader, command_type))
    precompile(Client.decode_request, (Profile, Envelope.RequestHeader, SPA.Struct))
    precompile(Endpoint.stage!, (endpoint_type, Pod))
    precompile(Endpoint.take!, (endpoint_type,))
    precompile(Endpoint.check_ticket, (endpoint_type, ticket_type))
    precompile(stage_parameter!, (runtime_type, endpoint_type, ticket_type, Vector{Source},
        Envelope.ControllerIdentity))
    for storage in (Vector{Float32}, Runner.ParameterStream)
        precompile(receive_parameter!, (
            runtime_type, endpoint_type, ticket_type, Source, Envelope.ControllerIdentity, storage,
        ))
    end
    precompile(parameter_controller, (registry_type, Envelope.ControllerIdentity))
    for value_type in (transport_type, bootstrap_type, ticket_type)
        precompile(getproperty, (value_type, Symbol))
    end
    precompile(_completion!, (endpoint_type, ticket_type, Source, Int32, String))
    precompile(Endpoint.complete!, (endpoint_type, ticket_type, Pod))
    precompile(Core.kwcall, (
        NamedTuple{(:terminal,),Tuple{Bool}}, typeof(Endpoint.complete!), endpoint_type, ticket_type, Pod,
    ))
    precompile(close, (endpoint_type,))
    return nothing
end

function preparation_request(controller, instance, token, parameter)
    header = Envelope.RequestHeader(
        controller, instance, token, Runner.PARAMETER_NDARRAY_OPERATION, Int64(30_000_000_000),
    )
    command = NdArrayParameter("graph", "parameter", parameter, controller)
    return command, Client.encode_request(PROFILE, header, command)
end

function prepare_parameter_ndarrays!(runtime, endpoint_type, ticket_type, sources, wake, clock)
    ranks = sort!(unique(length(source.shape) for source in sources))
    isempty(ranks) && return nothing
    controller = Envelope.ControllerIdentity(UInt32(3), UInt64(4), Int64(5))
    controller_proof = Endpoint.Controller(
        controller.global_id, controller.serial, controller, "unpublished-parameter-preparation",
        UInt32(getpid()), nothing, true, false, false,
    )
    instance = Int64(1)
    completion = Envelope.encode_completion(
        Envelope.ReplyHeader(instance, Int32(0)), _struct(); endpoint = :lifecycle,
    )
    rejection = Client.encode_rejection(
        PROFILE, Envelope.ReplyHeader(instance, Int32(-Base.Libc.EINVAL)), Connected,
    )
    transport = runtime.transport
    bootstrap = transport.endpoint
    # Use the running bootstrap loop only for the Endpoint's local state
    # checks. The scratch endpoint has no registry, does not publish any
    # Props, and has no parameter output stream. Its publisher has the same
    # concrete type as the live endpoint's publisher.
    scratch = endpoint_type(
        PROFILE, transport.loop, nothing, bootstrap.filter, instance, Connected,
        ParameterPublisher(wake, false), [controller_proof], nothing, Int64(0), nothing,
        completion, rejection, nothing, false, controller, clock, nothing,
    )
    token = Int64(0)
    for rank in ranks, parameter in Runner.parameter_ndarray_workload(rank)
        token += 1
        command, encoded = preparation_request(controller, instance, token, parameter)
        with_thread_loop_lock(transport.loop) do _
            Endpoint.stage!(scratch, encoded)
        end
        active = Endpoint.take!(scratch)
        active !== nothing || error("parameter dispatch preparation did not stage its request")
        # A Publication stored in a Source erases the endpoint and ticket types.
        # Exercise the standalone check and its native lock wrapper from a
        # dynamic call, as the publication boundary does.
        Base.invokelatest(Endpoint.check_ticket, scratch, active)
        format = parameter.format
        # Compile the staging mutation with the same Source type and a single-F32
        # slot. This source has no bootstrap authority or native output stream.
        source = Source(
            "", command.graph, command.inlet, collect(format.shape), something(parameter.schema, ""),
            format, zeros(UInt8, sizeof(Float32)), false, nothing, StreamBuffer(), Int32(4),
            IDLE, false, nothing, nothing, nothing, Int64(0), nothing, nothing,
            (Pod(nothing), Pod(nothing)), wake,
        )
        selected = parameter_source([source], parameter_address(active.command)...)
        with_thread_loop_lock(transport.loop) do _
            stage_publication!(selected, scratch, active)
        end
        source.phase = SUBMITTED
        _completion!(scratch, active, source, Int32(0), "")
        precompile(read_parameter!, (
            typeof(runtime), endpoint_type, ticket_type, Source,
            typeof(command), Envelope.ControllerIdentity,
        ))
    end
    return nothing
end

"""
    run_owner(options, runtime; clock=runtime.transport.endpoint.clock)

Run one ordinary owner and supervise its process lifetime.
"""
function run_owner(
    options, runtime; clock::Clocks.AbstractNanoClock = runtime.transport.endpoint.clock
)
    transport = runtime.transport
    wake = Base.Event(true)
    endpoint = listener = timer = nothing
    sources = Source[]
    active = selected = nothing
    failures = Exception[]
    try
        timer = parameter_timer(transport.loop, wake)
        sources = read_declarations(
            options.config, wake; check = () -> Bootstrap.preparation_check!(runtime)
        )
        all(
            source ->
                source.node_name != options.control_node &&
                source.node_name != options.bootstrap_node,
            sources,
        ) || throw(
            ArgumentError("parameter data and control endpoint names must be distinct")
        )
        with_thread_loop_lock(transport.loop) do _
            for source in sources
                _prepare_source!(source, transport, runtime)
            end
        end
        precompile(
            _control_endpoint, (typeof(options), typeof(transport), typeof(clock), typeof(wake))
        )
        # Compile the first sparse update before reporting the owner prepared.
        # The actual endpoint, ticket and payload remain operator-owned.
        endpoint_type = ParameterEndpoint{typeof(clock)}
        precompile_parameter_dispatch!(typeof(runtime), endpoint_type, ParameterTicket)
        prepare_parameter_ndarrays!(runtime, endpoint_type, ParameterTicket, sources, wake, clock)
        precompile_parameter_timer!(typeof(timer))
        for source in sources
            precompile(close, (typeof(source.stream),))
        end
        Bootstrap.prepared!(runtime)
        connect_ticket = Bootstrap.take_connect!(runtime)
        Bootstrap.connecting!(
            runtime,
            connect_ticket;
            ready = () -> with_thread_loop_lock(transport.loop) do _
                all(
                        source ->
                            source.stream !== nothing &&
                            source.failure === nothing &&
                            node_id(source.stream) ∉ (UInt32(0), typemax(UInt32)),
                        sources,
                    ) &&
                    endpoint !== nothing &&
                    node_id(something(endpoint.filter)) ∉ (UInt32(0), typemax(UInt32))
            end,
            quit = () -> notify(wake),
        )
        Bootstrap.check_connect!(runtime, connect_ticket)
        with_thread_loop_lock(transport.loop) do _
            for source in sources
                set_active!(something(source.stream), true)
            end
            endpoint = _control_endpoint(options, transport, clock, wake)
            listener = add_listener!(
                something(endpoint.registry);
                on_global_added = (registry, object) -> (notify(wake); nothing),
                on_global_removed = (registry, id) -> (notify(wake); nothing),
            )
        end
        Bootstrap.await_connected!(runtime, connect_ticket)
        previous = nothing
        while true
            at = Clocks.time_nanos(clock)::Int64
            previous === nothing ||
                at >= previous ||
                throw(Client.UnknownOutcome("parameter owner clock regressed"))
            previous = at
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
                    delay = max(1, Common.remaining_ns(active.deadline, at)) / 1e9
                    update_timer!(timer; delay)
                    selected = stage_parameter!(
                        runtime, endpoint, active, sources, connect_ticket.header.controller,
                    )
                    if selected === nothing
                        update_timer!(timer; delay = nothing)
                        active = nothing
                    end
                end
            end
            if active !== nothing
                with_thread_loop_lock(transport.loop) do _
                    result = Int32(0)
                    message = ""
                    if selected.revoked !== nothing
                        result = Int32(-Base.Libc.ETIMEDOUT)
                        message = _message(selected.revoked)
                    else
                        try
                            Endpoint.check_ticket(endpoint, active)
                        catch error
                            result = Int32(-Base.Libc.ETIMEDOUT)
                            message = _message(error)
                        end
                    end
                    if result < 0 || selected.phase == SUBMITTED
                        _completion!(endpoint, active, selected, result, message)
                        selected.phase = IDLE
                        selected.publication = nothing
                        selected.revoked = nothing
                        update_timer!(timer; delay = nothing)
                        active = selected = nothing
                    end
                end
            end
            wait(wake)
        end
    catch error
        push!(failures, error)
    finally
        try
            Bootstrap.finishing!(runtime)
        catch error
            push!(failures, error)
        end
        try
            timer === nothing || close(timer)
        catch error
            push!(failures, error)
        end
        try
            with_thread_loop_lock(transport.loop) do _
                # Exclude callbacks before releasing slots; teardown never applies a pending payload.
                for source in sources
                    source.phase = IDLE
                    source.publication = nothing
                    source.initial_pending = false
                    try
                        source.stream === nothing || close(source.stream)
                    catch error
                        push!(failures, error)
                    end
                end
                for resource in (listener, endpoint)
                    try
                        resource === nothing || close(resource)
                    catch error
                        push!(failures, error)
                    end
                end
            end
        catch error
            push!(failures, error)
        end
    end
    isempty(failures) ||
        throw(length(failures) == 1 ? only(failures) : CompositeException(failures))
    return nothing
end

function _owner_options(arguments)
    required = [
        "config",
        "remote",
        "bootstrap-node",
        "bootstrap-instance",
        "control-node",
        "control-instance",
    ]
    options = Common.cli_arguments(arguments; required)
    isabspath(options.config) && isabspath(options.remote) || throw(
        ArgumentError("parameter owner requires absolute --config and --remote paths")
    )
    for name in (:bootstrap_node, :control_node)
        occursin(r"^[a-zA-Z0-9_.-]{1,128}$", getproperty(options, name)) ||
            throw(ArgumentError("invalid parameter owner node name"))
    end
    bootstrap_instance = tryparse(Int64, options.bootstrap_instance)
    control_instance = tryparse(Int64, options.control_instance)
    bootstrap_instance !== nothing &&
    bootstrap_instance > 0 &&
    control_instance !== nothing &&
    control_instance > 0 ||
        throw(ArgumentError("parameter owner instances must be positive Int64"))
    options.bootstrap_node != options.control_node ||
        throw(ArgumentError("bootstrap and parameter endpoints must have distinct names"))
    return merge(options, (; bootstrap_instance, control_instance))
end

"""
    main(arguments=ARGS)

Run the sparse parameter owner using explicit config, remote, bootstrap endpoint
and control endpoint arguments. Publish bootstrap `Preparing` before reading the
parameter declarations; RTC controls admission and links. Return
`nothing` after cleanup, or throw the retained owner and cleanup failures.
"""
function main(arguments = ARGS)
    options = _owner_options(arguments)
    return Bootstrap.with_owner(options; application_name = "RTC parameters") do admitted
        run_owner(admitted, admitted.bootstrap_runtime)
    end
end

function precompile_parameter_codecs!(runtime_type, endpoint_type, ranks)
    controller = Envelope.ControllerIdentity(UInt32(3), UInt64(4), Int64(5))
    instance = Int64(1)
    token = Int64(0)
    for rank in ranks, parameter in Runner.parameter_ndarray_workload(rank)
        token += 1
        command, encoded = preparation_request(controller, instance, token, parameter)
        header, decoded = Client.decode_request(PROFILE, encoded)
        request = Endpoint.requested_event(header, decoded, UInt8[], Int64(0))
        precompile(Hsm.dispatch!, (endpoint_type, Symbol, typeof(request)))
        reply = Envelope.ReplyHeader(header.controller, instance, token, header.operation, Int32(0))
        Client.decode_completion(PROFILE, Client.encode_completion(
            PROFILE, reply, decoded.graph, decoded.inlet, Int64(1), true, false, "",
        ))
        isconcretetype(runtime_type) && precompile(read_parameter!, (
            runtime_type, endpoint_type, ParameterTicket, Source,
            typeof(command), Envelope.ControllerIdentity,
        ))
    end
    return nothing
end

@compile_workload begin
    # Infer the production wrappers. Only the value-only codec round trips run
    # during image generation. Live preparation still uses the installed SDK's
    # loop, timer, registry and exact declared ranks before owner readiness.
    clock = Clocks.SystemNanoClock
    endpoint_type = ParameterEndpoint{clock}
    runtime_type = Core.Compiler.return_type(Bootstrap.Runtime, Tuple{String,String,Int64})
    precompile_parameter_codecs!(runtime_type, endpoint_type, Runner.PARAMETER_NDARRAY_PRECOMPILE_RANKS)
    if isconcretetype(runtime_type)
        precompile_parameter_dispatch!(runtime_type, endpoint_type, ParameterTicket)
        precompile(prepare_parameter_ndarrays!, (
            runtime_type, Type{endpoint_type}, Type{ParameterTicket}, Vector{Source}, Base.Event, clock,
        ))
    end
    timer_type = Core.Compiler.return_type(parameter_timer, Tuple{ThreadLoop,Base.Event})
    isconcretetype(timer_type) && precompile_parameter_timer!(timer_type)
end

end # module ParameterSource
