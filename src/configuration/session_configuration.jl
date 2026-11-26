"""Generate the headless RTC configuration for one RTC invocation.

The caller supplies exact node-to-owner roles from the sealed export. This
module validates those roles against retained systemd owner records and writes
configuration only; the Julia session policy owns admission and lifecycle.
"""
module SessionConfiguration

import ..PipeWireAORTC

export session_configuration, write_session_config

const Export = PipeWireAORTC.ScienceExport
const D = PipeWireAORTC.DeploymentConfiguration

struct ConfigurationError <: Exception
    message::String
end
Base.showerror(io::IO, error::ConfigurationError) = print(io, error.message)
fail(message) = throw(ConfigurationError(message))

session_entries(value, key) = fail("session $key must be a list")
session_entries(value::AbstractVector, key) = value
session_node_name(value, key) = fail("session $key entry needs node.name")
function session_node_name(value::String, key)
    isempty(value) && fail("session $key entry needs node.name")
    return value
end
graph_factory!(factories, name, value) = fail("graph $name has an invalid factory")
graph_factory!(factories, name, value::String) = (factories[name] = value)
declare_node!(names, factories, entry, key) = fail("session $key entry must be a mapping")
function declare_node!(names, factories, entry::AbstractDict, key)
    name = session_node_name(get(entry, "node.name", nothing), key)
    name in names && fail("session declares node $name more than once")
    push!(names, name)
    key == "graphs" && graph_factory!(factories, name, get(entry, "factory", ""))
    return nothing
end

function declared_nodes(session)
    names = String[]
    factories = Dict{String,String}()
    for key in ("sources", "graphs", "sinks")
        entries = session_entries(get(session, key, Any[]), key)
        for entry in entries
            declare_node!(names, factories, entry, key)
        end
    end
    return names, factories
end

function verified_pid(records, role)
    item = get(records, role, nothing)
    return verified_pid_record(item, role)
end
verified_pid_record(item, role) = fail("node owner $role has no retained running record")
function verified_pid_record(item::AbstractDict, role)
    get(item, "role", nothing) == role && get(item, "state", nothing) == "running" ||
        fail("node owner $role has no retained running record")
    pid = get(item, "pid", nothing)
    return process_record_pid(pid, item, role)
end
process_record_pid(pid, item, role) =
    fail("node owner $role lacks verified PID and process identity")
process_record_pid(pid::Bool, item, role) =
    fail("node owner $role lacks verified PID and process identity")
function process_record_pid(pid::Integer, item, role)
    pid > 0 && pid <= typemax(UInt32) ||
        fail("node owner $role lacks verified PID and process identity")
    return process_record_ticks(get(item, "start-ticks", 0), pid, item, role)
end
process_record_ticks(ticks, pid, item, role) =
    fail("node owner $role lacks verified PID and process identity")
function process_record_ticks(ticks::Integer, pid, item, role)
    ticks > 0 &&
    !isempty(get(item, "invocation", "")) &&
    startswith(get(item, "cgroup", ""), "/") ||
        fail("node owner $role lacks verified PID and process identity")
    return Int(pid)
end

hosted_graph_name(value) = fail("FGN record lacks exact hosted graph names")
hosted_graph_name(value::String) = value
hosted_graph_names(value) = fail("FGN record lacks exact hosted graph names")
function hosted_graph_names(value::AbstractVector)
    foreach(hosted_graph_name, value)
    return value
end

function node_ownership(session, node_owners, fgn)
    names, factories = declared_nodes(session)
    mapping = Dict{String,String}(node_owners)
    if fgn !== nothing
        graph_nodes = hosted_graph_names(get(fgn, "graph-nodes", nothing))
        for name in graph_nodes
            get(factories, name, nothing) == "pipewireao.fgn-native" ||
                fail("FGN host claims an undeclared or different graph")
            if haskey(mapping, name)
                mapping[name] == "fgn" || fail("FGN graph has a conflicting owner mapping")
            else
                mapping[name] = "fgn"
            end
        end
    end
    for (name, factory) in factories
        factory == "pipewireao.fgn-native" || continue
        get(mapping, name, nothing) == "fgn" &&
        fgn !== nothing &&
        name in fgn["graph-nodes"] || fail("FGN graph is not hosted by the FGN owner")
    end
    Set(keys(mapping)) == Set(names) ||
        fail("every declared source, graph and sink needs one exact owner mapping")
    return mapping
