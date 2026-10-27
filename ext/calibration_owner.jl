# Initial sessions own their graphs and held-probe endpoints exclusively. All
# scientific samples arrive over the same transport as deployed measurements.
using PipeWireAO
using UUIDs: uuid4
const Actions = PipeWireAORTC.NativeCalibrationActionCodec
const Native = PipeWireAORTC.NativeCalibrationEndpoint
const Control = PipeWireAORTC.NativeControlClient
const Wire = AdaptiveOpticsSimPipeWireHIL

mutable struct InitialCalibration{P,D,C,T,W,G,S,F}
    hil::P
    driver::D
    capture::C
    capture_store::S
    consume::F
    consumer_failed::Bool
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
    owner.consumer_failed && return Actions.Failed(Actions.InvalidEvidence)
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
        # Freeze native response evidence before lending sample storage to the
        # reducer. A consumer cannot clear intrinsic rejection or rewrite the
        # transported response by mutating its borrowed arrays.
        valid &= all(i -> !owner.active[i] || values.arrays.validity[i], eachindex(owner.active))
        flattened = vec(permutedims(values.arrays.slopes))
        valid &= all(isfinite, flattened)
        mean .+= flattened ./ Float32(action.frames)
        if owner.consume !== nothing && !owner.consumer_failed
            try
                owner.consume(values, exposure)
            catch
                # The correlated exposure is already complete. Finish this
                # bounded action truthfully, then permit explicit restoration;
                # transport/owner failures still escape and fence the endpoint.
                owner.consumer_failed = true
            end
        end
        valid &= !owner.consumer_failed
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
function (owner::InitialCalibration)(action::Actions.Capture, deadline)
    owner.capture_store === nothing && return Actions.Failed(Actions.InvalidEvidence)
    action.probe == owner.probe && action.after == owner.cursor ||
        return Actions.Failed(Actions.InvalidEvidence)
    check(owner)
    run, serial = owner.control.run, owner.control.serial
    # Only pre-effect validation becomes a known rejection. A write/acquisition
    # failure after admission retains the dispatcher's unknown-outcome fence.
    try
        Calibration.capture_preflight(owner.capture_store; run,serial,probe=action.probe,
            cursor=owner.cursor,frames=action.frames,deadline=Float64(deadline),check=()->check(owner))
    catch error
        error isa ArgumentError || rethrow()
        return Actions.Failed(Actions.InvalidEvidence)
    end
    return Calibration.capture!(owner.capture_store, () -> exposure!(owner,deadline);
        run,serial,probe=action.probe,cursor=owner.cursor,frames=action.frames,
        deadline=Float64(deadline),check=()->check(owner))
end

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

function calibration_endpoint(registry, node, direction, name)
    nodes = if node isa AbstractString
        find_globals(registry; interface="PipeWire:Interface:Node", properties=("node.name"=>node,))
    else
        id = node_id(node)
        entry = id === nothing ? nothing : find_global(registry, id)
        entry === nothing ? PipeWireAO.Global[] : [entry]
    end
    length(nodes) <= 1 || error("initial calibration node is ambiguous")
    isempty(nodes) && return nothing
    current = only(nodes)
    current.type == "PipeWire:Interface:Node" || error("initial calibration endpoint is not a node")
    ports = find_globals(registry; interface="PipeWire:Interface:Port",
        properties=("node.id"=>string(current.id), "port.direction"=>direction))
    name === nothing || filter!(entry -> get(entry.properties, "port.name", nothing) == String(name), ports)
    length(ports) <= 1 || error("initial calibration port is ambiguous")
    isempty(ports) && return nothing
    port = only(ports)
    all(entry -> haskey(entry.properties, "object.serial"), (current, port)) ||
        error("initial calibration endpoints require object serials")
    return (; node=current, port)
end

function calibration_incarnation_present(registry, endpoint)
    return all((endpoint.node, endpoint.port)) do original
        current = find_global(registry, original.id)
        current !== nothing && get(current.properties, "object.serial", nothing) ==
            original.properties["object.serial"]
    end
end

