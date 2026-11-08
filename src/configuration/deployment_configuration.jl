module DeploymentConfiguration

using JSON, TOML
using ..Common
using ..Placement
import ..PipeWireAORTC
import ..ScienceExport
import ..ControlClient
import ..OwnerBootstrapCodec

export DeploymentError,
    fail,
    require,
    digest,
    atomic_record,
    installed_paths,
    decode,
    validate_environment,
    relative_asset,
    valid_cpu_list,
    uses_bootstrap_protocol,
    bootstrap_instance_key,
    uses_heart_protocol,
    uses_source_control_protocol,
    uses_acquisition_protocol,
    validate_acquisition_arguments,
    validate_bootstrap_arguments,
    validate_session_runtime,
    profile,
    substitute,
    selected_julia_executable,
    shell_quote,
    registered_application,
    application_environment

const MAX_EXTERNAL_OWNERS = 8
const MAX_SESSION_LINKS = 64
const MAX_CONFIG_BYTES = 16 * 1024 * 1024
const REQUIRED_KEYS = Set([
    "version",
    "name",
    "session",
    "core",
    "client",
    "placement",
    "owners",
    "environment",
    "artifacts",
    "cpu-latency-us",
])

struct DeploymentError <: Exception
    message::String
end
Base.showerror(io::IO, error::DeploymentError) = print(io, error.message)
fail(message) = throw(DeploymentError(message))
require(condition, message) = condition || fail(message)
digest(path::AbstractString) = Common.sha256_file(path)
atomic_record(path::AbstractString, value) = Common.write_json(path, value; atomic = true)

function installed_paths(prefix::AbstractString)
    candidates = [joinpath(prefix, "lib"), joinpath(prefix, "lib64")]
    lib = joinpath(prefix, "lib")
    isdir(lib) && append!(candidates, readdir(lib; join = true))
    libraries = filter(path -> isfile(joinpath(path, "libpipewire-ao-0.3.so")), candidates)
    length(libraries) == 1 ||
        fail("expected one installed PipeWireAO library directory in $prefix")
    library = only(libraries)
    paths = Dict(
        "library" => library,
        "modules" => joinpath(library, "pipewire-ao-0.3"),
        "spa" => joinpath(library, "spa-ao-0.2"),
        "daemon" => joinpath(prefix, "bin/pipewire-ao"),
        "parser" => joinpath(prefix, "bin/pwao-spa-json-dump"),
    )
    for (label, path) in paths
        ispath(path) || fail("missing installed $label: $path")
    end
    paths
end

function decode(path::AbstractString, prefix::AbstractString)
    filesize(path) <= MAX_CONFIG_BYTES || fail("deployment configuration exceeds 16 MiB")
    try
        return Common.read_json(path; maximum = MAX_CONFIG_BYTES)
    catch error
        return decode_fallback(error, path, prefix)
    end
end

# Offline optical-calibration exports may have no operational connections.
# An actual native session additionally requires at least one connection.
function validate_session_links(session)
    links = get(session, "links", Any[])
    validate_links(links)
    return links
end

# Mirror native session policy before owners are launched. Ownership and a
# processing graph's run-control grant are separate declarations (RTC-DEV-016).
function validate_execution_groups(session)
    controlled = Dict{String,Bool}()
    required = Set{String}()
    processing = Set{String}()
    graphs = Set{String}()
    for role in ("sources", "graphs", "sinks")
        entries = get(session, role, Any[])
        validate_session_role!(controlled, required, processing, graphs, entries, role)
    end
    groups = get(session, "execution-groups", Any[])
    names = Set{String}()
    membership = Dict{String,String}()
    validate_execution_group_memberships!(
        names, membership, groups, graphs, processing, controlled
    )
    if !isempty(graphs)
        for node in sort!(collect(required))
            require(
                haskey(membership, node),
                "eligible graph or nonexternal sink has no execution group: $node",
            )
        end
    end
    for link in get(session, "links", Any[])
        output, input = link["output"], link["input"]
        from = get(membership, first(split(output, ':'; limit = 2)), nothing)
        to = get(membership, first(split(input, ':'; limit = 2)), nothing)
        require(
            from === nothing || to === nothing || from == to,
            "link crosses execution groups: $output → $input",
        )
        boundary = from === nothing && to !== nothing
        require(
            (get(link, "passive", false) === true) == boundary,
            "invalid execution-group passive boundary: $output → $input (passive must be $boundary)",
        )
    end
    return nothing
end

validate_environment(value, label) =
    fail("$label environment must map valid names to strings")
function validate_environment(value::AbstractDict, label)
    require(
        all(valid_environment_entry(key, item) for (key, item) in value),
        "$label environment must map valid names to strings",
    )
end
valid_environment_entry(key, item) = false
valid_environment_entry(key::String, item::String) =
    !isempty(key) && !occursin('=', key) && !occursin('\0', key) && !occursin('\0', item)

relative_asset(package::AbstractString, name) =
    fail("installed asset must be a package-relative path")
function relative_asset(package::AbstractString, name::String)
    require(
        !isempty(name) && !occursin('\0', name) && !isabspath(name),
        "installed asset must be a package-relative path",
    )
    candidate = realpath(joinpath(package, name))
    root = realpath(package)
    require(
        startswith(candidate, root * "/") && isfile(candidate),
        "asset escapes package or is not a file: $name",
    )
    candidate
end

valid_cpu_list(value::AbstractVector) = Placement.cpu_set(value)
valid_cpu_list(value) = fail("process CPU envelope must be a list")

"Return whether a declaration selects the exact OwnerBootstrap protocol."
uses_bootstrap_protocol(owner) =
    get(owner, "bootstrap-protocol", nothing) ==
    ControlClient.profile_name(OwnerBootstrapCodec.PROFILE)
bootstrap_instance_key(role::AbstractString) =
    "BOOTSTRAP_INSTANCE_" * replace(uppercase(role), "-" => "_")