end

function positive_instance(bindings, key)
    return positive_instance_value(get(bindings, key, nothing), key)
end
positive_instance_value(value, key) = fail("missing $key binding")
function positive_instance_value(value::AbstractString, key)
    parsed = tryparse(Int64, value)
    parsed !== nothing && parsed > 0 || fail("invalid $key binding")
    return parsed
end

function owner_specs(spec)
    return owner_declarations(get(spec, "owners", Any[]))
end
owner_declarations(entries) =
    fail("deployment owners must be a list of at most eight external owners")
function owner_declarations(entries::AbstractVector)
    length(entries) <= D.MAX_EXTERNAL_OWNERS ||
        fail("deployment owners must be a list of at most eight external owners")
    by_role = Dict{String,Any}()
    for entry in entries
        register_owner!(by_role, entry)
    end
    return by_role
end
owner_role(role) = fail("deployment owner has no role")
owner_role(role::String) = isempty(role) ? fail("deployment owner has no role") : role
register_owner!(by_role, entry) = fail("deployment owner must be a mapping")
function register_owner!(by_role, entry::AbstractDict)
    role = owner_role(get(entry, "role", nothing))
    haskey(by_role, role) && fail("deployment has duplicate owner role $role")
    by_role[role] = entry
    return nothing
end

session_name(value) = fail("deployment has no validated name")
function session_name(value::String)
    occursin(r"^[a-z0-9][a-z0-9-]{0,39}$", value) ||
        fail("deployment has no validated name")
    return value
end
declared_source_role(value) = fail("session has no declared source owner")
declared_source_role(value::String) = value
private_remote_bindings(runtime, remote) = fail("invalid private PipeWire remote binding")
function private_remote_bindings(runtime::String, remote::String)
    isabspath(runtime) && occursin(r"^[a-zA-Z0-9_.-]+$", remote) ||
        fail("invalid private PipeWire remote binding")
    return runtime, remote
end
session_uuid(value) = fail("invalid session UUID binding")
function session_uuid(value::String)
    occursin(r"^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$", value) ||
        fail("invalid session UUID binding")
    return value
end
const AUXILIARY_ROLES_ERROR = "auxiliary source roles must uniquely name declared external owners distinct from the primary"
auxiliary_source_role(role, declarations, source) = fail(AUXILIARY_ROLES_ERROR)
function auxiliary_source_role(role::String, declarations, source)
    haskey(declarations, role) && role != source || fail(AUXILIARY_ROLES_ERROR)
    return role
end
auxiliary_source_roles(roles, declarations, source) = fail(AUXILIARY_ROLES_ERROR)
function auxiliary_source_roles(roles::AbstractVector, declarations, source)
    length(roles) <= D.MAX_EXTERNAL_OWNERS - 1 || fail(AUXILIARY_ROLES_ERROR)
    foreach(role -> auxiliary_source_role(role, declarations, source), roles)
    length(unique(roles)) == length(roles) || fail(AUXILIARY_ROLES_ERROR)
    return roles
end
function owner_record(role, declaration, records, bindings)
    record = Dict{String,Any}("role" => role, "pid" => verified_pid(records, role))
    for field in
        ("control-protocol", "control-node", "bootstrap-protocol", "bootstrap-node")
        haskey(declaration, field) && (record[field] = declaration[field])
    end
    if haskey(declaration, "bootstrap-node")
        key = "BOOTSTRAP_INSTANCE_" * replace(uppercase(role), "-" => "_")
        record["bootstrap-instance"] = string(positive_instance(bindings, key))
    end
    instance = get(records[role], "control-instance", nothing)
    if instance !== nothing
        parsed = tryparse(Int64, string(instance))
        parsed !== nothing && parsed > 0 || fail("invalid owner control incarnation")
        record["control-instance"] = string(parsed)
    end
    get(records[role], "persistent", false) === true && (record["persistent"] = true)
    return record
end

