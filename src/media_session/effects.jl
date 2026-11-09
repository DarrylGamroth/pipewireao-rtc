import ..DeploymentConfiguration

const MAX_PARAMETER_PUBLISHERS = 1
const SOURCE_CONTROL_PROFILE = "pipewireao.source-control/1"
const PARAMETER_SOURCE_PROFILE = ControlClient.profile_name(ParameterSource.PROFILE)

"""
    perform!(runtime, job, effect::AbstractEffect)

Execute one effect on the session's serialized owner task, outside Hsm dispatch.
The host supplies a guarded job, asynchronous native I/O, exact object bindings,
and the captured owner/source collections. Those adapters enforce each native
deadline and mark scientific submissions before sending them. This layer orders
their terminal acknowledgements; it never retries an operation or drives Hsm.

Query and group results are native `SPA.Struct` details for the existing runner
wire profile. Lifecycle effects return `nothing`; `QuerySourceEnd` returns the
machine's typed evidence. Property/parameter payloads are the decoded runner
command's argument tuple. Host-specific `RemoveControls`, `PublishQuit` and
`Disconnect` methods belong to the application host, including the emergency
Disconnect budget exception and the final Quit publication fence.
"""
function perform! end

function _declared_instance(declaration, key)
    instance = tryparse(Int64, string(declaration[key]))
    instance !== nothing && instance > 0 ||
        throw(ArgumentError("invalid declared control incarnation: $key"))
    return instance
end

function _assert_controller!(runtime, object::Object{P,NodeInfo}) where {P}
    controller = runtime.controller
    object.id == controller.global_id && object.serial == controller.serial ||
        throw(ArgumentError("session controller registry incarnation differs"))
    info = object.info
    mask =
        PipeWireAO.NODE_CHANGE_INPUT_PORTS | PipeWireAO.NODE_CHANGE_OUTPUT_PORTS |
        PipeWireAO.NODE_CHANGE_PROPERTIES
    info !== nothing &&
    info.change_mask & mask == mask &&
    info.n_input_ports == 0 &&
    info.n_output_ports == 0 ||
        throw(ArgumentError("session controller needs complete zero-port NodeInfo"))
    handle = UInt64(object.id)
    property(runtime, handle, "pipewireao.rtc-control.protocol") ==
    ControlClient.PROTOCOL &&
    property(runtime, handle, "pipewireao.rtc-control.profile") ==
    ControlClient.CONTROLLER_PROFILE &&
    identity_integer(runtime, handle, "pipewireao.rtc-control.instance") ==
    controller.instance &&
    controller.instance ==
    _declared_instance(runtime.configuration, "controller.instance") &&
    identity_integer(runtime, handle, "pipewireao.rtc-control.owner-pid") == getpid() ||
        throw(ArgumentError("session controller metadata differs"))
    return nothing
end

function perform!(runtime, job, ::CaptureOwners)
    isempty(runtime.owners) || throw(ArgumentError("bootstrap owners are already captured"))
    await_condition!(runtime, job) do
        runtime.core_info !== nothing &&
        runtime.client_id > 0 &&
        runtime.client_id != typemax(UInt32) &&
        runtime.controller !== nothing ? true : nothing
    end
    core = _core_identity(runtime)
    core.pid == runtime.configuration["core.owner"]["pid"] ||
        throw(ArgumentError("declared core process differs from remote core"))
    controller = node!(
        runtime, job, runtime.configuration["controller.node.name"], getpid()
    )
    object = something(find_object(runtime, controller))
    _assert_controller!(runtime, object)
    capture!(runtime, controller; core)
    declarations = runtime.configuration["owners"]
    length(declarations) <= DeploymentConfiguration.MAX_EXTERNAL_OWNERS ||
        throw(ArgumentError("too many declared external owners"))
    names, handles = Set{String}(), Set{UInt64}()
    for declaration in declarations
        haskey(declaration, "bootstrap-node") || continue
        name = String(declaration["bootstrap-node"])
        name in names && throw(ArgumentError("duplicate bootstrap control node"))
        push!(names, name)
        handle = node!(runtime, job, name, declaration["pid"])
        handle in handles && throw(ArgumentError("duplicate bootstrap owner incarnation"))
        push!(handles, handle)
        capture!(runtime, handle; core)
        owner = capture_owner(
            runtime,
            handle,
            OwnerBootstrapCodec.PROFILE,
            _declared_instance(declaration, "bootstrap-instance"),
            declaration["pid"],
        )
        push!(runtime.owners, owner)
    end
    return nothing
