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
    # Nonempty reports first save during Reset or Quit. Compile that branch
    # before admission without writing a report or consuming capture samples.
    precompile(PhaseTiming.save!, (PhaseTiming.Capture,)) ||
        error("cannot compile prepared phase timing cleanup before admission")
    return OwnerPhaseTiming(
        PhaseTiming.Capture(
            directory,
            options.phase_timing_warmup,
            options.phase_timing_frames,
            options.pacing_period_ns,
            options.bootstrap_instance,
        ),
        PipeWireExchangeTiming(),
        Ref{Int64}(0),
    )
end

exchange_timing(::Nothing) = nothing
exchange_timing(timing::OwnerPhaseTiming) =
    PhaseTiming.wants_sample(timing.capture) ? timing.exchange : nothing

save_phase_timing!(::Nothing) = nothing
save_phase_timing!(timing::OwnerPhaseTiming) = PhaseTiming.save!(timing.capture)
reset_phase_timing!(::Nothing, generation) = nothing
reset_phase_timing!(timing::OwnerPhaseTiming, generation) =
    PhaseTiming.reset!(timing.capture, UInt64(generation))

function record_phase_timing!(
    owner::OwnerPhaseTiming,
    timing::PipeWireExchangeTiming,
    frame::PipeWireFrameCommandTiming,
    deadline::Int64,
    optical_finished::Int64,
    next_deadline::Int64,
)
    timing.sequence == frame.sequence ||
        error("phase timing sequence differs from completed exchange")
    # Saved rows and public HIL measurements retain their existing UInt64 ABI.
    # Negative injected pacing origins are supported without this optional capture;
    # a saved timing row cannot represent them and rejects before recording.
    saved_deadline = UInt64(deadline)
    saved_finished = UInt64(optical_finished)
    saved_next = UInt64(next_deadline)
    period = owner.capture.period_ns
    missed =
        period == 0 ? UInt64(0) :
        UInt64(div(widen(next_deadline) - (widen(deadline) + period), period))
    Base.gc_bytes(owner.allocated_bytes)
    row = (
        timing.generation,
        timing.sequence,
        saved_deadline,
        timing.started_ns,
        timing.ready_ns,
        timing.step_started_ns,
        timing.step_finished_ns,
        timing.staged_ns,
        UInt64(frame.source_published_nanoseconds),
        UInt64(frame.command_received_nanoseconds),
        timing.adoption_started_ns,
        timing.finished_ns,
        saved_finished,
        saved_next,
        missed,
        Base.gc_time_ns(),
        UInt64(owner.allocated_bytes[]),
    )
    PhaseTiming.record!(owner.capture, row)
    return nothing
end
