"""Cold declarations for optional graph and instrument AOS owners."""
module AOSOwner

import TOML
import UUIDs

import ..Artifacts
import ..Common
import ..DeploymentConfiguration
import ..InstrumentDefinition
import ..InstrumentConfiguration
import ..NativeOwnerBootstrapRuntime

public main, plant_settings, plant_declaration

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

"Seal a bounded JSON value into concrete, immutable cold settings."
Base.@nospecializeinfer function plant_settings(@nospecialize(value), remaining=Ref(4096), depth=0)
    depth <= 16 || throw(ArgumentError("plant settings exceed 16 nesting levels"))
    remaining[] -= 1
    remaining[] >= 0 || throw(ArgumentError("plant settings exceed 4096 values"))
    if value isa AbstractDict
        length(value) <= remaining[] || throw(ArgumentError("plant settings exceed 4096 values"))
        names = Tuple(identifier(key, "plant setting name") for key in keys(value))
        items = Tuple(plant_settings(item, remaining, depth + 1) for item in values(value))
        return NamedTuple{names}(items)
    elseif value isa AbstractVector
        length(value) <= remaining[] || throw(ArgumentError("plant settings exceed 4096 values"))
        return Tuple(plant_settings(item, remaining, depth + 1) for item in value)
    elseif value isa String
        ncodeunits(value) <= 16 * 1024 && !occursin('\0', value) ||
            throw(ArgumentError("plant setting strings must be at most 16 KiB without NUL"))
        return value
    elseif value === nothing || value isa Bool || value isa Integer
        return value
    elseif value isa AbstractFloat && isfinite(value)
        return value
    end
    throw(ArgumentError("plant settings must contain finite basic JSON values"))
end

function plant_declaration(value; directory=nothing)
    value isa AbstractDict && Set(keys(value)) == Set(("package", "settings")) ||
        throw(ArgumentError("plant requires exactly package and settings"))
    package = identifier(value["package"], "plant package")
    value["settings"] isa AbstractDict || throw(ArgumentError("plant settings must be an object"))
    settings = plant_settings(value["settings"])
    if directory !== nothing && haskey(settings,:mirror_description)
        settings=merge(settings,(;mirror_description=DeploymentConfiguration.relative_asset(
            directory,settings.mirror_description)))
    end
    if directory !== nothing && haskey(settings,:influence_functions) &&
            hasproperty(settings.influence_functions, :path)
        influences = settings.influence_functions
        settings = merge(settings, (; influence_functions=merge(influences,
            (; path=DeploymentConfiguration.relative_asset(directory, influences.path)))))
    end
    return (; package, settings)
end

"Parse the complete native bootstrap invocation without loading science."
function arguments(args)
    values = Dict{String,String}()
    required = ("--config", "--remote", "--control-node", "--bootstrap-node", "--bootstrap-instance")
    optional = ("--phase-timing-directory", "--phase-timing-frames", "--phase-timing-warmup")
    allowed = (required..., optional..., "--transport-cpu")
    iseven(length(args)) || throw(ArgumentError("each AOS owner option requires a value"))
    for index in 1:2:length(args)
        key, value = args[index], args[index + 1]
        key in allowed || throw(ArgumentError("unknown AOS owner option $key"))
        haskey(values, key) && throw(ArgumentError("duplicate $key"))
        values[key] = text(value, key)
    end
    all(key -> haskey(values, key), required) || throw(ArgumentError(
        "AOS owner requires --config, --remote, --control-node, --bootstrap-node and --bootstrap-instance"))
    remote = values["--remote"]
    isabspath(remote) || throw(ArgumentError("AOS owner requires an absolute private remote"))
    control_node = node_name(values["--control-node"], "control node")
    bootstrap_node = node_name(values["--bootstrap-node"], "bootstrap node")
    control_node != bootstrap_node || throw(ArgumentError("source and bootstrap nodes must differ"))
    instance = tryparse(Int64, values["--bootstrap-instance"])
    instance !== nothing && instance > 0 || throw(ArgumentError("bootstrap instance must be positive"))
    transport_cpu = nothing
    if haskey(values, "--transport-cpu")
        transport_cpu = tryparse(Int, values["--transport-cpu"])
        transport_cpu !== nothing && transport_cpu >= 2 ||
            throw(ArgumentError("transport CPU must be an integer excluding CPUs 0 and 1"))
    end
    requested_timing = any(key -> haskey(values, key), optional)
    timing_directory = nothing
    timing_frames = timing_warmup = 0
    if requested_timing
        all(key -> haskey(values, key), optional[1:2]) || throw(ArgumentError(
            "phase timing requires --phase-timing-directory and --phase-timing-frames"))
        timing_directory = values["--phase-timing-directory"]
        isabspath(timing_directory) || throw(ArgumentError("phase timing directory must be absolute"))
        timing_directory = abspath(timing_directory)
        timing_frames = tryparse(Int, values["--phase-timing-frames"])
        timing_warmup = tryparse(Int, get(values, "--phase-timing-warmup", "512"))
        timing_frames !== nothing && 1 <= timing_frames <= 65_536 ||
            throw(ArgumentError("phase timing frames must be in 1:65536"))
        timing_warmup !== nothing && 0 <= timing_warmup <= 65_536 ||
            throw(ArgumentError("phase timing warmup must be in 0:65536"))
    end
    return (; remote, control_node, bootstrap_node, bootstrap_instance=instance,
        config=abspath(values["--config"]), phase_timing_directory=timing_directory,
        phase_timing_frames=timing_frames, phase_timing_warmup=timing_warmup, transport_cpu)
