module CalibrationAcquisition

using AdaptiveOpticsSim
using AdaptiveOpticsSim.AlgorithmGraphs
using AdaptiveOpticsSimPipeWireHIL
using PipeWireAO
using TOML

const REQUESTED_SCHEMA = "org.calculon.ao.requested-pdm-command/1"
const FEEDBACK_SCHEMA = "org.calculon.ao.pdm-constraint-feedback/1"
const PlantBackends = AdaptiveOpticsSim.Backends

function validate_exposure_duration(detector_config, exposure_ns::UInt64)
    scaled = Float64(detector_config["exposure_duration_s"]) * 1e9
    isfinite(scaled) && 0 < scaled < Float64(typemax(Int64)) ||
        throw(ArgumentError("declared detector exposure must fit positive model nanoseconds"))
    declared = round(Int64, scaled)
    declared > 0 && UInt64(declared) == exposure_ns ||
        throw(ArgumentError("transport exposure duration differs from the declared detector exposure"))
    return nothing
end

"""Stationary calibration illumination with the installed, noisy ADC detector."""
function prepare_science(path, plant_module, target, profile::Symbol;
    period_ns::UInt64, illumination::Symbol=:lamp,
)
    profile in (:classic, :copper) || throw(ArgumentError("unknown calibration profile"))
    illumination in (:lamp, :dark) || throw(ArgumentError("illumination must be lamp or dark"))
    document = TOML.parsefile(path)
    sensor = profile === :classic ? :shwfs : :pwfs
    [node["name"] for node in document["nodes"]] ==
        ["atmosphere", "pdm", "pupil_opd_composition", String(sensor), "detector"] ||
        error("calibration requires the maintained five-node production plant")
    plant_module.command_count() == 277 || error("plant command count differs")
    pdm_command = PlantBackends.allocate_device_array(target, Float32, 277)
    fill!(pdm_command, 0.0f0)
    indices = plant_module.actuator_grid_indices()
    pdm_actuator_grid_indices = PlantBackends.allocate_device_array(target,
        eltype(indices), size(indices)...)
    copyto!(pdm_actuator_grid_indices, indices)
    production = load_algorithm_graph(path; bindings=(; pdm_command, pdm_actuator_grid_indices))
    detector = production.nodes[5]
    detector.config.binning == 1 || error("calibration requires detector binning=1")
    extent = profile === :classic ? 352 : 64
    (detector.config.rows, detector.config.columns) == (extent, extent) ||
        error("production detector geometry differs from the calibration profile")
    definition = if illumination === :lamp
        resolution = Int(document["nodes"][3]["config"]["resolution"])
        uncompensated_opd = PlantBackends.allocate_device_array(target, Float32, resolution, resolution)
        fill!(uncompensated_opd, 0.0f0)
        algorithm_graph(production.nodes[2:5]; name=:operational_calibration_lamp,
            inputs=(first(production.inputs), graph_input(:uncompensated_opd,
                :pupil_opd_composition => :uncompensated_opd, uncompensated_opd)),
            outputs=(graph_output(:frame, :detector => :frame),),
            links=(link(:pdm => :surface_opd, :pupil_opd_composition => :surface_opd),
                link(:pupil_opd_composition => :pupil_opd, sensor => :opd),
                link(sensor => :photon_rate, :detector => :photon_rate)),
            parameters=production.parameters)
    else
        photons = PlantBackends.allocate_device_array(target, Float32, extent, extent)
        fill!(photons, 0.0f0)
        algorithm_graph((production.nodes[2], detector); name=:operational_calibration_dark,
            inputs=(first(production.inputs), graph_input(:zero_photon_rate,
                :detector => :photon_rate, photons)),
            outputs=(graph_output(:frame, :detector => :frame),),
            parameters=production.parameters)
    end
    graph = prepare_algorithm_graph(definition; target, execution=StreamGraphExecution())
    boundary = prepare_graph_calibration_boundary(graph; command_input=:pdm_command, frame_output=:frame)
    driver = FixedStepModelTimeDriver(PeriodicSchedule(; period_ns))
    # Compile science and host staging before any operational endpoint exists.
    adopt_hil_probe!(boundary, UInt64(1))
    step_hil_exposure_at!(boundary, driver)
    reset_hil_boundary!(boundary, driver)
    return (; graph, boundary, driver, target, illumination,
        detector_config=document["nodes"][5]["config"])
