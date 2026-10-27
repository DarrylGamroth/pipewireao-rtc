"""Cold preparation of command completion, allocation and calibration artifacts."""
module InstrumentCalibration

using LinearAlgebra, SHA
import ..Common
import ..Artifacts
import ..InstrumentConfiguration
import ..GraphOwner
import ..DeploymentConfiguration
import ..ScienceExport
import ..InstrumentExport

public digest, source_completion, read_parameters, write_fits, heart_completion,
    controlled_rows, central_completion, allocation_parameters, replace_dimensions!,
    require_prepared_application, estimator_dimensions, checked_command_limits, shack_hartmann_configuration,
    controller_graph, calibration_graph, controller_storage, measure!, calibration_frame!, calibrate_system,
    calibrate_hidden_modes, validate_system, lowpass_coefficients, read_recipe,
    read_bundle, write_bundle, stage_calibration

"""
    lowpass_coefficients(T; cutoff_frequency_hz, sample_rate_hz)

Prepare a first-order low-pass section in `Float32` or `Float64`, in FGA's
normalized `(b0, b1, b2, a1, a2)` order. The denominator is
`1 + a1*z⁻¹ + a2*z⁻²`. A prewarped bilinear transform gives
`k = tan(π*cutoff_frequency_hz/sample_rate_hz)` and `a1 = (k-1)/(k+1)`.
After rounding the pole to `T`, normalize `b0 = b1 = (1+a1)/2` and set
`b2 = a2 = 0`. This preserves unity DC gain in the prepared precision.

Both frequencies must be finite and positive, and the cutoff must be strictly
below Nyquist. Reject poles that round onto the unit circle. This cold helper
does not prepare optical matrices or require FGA or DSP at runtime.
"""
function lowpass_coefficients(::Type{T}; cutoff_frequency_hz, sample_rate_hz) where {T<:Union{Float32,Float64}}
    for value in (cutoff_frequency_hz, sample_rate_hz)
        InstrumentConfiguration.isfinite_real(value) && value > 0 &&
            isfinite(Float64(value)) ||
            throw(ArgumentError("filter frequencies must be finite positive numbers representable in Float64"))
    end
    ratio = Float64(cutoff_frequency_hz) / Float64(sample_rate_hz)
    0 < ratio < 0.5 || throw(ArgumentError("low-pass cutoff must be strictly below Nyquist"))
    k = tanpi(ratio)
    a1 = T((k - 1) / (k + 1))
    abs(a1) < one(T) || throw(ArgumentError("low-pass pole must remain strictly stable in $T"))
    b0 = T((1 + Float64(a1)) / 2)
    dc_gain = (2 * Float64(b0)) / (1 + Float64(a1))
    isfinite(dc_gain) && isapprox(dc_gain, 1; rtol=4eps(T), atol=0) ||
        throw(ArgumentError("low-pass DC normalization is not representable in $T"))
    return T[b0, b0, 0, a1, 0]
end

# Validate before preparing the optical plant. Only the existing tip/tilt cascade
# is selected here; absent configuration retains its identity coefficients.
function _tiptilt_temporal(recipe, frame_period_s)
    InstrumentConfiguration.isfinite_real(frame_period_s) && frame_period_s > 0 ||
        throw(ArgumentError("simulation frame_period_s must be finite and positive"))
    period = Float64(frame_period_s)
    sample_rate_hz = inv(period)
    isfinite(period) && isfinite(sample_rate_hz) && sample_rate_hz > 0 ||
        throw(ArgumentError("simulation frame period must give a finite positive sample rate"))
    description = Dict{String,Any}("frame_period_s"=>period, "sample_rate_hz"=>sample_rate_hz,
        "tiptilt"=>Dict("kind"=>"identity"))
    haskey(recipe,"temporal") || return (;coefficients=Float32[1,0,0,0,0],description)
    temporal = InstrumentConfiguration._declaration_fields(recipe["temporal"],
        ("tiptilt",), ("tiptilt",), "calibration temporal")
    tiptilt = InstrumentConfiguration._declaration_fields(temporal["tiptilt"],
        ("kind","cutoff_frequency_hz"), ("kind","cutoff_frequency_hz"), "calibration temporal.tiptilt")
    tiptilt["kind"] == "lowpass" || throw(ArgumentError("temporal.tiptilt kind must be lowpass"))
    coefficients = lowpass_coefficients(Float32;
        cutoff_frequency_hz=tiptilt["cutoff_frequency_hz"], sample_rate_hz)
    description["tiptilt"] = Dict("kind"=>"lowpass", "cutoff_frequency_hz"=>Float64(tiptilt["cutoff_frequency_hz"]))
    return (;coefficients,description)
