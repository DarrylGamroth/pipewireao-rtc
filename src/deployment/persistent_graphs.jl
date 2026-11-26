# The installed graph services have a systemd lifetime independent of the RTC.
# Their launcher and each RTC activation use the same sealed deployment inputs.
const GRAPH_MANIFEST_ENV = "PIPEWIREAORTC_GRAPH_MANIFEST_SHA256"
const GRAPH_MANIFEST = "graph-owners.json"
const GRAPH_ASSETS = "graph-owner-assets.json"

function graph_unit_name(name, role)
    occursin(r"^[a-z0-9][a-z0-9-]{0,39}$", name) && occursin(S.ROLE, role) ||
        fail("invalid persistent graph service name")
    return "pipewireao-graph-$name-$role.service"
end

graph_bootstrap_instance(invocation) =
    string(parse(Int64, first(S.valid_invocation(invocation), 15); base = 16) + 1)

function graph_owners(spec)
    startup = PipeWireAORTC.GraphStartup
    owners = filter(spec["owners"]) do owner
        owner["role"] != spec["source-owner"] &&
            startup.owner_arguments(owner) !== nothing
    end
    isempty(owners) && fail("persistent graph mode requires a declared graph owner")
    for owner in owners
        role = owner["role"]
        arguments = startup.owner_arguments(owner)
        D.uses_bootstrap_protocol(owner) ||
            fail("persistent graph mode requires native bootstrap for $role")
        "--session-run-control" in arguments ||
            fail("persistent graph owner $role requires session run control")
        flags = Set(first(split(arg, '='; limit = 2)) for arg in arguments)
        unsupported = (
            "--physical-offsets", "--row-workers", "--capture-backend",
            "--matrix-layout", "--persistent", "--parameter", "--check",
        )
        any(in(flags), unsupported) &&
            fail("persistent graph owner $role requires complete-frame CPU execution and FITS startup parameters")
        choices = findall(arg -> first(split(arg, '='; limit = 2)) == "--execution", arguments)
        if !isempty(choices)
            length(choices) == 1 || fail("persistent graph owner $role has ambiguous execution")
            index = only(choices)
            complete = arguments[index] == "--execution=complete-frame" ||
                (arguments[index] == "--execution" && index < length(arguments) &&
                 arguments[index + 1] == "complete-frame")
            complete || fail("persistent graph owner $role requires complete-frame execution")
        end
        !("--correction-property" in flags) || "--prime-on-output" in flags ||
            fail("persistent correction owner $role requires live priming")
    end
    return owners
end

function graph_file_identity(path)
    value = stat(path)
    isfile(value) || fail("persistent graph input is not a file: $path")
    return Dict(
        "device" => value.device, "inode" => value.inode, "size" => value.size,
        "mtime" => value.mtime, "ctime" => value.ctime,
    )
end

function graph_asset_inventory(package, spec, project, executables, paths, generated)
    files = [
        [D.relative_asset(package, file) for file in keys(spec["artifacts"])];
        joinpath(package, "deployment.conf");
        joinpath(project, "Project.toml");
        joinpath(project, "Manifest.toml");
        executables;
        paths["daemon"];
        joinpath(paths["library"], "libpipewire-ao-0.3.so");
        generated;
    ]
    return Dict(
        path => merge(graph_file_identity(path), Dict("sha256" => C.sha256_file(path)))
        for path in unique(files)
    )
end

function graph_argument_files(arguments, directory, inventory, prefix)
    files = Set{String}()
    function input(path)
        selected = realpath(joinpath(directory, path))
        haskey(inventory, selected) ||
            fail("persistent graph input is outside the installed asset inventory: $selected")
        push!(files, selected)
        return selected
    end
    for (index, argument) in pairs(arguments)
        terms = split(argument, '='; limit = 2)
        first(terms) in ("--graph", "--fits-bindings", "--supervision", "--chopped-warmup") ||
            continue
        path = input(length(terms) == 2 ? last(terms) : arguments[index + 1])
        if first(terms) == "--graph"
            document = D.decode(path, prefix)
            document isa AbstractDict || fail("persistent graph must be an object: $path")
            # Use the argument's path when resolving relative references, as the
            # scientific graph loader does. Check canonical paths against the inventory.
            graph = joinpath(directory, length(terms) == 2 ? last(terms) : arguments[index + 1])
            foreach(input, PipeWireAORTC.GraphOwner.composition_files(document, graph))
        elseif first(terms) == "--fits-bindings"
            entries = PipeWireAORTC.GraphOwner.bindings(path, D.decode(path, prefix))
            foreach(entry -> input(entry.source.path), entries)
        end
    end
    return files
