#!/usr/bin/env julia
# One complete-frame external plant owner. Scientific graphs and GPU work run
# on this owner; the integration package owns the PipeWire copy callbacks.
using AdaptiveOpticsSim
using AdaptiveOpticsSim.AlgorithmGraphs
using AdaptiveOpticsSimPipeWireHIL
using PipeWireAO
using SHA
using TOML

include("owner_protocol.jl")
include("native_heart_control.jl")
include("source_control.jl")
include("correction_truth.jl")
include("sustained_metrics.jl")
include("sustained_run.jl")
using .HILOwnerProtocol
const Protocol = HILOwnerProtocol
const SourceControl = HILSourceControl
const Backends = AdaptiveOpticsSim.Backends
const RAW_SCHEMA = "org.calculon.ao.raw-detector-pixels/1"
const COMMAND_SCHEMA = "org.calculon.ao.demanded-pdm-command/1"
const COMMAND_TO_METRES = 1.0f-6

function transport_contract(options)
    if get(options, :transport, :scientific) === :heart
        return (; frame_schema="org.heart.std-wfs.raw-pixels/1",
            command_schema="org.heart.std-dm.actuator-command/1",
            command_scale=1.0f0, command_units="metre OPD")
    end
    return (; frame_schema=RAW_SCHEMA, command_schema=COMMAND_SCHEMA,
        command_scale=COMMAND_TO_METRES, command_units="micrometre OPD")
end

function reset_controller!(options, request_id; timeout_seconds=14)
    get(options, :transport, :scientific) === :heart || return nothing
    # Native tokens belong to the bound controller, not the legacy request id.
    return HILHeartControl.reset!(options; timeout_seconds)
end

function load_plant(profile)
    if profile === :classic
        return @eval begin
            import REVOLTClassicSim
            REVOLTClassicSim
        end
    end
    return @eval begin
        import REVOLTCopperSim
        REVOLTCopperSim
    end
end

function load_target(backend)
    target = if backend === :cpu
        Backends.HostComputeDevice()
    elseif backend === :cuda
        @eval import CUDA
        Backends.AcceleratorComputeDevice(Backends.CUDABackend(), 0)
    else
        @eval import AMDGPU
        Backends.AcceleratorComputeDevice(Backends.AMDGPUBackend(), 1)
    end
    availability = Base.invokelatest(Backends.compute_device_availability, target)
    Backends.compute_device_is_available(availability) || error(
        "requested $backend backend is unavailable: $(Backends.compute_device_unavailable_reason(availability))",
    )
    return target
end

function copy_to_target(target, values)
    destination = Backends.allocate_device_array(target, eltype(values), size(values)...)
    copyto!(destination, values)
    return destination
end

function validate_graph_timing(options)
    definition = TOML.parsefile(options.graph)
    nodes = get(definition, "nodes", Any[])
    atmosphere = filter(node -> get(node, "name", "") == "atmosphere", nodes)
    length(atmosphere) == 1 || error("installed plant graph must contain exactly one atmosphere node")
    config = get(only(atmosphere), "config", Dict())
    step = get(config, "atmosphere_step", nothing)
    model_step_seconds = options.period_ns / 1e9
    step isa Real && !(step isa Bool) && isfinite(step) &&
        isapprox(step, model_step_seconds; rtol=1e-12, atol=0) || error(
            "installed plant atmosphere_step must equal the rounded model period in seconds",
        )
    return nothing
end

simulator_execution(::Backends.HostComputeDevice) = StreamGraphExecution()
simulator_execution(::Backends.AcceleratorComputeDevice) = CapturedGraphExecution()