end

"Return the SHA-256 digest of a file's bytes."
digest(path) = bytes2hex(sha256(read(path)))

"Read a reviewed command-completion artifact with an explicit logical shape."
function source_completion(path; expected_sha256, shape, axes=(2, 1))
    source = Artifacts.FITSArtifact(path; axes)
    bytes = Artifacts.snapshot(String(path); check=()->nothing)
    bytes2hex(sha256(bytes)) == expected_sha256 ||
        throw(ArgumentError("source completion differs from the reviewed input"))
    return Artifacts.prepare_snapshot(source, Float32, shape, bytes).data
end

function read_parameters(application)
    # This cold API loads the optional scientific owner; core startup stays independent.
    Base.require(Main, :FilterGraphIsland)
    return Base.invokelatest(GraphOwner.read_bindings,
        joinpath(application, "rtc", "graph.conf"),
        joinpath(application, "rtc", "parameters.conf"))
end

"Cold projection of an existing built graph for initial calibration (optional science extension)."
function calibration_graph end

"Prepare a native CPU initial-calibration endpoint from the regular graph projections."
function prepare_initial_calibration end
public prepare_initial_calibration

"Reject source instruments before numerical calibration or validation starts."
function require_prepared_application(application)
    for path in ("deployment.conf", "instrument.json", joinpath("rtc", "parameters.conf"))
        isfile(joinpath(application, path)) || throw(ArgumentError(
            "calibration requires a built application; run tools/build.jl on the source instrument first (missing $path)"))
    end
    return nothing
end

"Write the existing row-major calibration FITS convention."
function write_fits(path, array)
    isfile(path) && rm(path)
    Artifacts.FITSIO.FITS(path, "w") do file
        values = eltype(array) === Bool ? UInt8.(array) : array
        write(file, ndims(values) == 1 ? values : permutedims(values, reverse(ntuple(identity,ndims(values)))))
    end
    return path
end

"""
Read the archived zero-based row,column,value convention, with its original
`-32 2 rows columns` header. This is an archive reader, not a current HEART loader.
The supplied digest identifies the reviewed input; no instrument path is implied.
"""
function heart_completion(path; expected_sha256, shape)
    length(shape) == 2 && all(>(0), shape) ||
        throw(ArgumentError("archived completion requires a positive matrix shape"))
    bytes = read(path)
    bytes2hex(sha256(bytes)) == expected_sha256 ||
        throw(ArgumentError("archived extrapolator differs from the reviewed input"))
    lines = readlines(IOBuffer(bytes))
    isempty(lines) && throw(ArgumentError("missing legacy header"))
    split(strip(first(lines))) == ["-32", "2", string(shape[1]), string(shape[2])] ||
        throw(ArgumentError("unexpected legacy header"))
    matrix = zeros(Float32, shape...)
    occupied = falses(shape...)
    for line in lines[2:end]
        fields = split(strip(line), ',')
        length(fields) == 3 || throw(ArgumentError("invalid sparse record"))
        row, column = parse(Int, fields[1]) + 1, parse(Int, fields[2]) + 1
        checkbounds(Bool, matrix, row, column) ||
            throw(ArgumentError("sparse index outside command map"))
        occupied[row, column] && throw(ArgumentError("duplicate sparse record"))
        value = parse(Float32, fields[3])
        isfinite(value) || throw(ArgumentError("nonfinite extrapolation coefficient"))
        matrix[row, column] = value
        occupied[row, column] = true
    end
    controlled = findall(column -> any(!iszero, view(matrix, :, column)), axes(matrix, 2))
    completion = matrix[:, controlled]
    # Reproduce the archive's truncation convention: exact unit rows identify
    # direct coordinates. Inputs without a direct row remain archive data.
    feedback = zeros(Float32, length(controlled), size(matrix, 1))
    for row in axes(completion, 1)
        nonzero = findall(!iszero, view(completion, row, :))
        if length(nonzero) == 1 && completion[row, only(nonzero)] == 1
            feedback[only(nonzero), row] = 1
        end
    end
    return (; completion, controlled, feedback)
