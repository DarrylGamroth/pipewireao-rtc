# Admission for published correction/recovery controls; no scientific mutations.
const CORRECTION_PREFIX = "pipewireao.correction-control."
const RECOVERY_PREFIX = "pipewireao-recovery:"
function correction_status_field(name::AbstractString)
    startswith(name, CORRECTION_PREFIX) || return false
    suffix = chopprefix(name, CORRECTION_PREFIX)
    suffix in ("version", "owner-instance") ||
        occursin(r"^[^:]+:[^:]+\.(state|fault|requested|primed)$", suffix)
end
required_value(values, name) = get(values, name) do
    throw(ArgumentError("missing correction status: $name"))
end
correction_long(values, name) = policy_long(required_value(values, name))
correction_int(values, name) = policy_int(required_value(values, name))
correction_bool(values, name) = policy_bool(required_value(values, name))
correction_text(values, name) = policy_text(required_value(values, name))
function correction_owner_instance(configuration, name)
    pid = get(configuration["node.pids"], name, nothing)
    pid !== nothing && pid > 0 || throw(ArgumentError("correction graph owner PID missing"))
    instance = nothing
    for declaration in configuration["owners"]
        if haskey(declaration, "bootstrap-node") && declaration["pid"] == pid
            instance === nothing || throw(ArgumentError("ambiguous correction graph owner"))
            instance = tryparse(Int64, string(declaration["bootstrap-instance"]))
            instance !== nothing && instance > 0 ||
                throw(ArgumentError("correction graph owner incarnation missing"))
        end
    end
    instance !== nothing ||
        throw(ArgumentError("correction graph has no declared bootstrap owner"))
    return instance
end
"""Validate native correction evidence under the Hsm's admitted origin.

Ready-origin transactions may update ordinary scalars, but cannot toggle
correction or request/release protective recovery. Running-origin transactions
still require the exact owner incarnation, running group and native Run proof.
"""
correction_running!(runtime, ::ReadyOrigin, name, values) =
    throw(ArgumentError("correction control requires a running session"))
function correction_running!(runtime, ::RunningOrigin, name, values)
    correction_long(values, CORRECTION_PREFIX * "owner-instance") ==
    correction_owner_instance(runtime.configuration, name) ||
        throw(ArgumentError("correction graph owner incarnation changed"))
    admitted = false
    for group in Base.values(runtime.groups)
        if name in group.nodes
            group.running || throw(ArgumentError("correction execution group is stopped"))
            admitted = true
        end
    end
    admitted || throw(ArgumentError("correction graph has no running execution group"))
    correction_text(values, "pipewireao.run-control.actual-state") == "running" ||
        throw(ArgumentError("correction graph owner is stopped"))
    return nothing
end
function recovery_reference_fresh(values, current_ns::Int64)
    timestamp = correction_long(
        values, RECOVERY_PREFIX * "observation-monotonic-nanoseconds"
    )
    timeout_ms = correction_int(values, RECOVERY_PREFIX * "reference-timeout-ms")
    return 1 <= timeout_ms <= 60000 &&
           timestamp > 0 &&
           timestamp <= current_ns &&
           current_ns - timestamp < Int64(timeout_ms) * 1_000_000
end
function recovery_reference_confirmed(values, current_ns::Int64)
    correction_bool(values, RECOVERY_PREFIX * "reference-reached") &&
        correction_long(values, RECOVERY_PREFIX * "observation-sequence") > 0 &&
        recovery_reference_fresh(values, current_ns)
