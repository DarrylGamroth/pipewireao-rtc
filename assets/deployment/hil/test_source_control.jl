using PipeWireAO
using Test

include("owner_protocol.jl")
include("source_control.jl")

const Protocol = HILOwnerProtocol
const Control = HILSourceControl
const Native = PipeWireAO.LibPipeWire

struct ResetOwnerRecorder
    calls::Base.RefValue{Int}
end

(recorder::ResetOwnerRecorder)() = (recorder.calls[] += 1; nothing)

function deliver_source_parameter(stream::T, id::UInt32, pod::Pod) where {T<:Stream}
    events = getfield(stream, :events)[]
    GC.@preserve stream pod ccall(
        events.param_changed,
        Cvoid,
        (Ref{T}, UInt32, Ptr{Native.spa_pod}),
        stream,
        id,
        PipeWireAO._pod_pointer(pod),
    )
    return nothing
end

function deliver_source_overflow(stream::T, id::UInt32, pod::Pod) where {T<:Stream}
    events = getfield(stream, :events)[]
    GC.@preserve stream pod ccall(
        events.param_changed,
        Cvoid,
        (Ref{T}, UInt32, Ptr{Native.spa_pod}),
        stream,
        id,
        PipeWireAO._pod_pointer(pod),
    )
    return nothing
end

function source_callback_bytes(stream, id, pod)
    return @allocated deliver_source_parameter(stream, id, pod)
end

function source_apply_bytes(state, kind, token, running, now, period, reset_owner)
    return @allocated Control.apply!(state, kind, token, running, now, period, reset_owner)
end

function source_publish_bytes(mailbox, stream, kind, token, result::Int32, state, generation::Int64)
    return @allocated Control.publish!(mailbox, stream, kind, token, result, state, generation)
end

function source_rejection_bytes(mailbox, stream, state, generation)
    return @allocated Control.publish_rejection!(mailbox, stream, state, generation)
end

function source_snapshot(mailbox)
    result = parse_props!(mailbox.snapshot_destination, mailbox.snapshot, mailbox.snapshot.pod)
    result == 0 || error("failed to parse source snapshot: $result")
    return mailbox.snapshot_destination[]
end

function source_rejection(mailbox)
    result = parse_props!(mailbox.rejection_destination, mailbox.rejection, mailbox.rejection.pod)
    result == 0 || error("failed to parse source rejection: $result")
    return mailbox.rejection_destination[]
end

