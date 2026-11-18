module MultirateMeasurement

using PipeWireAORTC
using Statistics: mean, quantile
using TOML

export Observer, record_optical!, record_native!, finish!

const FITS = PipeWireAORTC.InstrumentConfiguration.FITSIO.FITS
const REGION = "generated/dual-calibration/scc/artifacts/scc-pixel-mask.fits"
const DEMAND = Symbol("dm-command")
const FEEDBACK = Symbol("constraint-feedback")
const LLOWFS = Symbol("llowfs-modal-residual")
const SCC = Symbol("modal-residual")
const PAIR_STATUS = Symbol("pair-status")
const Identity = NamedTuple{(:domain, :generation, :sequence),Tuple{String,UInt64,UInt64}}

struct OpticalSample
    tick::Int
    phase::Symbol
    camera::Symbol
    published::Bool
    model_pts_ns::Int64
    duration_ns::UInt64
    sequence::UInt64
    chopping::Symbol
    contrast::Union{Nothing,Float64}
    identity::Union{Nothing,Identity}
end

struct NativeSample
    tick::Int
    phase::Symbol
    stream::Symbol
    pts_ns::Int64
    identity::Union{Nothing,Identity}
    payload::Vector{Float32}
end

struct Observer
    pixels::Vector{CartesianIndex{2}}
    peak_electrons::Float64
    command_limit::Float32
    optical::Vector{OpticalSample}
    native::Vector{NativeSample}
end

"""
    Observer(app; photometry, command_limit=0.5f0)

Load the sealed 112-mode dark-hole mask and fitted unocculted stellar peak.
"""
function Observer(app; photometry=joinpath(@__DIR__, "photometry.toml"), command_limit=0.5f0)
    mask = FITS(joinpath(app, REGION)) do file
        permutedims(read(file[1]))
    end
    size(mask) == (221, 221) && all(in((0, 1)), mask) || error("Invalid sealed dark-hole mask")
    pixels = findall(!iszero, mask)
    length(pixels) == 12_703 || error("Unexpected sealed dark-hole pixel count")
    photometry_data = TOML.parsefile(photometry)
    peak_electrons = photometry_data["unocculted_star_peak"] * photometry_data["exposure_seconds"] *
        photometry_data["photons_per_second_per_unit_intensity"] * photometry_data["quantum_efficiency"]
    return Observer(pixels, peak_electrons, Float32(command_limit), OpticalSample[], NativeSample[])
end

identity_record(::Nothing) = nothing

function identity_record(identity)
    bytes = hasproperty(identity.domain, :bytes) ? identity.domain.bytes : identity.domain
    return (; domain=bytes2hex(collect(bytes)), generation=UInt64(identity.generation),
        sequence=UInt64(identity.sequence))
end

"""
    record_optical!(observer; tick, phase, camera, image, metadata, published, identity=nothing)

Record a physical camera exposure. Pass the submitted acquisition identity when the
producer publishes this exposure. Compute normalized contrast for unfringed SCC images.
"""
function record_optical!(observer::Observer; tick, phase, camera, image, metadata, published,
        identity=nothing)
    chopping = hasproperty(metadata, :chopped_image_kind) ?
        something(metadata.chopped_image_kind, :absent) : :absent
    contrast = nothing
    if camera === :scc && chopping === :unfringed
        isfinite_image = all(pixel -> isfinite(image[pixel]), observer.pixels)
        isfinite_image || error("Nonfinite dark-hole pixel at tick $tick")
        contrast = mean(pixel -> Float64(image[pixel]), observer.pixels) / observer.peak_electrons
    end
    push!(observer.optical, OpticalSample(tick, phase, camera, published, metadata.pts,
        metadata.duration, metadata.sequence, chopping, contrast, identity_record(identity)))
    return nothing
end

"""
    record_native!(observer; tick, phase, name, payload, identity, pts)

Retain a decoded output from the native controller and its transport receipt.
`tick` identifies the harness event that the receipt was collected for.
"""
function record_native!(observer::Observer; tick, phase, name, payload, identity, pts)
    values = Float32.(vec(payload))
    all(isfinite, values) && !isempty(values) || error("Invalid $name sample at tick $tick")
    if name in (DEMAND, FEEDBACK)
        length(values) == 468 || error("Invalid $name extent at tick $tick")
    elseif name in (LLOWFS, SCC)
        length(values) == 114 || error("Invalid $name extent at tick $tick")
        if name === LLOWFS
            all(iszero, view(values, 3:length(values))) || error("Unexpected non-tip/tilt LLOWFS residual")
        end
    elseif name === PAIR_STATUS
        length(values) == 1 && only(values) in (0, 1) || error("Invalid SCC pair status")
    end
    push!(observer.native, NativeSample(tick, phase, name, pts, identity_record(identity), values))
    return nothing
