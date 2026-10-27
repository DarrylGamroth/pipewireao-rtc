# Initial sessions own their graphs and held-probe endpoints exclusively. All
# scientific samples arrive over the same transport as deployed measurements.
using PipeWireAO
const Actions = PipeWireAORTC.NativeCalibrationActionCodec
const Native = PipeWireAORTC.NativeCalibrationEndpoint
const Control = PipeWireAORTC.NativeControlClient
const Wire = AdaptiveOpticsSimPipeWireHIL

mutable struct InitialCalibration{P,D,C,T,W,G}
    hil::P
    driver::D
    capture::C
    transport::T
    workers::W
    graphs::G
    registry::Registry
    listener::ManagedListener
    frame_listener::ManagedListener
    links::Vector{PipeWireAO.Link}
    reference::Vector{Float32}
    active::Vector{Bool}
    token::UInt64
    probe::Union{Nothing,UInt32}
    cursor::Actions.AcquisitionCursor
    acquisition_domain::AcquisitionDomain
    restored::Bool
    wakeup::Base.AsyncCondition
    guard::ReentrantLock
    control::Any
    closed::Bool
end

function remaining(owner::InitialCalibration, deadline)
    budget = UInt64(Control.budget_ns(Actions.PROFILE, Float64(deadline - Control.monotonic())))
    return min(budget, owner.hil.configuration.timeout_ns)
end

function check(owner::InitialCalibration)
    owner.closed && error("initial calibration is closed")
    owner.control === nothing || Native.check_current!(owner.control)
    Wire.pipewire_calibration_status(owner.hil).failed && error("held-probe transport failed")
    for worker in values(owner.workers)
        if istaskdone(worker.task)
            fetch(worker.task)
            worker.error[] === nothing || throw(worker.error[])
            error("initial calibration graph owner stopped")
        end
    end
    status = calibration_probe_snapshot(owner.transport)
    status.error === nothing || throw(status.error)
    return status
end

function adopt!(owner::InitialCalibration, figure, deadline)
    check(owner)
    length(figure) == length(owner.reference) && all(isfinite, figure) ||
        throw(ArgumentError("initial calibration figure differs from the declared command contract"))
    owner.token = Base.Checked.checked_add(owner.token, UInt64(1))
    token = owner.token
    Wire.adopt_pipewire_probe!(owner.hil, token;
        timeout_ns=remaining(owner, deadline),
        submit=() -> stage!(owner.transport, token, figure))
    check(owner)
    # This is a received-and-adopted snapshot, not a parameter submission ACK.
    actual = copy(Wire.pipewire_probe_values(owner.hil))
    feedback = Native.await(owner.wakeup, owner.guard, Float64(deadline)) do
        status = check(owner)
        status.received == token ? status.values : nothing
    end
    feedback == figure .- actual || error("conditioner feedback disagrees with the adopted figure")
    owner.restored = false
    return actual, any(!iszero, feedback) || actual != figure
end

function exposure!(owner::InitialCalibration, deadline)
    check(owner)
    exposure = Wire.step_pipewire_exposure!(owner.hil, owner.driver;
        timeout_ns=remaining(owner, deadline),
        before_publish=value -> CalibrationCapture.arm!(owner.capture, value))
    # Publication acknowledges a queued source buffer before its native cycle
    # ends. Await the transport witness before requesting downstream progress;
    # only the correlated raw/WFS receipts below prove exposure completion.
    Native.await(owner.wakeup, owner.guard, Float64(deadline)) do
        check(owner)
        Wire.pipewire_calibration_status(owner.hil).frame_publication_cycle_sequence == exposure.identity.sequence
    end
    with_thread_loop_lock(owner.hil.loop) do _
        trigger_process!(owner.hil.frame_stream)
    end
    values = CalibrationCapture.await!(owner.capture; deadline=Float64(deadline), check=() -> check(owner))
    exposure.probe_sequence == owner.token || error("exposure belongs to another probe")
    check(owner)
    start = UInt64(exposure.timestamp.nanoseconds)
    duration = exposure.exposure_duration_nanoseconds
    identity = exposure.identity
    identity.domain == owner.acquisition_domain && identity.generation == owner.cursor.generation ||
        error("exposure acquisition domain or generation changed")
    Wire.complete_pipewire_exposure!(owner.hil, exposure)
    # One initial session binds exactly one full wire domain to coordinator ID 1.
    # The full domain remains in owner.acquisition_domain and every raw/WFS receipt.
    domain = owner.cursor.domain
    owner.cursor = Actions.AcquisitionCursor(domain, identity.generation,
        identity.sequence, Base.Checked.checked_add(start, duration))
    return values, Actions.Exposure(domain, identity.generation, identity.sequence, start, duration)
