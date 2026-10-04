#!/usr/bin/env julia
# One serialized owner composes transport and science for initial calibration.
include("simulator.jl")
include("calibration_acquisition.jl")
include("calibration_server.jl")
using Sockets

function calibration_options(arguments; required_transport::Symbol=:scientific)
    length(arguments) % 2 == 0 || throw(ArgumentError("each option requires one value"))
    ordinary = String[]
    endpoint = nothing
    active_path = nothing
    illumination = :lamp
    capture_directory = nothing
    capture_max_bytes = nothing
    calibration_stage = "calibration"
    seen_campaign = Set{String}()
    for index in 1:2:length(arguments)
        if arguments[index] == "--calibration-socket"
            endpoint === nothing || throw(ArgumentError("duplicate --calibration-socket"))
            isempty(arguments[index + 1]) && throw(ArgumentError("empty calibration socket"))
            endpoint = abspath(arguments[index + 1])
        elseif arguments[index] == "--wfs-active"
            active_path === nothing || throw(ArgumentError("duplicate --wfs-active"))
            isempty(arguments[index + 1]) && throw(ArgumentError("empty WFS active path"))
            active_path = abspath(arguments[index + 1])
        elseif arguments[index] in ("--illumination", "--capture-directory", "--capture-max-bytes", "--calibration-stage")
            option, value = arguments[index], arguments[index + 1]
            option in seen_campaign && throw(ArgumentError("duplicate $option"))
            push!(seen_campaign, option)
            isempty(value) && throw(ArgumentError("empty $option"))
            if option == "--illumination"
                value in ("dark", "lamp") || throw(ArgumentError("illumination must be dark or lamp"))
                illumination = Symbol(value)
            elseif option == "--capture-directory"
                capture_directory = abspath(value)
            elseif option == "--capture-max-bytes"
                parsed = tryparse(UInt64, value)
                parsed !== nothing && 0 < parsed <= UInt64(typemax(Int64)) ||
                    throw(ArgumentError("capture payload budget must be positive and fit Int64"))
                capture_max_bytes = parsed
            else
                occursin(r"^[A-Za-z][A-Za-z0-9_-]{0,63}$", value) || throw(ArgumentError("invalid calibration stage"))
                calibration_stage = value
            end
        else
            push!(ordinary, arguments[index], arguments[index + 1])
        end
    end
    endpoint === nothing && throw(ArgumentError("missing --calibration-socket"))
    options = Protocol.parse_options(ordinary)
    options.transport === required_transport || throw(ArgumentError("calibration transport differs from the selected owner"))
    ncodeunits(endpoint) < 108 || throw(ArgumentError("calibration socket path exceeds the Unix limit"))
    endpoint in (options.graph, options.prepared_event, options.connect_request,
        options.connect_reply, options.quit_request, options.control_request,
        options.control_reply, options.output) && throw(ArgumentError("calibration socket path conflicts"))
    ispath(endpoint) && throw(ArgumentError("calibration socket already exists"))
    if active_path !== nothing
        options.profile === :classic || throw(ArgumentError("--wfs-active is Classic only"))
        isfile(active_path) || throw(ArgumentError("WFS active artifact is missing"))
        active_path in (endpoint, options.graph, options.prepared_event, options.connect_request,
            options.connect_reply, options.quit_request, options.control_request,
            options.control_reply, options.output) && throw(ArgumentError("WFS active path conflicts"))
    end
    (capture_directory === nothing) == (capture_max_bytes === nothing) ||
        throw(ArgumentError("capture requires both directory and finite payload budget"))
    if capture_directory !== nothing
        CalibrationServer.capture_layout(Val(options.profile))
        (ispath(capture_directory) || islink(capture_directory)) &&
            throw(ArgumentError("capture directory must be fresh"))
        isdir(dirname(capture_directory)) || throw(ArgumentError("capture directory parent is missing"))
        capture_directory in (endpoint, options.graph, options.prepared_event, options.connect_request,
            options.connect_reply, options.quit_request, options.control_request,
            options.control_reply, options.output, active_path) && throw(ArgumentError("capture directory path conflicts"))
    end
    return merge(options, (; calibration_socket=endpoint, active_path,
        illumination, capture_directory, capture_max_bytes, calibration_stage))
end

function calibration_active(options)
    options.active_path === nothing && return nothing
    bytes = open(options.active_path) do io
        read(io, 189)
    end
    length(bytes) == 188 && all(value -> value == 0 || value == 1, bytes) ||
        throw(ArgumentError("Classic WFS active artifact requires 188 zero/one bytes"))
    return CalibrationAcquisition.prepare_active(Val(:classic), Vector{Bool}(bytes .== 1))
end

function calibration_report(options, science, state, owner; failure=nothing)
    cursor = CalibrationAcquisition.cursor(owner.session)
    domain = owner.session.domain
    return (; version=1, profile=String(options.profile), backend=String(options.backend),
        state=state.running ? "running" : "paused", sequence=cursor.sequence,
        completed=state.completed, failure, phase=String(owner.phase),
        ownership_held=owner.held, restoration_confirmed=owner.restored,
        acquisition_domain_mapping=(; opaque_domain=UInt64(1), complete_domain=collect(domain.bytes)),
        acquisition_generation=cursor.generation, cursor_model_ns=cursor.model_ns,
        calibration_stage=options.calibration_stage,
        capture_directory=owner.capture === nothing ? nothing : owner.capture.directory,
        capture_max_bytes=options.capture_max_bytes,
        capture_reserved_payload_bytes=owner.capture === nothing ? nothing : owner.capture.reserved_bytes,
        capture_settings_sha256=owner.capture === nothing ? nothing : owner.capture.settings_sha256,
        illumination=String(science.illumination), detector_config=science.detector_config,
        wfs_active=owner.session.active,
        wfs_active_sha256=owner.session.active === nothing ? nothing : bytes2hex(sha256(UInt8.(owner.session.active))),
        detector_diagnostics=CalibrationAcquisition.exposure_diagnostics(owner.session),
        command_transport_units="micrometre OPD", plant_command_units="metre OPD",
        graph_sha256=bytes2hex(open(sha256, options.graph)),
        qualification="operational software acquisition; matrix, correction and rate require separate acceptance")
