"""Native bootstrap entry point for optional Julia Filter Graph owners."""
module GraphOwner

import ..Artifacts
import ..DeploymentConfiguration
import ..OwnerBootstrapRuntime
import ..CorrectionLoops
import ..CorrectionSupervision
import ..Common
import ..Schemas

public main, read_bindings, bindings, FITSBinding

const Bootstrap = OwnerBootstrapRuntime
const MAX_RETAINED_BYTES = 512 * 1024 * 1024

include("supervision.jl")

function read_chopped_warmup(path)
    filesize(path) <= 16 * 1024 || throw(ArgumentError("chopped warmup exceeds 16 KiB"))
    return chopped_warmup(Common.read_yaml(path))
end
chopped_warmup(value) = throw(
    ArgumentError(
        "chopped warmup requires version, input, exposure_duration_ns and trigger_high_is_fringed",
    ),
)
function chopped_warmup(value::AbstractDict)
    Set(keys(value)) ==
    Set(("version", "input", "exposure_duration_ns", "trigger_high_is_fringed")) || throw(
        ArgumentError(
            "chopped warmup requires version, input, exposure_duration_ns and trigger_high_is_fringed",
        ),
    )
    value["version"] === 1 || throw(ArgumentError("unsupported chopped warmup version"))
    input = value["input"]
    warmup_input(input)
    duration = value["exposure_duration_ns"]
    warmup_duration(duration) || throw(
        ArgumentError(
            "chopped warmup exposure duration must be positive Int64 nanoseconds"
        ),
    )
    warmup_polarity(value["trigger_high_is_fringed"])
    return (;
        input = Symbol(input),
        exposure_duration_ns = Int64(duration),
        trigger_high_is_fringed = value["trigger_high_is_fringed"],
    )
end

"""Extract RTC bootstrap, correction and FITS settings; preserve graph arguments."""
function arguments(arguments)
    values = Dict{String,String}()
    graph = String[]
    correction_properties = String[]
    recovery_nodes = String[]
    priming_outputs = String[]
    local_output = nothing
    display_sink = nothing
    qualify_at_install = false
    forbidden = (
        "--prepared-event",
        "--connect-request",
        "--connect-reply",
        "--quit-request",
        "--control-request",
        "--control-reply",
        "--check",
    )
    index = 1
    while index <= length(arguments)
        argument = arguments[index]
        terms = split(argument, '='; limit = 2)
        key = first(terms)
        key in forbidden && throw(ArgumentError("native graph owner forbids $key"))
        if key == "--qualify-at-install"
            length(terms) == 1 && !qualify_at_install ||
                throw(ArgumentError("$key is a single flag without a value"))
            qualify_at_install = true
        elseif key in ("--latest-output", "--unpublished-output", "--latest-output-sink")
            count = key == "--latest-output" ? 3 : key == "--latest-output-sink" ? 2 : 1
            length(terms) == 1 && index + count <= length(arguments) || throw(
                ArgumentError("$key requires $count separate arguments"),
            )
            fields = arguments[(index + 1):(index + count)]
            all(field -> occursin(r"^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}$", field), fields) ||
                throw(ArgumentError("invalid $key identifier"))
            if key == "--latest-output-sink"
                display_sink === nothing || throw(ArgumentError("duplicate $key"))
                display_sink = (; node = String(fields[1]), port = String(fields[2]))
            else
                local_output === nothing || throw(ArgumentError("only one local output may be declared"))
                port = Symbol(first(fields))
                local_output = count == 1 ? (; port, node = nothing, media = nothing) :
                    (; port, node = String(fields[2]), media = String(fields[3]))
            end
            index += count
        elseif key in (
            "--bootstrap-node",
            "--bootstrap-instance",
            "--remote",
            "--fits-bindings",
            "--correction-property",
            "--correction-timeout-ms",
            "--recovery-node",
            "--supervision",
            "--physical-offsets",
            "--chopped-warmup",
            "--reference-clock",
            "--prime-on-output",
        )
            key in ("--correction-property", "--recovery-node", "--prime-on-output") ||
                !haskey(values, key) ||
                throw(ArgumentError("duplicate $key"))
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
                value in recovery_nodes &&
                    throw(ArgumentError("duplicate recovery node $value"))
                push!(recovery_nodes, value)
            elseif key == "--correction-property"
                terms = split(value, ':'; keepempty = true)
                length(terms) == 2 && all(!isempty, terms) && !occursin('\0', value) ||
                    throw(ArgumentError("correction property requires NODE:PROPERTY"))
                value in correction_properties &&
                    throw(ArgumentError("duplicate correction property $value"))
                push!(correction_properties, value)
            elseif key == "--prime-on-output"
                push!(priming_outputs, value)
            else
                values[key] = value
                key == "--remote" && append!(graph, [key, value])
            end
        else
            push!(graph, argument)
        end
        index += 1
    end
    all(
        key -> haskey(values, key), ("--bootstrap-node", "--bootstrap-instance", "--remote")
    ) || throw(
        ArgumentError(
            "native graph owner requires explicit --bootstrap-node, --bootstrap-instance and --remote",
        ),
    )
    remote = values["--remote"]
    isabspath(remote) ||
        throw(ArgumentError("native graph owner requires an absolute private remote"))
    node = values["--bootstrap-node"]
    occursin(r"^[a-zA-Z0-9_.-]{1,128}$", node) ||
        throw(ArgumentError("invalid bootstrap node name"))
    instance = tryparse(Int64, values["--bootstrap-instance"])
    instance !== nothing && instance > 0 ||
        throw(ArgumentError("invalid bootstrap instance"))
    bindings = get(values, "--fits-bindings", nothing)
    timeout_ms = tryparse(Int, get(values, "--correction-timeout-ms", "5000"))
    timeout_ms !== nothing && 1 <= timeout_ms <= 60000 ||
        throw(ArgumentError("correction timeout must be 1–60000 milliseconds"))
    haskey(values, "--correction-timeout-ms") &&
        isempty(correction_properties) &&
        throw(ArgumentError("correction timeout requires a declared correction property"))
    if !isempty(recovery_nodes)
        1 <= length(correction_properties) <= 16 &&
        all(endswith(":closed"), correction_properties) || throw(
            ArgumentError(
                "recovery requires 1:16 declared NODE:closed correction properties"
            ),
        )
        any(
            property -> first(split(property, ':')) in recovery_nodes, correction_properties
        ) && throw(
            ArgumentError(
                "recovery controller is implicit; declare only participant nodes"
            ),
        )
    end
    supervision = get(values, "--supervision", nothing)
    supervision === nothing ||
        length(correction_properties) == 1 ||
        throw(ArgumentError("supervision requires one declared correction property"))
    prime_on_output = priming_properties(priming_outputs, correction_properties)
    display_sink === nothing || (local_output !== nothing && local_output.node !== nothing) ||
        throw(ArgumentError("--latest-output-sink requires --latest-output"))
    local_output === nothing || (local_output = merge(local_output, (; sink = display_sink)))
    clock_policy =
        haskey(values, "--reference-clock") ?
        (;
            reference_clock = Common.reference_clock_configuration(
                values["--reference-clock"]
            )
        ) : (;)
    return (;
        remote, bootstrap_node = node, bootstrap_instance = instance, clock_policy...,
        (prime_on_output === nothing ? (;) : (; prime_on_output))...,
    ),
    graph,
    bindings,
    correction_properties,
    timeout_ms,
    recovery_nodes,
    supervision,
    get(values, "--physical-offsets", nothing),
    (; path = get(values, "--chopped-warmup", nothing), at_install = qualify_at_install),
    local_output