function prepare_science(options, plant, target; execution=simulator_execution(target))
    validate_graph_timing(options)
    # These public plant APIs define the exact grid geometry and command count.
    isfile(plant.graph_path(:grid_gaussian)) || error("plant grid Gaussian graph is unavailable")
    plant.command_count() == 277 || error("plant must expose 277 PDM commands")
    pdm_command = Backends.allocate_device_array(target, Float32, plant.command_count())
    fill!(pdm_command, 0.0f0)
    pdm_actuator_grid_indices = copy_to_target(target, plant.actuator_grid_indices())
    definition = load_algorithm_graph(
        options.graph; bindings=(; pdm_command, pdm_actuator_grid_indices),
    )
    graph = prepare_algorithm_graph(definition; target, execution)
    frame_output = options.profile === :classic ? :shwfs_frame : :pwfs_frame
    boundary = prepare_graph_hil_boundary(graph; command_input=:pdm_command, frame_output)
    expected_shape = options.profile === :classic ? (352, 352) : (64, 64)
    size(hil_frame_buffer(boundary)) == expected_shape || error("plant frame shape does not match $expected_shape")
    size(hil_command_buffer(boundary)) == (277,) || error("plant command shape does not match (277,)")
    driver = FixedStepModelTimeDriver(PeriodicSchedule(; period_ns=options.period_ns))
    warm = step_hil_frame_at!(boundary, driver)
    for value in hil_frame_buffer(boundary)
        isfinite(value) && 0 <= value <= typemax(UInt16) || error("prepared detector frame cannot encode as UInt16")
        round(UInt16, value)
    end
    # Warm the model, host staging and command adoption before publishing readiness.
    fill!(hil_command_buffer(boundary), 0.0f0)
    adopt_hil_command!(boundary, warm.sequence)
    reset_hil_boundary!(boundary, driver)
    return (; graph, boundary, driver, target)
end

mutable struct Recorder{W}
    count::Int
    frames::Vector{UInt16}
    commands::Matrix{Float32}
    sequences::Vector{UInt64}
    model_timestamps_ns::Vector{Int64}
    cycle_ns::Vector{UInt64}
    graph_latency_ns::Vector{UInt64}
    source_published_ns::Vector{Int64}
    command_received_ns::Vector{Int64}
    missed_wall_periods::UInt64
    started_ns::UInt64
    completed_ns::UInt64
    truth::W
end

function Recorder(options, boundary; truth=nothing)
    return Recorder(
        0, zeros(UInt16, length(hil_frame_buffer(boundary)) * options.frames),
        zeros(Float32, 277, options.frames), zeros(UInt64, options.frames),
        zeros(Int64, options.frames), zeros(UInt64, options.frames),
        zeros(UInt64, options.frames), zeros(Int64, options.frames),
        zeros(Int64, options.frames), UInt64(0), UInt64(0), UInt64(0), truth,
    )
end

function reset_recorder!(recorder)
    recorder.count = 0
    recorder.missed_wall_periods = 0
    recorder.started_ns = 0
    recorder.completed_ns = 0
    fill!(recorder.frames, 0)
    fill!(recorder.commands, 0)
    fill!(recorder.sequences, 0)
    fill!(recorder.model_timestamps_ns, 0)
    fill!(recorder.cycle_ns, 0)
    fill!(recorder.graph_latency_ns, 0)
    fill!(recorder.source_published_ns, 0)
    fill!(recorder.command_received_ns, 0)
    recorder.truth === nothing || CorrectionTruth.reset!(recorder.truth)
    return nothing
end

function prepare_correction_truth(options, science)
    get(options, :correction_diagnostics, false) || return nothing
    options.profile in (:classic, :copper) && options.backend in (:cpu, :cuda, :amdgpu) &&
        get(options, :transport, :scientific) in (:scientific, :heart) || throw(
            ArgumentError("correction diagnostics require a declared Classic/Copper simulation"))
    witness = CorrectionTruth.prepare_witness(options.graph, AdaptiveOpticsSim.Optics, science.target, options.frames)
    isapprox(witness.config.exposure_seconds, options.exposure_ns / 1e9; rtol=1e-12, atol=0) ||
        throw(ArgumentError("truth plant/report exposure mismatch"))
    return witness
end

function record_correction_truth!(recorder, science, sequence, model_timestamp_ns)
    recorder.truth === nothing && return nothing
    staged = CorrectionTruth.stage!(recorder.truth,
        graph_output(science.graph, Val(:atmosphere_opd)), graph_output(science.graph, Val(:pupil_opd)),
        graph_output(science.graph, Val(:pdm_surface_opd)))
    return CorrectionTruth.record!(recorder.truth, staged..., sequence, model_timestamp_ns)
end

