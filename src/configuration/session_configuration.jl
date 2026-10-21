"""Generate the headless RTC configuration for one RTC invocation.

The caller supplies exact node-to-owner roles from the sealed export. This
module validates those roles against retained systemd owner records and writes
configuration only; session admission and lifecycle remain in Lua.
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

function declared_nodes(session)
    names = String[]
    factories = Dict{String,String}()
    for key in ("sources", "graphs", "sinks")
        entries = get(session, key, Any[])
        entries isa AbstractVector || fail("session $key must be a list")
        for entry in entries
            entry isa AbstractDict || fail("session $key entry must be a mapping")
            name = get(entry, "node.name", nothing)
            name isa String && !isempty(name) || fail("session $key entry needs node.name")
            name in names && fail("session declares node $name more than once")
            push!(names, name)
            if key == "graphs"
                factory = get(entry, "factory", "")
                factory isa String || fail("graph $name has an invalid factory")
                factories[name] = factory
            end
        end
    end
    return names, factories
end

function verified_pid(records, role)
    item = get(records, role, nothing)
    item isa AbstractDict && get(item, "role", nothing) == role &&
        get(item, "state", nothing) == "running" ||
        fail("node owner $role has no retained running record")
    pid = get(item, "pid", nothing)
    pid isa Integer && !(pid isa Bool) && pid > 0 && pid <= typemax(UInt32) &&
        get(item, "start-ticks", 0) isa Integer &&
        get(item, "start-ticks", 0) > 0 &&
        !isempty(get(item, "invocation", "")) &&
        startswith(get(item, "cgroup", ""), "/") ||
        fail("node owner $role lacks verified PID and process identity")
    return Int(pid)
end

function node_pids(session, records, node_owners)
    names, factories = declared_nodes(session)
    mapping = Dict{String,String}(node_owners)
    fgn = get(records, "fgn", nothing)
    if fgn !== nothing
        graph_nodes = get(fgn, "graph-nodes", nothing)
        graph_nodes isa AbstractVector && all(name -> name isa String, graph_nodes) ||
            fail("FGN record lacks exact hosted graph names")
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
        get(mapping, name, nothing) == "fgn" && fgn !== nothing &&
            name in fgn["graph-nodes"] || fail("FGN graph is not hosted by the FGN owner")
    end
    Set(keys(mapping)) == Set(names) ||
        fail("every declared source, graph and sink needs one exact owner mapping")
    return Dict{String,Int}(name => verified_pid(records, mapping[name]) for name in names)
end

function positive_instance(bindings, key)
    value = get(bindings, key, nothing)
    value isa AbstractString || fail("missing $key binding")
    parsed = tryparse(Int64, value)
    parsed !== nothing && parsed > 0 || fail("invalid $key binding")
    return parsed
end

function owner_specs(spec)
    entries = get(spec, "owners", Any[])
    entries isa AbstractVector || fail("deployment owners must be a list")
    by_role = Dict{String,Any}()
    for entry in entries
        entry isa AbstractDict || fail("deployment owner must be a mapping")
        role = get(entry, "role", nothing)
        role isa String && !isempty(role) || fail("deployment owner has no role")
        haskey(by_role, role) && fail("deployment has duplicate owner role $role")
        by_role[role] = entry
    end
    return by_role
end

function lua_owner_record(role, declaration, records, bindings)
    record = Dict{String,Any}("role" => role, "pid" => verified_pid(records, role))
    for field in ("control-protocol", "control-node", "bootstrap-protocol", "bootstrap-node")
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
    session_configuration(spec, session, bindings, records; node_owners)

Validate exact node owners and retained process identities, then return the
RTC configuration for this invocation. This does not start a session.
"""
function session_configuration(spec, session, bindings, records;
                               node_owners::Dict{String,String},
                               configuration_store_root::Union{Nothing,AbstractString}=PipeWireAORTC.ConfigurationStore.default_root())
    name = get(spec, "name", nothing)
    name isa String && occursin(r"^[a-z0-9][a-z0-9-]{0,39}$", name) ||
        fail("deployment has no validated name")
    source_role = get(spec, "source-owner", nothing)
    source_role isa String || fail("session has no declared source owner")
    verified_pid(records, source_role)
    runtime = get(bindings, "RUNTIME", nothing)
    remote_name = get(bindings, "REMOTE", nothing)
    runtime isa String && isabspath(runtime) && remote_name isa String &&
        occursin(r"^[a-zA-Z0-9_.-]+$", remote_name) ||
        fail("invalid private PipeWire remote binding")
    uuid = get(bindings, "SESSION_UUID", nothing)
    uuid isa String && occursin(r"^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$", uuid) ||
        fail("invalid session UUID binding")
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
    owners = Any[lua_owner_record(role, declarations[role], records, bindings)
        for role in sort!(collect(keys(records))) if haskey(declarations, role)]
    haskey(declarations, source_role) || fail("source owner has no declaration")
    source_declaration = declarations[source_role]
    source = lua_owner_record(source_role, source_declaration, records, bindings)
    for field in ("control-protocol", "control-node")
        haskey(source, field) || fail("source owner is missing $field")
    end
    script_path = get(bindings, "SESSION_SCRIPT", nothing)
    script_path isa String && isabspath(script_path) && !occursin('\0', script_path) ||
        fail("session script must be bound to its absolute trusted RTC asset")
    public_node = "pipewireao.rtc.session." * name
    controller_node = "pipewireao.rtc.controller." * name
    public_endpoint = Dict{String,Any}(
        "name" => "libwireplumber-module-ao-control-endpoint", "type" => "module",
        "provides" => "ao.session-control",
        "arguments" => Dict{String,Any}(
            "plugin.name" => "ao-session-control",
            "node.name" => public_node, "profile" => "pipewireao.rtc.session/1",
            "instance" => public_instance,
            "properties" => Dict("pipewireao.rtc.session.session-uuid" => uuid)))
    controller_endpoint = Dict{String,Any}(
        "name" => "libwireplumber-module-ao-control-endpoint", "type" => "module",
        "provides" => "ao.session-controller",
        "arguments" => Dict{String,Any}(
            "plugin.name" => "ao-session-controller",
            "node.name" => controller_node, "profile" => "pipewireao.rtc.controller/1",
            "instance" => controller_instance))
    script = Dict{String,Any}(
        "name" => script_path, "type" => "script/lua",
        "provides" => "ao.rtc-session",
        "requires" => ["support.lua-scripting", "si.node", "si.standard-link",
            "ao.session-control", "ao.session-controller"],
            "arguments" => Dict{String,Any}(
            "session" => deepcopy(session), "owners" => owners, "source" => source,
            "node.pids" => pids, "core.owner" => core_owner,
            "instance" => string(public_instance),
            "controller.instance" => string(controller_instance), "session.uuid" => uuid,
            "admission.controller-instance" => string(admission_instance),
            "startup.timeout-ms" => D.startup_timeout_ms(spec)))
    components = Any[Dict("name" => "libwireplumber-module-lua-scripting",
        "type" => "module", "provides" => "support.lua-scripting"),
        Dict("name" => "libwireplumber-module-si-node", "type" => "module",
            "provides" => "si.node"),
        Dict("name" => "libwireplumber-module-si-standard-link", "type" => "module",
            "provides" => "si.standard-link"),
        public_endpoint, controller_endpoint]
    features = Dict("support.lua-scripting" => "required",
        "si.node" => "required", "si.standard-link" => "required",
        "ao.session-control" => "required", "ao.session-controller" => "required",
        "ao.rtc-session" => "required")
    if configuration_store_root !== nothing
        root = String(configuration_store_root)
        isabspath(root) && !occursin('\0', root) ||
            fail("configuration store root must be an absolute path without NUL")
        push!(components, Dict("name" => "libwireplumber-module-ao-journal",
            "type" => "module", "provides" => "ao.journal",
            "arguments" => Dict("plugin.name" => "ao-journal",
                "path" => joinpath(root, "history.sqlite3"))))
        features["ao.journal"] = "required"
        push!(script["requires"], "ao.journal")
        script["arguments"]["journal.plugin"] = "ao-journal"
        public_endpoint["arguments"]["properties"]["pipewireao.rtc.session.journal"] =
            "pipewireao.configuration/1"
    end
    push!(components, script)
    return Dict{String,Any}(
        "context.properties" => Dict{String,Any}(
            "library.use-fallback" => false, "support.dbus" => false,
            "remote.name" => joinpath(runtime, remote_name)),
        "context.modules" => Any[Dict("name" => "libpipewire-module-protocol-native"),
            Dict("name" => "libpipewire-module-client-node")],
        "wireplumber.profiles" => Dict("ao-rtc" => features),
        "wireplumber.components" => components)
end

"""
    write_session_config(spec, session, bindings, records, runtime; node_owners)

Write validated native configuration below `runtime` and return its path.
The runtime must match the invocation's `RUNTIME` binding.
"""
function write_session_config(spec, session, bindings, records, runtime;
                              node_owners::Dict{String,String},
                              configuration_store_root::Union{Nothing,AbstractString}=PipeWireAORTC.ConfigurationStore.default_root())
    get(bindings, "RUNTIME", nothing) == runtime ||
        fail("configuration runtime differs from launch binding")
    config = session_configuration(spec, session, bindings, records; node_owners, configuration_store_root)
    directory = joinpath(runtime, "rtc")
    mkpath(directory)
    path = joinpath(directory, "rtc.conf")
    Export.write_spa_config(path, config)
    return path
end

end # module