end

function priming_properties(outputs, correction_properties)
    isempty(outputs) && return nothing
    length(outputs) == length(correction_properties) &&
        all(endswith(":closed"), correction_properties) ||
        throw(ArgumentError("--prime-on-output requires one output for each declared NODE:closed"))
    selected = Pair{String,Union{Symbol,Tuple{Symbol,Symbol}}}[]
    for value in outputs
        terms = split(value, '='; limit = 2)
        ports = split(last(terms), ','; limit = 2)
        all(port -> occursin(r"^[a-zA-Z0-9_.-]{1,128}$", port), ports) ||
            throw(ArgumentError("--prime-on-output requires a Graph output name"))
        output = length(ports) == 1 ? Symbol(only(ports)) : Tuple(Symbol.(ports))
        if length(terms) == 1
            length(outputs) == 1 || throw(ArgumentError("use NODE:closed=PORT for multiple corrections"))
            return output isa Symbol ? output : (only(correction_properties) => output,)
        end
        property = first(terms)
        property in correction_properties && !any(pair -> first(pair) == property, selected) ||
            throw(ArgumentError("--prime-on-output requires a unique declared NODE:closed"))
        push!(selected, String(property) => output)
    end
    return Tuple(selected)
end

"""
    FITSBinding(port, source)

Associate a graph Parameter Port with its FITS artifact declaration.
"""
struct FITSBinding
    port::Symbol
    source::Artifacts.FITSArtifact
end

"""
    bindings(path)
    bindings(path, document)

Read declared FITS Parameter Port bindings without loading image data.
When `document` is supplied, resolve its relative paths beside `path`.
"""
function bindings(path::AbstractString)
    document = DeploymentConfiguration.decode(
        path, get(ENV, "PIPEWIREAO_PREFIX", "/opt/pipewireao")
    )
    return bindings(path, document)
end