end

function perform!(runtime, job, ::ConnectOwners)
    for owner in runtime.owners
        connect_owner!(runtime, job, owner)
    end
    return nothing
end

function perform!(runtime, job, ::CaptureParameters)
    runtime.parameters === nothing ||
        throw(ArgumentError("parameter publisher is already captured"))
    declarations = filter(
        declaration ->
            get(declaration, "control-protocol", nothing) == PARAMETER_SOURCE_PROFILE,
        runtime.configuration["owners"],
    )
    length(declarations) <= MAX_PARAMETER_PUBLISHERS ||
        throw(ArgumentError("multiple parameter publishers are unsupported"))
    isempty(declarations) && return nothing
    declaration = only(declarations)
    handle = node!(runtime, job, declaration["control-node"], declaration["pid"])
    runtime.parameters = capture_owner(
        runtime,
        handle,
        ParameterSource.PROFILE,
        _declared_instance(declaration, "control-instance"),
        declaration["pid"],
    )
    return nothing
end

function perform!(runtime, job, ::CaptureSources)
    isempty(runtime.sources) ||
        throw(ArgumentError("acquisition sources are already captured"))
    primary = runtime.configuration["source"]
    auxiliary = get(runtime.configuration, "auxiliary-sources", [])
    length(auxiliary) < DeploymentConfiguration.MAX_EXTERNAL_OWNERS ||
        throw(ArgumentError("too many auxiliary acquisition sources"))
    declarations = (primary, auxiliary...)
    names, roles = Set{String}(), Set{String}()
    for declaration in declarations
        name, role = String(declaration["control-node"]), String(declaration["role"])
        if name in names || role in roles
            throw(ArgumentError("duplicate acquisition source role or control node"))
        end
        push!(names, name)
        push!(roles, role)
    end
    all(
        declaration -> declaration["control-protocol"] == SOURCE_CONTROL_PROFILE, auxiliary
    ) || throw(ArgumentError("auxiliary acquisition requires native SourceControl"))
    handles = Set{UInt64}()
    for declaration in declarations
        handle = node!(runtime, job, declaration["control-node"], declaration["pid"])
        handle in handles && throw(ArgumentError("duplicate acquisition owner incarnation"))
        push!(handles, handle)
        push!(runtime.sources, source(runtime, handle, declaration))
    end
    return nothing
end

function perform!(runtime, job, ::PrepareSources)
    for binding in runtime.sources
        prepare_source!(runtime, job, binding)
    end
    return nothing
end

perform!(runtime, job, ::DiscoverGraphs) = discover_graphs!(runtime, job)
perform!(runtime, job, ::ConnectLinks) = create_links!(runtime, job)
perform!(runtime, job, ::WithdrawLinks) = remove_links!(runtime, job)

# Source adapters expose terminal retirement and the last acknowledged cursor
# generation through dispatch. Retirement is established only by the adapter's
# validated Shutdown receipt; a cached cursor never predicts a future reset.
_source_retired(binding::AcquisitionBinding) = binding.owner.retired
_source_retired(::SourceControlBinding) = false
_source_generation(binding::AcquisitionBinding) =
    binding.previous === nothing ? nothing : binding.previous.generation
_source_generation(binding::SourceControlBinding) =
    binding.previous === nothing ? nothing : binding.previous.generation

function _validate_hold(origin::AbstractOrigin, snapshot::SourceSnapshot)
    snapshot.running && throw(ArgumentError("acquisition remained running after Hold"))
    return nothing
