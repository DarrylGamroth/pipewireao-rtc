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
include("correction_truth.jl")
using .HILOwnerProtocol
const Protocol = HILOwnerProtocol
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
    Protocol.write_json_atomic(options.controller_request,
        (; version=1, id=request_id, operation="reset"))
    deadline = time_ns() + UInt64(round(Int, timeout_seconds * 1e9))
    while time_ns() < deadline
        isfile(options.quit_request) && error("shutdown requested while resetting HEART")
        if isfile(options.controller_reply)
            payload = read(options.controller_reply)
            length(payload) <= Protocol.MAX_REPLY_BYTES || error("HEART reset reply exceeds bound")
            reply = Protocol.JSON3.read(payload)
            if get(reply, :id, nothing) == request_id
                get(reply, :version, nothing) == 1 && get(reply, :operation, nothing) == "reset" &&
                    get(reply, :ok, false) === true && get(reply, :sequence, nothing) == 0 &&
                    get(reply, :state, nothing) == "paused" || error("HEART reset failed: $reply")
                return nothing
            end
        end
        sleep(0.005)
    end
    error("HEART reset acknowledgement timed out")
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

function prepare_science(options, plant, target)
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
    graph = prepare_algorithm_graph(definition; target, execution=StreamGraphExecution())
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
    options.profile === :classic && options.backend === :cpu &&
        get(options, :transport, :scientific) === :scientific || throw(
            ArgumentError("correction diagnostics require Classic CPU scientific transport"))
    witness = CorrectionTruth.prepare_witness(options.graph, AdaptiveOpticsSim.Optics, science.target, options.frames)
    isapprox(witness.config.exposure_seconds, options.exposure_ns / 1e9; rtol=1e-12, atol=0) ||
        throw(ArgumentError("truth plant/report exposure mismatch"))
    return witness
end

function record_correction_truth!(recorder, science, sequence, model_timestamp_ns)
    recorder.truth === nothing && return nothing
    return CorrectionTruth.record!(recorder.truth,
        graph_output(science.graph, :atmosphere_opd), graph_output(science.graph, :pupil_opd),
        graph_output(science.graph, :pdm_surface_opd), sequence, model_timestamp_ns)
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

function write_report(options, science, recorder, state; failure=nothing)
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
        remote=options.remote, graph=options.graph, graph_sha256=bytes2hex(open(sha256, options.graph)),
        target=(type=string(typeof(science.target)),
                backend=string(typeof(Backends.compute_device_backend(science.target))),
                device_identifier=Backends.compute_device_identifier(science.target)),
        state=state.running ? "running" : "paused", completed=state.completed,
        failure=failure, requested_rate_hz=options.rate, achieved_cycle_rate_hz=achieved,
        measurement_span_ns=elapsed, source_publication_span_ns=source_span,
        model_period_ns=options.period_ns, exposure_ns=options.exposure_ns,
        requested_frames=options.frames, completed_frames=count, completed_commands=count,
        sequence=state.sequence, sequences=recorder.sequences[1:count],
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
    Protocol.write_json_atomic(options.output, report; maximum=256 * 1024)
    return nothing
end

function warm_report_writer!(options, science, recorder, state)
    recorder.count == 0 && state.sequence == 0 && !state.running || throw(
        ArgumentError("report warmup requires the initial paused owner"),
    )
    # A String failure changes the report's concrete type and JSON serializer.
    # Compile that path privately; the public record describes the actual owner.
    mkpath(dirname(options.output))
    mktempdir(dirname(options.output); prefix=".report-warmup-") do directory
        warm_options = merge(options, (; output=joinpath(directory, "result.json")))
        write_report(warm_options, science, recorder, state; failure="report writer warmup")
    end
    write_report(options, science, recorder, state)
    return nothing
end

function wait_for_connect(options)
    while !isfile(options.connect_request)
        isfile(options.quit_request) && return false
        sleep(0.005)
    end
    return !isfile(options.quit_request)
end