end
function coupled_recovery_controllers(values)
    count = correction_int(values, RECOVERY_PREFIX * "controller-count")
    1 <= count <= 16 || throw(ArgumentError("invalid recovery controller count"))
    controllers = map(1:Int(count)) do index
        field = RECOVERY_PREFIX * "controller-$index"
        name = correction_text(values, field)
        occursin(r"^[a-zA-Z0-9_.-]{1,128}$", name) ||
            throw(ArgumentError("invalid recovery controller"))
        guarded = correction_bool(values, field * "-close-guarded")
        ready = correction_bool(values, field * "-ready")
        sequence = correction_long(values, field * "-observation-sequence")
        timestamp = correction_long(values, field * "-observation-monotonic-nanoseconds")
        sequence >= 0 && timestamp >= 0 ||
            throw(ArgumentError("invalid recovery controller observation"))
        (; name, guarded, ready, sequence, timestamp)
    end
    allunique(controller -> controller.name, controllers) ||
        throw(ArgumentError("duplicate recovery controllers"))
    return controllers
end

function require_coherent_controller(values, controller)
    target = controller * ":closed"
    key = CORRECTION_PREFIX * target
    current = correction_text(values, key * ".state")
    current in ("Open", "Closed") || throw(ArgumentError("correction state is not ready"))
    isempty(correction_text(values, key * ".fault")) ||
        throw(ArgumentError("correction fault is latched"))
    requested = correction_long(values, controller * ":requested-generation")
    requested >= 0 &&
    requested == correction_long(values, controller * ":active-generation") ||
        throw(ArgumentError("correction property adoption is pending"))
    active = correction_bool(values, target)
    (current == "Closed") == active && correction_bool(values, key * ".requested") == active ||
        throw(ArgumentError("inconsistent correction state"))
    return active
end

function check_coupled_recovery!(runtime, origin, name, values, updates, request, release)
    controllers = coupled_recovery_controllers(values)
    state = correction_text(values, RECOVERY_PREFIX * "state")
    inhibited = correction_bool(values, RECOVERY_PREFIX * "closure-inhibited")
    state in ("idle", "pending", "applied", "release_pending", "release_refused", "released") ||
        throw(ArgumentError("unknown recovery state"))
    inhibited == (state in ("pending", "applied", "release_pending", "release_refused")) ||
        throw(ArgumentError("inconsistent recovery inhibition"))
    if request === nothing && release === nothing
        !inhibited ||
            throw(ArgumentError("protective recovery inhibits scientific updates"))
        closes = filter(controllers) do controller
            close = get(updates, controller.name * ":closed", nothing)
            controller.guarded && close !== nothing && policy_bool(close)
        end
        isempty(closes) && return nothing
        all(updates) do update
            property, value = update
            any(controller -> property == controller.name * ":closed", controllers) &&
                policy_bool(value)
        end || throw(ArgumentError("recovery close cannot mix other control requests"))
        correction_running!(runtime, origin, name, values)
        foreach(controller -> require_coherent_controller(values, controller.name), controllers)
        generation = correction_long(values, RECOVERY_PREFIX * "recovery-generation")
        state == "released" && generation > 0 &&
        correction_long(values, RECOVERY_PREFIX * "release-token") == generation &&
        correction_long(values, RECOVERY_PREFIX * "requested-generation") ==
        correction_long(values, RECOVERY_PREFIX * "active-generation") ||
            throw(ArgumentError("recovery release has not been adopted"))
        timeout = correction_int(values, RECOVERY_PREFIX * "reference-timeout-ms")
        current_ns = now(runtime)
        1 <= timeout <= 60000 && all(closes) do controller
            controller.ready && controller.sequence > 0 &&
            0 < controller.timestamp <= current_ns &&
            current_ns - controller.timestamp < Int64(timeout) * 1_000_000
        end || throw(ArgumentError("selected controller recovery reference is not confirmed"))
        return nothing
    end

    length(updates) == 1 && !(request !== nothing && release !== nothing) ||
        throw(ArgumentError("recovery requires one unmixed control request"))
    correction_running!(runtime, origin, name, values)
    correction_int(values, CORRECTION_PREFIX * "version") == 1 ||
        throw(ArgumentError("unsupported correction-control version"))
    closed = map(controller -> require_coherent_controller(values, controller.name), controllers)
    correction_long(values, RECOVERY_PREFIX * "requested-generation") ==
    correction_long(values, RECOVERY_PREFIX * "active-generation") ||
        throw(ArgumentError("recovery adoption is pending"))
    if request !== nothing
        !inhibited || throw(ArgumentError("protective recovery is already inhibited"))
        token = policy_long(request)
        token > 0 && token > correction_long(values, RECOVERY_PREFIX * "request-token") ||
            throw(ArgumentError("recovery request token must advance"))
    else
        inhibited && !any(closed) ||
            throw(ArgumentError("recovery release requires inhibited open controllers"))
        generation = correction_long(values, RECOVERY_PREFIX * "recovery-generation")
        generation > 0 && policy_long(release) == generation ||
            throw(ArgumentError("recovery release generation mismatch"))
        state in ("applied", "release_refused") && recovery_reference_confirmed(values, now(runtime)) ||
            throw(ArgumentError("recovery command reference is not confirmed"))
    end
    return nothing
