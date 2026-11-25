"""Optional CPU analysis graphs, independent of required RTC readiness and owners."""
module Analysis
import ..Common
import ..DeploymentConfiguration
import ..ConfigurationStore
import ..Artifacts
import ..PipeWireAORTC

public Config, Endpoint, LinkSpec, configuration, main

include("capture.jl")

const D = DeploymentConfiguration

"""
    Endpoint(node, port)

An exact graph node name and port name used in analysis link declarations.
"""
struct Endpoint
    node::String
    port::String
end
"""
    LinkSpec(output, input)

An output-to-input link between two [`Endpoint`](@ref) values.
"""
struct LinkSpec
    output::Endpoint
    input::Endpoint
end
"""
    Config(graph, name, rate, links, channel_units, capture, fits_bindings)

Resolved optional analysis graph configuration.

`graph` and `fits_bindings`, when present, are absolute paths resolved from the
configuration file. `rate` is the declared positive rate as a reduced rational.
Instances returned by [`configuration`](@ref) have already passed deployment
analysis declaration validation.
"""
struct Config
    graph::String
    name::String
    rate::Rational{Int}
    links::Vector{LinkSpec}
    channel_units::Dict{String,Dict{String,String}}
    capture::Union{Nothing,CaptureConfig}
    fits_bindings::Union{Nothing,String}
end

Config(graph, name, rate, links) =
    Config(graph, name, rate, links, Dict{String,Dict{String,String}}(), nothing)
Config(graph, name, rate, links, units) = Config(graph, name, rate, links, units, nothing)
Config(graph, name, rate, links, units, capture) =
    Config(graph, name, rate, links, units, capture, nothing)

channel_units(value) =
    throw(ArgumentError("analysis channel-units must map at most 64 output Ports"))
function channel_units(value::AbstractDict)
    length(value) <= 64 ||
        throw(ArgumentError("analysis channel-units must map at most 64 output Ports"))
    result = Dict{String,Dict{String,String}}()
    bytes = 0
    text = channel_unit_text
    for (port, channels) in value
        text(port) || throw(ArgumentError("invalid analysis channel-units Port"))
        channel_unit_channels(channels)
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
    bytes <= 16384 ||
        throw(ArgumentError("analysis channel-units exceeds 16384 UTF-8 bytes"))
    return result
end

endpoint(value) =
    throw(ArgumentError("analysis endpoint must be a bounded node:port string"))
function endpoint(value::String)
    ncodeunits(value) <= 257 ||
        throw(ArgumentError("analysis endpoint must be a bounded node:port string"))
    terms = split(value, ':'; keepempty = true)
    length(terms) == 2 && all(term -> occursin(r"^[A-Za-z0-9_.-]{1,128}$", term), terms) ||
        throw(ArgumentError("analysis endpoint must name one exact node and port"))
    return Endpoint(String(terms[1]), String(terms[2]))
end

"""
    configuration(path, prefix)

Read and validate an optional analysis configuration and its referenced assets.
`prefix` selects the PipeWireAO native installation used to decode native
configuration. Returns a [`Config`](@ref); paths are resolved relative to
`path`. This validates the configuration only and does not start the graph.
"""
function configuration(path::AbstractString, prefix::AbstractString)
    return configuration(path, prefix, D.decode(path, prefix))
