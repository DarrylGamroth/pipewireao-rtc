module HILSourceControl

using PipeWireAO

# All fields use standard scalar PODs in SPA_PROP_params. Run/reset retain the
# existing native V1 encoding; source-query and source-snapshot have separate
# exact key sets and are published as separate Props in one complete update.
const VERSION = Int32(1)
const INITIAL = Int32(0)
const RUN = Int32(1)
const RESET = Int32(2)
const QUERY = Int32(3)
const INVALID = Int32(4)
const QUERY_NAMES = (
    "pipewireao.source-query.version", "pipewireao.source-query.request-token",
    "pipewireao.source-query.instance",
)
const SNAPSHOT_NAMES = (
    "pipewireao.source-snapshot.version", "pipewireao.source-snapshot.instance",
    "pipewireao.source-snapshot.kind", "pipewireao.source-snapshot.completed-token",
    "pipewireao.source-snapshot.result", "pipewireao.source-snapshot.generation",
    "pipewireao.source-snapshot.sequence", "pipewireao.source-snapshot.running",
    "pipewireao.source-snapshot.completed", "pipewireao.source-snapshot.report-generation",
    "pipewireao.source-snapshot.report-sequence",
)
const REJECTION_NAMES = map(name -> replace(name, "source-snapshot" => "source-rejection"), SNAPSHOT_NAMES)
query_values(token::Int64, instance::Int64) = (VERSION, token, instance)
snapshot_values(instance::Int64, kind::Int32, token::Int64, result::Int32,
                generation::Int64, sequence::Int64, running::Bool, completed::Bool,
                report_generation::Int64, report_sequence::Int64) =
    (VERSION, instance, kind, token, result, generation, sequence, running,
     completed, report_generation, report_sequence)

const QueryValues = typeof(query_values(Int64(0), Int64(1)))
const SnapshotValues = typeof(snapshot_values(Int64(1), INITIAL, Int64(0), Int32(0),
    Int64(1), Int64(0), false, false, Int64(1), Int64(0)))

"""One loop-locked pending request, one bounded rejection slot, prepared codecs.

Only the PipeWire parameter callback stages requests. Only the serialized plant
owner applies them, after adoption, outside the lock. It then publishes under
that same lock and clears the slot before releasing the lock. No borrowed POD
escapes a callback and no simulation or report work runs on the PipeWire loop.
"""
mutable struct Mailbox{Q,S,P}
    instance::Int64
    ready::Threads.Atomic{Bool}
    kind::Int32
    token::Int64
    requested_running::Bool
    rejected_kind::Int32
    rejected_token::Int64
    rejected_result::Int32
    last_token::Int64
    last_kind::Int32
    report_generation::Int64
    report_sequence::Int64
    run_request::Base.RefValue{RunControlRequest}
    reset_request::Base.RefValue{ResetControlRequest}
    run_status::Base.RefValue{RunControlStatus}
    reset_status::Base.RefValue{ResetControlStatus}
    query::Q
    query_destination::Base.RefValue{QueryValues}
    snapshot::S
    snapshot_destination::Base.RefValue{SnapshotValues}
    rejection::S
    rejection_destination::Base.RefValue{SnapshotValues}
    run_buffer::PodBuffer
    reset_buffer::PodBuffer
    parameters::P
end

function Mailbox(instance::Int64)
    instance > 0 || throw(ArgumentError("source instance must be positive"))
    query = PropsBuffer(QUERY_NAMES, query_values(Int64(0), instance))
    initial = snapshot_values(instance, INITIAL, Int64(0), Int32(0), Int64(1),
        Int64(0), false, false, Int64(1), Int64(0))
    snapshot = PropsBuffer(SNAPSHOT_NAMES, initial)
    rejection = PropsBuffer(REJECTION_NAMES, initial)
    run_buffer = PodBuffer(512)
    reset_buffer = PodBuffer(512)
    run_control_status!(run_buffer, 0, 0, :stopped)
    reset_control_status!(reset_buffer, 0, 0)
    parameters = PreparedParams((run_buffer.pod, reset_buffer.pod, snapshot.pod, rejection.pod))
    return Mailbox(instance, Threads.Atomic{Bool}(false), INITIAL, 0, false, INITIAL, 0, Int32(0), 0, INITIAL, 1, 0,
        Ref{RunControlRequest}(), Ref{ResetControlRequest}(),
        Ref{RunControlStatus}(), Ref{ResetControlStatus}(), query,
        Ref(query_values(Int64(0), instance)), snapshot, Ref(initial), rejection, Ref(initial),
        run_buffer, reset_buffer, parameters)