end
_validate_hold(::AbstractOrigin, ::InitialSourceHold) = nothing
function _validate_hold(::ConfiguringOrigin, snapshot::SourceSnapshot)
    !snapshot.running &&
    !snapshot.completed &&
    snapshot.sequence == 0 &&
    snapshot.generation != 0 ||
        throw(ArgumentError("initial acquisition was not held before its first exposure"))
    return nothing
end

function perform!(runtime, job, ::HoldSources)
    for binding in runtime.sources
        # Retired acquisition bindings carry the validated terminal Shutdown
        # proof. They must not receive another scientific command.
        _source_retired(binding) && continue
        snapshot = source_operation!(runtime, job, binding, :run; running = false)
        _validate_hold(job.ticket.origin, snapshot)
    end
    return nothing
end

function perform!(runtime, job, ::RunSources)
    for binding in Iterators.reverse(runtime.sources)
        _source_retired(binding) &&
            throw(ArgumentError("cannot run a retired acquisition owner"))
        snapshot = source_operation!(runtime, job, binding, :run; running = true)
        snapshot.running && !snapshot.completed ||
            throw(ArgumentError("acquisition release was not observed"))
    end
    return nothing
end

function perform!(runtime, job, ::QuerySourceEnd)
    isempty(runtime.sources) &&
        throw(ArgumentError("primary acquisition source is not captured"))
    binding = first(runtime.sources)
    _source_retired(binding) &&
        throw(ArgumentError("cannot query a retired acquisition owner"))
    snapshot = source_operation!(runtime, job, binding, :query)
    return SourceEnd(snapshot.completed, snapshot.running)
end

function perform!(runtime, job, ::ResetSources)
    for binding in runtime.sources
        _source_retired(binding) &&
            throw(ArgumentError("cannot reset a retired acquisition owner"))
        before = _source_generation(binding)
        before !== nothing && before != 0 ||
            throw(ArgumentError("acquisition reset has no acknowledged baseline"))
        after = source_operation!(runtime, job, binding, :reset)
        !after.running &&
        !after.completed &&
        after.sequence == 0 &&
        after.generation != 0 &&
        after.generation != before ||
            throw(ArgumentError("acquisition reset did not adopt a new held generation"))
    end
    return nothing
end

function perform!(runtime, job, ::ShutdownSources)
    for binding in runtime.sources
        _source_retired(binding) || shutdown_source!(runtime, job, binding)
    end
    return nothing
end

function _bootstrap_order(runtime, index::Int, owner::Owner{OwnerBootstrapCodec.Profile})
    # CaptureOwners appends the declared bootstraps in declaration order. A
    # partial capture is a prefix; terminal owners can lose their control node
    # before a later Quit, so ordering must retain this admission evidence.
    declarations = filter(
        declaration -> haskey(declaration, "bootstrap-node"),
        runtime.configuration["owners"],
    )
    index <= length(declarations) ||
        throw(ArgumentError("captured bootstrap has no owner declaration"))
    declaration = declarations[index]
    declaration["pid"] == owner.pid &&
    _declared_instance(declaration, "bootstrap-instance") == owner.instance ||
        throw(ArgumentError("captured bootstrap declaration differs"))
    owner.retired ||
        property(runtime, owner.handle, "node.name") == declaration["bootstrap-node"] ||
        throw(ArgumentError("captured bootstrap control node differs"))
    return (declaration["role"] != runtime.configuration["source"]["role"], index)
end
function perform!(runtime, job, ::ShutdownOwners)
    order = sort!(
        collect(eachindex(runtime.owners));
        by = index -> _bootstrap_order(runtime, index, runtime.owners[index]),
    )
    for index in order
        _shutdown_bootstrap!(runtime, job, runtime.owners[index])
    end
    return nothing
end
function _shutdown_bootstrap!(runtime, job, owner::Owner{OwnerBootstrapCodec.Profile})
    owner.retired && return nothing
    retire_owner!(runtime, owner) do
        shutdown_owner!(runtime, job, owner)
    end
    return nothing