"Return whether a declaration selects the existing HEART wrapper control protocol."
uses_heart_protocol(owner) =
    get(owner, "control-protocol", nothing) == "pipewireao.rtc.heart/1"

"Return whether a declaration selects the SourceControl protocol."
uses_source_control_protocol(owner) =
    get(owner, "control-protocol", nothing) == "pipewireao.source-control/1"

"Return whether a declaration selects a calibration or correction acquisition-lifecycle protocol."
uses_acquisition_protocol(owner) = get(owner, "control-protocol", nothing) in
("pipewireao.rtc.calibration-lifecycle/1", "pipewireao.rtc.correction-lifecycle/1")

function validate_acquisition_arguments(owner)
    argv = owner["argv"]
    for flag in (
        "--prepared-event",
        "--connect-request",
        "--connect-reply",
        "--quit-request",
        "--control-request",
        "--control-reply",
    )
        require(!(flag in argv), "native acquisition cannot use live file controls")
    end
    for (flag, value) in (
        ("--control-node", owner["control-node"]),
        ("--control-instance", "@SOURCE_OWNER_INSTANCE@"),
        ("--profile", owner["instrument"]),
        ("--remote", "@RUNTIME@/@REMOTE@"),
    )
        indices = findall(==(flag), argv)
        require(
            length(indices) == 1 &&
                only(indices) < length(argv) &&
                argv[only(indices)+1] == value,
            "native acquisition requires the exact $flag binding",
        )
    end
    return nothing
end

function validate_bootstrap_arguments(owner)
    argv = owner["argv"]
    for flag in (
        "--prepared-event",
        "--connect-request",
        "--connect-reply",
        "--quit-request",
        "--control-request",
        "--control-reply",
    )
        require(
            !any(arg -> first(split(arg, '='; limit = 2)) == flag, argv),
            "native bootstrap cannot use live file controls",
        )
    end
    for (flag, value) in (
        ("--bootstrap-node", owner["bootstrap-node"]),
        ("--bootstrap-instance", "@" * bootstrap_instance_key(owner["role"]) * "@"),
        ("--remote", "@RUNTIME@/@REMOTE@"),
    )
        indices = findall(arg -> first(split(arg, '='; limit = 2)) == flag, argv)
        require(
            length(indices) == 1 &&
                argv[only(indices)] == flag &&
                only(indices) < length(argv) &&
                argv[only(indices)+1] == value,
            "native bootstrap requires the exact $flag binding",
        )
    end
    if uses_source_control_protocol(owner)
        flag = "--control-node"
        indices = findall(arg -> first(split(arg, '='; limit = 2)) == flag, argv)
        require(
            length(indices) == 1 &&
                argv[only(indices)] == flag &&
                only(indices) < length(argv) &&
                argv[only(indices)+1] == owner["control-node"],
            "native source requires the exact --control-node binding",
        )
        require(
            owner["bootstrap-node"] != owner["control-node"],
            "source and bootstrap nodes must differ",
        )
    end
    thread_flags = filter(arg -> startswith(arg, "--threads="), argv)
    require(
        length(thread_flags) == 1 &&
            occursin(r"^--threads=([2-9]|[1-9][0-9]+),0$", only(thread_flags)),
        "native bootstrap requires at least two default Julia threads and zero interactive threads",
    )
    return nothing
end

const SESSION_PRIVATE_ENVIRONMENT = Set([
    "INVOCATION_ID",
    "NOTIFY_SOCKET",
    "SYSTEMD_EXEC_PID",
    "RTC_CONFIG",
    "WIREPLUMBER_CONFIG",
    "WIREPLUMBER_CONFIG_DIR",
    "WIREPLUMBER_MODULE_DIR",
    "WIREPLUMBER_DATA_DIR",
    "LD_LIBRARY_PATH",
    "PIPEWIRE_RUNTIME_DIR",
    "PIPEWIRE_REMOTE",
    "PIPEWIREAO_REMOTE",
    "PIPEWIREAORTC_JULIA",
    "PIPEWIREAORTC_PROJECT",
])

"Validate the sole headless RTC executable and its exact invocation."
validate_session_runtime(value) = fail("session-runtime requires argv and environment")
function validate_session_runtime(value::AbstractDict)
    require(
        Set(keys(value)) == Set(["argv", "environment"]),
        "session-runtime requires argv and environment",
    )
    argv = value["argv"]
    validate_session_argv(argv)
    validate_environment(value["environment"], "session-runtime")
    require(
        isempty(intersect(Set(keys(value["environment"])), SESSION_PRIVATE_ENVIRONMENT)),
        "session-runtime environment cannot override private session bindings",
    )
    return nothing
end

"Resolve the generated RTC launcher from the sealed deployment contract."
function session_executable(spec, package, prefix)
    value = spec["session-runtime"]
    validate_session_runtime(value)
    expected = "@PACKAGE@/rtc/bin/pipewireao-rtc"
    require(
        first(value["argv"]) == expected,
        "session-runtime executable does not match its sealed deployment",
    )
    return substitute(expected, Dict("PACKAGE" => package, "PREFIX" => prefix))
end

"Return the pinned Julia process binding used by the generated RTC launcher."
function session_process_binding(
    spec::AbstractDict, package::AbstractString, config::AbstractString
)
    validate_session_runtime(spec["session-runtime"])
    launcher_project = application_environment(spec, package)
    isdir(launcher_project) || fail("selected Julia project environment is unavailable")
    julia = selected_julia_executable(Base.julia_cmd().exec[1])
    return Dict{String,Any}(
        "julia" => julia,
        "project" => launcher_project,
        "config" => String(config),
        "argv" => ScienceExport.rtc_arguments(julia, launcher_project, config),
    )
end