end

function check_recovery!(
    runtime, origin::AbstractOrigin, name, values, updates, declarations
)
    request = get(updates, RECOVERY_PREFIX * "request-token", nothing)
    release = get(updates, RECOVERY_PREFIX * "release-token", nothing)
    version = get(values, RECOVERY_PREFIX * "version", nothing)
    version !== nothing ||
        haskey(declarations, RECOVERY_PREFIX * "version") ||
        request !== nothing ||
        release !== nothing ||
        return nothing
    version === nothing && throw(ArgumentError("missing recovery-control version"))
    schema = policy_int(version)
    schema == 2 && return check_coupled_recovery!(runtime, origin, name, values, updates, request, release)
    schema == 1 || throw(ArgumentError("unsupported recovery-control version"))
    inhibited = correction_bool(values, RECOVERY_PREFIX * "closure-inhibited")
    if request === nothing && release === nothing
        !inhibited ||
            throw(ArgumentError("protective recovery inhibits scientific updates"))
        controller = correction_text(values, RECOVERY_PREFIX * "controller")
        close = get(updates, controller * ":closed", nothing)
        if close !== nothing &&
            policy_bool(close) &&
            correction_bool(values, RECOVERY_PREFIX * "close-guarded")
            length(updates) == 1 ||
                throw(ArgumentError("recovery close requires one unmixed control request"))
            correction_text(values, RECOVERY_PREFIX * "state") == "released" &&
            correction_long(values, RECOVERY_PREFIX * "requested-generation") ==
            correction_long(values, RECOVERY_PREFIX * "active-generation") &&
            recovery_reference_confirmed(values, now(runtime)) ||
                throw(ArgumentError("recovery command reference is not confirmed"))
        end
        return nothing
    end
    length(updates) == 1 && !(request !== nothing && release !== nothing) ||
        throw(ArgumentError("recovery requires one unmixed control request"))
    correction_running!(runtime, origin, name, values)
    correction_int(values, CORRECTION_PREFIX * "version") == 1 ||
        throw(ArgumentError("unsupported correction-control version"))
    controller = correction_text(values, RECOVERY_PREFIX * "controller")
    occursin(r"^[A-Za-z0-9_.-]+$", controller) ||
        throw(ArgumentError("invalid recovery controller"))
    target = controller * ":closed"
    key = CORRECTION_PREFIX * target
    current = correction_text(values, key * ".state")
    current in ("Open", "Closed") || throw(ArgumentError("correction state is not ready"))
    isempty(correction_text(values, key * ".fault")) ||
        throw(ArgumentError("correction fault is latched"))
    correction_long(values, RECOVERY_PREFIX * "requested-generation") ==
    correction_long(values, RECOVERY_PREFIX * "active-generation") ||
        throw(ArgumentError("recovery adoption is pending"))
    correction_long(values, controller * ":requested-generation") ==
    correction_long(values, controller * ":active-generation") ||
        throw(ArgumentError("correction property adoption is pending"))
    active = correction_bool(values, target)
    (current == "Closed") == active &&
    correction_bool(values, key * ".requested") == active ||
        throw(ArgumentError("inconsistent correction state"))
    if request !== nothing
        !inhibited || throw(ArgumentError("protective recovery is already inhibited"))
        token = policy_long(request)
        token > 0 && token > correction_long(values, RECOVERY_PREFIX * "request-token") ||
            throw(ArgumentError("recovery request token must advance"))
    else
        inhibited && !active ||
            throw(ArgumentError("recovery release requires an inhibited open controller"))
        generation = correction_long(values, RECOVERY_PREFIX * "recovery-generation")
        generation > 0 && policy_long(release) == generation ||
            throw(ArgumentError("recovery release generation mismatch"))
        correction_text(values, RECOVERY_PREFIX * "state") in
        ("applied", "release_refused") &&
        recovery_reference_confirmed(values, now(runtime)) ||
            throw(ArgumentError("recovery command reference is not confirmed"))
    end
    return nothing