end

_graph_names(runtime, ::Nothing) = sort!(collect(keys(runtime.graphs)))
function _graph_names(runtime, group::AbstractString)
    declaration = get(runtime.groups, group, nothing)
    declaration === nothing && throw(ArgumentError("undeclared execution group"))
    return sort!(copy(declaration.nodes))
end

"""Order controlled graphs by declared dependencies, with alphabetical ties.

Consumers run before producers. Producers hold before consumers. Only members
of the selected execution group participate in a selective control operation.
"""
function graph_order(runtime, running::Bool, group = nothing)
    names = _graph_names(runtime, group)
    members = Set(names)
    successors = Dict(name => Set{String}() for name in names)
    for link in runtime.configuration["session"]["links"]
        output, input = first(_endpoint_address(link["output"])),
        first(_endpoint_address(link["input"]))
        output in members && input in members && push!(successors[output], input)
    end
    depths, visiting = Dict{String,Int}(), Set{String}()
    function depth(name)
        haskey(depths, name) && return depths[name]
        name in visiting && throw(ArgumentError("processing graph has a scheduling cycle"))
        push!(visiting, name)
        result = 0
        for successor in successors[name]
            result = max(result, depth(successor) + 1)
        end
        delete!(visiting, name)
        return depths[name] = result
    end
    return sort!(names; by = name -> (running ? depth(name) : -depth(name), name))
end

function _graph_states!(runtime, ::Nothing, running::Bool)
    for group in values(runtime.groups)
        group.running = running
    end
    return nothing
end
_graph_states!(runtime, group::AbstractString, running::Bool) =
    (runtime.groups[group].running = running; nothing)

function _run_graphs!(runtime, job, running::Bool, group)
    for name in graph_order(runtime, running, group)
        node_operation!(runtime, job, runtime.graphs[name], :run, running)
    end
    _graph_states!(runtime, group, running)
    return nothing
end
function perform!(runtime, job, effect::RunGraphs{Nothing})
    _run_graphs!(runtime, job, effect.running, nothing)
    return nothing
end
function perform!(runtime, job, effect::RunGraphs{<:AbstractString})
    _run_graphs!(runtime, job, effect.running, effect.group)
    state = effect.running ? RunnerCodec.GroupRunning : RunnerCodec.Stopped
    return policy_struct(
        PolicyPod(String(effect.group)),
        PolicyPod(PolicySPA.Id(UInt32(state))),
        PolicyPod(PolicySPA.Id(UInt32(state))),
    )
end
function _hold_graphs!(runtime, job, ::AbstractOrigin)
    return _run_graphs!(runtime, job, false, nothing)
end
function _hold_graphs!(runtime, job, ::FaultOrigin)
    failure = nothing
    for name in graph_order(runtime, false)
        try
            node_operation!(runtime, job, runtime.graphs[name], :run, false)
        catch error
            failure === nothing && (failure = error)
        end
    end
    failure === nothing || throw(failure)
    _graph_states!(runtime, nothing, false)
    return nothing
end
perform!(runtime, job, ::HoldGraphs) = _hold_graphs!(runtime, job, job.ticket.origin)
function perform!(runtime, job, ::ResetGraphs)
    for name in sort!(collect(keys(runtime.graphs)))
        node_operation!(runtime, job, runtime.graphs[name], :reset)
    end
    return nothing
end

function groups_details(runtime)::PolicySPA.Struct
    rows = PolicyPod[
        PolicyPod(
            policy_struct(
                PolicyPod(name),
                PolicyPod(
                    PolicySPA.Id(
                        UInt32(
                            runtime.groups[name].running ? RunnerCodec.GroupRunning :
                            RunnerCodec.Stopped,
                        ),
                    ),
                ),
            ),
        ) for name in sort!(collect(keys(runtime.groups)))
    ]
    return policy_struct(PolicyPod(PolicySPA.Struct(rows)))