end

settle!(owner::InitialCalibration, ::Actions.Immediate, deadline) = check(owner)
function settle!(owner::InitialCalibration, rule::Actions.DiscardExposures, deadline)
    for _ in 1:rule.frames
        exposure!(owner, deadline)
    end
end
function settle!(owner::InitialCalibration, rule::Actions.ModelTime, deadline)
    boundary = Base.Checked.checked_add(owner.cursor.model_ns, rule.duration_ns)
    while owner.cursor.model_ns < boundary
        exposure!(owner, deadline)
    end
end

function (owner::InitialCalibration)(::Actions.Hold, deadline)
    actual, clipped = adopt!(owner, owner.reference, deadline)
    clipped && return Actions.Failed(Actions.ProbeClipped)
    owner.restored = true
    return Actions.Held(owner.cursor)
end
function (owner::InitialCalibration)(action::Actions.Adopt, deadline)
    expected = owner.probe === nothing ? UInt32(0) : Base.Checked.checked_add(owner.probe, UInt32(1))
    action.probe == expected || return Actions.Failed(Actions.InvalidEvidence)
    actual, clipped = adopt!(owner, action.figure, deadline)
    owner.probe = action.probe
    return Actions.Adopted(owner.cursor, actual, clipped)
end
function (owner::InitialCalibration)(action::Actions.Settle, deadline)
    action.probe == owner.probe && action.after == owner.cursor ||
        return Actions.Failed(Actions.InvalidEvidence)
    settle!(owner, action.rule, deadline)
    return Actions.Settled(owner.cursor)
end
function (owner::InitialCalibration)(action::Actions.Collect, deadline)
    action.probe == owner.probe && action.after == owner.cursor ||
        return Actions.Failed(Actions.InvalidEvidence)
    measurements = prod(JuliaFilterGraph.output_formats(owner.graphs.frontend.graph).slopes.shape)
    action.measurements == measurements || return Actions.Failed(Actions.InvalidEvidence)
    # Response order is the deployed estimator's logical row-major order, as in
    # the existing SH AOC reduction. Acquisition averages in Float32 online.
    mean = zeros(Float32, measurements)
    exposures = Actions.Exposure[]
    valid = true
    for _ in 1:action.frames
        values, exposure = exposure!(owner, deadline)
        push!(exposures, exposure)
        valid &= all(i -> !owner.active[i] || values.arrays.validity[i], eachindex(owner.active))
        flattened = vec(permutedims(values.arrays.slopes))
        valid &= all(isfinite, flattened)
        mean .+= flattened ./ Float32(action.frames)
    end
    return Actions.Responses(mean, exposures, valid)
end
function (owner::InitialCalibration)(action::Actions.Restore, deadline)
    action.figure == owner.reference || return Actions.Failed(Actions.InvalidEvidence)
    actual, clipped = adopt!(owner, owner.reference, deadline)
    settle!(owner, action.rule, deadline)
    owner.restored = !clipped && actual == owner.reference
    return Actions.Restored(actual, clipped)