end

function sealed_graph_document(path, digest)
    isfile(path) && !islink(path) && filesize(path) <= D.MAX_CONFIG_BYTES ||
        fail("persistent graph document is missing or invalid: $path")
    bytes = open(io -> read(io, D.MAX_CONFIG_BYTES + 1), path)
    length(bytes) <= D.MAX_CONFIG_BYTES &&
        occursin(r"^[0-9a-f]{64}$", digest) && bytes2hex(sha256(bytes)) == digest ||
        fail("persistent graph document changed: $path")
    data = C.parse_json(String(bytes))
    data isa AbstractDict && get(data, "version", nothing) === 1 ||
        fail("unsupported persistent graph document: $path")
    return data
end

function verify_graph_assets!(path, digest)
    data = sealed_graph_document(path, digest)
    for (file, expected) in data["files"]
        observed = graph_file_identity(file)
        all(expected[key] == value for (key, value) in observed) ||
            fail("persistent graph input changed: $file")
    end
    return data["files"]
end

# Run in the final Julia MainPID. The process argv keeps the asset digest, so
# a service launched for an older installation cannot attest to the new files.
function bind_persistent_graph!(arguments)
    path, digest = popfirst!(arguments), popfirst!(arguments)
    inventory = verify_graph_assets!(path, digest)
    for file in graph_argument_files(arguments, pwd(), inventory, ENV["PIPEWIREAO_PREFIX"])
        inventory[file]["sha256"] == C.sha256_file(file) ||
            fail("persistent graph input content changed: $file")
    end
    instance = findfirst(==("--bootstrap-instance"), arguments)
    instance === nothing && fail("persistent graph launcher lacks a bootstrap instance")
    arguments[instance + 1] = graph_bootstrap_instance(get(ENV, "INVOCATION_ID", ""))
    push!(arguments, "--persistent")
    return nothing
end