function run_owner(options, plant, target)
    println("SIMULATOR_PREPARING profile=$(options.profile) backend=$(options.backend)")
    flush(stdout)
    science = prepare_science(options, plant, target)
    recorder = Recorder(options, science.boundary; truth=prepare_correction_truth(options, science))
    state = Protocol.OwnerState()
    # Warm success and failure serialization before bounded source control.
    # No transport frame has been admitted, and the recorder remains empty.
    warm_report_writer!(options, science, recorder, state)
    Protocol.write_json_atomic(options.prepared_event, (version=1, state="prepared", sequence=0))
    println("SIMULATOR_PREPARED sequence=0")
    flush(stdout)
    wait_for_connect(options) || return nothing
    transport = transport_contract(options)
    configuration = PipeWireHILConfiguration(
        remote=options.remote, frame_node_name="simulator-wfs", command_node_name="simulator-command",
        frame_schema=transport.frame_schema, command_schema=transport.command_schema,
        rate=SPA.Fraction(UInt32(options.rate), UInt32(1)), exposure_duration_ns=options.exposure_ns,
        frame_encoding=:uint16, command_scale=transport.command_scale,
    )
    println("SIMULATOR_CONNECTING remote=$(options.remote)")
    flush(stdout)
    pipewire = prepare_pipewire_hil(science.boundary, configuration)
    failure = nothing
    last_payload = nothing
    try
        # Both streams become inspectable with no pending frame. No frame is
        # armed until a valid typed resume request reaches the serialized loop.
        start!(pipewire)
        Protocol.write_json_atomic(options.connect_reply, (version=1, state="connected", sequence=0))
        println("SIMULATOR_CONNECTED sequence=0 held=true")
        flush(stdout)
        while !isfile(options.quit_request)
            if isfile(options.control_request)
                payload = open(options.control_request) do io
                    String(read(io, Protocol.MAX_REQUEST_BYTES + 1))
                end
                if payload != last_payload
                    last_payload = payload
                    reply = Protocol.control!(state, payload, time_ns(), options.period_ns, () -> begin
                        heart = get(options, :transport, :scientific) === :heart
                        heart && stop!(pipewire)
                        reset_controller!(options, state.last_request_id)
                        reset_pipewire_hil!(pipewire, science.driver)
                        reset_recorder!(recorder)
                        heart && start!(pipewire)
                    end)
                    if reply.ok && reply.operation in ("pause", "reset")
                        write_report(options, science, recorder, state)
                    end
                    Protocol.write_json_atomic(options.control_reply, reply)
                end
            end
            isfile(options.quit_request) && break
            if !state.running
                sleep(0.005)
                continue
            end
            now = time_ns()
            if now < state.deadline_ns
                sleep(min((state.deadline_ns - now) / 1e9, 0.001))
                continue
            end
            started = time_ns()
            model_timestamp_ns = model_nanoseconds(next_model_timestamp(science.driver))
            sequence = exchange_frame!(pipewire, science.driver)
            finished = time_ns()
            # exchange_frame! adopts the matching command before returning.
            state.sequence = sequence
            record!(recorder, science.boundary, sequence, science.driver, model_timestamp_ns,
                    frame_command_timing(pipewire), finished - started, started, finished)
            # Public OPD outputs still describe this completed frame. Exchange
            # has adopted its matching command for the next step. Hashing is an
            # opt-in source diagnostic and can extend the cold owner interval.
            record_correction_truth!(recorder, science, sequence, model_timestamp_ns)
            state.deadline_ns, missed = Protocol.next_deadline(state.deadline_ns, options.period_ns, time_ns())
            recorder.missed_wall_periods += missed
            if recorder.count == options.frames
                state.running = false
                state.completed = true
                state.deadline_ns = 0
                write_report(options, science, recorder, state)
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
            write_report(options, science, recorder, state; failure)
        end
    end
    return nothing
end

function main(arguments=ARGS)
    options = Protocol.parse_options(arguments)
    Protocol.require_fresh_instance(options)
    plant = load_plant(options.profile)
    target = load_target(options.backend)
    # Selected plant and accelerator extension imports must be visible to all
    # calls made by the owner, including public backend availability methods.
    return Base.invokelatest(run_owner, options, plant, target)
end

abspath(PROGRAM_FILE) == (@__FILE__) && main()