bindings(path::AbstractString, document) =
    throw(ArgumentError("FITS bindings require only a parameters array"))
function bindings(path::AbstractString, document::AbstractDict)
    Set(keys(document)) == Set(["parameters"]) ||
        throw(ArgumentError("FITS bindings require only a parameters array"))
    entries = document["parameters"]
    entries = binding_entries(entries)
    result = FITSBinding[]
    ports = Set{Symbol}()
    for entry in entries
        binding_entry(entry)
        for key in ("port", "path")
            value = get(entry, key, nothing)
            binding_text(value, key)
        end
        port = Symbol(entry["port"])
        port in ports && throw(ArgumentError("duplicate FITS parameter $port"))
        push!(ports, port)
        axes = get(entry, "axes", nothing)
        source = Artifacts.FITSArtifact(
            joinpath(dirname(abspath(path)), entry["path"]);
            hdu = get(entry, "hdu", 1),
            axes,
        )
        push!(result, FITSBinding(port, source))
    end
    return result
end

"""Validate every declaration before reading FITS; retain arrays and their snapshot provenance."""
function prepare_artifacts(entries, formats; check = () -> nothing)
    total = 0
    ports = Set{Symbol}()
    for entry in entries
        check()
        entry.port in ports &&
            throw(ArgumentError("duplicate FITS parameter $(entry.port)"))
        push!(ports, entry.port)
        haskey(formats, entry.port) ||
            throw(ArgumentError("Graph has no external Parameter Port '$(entry.port)'"))
        format = getproperty(formats, entry.port)
        T = format.element_type
        T in Artifacts.TARGET_TYPES ||
            throw(ArgumentError("unsupported FITS parameter type: $T"))
        shape = Artifacts.checked_shape(format.shape, sizeof(T))
        length(shape) > 1 &&
            entry.source.axes === nothing &&
            throw(ArgumentError("multidimensional FITS binding requires axes"))
        entry.source.axes === nothing ||
            length(entry.source.axes) == length(shape) ||
            throw(DimensionMismatch("FITS binding axes and graph parameter ranks differ"))
        total += prod(shape) * sizeof(T)
        total <= MAX_RETAINED_BYTES ||
            throw(ArgumentError("retained FITS parameters exceed 512 MiB"))
    end
    prepared = Artifacts.PreparedArtifact[]
    for entry in entries
        check()
        format = getproperty(formats, entry.port)
        push!(
            prepared,
            Artifacts.prepare(entry.source, format.element_type, format.shape; check),
        )
    end
    check()
    return [entry.port => artifact for (entry, artifact) in zip(entries, prepared)]
end

function prepare_bindings(entries, formats; check = () -> nothing)
    return [
        port => artifact.data for
        (port, artifact) in prepare_artifacts(entries, formats; check)
    ]
end

function precompile_graph_warmup end

function run_owner end

"Return RTC metadata profiles for the optional graph integration's public data ports."
function metadata_profiles end

"""
    read_bindings(graph_path, binding_path)

Read FITS startup arrays against a graph's typed parameter formats (optional graph
extension).
"""
function read_bindings end

supports_offline_qualification(options) =
    options.capture_backend === nothing && options.execution == "complete-frame" &&
    options.row_workers == 0 && options.physical_offsets === nothing

function graph_options(fgp, graph_arguments, correction_properties, timeout_ms,
                       recovery_nodes, supervision_path, offsets_path, qualification,
                       local_output = nothing; offline = false, prime_on_output = nothing)
    options = merge(
        Base.invokelatest(fgp.parse_arguments, graph_arguments),
        (;
            correction_properties,
            correction_timeout_ms = timeout_ms,
            recovery_nodes,
            physical_offsets = offsets_path,
            supervision = supervision_path === nothing ? () :
                          read_supervision(supervision_path),
            qualify_at_install = qualification.at_install,
            prime_on_output,
            chopped_warmup = offline && qualification.path !== nothing ?
                             read_chopped_warmup(qualification.path) : nothing,
            local_output,
        ),
    )
    if qualification.at_install && !supports_offline_qualification(options)
        throw(ArgumentError(
            "install qualification requires a complete-frame CPU graph without row workers or an offset receiver",
        ))
    end
    if prime_on_output !== nothing &&
            (options.capture_backend !== nothing || options.execution != "complete-frame")
        throw(ArgumentError("correction priming requires a complete-frame CPU graph"))
    end
    return options
end

