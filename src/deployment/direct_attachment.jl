# A direct installation keeps its topology on disk. Only service incarnations
# and the public RTC endpoint identity are resolved for each new connection.
function with_direct_attachment(f, config, activation, unit, root, invocation)
    package = activation["package"]
    prefix = activation["prefix"]
    config == activation["config"] == joinpath(package, "systemd", "rtc.conf") &&
        haskey(activation["files"], config) ||
        throw(ArgumentError("RTC configuration differs from the installed attachment"))
    isdir(root) && !islink(root) && stat(root).uid == ccall(:getuid, Cuint, ()) &&
        (stat(root).mode & 0o777) == 0o700 ||
        throw(ArgumentError("direct RTC requires its private systemd runtime directory"))
    spec = activation["profile"]
    source = spec["source-owner"]
    services = activation["direct-services"]
    external = SessionLaunch.external_services()
    external !== nothing && (services["core"], services[source], activation["direct-socket"]) ==
        (external.core, external.source, external.socket) ||
        throw(ArgumentError("direct service bindings differ from the installed application"))
    request = SessionLaunch.Request(package, prefix, unit, activation["launcher"], root)
    clock = Clocks.SystemNanoClock()
    deadline = Base.checked_add(Clocks.time_nanos(clock), Int64(D.startup_timeout_ms(spec)) * 1_000_000)
    instance_name = only(match(PipeWireAORTC.SessionRuntime.UNIT, unit).captures)
    resolved = Dict(role => replace(name, "%i" => instance_name) for (role, name) in services)
    manager = S.UserManager([unit; collect(values(resolved))]; deadline, clock)
    try
        attachment = direct_attachment(config, activation, request, invocation, resolved, external,
            manager, instance_name; deadline, clock)
        return f(attachment)
    finally
        close(manager)
    end
end