function install_persistent_graphs!(package, prefix, spec, external;
    stop_unit = joinpath(PipeWireAORTC.resource_root(), "persistent-graph-stop.service.in"),
    ready_unit = joinpath(PipeWireAORTC.resource_root(), "persistent-graph-ready.service.in"),
)
    if isfile(stop_unit)
        Sys.isexecutable("/usr/bin/waitpid") ||
            fail("persistent graph service shutdown requires /usr/bin/waitpid from util-linux")
    end
    external === nothing &&
        fail("persistent graph mode requires an independent core and publishing source")
    package = realpath(package)
    prefix = realpath(prefix)
    source = only(owner for owner in spec["owners"] if owner["role"] == spec["source-owner"])
    external_source!(spec, deepcopy(source))
    owners = graph_owners(spec)
    paths = D.installed_paths(prefix)
    project = D.application_environment(spec, package)
    systemd = joinpath(package, "systemd")
    runtime = joinpath(systemd, "graph-owners")
    mkdir(runtime; mode = 0o700)
    assets = joinpath(systemd, GRAPH_ASSETS)
    manifest = joinpath(systemd, GRAPH_MANIFEST)
    all(path -> !(ispath(path) || islink(path)), (assets, manifest)) ||
        fail("persistent graph manifest paths are reserved for installation")
    generated = String[]
    bindings = Dict(
        "PACKAGE" => package, "PREFIX" => prefix, "RUNTIME" => runtime,
        "REMOTE" => external.socket,
    )
    request = (; package, prefix)
    prepare_julia_overlay!(request, paths, spec, runtime)
    overrides = joinpath(runtime, "julia-depot", "artifacts", "Overrides.toml")
    isfile(overrides) && push!(generated, overrides)
    graphs = joinpath(package, "graphs")
    if isdir(graphs)
        for name in readdir(graphs)
            endswith(name, ".conf.in") || continue
            source_graph = D.relative_asset(package, joinpath("graphs", name))
            graph = joinpath(runtime, name[1:(end-3)])
            write(graph, D.substitute(read(source_graph, String), bindings; quoted = true))
            push!(generated, graph)
        end
    end
    for owner in owners
        role = owner["role"]
        directory = joinpath(runtime, role)
        mkdir(directory; mode = 0o700)
        client = D.relative_asset(package, spec["client"][role])
        output = joinpath(directory, "client.conf")
        write(output, D.substitute(read(client, String), bindings; quoted = true))
        push!(generated, output)
    end
    executables = Dict(
        owner["role"] => D.selected_julia_executable(
            realpath(D.substitute(first(owner["argv"]), bindings))
        ) for owner in owners
    )
    inventory = graph_asset_inventory(package, spec, project, collect(values(executables)), paths, generated)
    C.write_json(assets, Dict("version" => 1, "files" => inventory); atomic = true)
    digest = C.sha256_file(assets)
    entries = Dict{String,Any}()
    notify = isfile(ready_unit)
    for owner in owners
        role = owner["role"]
        unit = graph_unit_name(spec["name"], role)
        unit in (external.core, external.source) &&
            fail("persistent graph service conflicts with an independent provider")
        placement = spec["placement"][role]
        local_bindings = merge(bindings, Dict(D.bootstrap_instance_key(role) => "1"))
        # Install captures only the Julia depot selection from the installer.
        # Deployment and role declarations provide any other owner environment.
        ambient = Dict{String,String}()
        haskey(ENV, "JULIA_DEPOT_PATH") &&
            (ambient["JULIA_DEPOT_PATH"] = ENV["JULIA_DEPOT_PATH"])
        env = owner_environment(paths, spec, local_bindings, runtime, role; ambient)
        env["PIPEWIREAO_PREFIX"] = prefix
        for (key, value) in owner["environment"]
            env[key] = D.substitute(value, local_bindings)
        end
        private_remote_environment(env, runtime, bindings)
        get(env, "LD_LIBRARY_PATH", "") == paths["library"] &&
            !haskey(env, "JULIA_LOAD_PATH") &&
            !haskey(env, "JULIA_FILTER_GRAPH_QUIT_REQUEST") &&
            env["PIPEWIREAO_PREFIX"] == prefix &&
            get(env, "PIPEWIREAO_CONFIG_DIR", "") == joinpath(runtime, role) ||
            fail("persistent graph owner $role overrides its private environment")
        env["JULIA_LOAD_PATH"] = "@:@stdlib"
        argv = String[D.substitute(arg, local_bindings) for arg in owner["argv"]]
        argv[1] = executables[role]
        split_arg = findfirst(==("-e"), argv)
        split_arg !== nothing && argv[split_arg+1] == PipeWireAORTC.GraphStartup.ENTRY ||
            fail("persistent graph owner $role does not use the package Julia entry")
        julia_arguments = argv[2:(split_arg-1)]
        projects = filter(arg -> startswith(arg, "--project="), julia_arguments)
        length(projects) == 1 && realpath(only(projects)[11:end]) == project ||
            fail("persistent graph owner $role uses a different Julia project")
        "--startup-file=no" in julia_arguments &&
            all(arg -> occursin(r"^(?:--(?:project|threads)=.+|--startup-file=no|-O[0-3])$", arg), julia_arguments) ||
            fail("persistent graph owner $role has unsupported Julia launch arguments")
        directory = joinpath(runtime, role)
        graph_argument_files(argv[(split_arg + 3):end], directory, inventory, prefix)
        (isfile(overrides) && first(split(env["JULIA_DEPOT_PATH"], ':')) !=
            joinpath(runtime, "julia-depot")) &&
            fail("persistent graph owner $role overrides its native depot binding")
        PipeWireAORTC.GraphStartup.configure_owner!(argv, package, owner)
        code_index = findfirst(==("-e"), argv) + 1
        entry = PipeWireAORTC.GraphStartup.ENTRY
        launch = "using PipeWireAORTC; PipeWireAORTC.SessionLaunch.bind_persistent_graph!(ARGS); " *
                 "PipeWireAORTC.GraphOwner.main(ARGS)"
        argv[code_index] = replace(argv[code_index], entry => launch)
        insert!(argv, code_index + 2, assets)
        insert!(argv, code_index + 3, digest)
        path = joinpath(systemd, unit)
        ispath(path) || islink(path) ? fail("persistent graph service already exists: $unit") : nothing
        unit_text = S.owner_service_unit(
            role, argv, env, directory, placement;
            after = [external.core], requisite = [external.core],
            stop_signal = get(owner, "stop-signal", "SIGTERM"),
        )
        if notify
            readiness = replace(read(ready_unit, String),
                "@TIMEOUT_START@" => string(D.startup_timeout_ms(spec), "ms"))
            unit_text = replace(unit_text, "Type=exec\n" => "", "TimeoutStartSec=20\n" => "")
            unit_text *= "\n" * readiness
        end
        # Only pinned graph packages that implement cooperative service shutdown
        # supply this unit fragment. Historical installations keep their launcher.
        if isfile(stop_unit)
            unit_text *= "\n" * read(stop_unit, String)
        end
        write(path, "# Generated by PipeWireAORTC.SessionInstall. Reinstall to change this unit.\n" * unit_text)
        entries[role] = Dict(
            "unit" => unit, "fragment" => path, "sha256" => C.sha256_file(path),
            "type" => notify ? "notify" : "exec",
            "argv" => argv, "placement" => placement,
            "environment" => Dict(key => env[key] for key in (
                "LD_LIBRARY_PATH", "PIPEWIREAO_CONFIG_DIR", "PIPEWIREAO_PREFIX",
                "JULIA_DEPOT_PATH", "JULIA_LOAD_PATH",
                "PIPEWIREAO_REMOTE", "PIPEWIRE_REMOTE", "PIPEWIREAO_RUNTIME_DIR",
                "PIPEWIRE_RUNTIME_DIR",
            )),
            "pipewire-library" => realpath(joinpath(paths["library"], "libpipewire-ao-0.3.so")),
        )
    end
    C.write_json(manifest, Dict(
        "version" => 1, "package" => package, "prefix" => prefix, "assets" => assets,
        "asset-sha256" => digest, "core" => external.core, "source" => external.source,
        "socket" => external.socket, "owners" => entries,
    ); atomic = true)
    owner_units = Dict(role => item["unit"] for (role, item) in entries)
    return (; manifest, digest = C.sha256_file(manifest), owners = owner_units,
        units = sort!(collect(values(owner_units))))
