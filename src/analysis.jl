"""Optional CPU analysis graphs, independent of required RTC readiness and owners."""
module Analysis

import ..Common
import ..DeploymentConfiguration
import ..SystemdOwners

public Config, Endpoint, LinkSpec, configuration, main
const D = DeploymentConfiguration
const S = SystemdOwners

struct Endpoint
    node::String
    port::String
end
struct LinkSpec
    output::Endpoint
    input::Endpoint
end
struct Config
    graph::String
    name::String
    rate::Rational{Int}
    links::Vector{LinkSpec}
    channel_units::Dict{String,Dict{String,String}}
end

Config(graph, name, rate, links) = Config(graph, name, rate, links,
    Dict{String,Dict{String,String}}())

function channel_units(value)
    value isa AbstractDict && length(value) <= 64 ||
        throw(ArgumentError("analysis channel-units must map at most 64 output Ports"))
    result = Dict{String,Dict{String,String}}()
    bytes = 0
    text(value) = value isa String && isvalid(value) && !isempty(strip(value)) &&
        ncodeunits(value) <= 255 && !any(iscntrl, value)
    for (port, channels) in value
        text(port) || throw(ArgumentError("invalid analysis channel-units Port"))
        channels isa AbstractDict && length(channels) <= 64 ||
            throw(ArgumentError("analysis channel-units must map at most 64 channel names per Port"))
        units = Dict{String,String}()
        bytes += ncodeunits(port)
        for (name, unit) in channels
            text(name) && occursin(r"^[a-z][a-z0-9_]*$", name) && text(unit) ||
                throw(ArgumentError("invalid analysis channel-units channel or units"))
            units[name] = unit
            bytes += ncodeunits(name) + ncodeunits(unit)
        end
        result[port] = units
    end
    bytes <= 16384 || throw(ArgumentError("analysis channel-units exceeds 16384 UTF-8 bytes"))
    return result
end

function endpoint(value)
    value isa String && ncodeunits(value) <= 257 ||
        throw(ArgumentError("analysis endpoint must be a bounded node:port string"))
    terms = split(value, ':'; keepempty=true)
    length(terms) == 2 && all(term -> occursin(r"^[A-Za-z0-9_.-]{1,128}$", term), terms) ||
        throw(ArgumentError("analysis endpoint must name one exact node and port"))
    return Endpoint(String(terms[1]), String(terms[2]))
end