@testset "native source control callbacks and owner publication" begin
    context = Context()
    core = CoreConnection(context; self=true)
    mailbox = Control.Mailbox(Int64(0x123456))
    parameter_buffer = PodBuffer(4096)
    stream = Stream(
        core,
        "source-control-test";
        properties=Control.source_properties(mailbox),
        param_buffer=parameter_buffer,
        on_param_changed=Control.ParameterChanged(mailbox),
        on_param_overflow=Control.ParameterOverflow(mailbox),
    )
    state = Protocol.OwnerState()
    reset_owner = ResetOwnerRecorder(Ref(0))

    try
        properties = stream_properties(stream)
        @test properties["pipewireao.run-control"] == "true"
        @test properties["pipewireao.reset-control"] == "true"
        @test properties["pipewireao.source-query.version"] == "1"
        @test properties["pipewireao.source-snapshot.version"] == "1"
        @test properties["pipewireao.source-rejection.version"] == "1"
        @test properties["pipewireao.source-control.instance"] == string(mailbox.instance)
        @test properties["pipewireao.source-control.owner-pid"] == string(getpid())
        @test length(mailbox.parameters.params) == 4
        @test mailbox.parameters.params[3] === mailbox.snapshot.pod
        @test mailbox.parameters.params[4] === mailbox.rejection.pod

        @test parse_run_control_status!(mailbox.run_status, mailbox.run_buffer.pod) == 0
        @test mailbox.run_status[].completed_token == 0
        @test mailbox.run_status[].result == 0
        @test mailbox.run_status[].actual_state == Native.PW_AO_RUN_CONTROL_STATE_STOPPED
        @test parse_reset_control_status!(mailbox.reset_status, mailbox.reset_buffer.pod) == 0
        @test mailbox.reset_status[].completed_token == 0
        @test mailbox.reset_status[].result == 0
        @test source_snapshot(mailbox) == Control.snapshot_values(mailbox.instance,
            Control.INITIAL, Int64(0), Int32(0), Int64(1), Int64(0), false, false,
            Int64(1), Int64(0))

        # Run request is staged by the actual PipeWire callback trampoline;
        # OwnerState changes only when the serialized owner applies it.
        run_request = run_control_request(1, :running)
        @test deliver_source_parameter(stream, SPA.PARAM_PROPS, run_request) === nothing
        @test Control.pending(mailbox) == (Control.RUN, 1, true)
        @test !state.running && state.last_request_id == 0
        @test source_callback_bytes(stream, SPA.PARAM_PROPS, run_request) == 0
        @test Control.apply!(state, Control.RUN, 1, true, UInt64(100), UInt64(20), reset_owner) == 0
        @test state.running && state.deadline_ns == 120 && state.last_request_id == 1
        @test Control.publish!(mailbox, stream, Control.RUN, 1, Int32(0), state, 1) === nothing
        @test parse_run_control_status!(mailbox.run_status, mailbox.run_buffer.pod) == 0
        @test mailbox.run_status[].completed_token == 1
        @test mailbox.run_status[].actual_state == Native.PW_AO_RUN_CONTROL_STATE_RUNNING
        @test source_snapshot(mailbox)[3:8] == (Control.RUN, 1, 0, 1, 0, true)

        # Pause commits token 2; reset then clears sequence/completion without
        # moving the monotonic request identity backwards.
        pause_request = run_control_request(2, :stopped)
        @test deliver_source_parameter(stream, SPA.PARAM_PROPS, pause_request) === nothing
        @test state.running
        @test Control.apply!(state, Control.RUN, 2, false, UInt64(110), UInt64(20), reset_owner) == 0
        @test !state.running && state.deadline_ns == 0 && state.last_request_id == 2
        @test Control.publish!(mailbox, stream, Control.RUN, 2, Int32(0), state, 1) === nothing
        @test parse_run_control_status!(mailbox.run_status, mailbox.run_buffer.pod) == 0
        @test mailbox.run_status[].completed_token == 2
        @test mailbox.run_status[].actual_state == Native.PW_AO_RUN_CONTROL_STATE_STOPPED

        state.sequence = 9
        state.completed = true
        reset_request = reset_control_request(3)
        @test deliver_source_parameter(stream, SPA.PARAM_PROPS, reset_request) === nothing
        @test state.sequence == 9 && state.completed && state.last_request_id == 2
        @test Control.apply!(state, Control.RESET, 3, false, UInt64(120), UInt64(20), reset_owner) == 0
        @test reset_owner.calls[] == 1
        @test state.sequence == 0 && !state.completed && !state.running
        @test state.last_request_id == 3
        @test Control.publish!(mailbox, stream, Control.RESET, 3, Int32(0), state, 1) === nothing
        @test parse_reset_control_status!(mailbox.reset_status, mailbox.reset_buffer.pod) == 0
        @test mailbox.reset_status[].completed_token == 3 && mailbox.reset_status[].result == 0

        # Query has its own token kind; run/reset acknowledgements remain intact.
        query_request = Pod(props_param(SPA.Props(
            Control.QUERY_NAMES[1] => Control.VERSION,
            Control.QUERY_NAMES[2] => Int64(4),
            Control.QUERY_NAMES[3] => mailbox.instance,
        )))
        @test deliver_source_parameter(stream, SPA.PARAM_PROPS, query_request) === nothing
        @test Control.pending(mailbox) == (Control.QUERY, 4, false)
        @test Control.apply!(state, Control.QUERY, 4, false, UInt64(130), UInt64(20), reset_owner) == 0
        @test state.last_request_id == 4 && !state.running
        @test Control.publish!(mailbox, stream, Control.QUERY, 4, Int32(0), state, 1) === nothing
        @test parse_run_control_status!(mailbox.run_status, mailbox.run_buffer.pod) == 0
        @test parse_reset_control_status!(mailbox.reset_status, mailbox.reset_buffer.pod) == 0
        @test mailbox.run_status[].completed_token == 2
        @test mailbox.reset_status[].completed_token == 3
        @test source_snapshot(mailbox)[3:8] == (Control.QUERY, 4, 0, 1, 0, false)

        # Measure a fresh accepted request through the native callback
        # trampoline; reset mailbox state only outside the measured call.
        accepted_for_measurement = run_control_request(10, :running)
        @test deliver_source_parameter(stream, SPA.PARAM_PROPS, accepted_for_measurement) === nothing
        mailbox.kind = Control.INITIAL
        mailbox.token = 0
        mailbox.ready[] = false
        @test source_callback_bytes(stream, SPA.PARAM_PROPS, accepted_for_measurement) == 0
        @test Control.pending(mailbox) == (Control.RUN, 10, true)
        mailbox.kind = Control.INITIAL
        mailbox.token = 0
        mailbox.ready[] = false

        # Commit an accepted pending request, then malformed input must not use
        # the native parser's partially written token as a rejection identity.
        pending_request = run_control_request(5, :running)
        @test deliver_source_parameter(stream, SPA.PARAM_PROPS, pending_request) === nothing
        @test Control.pending(mailbox) == (Control.RUN, 5, true)
        @test deliver_source_parameter(stream, SPA.PARAM_PROPS, pending_request) === nothing
        @test mailbox.rejected_kind == Control.INITIAL
        owner_before_rejection = (state.running, state.completed, state.sequence,
            state.last_request_id, state.deadline_ns)
        partially_parsed = Pod(props_param(SPA.Props(
            "pipewireao.run-control.version" => Int32(1),
            "pipewireao.run-control.request-token" => Int64(77),
            "pipewireao.run-control.requested-state" => Int32(1),
        )))
        @test deliver_source_parameter(stream, SPA.PARAM_PROPS, partially_parsed) === nothing
        @test Control.pending(mailbox) == (Control.RUN, 5, true)
        @test mailbox.rejected_kind == Control.INVALID
        @test mailbox.rejected_token == 0
        @test mailbox.rejected_result == -Base.Libc.EINVAL
        @test (state.running, state.completed, state.sequence,
            state.last_request_id, state.deadline_ns) == owner_before_rejection
        committed_snapshot = copy(mailbox.snapshot.pod.data)
        committed_run = copy(mailbox.run_buffer.pod.data)
        committed_reset = copy(mailbox.reset_buffer.pod.data)
        @test Control.publish_rejection!(mailbox, stream, state, 1) === nothing
        @test source_rejection(mailbox)[3:6] ==
              (Control.INVALID, 0, -Base.Libc.EINVAL, 1)
        @test mailbox.snapshot.pod.data == committed_snapshot
        @test mailbox.run_buffer.pod.data == committed_run
        @test mailbox.reset_buffer.pod.data == committed_reset
        @test Control.pending(mailbox) == (Control.RUN, 5, true)

        oversized = Pod("x"^8192)
        before_overflow = copy(parameter_buffer.pod.data)
        @test deliver_source_overflow(stream, SPA.PARAM_PROPS, oversized) === nothing
        @test parameter_buffer.pod.data == before_overflow
        @test Control.pending(mailbox) == (Control.RUN, 5, true)
        @test (state.running, state.completed, state.sequence,
            state.last_request_id, state.deadline_ns) == owner_before_rejection
        @test mailbox.rejected_kind == Control.INVALID
        @test mailbox.rejected_token == 0
        @test mailbox.rejected_result == -Base.Libc.E2BIG
        @test Control.publish_rejection!(mailbox, stream, state, 1) === nothing
        @test source_rejection(mailbox)[3:6] ==
              (Control.INVALID, 0, -Base.Libc.E2BIG, 1)

        # A distinct pending token is rejected as busy without displacing the
        # accepted request; rejection publication leaves the committed ACKs intact.
        busy_request = run_control_request(6, :stopped)
        @test deliver_source_parameter(stream, SPA.PARAM_PROPS, busy_request) === nothing
        @test Control.pending(mailbox) == (Control.RUN, 5, true)
        @test mailbox.rejected_kind == Control.RUN
        @test mailbox.rejected_token == 6
        @test mailbox.rejected_result == -Base.Libc.EBUSY
        committed_snapshot = copy(mailbox.snapshot.pod.data)
        committed_run = copy(mailbox.run_buffer.pod.data)
        committed_reset = copy(mailbox.reset_buffer.pod.data)
        @test Control.publish_rejection!(mailbox, stream, state, 1) === nothing
        @test source_rejection(mailbox)[3:6] == (Control.RUN, 6, -Base.Libc.EBUSY, 1)
        @test mailbox.snapshot.pod.data == committed_snapshot
        @test mailbox.run_buffer.pod.data == committed_run
        @test mailbox.reset_buffer.pod.data == committed_reset
        @test mailbox.parameters.params[4] === mailbox.rejection.pod
        @test Control.pending(mailbox) == (Control.RUN, 5, true)

        # Apply and publish the accepted pending request; an older identity is
        # then rejected with ESTALE, preserving kind/token in the fourth POD.
        @test Control.apply!(state, Control.RUN, 5, true, UInt64(140), UInt64(20), reset_owner) == 0
        @test Control.publish!(mailbox, stream, Control.RUN, 5, Int32(0), state, 1) === nothing
        stale_request = run_control_request(4, :stopped)
        @test deliver_source_parameter(stream, SPA.PARAM_PROPS, stale_request) === nothing
        @test mailbox.rejected_kind == Control.RUN
        @test mailbox.rejected_token == 4
        @test mailbox.rejected_result == -Base.Libc.ESTALE
        @test Control.publish_rejection!(mailbox, stream, state, 1) === nothing
        @test source_rejection(mailbox)[3:6] == (Control.RUN, 4, -Base.Libc.ESTALE, 1)

        # Warm and measure successful run, reset, and query owner calls.
        @test Control.apply!(state, Control.RUN, 6, false, UInt64(150), UInt64(20), reset_owner) == 0
        @test source_apply_bytes(state, Control.RUN, 7, false, UInt64(151), UInt64(20), reset_owner) == 0
        @test source_apply_bytes(state, Control.RUN, 8, false, UInt64(152), UInt64(20), reset_owner) == 0
        state.sequence = 3
        state.completed = true
        @test Control.apply!(state, Control.RESET, 9, false, UInt64(153), UInt64(20), reset_owner) == 0
        @test source_apply_bytes(state, Control.RESET, 10, false, UInt64(154), UInt64(20), reset_owner) == 0
        @test source_apply_bytes(state, Control.RESET, 11, false, UInt64(155), UInt64(20), reset_owner) == 0
        @test Control.apply!(state, Control.QUERY, 12, false, UInt64(156), UInt64(20), reset_owner) == 0
        @test source_apply_bytes(state, Control.QUERY, 13, false, UInt64(157), UInt64(20), reset_owner) == 0
        @test source_apply_bytes(state, Control.QUERY, 14, false, UInt64(158), UInt64(20), reset_owner) == 0

        @test Control.publish!(mailbox, stream, Control.RUN, 14, Int32(0), state, 1) === nothing
        @test source_publish_bytes(mailbox, stream, Control.RUN, 15, Int32(0), state, Int64(1)) == 0
        @test source_publish_bytes(mailbox, stream, Control.RUN, 16, Int32(0), state, Int64(1)) == 0
        @test Control.publish!(mailbox, stream, Control.RESET, 17, Int32(0), state, 1) === nothing
        @test source_publish_bytes(mailbox, stream, Control.RESET, 18, Int32(0), state, Int64(1)) == 0
        @test source_publish_bytes(mailbox, stream, Control.RESET, 19, Int32(0), state, Int64(1)) == 0
        @test Control.publish!(mailbox, stream, Control.QUERY, 20, Int32(0), state, 1) === nothing
        @test source_publish_bytes(mailbox, stream, Control.QUERY, 21, Int32(0), state, Int64(1)) == 0
        @test source_publish_bytes(mailbox, stream, Control.QUERY, 22, Int32(0), state, Int64(1)) == 0

        Control.reject!(mailbox, Control.INVALID, 0, Int32(-Base.Libc.EINVAL))
        @test Control.publish_rejection!(mailbox, stream, state, 1) === nothing
        Control.reject!(mailbox, Control.INVALID, 0, Int32(-Base.Libc.EINVAL))
        @test source_rejection_bytes(mailbox, stream, state, 1) == 0
        Control.reject!(mailbox, Control.INVALID, 0, Int32(-Base.Libc.EINVAL))
        @test source_rejection_bytes(mailbox, stream, state, 1) == 0
    finally
        close(stream)
        close(core)
        close(context)
    end
end