end

function reference_persistent_graphs(installation, package, prefix, spec, external)
    provider = realpath(installation)
    manifest = D.relative_asset(provider, joinpath("systemd", GRAPH_MANIFEST))
    filesize(manifest) <= D.MAX_CONFIG_BYTES || fail("referenced graph manifest exceeds size bound")
    digest = C.sha256_file(manifest)
    provider_spec = D.profile(joinpath(provider, "deployment.conf"), prefix)
    data = installed_graphs(provider, prefix, provider_spec, external; digest)
    selected = Dict(owner["role"] => owner for owner in graph_owners(spec))
    supplied = Dict(owner["role"] => owner for owner in graph_owners(provider_spec))
    selected == supplied && spec["environment"] == provider_spec["environment"] ||
        fail("referenced graph owner declarations differ from the selected deployment")
    inventory = verify_graph_assets!(data["assets"], data["asset-sha256"])
    native_library = realpath(joinpath(D.installed_paths(prefix)["library"], "libpipewire-ao-0.3.so"))
    provider_session = D.decode(D.relative_asset(provider, provider_spec["session"]), prefix)
    session = D.decode(D.relative_asset(package, spec["session"]), prefix)
    for (role, item) in data["owners"]
        fragment = item["fragment"]
        isfile(fragment) && !islink(fragment) && filesize(fragment) <= D.MAX_CONFIG_BYTES &&
            C.sha256_file(fragment) == item["sha256"] ||
            fail("referenced graph service fragment changed for $role")
        item["placement"] == spec["placement"][role] ||
            fail("referenced graph placement differs for $role")
        endpoints(deployment, config) = Dict(
            node["node.name"] => node
            for section in ("sources", "graphs", "sinks") for node in config[section]
            if deployment["node-owners"][node["node.name"]] == role
        )
        endpoints(spec, session) == endpoints(provider_spec, provider_session) ||
            fail("referenced graph endpoints differ for $role")
        haskey(inventory, realpath(first(item["argv"]))) ||
            fail("referenced graph executable is outside the installed asset inventory")
        item["pipewire-library"] == native_library ||
            fail("referenced graph uses a different PipeWireAO library")
        client = D.relative_asset(provider, provider_spec["client"][role])
        same_graph_asset(inventory, client, D.relative_asset(package, spec["client"][role]))
        directory = item["environment"]["PIPEWIREAO_CONFIG_DIR"]
        generated = joinpath(provider, "systemd", "graph-owners")
        for file in graph_argument_files(item["argv"], directory, inventory, prefix)
            if dirname(file) == generated
                relative = joinpath("graphs", basename(file) * ".in")
                template = D.relative_asset(provider, relative)
                same_graph_asset(inventory, template, D.relative_asset(package, relative))
            else
                asset = D.relative_asset(package, relpath(file, provider))
                same_graph_asset(inventory, file, asset)
            end
        end
    end
    owners = Dict(role => item["unit"] for (role, item) in data["owners"])
    return (; manifest, digest, owners, units = sort!(collect(values(owners))))
end