function configuration(path::AbstractString, prefix::AbstractString)
    document = D.decode(path, prefix)
    required = Set(["graph", "name", "rate", "links"])
    document isa AbstractDict && required ⊆ Set(keys(document)) &&
        Set(keys(document)) ⊆ union(required, Set(["channel-units"])) ||
        throw(ArgumentError("analysis configuration requires graph, name, rate and links; channel-units is optional"))
    graph = D.relative_asset(dirname(abspath(path)), document["graph"])
    name = document["name"]
    name isa String && occursin(r"^[A-Za-z0-9_.-]{1,128}$", name) ||
        throw(ArgumentError("analysis name must be a bounded public node name"))
    rate = document["rate"]
    rate isa String && occursin(r"^[1-9][0-9]{0,8}/[1-9][0-9]{0,8}$", rate) ||
        throw(ArgumentError("analysis rate must be a positive bounded numerator/denominator"))
    numerator, denominator = parse.(Int, split(rate, '/'))
    entries = document["links"]
    entries isa AbstractVector && length(entries) <= 64 ||
        throw(ArgumentError("analysis links must be a list of at most 64 links"))
    links = LinkSpec[]
    addresses = Set{Tuple{String,String}}()
    for entry in entries
        entry isa AbstractDict && Set(keys(entry)) == Set(["output", "input"]) ||
            throw(ArgumentError("analysis link requires only output and input"))
        output, input = endpoint(entry["output"]), endpoint(entry["input"])
        xor(output.node == name, input.node == name) ||
            throw(ArgumentError("each analysis link must touch the analysis node exactly once"))
        address = (entry["output"], entry["input"])
        address in addresses && throw(ArgumentError("duplicate analysis link"))
        push!(addresses, address)
        push!(links, LinkSpec(output, input))
    end
    units = channel_units(get(document, "channel-units", Dict()))
    return Config(graph, name, numerator // denominator, links, units)
end

function observation_queues(spec, root, prefix)
    core = D.decode(D.relative_asset(root, spec["core"]), prefix)
    sources, sinks = Set{String}(), Set{String}()
    playback_by_capture = Dict{String,String}()
    for declaration in get(core, "context.modules", [])
        declaration isa AbstractDict && get(declaration, "name", nothing) == "libpipewire-module-queue" || continue
        args = get(declaration, "args", nothing)
        args isa AbstractDict || continue
        capture, playback = get(args,"capture.props",nothing), get(args,"playback.props",nothing)
        capture isa AbstractDict && playback isa AbstractDict || continue
        # Native queue policy is selected from module arguments, not endpoint
        # metadata. An endpoint must not make a retaining queue look like a copy.
        maximum = get(args, "queue.max-buffers", nothing)
        get(args, "queue.storage", nothing) == "copy" &&
            get(args, "queue.overflow", nothing) == "drop-oldest" &&
            ((typeof(maximum) === Int && maximum == 1) || maximum == "1") || continue
        all((capture,playback)) do props
            maximum = get(props,"queue.max-buffers",get(args,"queue.max-buffers",nothing))
            get(props,"queue.storage",get(args,"queue.storage",nothing)) == "copy" &&
                get(props,"queue.overflow",get(args,"queue.overflow",nothing)) == "drop-oldest" &&
                ((typeof(maximum) === Int && maximum == 1) || (maximum isa String && maximum == "1"))
        end || continue
        source, sink = get(playback,"node.name",nothing), get(capture,"node.name",nothing)
        source isa String && sink isa String || continue
        source in sources || sink in sinks ? D.fail("ambiguous analysis observation queue node") : nothing
        push!(sources,source)
        push!(sinks,sink)
        playback_by_capture[sink] = source
    end
    return sources, sinks, playback_by_capture
end

function validate_deployment(spec, path, prefix)
    entries = get(spec, "analysis", [])
    entries isa AbstractVector && length(entries) <= 8 ||
        D.fail("deployment analysis must be a list of at most eight entries")
    isempty(entries) && return nothing
    names, nodes = Set{String}(), Set{String}()
    output_captures = Set{String}()
    application_nodes = Set{String}(keys(get(spec, "node-owners", Dict())))
    occupied = Set{Int}()
    for placement in values(spec["placement"])
        union!(occupied, placement["cpus"])
    end
    root = dirname(abspath(path))
    artifacts = spec["artifacts"]
    sources, sinks, playback_by_capture = observation_queues(spec, root, prefix)
    session = D.decode(D.relative_asset(root,spec["session"]),prefix)
    required_inputs, required_outputs = Set{String}(), Set{String}()
    for link in get(session,"links",[])
        push!(required_inputs,endpoint(link["input"]).node)
        push!(required_outputs,endpoint(link["output"]).node)
    end
    client = get(get(spec, "client", Dict()), "analysis", nothing)
    client isa String && haskey(artifacts, client) || D.fail("analysis requires a sealed client.analysis configuration")
    client_config = D.decode(D.relative_asset(root, client), prefix)
    for declaration in get(client_config, "context.modules", [])
        declaration isa AbstractDict && get(declaration,"name",nothing) == "libpipewire-module-rt" &&
            D.fail("analysis client must not load the realtime module")
    end
    for loop in get(get(client_config,"context.properties",Dict()),"context.data-loops",[])
        get(loop,"loop.rt-prio",0) in (0,"0") || D.fail("analysis client loops must use ordinary scheduling")
    end
    for entry in entries
        entry isa AbstractDict && Set(keys(entry)) == Set(["name", "config", "cpus"]) ||
            D.fail("analysis entry requires only name, config and cpus")
        name = entry["name"]
        name isa String && occursin(r"^[a-z][a-z0-9-]{0,22}$", name) && !(name in names) ||
            D.fail("analysis name must be unique and fit its analysis- service role")
        ("analysis-" * name) in keys(spec["placement"]) &&
            D.fail("analysis service role conflicts with a required owner")
        push!(names, name)
        cpus = entry["cpus"]
        cpus isa AbstractVector && 1 <= length(cpus) <= 128 &&
            all(cpu -> typeof(cpu) === Int && cpu >= 2, cpus) &&
            length(unique(cpus)) == length(cpus) && isempty(intersect(occupied, cpus)) ||
            D.fail("analysis CPUs must be unique, exclude CPUs 0/1 and required process envelopes")
        source = D.relative_asset(root, entry["config"])
        haskey(artifacts, entry["config"]) || D.fail("analysis configuration must be sealed")
        config = configuration(source, prefix)
        relative_graph = relpath(config.graph, root)
        haskey(artifacts, relative_graph) || D.fail("analysis graph must be sealed")
        !(config.name in nodes || config.name in application_nodes || config.name in sources || config.name in sinks) ||
            D.fail("analysis graph node name conflicts with another declared node")
        push!(nodes, config.name)
        for link in config.links
            if link.input.node == config.name
                link.output.node in sources && !(link.output.node in application_nodes) &&
                    !(link.output.node in required_outputs) ||
                    D.fail("analysis input must use a declared capacity-one copy/drop-oldest queue playback")
            else
                link.input.node in sinks && !(link.input.node in required_inputs) &&
                    !(playback_by_capture[link.input.node] in required_outputs) ||
                    D.fail("analysis output requires an exclusive observation queue capture with no required playback consumers")
                link.input.node in output_captures && D.fail("analysis outputs must not share a queue capture")
                push!(output_captures,link.input.node)
            end
        end
    end
    return nothing
end

function arguments(args)
    values = Dict{String,String}()
    index = 1
    while index <= length(args)
        key = args[index]
        key in ("--config", "--remote") && !haskey(values, key) && index < length(args) ||
            throw(ArgumentError("analysis requires --config PATH --remote ABSOLUTE_SOCKET"))
        index += 1
        values[key] = args[index]
        index += 1
    end
    Set(keys(values)) == Set(["--config", "--remote"]) ||
        throw(ArgumentError("analysis requires --config and --remote"))
    remote = values["--remote"]
    isabspath(remote) && !occursin(r"[\0\n\r]", remote) ||
        throw(ArgumentError("analysis requires an absolute private remote"))
    return values["--config"], remote
end

function run_graph end

function main(args=ARGS)
    path, remote = arguments(args)
    config = configuration(path, get(ENV, "PIPEWIREAO_PREFIX", "/opt/pipewireao"))
    for name in (:FilterGraphIsland, :FilterGraphPipeWire, :JuliaFilterGraph)
        Base.require(Main, name)
    end
    Base.invokelatest(run_graph, config, remote)
    return 0
end

save_receipt!(runtime, record) = Common.write_json(joinpath(runtime, "analysis.json"), record; atomic=true)

function environment(runtime, prefix, library; config_directory=runtime, modules="", spa="")
    env = Dict{String,String}(ENV)
    for key in ("NOTIFY_SOCKET", "INVOCATION_ID", "JOURNAL_STREAM", "SYSTEMD_EXEC_PID")
        delete!(env, key)
    end
    merge!(env, Dict("PIPEWIREAO_PREFIX" => prefix, "LD_LIBRARY_PATH" => library,
        "PIPEWIREAO_RUNTIME_DIR" => runtime, "PIPEWIRE_RUNTIME_DIR" => runtime,
        "PIPEWIREAO_CONFIG_DIR" => config_directory, "PIPEWIREAO_MODULE_DIR" => modules,
        "PIPEWIREAO_SPA_PLUGIN_DIR" => spa,
        "CUDA_VISIBLE_DEVICES" => "", "ROCR_VISIBLE_DEVICES" => "", "HIP_VISIBLE_DEVICES" => "",
        "OPENBLAS_NUM_THREADS" => "1", "OMP_NUM_THREADS" => "1", "MKL_NUM_THREADS" => "1",
        "JULIA_NUM_THREADS" => "2", "JULIA_DEPOT_PATH" => joinpath(runtime, "julia-depot") * ":" *
            get(ENV, "JULIA_DEPOT_PATH", joinpath(homedir(), ".julia") * ":")))
    return env
end

# The optional installer and ExecStopPost run in different processes. flock
# releases on process death and prevents a late fragment from escaping cleanup.
function with_lifecycle_lock(action, runtime, deadline)
    path = joinpath(runtime,"analysis.lock")
    islink(path) && throw(ArgumentError("optional analysis lock must not be a symlink"))
    open(path,"a+") do io
        stat(io).uid == ccall(:getuid,Cuint,()) ||
            throw(ArgumentError("optional analysis lock belongs to another user"))
        chmod(path,0o600)
        locked = false
        try
            while !locked
                S.monotonic() < deadline || throw(ArgumentError("optional analysis lifecycle lock deadline expired"))
                locked = ccall(:flock,Cint,(Cint,Cint),fd(io),2|4) == 0
                locked && break
                Base.Libc.errno() in (4,11) || throw(SystemError("optional analysis flock",Base.Libc.errno()))
                sleep(min(0.02,max(0,deadline-S.monotonic())))
            end
            return action()
        finally
            locked && ccall(:flock,Cint,(Cint,Cint),fd(io),8)
        end
    end
end

function _same_session(record, unit, deadline)
    values = S.properties(unit; deadline)
    values["ActiveState"] == "active" && values["InvocationID"] == record["invocation"] &&
        tryparse(Int, values["MainPID"]) == record["wireplumber_pid"] ||
        throw(ArgumentError("optional analysis session incarnation is no longer active"))
    return nothing
end

"""Submit optional units after RTC readiness; failures never fail the required RTC."""
function start!(installed, launch_record, session_unit; prefix="/opt/pipewireao",
        deadline=S.monotonic()+20, ready=()->nothing)
    runtime = launch_record["runtime"]
    if ispath(joinpath(runtime, "analysis.json"))
        @warn "Optional analysis start already attempted; preserving its receipt"
        return nothing
    end
    receipt = Dict{String,Any}("invocation" => launch_record["invocation"],
        "unit" => String(session_unit), "unit_files" => Dict{String,Any}(),
        "analysis" => Dict{String,Any}(), "errors" => String[])
    try
        spec = D.profile(joinpath(installed, "deployment.conf"), prefix)
        entries = get(spec, "analysis", [])
        isempty(entries) && return nothing
        save_receipt!(runtime, receipt)
        ready()
        with_lifecycle_lock(runtime,deadline) do
            # Recheck while locked: cleanup may have completed during readiness.
            _same_session(launch_record, session_unit, deadline)
            paths = D.installed_paths(prefix)
            project = D.registered_application(spec) ? D.application_environment(spec, installed) : joinpath(installed, "julia")
            coordinator = S.Coordinator(String(session_unit), launch_record["invocation"], "")
            for entry in entries
                service = S.Service(coordinator, "analysis-" * entry["name"])
                receipt["analysis"][service.role] = Dict{String,Any}("unit" => service.unit, "state" => "installing")
                argv = [realpath(Base.julia_cmd().exec[1]), "--startup-file=no", "--project=" * project,
                    "-e", "using PipeWireAORTC; exit(PipeWireAORTC.Analysis.main(ARGS))", "--",
                    "--config", D.relative_asset(installed, entry["config"]),
                    "--remote", joinpath(runtime, launch_record["remote"])]
                placement = Dict("cpus" => entry["cpus"], "leader-cpu" => first(entry["cpus"]))
                receipt["analysis"][service.role]["placement"] = placement
                directory = joinpath(runtime, service.role)
                mkdir(directory; mode=0o700)
                bindings = Dict("PACKAGE"=>installed, "PREFIX"=>prefix, "RUNTIME"=>runtime,
                    "REMOTE"=>basename(launch_record["remote"]), "INSTANCE"=>launch_record["invocation"])
                client = D.relative_asset(installed, spec["client"]["analysis"])
                write(joinpath(directory, "client.conf"), D.substitute(read(client, String), bindings; quoted=true))
                env = environment(runtime, prefix, paths["library"]; config_directory=directory,
                    modules=paths["modules"], spa=paths["spa"])
                # Requisite never reactivates an RTC that stopped during submission.
                # Readiness and the locked invocation check order startup.
                # An After dependency would reverse on shutdown and let slow
                # optional teardown delay the RTC's control-stop hook.
                text = S.service_unit(service, argv, env, installed, placement;
                    requisite=[session_unit], part_of=[session_unit], ordinary=true)
                S.install_fragment!(service.unit, text, runtime, receipt; save=save_receipt!, deadline)
            end
            result = S.checked(["systemctl", "--user", "daemon-reload"]; deadline)
            result.returncode == 0 || throw(ArgumentError("optional analysis unit reload failed"))
            for (role, item) in receipt["analysis"]
                _same_session(launch_record, session_unit, deadline)
                S.verify_fragment!(item["unit"], receipt; placement=item["placement"], ordinary=true, deadline)
                item["state"] = "submitted"
                save_receipt!(runtime, receipt)
                result = S.checked(["systemctl", "--user", "start", "--no-block", item["unit"]]; deadline)
                result.returncode == 0 || throw(ArgumentError("optional analysis submission failed for $role"))
                values = S.properties(item["unit"]; extra="Result", deadline)
                item["active_state"] = values["ActiveState"]
                item["result"] = values["Result"]
                item["invocation"] = values["InvocationID"]
                item["cgroup"] = values["ControlGroup"]
                main = something(tryparse(Int,values["MainPID"]),0)
                ticks = S.maybe_start_ticks(main)
                if ticks !== nothing && !isempty(values["ControlGroup"]) &&
                        S.process_identity(main,ticks,values["ControlGroup"])
                    item["pid"] = main
                    item["start-ticks"] = ticks
                    item["state"] = "running"
                end
                values["ActiveState"] == "failed" &&
                    @warn "Optional analysis service failed" role result=values["Result"]
                save_receipt!(runtime, receipt)
            end
        end
    catch error
        @warn "Optional analysis startup failed; RTC remains active" exception=(error, catch_backtrace())
        try
            with_lifecycle_lock(runtime,max(deadline,S.monotonic()+1)) do
                path = joinpath(runtime,"analysis.json")
                saved = isfile(path) ? Common.read_json(path;maximum=1024*1024) : receipt
                push!(saved["errors"],sprint(showerror,error))
                save_receipt!(runtime,saved)
            end
        catch receipt_error
            @warn "Optional analysis receipt could not be saved" exception=(receipt_error,catch_backtrace())
        end
    end
    return nothing
end

"""Remove separately retained optional fragments after the invocation sweep is quiet."""
function cleanup_receipt(runtime, launch_record)
    path = joinpath(runtime, "analysis.json")
    isfile(path) || return nothing
    receipt = Common.read_json(path; maximum=1024*1024)
    receipt["invocation"] == launch_record["invocation"] &&
        receipt["unit"] == launch_record["unit"] ||
        throw(ArgumentError("optional analysis receipt belongs to another session"))
    roles = collect(keys(receipt["analysis"]))
    length(roles) <= 8 && all(role -> occursin(r"^analysis-[a-z][a-z0-9-]{0,22}$", role), roles) ||
        throw(ArgumentError("optional analysis receipt contains invalid roles"))
    return receipt
end

function verify_cleanup!(runtime, launch_record, deadline)
    receipt = cleanup_receipt(runtime, launch_record)
    receipt === nothing && return nothing
    for (unit, entry) in receipt["unit_files"]
        unit in (S.PREFIX * receipt["invocation"] * "-" * role * ".service"
            for role in keys(receipt["analysis"])) || throw(ArgumentError("foreign optional analysis unit"))
        path = joinpath(runtime, "units", unit)
        entry["path"] == path && !islink(path) &&
            ((isfile(path) && Common.sha256_file(path) == entry["sha256"]) ||
                (get(receipt,"unit_file_removal_started",false) && !ispath(path))) ||
            throw(ArgumentError("optional analysis fragment changed before cleanup"))
        values = S.properties(unit; extra="FragmentPath,DropInPaths", deadline)
        isempty(values["DropInPaths"]) && (values["LoadState"] == "not-found" ||
            (isfile(values["FragmentPath"]) && realpath(values["FragmentPath"]) == path) ||
            (get(receipt,"unit_file_removal_started",false) && !ispath(path) &&
                values["FragmentPath"] in (path,joinpath(S.runtime_unit_directory(),unit)))) ||
            throw(ArgumentError("optional analysis manager definition changed before cleanup"))
    end
    return nothing
end

function cleanup!(runtime, launch_record, deadline)
    with_lifecycle_lock(runtime,deadline) do
        receipt = cleanup_receipt(runtime, launch_record)
        if receipt === nothing
            units = S.listed_units(launch_record["invocation"];deadline)
            jobs = S.listed_jobs(launch_record["invocation"];deadline)
            prefix = S.PREFIX * launch_record["invocation"] * "-analysis-"
            required = Set(get(owner,"unit","") for owner in Base.values(launch_record["owners"]))
            any(unit -> startswith(unit,prefix) && !(unit in required),union(units,last.(jobs))) &&
                throw(ArgumentError("optional analysis unit or job remains without its retained receipt"))
            return nothing
        end
        verify_cleanup!(runtime,launch_record,deadline)
        files = Set(keys(receipt["unit_files"]))
        # Only the separately retained, exactly verified definitions authorize
        # optional stops; a matching name by itself is insufficient.
        for job in S.listed_jobs(receipt["invocation"];deadline)
            job.second in files && S.cancel_job(job.first;deadline)
        end
        for (role,item) in receipt["analysis"]
            unit = item["unit"]
            unit in files || continue
            values = S.properties(unit;deadline)
            retained_id = get(item,"invocation","")
            isempty(retained_id) || isempty(values["InvocationID"]) ||
                lowercase(values["InvocationID"]) == retained_id ||
                throw(ArgumentError("optional analysis unit incarnation changed before cleanup"))
            if get(item,"pid",0) > 0 && haskey(item,"start-ticks") && !isempty(get(item,"cgroup",""))
                owner = S.Coordinator(receipt["unit"],receipt["invocation"],"")
                service = S.Service(owner,role)
                service.main_pid = item["pid"]
                service.start_ticks = UInt64(item["start-ticks"])
                service.invocation = retained_id
                service.cgroup = item["cgroup"]
                service.state = :running
                S.stop!(service,0)
            else
                S.cleanup_unit(unit;deadline)
            end
        end
        for unit in S.listed_units(receipt["invocation"];deadline)
            startswith(unit,S.PREFIX * receipt["invocation"] * "-analysis-") &&
                !(unit in files) && !(unit in (get(owner,"unit","") for owner in Base.values(launch_record["owners"]))) &&
                throw(ArgumentError("optional analysis unit lacks an exact retained fragment"))
        end
        roles = keys(receipt["analysis"])
        get(receipt, "unit_files_removed", false) ||
            S.remove_fragments!(runtime, receipt, deadline; roles, save=save_receipt!)
        receipt["cleanup_complete"] = true
        save_receipt!(runtime, receipt)
        return nothing
    end
end

end