end

identity_columns(::Nothing) = (nothing, nothing, nothing)
identity_columns(identity::Identity) = Tuple(identity)
identity_key(sample) = (sample.identity, sample.pts_ns)
adjacent(a, b) = a !== nothing && b !== nothing && a.domain == b.domain &&
    a.generation == b.generation && a.sequence + 1 == b.sequence

function write_csv(io, fields)
    println(io, join((value === nothing ? "" : value for value in fields), ','))
    return nothing
end

function write_optical(path, samples)
    open(path, "w") do io
        println(io, "tick,phase,camera,published,model_pts_ns,duration_ns,sequence,chopping,contrast,domain,generation,published_sequence")
        for sample in samples
            write_csv(io, (sample.tick, sample.phase, sample.camera, sample.published,
                sample.model_pts_ns, sample.duration_ns, sample.sequence, sample.chopping,
                sample.contrast, identity_columns(sample.identity)...))
        end
    end
    return nothing
end

function write_native(path, samples)
    open(path, "w") do io
        println(io, "tick,phase,stream,pts_ns,domain,generation,sequence,tip_m,tilt_m,llowfs_norm_m,peak_native,first_value")
        for sample in samples
            tip = tilt = norm = peak = nothing
            if sample.stream === LLOWFS
                tip, tilt = Float64(sample.payload[1]), Float64(sample.payload[2])
                norm = hypot(tip, tilt)
            elseif sample.stream in (DEMAND, FEEDBACK)
                peak = maximum(abs, sample.payload)
            end
            write_csv(io, (sample.tick, sample.phase, sample.stream, sample.pts_ns,
                identity_columns(sample.identity)..., tip, tilt, norm, peak, first(sample.payload)))
        end
    end
    return nothing
end

function measure_commands(observer)
    feedback = Dict{Tuple{Identity,Int64},NativeSample}()
    for sample in observer.native
        sample.stream === FEEDBACK && sample.identity !== nothing || continue
        key = identity_key(sample)
        haskey(feedback, key) && error("Duplicate physical limiter feedback receipt at tick $(sample.tick)")
        feedback[key] = sample
    end
    seen = Set{Tuple{Identity,Int64}}()
    rows = NamedTuple[]
    previous = nothing
    for sample in observer.native
        sample.stream === DEMAND || continue
        key = identity_key(sample)
        if sample.identity !== nothing
            key in seen && error("Duplicate demand receipt at tick $(sample.tick)")
            push!(seen, key)
        end
        demand = sample.payload
        peak = maximum(abs, demand)
        bounded = peak <= observer.command_limit
        step_inf = step_rms = nothing
        if previous !== nothing && adjacent(previous.identity, sample.identity)
            step = Float64.(demand) .- previous.payload
            step_inf = maximum(abs, step)
            step_rms = sqrt(mean(abs2, step))
        end
        requested_peak = clipped_actuators = feedback_peak = clamp_consistent = nothing
        witness_actuator = witness_demand = witness_feedback = nothing
        paired = get(feedback, key, nothing)
        if paired !== nothing
            sample.tick == paired.tick && sample.phase === paired.phase || error("Limiter receipt event mismatch at $key")
            correction = paired.payload
            requested = Float64.(demand) .+ correction
            feedback_peak = maximum(abs, correction)
            requested_peak = maximum(abs, requested)
            clipped_actuators = count(!iszero, correction)
            limit = observer.command_limit
            clamp_consistent = all(eachindex(demand)) do i
                demand[i] == clamp(requested[i], -limit, limit) &&
                    (iszero(correction[i]) || (abs(demand[i]) == limit && sign(demand[i]) == sign(correction[i])))
            end
            if clipped_actuators > 0
                witness_actuator = argmax(abs.(correction))
                witness_demand = demand[witness_actuator]
                witness_feedback = correction[witness_actuator]
            end
        end
        push!(rows, (; sample.tick, sample.phase, sample.pts_ns, sample.identity, peak, step_inf,
            step_rms, requested_peak, clipped_actuators, feedback_peak, bounded, clamp_consistent,
            witness_actuator, witness_demand, witness_feedback))
        previous = sample
    end
    return rows, length(setdiff(keys(feedback), seen))
end