end

mutable struct AcquisitionState
    probe_sequence::UInt64
    publication::Union{Nothing,Task}
    progressing::Threads.Atomic{Bool}
    cursor_sequence::UInt64
    cursor_model_ns::UInt64
    held::Bool
    failed::Bool
    closed::Bool
end
AcquisitionState() = AcquisitionState(0, nothing, Threads.Atomic{Bool}(false), 0, 0, false, false, false)

"""Bounded acquisition diagnostics, including discarded settling exposures.

The owner scans the already received raw ADC array outside SPA callbacks. These
counters expose clipping; they do not change WFS validity or invent an optical
acceptance threshold.
"""
mutable struct ExposureDiagnostics
    adc_upper_rail::Union{Nothing,UInt16}
    frames::UInt64
    invalid_frames::UInt64
    maximum_adc::UInt16
    upper_rail_pixels::UInt64
    upper_rail_frames::UInt64
end
function ExposureDiagnostics(adc_bits::Union{Nothing,Integer}=nothing)
    adc_bits === nothing || (!(adc_bits isa Bool) && 1 <= adc_bits <= 16) ||
        throw(ArgumentError("ADC width requires 1..16 bits"))
    rail = adc_bits === nothing ? nothing : UInt16((UInt32(1) << adc_bits) - 1)
    return ExposureDiagnostics(rail, 0, 0, 0, 0, 0)
end
function record_exposure!(diagnostics::ExposureDiagnostics, raw::AbstractVector{UInt16}, valid::Bool)
    isempty(raw) && throw(ArgumentError("empty raw detector exposure"))
    peak = maximum(raw)
    rail = diagnostics.adc_upper_rail
    rail === nothing || peak <= rail || error("ADC payload exceeds declared detector rail")
    hits = rail === nothing ? 0 : count(==(rail), raw)
    diagnostics.frames = Base.checked_add(diagnostics.frames, UInt64(1))
    diagnostics.invalid_frames = Base.checked_add(diagnostics.invalid_frames, UInt64(!valid))
    diagnostics.maximum_adc = max(diagnostics.maximum_adc, peak)
    diagnostics.upper_rail_pixels = Base.checked_add(diagnostics.upper_rail_pixels, UInt64(hits))
    diagnostics.upper_rail_frames = Base.checked_add(diagnostics.upper_rail_frames, UInt64(hits > 0))
    return nothing
end
function exposure_diagnostics(session)
    value = session.diagnostics
    return (; raw_available=session.raw !== nothing, adc_upper_rail=value.adc_upper_rail,
        frames=value.frames, invalid_frames=value.invalid_frames, maximum_adc=value.maximum_adc,
        upper_rail_pixels=value.upper_rail_pixels, upper_rail_frames=value.upper_rail_frames,
        scope="all completed exposures including settling; descriptive ADC diagnostics, no scientific acceptance")
end

"""Initial calibration composition; scientific work stays outside callbacks."""
struct AcquisitionSession{Plant,Driver,Source,Feedback,Responses,Raw,Active}
    plant::Plant
    driver::Driver
    source::Source
    feedback::Feedback
    responses::Responses
    raw::Raw
    profile::Symbol
    active::Active
    domain::AcquisitionDomain
    state::AcquisitionState
    diagnostics::ExposureDiagnostics
end