function calibration_link(core, registry, output, input; on_info, on_removed=nothing, on_error=nothing)
    return with_thread_loop_lock(main_loop(core)) do _
        all(endpoint -> calibration_incarnation_present(registry, endpoint), (output, input)) ||
            error("initial calibration endpoint changed before linking")
        create_object(core, "link-factory", PipeWireAO.Link; on_info, on_removed, on_error, properties=Dict(
            "link.output.node"=>string(output.node.id), "link.output.port"=>string(output.port.id),
            "link.input.node"=>string(input.node.id), "link.input.port"=>string(input.port.id),
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
        reference, name, instance, deadline, active=frontend.parameters[:active],
        simulation_graph="production", capture_directory=nothing,
        capture_stage=nothing, capture_maximum_bytes=0)

Prepare a non-actuating CPU initial-calibration endpoint from two cold projections
of the built regular graph. `frontend` exposes raw→slopes/flux/validity; `command`
exposes absolute requested→demanded/constraint-feedback. Reference/probes use the
command graph's declared physical wire units. No flat/offset is added here.
Both descriptors transfer ownership to this endpoint. Its lifetime is one native
run; call `NativeCalibrationEndpoint.serve!` and close it explicitly afterwards.
Requires at least three Julia default threads for two blocking native graph loops
and the control owner. This is an initial SH interface, not running-loop state
preservation, multi-corrector/multi-WFS support or physical authorization.
`simulation_graph="internal-source"` selects that explicitly declared AOS graph
while retaining the regular RTC graph and normal production detector nodes.
`simulation_graph="dark"` selects declared zero incident photon rate with the
same detector electronics. This models blocked light, not a noise-free camera.
The ideal diagnostic `calibration` graph is not an operational selection.
Classic may enable the native Capture action with a fresh `capture_directory`,
explicit `capture_stage` and positive cumulative `capture_maximum_bytes`.
Capture preserves intrinsic invalidity and writes bounded immutable evidence;
it does not accept interaction responses or replace active calibration.
`consume(sample, exposure)` optionally reduces each completed Collect exposure
on the control task, before another exposure. Sample arrays are borrowed read-only until
the callback returns; retain only owned numerical state or explicit copies.
Discarded settling, restoration and Capture exposures are not delivered to it.
The callback must do bounded work. A callback exception latches
`effects.consumer_failed`, completes the current bounded batch with false
validity and rejects later Collect requests; explicit Restore/Release remain
available. Transport/identity failures retain their unknown-outcome fence.
Explicit typed FITS sources in a frontend projection may replace only background,
active mask and WFS reference. Their prepared byte hashes and arrays are checked
again before startup. Original graph topology, coordinates and thresholds remain
the authority; no live parameter update stands in for startup adoption.
"""
function Calibration.prepare_initial_calibration(application, remote, frontend, command;
        reference::AbstractVector{Float32}, name::AbstractString, instance::Int64,
        deadline::Real, active=frontend.parameters[:active], simulation_graph::AbstractString="production",
        capture_directory=nothing, capture_stage=nothing,capture_maximum_bytes::Integer=0,
        consume=nothing)
    Threads.nthreads(:default) >= 3 || throw(ArgumentError("initial calibration requires at least three Julia threads"))
    remote = Control.private_remote(remote)
    Calibration.require_prepared_application(application)
    authority = Calibration.digest(joinpath(application, "rtc", "graph.conf"))
    frontend.source_graph_sha256 == command.source_graph_sha256 == authority ||
        throw(ArgumentError("calibration projections must share this application's regular graph"))
    selected = GraphOwner.bindings(joinpath(application, "rtc", "parameters.conf"))
    frontend, command = map((frontend, command),(:frontend,:command)) do descriptor,role
        formats = JuliaFilterGraph.parameter_formats(descriptor.graph)
        entries = filter(entry -> haskey(formats, entry.port), selected)
        Set(entry.port for entry in entries) == Set(keys(formats)) == Set(keys(descriptor.parameters)) ||
            throw(ArgumentError("calibration projection parameter ports differ from the selected bindings"))
        sources = descriptor.parameter_sources
        allowed = role === :frontend ? Set((:background,:active,Symbol("reference-slopes"))) : Set{Symbol}()
        Set(keys(sources)) ⊆ allowed ||
            throw(ArgumentError("initial calibration overrides are restricted to background, mask and reference"))
        expected = [GraphOwner.FITSBinding(entry.port,get(sources,entry.port,entry.source)) for entry in entries]
        same_source(a,b) = a.port == b.port && a.source.path == b.source.path &&
            a.source.hdu == b.source.hdu && a.source.axes == b.source.axes
        length(expected) == length(descriptor.bindings) &&
            all(pair -> same_source(pair...),zip(expected,descriptor.bindings)) ||
            throw(ArgumentError("calibration projection FITS bindings differ from explicit stage sources"))
        entries = expected
        artifacts = GraphOwner.prepare_artifacts(entries, formats)
        all(pair -> last(pair).provenance["original_sha256"] == descriptor.parameter_sha256[first(pair)],artifacts) ||
            throw(ArgumentError("calibration parameter source changed after projection preparation"))
        updates = [port => artifact.data for (port, artifact) in artifacts]
        all(pair -> isequal(last(pair), descriptor.parameters[first(pair)]), updates) ||
            throw(ArgumentError("calibration projection parameters differ from the selected FITS inputs"))
        isempty(updates) || JuliaFilterGraph.replace_parameters!(descriptor.graph, updates...)
        provenance = Dict(port => filter(pair -> first(pair) != "source", artifact.provenance)
            for (port, artifact) in artifacts)
        merge(descriptor, (; bindings=entries, parameters=Dict{Symbol,Array}(updates), provenance))
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
    simulation_graph in ("production","internal-source","dark") ||
        throw(ArgumentError("unsupported operational simulation graph"))
    declaration = IC.load_simulation(options.plant.definition)
    configured = IC.settings(declaration,options.plant.settings)
    selected = IC.graph_document(declaration,configured;simulation_graph)
    production = IC.graph_document(declaration,configured)
    detectors(graph) = Dict(node["name"]=>node for node in graph["nodes"] if node["type"] == "detector")
    detectors(selected) == detectors(production) ||
        throw(ArgumentError("operational calibration must retain normal production detector configuration"))
    capture_store = if capture_directory === nothing
        capture_stage === nothing && capture_maximum_bytes == 0 ||
            throw(ArgumentError("capture settings require a fresh capture directory"))
        nothing
    else
        declaration.document["id"] == "revolt-classic" ||
            throw(ArgumentError("capture storage requires the declared Classic profile"))
        raw = JuliaFilterGraph.input_formats(frontend.graph).raw
        for (role,contract) in pairs(Calibration.CLASSIC_CAPTURE_CONTRACTS)
            payload_format = role === :raw ? raw : getproperty(outputs,role)
            payload_format.element_type === contract.type && Tuple(payload_format.shape) == contract.shape ||
                throw(ArgumentError("capture graph differs from the fixed Classic payload contract"))
        end
        capture_stage isa AbstractString || throw(ArgumentError("capture stage must be explicit"))
        identities(projection) = Dict(String(port)=>Dict(key=>identity[key]
            for key in ("original_sha256","sha256","hdu","axes","target_type","target_shape"))
            for (port,identity) in projection.provenance)
        settings = Dict{String,Any}("simulation_graph"=>simulation_graph,
            "prescription_identity"=>IC.prescription_identity(declaration,configured),
            "plant_settings"=>IC.json_value(configured),"detectors"=>detectors(production),
            "rtc_graph_sha256"=>authority,
            "frontend_parameters"=>identities(frontend),"command_parameters"=>identities(command),
            "exposure_ns"=>options.exposure_ns,"rate"=>options.rate,
            "frame_schema"=>options.frame_schema,"command_schema"=>options.command_schema,
            "command_scale"=>options.command_scale,"reference"=>collect(reference))
        Calibration.CaptureStore(capture_directory;stage=String(capture_stage),
            illumination=simulation_graph == "production" ? "on-sky" : simulation_graph,
            settings,maximum_bytes=capture_maximum_bytes)
    end
    wakeup, guard = Base.AsyncCondition(), ReentrantLock()
    notify() = Native.wake!(wakeup, guard)
    hil = capture = probe = registry = listener = frame_listener = owner = nothing
    links = PipeWireAO.Link[]
    workers = CalibrationGraphWorker[]
    try
        # Use normal configured noise/ADC and graph settings; the noise-free
        # calibration oracle and hidden optical outputs are not read.
        science = IC.prepare_system(options.plant.definition; settings=options.plant.settings, simulation_graph,
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
        graph_name = "calibration."*string(uuid4())
        front_node, command_node = graph_name*".wfs", graph_name*".pdm"
        push!(workers, start_calibration_graph(frontend,remote,front_node,rate;notify))
        push!(workers, start_calibration_graph(command,remote,command_node,rate;notify))
        function check_workers()
            for worker in values(workers)
                if istaskdone(worker.task)
                    fetch(worker.task)
                    worker.error[] === nothing || throw(worker.error[])
                    error("calibration graph stopped during preparation")
                end
            end
            return all(worker -> worker.ready[], workers)
        end
        # Registry callbacks publish and notify this exact discovery state.
        # A worker's client-side node_id can become visible after the registry
        # event without another wake, so it is not a readiness predicate.
        connections = ((hil.frame_stream,nothing,front_node,:raw),
                (hil.frame_stream,nothing,capture.streams.raw,nothing),
                (probe.source,nothing,command_node,:requested),
                (command_node,:demanded,hil.command_stream,nothing),
                (command_node,Symbol("constraint-feedback"),probe.feedback,nothing),
                ((front_node,key,getproperty(capture.streams,key),nothing) for key in (:slopes,:flux,:validity))...)
        endpoints = Native.await(wakeup, guard, Float64(deadline)) do
            check_workers() || return nothing
            with_thread_loop_lock(hil.loop) do _
                candidates = map(connections) do (output, out_name, input, in_name)
                    (calibration_endpoint(registry,output,"out",out_name),
                        calibration_endpoint(registry,input,"in",in_name))
                end
                all(pair -> all(!isnothing,pair), candidates) ? candidates : nothing
            end
        end
        states = Threads.Atomic{Int}[]
        for (output, input) in endpoints
            state = Threads.Atomic{Int}(Int(PipeWireAO.LINK_STATE_INIT))
            push!(states, state)
            function failed(_...)
                state[] = Int(PipeWireAO.LINK_STATE_ERROR)
                notify()
                return nothing
            end
            link = calibration_link(hil.core,registry,output,input;
                on_removed=failed, on_error=failed, on_info=(_, info) -> begin
                matches = (info.output_node_id, info.output_port_id, info.input_node_id, info.input_port_id) ==
                    (output.node.id, output.port.id, input.node.id, input.port.id)
                if !matches || info.state in (PipeWireAO.LINK_STATE_ERROR,PipeWireAO.LINK_STATE_UNLINKED)
                    return failed()
                end
                state[] == Int(PipeWireAO.LINK_STATE_ERROR) || (state[] = Int(info.state))
                notify()
                nothing
            end)
            push!(links, link)
        end
        start!(capture)
        with_thread_loop_lock(hil.loop) do _
            set_active!(probe.feedback, true)
            set_active!(probe.source, true)
        end
        Native.await(wakeup, guard, Float64(deadline)) do
            check_workers() || return false
            with_thread_loop_lock(hil.loop) do _
                all(pair -> all(endpoint -> calibration_incarnation_present(registry,endpoint),pair), endpoints) ||
                    error("initial calibration endpoint changed while linking")
            end
            any(state -> state[] == Int(PipeWireAO.LINK_STATE_ERROR), states) && error("initial calibration link failed")
            all(state -> state[] in (Int(PipeWireAO.LINK_STATE_PAUSED),Int(PipeWireAO.LINK_STATE_ACTIVE)), states)
        end
        start!(hil)
        status = Wire.pipewire_calibration_status(hil)
        cursor = Actions.AcquisitionCursor(UInt64(1), status.acquisition_generation,
            UInt64(0), UInt64(0))
        owner = InitialCalibration(hil, science.driver, capture, capture_store, consume, false, probe, workers,
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