function write_commands(path, rows)
    open(path, "w") do io
        println(io, "tick,phase,pts_ns,domain,generation,sequence,peak_native,step_inf_native,step_rms_native,requested_peak_native,clipped_actuators,feedback_peak_native,bounded,clamp_consistent,witness_actuator,witness_demand_native,witness_feedback_native")
        for row in rows
            write_csv(io, (row.tick, row.phase, row.pts_ns, identity_columns(row.identity)...,
                row.peak, row.step_inf, row.step_rms, row.requested_peak, row.clipped_actuators,
                row.feedback_peak, row.bounded, row.clamp_consistent, row.witness_actuator,
                row.witness_demand, row.witness_feedback))
        end
    end
    return nothing
end

function describe(values)
    isempty(values) && return (; count=0)
    return (; count=length(values), mean=mean(values), rms=sqrt(mean(abs2, values)),
        p95=quantile(values, 0.95), maximum=maximum(values))
end

function phase_summary(phase, observer, commands)
    optical = filter(row -> row.phase === phase, observer.optical)
    native = filter(row -> row.phase === phase, observer.native)
    command = filter(row -> row.phase === phase, commands)
    lo, hi = extrema(row.tick for row in optical)
    late_start = lo + cld(hi - lo + 1, 2)
    scc = filter(row -> row.camera === :scc, optical)
    llowfs = filter(row -> row.camera === :llowfs, optical)
    function sensor_counts(rows)
        submitted = filter(row -> row.published, rows)
        intervals = diff([row.model_pts_ns for row in submitted])
        return (; modeled=length(rows), submitted=length(submitted),
            submitted_model_interval_ns=describe(intervals))
    end
    diagnostic(stream) = filter(row -> row.stream === stream, native)
    lres = diagnostic(LLOWFS)
    sres = diagnostic(SCC)
    pairs = diagnostic(PAIR_STATUS)
    lnorm(rows) = [hypot(Float64(row.payload[1]), Float64(row.payload[2])) for row in rows]
    contrasts(rows) = [row.contrast for row in rows if row.contrast !== nothing]
    function overlap(exposures, receipts)
        submitted = Set((row.identity, row.model_pts_ns) for row in exposures
            if row.published && row.identity !== nothing)
        return count(row -> (row.identity, row.pts_ns) in submitted, receipts)
    end
    feedback_pairs = filter(row -> row.clamp_consistent !== nothing, command)
    clipped = filter(row -> row.clipped_actuators > 0, feedback_pairs)
    result = (; first_tick=lo, last_tick=hi, late_start_tick=late_start,
        scc=sensor_counts(scc), llowfs=sensor_counts(llowfs),
        pair_status_receipts=length(pairs), completed_pairs=count(row -> only(row.payload) == 1, pairs),
        scc_residual_receipts=length(sres), llowfs_residual_receipts=length(lres),
        scc_exact_pair_identity_matches=overlap(scc, pairs),
        scc_exact_residual_identity_matches=overlap(scc, sres),
        llowfs_exact_residual_identity_matches=overlap(llowfs, lres),
        llowfs_residual_m=describe(lnorm(lres)),
        late_llowfs_residual_m=describe(lnorm(filter(row -> row.tick >= late_start, lres))),
        unfringed_contrast=describe(contrasts(scc)),
        late_unfringed_contrast=describe(contrasts(filter(row -> row.tick >= late_start, scc))),
        commands=length(command), adjacent_command_steps=count(row -> row.step_inf !== nothing, command),
        command_feedback_pairs=length(feedback_pairs), clipped_commands=length(clipped),
        late_clipped_commands=count(row -> row.tick >= late_start, clipped),
        command_peak_native=describe([row.peak for row in command]),
        command_step_inf_native=describe([row.step_inf for row in command if row.step_inf !== nothing]),
        command_step_rms_native=describe([row.step_rms for row in command if row.step_rms !== nothing]),
        reconstructed_request_peak_native=describe([row.requested_peak for row in feedback_pairs]))
    if !isempty(clipped)
        witness = argmax(row -> row.requested_peak, clipped)
        result = merge(result, (; saturation_witness=(; witness.tick, witness.pts_ns, witness.identity...,
            actuator=witness.witness_actuator, demanded_native=witness.witness_demand,
            feedback_native=witness.witness_feedback, requested_native=Float64(witness.witness_demand) + witness.witness_feedback,
            peak_requested_native=witness.requested_peak, clipped_actuators=witness.clipped_actuators)))
    end
    return result
end