"""
    session_configuration(spec, session, bindings, records; node_owners, links)

Validate exact node owners and retained process identities, then return the
RTC configuration for this invocation. Pass `links` from the same session
document to reuse its parsed Link declarations. This does not start a session.
"""
function session_configuration(
    spec, session, bindings, records;
    node_owners::Dict{String,String}, links = D.session_links(session)
)
    topology = session_topology(spec, session, bindings, node_owners, owner_specs(spec);
        links, fgn = get(records, "fgn", nothing))
    return bind_session_configuration(topology, deepcopy(session), bindings, records)
end

function session_topology(spec, session, bindings, node_owners, declarations;
    links = D.session_links(session), fgn = nothing,
)
    D.validate_session_links(session, links)
    isempty(links) && fail("native session requires at least one declared connection")
    D.validate_execution_groups(session, links)
    name = session_name(get(spec, "name", nothing))
    source_role = declared_source_role(get(spec, "source-owner", nothing))
    haskey(declarations, source_role) || fail("source owner has no declaration")
    source = declarations[source_role]
    haskey(source, "control-protocol") || fail("source owner is missing control-protocol")
    external = D.uses_external_stream(source)
    external || haskey(source, "control-node") || fail("source owner is missing control-node")
    auxiliary_roles = auxiliary_source_roles(
        get(spec, "auxiliary-source-owners", String[]), declarations, source_role
    )
    external && !isempty(auxiliary_roles) && fail("independent input cannot control auxiliary sources")
    source_nodes = String[]
    for role in auxiliary_roles
        declaration = declarations[role]
        D.uses_source_control_protocol(declaration) &&
        D.uses_bootstrap_protocol(declaration) ||
            fail("auxiliary source requires native SourceControl and owner bootstrap")
        push!(source_nodes, declaration["control-node"])
    end
    external || push!(source_nodes, source["control-node"])
    length(unique(source_nodes)) == length(source_nodes) ||
        fail("primary and auxiliary sources require distinct control node names")
    return Dict{String,Any}(
        "node-owners" => node_ownership(session, node_owners, fgn),
        "core-nodes" => sort!([node for (node, role) in node_owners if role == "core"]),
        "owners" => declarations,
        "source-role" => source_role,
        "auxiliary-roles" => auxiliary_roles,
        "node.name" => "pipewireao.rtc.session." * name,
        "controller.node.name" => "pipewireao.rtc.controller." * name,
        "startup.timeout-ms" => D.startup_timeout_ms(spec),
        "properties" => PipeWireAORTC.InstrumentDefinition.publication(spec, bindings),
    )
end

function bind_session_configuration(topology, session, bindings, records)
    source_role = topology["source-role"]
    verified_pid(records, source_role)
    core_pid = verified_pid(records, "core")
    remote = if get(records["core"], "external", false)
        PipeWireAORTC.ControlClient.private_remote(bindings["REMOTE"])
    else
        parent, socket_name = private_remote_bindings(
            get(bindings, "RUNTIME", nothing), get(bindings, "REMOTE", nothing)
        )
        joinpath(parent, socket_name)
    end
    uuid = session_uuid(get(bindings, "SESSION_UUID", nothing))
    public_instance = positive_instance(bindings, "SESSION_CONTROL_INSTANCE")
    controller_instance = positive_instance(bindings, "SESSION_CONTROLLER_INSTANCE")
    admission_instance = positive_instance(bindings, "ADMISSION_CONTROLLER_INSTANCE")
    public_instance != controller_instance || fail("session endpoint instances must differ")
    admission_instance != public_instance && admission_instance != controller_instance ||
        fail("admission controller instance must be distinct from session endpoints")
    pids = Dict{String,Int}(name => verified_pid(records, role)
        for (name, role) in topology["node-owners"])
    core_owner = Dict("pid" => core_pid, "nodes" => topology["core-nodes"])
    declarations = topology["owners"]
    all(role -> haskey(declarations, role) || role in ("core", "fgn"), keys(records)) ||
        fail("an owner process record has no matching owner declaration")
    owners = Any[
        owner_record(role, declarations[role], records, bindings) for
        role in sort!(collect(keys(records))) if haskey(declarations, role)
    ]
    source = owner_record(source_role, declarations[source_role], records, bindings)
    auxiliary = [owner_record(role, declarations[role], records, bindings)
        for role in topology["auxiliary-roles"]]
    policy = Dict{String,Any}(
        "session" => session,
        "owners" => owners,
        "source" => source,
        "auxiliary-sources" => auxiliary,
        "node.pids" => pids,
        "core.owner" => core_owner,
        "instance" => string(public_instance),
        "controller.instance" => string(controller_instance),
        "session.uuid" => uuid,
        "node.name" => topology["node.name"],
        "controller.node.name" => topology["controller.node.name"],
        "admission.controller-instance" => string(admission_instance),
        "startup.timeout-ms" => topology["startup.timeout-ms"],
        "properties" => merge(
            Dict("pipewireao.rtc.session.session-uuid" => uuid),
            topology["properties"],
        ),
    )
    return runtime_configuration(remote, policy)