function response_sinks(core, ::Val{:classic}, rate)
    slopes = flux = validity = nothing
    try
        slopes = NdArraySink(core, "calibration-slopes", zeros(Float32, 376),
            NdArrayFormat(NdArray.F32_LE, (188, 2); rate, layout=NdArray.ROW_MAJOR);
            schema="org.calculon.ao.shack-hartmann-slopes/1")
        flux = NdArraySink(core, "calibration-flux", zeros(Float32, 188),
            NdArrayFormat(NdArray.F32_LE, (188,); rate, layout=NdArray.ROW_MAJOR);
            schema="org.calculon.ao.shack-hartmann-flux/1")
        validity = NdArraySink(core, "calibration-validity", fill(false, 188),
            NdArrayFormat(NdArray.BOOL8, (188,); rate, layout=NdArray.ROW_MAJOR);
            schema="org.calculon.ao.shack-hartmann-validity/1")
        return (slopes, flux, validity)
    catch
        close_endpoints((validity, flux, slopes))
        rethrow()
    end
end

function response_sinks(core, ::Val{:copper}, rate)
    pixels = intensity = nothing
    try
        pixels = NdArraySink(core, "calibration-reconstruction-pixels", zeros(Float32, 3600),
            NdArrayFormat(NdArray.F32_LE, (4, 900); rate, layout=NdArray.ROW_MAJOR);
            schema="org.calculon.ao.pyramid-reconstruction-pixels/1")
        intensity = NdArraySink(core, "calibration-mean-pupil-intensity", zeros(Float32, 1),
            NdArrayFormat(NdArray.F32_LE, (1,); rate, layout=NdArray.ROW_MAJOR);
            schema="org.calculon.ao.pyramid-mean-pupil-intensity/1")
        return (pixels, intensity)
    catch
        close_endpoints((intensity, pixels))
        rethrow()
    end
end

function close_endpoints(endpoints)
    failure = nothing
    for endpoint in endpoints
        endpoint === nothing && continue
        try
            close(endpoint)
        catch exception
            failure === nothing && (failure = exception)
        end
    end
    failure === nothing || throw(failure)
    return nothing
end

prepare_active(::Val{:classic}, ::Nothing) = fill(true, 188)
function prepare_active(::Val{:classic}, active::Vector{Bool})
    length(active) == 188 || throw(DimensionMismatch("Classic active selection requires 188 entries"))
    any(active) || throw(ArgumentError("Classic active selection is empty"))
    return copy(active)
end
prepare_active(::Val{:copper}, ::Nothing) = nothing
prepare_active(profile, active) = throw(ArgumentError("unsupported WFS active selection"))

function prepare_session(plant, driver, profile::Symbol; rate, capture_raw=true, active=nothing, adc_bits=nothing)
    profile in (:classic, :copper) || throw(ArgumentError("unknown calibration profile"))
    selection = prepare_active(Val(profile), active)
    source = feedback = raw = nothing
    responses = ()
    try
        core = plant.core
        source = NdArraySource(core, "calibration-probe", zeros(Float32, 277),
            NdArrayFormat(NdArray.F32_LE, (277,); rate, layout=NdArray.ROW_MAJOR);
            schema=REQUESTED_SCHEMA)
        feedback = NdArraySink(core, "calibration-feedback", zeros(Float32, 277),
            NdArrayFormat(NdArray.F32_LE, (277,); rate, layout=NdArray.ROW_MAJOR);
            schema=FEEDBACK_SCHEMA)
        responses = response_sinks(core, Val(profile), rate)
        if capture_raw
            extent = profile === :classic ? 352 : 64
            raw = NdArraySink(core, "calibration-raw", zeros(UInt16, extent * extent),
                NdArrayFormat(NdArray.U16_LE, (extent, extent); rate, layout=NdArray.ROW_MAJOR);
                schema="org.calculon.ao.raw-detector-pixels/1")
        end
        return AcquisitionSession(plant, driver, source, feedback, responses, raw,
            profile, selection, pipewire_calibration_status(plant).acquisition_domain, AcquisitionState(),
            ExposureDiagnostics(adc_bits))
    catch
        close_endpoints((raw, responses..., feedback, source))
        rethrow()
    end
end

function start_session!(session)
    require_usable(session)
    try
        for endpoint in (session.feedback, session.responses..., session.raw, session.source)
            endpoint === nothing || start!(endpoint)
        end
        start!(session.plant)
        return session
    catch
        session.state.failed = true
        close_session!(session)
        rethrow()
    end
end