function pair_history(observer; scc_resets=Int[])
    receipts = Dict{Tuple{Identity,Int64},NativeSample}()
    for row in observer.native
        row.stream === PAIR_STATUS && row.identity !== nothing || continue
        key = identity_key(row)
        haskey(receipts, key) && error("Duplicate SCC pair-status receipt at tick $(row.tick)")
        receipts[key] = row
    end
    previous = nothing
    missing = 0
    unexpected = 0
    priming_with_no_status = 0
    status_drained_after_event = 0
    first_after_dropout = nothing
    first_complete_after_dropout = nothing
    for row in observer.optical
        row.camera === :scc && row.published || continue
        if previous !== nothing && any(tick -> previous.tick < tick <= row.tick, scc_resets)
            previous = nothing
        end
        key = (row.identity, row.model_pts_ns)
        actual = pop!(receipts, key, nothing)
        expected = previous !== nothing && adjacent(previous.identity, row.identity) &&
            previous.duration_ns == row.duration_ns &&
            ((previous.chopping === :fringed && row.chopping === :unfringed) ||
             (previous.chopping === :unfringed && row.chopping === :fringed))
        complete = actual !== nothing && only(actual.payload) == 1
        if actual === nothing
            missing += expected
            priming_with_no_status += !expected
        else
            unexpected += complete != expected || actual.tick < row.tick
            status_drained_after_event += actual.tick > row.tick
        end
        if row.phase === :resume
            first_after_dropout = something(first_after_dropout, (; row.tick, complete))
            if complete
                first_complete_after_dropout = something(first_complete_after_dropout, row.tick)
            end
        end
        previous = row
    end
    result = (; missing, unexpected, unpaired=length(receipts), priming_with_no_status,
        status_drained_after_event)
    if first_after_dropout !== nothing
        result = merge(result, (; first_after_dropout))
    end
    if first_complete_after_dropout !== nothing
        result = merge(result, (; first_complete_after_dropout))
    end
    return result
end

function recovery_summary(commands)
    last_clipped = findlast(row -> row.clipped_actuators !== nothing && row.clipped_actuators > 0, commands)
    release = findfirst(row -> row.phase === :release, commands)
    (last_clipped === nothing || release === nothing) && return (; observed=false)
    next = max(last_clipped + 1, release)
    next > length(commands) && return (; observed=false, last_clipped_tick=commands[last_clipped].tick)
    tail = view(commands, next:length(commands))
    covered = all(row -> row.clipped_actuators === 0 && row.bounded && row.clamp_consistent === true, tail)
    consecutive = all(i -> adjacent(commands[i-1].identity, commands[i].identity), next + 1:length(commands))
    return (; observed=covered && consecutive, first_release_command_tick=commands[release].tick,
        last_clipped_tick=commands[last_clipped].tick, first_unclipped_tail_tick=first(tail).tick,
        release_to_unclipped_tail_ticks=first(tail).tick - commands[release].tick,
        sustained_unclipped_commands=length(tail), last_observed_tick=last(tail).tick,
        verified_feedback_pairs=covered, consecutive_identity=consecutive)
end

"""
    finish!(observer, outdir)

Write raw scalar receipts, paired native-command measurements and phase coverage.
Return the same summary record written to `measurement.json`.
"""
function finish!(observer::Observer, outdir; scc_resets=Int[])
    mkpath(outdir)
    commands, unpaired_feedback = measure_commands(observer)
    write_optical(joinpath(outdir, "optical.csv"), observer.optical)
    write_native(joinpath(outdir, "native.csv"), observer.native)
    write_commands(joinpath(outdir, "commands.csv"), commands)
    phases = unique(row.phase for row in observer.optical)
    phase_records = Dict(string(phase) => phase_summary(phase, observer, commands) for phase in phases)
    summary = (; dark_hole_pixels=length(observer.pixels), unocculted_peak_electrons=observer.peak_electrons,
        command_limit_native=observer.command_limit, phases=phase_records,
        native_commands=length(commands), unpaired_feedback,
        commands_with_source_pts=count(row -> row.pts_ns != typemin(Int64), commands),
        missing_command_feedback=count(row -> row.clamp_consistent === nothing, commands),
        out_of_bounds_commands=count(row -> !row.bounded, commands),
        inconsistent_clamps=count(row -> row.clamp_consistent === false, commands),
        scc_pair_history=pair_history(observer; scc_resets),
        recovery=recovery_summary(commands))
    PipeWireAORTC.Common.write_json(joinpath(outdir, "measurement.json"), summary; atomic=true)
    return summary
end

end
