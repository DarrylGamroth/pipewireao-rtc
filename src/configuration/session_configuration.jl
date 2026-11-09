"""Generate the headless RTC configuration for one RTC invocation.

The caller supplies exact node-to-owner roles from the sealed export. This
module validates those roles against retained systemd owner records and writes
configuration only; the Julia session policy owns admission and lifecycle.
"""
module SessionConfiguration

import ..PipeWireAORTC

const Export = PipeWireAORTC.ScienceExport
const D = PipeWireAORTC.DeploymentConfiguration

export session_configuration, write_session_config

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

function node_pids(session, records, node_owners)
    names, factories = declared_nodes(session)
    mapping = Dict{String,String}(node_owners)
    fgn = get(records, "fgn", nothing)
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
    return Dict{String,Int}(name => verified_pid(records, mapping[name]) for name in names)
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
    D.validate_session_links(session, links)
    isempty(links) && fail("native session requires at least one declared connection")
    D.validate_execution_groups(session, links)
    name = session_name(get(spec, "name", nothing))
    source_role = declared_source_role(get(spec, "source-owner", nothing))
    verified_pid(records, source_role)
    runtime, remote_name = private_remote_bindings(
        get(bindings, "RUNTIME", nothing), get(bindings, "REMOTE", nothing)
    )
    uuid = session_uuid(get(bindings, "SESSION_UUID", nothing))
    public_instance = positive_instance(bindings, "SESSION_CONTROL_INSTANCE")
    controller_instance = positive_instance(bindings, "SESSION_CONTROLLER_INSTANCE")
    admission_instance = positive_instance(bindings, "ADMISSION_CONTROLLER_INSTANCE")
    public_instance != controller_instance || fail("session endpoint instances must differ")
    admission_instance != public_instance && admission_instance != controller_instance ||
        fail("admission controller instance must be distinct from session endpoints")
    pids = node_pids(session, records, node_owners)
    core_nodes = sort!([name for (name, role) in node_owners if role == "core"])
    core_owner = Dict("pid" => verified_pid(records, "core"), "nodes" => core_nodes)
    declarations = owner_specs(spec)
    all(role -> haskey(declarations, role) || role in ("core", "fgn"), keys(records)) ||
        fail("an owner process record has no matching owner declaration")
    owners = Any[
        owner_record(role, declarations[role], records, bindings) for
        role in sort!(collect(keys(records))) if haskey(declarations, role)
    ]
    haskey(declarations, source_role) || fail("source owner has no declaration")
    source_declaration = declarations[source_role]
    source = owner_record(source_role, source_declaration, records, bindings)
    for field in ("control-protocol", "control-node")
        haskey(source, field) || fail("source owner is missing $field")
    end
    auxiliary_roles = auxiliary_source_roles(
        get(spec, "auxiliary-source-owners", String[]), declarations, source_role
    )
    auxiliary = map(auxiliary_roles) do role
        declaration = declarations[role]
        D.uses_source_control_protocol(declaration) &&
        D.uses_bootstrap_protocol(declaration) ||
            fail("auxiliary source requires native SourceControl and owner bootstrap")
        owner_record(role, declaration, records, bindings)
    end
    source_nodes = [
        source["control-node"], [entry["control-node"] for entry in auxiliary]...
    ]
    length(unique(source_nodes)) == length(source_nodes) ||
        fail("primary and auxiliary sources require distinct control node names")
    policy = Dict{String,Any}(
        "session" => deepcopy(session),
        "owners" => owners,
        "source" => source,
        "auxiliary-sources" => auxiliary,
        "node.pids" => pids,
        "core.owner" => core_owner,
        "instance" => string(public_instance),
        "controller.instance" => string(controller_instance),
        "session.uuid" => uuid,
        "node.name" => "pipewireao.rtc.session." * name,
        "controller.node.name" => "pipewireao.rtc.controller." * name,
        "admission.controller-instance" => string(admission_instance),
        "startup.timeout-ms" => D.startup_timeout_ms(spec),
        "properties" => merge(
            Dict("pipewireao.rtc.session.session-uuid" => uuid),
            PipeWireAORTC.InstrumentDefinition.publication(spec, bindings),
        ),
    )
    return Dict{String,Any}(
        "context.properties" => Dict{String,Any}(
            "library.use-fallback" => false,
            "support.dbus" => false,
            "remote.name" => joinpath(runtime, remote_name),
        ),
        "context.modules" => Any[
            Dict("name" => "libpipewire-module-protocol-native"),
            Dict("name" => "libpipewire-module-client-node"),
        ],
        "pipewireao.session" => policy,
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

end # module