"Verify exact Julia executable, pinned project, launcher arguments, and config."
function verify_session_process(pid::Integer, binding::AbstractDict)
    require(
        Set(keys(binding)) == Set(("julia", "project", "config", "argv")),
        "invalid headless RTC process binding",
    )
    julia, project, config, argv = session_process_values(
        binding["julia"], binding["project"], binding["config"], binding["argv"]
    )
    expected = ScienceExport.rtc_arguments(julia, project, config)
    require(argv == expected, "invalid headless RTC process arguments")
    observed = try
        realpath("/proc/$pid/exe") == realpath(julia) &&
            split(read("/proc/$pid/cmdline", String), '\0'; keepempty = false) == expected
    catch
        false
    end
    require(observed, "session MainPID is not the exact prepared headless RTC executable")
    return nothing
end

session_process_values(julia, project, config, argv) =
    fail("invalid headless RTC process binding types")
function session_process_values(
    julia::AbstractString,
    project::AbstractString,
    config::AbstractString,
    argv::AbstractVector,
)
    all(isabspath, (julia, project, config)) ||
        fail("headless RTC process paths must be absolute")
    return String(julia),
    String(project), String(config),
    String[session_process_argument(value) for value in argv]
end
session_process_argument(value::AbstractString) = String(value)
session_process_argument(value) = fail("headless RTC process argument must be text")

"Explicit cold startup budget; acquisition and live-control deadlines are separate."
function startup_timeout_ms(spec::AbstractDict)
    value = get(spec, "startup-timeout-ms", 300000)
    validate_startup_timeout(value)
    return Int(value)
end

"""Whether this deployment obtains its executable implementation from Julia packages."""
registered_application(spec::AbstractDict) = haskey(spec, "runtime")

"""Validate a contained, immutable application environment without resolving packages."""
function application_environment(spec::AbstractDict, package::AbstractString)
    require(
        registered_application(spec),
        "deployment requires a registered RTC package dependency; copied SDK runtimes are retired",
    )
    runtime = spec["runtime"]
    validate_registered_runtime(runtime)
    project = runtime["project"]
    validate_runtime_project(project)
    root = realpath(package)
    environment = realpath(joinpath(root, project))
    require(
        environment == root || startswith(environment, root * "/"),
        "runtime project escapes the application",
    )
    sealed = get(spec, "artifacts", Dict())
    for filename in ("Project.toml", "Manifest.toml")
        relative = normpath(joinpath(project, filename))
        file = relative_asset(root, relative)
        require(
            get(sealed, relative, nothing) == digest(file),
            "application environment must be sealed: $relative",
        )
    end
    metadata = TOML.parsefile(joinpath(environment, "Project.toml"))
    require(
        !haskey(metadata, "workspace"),
        "deployed application must not declare a development workspace",
    )
    direct = get(metadata, "deps", Dict())
    require(
        get(direct, "PipeWireAORTC", nothing) == "a3e2c7da-f73f-4284-8482-36ac422b34e6",
        "application must depend on PipeWireAORTC",
    )
    require(
        !haskey(metadata, "sources"),
        "registered application must not override package sources",
    )
    manifest = TOML.parsefile(joinpath(environment, "Manifest.toml"))
    dependencies = get(manifest, "deps", nothing)
    validate_manifest_dependencies(dependencies)
    for (name, uuid) in direct
        entries = get(dependencies, name, Any[])
        validate_direct_dependency(entries, name, uuid)
    end
    for (name, entries) in dependencies
        validate_manifest_entries(entries, name)
        for entry in entries
            validate_manifest_entry(entry, name)
            uuid = get(entry, "uuid", nothing)
            validate_manifest_uuid(uuid, name)
            stdlib = joinpath(Sys.STDLIB, name, "Project.toml")
            bundled = isfile(stdlib) && get(TOML.parsefile(stdlib), "uuid", nothing) == uuid
            tree = get(entry, "git-tree-sha1", nothing)
            require(
                bundled || valid_manifest_tree(tree),
                "registered dependency $name requires an immutable tree hash",
            )
            version = get(entry, "version", nothing)
            require(
                bundled || valid_manifest_version(version),
                "registered dependency $name requires a package version",
            )
            required = get(entry, "deps", String[])
            names = manifest_dependency_names(required, name)
            require(
                all(dependency -> haskey(dependencies, dependency), names),
                "application manifest is missing a dependency of $name",
            )
            for dependency in names
                candidates = dependencies[dependency]
                validate_manifest_candidates(candidates, required, dependency, name)
            end
        end
    end
    return environment
end

# Explicit FGI pins must remain consistent when complete owner argv is replaced.
# This is cold metadata validation; it neither imports FGI nor changes affinity.
function validate_owner_pins(owner, placement)
    argv = owner["argv"]
    option_key(arg) = first(split(arg, '='; limit = 2))
    any(arg -> option_key(arg) == "--pin-cpus", argv) || return nothing
    function option_value(flag)
        positions = findall(arg -> option_key(arg) == flag, argv)
        require(
            length(positions) == 1, "explicit CPU pins require exactly one $flag argument"
        )
        index = only(positions)
        terms = split(argv[index], '='; limit = 2)
        length(terms) == 2 && return last(terms)
        require(index < length(argv), "$flag requires a value")
        return argv[index+1]
    end
    raw_pins = tryparse.(Int, split(option_value("--pin-cpus"), ','; keepempty = true))
    require(
        !isempty(raw_pins) && all(cpu -> cpu !== nothing && cpu >= 2, raw_pins),
        "--pin-cpus requires CPU IDs >= 2 separated by commas",
    )
    pins = Int[cpu for cpu in raw_pins]
    count = tryparse(Int, first(split(option_value("--threads"), ','; keepempty = true)))
    require(
        count !== nothing && count > 0,
        "explicit CPU pins require an explicit positive default Julia thread count",
    )
    require(
        length(pins) == count,
        "owner $(owner["role"]) --pin-cpus must list one CPU per default Julia thread",
    )
    require(
        Set(pins) ⊆ valid_cpu_list(placement["cpus"]),
        "owner $(owner["role"]) CPU pins exceed its declared process envelope",
    )
    require(
        first(pins) == placement["leader-cpu"],
        "owner $(owner["role"]) thread one CPU must equal its declared process leader",
    )
    return nothing
