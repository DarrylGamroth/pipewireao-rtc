"""Native bootstrap entry point for optional Julia Filter Graph owners."""
module GraphOwner

import ..Artifacts
import ..DeploymentConfiguration
import ..NativeOwnerBootstrapRuntime
import ..CorrectionLoops
import ..CorrectionSupervision
import ..Common
import ..Schemas

public main, read_bindings

const Bootstrap = NativeOwnerBootstrapRuntime
const MAX_RETAINED_BYTES = 512 * 1024 * 1024

include("graph_supervision.jl")

"""Extract RTC bootstrap, correction and FITS settings; preserve graph arguments."""
function arguments(arguments)
    values = Dict{String,String}()
    graph = String[]
    correction_properties = String[]
    recovery_nodes = String[]
    forbidden = ("--prepared-event", "--connect-request", "--connect-reply", "--quit-request",
        "--control-request", "--control-reply", "--check")
    index = 1
    while index <= length(arguments)
        argument = arguments[index]
        terms = split(argument, '='; limit=2)
        key = first(terms)
        key in forbidden && throw(ArgumentError("native graph owner forbids $key"))
        if key in ("--bootstrap-node", "--bootstrap-instance", "--remote", "--fits-bindings", "--correction-property", "--correction-timeout-ms", "--recovery-node", "--supervision")
            key in ("--correction-property", "--recovery-node") || !haskey(values, key) || throw(ArgumentError("duplicate $key"))
            value = if length(terms) == 2
                terms[2]
            else
                index < length(arguments) || throw(ArgumentError("$key requires a value"))
                index += 1
                arguments[index]
            end
            isempty(value) && throw(ArgumentError("$key must not be empty"))
            if key == "--recovery-node"
                occursin(r"^[a-zA-Z0-9_.-]{1,128}$", value) ||
                    throw(ArgumentError("invalid recovery node name"))
                value in recovery_nodes && throw(ArgumentError("duplicate recovery node $value"))
                push!(recovery_nodes, value)
            elseif key == "--correction-property"
                terms = split(value, ':'; keepempty=true)
                length(terms) == 2 && all(!isempty, terms) && !occursin('\0', value) ||
                    throw(ArgumentError("correction property requires NODE:PROPERTY"))
                value in correction_properties && throw(ArgumentError("duplicate correction property $value"))
                push!(correction_properties, value)
            else
                values[key] = value
                key == "--remote" && append!(graph, [key, value])
            end
        else
            push!(graph, argument)
        end
        index += 1
    end
    all(key -> haskey(values, key), ("--bootstrap-node", "--bootstrap-instance", "--remote")) ||
        throw(ArgumentError("native graph owner requires explicit --bootstrap-node, --bootstrap-instance and --remote"))
    remote = values["--remote"]
    isabspath(remote) || throw(ArgumentError("native graph owner requires an absolute private remote"))
    node = values["--bootstrap-node"]
    occursin(r"^[a-zA-Z0-9_.-]{1,128}$", node) || throw(ArgumentError("invalid bootstrap node name"))
    instance = tryparse(Int64, values["--bootstrap-instance"])
    instance !== nothing && instance > 0 || throw(ArgumentError("invalid bootstrap instance"))
    bindings = get(values, "--fits-bindings", nothing)
    timeout_ms = tryparse(Int, get(values, "--correction-timeout-ms", "5000"))
    timeout_ms !== nothing && 1 <= timeout_ms <= 60000 ||
        throw(ArgumentError("correction timeout must be 1–60000 milliseconds"))
    haskey(values, "--correction-timeout-ms") && isempty(correction_properties) &&
        throw(ArgumentError("correction timeout requires a declared correction property"))
    if !isempty(recovery_nodes)
        length(correction_properties) == 1 && endswith(only(correction_properties), ":closed") ||
            throw(ArgumentError("recovery requires one declared NODE:closed correction property"))
        first(split(only(correction_properties), ':')) in recovery_nodes &&
            throw(ArgumentError("recovery controller is implicit; declare only participant nodes"))
    end
    supervision = get(values, "--supervision", nothing)
    supervision === nothing || length(correction_properties) == 1 ||
        throw(ArgumentError("supervision requires one declared correction property"))
    return (; remote, bootstrap_node=node, bootstrap_instance=instance), graph, bindings, correction_properties, timeout_ms, recovery_nodes, supervision
end

struct FITSBinding
    port::Symbol
    source::Artifacts.FITSArtifact
end

function bindings(path::AbstractString)
    document = DeploymentConfiguration.decode(path, get(ENV, "PIPEWIREAO_PREFIX", "/opt/pipewireao"))
    return bindings(path,document)
end