end

function controlled_rows(completion)
    return map(axes(completion, 2)) do column
        only(filter(axes(completion, 1)) do row
            completion[row, column] == 1 && count(!iszero, view(completion, row, :)) == 1
        end)
    end
end

"Complete obscured coordinates by the discrete harmonic extension of their neighbours."
function central_completion(original, obstruction, mirror; pupil_registration)
    size(original, 1) == InstrumentConfiguration.command_count(mirror) ||
        throw(DimensionMismatch("completion rows differ from physical mirror commands"))
    isfinite(obstruction) && obstruction > 0 ||
        throw(ArgumentError("central obstruction must be finite and positive"))
    controlled = controlled_rows(original)
    coordinates = InstrumentConfiguration.actuator_coordinates(mirror; pupil_registration)
    removed = findall(controlled) do actuator
        hypot(coordinates[1, actuator], coordinates[2, actuator]) < obstruction
    end
    isempty(removed) && throw(ArgumentError("no obscured command coordinates"))
    retained = setdiff(collect(axes(original, 2)), removed)
    grid = CartesianIndices(mirror.layout.grid_shape)[InstrumentConfiguration.actuator_grid_indices(mirror)]
    by_position = Dict(Tuple(position) => index for (index, position) in pairs(grid))
    removed_by_actuator = Dict(controlled[column] => row for (row, column) in pairs(removed))
    direct_by_actuator = Dict(controlled[column] => index for (index, column) in pairs(retained))
    laplacian = zeros(Float64, length(removed), length(removed))
    boundary = zeros(Float64, length(removed), length(retained))
    for (row, column) in pairs(removed)
        x, y = Tuple(grid[controlled[column]])
        for (dx, dy) in ((-1, 0), (1, 0), (0, -1), (0, 1))
            neighbour = get(by_position, (x + dx, y + dy), 0)
            neighbour > 0 || throw(ArgumentError("central completion has a missing lattice neighbour"))
            laplacian[row, row] += 1
            if haskey(removed_by_actuator, neighbour)
                laplacian[row, removed_by_actuator[neighbour]] -= 1
            else
                haskey(direct_by_actuator, neighbour) ||
                    throw(ArgumentError("boundary is not directly controlled"))
                boundary[row, direct_by_actuator[neighbour]] += 1
            end
        end
    end
    extension = laplacian \ boundary
    substitution = zeros(Float32, size(original, 2), length(retained))
    substitution[retained, :] = Matrix{Float32}(I, length(retained), length(retained))
    substitution[removed, :] = Float32.(extension)
    # Carry original outer-completion dependence on obscured coordinates through
    # to the same sensed boundary values.
    completion = original * substitution
    return (; completion, controlled=controlled[retained], obscured=controlled[removed])
end