end
perform!(runtime, job, ::QueryGroups) = groups_details(runtime)

"""Authority-local status in the existing wire shape.

The authority owns no scientific nodes and processes/discards no frame buffers.
The link count describes its retained native Link proxies. Empty per-sink data
does not assert that independent scientific owners discarded no buffers.
"""
function status_details(runtime; running::Bool)::PolicySPA.Struct
    return policy_struct(
        PolicyPod(running),
        PolicyPod(Int64(0)),
        PolicyPod(Int64(length(runtime.links))),
        PolicyPod(Int64(0)),
        PolicyPod(PolicySPA.Struct(PolicyPod[])),
    )
end
function perform!(runtime, job, ::QueryStatus)
    isempty(runtime.sources) &&
        throw(ArgumentError("primary acquisition source is not captured"))
    primary_running = false
    for (index, binding) in enumerate(runtime.sources)
        _source_retired(binding) &&
            throw(ArgumentError("cannot observe a retired acquisition owner"))
        snapshot = source_operation!(runtime, job, binding, :query)
        snapshot.generation != 0 && !(snapshot.running && snapshot.completed) ||
            throw(ArgumentError("source status has no coherent acquisition proof"))
        index == 1 && (primary_running = snapshot.running)
    end
    return status_details(
        runtime; running = _status_running(job.ticket.origin) && primary_running
    )
end
_status_running(::RunningOrigin) = true
_status_running(::AbstractOrigin) = false

function _graph_handle(runtime, name::AbstractString)
    handle = get(runtime.graphs, name, nothing)
    handle === nothing && throw(ArgumentError("undeclared scientific graph"))
    return handle
end
function perform!(runtime, job, effect::QueryProperties{<:Tuple})
    length(effect.payload) == 1 ||
        throw(ArgumentError("property query requires one declared graph"))
    name, = effect.payload
    values = named_properties!(runtime, job, _graph_handle(runtime, name))
    rows = PolicyPod[]
    for key in sort!(collect(keys(values)))
        value = values[key]
        kind = PipeWireAO.pod_type(value)
        if kind in (
            PolicySPA.POD_BOOL,
            PolicySPA.POD_INT,
            PolicySPA.POD_LONG,
            PolicySPA.POD_FLOAT,
            PolicySPA.POD_DOUBLE,
            PolicySPA.POD_ID,
            PolicySPA.POD_STRING,
        )
            RunnerCodec._scalar_value(value; finite = false)
            push!(rows, PolicyPod(policy_struct(PolicyPod(key), value)))
        end
    end
    return policy_struct(PolicyPod(name), PolicyPod(PolicySPA.Struct(rows)))
end
function _generation_details(
    runtime, job, payload::Tuple, suffix::String; optional_active::Bool
)
    length(payload) == 2 ||
        throw(ArgumentError("generation query requires a graph and algorithm"))
    name, algorithm = payload
    values = named_properties!(runtime, job, _graph_handle(runtime, name))
    requested = values[algorithm*":requested-"*suffix]
    active = values[algorithm*":active-"*suffix]
    policy_long(requested)
    if !optional_active || PipeWireAO.pod_type(active) != PolicySPA.POD_NONE
        policy_long(active)
    end
    return policy_struct(PolicyPod(name), PolicyPod(algorithm), requested, active)
end
perform!(runtime, job, effect::QueryPropertyGeneration{<:Tuple}) =
    _generation_details(runtime, job, effect.payload, "generation"; optional_active = true)
perform!(runtime, job, effect::QueryParameterGeneration{<:Tuple}) = _generation_details(
    runtime, job, effect.payload, "parameter-sequence"; optional_active = false
)
perform!(runtime, job, effect::UpdateProperties{<:Tuple}) =
    update_properties!(runtime, job, job.ticket.origin, effect.payload)
perform!(runtime, job, effect::SubmitParameter{<:Tuple}) =
    submit_parameter!(runtime, job, effect.payload)