function bindings(path::AbstractString,document)
    document isa AbstractDict && Set(keys(document)) == Set(["parameters"]) ||
        throw(ArgumentError("FITS bindings require only a parameters array"))
    entries = document["parameters"]
    entries isa AbstractVector || throw(ArgumentError("FITS parameters must be an array"))
    result = FITSBinding[]
    ports = Set{Symbol}()
    for entry in entries
        entry isa AbstractDict && all(key -> key in ("port", "path", "hdu", "axes"), keys(entry)) ||
            throw(ArgumentError("invalid FITS binding fields"))
        for key in ("port", "path")
            value = get(entry, key, nothing)
            value isa String && !isempty(value) && !occursin('\0', value) ||
                throw(ArgumentError("FITS binding requires nonempty $key"))
        end
        port = Symbol(entry["port"])
        port in ports && throw(ArgumentError("duplicate FITS parameter $port"))
        push!(ports, port)
        axes = get(entry, "axes", nothing)
        source = Artifacts.FITSArtifact(joinpath(dirname(abspath(path)), entry["path"]);
            hdu=get(entry, "hdu", 1), axes)
        push!(result, FITSBinding(port, source))
    end
    return result
end

"""Validate every declaration before reading FITS, then retain owned logical arrays."""
function prepare_bindings(entries, formats; check=()->nothing)
    total = 0
    ports = Set{Symbol}()
    for entry in entries
        check()
        entry.port in ports && throw(ArgumentError("duplicate FITS parameter $(entry.port)"))
        push!(ports, entry.port)
        haskey(formats, entry.port) || throw(ArgumentError("Graph has no external Parameter Port '$(entry.port)'"))
        format = getproperty(formats, entry.port)
        T = format.element_type
        T in Artifacts.TARGET_TYPES || throw(ArgumentError("unsupported FITS parameter type: $T"))
        shape = Artifacts.checked_shape(format.shape, sizeof(T))
        length(shape) > 1 && entry.source.axes === nothing &&
            throw(ArgumentError("multidimensional FITS binding requires axes"))
        entry.source.axes === nothing || length(entry.source.axes) == length(shape) ||
            throw(DimensionMismatch("FITS binding axes and graph parameter ranks differ"))
        total += prod(shape) * sizeof(T)
        total <= MAX_RETAINED_BYTES || throw(ArgumentError("retained FITS parameters exceed 512 MiB"))
    end
    prepared = Artifacts.PreparedArtifact[]
    for entry in entries
        check()
        format = getproperty(formats, entry.port)
        push!(prepared, Artifacts.prepare(entry.source, format.element_type, format.shape; check))
    end
    check()
    return [entry.port => artifact.data for (entry, artifact) in zip(entries, prepared)]
end

function run_owner end

"""Read FITS startup arrays against a graph's typed parameter formats (optional JFG extension)."""
function read_bindings end

function _main(args; with_owner=Bootstrap.with_owner,
        load_science=() -> Base.require(Main, :FilterGraphIsland), run=run_owner)
    binding, graph_arguments, fits_path, correction_properties, correction_timeout_ms, recovery_nodes, supervision_path = arguments(args)
    with_owner(binding) do admitted
        admitted.owner_check()
        island = load_science()
        admitted.owner_check()
        options = merge(Base.invokelatest(island.parse_arguments, graph_arguments),
            (; correction_properties, correction_timeout_ms, recovery_nodes,
                supervision=supervision_path === nothing ? () : read_supervision(supervision_path)))
        entries = fits_path === nothing ? FITSBinding[] : bindings(fits_path)
        admitted.owner_check()
        Base.invokelatest(run, island, options, admitted.bootstrap_runtime, entries)
    end
    return 0
end

"""
    main(args)

Run a package-owned JFG scientific process. Publish bootstrap Preparing before
loading FilterGraphIsland. Required bootstrap flags are `--bootstrap-node`,
`--bootstrap-instance`, and absolute `--remote`; other graph flags are forwarded.
`--fits-bindings PATH` selects a native SPA-JSON document with `parameters` entries
containing `port`, `path`, optional one-based `hdu` and FITS `axes`. The graph's
typed Parameter Ports define element types and shapes. Paths resolve relative to
the manifest. Multidimensional images require explicit
axes. FITS startup does not change legacy raw `--parameter` file semantics.
`--correction-property NODE:PROPERTY` declares a Boolean correction-loop property
for RTC-owned adoption tracking; repeat it for independent declared loops.
This does not change startup closure, lifecycle, or the scientific controller.
`--recovery-node NODE` opts the single declared coupled loop into scoped CPU
recovery; repeat it for every participating temporal filter and conditioner.
The controller is implicit. Recovery refuses unsupported scopes before effects;
reference evidence expires using `--correction-timeout-ms`. No supervisor
threshold or automatic intervention is enabled by these declarations.
`--supervision PATH` selects bounded YAML command-constraint monitoring. Its
explicit thresholds apply to successful complete frames; sizes come from the
typed graph outputs. Monitor-only is the default and never changes closure.
`--correction-timeout-ms N` bounds adoption confirmation for declared loops
(1–60000 ms, default 5000). Expiry reports Unknown without a control retry.
"""
main(args) = _main(args)

end