end

function source_properties(mailbox::Mailbox)
    return Dict(
        "pipewireao.run-control" => "true", "pipewireao.reset-control" => "true",
        "pipewireao.source-query.version" => "1",
        "pipewireao.source-snapshot.version" => "1",
        "pipewireao.source-rejection.version" => "1",
        "pipewireao.source-control.instance" => string(mailbox.instance),
        "pipewireao.source-control.owner-pid" => string(getpid()),
    )
end

# Rejections never overwrite an accepted request. A flooding controller can
# fill only this one rejection slot; further rejects have no completion promise.
function reject!(mailbox::Mailbox, kind::Int32, token::Int64, result::Int32)
    if mailbox.rejected_kind == INITIAL
        mailbox.rejected_kind = kind
        mailbox.rejected_token = token
        mailbox.rejected_result = result
        mailbox.ready[] = true
    end
    return nothing
end

function stage!(mailbox::Mailbox, kind::Int32, token::Int64, requested_running::Bool=false)
    if (mailbox.kind == kind && mailbox.token == token) ||
       (mailbox.last_token == token && mailbox.last_kind == kind)
        # A duplicate has the original pending/committed outcome. Publishing
        # a competing EALREADY reply could reach a controller before that ACK.
        return nothing
    end
    if token <= mailbox.last_token
        reject!(mailbox, kind, token, Int32(-Base.Libc.ESTALE))
    elseif mailbox.kind != INITIAL
        result = token == mailbox.token ? -Base.Libc.EALREADY : -Base.Libc.EBUSY
        reject!(mailbox, kind, token, Int32(result))
    else
        mailbox.kind = kind
        mailbox.token = token
        mailbox.requested_running = requested_running
        mailbox.ready[] = true
    end
    return nothing
end

struct ParameterChanged{M}
    mailbox::M
end
function (callback::ParameterChanged)(::Stream, id::UInt32, pod::Union{Nothing,Pod})
    id == SPA.PARAM_PROPS && pod !== nothing || return nothing
    mailbox = callback.mailbox
    if parse_run_control_request!(mailbox.run_request, pod) == 0
        request = mailbox.run_request[]
        stage!(mailbox, RUN, request.token,
            request.requested_state == PipeWireAO.LibPipeWire.PW_AO_RUN_CONTROL_STATE_RUNNING)
    elseif parse_reset_control_request!(mailbox.reset_request, pod) == 0
        stage!(mailbox, RESET, mailbox.reset_request[].token)
    elseif parse_props!(mailbox.query_destination, mailbox.query, pod) == 0
        version, token, instance = mailbox.query_destination[]
        if version != VERSION || token <= 0 || instance != mailbox.instance
            reject!(mailbox, INVALID, Int64(0), Int32(-Base.Libc.EINVAL))
        else
            stage!(mailbox, QUERY, token)
        end
    elseif parse_run_control_status!(mailbox.run_status, pod) == 0 ||
           parse_reset_control_status!(mailbox.reset_status, pod) == 0 ||
           parse_props!(mailbox.snapshot_destination, mailbox.snapshot, pod) == 0 ||
           parse_props!(mailbox.rejection_destination, mailbox.rejection, pod) == 0
        # The stream's initial/publication parameters are not requests.
        return nothing
    else
        # Native parsers may partially write outputs on error. Never derive
        # a request identity from such output or from an oversized POD.
        reject!(mailbox, INVALID, Int64(0), Int32(-Base.Libc.EINVAL))
    end
    return nothing