end

"Validate the existing process and thread placement contracts without reading an application."
validate_placements(placements, roles) =
    fail("each owned process requires an explicit placement contract")
function validate_placements(placements::AbstractDict, roles)
    require(
        Set(keys(placements)) == roles,
        "each owned process requires an explicit placement contract",
    )
    for (role, placement) in placements
        validate_process_placement(placement, role)
        envelope = valid_cpu_list(placement["cpus"])
        require(
            typeof(placement["leader-cpu"]) === Int && placement["leader-cpu"] in envelope,
            "process leader CPU must belong to its declared envelope",
        )
        priority = placement["rt-priority"]
        require(
            typeof(priority) === Int && 0 <= priority <= 99,
            "RT priority must be an integer in 0..99",
        )
        require(
            typeof(placement["locked-bytes"]) === Int && placement["locked-bytes"] >= 0,
            "locked-bytes must be nonnegative",
        )
        threads = placement["threads"]
        validate_required_threads(threads)
        for thread in threads
            validate_required_thread(thread)
            require(
                required_thread_cpu_set(thread["cpus"]) ⊆ envelope,
                "required thread exceeds process envelope",
            )
            require(
                thread["policy"] in ("fifo", "other") &&
                    typeof(thread["count"]) === Int &&
                    typeof(thread["priority"]) === Int &&
                    1 <= thread["count"] <= 128 &&
                    thread["priority"] == (thread["policy"] == "fifo" ? priority : 0),
                "invalid required thread policy/count",
            )
            require(
                !haskey(thread, "name") || valid_required_thread_name(thread["name"]),
                "required thread name must be a nonempty string",
            )
        end
    end
    return nothing
end

function profile(path::AbstractString, prefix::AbstractString)
    value = decode(path, prefix)
    result = validate_application(value, path, prefix)
    application_environment(value, dirname(path))
    return result
end

# Shared structural, asset and ownership checks. This does not qualify a
# dependency environment; installation always goes through profile above.
validate_application(value, path, prefix) =
    fail("expected version 1 deployment with the documented fields")
function validate_application(value::AbstractDict, path, prefix)
    require(
        REQUIRED_KEYS ⊆
        Set(keys(value)) ⊆
        union(
            REQUIRED_KEYS,
            Set([
                "source-owner",
                "auxiliary-source-owners",
                "detector-observation",
                "session-runtime",
                "node-owners",
                "startup-timeout-ms",
                "runtime",
                "analysis",
                "instrument",
            ]),
        ) && get(value, "version", nothing) === 1,
        "expected version 1 deployment with the documented fields",
    )
    startup_timeout_ms(value)
    validate_deployment_name(value["name"])
    owners = value["owners"]
    validate_external_owners(owners)
    require(
        !haskey(value, "analysis") || valid_analysis_entries(value["analysis"]),
        "deployment analysis must be a list of at most eight entries",
    )
    validate_environment(value["environment"], "deployment")
    roles = Set(["core", "rtc"])
    if haskey(value, "session-runtime")
        validate_session_runtime(value["session-runtime"])
        push!(roles, "session")
    end
    source_role = get(value, "source-owner", nothing)
    require(
        source_role === nothing || valid_source_role(source_role),
        "source-owner must name an existing external owner",
    )
    auxiliary = get(value, "auxiliary-source-owners", String[])
    validate_auxiliary_sources(auxiliary, source_role)
    for owner in owners
        validate_external_owner!(owner, source_role, auxiliary, roles)
    end
    require(
        source_role === nothing || source_role in (owner["role"] for owner in owners),
        "source-owner must name an existing external owner",
    )
    require(
        all(role -> role in (owner["role"] for owner in owners), auxiliary),
        "auxiliary-source-owners must name declared external owners",
    )
    if !isempty(auxiliary)
        primary = only(filter(owner -> owner["role"] == source_role, owners))
        require(
            uses_source_control_protocol(primary) || uses_acquisition_protocol(primary),
            "auxiliary sources require a native primary source control",
        )
        source_controls = [
            owner["control-node"] for
            owner in owners if owner["role"] in auxiliary || owner["role"] == source_role
        ]
        require(
            length(unique(source_controls)) == length(source_controls),
            "primary and auxiliary sources require distinct control node names",
        )
    end
    haskey(value, "detector-observation") &&
        validate_detector_observation(value["detector-observation"])
    require(
        !get(value, "detector-observation", false) ||
            source_role !== nothing && uses_source_control_protocol(
                only(filter(owner -> owner["role"] == source_role, owners))
            ),
        "detector observation requires an admitted native source owner",
    )
    validate_placements(value["placement"], roles)
    for owner in owners
        uses_bootstrap_protocol(owner) &&
            validate_owner_pins(owner, value["placement"][owner["role"]])
    end
    latency = value["cpu-latency-us"]
    require(
        latency === nothing || typeof(latency) === Int && 0 <= latency <= typemax(Int32),
        "cpu-latency-us must be null or a nonnegative Int32",
    )
    client_roles =
        isempty(get(value, "analysis", [])) ? roles : union(roles, Set(["analysis"]))
    validate_client_roles(value["client"], client_roles)
    for name in values(value["client"])
        relative_asset(dirname(path), name)
    end
    relative_asset(dirname(path), value["session"])
    relative_asset(dirname(path), value["core"])
    validate_deployment_artifacts(value["artifacts"], path)
    session = decode(relative_asset(dirname(path), value["session"]), prefix)
    validate_session_links(session)
    validate_execution_groups(session)
    if haskey(value, "node-owners")
        mapping = value["node-owners"]
        mapping = node_owners(mapping)
        nodes = String[]
        fgn = false
        parameters = false
        for section in ("sources", "graphs", "sinks")
            entries = get(session, section, nothing)
            found_fgn, found_parameters = collect_node_owner_endpoints!(
                nodes, entries, section
            )
            fgn |= found_fgn
            parameters |= found_parameters
        end
        roles = Set(owner["role"] for owner in owners)
        fgn && push!(roles, "fgn")
        parameters && push!(roles, "parameters")
        core = decode(relative_asset(dirname(path), value["core"]), prefix)
        core_nodes = Set{String}()
        for item in get(core, "context.objects", Any[])
            collect_core_object!(core_nodes, item)
        end
        # Queue streams belong to the private core's native client; their names
        # still originate in the sealed core declaration.
        for item in get(core, "context.modules", Any[])
            collect_core_queue!(core_nodes, item)
        end
        !isempty(core_nodes) && push!(roles, "core")
        require(
            length(unique(nodes)) == length(nodes) &&
                Set(keys(mapping)) == Set(nodes) &&
                all(role in roles for role in values(mapping)),
            "node-owners must cover each declared node once with a declared owner role",
        )
        for section in ("sources", "graphs", "sinks"), item in session[section]
            if mapping[item["node.name"]] == "core"
                require(
                    item["node.name"] in core_nodes,
                    "core-mapped node must have an exact private core context object or queue stream",
                )
            end
            if section == "graphs" &&
                get(item, "factory", nothing) == "pipewireao.fgn-native"
                require(
                    mapping[item["node.name"]] == "fgn",
                    "FGN graph must map to its own host",
                )
            elseif section == "sources" &&
                get(item, "factory", nothing) == "pipewireao.runtime-parameter"
                require(
                    mapping[item["node.name"]] == "parameters",
                    "runtime parameter source must map to the parameters owner",
                )
            end
        end
    end
    PipeWireAORTC.Analysis.validate_deployment(value, path, prefix)
    if haskey(value, "instrument")
        asset = relative_asset(dirname(path), value["instrument"])
        haskey(value["artifacts"], value["instrument"]) ||
            fail("instrument definition must be sealed")
        PipeWireAORTC.InstrumentDefinition.load(asset)
    end
    Dict{String,Any}(value)
