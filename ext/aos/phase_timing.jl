const PhaseTiming = PipeWireAORTC.PhaseTiming

"Single-writer capture owned by the serialized simulator thread."
struct OwnerPhaseTiming
    capture::PhaseTiming.Capture
    exchange::PipeWireExchangeTiming
    allocated_bytes::Base.RefValue{Int64}
end

function prepare_phase_timing(options)
    directory = get(options, :phase_timing_directory, nothing)
    directory === nothing && return nothing
    return OwnerPhaseTiming(PhaseTiming.Capture(directory, options.phase_timing_warmup,
        options.phase_timing_frames, options.wall_period_ns, options.bootstrap_instance),
        PipeWireExchangeTiming(), Ref{Int64}(0))
end

exchange_timing(::Nothing) = nothing
exchange_timing(timing::OwnerPhaseTiming) =
    PhaseTiming.wants_sample(timing.capture) ? timing.exchange : nothing

save_phase_timing!(::Nothing) = nothing
save_phase_timing!(timing::OwnerPhaseTiming) = PhaseTiming.save!(timing.capture)
reset_phase_timing!(::Nothing, generation) = nothing
reset_phase_timing!(timing::OwnerPhaseTiming, generation) =
    PhaseTiming.reset!(timing.capture, UInt64(generation))

function record_phase_timing!(owner::OwnerPhaseTiming, timing::PipeWireExchangeTiming,
        frame::PipeWireFrameCommandTiming, deadline::UInt64, optical_finished::UInt64,
        next_deadline::UInt64)
    timing.sequence == frame.sequence || error("phase timing sequence differs from completed exchange")
    period = owner.capture.period_ns
    missed = period == 0 ? UInt64(0) :
        (next_deadline - Base.checked_add(deadline, period)) ÷ period
    Base.gc_bytes(owner.allocated_bytes)
    row = (timing.generation, timing.sequence, deadline, timing.started_ns,
        timing.ready_ns, timing.step_started_ns, timing.step_finished_ns, timing.staged_ns,
        UInt64(frame.source_published_nanoseconds), UInt64(frame.command_received_nanoseconds),
        timing.adoption_started_ns, timing.finished_ns, optical_finished, next_deadline,
        missed, Base.gc_time_ns(), UInt64(owner.allocated_bytes[]))
    PhaseTiming.record!(owner.capture, row)
    return nothing
end