end

function run_calibration_owner(options, plant_module, target)
    println("CALIBRATION_PREPARING profile=$(options.profile) backend=$(options.backend)")
    flush(stdout)
    science = CalibrationAcquisition.prepare_science(options.graph, plant_module,
        target, options.profile; period_ns=options.period_ns, illumination=options.illumination)
    CalibrationAcquisition.validate_exposure_duration(science.detector_config, options.exposure_ns)
    active = calibration_active(options)
    capture = options.capture_directory === nothing ? nothing : CalibrationServer.CaptureStore(
        options.capture_directory; maximum_bytes=options.capture_max_bytes,
        profile=options.profile, stage=options.calibration_stage, illumination=options.illumination,
        settings=(; detector_config=science.detector_config,
            graph_sha256=bytes2hex(open(sha256, options.graph)),
            wfs_active_sha256=active === nothing ? nothing : bytes2hex(sha256(UInt8.(active)))))
    Protocol.write_json_atomic(options.prepared_event, (; version=1, state="prepared", sequence=0))
    println("CALIBRATION_PREPARED sequence=0")
    flush(stdout)
    wait_for_connect(options) || return nothing
    configuration = PipeWireHILConfiguration(
        remote=options.remote, frame_node_name="simulator-wfs", command_node_name="simulator-command",
        frame_schema=RAW_SCHEMA, command_schema=COMMAND_SCHEMA,
        rate=SPA.Fraction(UInt32(options.rate), UInt32(1)), exposure_duration_ns=options.exposure_ns,
        frame_encoding=:uint16, command_scale=COMMAND_TO_METRES, timeout_ns=30_000_000_000)
    plant = prepare_pipewire_calibration(science.boundary, configuration)
    session = owner = listener = nothing
    state = Protocol.OwnerState()
    failure = nothing
    try
        session = CalibrationAcquisition.prepare_session(plant, science.driver,
            options.profile; rate=configuration.rate, active, adc_bits=science.detector_config["bits"])
        owner = CalibrationServer.Owner(session; normal_controller_absent=true,
            measurement_count=options.profile === :classic ? 376 : 3600,
            maximum_timeout_ns=configuration.timeout_ns, capture)
        CalibrationAcquisition.start_session!(session)
        mkpath(dirname(options.calibration_socket))
        listener = listen(options.calibration_socket)
        last_payload = Ref{Union{Nothing,String}}(nothing)
        service_control = () -> begin
            isfile(options.control_request) || return nothing
            payload = open(options.control_request) do io
                String(read(io, Protocol.MAX_REQUEST_BYTES + 1))
            end
            payload == last_payload[] && return nothing
            last_payload[] = payload
            state.sequence = CalibrationAcquisition.cursor(session).sequence
            reply = try
                Protocol.control!(state, payload, time_ns(), options.period_ns,
                    () -> error("calibration reset requires a new instance"))
            catch exception
                Protocol.response(state, state.last_request_id, "reset";
                    error=sprint(showerror, exception))
            end
            Protocol.write_json_atomic(options.control_reply, reply)
            Protocol.write_json_atomic(options.output, calibration_report(options, science, state, owner))
            return nothing
        end
        Protocol.write_json_atomic(options.output, calibration_report(options, science, state, owner))
        Protocol.write_json_atomic(options.connect_reply, (; version=1, state="connected", sequence=0))
        println("CALIBRATION_CONNECTED sequence=0")
        flush(stdout)
        CalibrationServer.serve!(owner, listener; accept_timeout_ns=UInt64(30_000_000_000),
            should_stop=() -> isfile(options.quit_request), service_control,
            admission_enabled=() -> state.running)
        state.running = false
        state.completed = true
        state.sequence = CalibrationAcquisition.cursor(session).sequence
        Protocol.write_json_atomic(options.output, calibration_report(options, science, state, owner))
        while !isfile(options.quit_request)
            service_control()
            sleep(0.005)
        end
    catch exception
        failure = sprint(showerror, exception)
        owner === nothing || CalibrationServer.fault!(owner)
        println(stderr, "CALIBRATION_FAILURE ", failure)
        flush(stderr)
        rethrow()
    finally
        state.running = false
        try
            if owner !== nothing
                Protocol.write_json_atomic(options.output,
                    calibration_report(options, science, state, owner; failure))
            end
        finally
            try
                listener === nothing || close(listener)
                ispath(options.calibration_socket) && rm(options.calibration_socket)
            finally
                session === nothing ? close(plant) : CalibrationAcquisition.close_session!(session)
            end
        end
    end
    return nothing
end

function calibration_main(arguments=ARGS)
    options = calibration_options(arguments)
    Protocol.require_fresh_instance(options)
    plant = load_plant(options.profile)
    target = load_target(options.backend)
    return Base.invokelatest(run_calibration_owner, options, plant, target)
end

abspath(PROGRAM_FILE) == (@__FILE__) && calibration_main()