function deadline(timeout_ns::UInt64)
    0 < timeout_ns <= UInt64(typemax(Int64)) || throw(ArgumentError("invalid operation timeout"))
    return Base.checked_add(time_ns(), timeout_ns)
end

function remaining(until::UInt64)
    now = time_ns()
    now < until || error("calibration operation deadline expired")
    return until - now
end

function require_usable(session)
    session.state.closed && error("calibration session is closed")
    session.state.failed && error("calibration session is faulted; ownership remains held")
    pipewire_calibration_status(session.plant).failed && error("plant transport failed")
    return nothing
end

function cursor(session)
    status = pipewire_calibration_status(session.plant)
    isequal(status.acquisition_domain, session.domain) || error("calibration acquisition domain changed")
    # Domain 1 is an explicit session-local mapping of the complete UUID above.
    # It is never obtained by truncating or hashing the UUID.
    return (; domain=UInt64(1), generation=status.acquisition_generation,
        sequence=session.state.cursor_sequence, model_ns=session.state.cursor_model_ns)
end

function hold!(session)
    require_usable(session)
    # This initial-calibration topology has no ordinary controller or command
    # producer. The deployment owner must establish that topology before Hold.
    session.state.held = true
    return cursor(session)
end

function release!(session)
    require_usable(session)
    pipewire_calibration_status(session.plant).pending_exposure === nothing ||
        error("cannot release ownership with a pending exposure")
    session.state.publication === nothing || istaskdone(session.state.publication) ||
        error("cannot release ownership with pending publication")
    session.state.held = false
    return nothing
end

function fault!(session)
    session.state.failed = true
    session.state.held = true
    return nothing
end

struct SubmitProbe{Session,Figure}
    session::Session
    figure::Figure
    sequence::UInt64
    until::UInt64
end

function drive_until_receipt!(session, stream, until)
    while session.state.progressing[]
        remaining(until)
        with_thread_loop_lock(main_loop(stream)) do _
            trigger_process!(stream)
        end
        # Native asynchronous followers may need another driver cycle after
        # publication. This retries transport progress; it never re-arms a
        # producer, republishes a probe or advances the scientific model.
        sleep(0.001)
    end
    return nothing
end

function finish_progress!(session)
    session.state.progressing[] = false
    publication = session.state.publication
    publication === nothing || fetch(publication)
    session.state.publication = nothing
    return nothing
end

function (submit::SubmitProbe)()
    session = submit.session
    token = submit_array!(session.source, submit.figure,
        BufferHeader(UInt32(0), UInt32(0), Int64(0), Int64(0), submit.sequence))
    # The publisher must make progress while adoption independently awaits
    # actual command receipt. Submission itself never waits for publication.
    session.state.publication = @async begin
        wait_array_source!(session.source, token; timeout_ns=remaining(submit.until))
        drive_until_receipt!(session, session.source.stream, submit.until)
    end
    return nothing
end

function adopt_probe!(session, figure::Vector{Float32}; timeout_ns::UInt64)
    require_usable(session)
    session.state.held || error("calibration ownership is not held")
    length(figure) == 277 && all(isfinite, figure) || error("invalid prepared command figure")
    until = deadline(timeout_ns)
    sequence = Base.checked_add(session.state.probe_sequence, UInt64(1))
    try
        arm_array_sink!(session.feedback, sequence)
        session.state.progressing[] = true
        adopt_pipewire_probe!(session.plant, sequence;
            submit=SubmitProbe(session, figure, sequence, until), timeout_ns=remaining(until))
        wait_array_sink!(session.feedback; timeout_ns=remaining(until))
        demanded = pipewire_probe_values(session.plant)
        feedback = array_values(session.feedback)
        validate_command_feedback(figure, demanded, feedback)
        finish_progress!(session)
        remaining(until)
        session.state.probe_sequence = sequence
        return (; cursor=cursor(session), figure=copy(demanded),
            clipped=any(!iszero, feedback) || demanded != figure)
    catch
        session.state.progressing[] = false
        session.state.failed = true
        rethrow()
    end
end

