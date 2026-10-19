"""Configuration and FITS declarations for an optional native AOS owner."""
module AOSOwner

import ..Artifacts
import ..DeploymentConfiguration
import ..NativeOwnerBootstrapRuntime

public main

const Bootstrap = NativeOwnerBootstrapRuntime
const MAX_RETAINED_BYTES = 512 * 1024 * 1024
const ELEMENT_TYPES = Dict(string(T) => T for T in Artifacts.TARGET_TYPES)

struct FITSBinding
    binding::Symbol
    source::Artifacts.FITSArtifact
    element_type::DataType
    shape::Tuple{Vararg{Int}}
end

function text(value, label)
    value isa String && !isempty(value) && ncodeunits(value) <= 16 * 1024 &&
        !occursin('\0', value) || throw(ArgumentError("$label must be a nonempty string"))
    return value
end
function integer(value, label, lower, upper)
    value isa Integer && !(value isa Bool) && lower <= value <= upper ||
        throw(ArgumentError("$label must be an integer in $lower:$upper"))
    return Int(value)
end
function identifier(value, label)
    name = text(value, label)
    occursin(r"^[a-zA-Z_][a-zA-Z0-9_]*$", name) ||
        throw(ArgumentError("$label must be an identifier"))
    return Symbol(name)
end
function node_name(value, label)
    name = text(value, label)
    occursin(r"^[a-zA-Z0-9_.-]{1,128}$", name) || throw(ArgumentError("invalid $label"))
    return name
end
function boolean(value, label)
    value isa Bool || throw(ArgumentError("$label must be Boolean"))
    return value
end

"Parse the complete native bootstrap invocation without loading science."
function arguments(args)
    values = Dict{String,String}()
    allowed = ("--config", "--remote", "--control-node", "--bootstrap-node", "--bootstrap-instance")
    iseven(length(args)) || throw(ArgumentError("each AOS owner option requires a value"))
    for index in 1:2:length(args)
        key, value = args[index], args[index + 1]
        key in allowed || throw(ArgumentError("unknown AOS owner option $key"))
        haskey(values, key) && throw(ArgumentError("duplicate $key"))
        values[key] = text(value, key)
    end
    all(key -> haskey(values, key), allowed) || throw(ArgumentError(
        "AOS owner requires --config, --remote, --control-node, --bootstrap-node and --bootstrap-instance"))
    remote = values["--remote"]
    isabspath(remote) || throw(ArgumentError("AOS owner requires an absolute private remote"))
    control_node = node_name(values["--control-node"], "control node")
    bootstrap_node = node_name(values["--bootstrap-node"], "bootstrap node")
    control_node != bootstrap_node || throw(ArgumentError("source and bootstrap nodes must differ"))
    instance = tryparse(Int64, values["--bootstrap-instance"])
    instance !== nothing && instance > 0 || throw(ArgumentError("bootstrap instance must be positive"))
    return (; remote, control_node, bootstrap_node, bootstrap_instance=instance,
        config=abspath(values["--config"]))
end