end

function substitute(value::AbstractString, bindings::AbstractDict; quoted = false)
    result = String(value)
    for (name, replacement) in bindings
        escaped = quoted ? String(JSON.json(replacement))[2:(end-1)] : string(replacement)
        result = replace(result, "@$name@" => escaped)
    end
    occursin(r"@[A-Z_]+@", result) &&
        fail("unresolved deployment binding in $(first(result, min(length(result), 200)))")
    result
end

function selected_julia_executable(path::AbstractString)
    isabspath(path) &&
    !occursin('\0', path) &&
    !occursin('\n', path) &&
    !occursin('\r', path) || fail("--julia-executable must be an absolute executable path")
    isfile(path) && isexecutable(path) ||
        fail("selected Julia executable is missing or not executable: $path")
    executable = realpath(path)
    probe = try
        Common.run_checked(
            [
                executable,
                "--startup-file=no",
                "--history-file=no",
                "-e",
                "print(VERSION, '\\n', Base.julia_cmd().exec[1])",
            ];
            timeout = 15,
            maximum_output_bytes = 4096,
        )
    catch error
        fail("cannot validate selected Julia executable $path: $(sprint(showerror, error))")
    end
    fields = split(strip(probe.stdout), '\n')
    version = tryparse(VersionNumber, first(fields))
    probe.returncode == 0 && version !== nothing && v"1.12" <= version < v"2" ||
        fail("selected Julia executable must run Julia >= 1.12 and < 2: $path")
    length(fields) == 2 &&
    isabspath(fields[2]) &&
    isfile(fields[2]) &&
    isexecutable(fields[2]) || fail(
        "selected Julia executable did not report its absolute runtime executable: $path",
    )
    # Pin the managed runtime itself when selection was through juliaup.
    return realpath(fields[2])
end

shell_quote(value::AbstractString) = "'" * replace(value, "'" => "'\"'\"'") * "'"

decode_fallback(error::SystemError, path, prefix) = rethrow()
function decode_fallback(error, path, prefix)
    paths = installed_paths(prefix)
    env = merge(Dict(ENV), Dict("LD_LIBRARY_PATH" => paths["library"]))
    out, _, code = Common.run_checked(
        [paths["parser"], "-N", "-R", path]; env, timeout = 10
    )
    code == 0 || fail("installed SPA-JSON parser rejected $path")
    ncodeunits(out) <= MAX_CONFIG_BYTES ||
        fail("decoded deployment configuration exceeds 16 MiB")
    return Common.parse_json(out)
end

validate_links(links) =
    fail("session links must be a list of at most $MAX_SESSION_LINKS declared connections")
function validate_links(links::AbstractVector)
    require(
        length(links) <= MAX_SESSION_LINKS,
        "session links must be a list of at most $MAX_SESSION_LINKS declared connections",
    )
    return nothing
end

validate_session_node_name(name, controlled) =
    fail("session node names must be nonempty and unique: $name")
function validate_session_node_name(name::String, controlled)
    require(
        !isempty(name) && !haskey(controlled, name),
        "session node names must be nonempty and unique: $name",
    )
    return nothing
end

validate_execution_group_name(name, names) =
    fail("execution group name must be nonempty and unique: $name")
function validate_execution_group_name(name::String, names)
    require(
        !isempty(name) && !occursin('\0', name) && !(name in names),
        "execution group name must be nonempty and unique: $name",
    )
    return nothing
end

validate_execution_group_nodes(nodes, name) = fail("execution group has no members: $name")
function validate_execution_group_nodes(nodes::AbstractVector, name)
    require(!isempty(nodes), "execution group has no members: $name")
    return nothing
end