function validate_command_feedback(requested, demanded, feedback)
    length(requested) == length(demanded) == length(feedback) ||
        throw(DimensionMismatch("command feedback extents differ"))
    for index in eachindex(requested, demanded, feedback)
        isfinite(demanded[index]) && isfinite(feedback[index]) || error("nonfinite command evidence")
        feedback[index] == requested[index] - demanded[index] || error("constraint feedback disagrees with demanded command")
    end
    return nothing
end

struct ArmResponses{Session}
    session::Session
end
function (arm::ArmResponses)(exposure)
    for sink in (arm.session.responses..., arm.session.raw)
        sink === nothing || arm_array_sink!(sink, exposure.identity;
            exposure_duration_ns=exposure.exposure_duration_nanoseconds)
    end
    return nothing
end

function classic_response_valid(slopes, flux, validity, active)
    length(slopes) == 376 && length(flux) == length(validity) == length(active) == 188 ||
        throw(DimensionMismatch("Classic response extents differ"))
    any(active) || throw(ArgumentError("Classic active selection is empty"))
    all(isfinite, slopes) && all(isfinite, flux) || error("nonfinite Classic WFS output")
    # Intrinsic validity and flux for every ROI remain available to the owner.
    # Selection must equal the deployed WFS active parameter; excluded rows
    # remain in the full measurement order and cannot become accepted samples.
    return all(index -> !active[index] || (validity[index] && flux[index] > 0.0f0), eachindex(active))
end
function response_valid(::Val{:classic}, responses, active)
    slopes, flux, validity = map(array_values, responses)
    return classic_response_valid(slopes, flux, validity, active)
end
function response_valid(::Val{:copper}, responses, ::Nothing)
    pixels, intensity = map(array_values, responses)
    all(isfinite, pixels) && all(isfinite, intensity) || error("nonfinite Copper WFS output")
    return only(intensity) > 0.0f0
end

function acquire_exposure!(session; timeout_ns::UInt64, require_valid=true)
    require_usable(session)
    session.state.held || error("calibration ownership is not held")
    until = deadline(timeout_ns)
    try
        exposure = step_pipewire_exposure!(session.plant, session.driver;
            before_publish=ArmResponses(session), timeout_ns=remaining(until))
        session.state.progressing[] = true
        session.state.publication = @async drive_until_receipt!(
            session, session.plant.frame_stream, until)
        for sink in (session.responses..., session.raw)
            sink === nothing && continue
            receipt = wait_array_sink!(sink; timeout_ns=remaining(until))
            isequal(receipt.identity, exposure.identity) || error("response identity differs from exposure")
            receipt.exposure_duration_ns == exposure.exposure_duration_nanoseconds || error("response exposure duration differs")
        end
        valid = response_valid(Val(session.profile), session.responses, session.active)
        session.raw === nothing || record_exposure!(session.diagnostics, array_values(session.raw), valid)
        require_valid && !valid && error("invalid WFS measurement")
        finish_progress!(session)
        remaining(until)
        start_ns = model_nanoseconds(exposure.timestamp)
        start_ns >= 0 || error("negative model timestamp")
        end_ns = Base.checked_add(UInt64(start_ns), exposure.exposure_duration_nanoseconds)
        complete_pipewire_exposure!(session.plant, exposure.identity)
        session.state.cursor_sequence = exposure.identity.sequence
        session.state.cursor_model_ns = end_ns
        return (; exposure, valid)
    catch
        session.state.progressing[] = false
        session.state.failed = true
        rethrow()
    end
end

function close_session!(session)
    session.state.closed && return nothing
    session.state.closed = true
    session.state.progressing[] = false
    try
        # Closing the producer wakes its bounded publication waiter. Join before
        # destroying the plant so no owner publication task survives teardown.
        close_endpoints((session.source, session.raw, session.responses..., session.feedback))
    finally
        try
            publication = session.state.publication
            if publication !== nothing
                try
                    fetch(publication)
                catch
                    # Publication cancellation is expected during fault teardown.
                    session.state.failed = true
                end
                session.state.publication = nothing
            end
        finally
            close(session.plant)
        end
    end
    return nothing
end

end