end
function check_parameter_correction(values)
    if haskey(values, RECOVERY_PREFIX * "version")
        correction_int(values, RECOVERY_PREFIX * "version") in (1, 2) ||
            throw(ArgumentError("unsupported recovery-control version"))
        !correction_bool(values, RECOVERY_PREFIX * "closure-inhibited") ||
            throw(ArgumentError("protective recovery inhibits scientific updates"))
    end
    return nothing
end
function check_correction!(
    runtime, origin::AbstractOrigin, name, values, updates, declarations
)
    check_recovery!(runtime, origin, name, values, updates, declarations)
    version = get(values, CORRECTION_PREFIX * "version", nothing)
    if version !== nothing || haskey(declarations, CORRECTION_PREFIX * "version")
        version !== nothing && policy_int(version) == 1 ||
            throw(ArgumentError("unsupported or missing correction-control version"))
    end
    for (property, update) in updates
        key = CORRECTION_PREFIX * property
        if any(
            field -> haskey(values, key * field) || haskey(declarations, key * field),
            (".state", ".fault", ".requested", ".primed"),
        )
            version !== nothing ||
                throw(ArgumentError("correction-control version missing"))
            correction_running!(runtime, origin, name, values)
            current = correction_text(values, key * ".state")
            current in ("Open", "Closed") ||
                throw(ArgumentError("correction state is not ready"))
            isempty(correction_text(values, key * ".fault")) ||
                throw(ArgumentError("correction fault is latched"))
            desired = policy_bool(update)
            active = correction_bool(values, property)
            correction_bool(values, key * ".requested") == active &&
            (current == "Closed") == active ||
                throw(ArgumentError("inconsistent correction state"))
            primed = key * ".primed"
            if desired && !active && (haskey(declarations, primed) || haskey(values, primed))
                info = get(declarations, primed, nothing)
                info !== nothing && !info.writable && info.kind == PolicySPA.POD_BOOL &&
                    correction_text(values, "pipewireao.frame-observer.state") == "active" &&
                    correction_bool(values, primed) ||
                    throw(ArgumentError("correction closure requires a valid live open-loop measurement"))
            end
            matched = match(r"^([^:]+):.+$", property)
            matched !== nothing || throw(ArgumentError("invalid correction property"))
            algorithm = matched.captures[1]
            requested = correction_long(values, algorithm * ":requested-generation")
            requested >= 0 &&
            requested == correction_long(values, algorithm * ":active-generation") ||
                throw(ArgumentError("correction property adoption is pending"))
        end
    end
    return nothing
end

struct PropertyDeclaration
    kind::UInt32
    writable::Bool
