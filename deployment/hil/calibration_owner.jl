#!/usr/bin/env julia
# One serialized owner composes transport and science for initial calibration.
include("simulator.jl")
include("calibration_acquisition.jl")
include("calibration_server.jl")
include("native_acquisition_lifecycle.jl")
include("native_calibration_actions.jl")
using Sockets

function calibration_options(arguments; required_transport::Symbol=:scientific)
    length(arguments) % 2 == 0 || throw(ArgumentError("each option requires one value"))
    ordinary = String[]
    active_path = nothing
    illumination = :lamp
    capture_directory = nothing
    capture_max_bytes = nothing
    calibration_stage = "calibration"
    seen_campaign = Set{String}()
    for index in 1:2:length(arguments)
        if arguments[index] == "--wfs-active"
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
    options = Protocol.parse_options(ordinary; native_lifecycle=true)
    options.transport === required_transport || throw(ArgumentError("calibration transport differs from the selected owner"))
    if active_path !== nothing
        options.profile === :classic || throw(ArgumentError("--wfs-active is Classic only"))
        isfile(active_path) || throw(ArgumentError("WFS active artifact is missing"))
        active_path in (options.graph, options.prepared_event, options.connect_request,
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
        capture_directory in (options.graph, options.prepared_event, options.connect_request,
            options.connect_reply, options.quit_request, options.control_request,
            options.control_reply, options.output, active_path) && throw(ArgumentError("capture directory path conflicts"))
    end
    return merge(options, (; active_path,
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

function run_calibration_owner_native(options, bridge, plant_module, target)
    Lifecycle = HILNativeAcquisitionLifecycle
    Codec = Lifecycle.Codec
    Actions = HILNativeCalibrationActions
    actions = Actions.ActionServer(bridge,options.control_node)
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
    state = Protocol.OwnerState()
    plant = session = owner = shutdown_ticket = nothing
    primary = control_failure = nothing
    current_cursor() = owner === nothing ? nothing : CalibrationAcquisition.cursor(session)
    current_snapshot() = Lifecycle.snapshot(bridge, state, current_cursor();
        phase=owner === nothing ? "initial" : String(owner.phase),
        held=owner === nothing ? false : owner.held,
        restored=owner === nothing ? false : owner.restored)
    function publish_report!()
        owner === nothing && return nothing
        cursor = current_cursor()
        Protocol.write_json_atomic(options.output, calibration_report(options, science, state, owner))
        Lifecycle.report_published!(bridge, cursor)
        return nothing
    end
    function connect_effect!(ticket)
        remaining = ticket.deadline - Lifecycle.NativeControlClient.monotonic()
        remaining > 0 || error("calibration Connect deadline expired")
        timeout_ns = UInt64(max(1, floor(Int64, min(remaining, 30.0) * 1e9)))
        configuration = PipeWireHILConfiguration(
            remote=options.remote, frame_node_name="simulator-wfs", command_node_name="simulator-command",
            frame_schema=RAW_SCHEMA, command_schema=COMMAND_SCHEMA,
            rate=SPA.Fraction(UInt32(options.rate), UInt32(1)), exposure_duration_ns=options.exposure_ns,
            frame_encoding=:uint16, command_scale=COMMAND_TO_METRES, timeout_ns)
        plant = prepare_pipewire_calibration(science.boundary, configuration)
        session = CalibrationAcquisition.prepare_session(plant, science.driver,
            options.profile; rate=configuration.rate, active, adc_bits=science.detector_config["bits"])
        owner = CalibrationServer.Owner(session; normal_controller_absent=true,
            measurement_count=options.profile === :classic ? 376 : 3600,
            maximum_timeout_ns=timeout_ns, capture)
        CalibrationAcquisition.start_session!(session)
        publish_report!()
        return nothing
    end
    function service_control(; safe::Bool)
        if control_failure !== nothing
            safe && throw(control_failure)
            return nothing
        end
        Lifecycle.has_pending(bridge; safe) || return nothing
        try
            terminal = Lifecycle.dispatch!(bridge, state; safe, period_ns=options.period_ns,
                snapshot! = current_snapshot, connect! = connect_effect!,
                reset! = ticket -> (Int32(-95), "calibration reset requires a fresh instance"),
                allow_shutdown=() -> owner === nothing ||
                    (!owner.held && owner.phase === :initial) ||
                    (owner.phase === :released && owner.restored && !owner.held))
            terminal === nothing || (shutdown_ticket = terminal)
        catch error
            if !safe && error isa Lifecycle.TransportFailure
                control_failure = error
                state.running = false
                return nothing
            end
            rethrow()
        end
        return nothing
    end
    function service_boundary()
        try service_control(; safe=true)
        catch error
            error isa Lifecycle.TransportFailure || rethrow()
            throw(CalibrationServer.OwnerServiceAbort(error))
        end
        shutdown_ticket === nothing || throw(CalibrationServer.OwnerServiceAbort(nothing))
        return nothing
    end
    Lifecycle.lifecycle!(bridge, Codec.Prepared)
    try
        while owner === nothing && shutdown_ticket === nothing
            service_control(; safe=true)
            sleep(0.005)
        end
        if owner !== nothing
            Actions.serve!(actions, owner; accept_timeout_ns=UInt64(30_000_000_000),
                should_stop=() -> false, service_control=() -> service_control(; safe=false),
                service_boundary,
                admission_enabled=() -> state.running)
            if shutdown_ticket === nothing
                state.running = false
                state.completed = true
                state.sequence = current_cursor().sequence
                publish_report!()
                while shutdown_ticket === nothing
                    service_control(; safe=true)
                    sleep(0.005)
                end
            end
        end
    catch error
        primary = error isa CalibrationServer.OwnerServiceAbort ? error.cause : error
        if primary !== nothing && !(primary isa Lifecycle.TransportFailure) &&
                owner !== nothing && owner.phase !== :released
            CalibrationServer.fault!(owner)
        end
        if primary !== nothing && !(primary isa Lifecycle.TransportFailure)
            try Lifecycle.lifecycle!(bridge, Codec.Fault) catch end
        end
    end
    state.running = false
    stopped_cursor = try current_cursor() catch; nothing end
    cleanup = Exception[]
    if owner !== nothing
        try publish_report!() catch error; push!(cleanup, error) end
    end
    for resource in (session === nothing ? plant : session,)
        resource === nothing && continue
        try
            resource === session ? CalibrationAcquisition.close_session!(session) : close(resource)
        catch error
            push!(cleanup, error)
        end
    end
    if shutdown_ticket !== nothing && primary === nothing && isempty(cleanup)
        try
            Lifecycle.lifecycle!(bridge, Codec.Stopped)
            final = Lifecycle.snapshot(bridge, state, stopped_cursor;
                phase=owner === nothing ? "initial" : String(owner.phase),
                held=owner === nothing ? false : owner.held,
                restored=owner === nothing ? false : owner.restored)
            Lifecycle.complete!(bridge, shutdown_ticket, Codec.Stopped, final)
            Lifecycle.flush_terminal!(bridge, shutdown_ticket.deadline)
        catch error
            push!(cleanup, error)
        end
    end
    primary === nothing || throw(isempty(cleanup) ? primary : CompositeException([primary; cleanup]))
    isempty(cleanup) || throw(CompositeException(cleanup))
    return nothing
end

function calibration_main(arguments=ARGS)
    options = calibration_options(arguments)
    Protocol.require_fresh_instance(options)
    bridge = HILNativeAcquisitionLifecycle.Bridge(options,
        HILNativeAcquisitionLifecycle.Codec.CALIBRATION_PROFILE)
    try
        plant = load_plant(options.profile)
        target = load_target(options.backend)
        return Base.invokelatest(run_calibration_owner_native, options, bridge, plant, target)
    catch error
        if !(error isa HILNativeAcquisitionLifecycle.TransportFailure) &&
                bridge.runtime.endpoint.lifecycle !== HILNativeAcquisitionLifecycle.Codec.Stopped
            try HILNativeAcquisitionLifecycle.lifecycle!(bridge,
                HILNativeAcquisitionLifecycle.Codec.Fault) catch end
        end
        rethrow()
    finally
        close(bridge)
    end
end

abspath(PROGRAM_FILE) == (@__FILE__) && calibration_main()