"Initialize a shape calibration pair, retaining an unbound shape offset's zero default."
function initialize_shape_offsets!(parameters::AbstractDict,prefix::AbstractString="")
    names=map(suffix -> Symbol(prefix*suffix),
        ("shape-active-to-full","shape-pdm-to-vdm","shape-offset"))
    present=map(name -> haskey(parameters,name),names)
    any(present) || return parameters
    present[1] && present[2] || throw(ArgumentError("shape calibration requires both completion and inverse ports"))
    parameters[names[1]]=copy(parameters[Symbol(prefix*"active-to-full")])
    parameters[names[2]]=copy(parameters[Symbol(prefix*"pdm-to-vdm")])
    present[3] && (parameters[names[3]]=zero(parameters[names[3]]))
    return parameters
end

"Prepare controller allocation matrices with explicit measurement dimensions."
function allocation_parameters(parameters, completion, controlled; measurement_count, feedback=nothing)
    n = length(controlled)
    n > 0 && measurement_count > 0 ||
        throw(ArgumentError("allocation requires positive command and measurement counts"))
    size(completion, 2) == n || throw(DimensionMismatch("completion columns differ from controlled coordinates"))
    length(unique(controlled)) == n && all(index -> index in axes(completion, 1), controlled) ||
        throw(ArgumentError("controlled coordinates must be distinct physical command indices"))
    selector = zeros(Float32, n, size(completion, 1))
    for (row, actuator) in pairs(controlled)
        selector[row, actuator] = 1
    end
    if feedback !== nothing
        size(feedback) == size(selector) || throw(DimensionMismatch("feedback shape differs from command selector"))
        selector = feedback
    end
    parameters[Symbol("active-to-full")] = completion
    parameters[Symbol("full-to-active")] = selector
    parameters[Symbol("controller-to-vdm")] = Matrix{Float32}(I, n, n)
    parameters[Symbol("vdm-to-controller")] = Matrix{Float32}(I, n, n)
    parameters[Symbol("shape-to-hidden")] = fill(1f0 / n, 1, n)
    parameters[Symbol("hidden-to-shape")] = ones(Float32, n, 1)
    parameters[:reconstructor] = zeros(Float32, n, measurement_count)
    initialize_shape_offsets!(parameters)
    return parameters
end

function command_limit(::Type{T}, value::Real, count) where {T<:AbstractFloat}
    InstrumentConfiguration.isfinite_real(value) && isfinite(T(value)) ||
        throw(ArgumentError("command limit must be finite in $T"))
    return T(value)
end
function command_limit(::Type{T}, value::AbstractVector, count) where {T<:AbstractFloat}
    length(value) == count || throw(DimensionMismatch("per-actuator command limit length differs"))
    all(InstrumentConfiguration.isfinite_real,value) || throw(ArgumentError("per-actuator command limits must be finite numbers"))
    return [command_limit(T, item, count) for item in value]
end
command_limit(::Type{T}, value, count) where {T<:AbstractFloat} =
    throw(ArgumentError("command limit must be a scalar or per-actuator vector"))
limit_at(value::Real, index) = value
limit_at(value::AbstractVector, index) = value[index]

"Validate scalar or per-actuator limits without changing their representation."
function checked_command_limits(::Type{T}, lower, upper, count::Integer) where {T<:AbstractFloat}
    InstrumentConfiguration.ispositive_integer(count) || throw(ArgumentError("physical actuator count must be positive"))
    lower, upper = command_limit(T, lower, count), command_limit(T, upper, count)
    all(index -> limit_at(lower,index) < limit_at(upper,index), 1:count) ||
        throw(ArgumentError("lower command limit must be strictly below upper command limit"))
    return (;lower,upper)
end

_dimension_reference(value::AbstractDict) = haskey(value, "\$ref")
_dimension_reference(value) = false