end
function property_declarations(records)
    length(records) <= 4096 ||
        throw(ArgumentError("property declaration count exceeds bound"))
    declarations = Dict{String,PropertyDeclaration}()
    for pod in records
        object = PipeWireAO.pod_value(PolicySPA.Parameter, pod).object
        length(unique(item.key for item in object.properties)) ==
        length(object.properties) ||
            throw(ArgumentError("duplicate property declaration field"))
        declaration = PolicySPA.PropInfo(pod)
        haskey(declarations, declaration.name) &&
            throw(ArgumentError("duplicate property declaration"))
        kind = PipeWireAO.pod_type(declaration.type)
        if kind == PolicySPA.POD_CHOICE
            choice = PipeWireAO.pod_value(PolicySPA.Choice, declaration.type)
            kind = PipeWireAO.pod_type(PolicyPod(first(choice.values)))
        end
        declarations[declaration.name] = PropertyDeclaration(
            kind, (declaration.flags & UInt32(1)) == 0
        )
    end
    return declarations
end
function properties_adopted(after, baseline, updates)
    for (algorithm, generation) in baseline
        requested = correction_long(after, algorithm * ":requested-generation")
        requested > generation &&
        requested == correction_long(after, algorithm * ":active-generation") ||
            return false
    end
    for (name, expected) in updates
        observed = get(after, name, nothing)
        observed !== nothing && same_property_scalar(observed, expected) || return false
    end
    return true
end
function same_property_scalar(observed::PolicyPod, expected::PolicyPod)
    kind = PipeWireAO.pod_type(expected)
    kind == PipeWireAO.pod_type(observed) || return false
    kind == PolicySPA.POD_BOOL && return policy_bool(observed) == policy_bool(expected)
    kind == PolicySPA.POD_STRING && return policy_text(observed; limit = 16 * 1024) ==
           policy_text(expected; limit = 16 * 1024)
    # Numeric scalars retain their exact representation, including signed zero.
    return observed.data == expected.data
end
property_baseline(::ReadyOrigin, before, names) = Dict{String,Int64}()
property_baseline(::RunningOrigin, before, names) = Dict(
    algorithm => correction_long(before, algorithm * ":requested-generation") for
    algorithm in names
)

"""Submit one property transaction using the Hsm's recorded admission origin.

The supported origins are ReadyOrigin (synchronize submission, report no active
adoption) and RunningOrigin (observe exact values and advancing active generations).
The ticket-based entry extracts `job.ticket.origin`; effect adapters may pass
that origin explicitly. Native declarations and correction guards remain required.
"""
update_properties!(runtime, job, payload::Tuple) =
    update_properties!(runtime, job, job.ticket.origin, payload)
function update_properties!(runtime, job, origin::AbstractOrigin, payload::Tuple)
    name, properties = payload
    1 <= length(properties) <= RunnerCodec.MAX_PROPERTIES ||
        throw(ArgumentError("invalid property transaction size"))
    updates = Dict{String,PolicyPod}()
    algorithms = Set{String}()
    for (key, value) in properties
        matched = match(r"^([^:]+):(.+)$", key)
        matched !== nothing || throw(ArgumentError("invalid qualified property"))
        updates[key] = RunnerCodec._scalar_pod(value; finite = true)
        push!(algorithms, matched.captures[1])
    end
    names = sort!(collect(algorithms))
    handle = get(runtime.graphs, name, UInt64(0))
    handle != 0 || throw(ArgumentError("undeclared scientific graph"))
    declarations = property_declarations(enumerate!(runtime, job, handle, "PropInfo"))
    for (key, value) in updates
        declaration = get(declarations, key, nothing)
        declaration !== nothing &&
        declaration.writable &&
        declaration.kind == PipeWireAO.pod_type(value) ||
            throw(ArgumentError("undeclared, read-only or incompatible property: $key"))
    end
    before = named_properties!(runtime, job, handle)
    check_correction!(runtime, origin, name, before, updates, declarations)
    baseline = property_baseline(origin, before, names)
    setparam!(
        runtime,
        job,
        handle,
        "Props",
        PolicyPod(
            PipeWireAO.props_param(PolicySPA.Props(sort!(collect(updates); by = first)))
        ),
    )
    return finish_properties!(runtime, job, origin, handle, name, names, updates, baseline)