validate_execution_group_member(node, controlled, membership) =
    fail("unknown or duplicate execution group member: $node")
function validate_execution_group_member(node::String, controlled, membership)
    require(
        haskey(controlled, node) && !haskey(membership, node),
        "unknown or duplicate execution group member: $node",
    )
    return nothing
end

validate_session_argv(argv) =
    fail("session-runtime requires pipewireao-rtc -c @RUNTIME@/rtc/rtc.conf")
function validate_session_argv(argv::AbstractVector)
    require(
        length(argv) == 3 &&
            all(valid_argv_argument, argv) &&
            first(argv) == "@PACKAGE@/rtc/bin/pipewireao-rtc" &&
            argv[2] == "-c" &&
            argv[3] == "@RUNTIME@/rtc/rtc.conf",
        "session-runtime requires the packaged pipewireao-rtc launcher -c @RUNTIME@/rtc/rtc.conf",
    )
    return nothing
end

valid_argv_argument(value::String) = !occursin('\0', value)
valid_argv_argument(value) = false

validate_startup_timeout(value) =
    fail("startup-timeout-ms must be an integer in 1000:3600000")
function validate_startup_timeout(value::Integer)
    require(
        1000 <= value <= 3600000, "startup-timeout-ms must be an integer in 1000:3600000"
    )
    return nothing
end

validate_startup_timeout(value::Bool) =
    fail("startup-timeout-ms must be an integer in 1000:3600000")

validate_registered_runtime(runtime) = fail("runtime requires kind=registered and project")
function validate_registered_runtime(runtime::AbstractDict)
    require(
        Set(keys(runtime)) == Set(["kind", "project"]) && runtime["kind"] == "registered",
        "runtime requires kind=registered and project",
    )
    return nothing
end

validate_runtime_project(project) = fail("runtime project must be a relative directory")
function validate_runtime_project(project::String)
    require(
        !isempty(project) && !isabspath(project) && !occursin('\0', project),
        "runtime project must be a relative directory",
    )
    return nothing
end

validate_manifest_dependencies(dependencies) =
    fail("application manifest must contain its dependency closure")
function validate_manifest_dependencies(dependencies::AbstractDict)
    require(
        !isempty(dependencies), "application manifest must contain its dependency closure"
    )
    return nothing
end

validate_direct_dependency(entries, name, uuid) =
    fail("application manifest must resolve direct dependency $name exactly once")
function validate_direct_dependency(entries::AbstractVector, name, uuid)
    require(
        count(entry -> matches_manifest_uuid(entry, uuid), entries) == 1,
        "application manifest must resolve direct dependency $name exactly once",
    )
    return nothing
end

matches_manifest_uuid(entry::AbstractDict, uuid) = get(entry, "uuid", nothing) == uuid
matches_manifest_uuid(entry, uuid) = false

validate_manifest_entries(entries, name) = fail("invalid manifest dependency $name")
function validate_manifest_entries(entries::AbstractVector, name)
    require(!isempty(entries), "invalid manifest dependency $name")
    return nothing
end

validate_manifest_entry(entry, name) = fail("invalid manifest dependency record $name")
function validate_manifest_entry(entry::AbstractDict, name)
    require(
        !haskey(entry, "path") && !haskey(entry, "repo-url") && !haskey(entry, "repo-rev"),
        "application dependencies must resolve through registries",
    )
    return nothing
end

validate_manifest_uuid(uuid, name) = fail("invalid manifest UUID for $name")
function validate_manifest_uuid(uuid::String, name)
    require(
        occursin(r"^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$", uuid),
        "invalid manifest UUID for $name",
    )
    return nothing
end

valid_manifest_tree(value::String) = occursin(r"^[0-9a-f]{40}$", value)
valid_manifest_tree(value) = false
valid_manifest_version(value::String) = tryparse(VersionNumber, value) !== nothing
valid_manifest_version(value) = false

manifest_dependency_names(required::AbstractVector, name) = required
manifest_dependency_names(required::AbstractDict, name) = keys(required)
manifest_dependency_names(required, name) = fail("invalid dependency list for $name")

validate_manifest_candidates(candidates, required, dependency, name) =
    fail("application manifest has an ambiguous dependency of $name")
function validate_manifest_candidates(
    candidates::AbstractVector, required, dependency, name
)
    require(
        manifest_dependency_matches(candidates, required, dependency),
        "application manifest has an ambiguous dependency of $name",
    )
    return nothing
end

manifest_dependency_matches(candidates, required::AbstractDict, dependency) =
    count(
        candidate -> matches_manifest_uuid(candidate, required[dependency]), candidates
    ) == 1
manifest_dependency_matches(candidates, required::AbstractVector, dependency) =
    length(candidates) == 1

validate_process_placement(placement, role) = fail("invalid placement contract for $role")
function validate_process_placement(placement::AbstractDict, role)
    require(
        Set(keys(placement)) ==
        Set(["cpus", "leader-cpu", "rt-priority", "threads", "locked-bytes"]),
        "invalid placement contract for $role",
    )
    return nothing
end

validate_required_threads(threads) = fail("thread requirements must be a bounded list")
function validate_required_threads(threads::AbstractVector)
    require(length(threads) <= 128, "thread requirements must be a bounded list")
    return nothing
end

validate_required_thread(thread) = fail("invalid required thread fields")
function validate_required_thread(thread::AbstractDict)
    require(
        Set(["cpus", "policy", "priority", "count"]) ⊆
        Set(keys(thread)) ⊆
        Set(["cpus", "policy", "priority", "count", "name"]),
        "invalid required thread fields",
    )
    return nothing
end

valid_required_thread_name(value::String) = !isempty(value) && !occursin('\0', value)
valid_required_thread_name(value) = false

validate_deployment_name(name) =
    fail("deployment name must use 1..40 lowercase letters, digits or hyphens")