function same_graph_asset(inventory, provider, selected)
    expected = get(inventory, provider, nothing)
    expected !== nothing && C.sha256_file(selected) == expected["sha256"] ||
        fail("referenced graph input differs: $selected")
    return nothing
end

function installed_graphs(package, prefix, spec, external; digest = get(ENV, GRAPH_MANIFEST_ENV, nothing))
    digest === nothing && return nothing
    external === nothing && fail("persistent graph mode requires independent core and source")
    manifest = sealed_graph_document(joinpath(package, "systemd", GRAPH_MANIFEST), digest)
    (manifest["package"], manifest["prefix"], manifest["core"], manifest["source"],
        manifest["socket"]) == (package, prefix, external.core, external.source, external.socket) ||
        fail("persistent graph installation differs from the selected deployment")
    entries = manifest["owners"]
    roles = Set(owner["role"] for owner in graph_owners(spec))
    Set(keys(entries)) == roles || fail("persistent graph service roles differ from the deployment")
    for (role, item) in entries
        unit = graph_unit_name(spec["name"], role)
        item["unit"] == unit && item["fragment"] == joinpath(package, "systemd", unit) &&
            item["placement"] == spec["placement"][role] ||
            fail("persistent graph service differs from the deployment: $role")
    end
    verify_graph_assets!(manifest["assets"], manifest["asset-sha256"])
    return manifest
end

function retain_persistent_graphs!(package, prefix, spec, external, coordinator, record)
    services = Dict{String,S.Service}()
    digest = get(ENV, GRAPH_MANIFEST_ENV, nothing)
    digest === nothing && return (; digest, services)
    runtime = record["runtime"]
    launch_record!(runtime, record)
    try
        manifest = installed_graphs(package, prefix, spec, external)
        for (role, item) in manifest["owners"]
            service = external_service(coordinator, role, item["unit"])
            verify_persistent_service!(service, item)
            services[role] = service
        end
    catch error
        record["phase"] = "failed"
        record["error"] = sprint(showerror, error)
        launch_record!(runtime, record)
        rethrow()
    end
    return (; digest, services)
end

function graph_library_mapping(line, library, inode)
    fields = split(line; limit = 6)
    return length(fields) == 6 && lstrip(fields[6]) == library &&
           tryparse(UInt64, fields[5]) == inode
end

# A staged systemd instance can use an exact copy of its installed template.
function installed_fragment_matches(path, template, digest, instance)
    isfile(path) || return false
    fragment = realpath(path)
    exact = fragment == template ||
        (instance !== nothing && fragment == joinpath(dirname(template), instance))
    return exact && C.sha256_file(fragment) == digest
end

function verify_persistent_service!(
    service, item; manager = nothing, deadline = nothing, clock = Clocks.SystemNanoClock(),
    attached = false, instance_template = false,
)
    values = S.unit_properties(
        manager, service.unit; extra = "FragmentPath,DropInPaths,NeedDaemonReload,Type,Restart,KillMode",
        deadline, clock,
    )
    S.same_incarnation(service, values) && values["LoadState"] == "loaded" &&
        values["ActiveState"] == "active" && S.parsed_pid(values) == S.pid(service) &&
        values["Type"] == get(item, "type", "exec") && values["Restart"] == "no" &&
        values["KillMode"] == "control-group" && isempty(values["DropInPaths"]) &&
        values["NeedDaemonReload"] in (false, "no") &&
        installed_fragment_matches(values["FragmentPath"], item["fragment"], item["sha256"],
            instance_template ? service.unit : nothing) && S.alive(service) ||
        fail("unit differs from its installed service: $(service.unit)")
    pid = S.pid(service)
    argv = item["argv"]
    graph_file_identity("/proc/$pid/exe") == graph_file_identity(first(argv)) &&
        split(read("/proc/$pid/cmdline", String), '\0'; keepempty = false) == argv ||
        fail("service process differs from its installed command: $(service.unit)")
    env = split(read("/proc/$pid/environ", String), '\0'; keepempty = false)
    all(("$key=$value" in env) for (key, value) in item["environment"]) &&
        "INVOCATION_ID=$(service.invocation)" in env && S.alive(service) ||
        fail("service process differs from its installed environment: $(service.unit)")
    if attached
        library = item["pipewire-library"]
        inode = stat(library).inode
        open("/proc/$pid/maps", "r") do maps
            any(line -> graph_library_mapping(line, library, inode), eachline(maps))
        end || fail("service process is using a different PipeWireAO library")
    end
    return nothing
end