end

function runtime_configuration(remote, policy)
    return Dict{String,Any}(
        "context.properties" => Dict{String,Any}(
            "library.use-fallback" => false,
            "support.dbus" => false,
            "remote.name" => remote,
        ),
        "context.modules" => Any[
            Dict("name" => "libpipewire-module-protocol-native"),
            Dict("name" => "libpipewire-module-client-node"),
        ],
        "pipewireao.session" => policy,
    )
end

struct LinkPlan
    declarations::Vector{D.LinkDeclaration}
    order::Vector{Int}
    prerequisites::Vector{Vector{Int}}
end

function seal_links(links)
    rows = [(link.output, link.input, link.passive) for link in links]
    order = link_order(rows)
    return Dict("order" => order, "prerequisites" => link_prerequisites(rows, order))
end

function installed_links(plan, session)
    # The installer validated this data before recording the activation digest.
    return LinkPlan(
        D.LinkDeclaration[D.link_declaration(row) for row in session["links"]],
        Vector{Int}(plan["order"]),
        [Vector{Int}(before) for before in plan["prerequisites"]],
    )
end

"""
    write_session_config(spec, session, bindings, records, runtime; node_owners)

Write validated native configuration below `runtime` and return its path.
The runtime must match the invocation's `RUNTIME` binding.
"""
function write_session_config(
    spec, session, bindings, records, runtime;
    node_owners::Dict{String,String}, links = D.session_links(session)
)
    get(bindings, "RUNTIME", nothing) == runtime ||
        fail("configuration runtime differs from launch binding")
    config = session_configuration(spec, session, bindings, records; node_owners, links)
    directory = joinpath(runtime, "rtc")
    mkpath(directory)
    path = joinpath(directory, "rtc.conf")
    Export.write_spa_config(path, config)
    return path
end

function link_order(rows)
    isempty(rows) && return Int[]
    node_type = typeof(first(rows)[1].node)
    successors = Dict{node_type,Set{node_type}}()
    for (output, input, passive) in rows
        push!(get!(successors, output.node, Set{node_type}()), input.node)
    end
    depths, visiting = Dict{node_type,Int}(), Set{node_type}()
    function rank(node)
        haskey(depths, node) && return depths[node]
        node in visiting && throw(ArgumentError("session links contain a scheduling cycle"))
        push!(visiting, node)
        depth = 0
        for successor in get(successors, node, Set{node_type}())
            depth = max(depth, rank(successor) + 1)
        end
        delete!(visiting, node)
        return depths[node] = depth
    end
    for (output, input, passive) in rows
        rank(output.node)
    end
    return sortperm(eachindex(rows); by = index -> (rank(rows[index][2].node), index))
end
# Each incoming edge waits for the downstream node's outgoing edges. Fan-out
# on the same port also keeps the original negotiation order and format.
function link_prerequisites(rows, order)
    before = [Int[] for _ in rows]
    for (position, index) in enumerate(order)
        output, input, _ = rows[index]
        for previous in @view order[1:(position - 1)]
            earlier_output, earlier_input, _ = rows[previous]
            if input.node == earlier_output.node ||
               (output.node == earlier_output.node && output.port == earlier_output.port) ||
               (input.node == earlier_input.node && input.port == earlier_input.port)
                push!(before[index], previous)
            end
        end
    end
    return before
end

end # module