end
function (owner::InitialCalibration)(::Actions.Release, deadline)
    check(owner)
    owner.restored || return Actions.Failed(Actions.InvalidEvidence)
    stop!(owner.hil)
    return Actions.Released()
end
(owner::InitialCalibration)(::Actions.Capture, deadline) = Actions.Failed(Actions.InvalidEvidence)

function Base.close(owner::InitialCalibration)
    owner.closed && return nothing
    owner.closed = true
    errors = Exception[]
    try stop!(owner.hil) catch error; push!(errors, error) end
    for worker in values(owner.workers)
        try quit_calibration_graph!(worker) catch error; push!(errors, error) end
    end
    deadline = Control.monotonic() + 30
    for worker in values(owner.workers)
        try
            Native.await(() -> istaskdone(worker.task), owner.wakeup, owner.guard, deadline)
            fetch(worker.task)
        catch error
            push!(errors, error)
        end
    end
    with_thread_loop_lock(owner.hil.loop) do _
        for resource in (owner.capture, owner.transport, reverse(owner.links)..., owner.frame_listener, owner.listener, owner.registry)
            try close(resource) catch error; push!(errors, error) end
        end
    end
    try close(owner.hil) catch error; push!(errors, error) end
    # Prepared storage cannot be destroyed while a native graph owner still runs.
    if all(worker -> istaskdone(worker.task), values(owner.workers))
        for descriptor in values(owner.graphs)
            try FilterGraphIsland.close_execution(descriptor.graph) catch error; push!(errors, error) end
        end
    end
    isempty(errors) || throw(CompositeException(errors))
    return nothing
end

function calibration_link(core, registry, output, output_name, input, input_name)
    function port(node, direction, name)
        candidates = find_globals(registry; interface="PipeWire:Interface:Port",
            properties=("node.id"=>string(node_id(node)), "port.direction"=>direction))
        name === nothing || filter!(entry -> get(entry.properties, "port.name", nothing) == String(name), candidates)
        length(candidates) == 1 || error("initial calibration link has an absent or ambiguous port")
        return only(candidates).id
    end
    return with_thread_loop_lock(main_loop(core)) do _
        out, into = port(output, "out", output_name), port(input, "in", input_name)
        create_object(core, "link-factory", PipeWireAO.Link; properties=Dict(
            "link.output.node"=>string(node_id(output)), "link.output.port"=>string(out),
            "link.input.node"=>string(node_id(input)), "link.input.port"=>string(into),
            "object.linger"=>"false"))
    end
end

wire_type(::Type{UInt16}) = NdArray.U16_LE
wire_type(::Type{Float32}) = NdArray.F32_LE
wire_type(::Type{Bool}) = NdArray.BOOL8
function capture_format(format, rate)
    return NdArrayFormat(wire_type(format.element_type), format.shape;
        rate, layout=NdArray.ROW_MAJOR)
end