end
function finish_properties!(
    runtime, job, ::ReadyOrigin, handle, name, names, updates, baseline
)
    synchronize!(runtime, job)
    generations = PolicyPod[
        PolicyPod(
            policy_struct(PolicyPod(algorithm), PolicyPod(nothing), PolicyPod(nothing))
        ) for algorithm in names
    ]
    return policy_struct(
        PolicyPod(name), PolicyPod(PolicySPA.Struct(generations)), PolicyPod(false)
    )
end
function finish_properties!(
    runtime, job, ::RunningOrigin, handle, name, names, updates, baseline
)
    return await_condition!(runtime, job) do
        after = named_properties!(runtime, job, handle)
        properties_adopted(after, baseline, updates) || return nothing
        generations = PolicyPod[
            PolicyPod(
                policy_struct(
                    PolicyPod(algorithm),
                    PolicyPod(correction_long(after, algorithm * ":requested-generation")),
                    PolicyPod(correction_long(after, algorithm * ":active-generation")),
                ),
            ) for algorithm in names
        ]
        policy_struct(
            PolicyPod(name), PolicyPod(PolicySPA.Struct(generations)), PolicyPod(true)
        )
    end
end
update_properties!(runtime, job, command::RunnerCodec.RunnerCommand{:properties_set}) =
    update_properties!(runtime, job, job.ticket.origin, command.args)
submit_parameter!(runtime, job, payload::Tuple) =
    submit_parameter!(runtime, job, RunnerCodec.RunnerCommand(:parameter, payload...))

function submit_parameter!(runtime, job, command::Union{
    RunnerCodec.RunnerCommand{:parameter},ParameterSource.NdArrayParameter,
})
    name, inlet = ParameterSource.parameter_address(command)
    handle = get(runtime.graphs, name, UInt64(0))
    handle != 0 || throw(ArgumentError("undeclared scientific graph"))
    check_parameter_correction(named_properties!(runtime, job, handle))
    declaration = nothing
    # The session schema remains the authority for sparse parameter publishers.
    spec = runtime.configuration["session"]
    for publisher in spec["sources"]
        if get(publisher, "factory", nothing) == "pipewireao.runtime-parameter"
            for link in runtime.declared_links
                if link.output.node == publisher["node.name"] &&
                    link.output.port == "output_1" &&
                    link.input.node == name && link.input.port == inlet
                    declaration === nothing ||
                        throw(ArgumentError("ambiguous parameter source"))
                    declaration = publisher
                end
            end
        end
    end
    declaration !== nothing && runtime.parameters !== nothing ||
        throw(ArgumentError("parameter inlet has no captured publisher"))
    if command isa ParameterSource.NdArrayParameter
        port = only(declaration["ports"])
        parameter = command.parameter
        string(parameter.format.element_type) == port["element-type"] &&
            parameter.format.shape == Tuple(port["shape"]) &&
            string(parameter.format.layout) == get(port, "layout", "ROW_MAJOR") &&
            something(parameter.schema, "") == get(port, "schema", "") ||
            throw(ArgumentError("parameter ndarray differs from its declared format"))
    end
    reply = request_owner!(runtime, job, runtime.parameters, command)
    reply.graph == name && reply.inlet == inlet && !reply.active_adoption_observed ||
        throw(ArgumentError("parameter submission identity or result differs"))
    if reply.header.result < 0
        return ParameterRefusal(reply.message)
    end
    reply.sequence > 0 && reply.submitted ||
        throw(ArgumentError("parameter submission identity or result differs"))
    return policy_struct(
        PolicyPod(name), PolicyPod(inlet), PolicyPod(nothing), PolicyPod(false)
    )
end
