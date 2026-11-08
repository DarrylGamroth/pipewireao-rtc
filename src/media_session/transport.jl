# Native callbacks only append owned records to this owner-thread queue. All
# application observations and Hsm events are applied after iterate! returns.
# A single dispatch can deliver registry, bound and info records for the
# nodes, ports, clients and links of a full session.
const MAX_OBSERVATION_RECORDS = 2048
const MAX_OBSERVATION_BYTES = 4 * 1024 * 1024
const MAX_ENUMERATION_BYTES = 4 * 1024 * 1024
const MAX_ENUMERATION_RECORDS = 4096
mutable struct EventQueue
    records::Vector{Union{Nothing,AbstractEvent}}
    head::Int
    count::Int
    bytes::Int
    byte_limit::Int
    overflow::Bool
end
EventQueue(
    capacity::Integer = MAX_OBSERVATION_RECORDS;
    byte_limit::Integer = MAX_OBSERVATION_BYTES,
) = (
    capacity > 0 && byte_limit > 0 ||
        throw(ArgumentError("invalid event queue bounds"));
    EventQueue(
        fill!(Vector{Union{Nothing,AbstractEvent}}(undef, capacity), nothing),
        1,
        0,
        0,
        byte_limit,
        false,
    )
)
"Conservative retained Julia size of a copied observation; this is cold control."
event_size(event::AbstractEvent) = Base.summarysize(event)
function stage!(queue::EventQueue, event::AbstractEvent)
    extent = event_size(event)
    if queue.count == length(queue.records) || extent > queue.byte_limit - queue.bytes
        queue.overflow = true
        return false
    end
    index = mod1(queue.head + queue.count, length(queue.records))
    queue.records[index] = event
    queue.count += 1
    queue.bytes += extent
    return true
end
function next_event!(queue::EventQueue)
    queue.count == 0 && return nothing
    event = something(queue.records[queue.head])
    queue.records[queue.head] = nothing
    queue.head = mod1(queue.head + 1, length(queue.records))
    queue.count -= 1
    queue.bytes -= event_size(event)
    return event
end

struct ControllerAdded <: AbstractEvent
    id::UInt32
    serial::UInt64
end
struct GlobalRemoved <: AbstractEvent
    id::UInt32
end
struct CoreUpdated <: AbstractEvent
    info::CoreInfo
end
struct CoreDone <: AbstractEvent
    id::UInt32
    sequence::Cint
end
struct CoreError <: AbstractEvent
    id::UInt32
    sequence::Cint
    message::String
end
struct ParamReceived <: AbstractEvent
    object::UInt32
    sequence::Cint
    param::UInt32
    pod::Union{Nothing,Pod}
end
struct RequestReceived <: AbstractEvent
    pod::Union{Nothing,Pod}
    received::Int64
end
struct FilterChanged <: AbstractEvent
    state::Int32
    message::Union{Nothing,String}
end
param_callback(queue::EventQueue, object::UInt32) =
    (_proxy, sequence, param, _index, _next, pod) ->
        stage!(queue, ParamReceived(object, sequence, param, pod))

struct Cancelled <: Exception end
Base.showerror(io::IO, ::Cancelled) = print(io, "retired session operation")
mutable struct Job{T<:EffectTicket}
    ticket::T
    cancelled::Bool
end
mutable struct Parameters
    param::UInt32
    records::Vector{Pod}
    bytes::Int
    error::Union{Nothing,String}
end
mutable struct Barrier
    done::Bool
    error::Union{Nothing,String}
end
now(runtime) = Clocks.time_nanos(runtime.clock)
function check_core!(runtime)
    runtime.transport_error === nothing || throw(ArgumentError(runtime.transport_error))
    isopen(runtime.core) || throw(InvalidStateException("session core is closed", :closed))
    return nothing
end
function check_job(runtime, job::Job)
    job.cancelled && throw(Cancelled())
    budgeted(job.ticket.effect) &&
        Clocks.time_nanos(runtime.source_clock) >= job.ticket.deadline &&
        throw(ArgumentError("session effect expired; outcome unknown"))
    check_core!(runtime)
    return nothing
end
function await_condition!(predicate, runtime, job)
    while true
        check_job(runtime, job)
        result = predicate()
        result === nothing || result === false || return result
        sleep(0.001)
    end
end
function parameter_error!(runtime, id::UInt32, sequence::Cint, message::AbstractString)
    pending = get(runtime.parameters_io, (id, sequence), nothing)
    pending === nothing && return false
    pending.error = String(message)
    return true