function validate_deployment_name(name::String)
    require(
        occursin(r"^[a-z0-9][a-z0-9-]{0,39}$", name),
        "deployment name must use 1..40 lowercase letters, digits or hyphens",
    )
    return nothing
end

validate_external_owners(owners) = fail("deployment permits at most eight external owners")
function validate_external_owners(owners::AbstractVector)
    require(
        length(owners) <= MAX_EXTERNAL_OWNERS,
        "deployment permits at most eight external owners",
    )
    return nothing
end

valid_analysis_entries(value::AbstractVector) = length(value) <= 8
valid_analysis_entries(value) = false

valid_source_role(value::String) = !isempty(value)
valid_source_role(value) = false

validate_auxiliary_sources(auxiliary, source_role) = fail(
    "auxiliary-source-owners must uniquely name at most seven owners distinct from the primary source",
)
function validate_auxiliary_sources(auxiliary::AbstractVector, source_role)
    require(
        length(auxiliary) <= MAX_EXTERNAL_OWNERS - 1 &&
            all(valid_source_role, auxiliary) &&
            length(unique(auxiliary)) == length(auxiliary) &&
            !(source_role in auxiliary) &&
            (isempty(auxiliary) || source_role !== nothing),
        "auxiliary-source-owners must uniquely name at most seven owners distinct from the primary source",
    )
    return nothing
end

valid_owner_node_name(value::String) = occursin(r"^[a-zA-Z0-9_.-]{1,128}$", value)
valid_owner_node_name(value) = false

validate_external_owner_role(role, roles) =
    fail("external owner role must be unique and filesystem-safe")
function validate_external_owner_role(role::String, roles)
    require(
        !(role in roles) && occursin(r"^[a-z][a-z0-9-]{0,31}$", role),
        "external owner role must be unique and filesystem-safe",
    )
    return nothing
end

validate_owner_argv(argv) = fail("owner argv must be a nonempty bounded string list")
function validate_owner_argv(argv::AbstractVector)
    require(
        1 <= length(argv) <= 256 && all(valid_argv_argument, argv) && !isempty(argv[1]),
        "owner argv must be a nonempty bounded string list",
    )
    require(
        !any(arg -> occursin(r"\bAOSOwner\s*\.\s*main\b", arg), argv),
        "AOSOwner.main has been retired. Export the simulation for AdaptiveOpticsSimPipeWireHIL and launch it separately.",
    )
    return nothing
end

validate_detector_observation(value::Bool) = nothing
validate_detector_observation(value) = fail("detector-observation must be a Boolean")

validate_client_roles(clients, client_roles) = fail(
    "each owned process and optional analysis require an explicit client configuration"
)
function validate_client_roles(clients::AbstractDict, client_roles)
    require(
        Set(keys(clients)) == client_roles,
        "each owned process and optional analysis require an explicit client configuration",
    )
    return nothing
end

validate_artifact_hash(sha, asset, name) = fail("deployment artifact hash mismatch: $name")
function validate_artifact_hash(sha::String, asset, name)
    require(
        occursin(r"^[0-9a-f]{64}$", sha) && digest(asset) == sha,
        "deployment artifact hash mismatch: $name",
    )
    return nothing
end

node_owners(mapping) = fail("node-owners must map exact node names to owner roles")
node_owners(mapping::AbstractDict) =
    Dict{String,String}(node_owner_pair(key, role) for (key, role) in mapping)
node_owner_pair(key::String, role::String) = key => role
node_owner_pair(key, role) = fail("node-owners must map exact node names to owner roles")

node_owner_name(item) = fail("node-owners requires declared node.name for every endpoint")
node_owner_name(item::AbstractDict) = node_owner_name_value(get(item, "node.name", nothing))
node_owner_name_value(value::String) = value
node_owner_name_value(value) =
    fail("node-owners requires declared node.name for every endpoint")

collect_core_object!(nodes, item) = nothing
collect_core_object!(nodes, item::AbstractDict) =
    collect_core_object_args!(nodes, get(item, "args", nothing))
collect_core_node!(nodes, properties) = nothing
collect_core_object_args!(nodes, properties) = nothing
collect_core_object_args!(nodes, properties::AbstractDict) =
    collect_core_node!(nodes, get(properties, "node.name", nothing))
collect_core_node!(nodes, name::String) = push!(nodes, name)
collect_core_queue!(nodes, item) = nothing
function collect_core_queue!(nodes, item::AbstractDict)
    get(item, "name", nothing) == "libpipewire-module-queue" || return nothing
    return collect_core_queue_args!(nodes, get(item, "args", nothing))
end
collect_core_queue_args!(nodes, args) = nothing
function collect_core_queue_args!(nodes, args::AbstractDict)
    for key in ("capture.props", "playback.props")
        properties = get(args, key, nothing)
        collect_core_queue_properties!(nodes, properties)
    end
    return nothing
end
collect_core_queue_properties!(nodes, properties) = nothing
collect_core_queue_properties!(nodes, properties::AbstractDict) =
    collect_core_node!(nodes, get(properties, "node.name", nothing))

validate_external_owner!(owner, source_role, auxiliary, roles) =
    fail("external owner fields do not match the deployment contract")