"Validate every configuration declaration before preparing any FITS artifact."
function configuration(path::AbstractString)
    document = DeploymentConfiguration.decode(path, get(ENV, "PIPEWIREAO_PREFIX", "/opt/pipewireao"))
    fields = ("version", "graph", "command_input", "frame_output", "command_count", "frame_shape",
        "rate", "exposure_ns", "wall_rate", "backend", "device", "artifacts", "command_node",
        "frame_schema", "command_schema", "command_scale", "total_exchanges", "optical_observation",
        "detector_observation", "command_observation", "applied_command_observation")
    required = ("version", "graph", "command_input", "frame_output", "command_count", "frame_shape",
        "rate", "exposure_ns", "wall_rate", "backend", "device", "artifacts")
    document isa AbstractDict && all(key -> key in fields, keys(document)) &&
        all(key -> haskey(document, key), required) || throw(ArgumentError("invalid AOS configuration fields"))
    integer(document["version"], "version", 1, 1)
    graph = abspath(joinpath(dirname(abspath(path)), text(document["graph"], "graph")))
    isfile(graph) || throw(ArgumentError("AOS graph does not exist: $graph"))
    command_input = identifier(document["command_input"], "command_input")
    frame_output = identifier(document["frame_output"], "frame_output")
    command_count = integer(document["command_count"], "command_count", 1, Artifacts.MAX_IMAGE_BYTES ÷ sizeof(Float32))
    frame_shape = Artifacts.checked_shape(document["frame_shape"], sizeof(Float32))
    length(frame_shape) == 2 || throw(ArgumentError("AOS frame_shape must have two dimensions"))
    rate = integer(document["rate"], "rate", 1, 1_000_000_000)
    period_ns = UInt64(div(1_000_000_000 + div(rate, 2), rate))
    exposure_ns = UInt64(integer(document["exposure_ns"], "exposure_ns", 1, period_ns))
    wall_rate = integer(document["wall_rate"], "wall_rate", 0, rate)
    wall_period_ns = wall_rate == 0 ? UInt64(0) : UInt64(div(1_000_000_000 + div(wall_rate, 2), wall_rate))
    backend = Symbol(text(document["backend"], "backend"))
    backend in (:cpu, :cuda) || throw(ArgumentError("AOS backend must be cpu or cuda"))
    device = integer(document["device"], "device", 0, typemax(Int32))
    backend == :cpu && device != 0 && throw(ArgumentError("CPU backend requires device 0"))
    command_node = node_name(get(document, "command_node", "simulator-command"), "command node")
    frame_schema = text(get(document, "frame_schema", "org.calculon.ao.raw-detector-pixels/1"), "frame_schema")
    command_schema = text(get(document, "command_schema", "org.calculon.ao.demanded-pdm-command/1"), "command_schema")
    scale = get(document, "command_scale", 1.0f-6)
    scale isa Real && !(scale isa Bool) && isfinite(scale) && 0 < scale <= floatmax(Float32) ||
        throw(ArgumentError("command_scale must be finite and positive"))
    command_scale = Float32(scale)
    command_scale > 0 || throw(ArgumentError("command_scale underflows Float32"))
    total = get(document, "total_exchanges", nothing)
    total_exchanges = total === nothing ? nothing : UInt64(integer(total, "total_exchanges", 1, typemax(Int64)))
    optical_observation = boolean(get(document, "optical_observation", false), "optical_observation")
    detector_observation = boolean(get(document, "detector_observation", false), "detector_observation")
    command_observation = boolean(get(document, "command_observation", false), "command_observation")
    applied_command_observation = boolean(get(document, "applied_command_observation", false), "applied_command_observation")
    entries = document["artifacts"]
    entries isa AbstractVector && length(entries) <= 64 || throw(ArgumentError("artifacts must be an array of at most 64 entries"))
    artifacts = FITSBinding[]
    names = Set([command_input])
    total_bytes = command_count * sizeof(Float32)
    for entry in entries
        entry isa AbstractDict && all(key -> key in ("binding", "path", "hdu", "axes", "type", "shape"), keys(entry)) ||
            throw(ArgumentError("invalid AOS FITS binding fields"))
        binding = identifier(get(entry, "binding", nothing), "artifact binding")
        binding in names && throw(ArgumentError("duplicate or command FITS binding $binding"))
        push!(names, binding)
        T = get(ELEMENT_TYPES, get(entry, "type", nothing), nothing)
        T === nothing && throw(ArgumentError("unsupported AOS FITS type"))
        shape = Artifacts.checked_shape(get(entry, "shape", nothing), sizeof(T))
        axes = get(entry, "axes", nothing)
        length(shape) > 1 && axes === nothing && throw(ArgumentError("multidimensional FITS bindings require axes"))
        source = Artifacts.FITSArtifact(joinpath(dirname(abspath(path)), text(get(entry, "path", nothing), "artifact path"));
            hdu=get(entry, "hdu", 1), axes)
        source.axes === nothing || length(source.axes) == length(shape) ||
            throw(DimensionMismatch("FITS axes and shape ranks differ"))
        total_bytes += prod(shape) * sizeof(T)
        total_bytes <= MAX_RETAINED_BYTES || throw(ArgumentError("retained AOS bindings exceed 512 MiB"))
        push!(artifacts, FITSBinding(binding, source, T, shape))
    end
    return (; graph, command_input, frame_output, command_count, frame_shape, rate, period_ns,
        exposure_ns, wall_rate, wall_period_ns, backend, device, artifacts, command_node,
        frame_schema, command_schema, command_scale, total_exchanges, optical_observation,
        detector_observation, command_observation, applied_command_observation)
end

"Prepare owned logical FITS arrays; preserve their provenance for the science owner."
function prepare_bindings(entries; check=()->nothing)
    prepared = Artifacts.PreparedArtifact[]
    for entry in entries
        check()
        push!(prepared, Artifacts.prepare(entry.source, entry.element_type, entry.shape; check))
    end
    check()
    return prepared
end

function prepare_science end
function run_owner end

function _main(args; with_owner=Bootstrap.with_owner,
        load_science=() -> begin
            Base.require(@__MODULE__, :AdaptiveOpticsSim)
            Base.require(@__MODULE__, :AdaptiveOpticsSimPipeWireHIL)
        end,
        load_cuda=() -> Base.require(@__MODULE__, :CUDA), run=run_owner)
    invocation = arguments(args)
    options = configuration(invocation.config)
    invocation.control_node != options.command_node && invocation.bootstrap_node != options.command_node ||
        throw(ArgumentError("bootstrap, frame and command nodes must differ"))
    with_owner(merge(options, invocation)) do admitted
        admitted.owner_check()
        load_science()
        admitted.owner_check()
        admitted.backend === :cuda && load_cuda()
        admitted.owner_check()
        Base.invokelatest(run, admitted)
    end
    return 0
end

"""
    main(args)

Run a native AOS scientific owner from `--config PATH`, with explicit `--remote`,
`--control-node`, `--bootstrap-node` and `--bootstrap-instance`. The version 1
SPA-JSON configuration declares the simulation TOML graph, command/frame names,
extents, timing, backend/device and FITS bindings. Paths are relative to the
configuration. Preparing is published before optional AOS/HIL/CUDA imports.
FITS preparation is cold startup only; WirePlumber retains lifecycle authority.
"""
main(args) = _main(args)

end