end

"Validate every configuration declaration before preparing any FITS artifact."
function configuration(path::AbstractString)
    document = DeploymentConfiguration.decode(path, get(ENV, "PIPEWIREAO_PREFIX", "/opt/pipewireao"))
    document isa AbstractDict || throw(ArgumentError("AOS configuration must be an object"))
    version = integer(get(document, "version", nothing), "version", 1, 3)
    shared_fields = ("version", "command_input", "frame_output", "command_count", "frame_shape",
        "rate", "exposure_ns", "wall_rate", "backend", "device", "command_node",
        "frame_schema", "command_schema", "command_scale", "total_exchanges", "optical_observation",
        "detector_observation", "command_observation", "applied_command_observation", "calibration_identity", "instrument")
    shared_required = ("version", "command_input", "frame_output", "command_count", "frame_shape",
        "rate", "exposure_ns", "wall_rate", "backend", "device")
    route_fields = version == 1 ? ("graph", "artifacts") : ("plant", "frame_encoding")
    fields = (shared_fields..., route_fields...)
    required = version == 1 ? (shared_required..., route_fields...) :
        (shared_required..., route_fields..., "frame_schema", "command_schema", "command_scale")
    version == 3 && (required = (required...,"instrument","calibration_identity"))
    all(key -> key in fields, keys(document)) &&
        all(key -> haskey(document, key), required) || throw(ArgumentError("invalid AOS configuration fields"))
    config_path = abspath(path)
    graph = version == 1 ? abspath(joinpath(dirname(config_path), text(document["graph"], "graph"))) : nothing
    graph === nothing || isfile(graph) || throw(ArgumentError("AOS graph does not exist: $graph"))
    plant = if version == 3
        entry = document["plant"]
        InstrumentConfiguration.fields(entry,("definition","settings"),("definition","settings"),"declarative plant")
        definition = DeploymentConfiguration.relative_asset(dirname(config_path),entry["definition"])
        declaration = InstrumentConfiguration.load(definition)
        configured = InstrumentConfiguration.settings(declaration,entry["settings"])
        (; definition,settings=plant_settings(configured))
    elseif version == 2
        plant_declaration(document["plant"]; directory=dirname(config_path))
    else
        nothing
    end
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
    frame_encoding = version == 1 ? :uint16 : Symbol(text(document["frame_encoding"], "frame_encoding"))
    frame_encoding === :uint16 || throw(ArgumentError("AOS frame_encoding must be uint16"))
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
    calibration_identity = haskey(document, "calibration_identity") ?
        text(document["calibration_identity"], "calibration_identity") : nothing
    instrument = haskey(document,"instrument") ?
        DeploymentConfiguration.relative_asset(dirname(config_path),document["instrument"]) : nothing
    instrument===nothing || version in (2,3) && calibration_identity!==nothing ||
        throw(ArgumentError("instrument definition requires an instrument plant and calibration identity"))
    mirror_description = plant === nothing ? nothing : get(plant.settings,:mirror_description,nothing)
    if version == 3
        declaration = InstrumentConfiguration.load(plant.definition)
        mirrors = declaration.document["deformable_mirrors"]
        mirror_description = length(mirrors)==1 ? DeploymentConfiguration.relative_asset(
            declaration.directory,only(values(mirrors))["description"]) : nothing
    end
    entries = version == 1 ? document["artifacts"] : ()
    (entries isa AbstractVector || entries === ()) && length(entries) <= 64 || throw(ArgumentError("artifacts must be an array of at most 64 entries"))
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
    return (; version, config_path, plant, graph, command_input, frame_output, command_count, frame_shape, rate, period_ns,
        exposure_ns, wall_rate, wall_period_ns, backend, device, artifacts, command_node,
        frame_encoding, frame_schema, command_schema, command_scale, total_exchanges, optical_observation,
        detector_observation, command_observation, applied_command_observation, calibration_identity, instrument, mirror_description)
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