function _main(
    args;
    with_owner = Bootstrap.with_owner,
    load_science = () -> Base.require(Main, :FilterGraphPipeWire),
    run = run_owner,
)
    binding, graph_arguments, fits_path, correction_properties, correction_timeout_ms, recovery_nodes, supervision_path, offsets_path, qualification, local_output = arguments(
        args
    )
    with_owner(binding) do admitted
        admitted.owner_check()
        filter_graph_pipewire = Common.startup_phase(
            load_science, binding.bootstrap_node, "load FilterGraphPipeWire"
        )
        offsets_path === nothing || Base.require(Main, :AdaptiveOpticsSimPipeWireHIL)
        admitted.owner_check()
        options = graph_options(
            filter_graph_pipewire, graph_arguments, correction_properties,
            correction_timeout_ms, recovery_nodes, supervision_path, offsets_path, qualification,
            local_output; prime_on_output = get(binding, :prime_on_output, nothing),
        )
        entries = fits_path === nothing ? FITSBinding[] : bindings(fits_path)
        admitted.owner_check()
        Base.invokelatest(run, options, admitted.bootstrap_runtime, entries)
    end
    return 0
end

"""
    main(args)

Run a package-owned FilterGraphPipeWire scientific process. Publish bootstrap
Preparing before loading FilterGraphPipeWire. Required bootstrap flags are `--bootstrap-node`,
`--bootstrap-instance`, and absolute `--remote`; other graph flags are forwarded.
`--fits-bindings PATH` selects a native SPA-JSON document with `parameters` entries
containing `port`, `path`, optional one-based `hdu` and FITS `axes`. The graph's
typed Parameter Ports define element types and shapes. Paths resolve relative to
the manifest. Multidimensional images require explicit
axes. FITS startup does not change legacy raw `--parameter` file semantics.
`--correction-property NODE:PROPERTY` declares a Boolean correction-loop property
for RTC-owned adoption tracking; repeat it for independent declared loops.
This does not change startup closure, lifecycle, or the scientific controller.
`--prime-on-output PORT` holds closure admission until the owner observes a valid
live measurement on the declared output of a complete-frame CPU graph.
Use `--prime-on-output NODE:closed=PORT` for each correction if the owner declares
multiple loops. Declare each controller initially open and select a published,
acquisition-aware measurement for its camera. Use `PORT,VALIDITY` for measurements
that also require a published Boolean validity output from the same acquisition.
Reset clears priming evidence while
preserving the applied correction property. Open the loop before collecting a new
open-loop measurement.
`--recovery-node NODE` opts the declared coupled controllers into scoped CPU
recovery; repeat it for every participating temporal filter and conditioner.
The controller is implicit. Recovery refuses unsupported scopes before effects;
reference evidence expires using `--correction-timeout-ms`. No supervisor
threshold or automatic intervention is enabled by these declarations.
`--supervision PATH` selects bounded YAML command-constraint monitoring. Its
explicit thresholds apply to successful complete frames; sizes come from the
typed graph outputs. Monitor-only is the default and never changes closure.
`--correction-timeout-ms N` bounds adoption confirmation for declared loops
(1–60000 ms, default 5000). Expiry reports Unknown without a control retry.
`--chopped-warmup PATH` supplies bounded version-1 YAML for offline qualification.
It declares an image `input`, `exposure_duration_ns` and `trigger_high_is_fringed`.
Three unpublished synthetic F/U/F samples exercise the chopped detector path.
Installation qualifies supported complete-frame CPU graphs. The existing
`--qualify-at-install` flag requires a supported graph and its qualification
workload. Live owners process only real frames, which establish their scientific
history and carry any required acquisition identity, exposure or chopping records.
`--latest-output PORT NODE MEDIA` publishes a complete-frame scalar on an
independent display Node. `--latest-output-sink NODE PORT` declares an optional
native sink for that publisher. `--unpublished-output PORT` discards the same
logical Graph output. In both cases the Graph owner exposes no native Port
for the scalar, while retaining the Graph's scientific state and calibration output.
"""
main(args) = _main(args)

warmup_input(value) = throw(ArgumentError("chopped warmup input must name a Graph Port"))
function warmup_input(value::String)
    occursin(r"^[a-zA-Z0-9_.-]{1,128}$", value) || return warmup_input(nothing)
    return value
end

warmup_duration(value::Integer) = 0 < value <= typemax(Int64)
warmup_duration(value::Bool) = false
warmup_duration(value) = false

warmup_polarity(value::Bool) = value
warmup_polarity(value) = throw(ArgumentError("chopped warmup polarity must be Boolean"))

binding_entries(value::AbstractVector) = value
binding_entries(value) = throw(ArgumentError("FITS parameters must be an array"))

binding_entry(value) = throw(ArgumentError("invalid FITS binding fields"))
function binding_entry(value::AbstractDict)
    all(key -> key in ("port", "path", "hdu", "axes"), keys(value)) ||
        return binding_entry(nothing)
    return value
end

binding_text(value, key) = throw(ArgumentError("FITS binding requires nonempty $key"))
function binding_text(value::String, key)
    !isempty(value) && !occursin('\0', value) || return binding_text(nothing, key)
    return value
end

end
