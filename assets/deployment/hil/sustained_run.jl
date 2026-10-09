module SustainedRun
using ..SustainedMetrics
using ..CorrectionTruth

mutable struct Run{W}
    metrics::SustainedMetrics.Metrics
    truth::W
    sample_stride::Int
    sample_count::Int
    sample_sequences::Vector{UInt64}
    sample_model_ns::Vector{Int64}
    residual_variance_m2::Vector{Float64}
    atmosphere_variance_m2::Vector{Float64}
    detector_rail::UInt16
    adc_maximum::UInt16
    adc_rail_pixels::UInt64
    adc_rail_frames::UInt64
    missed_wall_periods::UInt64
    allocation_start::Union{Nothing,Base.GC_Num}
    allocation_finish::Union{Nothing,Base.GC_Num}
end

function Run(options, truth; detector_bits::Integer=options.profile === :classic ? 12 : 14)
    !(detector_bits isa Bool) && 1 <= detector_bits <= 16 || throw(ArgumentError("detector bits must fit UInt16"))
    total = options.total_exchanges
    stride = max(128, cld(total, 512))
    samples = truth === nothing ? 0 : cld(total, stride)
    Run(SustainedMetrics.Metrics(total; warmup=options.frames,
            wall_period_ns=options.wall_period_ns), truth, stride, 0,
        zeros(UInt64,samples), zeros(Int64,samples), zeros(Float64,samples), zeros(Float64,samples),
        UInt16((1 << detector_bits) - 1), UInt16(0), UInt64(0), UInt64(0), UInt64(0), nothing, nothing)
end

function reset!(run::Run)
    SustainedMetrics.reset!(run.metrics)
    run.sample_count = 0
    fill!(run.sample_sequences,0); fill!(run.sample_model_ns,0)
    fill!(run.residual_variance_m2,0); fill!(run.atmosphere_variance_m2,0)
    run.adc_maximum = run.adc_rail_pixels = run.adc_rail_frames = 0
    run.missed_wall_periods = 0
    run.allocation_start = run.allocation_finish = nothing
    nothing
end

function observe!(run::Run, sequence, model_ns, period_ns, timing, exchange_ns, command, frame)
    # Validate the actual declared detector encoding on every frame, even after
    # retention stops. No copied image or duration-sized array is constructed.
    maximum_code = UInt16(0)
    rails = UInt64(0)
    for value in frame
        isfinite(value) && 0 <= value <= run.detector_rail ||
            throw(ArgumentError("detector code exceeds declared ADC range"))
        code = round(UInt16,value)
        maximum_code = max(maximum_code,code)
        rails += code == run.detector_rail
    end
    SustainedMetrics.observe!(run.metrics,sequence,model_ns,period_ns,timing,exchange_ns,command)
    run.adc_maximum = max(run.adc_maximum,maximum_code)
    run.adc_rail_pixels += rails
    run.adc_rail_frames += rails > 0
    nothing
end

function sample!(run::Run, atmosphere, pupil, surface, sequence, model_ns)
    run.truth === nothing && return nothing
    sequence > run.metrics.warmup && (sequence % run.sample_stride == 0 || sequence == run.metrics.total) || return nothing
    index = run.sample_count + 1
    index <= length(run.sample_sequences) || throw(ArgumentError("sustained truth sample capacity exceeded"))
    staged = CorrectionTruth.stage!(run.truth,atmosphere,pupil,surface)
    atmosphere_variance = CorrectionTruth.pupil_variance(staged[1],run.truth.mask)
    residual_variance = CorrectionTruth.pupil_variance(staged[2],run.truth.mask)
    run.sample_sequences[index] = sequence
    run.sample_model_ns[index] = model_ns
    run.atmosphere_variance_m2[index] = atmosphere_variance
    run.residual_variance_m2[index] = residual_variance
    run.sample_count = index
    nothing
end

function allocation_report(run)
    run.allocation_start === nothing && return nothing
    run.allocation_finish === nothing && return nothing
    diff = Base.GC_Diff(run.allocation_finish,run.allocation_start)
    (; scope="entire simulator process after retained prefix; includes optics, transport, recording, diagnostics and controls; excludes final report serialization; interim controls and pause reports remain included",
        completed_exchanges=run.metrics.measured_count, allocated_bytes=diff.allocd,
        gc_time_ns=diff.total_time, gc_pauses=diff.pause, full_sweeps=diff.full_sweep,
        allocations=(; pool=diff.poolalloc, big=diff.bigalloc, malloc=diff.malloc, realloc=diff.realloc))
end

function report(run::Run)
    (; metrics=SustainedMetrics.report(run.metrics),
       detector=(; bits=trailing_ones(run.detector_rail), maximum_adc=run.adc_maximum,
           upper_rail_pixels=run.adc_rail_pixels, upper_rail_frames=run.adc_rail_frames),
       allocation=allocation_report(run),
       truth=(; enabled=run.truth !== nothing, sample_stride=run.sample_stride,
           scope="observed public simulated pupil variance at global sequences; sparse samples do not independently replay intervening commands; diagnostics excluded from capacity runs",
           samples=[(; sequence=run.sample_sequences[i], model_timestamp_ns=run.sample_model_ns[i],
               residual_variance_m2=run.residual_variance_m2[i], atmosphere_variance_m2=run.atmosphere_variance_m2[i]) for i in 1:run.sample_count]))
end
end