end
function update!(runtime, event::ParamReceived)
    pending = get(runtime.parameters_io, (event.object, event.sequence), nothing)
    pending === nothing && return nothing
    if event.param != pending.param
        pending.error = "parameter enumeration identity changed"
    elseif event.pod !== nothing
        extent = sizeof(event.pod)
        if length(pending.records) >= MAX_ENUMERATION_RECORDS ||
            extent > MAX_ENUMERATION_BYTES - pending.bytes
            pending.error = "parameter enumeration exceeds bound"
        else
            push!(pending.records, event.pod)
            pending.bytes += extent
        end
    end
    return nothing
end
update!(runtime, event::GlobalRemoved) = remove_object!(runtime, event.id)
function update!(runtime, event::CoreUpdated)
    previous = runtime.core_info
    if previous !== nothing &&
        (previous.cookie, previous.name) != (event.info.cookie, event.info.name)
        required_lost!(runtime.machine, "remote core incarnation changed")
    end
    runtime.core_info = event.info
    return nothing
end
function update!(runtime, event::CoreDone)
    event.id == 0 || return nothing
    pending = get(runtime.barriers, event.sequence, nothing)
    pending === nothing || (pending.done = true)
    return nothing
end
function update!(runtime, event::CoreError)
    pending = get(runtime.barriers, event.sequence, nothing)
    if pending !== nothing
        pending.error = event.message
    elseif event.id == 0
        runtime.transport_error = event.message
        required_lost!(runtime.machine, event.message)
    end
    return nothing
end

function synchronize!(runtime, job)
    check_job(runtime, job)
    sequence = PipeWireAO.sync!(runtime.core)
    barrier = Barrier(false, nothing)
    runtime.barriers[sequence] = barrier
    try
        await_condition!(runtime, job) do
            barrier.error === nothing || throw(ArgumentError(barrier.error))
            barrier.done
        end
    finally
        delete!(runtime.barriers, sequence)
    end
    return nothing
end
parameter_id(::Val{:Props}) = SPA.PARAM_PROPS
parameter_id(::Val{:PropInfo}) = SPA.PARAM_PROP_INFO
parameter_id(::Val{:EnumFormat}) = SPA.PARAM_ENUM_FORMAT
parameter_id(::Val{:Format}) = SPA.PARAM_FORMAT
parameter_id(::Val) = throw(ArgumentError("unsupported parameter enumeration"))
function enumerate!(runtime, job, handle::UInt64, name::AbstractString)
    check_job(runtime, job)
    assert_identity!(runtime, handle)
    object = something(find_object(runtime, handle))
    param = parameter_id(Val(Symbol(name)))
    sequence = Ref(Cint(0))
    check_job(runtime, job)
    PipeWireAO.enum_params!(
        object.proxy,
        param;
        count = UInt32(MAX_ENUMERATION_RECORDS),
        sequence_out = sequence,
    )
    key = (object.id, sequence[])
    haskey(runtime.parameters_io, key) &&
        throw(ArgumentError("duplicate native parameter sequence"))
    pending = Parameters(param, Pod[], 0, nothing)
    runtime.parameters_io[key] = pending
    try
        synchronize!(runtime, job)
        if pending.error !== nothing
            # The server may refuse a read-only enum while keeping its global
            # alive. PipeWireAO correctly retains the failed proxy's error;
            # replace that local binding only after the native barrier.
            refresh_object!(runtime, object.id)
            throw(ArgumentError(pending.error))
        end
        assert_identity!(runtime, handle)
        return pending.records
    finally
        delete!(runtime.parameters_io, key)
    end
end
function setparam!(runtime, job, handle::UInt64, name::AbstractString, pod::Pod)
    check_job(runtime, job)
    assert_identity!(runtime, handle)
    submitted!(runtime.machine, job.ticket)
    object = something(find_object(runtime, handle))
    param = parameter_id(Val(Symbol(name)))
    check_job(runtime, job)
    PipeWireAO.set_param!(object.proxy, param, pod)
    return nothing
end
function queryparam!(runtime, job, handle::UInt64, name::AbstractString, pod::Pod)
    check_job(runtime, job)
    assert_identity!(runtime, handle)
    object = something(find_object(runtime, handle))
    param = parameter_id(Val(Symbol(name)))
    check_job(runtime, job)
    PipeWireAO.set_param!(object.proxy, param, pod)
    return nothing
end