"The private invocation directory owns this small operational report."
report_path(options) = joinpath(dirname(options.remote), options.control_node * "-report.json")

"""Save an atomic operational cursor record, without scientific arrays or timing claims."""
function write_report(options, state, generation, source_instance; failures=())
    generation === nothing && isempty(failures) &&
        throw(ArgumentError("an unknown report generation requires a recorded failure"))
    record = (;
        version=1, kind="pipewireao.rtc.aos-owner-report/1",
        bootstrap_instance=integer(options.bootstrap_instance, "bootstrap_instance", 1, typemax(Int64)),
        source_instance=integer(source_instance, "source_instance", 1, typemax(Int64)),
        owner_pid=getpid(),
        generation=generation === nothing ? nothing : integer(generation, "generation", 1, typemax(Int64)),
        sequence=integer(state.sequence, "sequence", 0, typemax(Int64)),
        running=state.running, completed=state.completed,
        backend=string(options.backend), graph=options.graph,
        graph_sha256=get(options, :graph_sha256, nothing),
        configuration=get(options, :config_path, nothing),
        configuration_sha256=get(options, :configuration_sha256, nothing),
        plant=get(options, :plant, nothing),
        failures=[first(replace(sprint(showerror, error), '\0' => '?'), 1024) for error in failures],
    )
    calibration_identity = get(options, :calibration_identity, nothing)
    calibration_identity === nothing ||
        (record = merge(record, (; startup_calibration_identity=calibration_identity)))
    path = report_path(options)
    mkpath(dirname(path))
    temporary, io = mktemp(dirname(path))
    errors = Exception[]
    try
        close(io)
        Common.write_json(temporary, record)
        # Same-directory rename replaces the complete file atomically and
        # preserves a conflicting directory when replacement fails.
        Base.rename(temporary, path)
    catch error
        push!(errors, error)
    finally
        try isopen(io) && close(io) catch error; push!(errors, error) end
        try ispath(temporary) && rm(temporary) catch error; push!(errors, error) end
    end
    isempty(errors) || throw(length(errors) == 1 ? only(errors) : CompositeException(errors))
    return nothing
end

"Load only the exact plant dependency declared by the active application."
function load_instrument(package::Symbol)
    project = Base.active_project()
    project !== nothing && isfile(project) ||
        throw(ArgumentError("instrument preparation requires an active application Project.toml"))
    dependencies = get(TOML.parsefile(project), "deps", nothing)
    name = string(package)
    dependencies isa AbstractDict && haskey(dependencies, name) ||
        throw(ArgumentError("plant package $name must be a direct dependency of the active application"))
    uuid = dependencies[name]
    uuid isa String || throw(ArgumentError("plant dependency $name must declare a UUID"))
    identity = Base.PkgId(UUIDs.UUID(uuid), name)
    instrument = Base.require(identity)
    Base.PkgId(instrument) == identity ||
        throw(ArgumentError("loaded plant module differs from the declared dependency identity"))
    return instrument
end

# The application declares optional science packages as its direct dependencies.
function _main(args; with_owner=Bootstrap.with_owner,
        load_science=() -> begin
            Base.require(Main, :AdaptiveOpticsSim)
            Base.require(Main, :AdaptiveOpticsSimPipeWireHIL)
        end,
        load_cuda=() -> Base.require(Main, :CUDA),
        load_plant=load_instrument, run=run_owner)
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
        if admitted.version == 3
            InstrumentDefinition.verify_declaration(admitted)
        elseif admitted.plant !== nothing
            plant_module = load_plant(admitted.plant.package)
            admitted.owner_check()
            InstrumentDefinition.verify_plant(admitted,plant_module)
            admitted = merge(admitted, (; plant_module))
        end
        Base.invokelatest(run, admitted)
    end
    return 0
end

"""
    main(args)

Run a native AOS scientific owner from `--config PATH`, with explicit `--remote`,
`--control-node`, `--bootstrap-node` and `--bootstrap-instance`. The version 1
SPA-JSON configuration declares the simulation YAML graph and FITS bindings;
version 2 selects an instrument package and immutable settings. Version 3 selects
a SPA-JSON instrument declaration and immutable settings without an instrument
package. All versions declare
command/frame names, extents, timing and backend/device. Paths are relative to
the configuration. Preparing is published before optional science imports.
FITS preparation is cold startup only; RTC retains lifecycle authority.
"""
main(args) = _main(args)

end