function direct_attachment(config, activation, request, invocation, services, external,
    manager, instance_name; deadline, clock)
    package, prefix, unit, root = request.package, request.prefix, request.unit, request.runtime_root
    spec = activation["profile"]
    source = spec["source-owner"]
    process_binding = D.session_process_binding(activation, config)
    admission = Dict{String,Any}("package" => package, "prefix" => prefix,
        "launcher" => request.launcher, "placement" => spec["placement"]["session"])
    record = Dict{String,Any}(
        "version" => SessionLaunch.LEDGER_VERSION, "direct_attach" => true,
        "unit" => unit, "runtime" => root, "invocation" => invocation,
        "config" => config, "session_process" => process_binding, "phase" => "prepared",
        "admission" => admission, "source_role" => source, "name" => spec["name"],
        "remote" => external.socket, "error" => nothing, "owners" => Dict{String,Any}(),
    )
    process = _main_identity(request, invocation, record, config; manager, deadline, clock)
    coordinator = S.Coordinator(unit, invocation, process[3], request.launcher)
    topology = get(activation, "direct-topology", nothing)
    if haskey(activation, "direct-parameter-owner")
        admission["parameter_service"] = activation["direct-parameter-service"]
        spec["placement"]["parameters"] = activation["direct-parameter-placement"]
    end
    record["credentials"] = P.credentials(spec["placement"]["session"]["rt-priority"],
        spec["placement"]["session"]["locked-bytes"], spec["cpu-latency-us"])
    declarations = if topology === nothing
        owners = SessionConfiguration.owner_specs(spec)
        SessionLaunch.external_source!(spec, owners[source])
        if haskey(activation, "direct-parameter-owner")
            owners = SessionConfiguration.owner_declarations(
                [collect(values(owners)); activation["direct-parameter-owner"]])
        end
        owners
    else
        topology["owners"]
    end
    Set(keys(services)) == union(keys(declarations), ["core"]) ||
        throw(ArgumentError("direct service bindings do not cover the installed owners"))
    bindings = Dict(
        "PACKAGE" => package, "PREFIX" => prefix, "REMOTE" => external.socket,
        "RUNTIME" => root, "INSTANCE" => invocation, "SESSION_UUID" => string(uuid4()),
        "SESSION_CONTROL_INSTANCE" => string(Client.next_instance()),
        "SESSION_CONTROLLER_INSTANCE" => string(Client.next_instance()),
        "ADMISSION_CONTROLLER_INSTANCE" => string(Client.next_instance()),
    )
    record["session_uuid"] = bindings["SESSION_UUID"]
    record["session_control_instance"] = parse(Int64, bindings["SESSION_CONTROL_INSTANCE"])
    record["session_controller_instance"] = parse(Int64, bindings["SESSION_CONTROLLER_INSTANCE"])
    record["admission_controller_instance"] = parse(Int64, bindings["ADMISSION_CONTROLLER_INSTANCE"])
    persistent = if haskey(activation, "graph-manifest")
        path = activation["graph-manifest"]
        digest = activation["graph-manifest-sha256"]
        manifest = SessionLaunch.sealed_graph_document(path, digest)
        admission["graph_manifest"] = path
        admission["graph_manifest_sha256"] = digest
        SessionLaunch.verify_graph_assets!(manifest["assets"], manifest["asset-sha256"])
        manifest["owners"]
    else
        Dict{String,Any}()
    end
    record["scoped_services"] = [
        replace(name, "%i" => instance_name) for name in activation["direct-companions"]
    ]
    for (role, service_unit) in services
        service = SessionLaunch.record_external_service!(coordinator, record, role, service_unit,
            spec["placement"][role]; manager, deadline, clock)
        item = record["owners"][role]
        if role == "parameters"
            SessionLaunch.verify_persistent_service!(service, admission["parameter_service"]; manager, deadline, clock, instance_template = true)
        elseif haskey(persistent, role)
            graph = persistent[role]
            graph["unit"] == service_unit || throw(ArgumentError("graph service binding changed: $role"))
            SessionLaunch.verify_persistent_service!(service, graph; manager, deadline, clock)
        end
        haskey(declarations, role) || continue
        owner = declarations[role]
        if D.uses_bootstrap_protocol(owner)
            instance = SessionLaunch.graph_bootstrap_instance(service.invocation)
            bindings[D.bootstrap_instance_key(role)] = instance
            item["persistent"] = role != "parameters"
            item["bootstrap-instance"] = instance
            if role == "parameters"
                item["control-instance"] = SessionLaunch.parameter_control_instance(service.invocation)
            end
        end
        for field in ("bootstrap-node", "bootstrap-protocol", "control-node", "control-protocol", "control-instance")
            haskey(owner, field) && !haskey(item, field) && (item[field] = owner[field])
        end
    end
    installed = get(activation, "direct-configuration") do
        D.decode(config, prefix) # Installations created before the normalized configuration was sealed.
    end
    session = installed["pipewireao.session"]["session"]
    plan = if topology === nothing
        topology = SessionConfiguration.session_topology(spec, session, bindings,
            spec["node-owners"], declarations)
        nothing
    else
        SessionConfiguration.installed_links(activation["direct-link-plan"], session)
    end
    bound = SessionConfiguration.bind_session_configuration(topology, session, bindings, record["owners"])
    for section in ("context.properties", "context.modules")
        installed[section] == bound[section] || throw(ArgumentError("installed PipeWire context differs: $section"))
    end
    deployment = InstalledAdmission(request, invocation, config, record, process, nothing, nothing, manager)
    return DirectAttachment(bound, deadline, deployment, plan)
end

function finish_direct_quit!(context::InstalledAdmission)
    record = context.record
    get(record, "direct_attach", false) || return nothing
    record["phase"] = "stopped"
    record["cleanup_errors"] = String[]
    record["cleanup_complete"] = true
    SessionLaunch.launch_record!(record["runtime"], record)
    return nothing
end