"""
    prepare_initial_calibration(application, remote, frontend, command;
        reference, name, instance, deadline, active=frontend.parameters[:active])

Prepare a non-actuating CPU initial-calibration endpoint from two cold projections
of the built regular graph. `frontend` exposes raw→slopes/flux/validity; `command`
exposes absolute requested→demanded/constraint-feedback. Reference/probes use the
command graph's declared physical wire units. No flat/offset is added here.
Both descriptors transfer ownership to this endpoint. Its lifetime is one native
run; call `NativeCalibrationEndpoint.serve!` and close it explicitly afterwards.
Requires at least three Julia default threads for two blocking native graph loops
and the control owner. This is an initial SH interface, not running-loop state
preservation, multi-corrector/multi-WFS support or physical authorization.
"""
function Calibration.prepare_initial_calibration(application, remote, frontend, command;
        reference::AbstractVector{Float32}, name::AbstractString, instance::Int64,
        deadline::Real, active=frontend.parameters[:active])
    Threads.nthreads(:default) >= 3 || throw(ArgumentError("initial calibration requires at least three Julia threads"))
    remote = Control.private_remote(remote)
    Calibration.require_prepared_application(application)
    authority = Calibration.digest(joinpath(application, "rtc", "graph.conf"))
    frontend.source_graph_sha256 == command.source_graph_sha256 == authority ||
        throw(ArgumentError("calibration projections must share this application's regular graph"))
    selected = GraphOwner.bindings(joinpath(application, "rtc", "parameters.conf"))
    frontend, command = map((frontend, command)) do descriptor
        formats = JuliaFilterGraph.parameter_formats(descriptor.graph)
        entries = filter(entry -> haskey(formats, entry.port), selected)
        Set(entry.port for entry in entries) == Set(keys(formats)) == Set(keys(descriptor.parameters)) ||
            throw(ArgumentError("calibration projection parameter ports differ from the selected bindings"))
        updates = GraphOwner.prepare_bindings(entries, formats)
        all(pair -> isequal(last(pair), descriptor.parameters[first(pair)]), updates) ||
            throw(ArgumentError("calibration projection parameters differ from the selected FITS inputs"))
        isempty(updates) || JuliaFilterGraph.replace_parameters!(descriptor.graph, updates...)
        merge(descriptor, (; bindings=entries, parameters=Dict{Symbol,Array}(updates)))
    end
    format = JuliaFilterGraph.input_formats(command.graph).requested
    length(format.shape) == 1 && format.element_type === Float32 &&
        length(reference) == only(format.shape) && all(isfinite, reference) ||
        throw(ArgumentError("reference must match the absolute physical command port"))
    outputs = JuliaFilterGraph.output_formats(frontend.graph)
    active isa AbstractVector{Bool} && length(active) == prod(outputs.validity.shape) &&
        active == frontend.parameters[:active] ||
        throw(ArgumentError("frozen active mask must match estimator validity"))
    options = PipeWireAORTC.AOSOwner.configuration(joinpath(application, "simulation.conf"))
    options.command_input isa Symbol || throw(ArgumentError("held calibration requires one named command"))
    options.backend === :cpu || throw(ArgumentError("initial calibration requires a built CPU application"))
    wakeup, guard = Base.AsyncCondition(), ReentrantLock()
    notify() = Native.wake!(wakeup, guard)
    hil = capture = probe = registry = listener = frame_listener = owner = nothing
    links = PipeWireAO.Link[]
    workers = CalibrationGraphWorker[]
    try
        # Use normal configured noise/ADC and graph settings; the noise-free
        # calibration oracle and hidden optical outputs are not read.
        science = IC.prepare_system(options.plant.definition; settings=options.plant.settings,
            target=AdaptiveOpticsSim.Backends.HostComputeDevice(), execution=HIL.StreamGraphExecution())
        boundary = HIL.prepare_graph_calibration_boundary(science.graph;
            command_input=options.command_input, frame_output=options.frame_output)
        configuration = Wire.PipeWireHILConfiguration(remote=remote,
            frame_node_name=name*".detector", command_node_name=name*".command",
            frame_schema=options.frame_schema, command_schema=options.command_schema,
            rate=SPA.Fraction(UInt32(options.rate), UInt32(1)),
            exposure_duration_ns=options.exposure_ns, frame_encoding=options.frame_encoding,
            command_scale=options.command_scale,
            timeout_ns=UInt64(Control.budget_ns(Actions.PROFILE, Float64(deadline-Control.monotonic()))))
        hil = Wire.prepare_pipewire_calibration(boundary, configuration)
        rate = UInt32(options.rate)//UInt32(1)
        frame_format = JuliaFilterGraph.input_formats(frontend.graph).raw
        declarations = (; raw=(name=name*".raw",format=capture_format(frame_format, configuration.rate),schema=frame_format.schema),
            (key => (name=name*"."*String(key), format=capture_format(getproperty(outputs,key),configuration.rate),
                schema=getproperty(outputs,key).schema) for key in (:slopes,:flux,:validity))...)
        capture = CalibrationCapture.Capture(hil.core, declarations; wakeup, wakeup_lock=guard)
        feedback = JuliaFilterGraph.output_formats(command.graph)[Symbol("constraint-feedback")]
        probe = prepare_calibration_probe(hil.core, format, format.schema, feedback, feedback.schema,
            configuration.rate; notify)
        with_thread_loop_lock(hil.loop) do _
            registry = Registry(hil.core)
            listener = add_listener!(registry; on_global_added=(_...)->(notify();nothing),
                on_global_removed=(_...)->(notify();nothing))
            frame_listener = add_listener!(hil.frame_stream; on_trigger_done=(_...)->(notify();nothing))
        end
        push!(workers, start_calibration_graph(frontend,remote,name*".wfs",rate;notify))
        push!(workers, start_calibration_graph(command,remote,name*".pdm",rate;notify))
        Native.await(wakeup, guard, Float64(deadline)) do
            for worker in values(workers)
                if istaskdone(worker.task)
                    fetch(worker.task)
                    worker.error[] === nothing || throw(worker.error[])
                    error("calibration graph stopped during preparation")
                end
            end
            all(worker -> worker.ready[] && node_id(worker.node[]) !== nothing, workers)
        end
        roundtrip(registry)
        front_node, command_node = workers[1].node[], workers[2].node[]
        for arguments in ((hil.frame_stream,nothing,front_node,:raw),
                (hil.frame_stream,nothing,capture.streams.raw,nothing),
                (probe.source,nothing,command_node,:requested),
                (command_node,:demanded,hil.command_stream,nothing),
                (command_node,Symbol("constraint-feedback"),probe.feedback,nothing),
                ((front_node,key,getproperty(capture.streams,key),nothing) for key in (:slopes,:flux,:validity))...)
            push!(links, calibration_link(hil.core,registry,arguments...))
        end
        roundtrip(hil.core)
        start!(capture)
        with_thread_loop_lock(hil.loop) do _
            set_active!(probe.feedback, true)
            set_active!(probe.source, true)
        end
        start!(hil)
        status = Wire.pipewire_calibration_status(hil)
        cursor = Actions.AcquisitionCursor(UInt64(1), status.acquisition_generation,
            UInt64(0), UInt64(0))
        owner = InitialCalibration(hil, science.driver, capture, probe, workers,
            (;frontend,command), registry, listener, frame_listener, links, collect(reference), collect(active),
            UInt64(0), nothing, cursor, status.acquisition_domain, false, wakeup, guard, nothing, false)
        endpoint = Native.Endpoint(remote, name, instance, owner; wakeup, wakeup_lock=guard)
        owner.control = endpoint
        return endpoint
    catch primary
        errors = Exception[primary]
        if owner !== nothing
            try close(owner) catch error; push!(errors,error) end
        else
            if hil !== nothing
                with_thread_loop_lock(hil.loop) do _
                    for resource in (capture,probe,reverse(links)...,frame_listener,listener,registry)
                        resource === nothing && continue
                        try close(resource) catch error; push!(errors,error) end
                    end
                end
            end
            if !isempty(workers)
                for worker in values(workers)
                    try quit_calibration_graph!(worker) catch error; push!(errors,error) end
                end
                for worker in values(workers)
                    try
                        Native.await(() -> istaskdone(worker.task), wakeup, guard, Control.monotonic()+30)
                        fetch(worker.task)
                    catch error
                        push!(errors,error)
                    end
                end
            end
            hil === nothing || try close(hil) catch error; push!(errors,error) end
            if all(worker -> istaskdone(worker.task), workers)
                for descriptor in (frontend,command)
                    try FilterGraphIsland.close_execution(descriptor.graph) catch error; push!(errors,error) end
                end
            end
        end
        lock(guard) do
            isopen(wakeup) && close(wakeup)
        end
        length(errors) == 1 && rethrow()
        throw(CompositeException(errors))
    end
end