function validate_external_owner!(owner::AbstractDict, source_role, auxiliary, roles)
    ordinary = !uses_heart_protocol(owner) && !uses_acquisition_protocol(owner)
    require(
        !ordinary || uses_bootstrap_protocol(owner),
        "ordinary owner requires native bootstrap; regenerate the deployment from its sealed artifacts",
    )
    fields = if !ordinary
        Set(["role", "argv", "environment", "control-protocol", "control-node"])
    else
        Set(["role", "argv", "environment", "bootstrap-protocol", "bootstrap-node"])
    end
    if uses_bootstrap_protocol(owner)
        node = get(owner, "bootstrap-node", nothing)
        require(
            valid_owner_node_name(node),
            "native bootstrap requires a bounded exact node name",
        )
    end
    if uses_acquisition_protocol(owner)
        push!(fields, "instrument")
        require(
            get(owner, "role", nothing) == source_role,
            "native acquisition lifecycle must be the selected source owner",
        )
        require(
            get(owner, "instrument", nothing) in ("classic", "copper"),
            "native acquisition requires an explicit Classic or Copper instrument",
        )
        node = get(owner, "control-node", nothing)
        require(
            valid_owner_node_name(node),
            "native acquisition requires a bounded exact node name",
        )
    end
    if uses_heart_protocol(owner)
        require(
            get(owner, "role", nothing) == "heart",
            "native HEART profile requires the heart role",
        )
        node = get(owner, "control-node", nothing)
        require(
            valid_owner_node_name(node), "native HEART requires a bounded exact node name"
        )
    end
    if source_role !== nothing && (
        get(owner, "role", nothing) == source_role ||
        get(owner, "role", nothing) in auxiliary
    )
        if get(owner, "role", nothing) in auxiliary
            require(
                uses_source_control_protocol(owner) && uses_bootstrap_protocol(owner),
                "auxiliary source requires native SourceControl and owner bootstrap",
            )
        end
        require(
            uses_acquisition_protocol(owner) || uses_source_control_protocol(owner),
            "source owner requires a native source control profile",
        )
        uses_acquisition_protocol(owner) ||
            union!(fields, ["control-protocol", "control-node"])
        if uses_source_control_protocol(owner)
            node = get(owner, "control-node", nothing)
            require(
                valid_owner_node_name(node),
                "native source requires a bounded exact node name",
            )
        end
    end
    require(
        Set(keys(owner)) == fields,
        "external owner fields do not match the deployment contract",
    )
    role = owner["role"]
    require(
        role != "heart" || uses_heart_protocol(owner),
        "HEART owner requires the native control profile",
    )
    validate_external_owner_role(role, roles)
    push!(roles, role)
    argv = owner["argv"]
    validate_owner_argv(argv)
    uses_acquisition_protocol(owner) && validate_acquisition_arguments(owner)
    uses_bootstrap_protocol(owner) && validate_bootstrap_arguments(owner)
    validate_environment(owner["environment"], "owner $role")
    return nothing
end

validate_session_role!(controlled, required, processing, graphs, entries, role) =
    fail("session $role must be a list")
function validate_session_role!(
    controlled, required, processing, graphs, entries::AbstractVector, role
)
    for entry in entries
        validate_session_node!(controlled, required, processing, graphs, entry, role)
    end
    return nothing
end
validate_session_node!(controlled, required, processing, graphs, entry, role) =
    fail("session $role entry must be a mapping")
function validate_session_node!(
    controlled, required, processing, graphs, entry::AbstractDict, role
)
    name = get(entry, "node.name", nothing)
    validate_session_node_name(name, controlled)
    ownership = get(entry, "ownership", nothing)
    grant = get(entry, "run-control", nothing)
    require(ownership in (nothing, "runner", "external"), "invalid node ownership: $name")
    managed = if ownership != "external"
        require(grant === nothing, "runner-owned node has an external run-control grant: $name")
        true
    elseif role == "graphs"
        require(
            grant in ("session", "application"),
            "external graph requires an explicit run-control grant: $name",
        )
        grant == "session"
    else
        require(
            grant in (nothing, "application"),
            "external source or sink remains application controlled: $name",
        )
        false
    end
    controlled[name] = managed
    if role == "graphs" && managed
        push!(graphs, name)
        push!(required, name)
        get(entry, "factory", nothing) == "api.ndarray.latest-hold" ||
            push!(processing, name)
    elseif role == "sinks" && ownership != "external"
        push!(required, name)
    end
    return nothing
end

validate_execution_group_memberships!(
    names, membership, groups, graphs, processing, controlled
) = fail("execution-groups must be a list")
function validate_execution_group_memberships!(
    names, membership, groups::AbstractVector, graphs, processing, controlled
)
    require(
        !isempty(graphs) == !isempty(groups),
        "execution groups require session-controlled graphs and vice versa",
    )
    for group in groups
        validate_execution_group!(names, membership, group, processing, controlled)
    end
    return nothing
end
validate_execution_group!(names, membership, group, processing, controlled) =
    fail("execution group must be a mapping")
function validate_execution_group!(
    names, membership, group::AbstractDict, processing, controlled
)
    name = get(group, "name", nothing)
    validate_execution_group_name(name, names)
    push!(names, name)
    nodes = get(group, "nodes", nothing)
    validate_execution_group_nodes(nodes, name)
    for node in nodes
        validate_execution_group_member(node, controlled, membership)
        require(
            controlled[node],
            "application-controlled external node cannot belong to execution group: $node",
        )
        membership[node] = name
    end
    require(
        any(node -> node in processing, nodes),
        "execution group contains no session-controlled processing graph: $name",
    )
    return nothing
end

required_thread_cpu_set(cpus::AbstractVector) = Placement.cpu_set(cpus)
required_thread_cpu_set(cpus) = fail("required thread CPUs must be a list")

validate_deployment_artifacts(artifacts, path) =
    fail("deployment artifacts must be a path/hash mapping")
function validate_deployment_artifacts(artifacts::AbstractDict, path)
    for (name, sha) in artifacts
        asset = relative_asset(dirname(path), name)
        validate_artifact_hash(sha, asset, name)
    end
    return nothing
end

collect_node_owner_endpoints!(nodes, entries, section) =
    fail("session $section must be a list for node-owners")
function collect_node_owner_endpoints!(nodes, entries::AbstractVector, section)
    fgn = false
    parameters = false
    for item in entries
        push!(nodes, node_owner_name(item))
        fgn |=
            section == "graphs" && get(item, "factory", nothing) == "pipewireao.fgn-native"
        parameters |=
            section == "sources" &&
            get(item, "factory", nothing) == "pipewireao.runtime-parameter"
    end
    return fgn, parameters
end

end