function record!(recorder, boundary, sequence, driver, model_timestamp_ns, timing, cycle_ns, start_ns, stop_ns)
    index = recorder.count + 1
    timing === nothing && error("completed exchange has no frame/command timing")
    timing.sequence == sequence || error("frame/command timing sequence mismatch")
    sequence == UInt64(index) || error("plant sequence does not match bounded recorder")
    model_time_sequence(driver) == sequence || error("model-time sequence does not match plant")
    command = hil_command_buffer(boundary)
    all(isfinite, command) || error("adopted command is not finite")
    for actuator in eachindex(command)
        recorder.commands[actuator, index] = command[actuator]
    end
    frame = hil_frame_buffer(boundary)
    destination = (index - 1) * length(frame) + 1
    # The recorded payload exactly matches UInt16 ROW_MAJOR wire encoding.
    for row in axes(frame, 1), column in axes(frame, 2)
        value = frame[row, column]
        isfinite(value) && 0 <= value <= typemax(UInt16) || error("raw frame cannot encode as UInt16")
        recorder.frames[destination] = round(UInt16, value)
        destination += 1
    end
    recorder.sequences[index] = sequence
    recorder.model_timestamps_ns[index] = model_timestamp_ns
    recorder.cycle_ns[index] = cycle_ns
    recorder.graph_latency_ns[index] = timing.end_to_end_latency_nanoseconds
    recorder.source_published_ns[index] = timing.source_published_nanoseconds
    recorder.command_received_ns[index] = timing.command_received_nanoseconds
    recorder.count = index
    index == 1 && (recorder.started_ns = start_ns)
    recorder.completed_ns = stop_ns
    return nothing
end

function write_binary_atomic(path, values)
    mkpath(dirname(path))
    temporary, io = mktemp(dirname(path))
    try
        # htol makes the artifact byte order explicit even on a big-endian host.
        for value in values
            word = value isa Float32 ? reinterpret(UInt32, value) : value
            write(io, htol(word))
        end
        close(io)
        mv(temporary, path; force=true)
    finally
        isopen(io) && close(io)
        ispath(temporary) && rm(temporary)
    end
    return bytes2hex(open(sha256, path))
end

function write_report(options, science, recorder, state; failure=nothing, sustained_run=nothing)
    transport = transport_contract(options)
    count = recorder.count
    prefix = endswith(options.output, ".json") ? options.output[1:end-5] : options.output
    frame_path = prefix * ".frames.u16le"
    command_path = prefix * ".commands.f32le"
    frame_hash = write_binary_atomic(frame_path, @view(recorder.frames[1:length(hil_frame_buffer(science.boundary))*count]))
    command_hash = write_binary_atomic(command_path, @view(recorder.commands[:, 1:count]))
    elapsed = recorder.completed_ns - recorder.started_ns
    source_span = count >= 2 ? recorder.source_published_ns[count] - recorder.source_published_ns[1] : 0
    achieved = count >= 2 && source_span > 0 ? (count - 1) * 1e9 / source_span : nothing
    recorded_command = @view(recorder.commands[:, 1:count])
    max_abs_command_um = maximum(value -> abs(value / COMMAND_TO_METRES), recorded_command; init=0.0f0)
    limit_threshold_um = 0.8f0 - 8 * eps(0.8f0)
    components_at_limit = Base.count(value -> abs(value / COMMAND_TO_METRES) >= limit_threshold_um, recorded_command)
    nonzero_components = Base.count(!iszero, recorded_command)
    report = (
        version=1, profile=String(options.profile), backend=String(options.backend),
        graph_execution=string(typeof(graph_execution_policy(science.graph))),
        remote=options.remote, graph=options.graph, graph_sha256=bytes2hex(open(sha256, options.graph)),
        target=(type=string(typeof(science.target)),
                backend=string(typeof(Backends.compute_device_backend(science.target))),
                device_identifier=Backends.compute_device_identifier(science.target)),
        state=state.running ? "running" : "paused", completed=sustained_run === nothing ? state.completed : count == options.frames,
        failure=failure, requested_rate_hz=options.rate, achieved_cycle_rate_hz=achieved,
        measurement_span_ns=elapsed, source_publication_span_ns=source_span,
        model_period_ns=options.period_ns, exposure_ns=options.exposure_ns,
        requested_frames=options.frames, completed_frames=count, completed_commands=count,
        sequence=sustained_run === nothing ? state.sequence : UInt64(count), sequences=recorder.sequences[1:count],
        model_timestamps_ns=recorder.model_timestamps_ns[1:count],
        cycle_durations_ns=recorder.cycle_ns[1:count],
        source_to_command_latency_ns=recorder.graph_latency_ns[1:count],
        source_published_ns=recorder.source_published_ns[1:count],
        command_received_ns=recorder.command_received_ns[1:count],
        missed_wall_periods=recorder.missed_wall_periods,
        max_abs_command_um=max_abs_command_um, command_limit_um=0.8f0,
        command_limit_tolerance_um=8 * eps(0.8f0), command_components_at_limit=components_at_limit,
        nonzero_command_components=nonzero_components,
        transport=String(get(options, :transport, :scientific)),
        frame=(schema=transport.frame_schema, element_type="U16_LE", layout="ROW_MAJOR",
               shape=collect(size(hil_frame_buffer(science.boundary))), file=frame_path,
               sha256=frame_hash, units="raw detector ADC code", encoding="nearest ties to even"),
        command=(schema=transport.command_schema, transport_element_type="F32_LE", shape=[277],
                 transport_units=transport.command_units, plant_units="metre OPD", transport_to_plant_scale=transport.command_scale,
                 recorded_units="metre OPD", recorded_element_type="F32_LE", file=command_path,
                 sha256=command_hash, layout="frame followed by 277 actuator values"),
        qualification="software complete-frame characterization against a provisional plant model; scientific convergence, hardware frame rate and physical validation not established",
    )
    if recorder.truth !== nothing
        truth = CorrectionTruth.report(recorder.truth; graph_sha256=report.graph_sha256,
            frame_sha256=frame_hash, command_sha256=command_hash,
            simulator_sha256=bytes2hex(open(sha256, @__FILE__)), completed_frames=count)
        report = merge(report, (; correction_truth=truth))
    end
    summary = nothing
    if sustained_run !== nothing
        report = merge(report,(; recording_scope="completed contiguous prefix of sustained run; owner state and total delivery in companion report",
            owner_sequence=state.sequence, sustained_report=options.output * ".sustained.json"))
        details = SustainedRun.report(sustained_run)
        summary = (; version=2, profile=String(options.profile), backend=String(options.backend),
            completed=state.completed && sustained_run.metrics.count == options.total_exchanges,
            failure, state=state.running ? "running" : "paused", sequence=state.sequence,
            requested_exchanges=options.total_exchanges, completed_frames=sustained_run.metrics.count,
            completed_commands=sustained_run.metrics.count, retained_prefix_frames=count,
            prefix_report=options.output, graph_sha256=report.graph_sha256,
            model_period_ns=options.period_ns, exposure_ns=options.exposure_ns,
            wall_rate_hz=options.wall_rate, wall_period_ns=options.wall_period_ns,
            arrival_policy=options.wall_rate == 0 ? "unpaced closed-loop completion-driven capacity" : "paced closed-loop future-deadline scheduling without catch-up",
            missed_wall_periods=sustained_run.missed_wall_periods,
            source_sha256=bytes2hex(open(sha256,@__FILE__)), details...)
    end
    Protocol.write_json_atomic(options.output, report; maximum=256 * 1024)
    summary === nothing || Protocol.write_json_atomic(options.output * ".sustained.json",summary;maximum=256 * 1024)
    return nothing