end
struct ParameterOverflow{M}
    mailbox::M
end
function (callback::ParameterOverflow)(::Stream, id::UInt32, total::Int)
    id == SPA.PARAM_PROPS && reject!(callback.mailbox, INVALID, Int64(0),
        Int32(-Base.Libc.E2BIG))
    return nothing
end

"""Read the pending scalar request while holding the source loop lock."""
pending(mailbox::Mailbox) = (mailbox.kind, mailbox.token, mailbox.requested_running)

"""Publish an owner-committed snapshot and native completion under the loop lock.

Publication failure leaves the pending identity intact and propagates to owner
failure cleanup. Historical run/reset statuses are retained across queries;
subscribers join only the kind/token named by the latest source snapshot.
"""
function publish!(mailbox::Mailbox, stream::Stream, kind::Int32, token::Int64,
                  result::Int32, state, generation::Int64)
    state.sequence <= typemax(Int64) || error("source sequence exceeds native Long range")
    generation >= 1 || error("source generation must be positive")
    kind == RUN && run_control_status!(mailbox.run_buffer, token, result,
        state.running ? :running : :stopped)
    kind == RESET && reset_control_status!(mailbox.reset_buffer, token, result)
    values = snapshot_values(mailbox.instance, kind, token, result,
        generation, Int64(state.sequence), state.running, state.completed,
        mailbox.report_generation, mailbox.report_sequence)
    props!(mailbox.snapshot, values)
    mailbox.snapshot_destination[] = values
    update_params!(stream, mailbox.parameters)
    if mailbox.kind == kind && mailbox.token == token
        mailbox.last_token = token
        mailbox.last_kind = kind
        mailbox.kind = INITIAL
        mailbox.token = 0
    end
    mailbox.ready[] = mailbox.kind != INITIAL || mailbox.rejected_kind != INITIAL
    return nothing
end

"Publish one staged rejection without changing the retained committed ACK."
function publish_rejection!(mailbox::Mailbox, stream::Stream, state, generation::Int64)
    mailbox.rejected_kind == INITIAL && return nothing
    state.sequence <= typemax(Int64) || error("source sequence exceeds native Long range")
    props!(mailbox.rejection, snapshot_values(mailbox.instance, mailbox.rejected_kind,
        mailbox.rejected_token, mailbox.rejected_result, generation,
        Int64(state.sequence), state.running, state.completed,
        mailbox.report_generation, mailbox.report_sequence))
    update_params!(stream, mailbox.parameters)
    mailbox.rejected_kind = INITIAL
    mailbox.ready[] = mailbox.kind != INITIAL
    return nothing
end

"""Record successful cold artifact publication for this exact owner cursor."""
function report_ready!(mailbox::Mailbox, generation::Int64, sequence::UInt64)
    sequence <= typemax(Int64) || error("report sequence exceeds native Long range")
    mailbox.report_generation = generation
    mailbox.report_sequence = Int64(sequence)
    return nothing
end

"""Apply one validated request outside the PipeWire lock, between exchanges."""
function apply!(state, kind::Int32, token::Int64, requested_running::Bool,
                now::UInt64, period::UInt64, reset_owner!::F) where {F}
    kind in (RUN, RESET, QUERY) || return Int32(-Base.Libc.EINVAL)
    token > state.last_request_id || return Int32(-Base.Libc.ESTALE)
    state.last_request_id = token
    if kind == RUN
        if requested_running
            state.completed && return Int32(-Base.Libc.EALREADY)
            if !state.running
                state.deadline_ns = Base.checked_add(now, period)
                state.running = true
            end
        else
            state.running = false
            state.deadline_ns = 0
        end
    elseif kind == RESET
        state.running && return Int32(-Base.Libc.EBUSY)
        reset_owner!()
        state.sequence = 0
        state.completed = false
        state.deadline_ns = 0
    end
    return Int32(0)
end

end