end
configuration(path, prefix, document) = throw(
    ArgumentError(
        "analysis requires graph, name, rate and links; channel-units, capture and fits-bindings are optional",
    ),
)
function configuration(path, prefix, document::AbstractDict)
    required = Set(["graph", "name", "rate", "links"])
    required ⊆ Set(keys(document)) &&
    Set(keys(document)) ⊆
    union(required, Set(["channel-units", "capture", "fits-bindings"])) || throw(
        ArgumentError(
            "analysis requires graph, name, rate and links; channel-units, capture and fits-bindings are optional",
        ),
    )
    graph = D.relative_asset(dirname(abspath(path)), document["graph"])
    name = document["name"]
    analysis_name(name)
    rate = document["rate"]
    analysis_rate(rate)
    numerator, denominator = parse.(Int, split(rate, '/'))
    entries = document["links"]
    analysis_links(entries)
    links = LinkSpec[]
    addresses = Set{Tuple{String,String}}()
    for entry in entries
        analysis_link(entry)
        output, input = endpoint(entry["output"]), endpoint(entry["input"])
        xor(output.node == name, input.node == name) || throw(
            ArgumentError("each analysis link must touch the analysis node exactly once"),
        )
        address = (entry["output"], entry["input"])
        address in addresses && throw(ArgumentError("duplicate analysis link"))
        push!(addresses, address)
        push!(links, LinkSpec(output, input))
    end
    units = channel_units(get(document, "channel-units", Dict()))
    capture =
        haskey(document, "capture") ?
        capture_contract(
            capture_configuration(document["capture"]), D.decode(graph, prefix)
        ) : nothing
    fits =
        haskey(document, "fits-bindings") ?
        D.relative_asset(dirname(abspath(path)), document["fits-bindings"]) : nothing
    fits === nothing || PipeWireAORTC.GraphOwner.bindings(fits) # Validate typed declarations before launch.
    return Config(graph, name, numerator // denominator, links, units, capture, fits)
end

function observation_queues(spec, root, prefix)
    core = D.decode(D.relative_asset(root, spec["core"]), prefix)
    sources, sinks = Set{String}(), Set{String}()
    playback_by_capture = Dict{String,String}()
    for declaration in get(core, "context.modules", [])
        observation_queue!(sources, sinks, playback_by_capture, declaration)
    end
    return sources, sinks, playback_by_capture
end

function validate_deployment(spec, path, prefix)
    entries = get(spec, "analysis", [])
    deployment_analysis_entries(entries)
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
    session = D.decode(D.relative_asset(root, spec["session"]), prefix)
    required_inputs, required_outputs = Set{String}(), Set{String}()
    for link in get(session, "links", [])
        push!(required_inputs, endpoint(link["input"]).node)
        push!(required_outputs, endpoint(link["output"]).node)
    end
    client = get(get(spec, "client", Dict()), "analysis", nothing)
    analysis_client(client, artifacts)
    client_config = D.decode(D.relative_asset(root, client), prefix)
    for declaration in get(client_config, "context.modules", [])
        validate_analysis_client_module(declaration)
    end
    for loop in
        get(get(client_config, "context.properties", Dict()), "context.data-loops", [])
        get(loop, "loop.rt-prio", 0) in (0, "0") ||
            D.fail("analysis client loops must use ordinary scheduling")
    end
    for entry in entries
        deployment_analysis_entry(entry)
        name = entry["name"]
        analysis_service_name(name, names)
        ("analysis-" * name) in keys(spec["placement"]) &&
            D.fail("analysis service role conflicts with a required owner")
        push!(names, name)
        cpus = entry["cpus"]
        analysis_cpus(cpus, occupied)
        source = D.relative_asset(root, entry["config"])
        haskey(artifacts, entry["config"]) ||
            D.fail("analysis configuration must be sealed")
        config = configuration(source, prefix)
        relative_graph = relpath(config.graph, root)
        haskey(artifacts, relative_graph) || D.fail("analysis graph must be sealed")
        if config.fits_bindings !== nothing
            haskey(artifacts, relpath(config.fits_bindings, root)) ||
                D.fail("analysis FITS bindings must be sealed")
            for binding in PipeWireAORTC.GraphOwner.bindings(config.fits_bindings)
                relative = relpath(binding.source.path, root)
                D.relative_asset(root, relative)
                haskey(artifacts, relative) ||
                    D.fail("analysis FITS artifact must be sealed")
            end
        end
        !(
            config.name in nodes ||
            config.name in application_nodes ||
            config.name in sources ||
            config.name in sinks
        ) || D.fail("analysis graph node name conflicts with another declared node")
        push!(nodes, config.name)
        for link in config.links
            if link.input.node == config.name
                link.output.node in sources &&
                !(link.output.node in application_nodes) &&
                !(link.output.node in required_outputs) || D.fail(
                    "analysis input must use a declared capacity-one copy/drop-oldest queue playback",
                )
            else
                link.input.node in sinks &&
                !(link.input.node in required_inputs) &&
                !(playback_by_capture[link.input.node] in required_outputs) || D.fail(
                    "analysis output requires an exclusive observation queue capture with no required playback consumers",
                )
                link.input.node in output_captures &&
                    D.fail("analysis outputs must not share a queue capture")
                push!(output_captures, link.input.node)
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
function prepare_graph end

"""
    main(args=ARGS)

Run one optional analysis graph using `--config PATH --remote ABSOLUTE_SOCKET`.
The native prefix comes from `PIPEWIREAO_PREFIX` or defaults to
`/opt/pipewireao`. Returns exit code `0` after graph execution completes;
invalid arguments, configuration errors, or graph failures throw.
"""
function main(args = ARGS)
    path, remote = arguments(args)
    config = configuration(path, get(ENV, "PIPEWIREAO_PREFIX", "/opt/pipewireao"))
    for name in (:FilterGraphPipeWire, :FilterGraphs)
        Base.require(Main, name)
    end
    Base.invokelatest(run_graph, config, remote)
    return 0
end

channel_unit_text(value::String) =
    isvalid(value) &&
    !isempty(strip(value)) &&
    ncodeunits(value) <= 255 &&
    !any(iscntrl, value)
channel_unit_text(value) = false

channel_unit_channels(value) = throw(
    ArgumentError("analysis channel-units must map at most 64 channel names per Port")
)
function channel_unit_channels(value::AbstractDict)
    length(value) <= 64 || return channel_unit_channels(nothing)
    return value
end

analysis_name(value) =
    throw(ArgumentError("analysis name must be a bounded public node name"))
function analysis_name(value::String)
    occursin(r"^[A-Za-z0-9_.-]{1,128}$", value) || return analysis_name(nothing)
    return value
end

analysis_rate(value) =
    throw(ArgumentError("analysis rate must be a positive bounded numerator/denominator"))
function analysis_rate(value::String)
    occursin(r"^[1-9][0-9]{0,8}/[1-9][0-9]{0,8}$", value) || return analysis_rate(nothing)
    return value
end

analysis_links(value) =
    throw(ArgumentError("analysis links must be a list of at most 64 links"))
function analysis_links(value::AbstractVector)
    length(value) <= 64 || return analysis_links(nothing)
    return value
end

analysis_link(value) = throw(ArgumentError("analysis link requires only output and input"))
function analysis_link(value::AbstractDict)
    Set(keys(value)) == Set(["output", "input"]) || return analysis_link(nothing)
    return value
end

observation_queue!(sources, sinks, playback_by_capture, declaration) = nothing
function observation_queue!(sources, sinks, playback_by_capture, declaration::AbstractDict)
    get(declaration, "name", nothing) == "libpipewire-module-queue" || return nothing
    observation_queue_args!(
        sources, sinks, playback_by_capture, get(declaration, "args", nothing)
    )
end
observation_queue_args!(sources, sinks, playback_by_capture, args) = nothing
function observation_queue_args!(sources, sinks, playback_by_capture, args::AbstractDict)
    capture, playback = get(args, "capture.props", nothing),
    get(args, "playback.props", nothing)
    return observation_queue_props!(
        sources, sinks, playback_by_capture, args, capture, playback
    )
end
observation_queue_props!(sources, sinks, playback_by_capture, args, capture, playback) =
    nothing
function observation_queue_props!(
    sources, sinks, playback_by_capture, args, capture::AbstractDict, playback::AbstractDict
)
    # Queue policy belongs to module arguments; endpoint properties cannot turn retention into copying.
    maximum = get(args, "queue.max-buffers", nothing)
    get(args, "queue.storage", nothing) == "copy" &&
    get(args, "queue.overflow", nothing) == "drop-oldest" &&
    ((typeof(maximum) === Int && maximum == 1) || maximum == "1") || return nothing
    all((capture, playback)) do props
        maximum = get(props, "queue.max-buffers", get(args, "queue.max-buffers", nothing))
        get(props, "queue.storage", get(args, "queue.storage", nothing)) == "copy" &&
            get(props, "queue.overflow", get(args, "queue.overflow", nothing)) ==
            "drop-oldest" &&
            observation_queue_capacity(maximum)
    end || return nothing
    return observation_queue_nodes!(
        sources,
        sinks,
        playback_by_capture,
        get(playback, "node.name", nothing),
        get(capture, "node.name", nothing),
    )
end
observation_queue_capacity(value::Int) = value == 1
observation_queue_capacity(value::String) = value == "1"
observation_queue_capacity(value) = false
observation_queue_nodes!(sources, sinks, playback_by_capture, source, sink) = nothing
function observation_queue_nodes!(
    sources, sinks, playback_by_capture, source::String, sink::String
)
    source in sources || sink in sinks ?
    D.fail("ambiguous analysis observation queue node") : nothing
    push!(sources, source)
    push!(sinks, sink)
    playback_by_capture[sink] = source
    return nothing
end


deployment_analysis_entries(value) =
    D.fail("deployment analysis must be a list of at most eight entries")
function deployment_analysis_entries(value::AbstractVector)
    length(value) <= 8 || return deployment_analysis_entries(nothing)
    return value
end

analysis_client(value, artifacts) =
    D.fail("analysis requires a sealed client.analysis configuration")
function analysis_client(value::String, artifacts)
    haskey(artifacts, value) || return analysis_client(nothing, artifacts)
    return value
end

validate_analysis_client_module(declaration) = nothing
function validate_analysis_client_module(declaration::AbstractDict)
    get(declaration, "name", nothing) == "libpipewire-module-rt" &&
        D.fail("analysis client must not load the realtime module")
    return nothing
end

deployment_analysis_entry(value) =
    D.fail("analysis entry requires only name, config and cpus")
function deployment_analysis_entry(value::AbstractDict)
    Set(keys(value)) == Set(["name", "config", "cpus"]) ||
        return deployment_analysis_entry(nothing)
    return value
end

analysis_service_name(value, names) =
    D.fail("analysis name must be unique and fit its analysis- service role")
function analysis_service_name(value::String, names)
    occursin(r"^[a-z][a-z0-9-]{0,22}$", value) && !(value in names) ||
        return analysis_service_name(nothing, names)
    return value
end

analysis_cpus(value, occupied) =
    D.fail("analysis CPUs must be unique, exclude CPUs 0/1 and required process envelopes")
function analysis_cpus(value::AbstractVector, occupied)
    1 <= length(value) <= 128 &&
    all(cpu -> typeof(cpu) === Int && cpu >= 2, value) &&
    length(unique(value)) == length(value) &&
    isempty(intersect(occupied, value)) || return analysis_cpus(nothing, occupied)
    return value
end

end