end

function warm_report_writer!(options, science, recorder, state; sustained_run=nothing)
    recorder.count == 0 && state.sequence == 0 && !state.running || throw(
        ArgumentError("report warmup requires the initial paused owner"),
    )
    # A String failure changes the report's concrete type and JSON serializer.
    # Compile that path privately; the public record describes the actual owner.
    mkpath(dirname(options.output))
    mktempdir(dirname(options.output); prefix=".report-warmup-") do directory
        warm_options = merge(options, (; output=joinpath(directory, "result.json")))
        write_report(warm_options, science, recorder, state; failure="report writer warmup", sustained_run)
    end
    write_report(options, science, recorder, state; sustained_run)
    return nothing
end

function wait_for_connect(options)
    while !isfile(options.connect_request)
        isfile(options.quit_request) && return false
        sleep(0.005)
    end
    return !isfile(options.quit_request)
end

function installed_detector_bits(options)
    definition = TOML.parsefile(options.graph)
    detectors = filter(node -> get(node,"name",nothing) == "detector",definition["nodes"])
    length(detectors) == 1 || throw(ArgumentError("installed graph requires exactly one detector"))
    bits = get(only(detectors)["config"],"bits",nothing)
    bits isa Integer && !(bits isa Bool) && 1 <= bits <= 16 || throw(ArgumentError("installed detector bits must fit UInt16"))
    return Int(bits)
end

function pace_owner!()
    yield()
    GC.safepoint()
    return nothing
end