"Update declared controller dimensions and artifacts in a prepared application."
function replace_dimensions!(application, parameters, n; measurement_count, command_limits=nothing, mirror=nothing)
    n > 0 && measurement_count > 0 || throw(ArgumentError("controller dimensions must be positive"))
    limits = command_limits === nothing ? nothing : checked_command_limits(Float64,
        command_limits.lower, command_limits.upper, size(parameters[Symbol("vdm-to-pdm")],1))
    authoring = DeploymentConfiguration.decode(joinpath(application, "rtc", "application.conf"),
        get(ENV, "PIPEWIREAO_PREFIX", "/opt/pipewireao"))
    configuration_path = DeploymentConfiguration.relative_asset(application, get(authoring,"configuration","rtc/configuration.yaml"))
    rtc = InstrumentConfiguration.load_rtc(configuration_path)
    hidden_count = get(rtc.document["dimensions"], "hidden_mode_count", nothing)
    if hidden_count !== nothing
        size(parameters[Symbol("shape-to-hidden")]) == (hidden_count, n) &&
            size(parameters[Symbol("hidden-to-shape")]) == (n, hidden_count) ||
            throw(DimensionMismatch("hidden-mode projections differ from the declared controller coordinates"))
    end
    dimensions = rtc.authoring["dimensions"]
    if haskey(rtc.authoring, "controller")
        rtc.authoring["controller"]["command_count"] = n
        # Retain a declared reference; an independently specified active VDM
        # allocation is updated by this calibration alongside the controller.
        active = get(dimensions, "active_vdm_count", nothing)
        if active !== nothing && !_dimension_reference(active)
            dimensions["active_vdm_count"] = n
        end
    else
        for name in ("controller_command_count", "active_vdm_count", "state_length")
            haskey(dimensions, name) && (dimensions[name] = n)
        end
    end
    expected = InstrumentConfiguration.controller_dimensions(rtc.authoring,rtc.instrument)
    for key in ("controller_command_count", "active_vdm_count")
        get(expected,key,n) == n || throw(DimensionMismatch(
            "calibrated allocation differs from declared $key"))
    end
    if limits !== nothing
        names = keys(rtc.controls["deformable_mirrors"])
        mirror === nothing && length(names) != 1 &&
            throw(ArgumentError("calibration limit updates require an explicit mirror when several are declared"))
        selected = mirror === nothing ? only(names) : String(mirror)
        haskey(rtc.controls["deformable_mirrors"], selected) || throw(ArgumentError("unknown calibration mirror"))
        expected_count = InstrumentConfiguration.command_count(
            InstrumentConfiguration.mirror(rtc, NamedTuple(), selected).description)
        expected_count == size(parameters[Symbol("vdm-to-pdm")],1) ||
            throw(DimensionMismatch("calibration command count differs from selected mirror"))
        limiter = rtc.control_authoring["deformable_mirrors"][selected]["limiter"]
        limiter["lower"], limiter["upper"] = limits.lower, limits.upper
    end
    graph_path = joinpath(application, "rtc", "graph.conf")
    graph = DeploymentConfiguration.decode(graph_path,
        get(ENV, "PIPEWIREAO_PREFIX", "/opt/pipewireao"))
    for node in graph["filter.graph"]["nodes"]
        config, name = node["config"], node["name"]
        name == "reconstruction" && (config["reconstructed_count"] = n)
        name == "closed-loop-correction" && (config["state_length"] = n)
        for key in ("active_vdm_count", "controller_command_count")
            haskey(config, key) && (config[key] = n)
        end
        if name == "pdm-command" && limits !== nothing
            config["command_limits"] = [limits.lower, limits.upper]
        end
    end
    ScienceExport.write_spa_config(graph_path, graph)
    path = joinpath(application, "rtc", "parameters.conf")
    document = DeploymentConfiguration.decode(path, get(ENV, "PIPEWIREAO_PREFIX", "/opt/pipewireao"))
    for entry in document["parameters"]
        array = parameters[Symbol(entry["port"])]
        write_fits(joinpath(dirname(path), entry["path"]), array)
    end
    Common.write_yaml(configuration_path, rtc.authoring; atomic=true,
        header="Generated by PipeWireAORTC calibration; edit RTC source and rebuild.")
    if limits !== nothing
        controls_path = DeploymentConfiguration.relative_asset(application,rtc.document["mirror_controls"])
        Common.write_yaml(controls_path, rtc.control_authoring;
            header="Generated by PipeWireAORTC calibration; edit source RTC mirror controls and rebuild.")
    end
    InstrumentConfiguration.prepare_publication(application; configuration=relpath(configuration_path,application))
    session_path = joinpath(application, "rtc", "session.conf.in")
    session = DeploymentConfiguration.decode(session_path, get(ENV, "PIPEWIREAO_PREFIX", "/opt/pipewireao"))
    contracts = InstrumentExport.graph_contract_context(application, authoring["graph-configurations"],
        get(ENV, "PIPEWIREAO_PREFIX", "/opt/pipewireao"))
    refresh_session_parameters!(session, contracts)
    Common.write_json(session_path, session)
    profile_path = joinpath(application, "gui", "operator-views.yaml")
    profile = Common.read_yaml(profile_path)
    refresh_parameter_metadata!(profile, contracts)
    Common.write_yaml(profile_path, profile)
    return nothing
