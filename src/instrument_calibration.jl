"""Cold preparation of command completion, allocation and calibration artifacts."""
module InstrumentCalibration

using LinearAlgebra, SHA, YAML
import ..Common
import ..Artifacts
import ..InstrumentConfiguration
import ..GraphOwner
import ..DeploymentConfiguration
import ..ScienceExport

public digest, source_completion, read_parameters, write_fits, heart_completion,
    controlled_rows, central_completion, allocation_parameters, replace_dimensions!,
    require_prepared_application, shack_hartmann_configuration,
    controller_graph, controller_storage, measure!, calibration_frame!

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
        write(file, ndims(values) == 1 ? values : permutedims(values))
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
    return parameters
end

"Update declared controller dimensions and artifacts in a prepared application."
function replace_dimensions!(application, parameters, n; measurement_count, command_limits=nothing)
    n > 0 && measurement_count > 0 || throw(ArgumentError("controller dimensions must be positive"))
    if command_limits !== nothing
        isfinite(command_limits.lower) && isfinite(command_limits.upper) &&
            command_limits.lower <= command_limits.upper || throw(ArgumentError("invalid command limits"))
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
        if name == "pdm-command" && command_limits !== nothing
            config["command_limits"] = [Float64(command_limits.lower), Float64(command_limits.upper)]
        end
    end
    ScienceExport.write_spa_config(graph_path, graph)
    path = joinpath(application, "rtc", "parameters.conf")
    document = DeploymentConfiguration.decode(path, get(ENV, "PIPEWIREAO_PREFIX", "/opt/pipewireao"))
    for entry in document["parameters"]
        array = parameters[Symbol(entry["port"])]
        write_fits(joinpath(dirname(path), entry["path"]), array)
    end
    simulation = DeploymentConfiguration.decode(joinpath(application, "simulation.conf"),
        get(ENV, "PIPEWIREAO_PREFIX", "/opt/pipewireao"))
    instrument_path = DeploymentConfiguration.relative_asset(application, simulation["plant"]["definition"])
    instrument = DeploymentConfiguration.decode(instrument_path,
        get(ENV, "PIPEWIREAO_PREFIX", "/opt/pipewireao"))
    dimensions = get!(instrument, "dimensions", Dict{String,Any}())
    for name in ("controller_command_count", "active_vdm_count", "state_length")
        dimensions[name] = n
    end
    Common.write_json(instrument_path, instrument; atomic=true)
    InstrumentConfiguration.prepare_publication(application)
    session_path = joinpath(application, "rtc", "session.conf.in")
    session = DeploymentConfiguration.decode(session_path, get(ENV, "PIPEWIREAO_PREFIX", "/opt/pipewireao"))
    update_reconstructor!(session, n, measurement_count)
    Common.write_json(session_path, session)
    profile_path = joinpath(application, "gui", "operator-views.yaml")
    profile = Common.read_yaml(profile_path)
    for parameter in profile["parameter"]
        parameter["parameter"] == "reconstructor" && (parameter["shape"] = [n, measurement_count])
    end
    YAML.write_file(profile_path, profile)
    return nothing
end

function update_reconstructor!(value::AbstractDict, n, measurement_count)
    if get(value, "schema", nothing) == "org.calculon.ao.shwfs-reconstructor/1"
        value["shape"] = [n, measurement_count]
    end
    foreach(item -> update_reconstructor!(item, n, measurement_count), values(value))
    return nothing
end
function update_reconstructor!(value::AbstractVector, n, measurement_count)
    foreach(item -> update_reconstructor!(item, n, measurement_count), value)
    return nothing
end
update_reconstructor!(value, n, measurement_count) = nothing

# Scientific/graph dependencies remain optional and extend these cold APIs.
function shack_hartmann_configuration end
function controller_graph end
function controller_storage end
function measure! end
function calibration_frame! end

end