function consume_native_control!(mailbox, pipewire, state, wall_period,
                                 reset_owner!::Reset, report_owner!::Report) where {Reset,Report}
    mailbox.ready[] || return nothing
    kind, token, requested_running = with_frame_stream(pipewire) do _
        SourceControl.pending(mailbox)
    end
    if kind != SourceControl.INITIAL
        result = SourceControl.apply!(state, kind, token, requested_running,
            time_ns(), max(wall_period, UInt64(1)), reset_owner!)
        if kind == SourceControl.RESET && result == 0
            # Stopped reset is a cold phase. Status/pause/resume never rewrite
            # reports; their native snapshot is the live owner cursor.
            report_owner!()
            SourceControl.report_ready!(mailbox,
                Int64(frame_acquisition_generation(pipewire)), state.sequence)
        end
        completed_generation = Int64(frame_acquisition_generation(pipewire))
        with_frame_stream(pipewire) do stream
            SourceControl.publish!(mailbox, stream, kind, token, result, state,
                completed_generation)
        end
    end
    rejection_generation = Int64(frame_acquisition_generation(pipewire))
    with_frame_stream(pipewire) do stream
        SourceControl.publish_rejection!(mailbox, stream, state,
            rejection_generation)
    end
    return nothing
end

function warm_exchange_methods!(science, pipewire, recorder, sustained_run)
    # Executing an exchange here would admit a transport frame before release.
    # Compile its exact public signature while the streams are still inactive.
    precompile(exchange_frame!, (typeof(pipewire), typeof(science.driver))) ||
        error("cannot compile the prepared frame exchange before admission")
    precompile(record!, (typeof(recorder), typeof(science.boundary), UInt64,
        typeof(science.driver), Int64, PipeWireFrameCommandTiming,
        UInt64, UInt64, UInt64)) || error("cannot compile the prepared frame recorder")
    precompile(record_correction_truth!, (typeof(recorder), typeof(science), UInt64, Int64)) ||
        error("cannot compile the prepared truth recorder")
    if sustained_run !== nothing
        precompile(SustainedRun.observe!, (typeof(sustained_run), UInt64, Int64, UInt64,
            PipeWireFrameCommandTiming, UInt64, typeof(hil_command_buffer(science.boundary)),
            typeof(hil_frame_buffer(science.boundary)))) || error("cannot compile prepared exchange metrics")
    end
    return nothing
end

function run_owner(options, plant, target)
    println("SIMULATOR_PREPARING profile=$(options.profile) backend=$(options.backend)")
    flush(stdout)
    science = prepare_science(options, plant, target)
    recorder = Recorder(options, science.boundary; truth=prepare_correction_truth(options, science))
    state = Protocol.OwnerState()
    source_control = SourceControl.Mailbox(Int64(rand(UInt64) % UInt64(typemax(Int64))) + Int64(1))
    sustained_run = get(options,:sustained,false) ? SustainedRun.Run(options,recorder.truth;detector_bits=installed_detector_bits(options)) : nothing
    wall_period = get(options,:wall_period_ns,options.period_ns)
    # Warm success and failure serialization before bounded source control.
    # No transport frame has been admitted, and the recorder remains empty.
    warm_report_writer!(options, science, recorder, state; sustained_run)
    Protocol.write_json_atomic(options.prepared_event, (version=1, state="prepared", sequence=0))
    println("SIMULATOR_PREPARED sequence=0")
    flush(stdout)
    wait_for_connect(options) || return nothing
    transport = transport_contract(options)
    configuration = PipeWireHILConfiguration(
        remote=options.remote, frame_node_name=get(options,:control_node,"simulator-wfs"), command_node_name="simulator-command",
        frame_schema=transport.frame_schema, command_schema=transport.command_schema,
        rate=SPA.Fraction(UInt32(options.rate), UInt32(1)), exposure_duration_ns=options.exposure_ns,
        frame_encoding=:uint16, command_scale=transport.command_scale,
    )
    println("SIMULATOR_CONNECTING remote=$(options.remote)")
    flush(stdout)
    pipewire = prepare_pipewire_hil(science.boundary, configuration;
        frame_properties=SourceControl.source_properties(source_control),
        frame_params=source_control.parameters.params,
        on_frame_param_changed=SourceControl.ParameterChanged(source_control),
        frame_param_buffer=PodBuffer(4096),
        on_frame_param_overflow=SourceControl.ParameterOverflow(source_control))
    # Graph preparation selects concrete scientific owners at runtime. Cross
    # that boundary once so the frame loop specializes on retained storage.
    return run_prepared_owner!(options, science, recorder, state,
        sustained_run, pipewire, wall_period, source_control)
end