end

"Read estimator dimensions from prepared ports and reject stale calibration declarations."
function estimator_dimensions(application, estimator)
    Base.require(Main, :FilterGraphIsland)
    contracts = Base.invokelatest(InstrumentExport.graph_port_contracts,
        joinpath(application, "rtc", "graph.conf"))
    detector_shape = Tuple(contracts["inputs"][estimator["raw_input"]]["shape"])
    measurement_count = foldl(Base.checked_mul,
        contracts["outputs"][estimator["slopes_output"]]["shape"]; init=1)
    detector_shape == Tuple(estimator["detector_shape"]) ||
        throw(DimensionMismatch("detector shape differs from estimator declaration"))
    measurement_count == estimator["measurement_count"] ||
        throw(DimensionMismatch("measurement count differs from estimator declaration"))
    return (; detector_shape, measurement_count)
end

# Native GUI parameter bindings select an exact graph and parameter. Their
# consumer supports F32_LE; schema, storage layout and units remain declarations.
function refresh_parameter_metadata!(value::AbstractDict, contracts)
    if haskey(value, "graph") && get(value, "parameter", nothing) isa AbstractString
        contract = contracts[value["graph"]]["parameters"][value["parameter"]]
        contract["element-type"] == "F32_LE" ||
            throw(ArgumentError("GUI parameter bindings require F32_LE"))
        value["shape"] = deepcopy(contract["shape"])
    end
    foreach(item -> refresh_parameter_metadata!(item, contracts), values(value))
    return nothing
end
function refresh_parameter_metadata!(value::AbstractVector, contracts)
    foreach(item -> refresh_parameter_metadata!(item, contracts), value)
    return nothing
end
refresh_parameter_metadata!(value, contracts) = nothing

function refresh_session_parameters!(session, contracts)
    endpoints = Dict{String,Any}()
    for graph in get(session, "graphs", []), port in graph["ports"]
        get(port, "parameter", false) === true || continue
        contract = contracts[graph["node.name"]]["parameters"][port["name"]]
        for field in ("shape", "element-type")
            port[field] = deepcopy(contract[field])
        end
        endpoints[graph["node.name"] * ":" * port["name"]] = contract
    end
    # Parameter producer endpoints are bound by explicit session links, never by
    # a scientific schema or an instrument-specific node name.
    for link in get(session, "links", [])
        haskey(endpoints, link["input"]) || continue
        endpoints[link["output"]] = endpoints[link["input"]]
    end
    for field in ("sources", "sinks"), node in get(session, field, []), port in node["ports"]
        endpoint = node["node.name"] * ":" * port["name"]
        haskey(endpoints, endpoint) || continue
        for property in ("shape", "element-type")
            port[property] = deepcopy(endpoints[endpoint][property])
        end
    end
    return nothing
end

# Scientific/graph dependencies remain optional and extend these cold APIs.
function shack_hartmann_configuration end
function controller_graph end
function controller_storage end
function measure! end
function calibration_frame! end
function calibrate_hidden_modes end
include("calibration_bundle.jl")
include("calibration_recipe.jl")

end