function run_prepared_owner!(options, science, recorder, state, sustained_run, pipewire, wall_period, source_control)
    failure = nothing
    reset_owner! = () -> begin
        heart = get(options, :transport, :scientific) === :heart
        heart && stop!(pipewire)
        reset_controller!(options, state.last_request_id)
        reset_pipewire_hil!(pipewire, science.driver)
        reset_recorder!(recorder)
        sustained_run === nothing || SustainedRun.reset!(sustained_run)
        heart && start!(pipewire)
    end
    report_owner! = () -> write_report(options, science, recorder, state; sustained_run)
    try
        warm_exchange_methods!(science, pipewire, recorder, sustained_run)
        # Both streams become inspectable with no pending frame. No frame is
        # armed until a valid typed resume request reaches the serialized loop.
        start!(pipewire)
        Protocol.write_json_atomic(options.connect_reply, (version=1, state="connected", sequence=0))
        println("SIMULATOR_CONNECTED sequence=0 held=true")
        flush(stdout)
        while !ispath(options.quit_request)
            consume_native_control!(source_control, pipewire, state, wall_period, reset_owner!, report_owner!)
            ispath(options.quit_request) && break
            if !state.running
                pace_owner!()
                continue
            end
            now = time_ns()
            if now < state.deadline_ns
                pace_owner!()
                continue
            end
            started = time_ns()
            model_timestamp_ns = model_nanoseconds(next_model_timestamp(science.driver))
            sequence = exchange_frame!(pipewire, science.driver)
            finished = time_ns()
            # exchange_frame! adopts the matching command before returning.
            state.sequence = sequence
            model_time_sequence(science.driver) == sequence || error("model-time sequence does not match plant")
            if sustained_run !== nothing
                SustainedRun.observe!(sustained_run, sequence, model_timestamp_ns, options.period_ns,
                    frame_command_timing(pipewire), finished - started,
                    hil_command_buffer(science.boundary),hil_frame_buffer(science.boundary))
            end
            if recorder.count < options.frames
                record!(recorder, science.boundary, sequence, science.driver, model_timestamp_ns,
                        frame_command_timing(pipewire), finished - started, started, finished)
                record_correction_truth!(recorder, science, sequence, model_timestamp_ns)
            end
            if sustained_run !== nothing
                sustained_run.truth === nothing || SustainedRun.sample!(sustained_run,
                    graph_output(science.graph,Val(:atmosphere_opd)),
                    graph_output(science.graph,Val(:pupil_opd)),
                    graph_output(science.graph,Val(:pdm_surface_opd)),sequence,model_timestamp_ns)
                sequence == options.frames && (sustained_run.allocation_start = Base.gc_num())
            end
            # Public OPD outputs still describe this completed frame. Exchange
            # has adopted its matching command for the next step. Hashing is an
            # opt-in source diagnostic and can extend the cold owner interval.
            if wall_period == 0
                state.deadline_ns = 0
            else
                state.deadline_ns, missed = Protocol.next_deadline(state.deadline_ns, wall_period, time_ns())
                if sustained_run === nothing
                    recorder.missed_wall_periods += missed
                else
                    sustained_run.missed_wall_periods += missed
                    sequence <= options.frames && (recorder.missed_wall_periods += missed)
                end
            end
            if sequence == get(options,:total_exchanges,options.frames)
                state.running = false
                state.completed = true
                state.deadline_ns = 0
                sustained_run === nothing || (sustained_run.allocation_finish = Base.gc_num())
                write_report(options, science, recorder, state; sustained_run)
                SourceControl.report_ready!(source_control,
                    Int64(frame_acquisition_generation(pipewire)), state.sequence)
            end
        end
    catch exception
        failure = sprint(showerror, exception)
        println(stderr, "SIMULATOR_FAILURE ", failure)
        flush(stderr)
        rethrow()
    finally
        state.running = false
        try
            close(pipewire)
        finally
            if sustained_run !== nothing && sustained_run.allocation_finish === nothing
                sustained_run.allocation_finish = Base.gc_num()
            end
            write_report(options, science, recorder, state; failure, sustained_run)
        end
    end
    return nothing
end

function main(arguments=ARGS)
    options = Protocol.parse_options(arguments)
    options.control_request === nothing && options.control_reply === nothing ||
        error("simulator controls require native PipeWire Props; file controls belong to calibration owners")
    Protocol.require_fresh_instance(options)
    plant = load_plant(options.profile)
    target = load_target(options.backend)
    # Selected plant and accelerator extension imports must be visible to all
    # calls made by the owner, including public backend availability methods.
    return HILHeartControl.with_controller(options) do admitted
        Base.invokelatest(run_owner, admitted, plant, target)
    end
end

abspath(PROGRAM_FILE) == (@__FILE__) && main()
