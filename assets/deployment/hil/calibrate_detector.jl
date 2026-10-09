#!/usr/bin/env julia
"""Cold acquisition of detector and reference offsets for the installed simulated plant."""
module HILDetectorCalibration

using AdaptiveOpticsSim
using AdaptiveOpticsSim.AlgorithmGraphs
import FilterGraphAlgorithms as FGA
using JSON3
using SHA
using TOML

const MAX_DARK_FRAMES = 4096

function parse_options(arguments)
    values = Dict{String,String}()
    allowed = ("--graph", "--profile", "--specification", "--output", "--dark-frames")
    iseven(length(arguments)) || error("options require a value")
    for index in 1:2:length(arguments)
        key = arguments[index]
        key in allowed || error("unknown option $key")
        haskey(values, key) && error("duplicate option $key")
        values[key] = arguments[index + 1]
    end
    for key in allowed[1:4]
        haskey(values, key) || error("missing $key")
    end
    profile = Symbol(values["--profile"])
    profile in (:classic, :copper) || error("profile must be classic or copper")
    samples = parse(Int, get(values, "--dark-frames", "256"))
    1 <= samples <= MAX_DARK_FRAMES || error("dark-frames must be in 1:$MAX_DARK_FRAMES")
    return (; graph=abspath(values["--graph"]), profile,
        specification=abspath(values["--specification"]),
        output=abspath(values["--output"]), dark_frames=samples)
end

function load_plant(profile::Symbol)
    if profile === :classic
        return @eval begin
            import REVOLTClassicSim
            REVOLTClassicSim
        end
    elseif profile === :copper
        return @eval begin
            import REVOLTCopperSim
            REVOLTCopperSim
        end
    end
    error("unsupported plant $profile")
end

"""Use the same nearest, ties-to-even UInt16 encoding as the HIL transport."""
function encode_adc!(output::AbstractMatrix{UInt16}, frame::AbstractMatrix)
    axes(output) == axes(frame) || throw(DimensionMismatch("ADC frame axes differ"))
    for index in eachindex(output, frame)
        value = frame[index]
        isfinite(value) && 0 <= value <= typemax(UInt16) || error("invalid UInt16 ADC sample")
        output[index] = round(UInt16, value)
    end
    return output
end

"""Prepare a separate production detector with zero incident photon rate."""
function prepare_dark_graph(detector)
    config = detector.config
    config.binning == 1 || error("calibration requires detector binning=1")
    photons = zeros(Float32, config.rows, config.columns)
    definition = algorithm_graph((detector,); name=:simulated_detector_dark,
        inputs=(graph_input(:zero_photon_rate, :detector => :photon_rate, photons),),
        outputs=(graph_output(:frame, :detector => :frame),))
    graph = prepare_algorithm_graph(definition;
        target=AdaptiveOpticsSim.Backends.HostComputeDevice(), execution=StreamGraphExecution())
    return (; graph, photons)
end

"""Average encoded ADC acquisitions without resetting or sharing detector RNG state."""
function acquire_dark(detector; samples::Int=256)
    1 <= samples <= MAX_DARK_FRAMES || error("invalid dark sample count")
    prepared = prepare_dark_graph(detector)
    frame = graph_output(prepared.graph, :frame)
    encoded = similar(frame, UInt16)
    mean_adc = zeros(Float64, size(frame))
    squared_deviation = zeros(Float64, size(frame))
    for sample in 1:samples
        step_graph!(prepared.graph)
        encode_adc!(encoded, frame)
        for index in eachindex(mean_adc, encoded)
            delta = Float64(encoded[index]) - mean_adc[index]
            mean_adc[index] += delta / sample
            squared_deviation[index] += delta * (Float64(encoded[index]) - mean_adc[index])
        end
    end
    # Population standard deviation of the finite retained acquisition window.
    std_adc = sqrt.(max.(squared_deviation ./ samples, 0.0))
    return (; background=Float32.(mean_adc), std_adc,
        acquisition_sequence=graph_step_sequence(prepared.graph))
end

function installed_definition(path::AbstractString, profile::Symbol)
    plant = load_plant(profile)
    Base.invokelatest(plant.command_count) == 277 || error("plant command count must be 277")
    bindings = (; pdm_command=zeros(Float32, 277),
        pdm_actuator_grid_indices=Base.invokelatest(plant.actuator_grid_indices))
    document = TOML.parsefile(path)
    sensor = profile === :classic ? "shwfs" : "pwfs"
    expected = ["atmosphere", "pdm", "pupil_opd_composition", sensor, "detector"]
    [node["name"] for node in document["nodes"]] == expected ||
        error("installed plant must have the maintained five-node topology")
    raw_detector = document["nodes"][5]
    expected_type = profile === :classic ? "cmos_detector_acquisition_f32" : "emccd_detector_acquisition_f32"
    raw_detector["type"] == expected_type || error("unexpected installed detector type")
    definition = load_algorithm_graph(path; bindings)
    definition.nodes[5].config.binning == 1 || error("calibration requires detector binning=1")
    return (; definition, document, sensor=Symbol(sensor))
end

"""Keep installed optical nodes and ADC settings, disabling only calibration noise/charge."""
function prepare_flat_graph(installed, profile::Symbol)
    production = installed.definition
    config = Dict(Symbol(key) => value for (key, value) in installed.document["nodes"][5]["config"])
    merge!(config, Dict(:dark_current_e_per_pixel_s => 0,
        :photon_noise => false, :readout_noise => false, :readout_noise_e => 0))
    detector = if profile === :classic
        merge!(config, Dict(:column_readout_noise_e => 0, :row_readout_noise_e => 0))
        cmos_detector_acquisition_node(:detector; config..., T=Float32)
    else
        merge!(config, Dict(:excess_noise_factor => 1,
            :clock_induced_charge_e_per_pixel_frame => 0))
        emccd_detector_acquisition_node(:detector; config..., T=Float32)
    end
    resolution = Int(installed.document["nodes"][3]["config"]["resolution"])
    uncompensated_opd = zeros(Float32, resolution, resolution)
    sensor = installed.sensor
    definition = algorithm_graph((production.nodes[2:4]..., detector);
        name=:installed_simulated_flat,
        inputs=(first(production.inputs), graph_input(:uncompensated_opd,
            :pupil_opd_composition => :uncompensated_opd, uncompensated_opd)),
        outputs=(graph_output(:frame, :detector => :frame),),
        links=(link(:pdm => :surface_opd, :pupil_opd_composition => :surface_opd),
            link(:pupil_opd_composition => :pupil_opd, sensor => :opd),
            link(sensor => :photon_rate, :detector => :photon_rate)),
        parameters=production.parameters)
    return prepare_algorithm_graph(definition;
        target=AdaptiveOpticsSim.Backends.HostComputeDevice(), execution=StreamGraphExecution())
end

artifact_path(base, specification) = normpath(joinpath(base, specification["path"]))

function validate_artifact(specification, shape; units=nothing)
    Tuple(specification["shape"]) == shape || error("artifact shape differs from $shape")
    specification["element_type"] == "F32_LE" || error("artifact must be F32_LE")
    specification["layout"] == "ROW_MAJOR" || error("artifact must be ROW_MAJOR")
    units === nothing || specification["units"] == units || error("artifact units must be $units")
    specification["path"] isa AbstractString && !isempty(specification["path"]) || error("empty artifact path")
    return specification
end

function read_artifact(base, specification, shape)
    validate_artifact(specification, shape)
    bytes = read(artifact_path(base, specification))
    length(bytes) == 4 * prod(shape) || error("artifact byte count differs from declared shape")
    values = reinterpret(Float32, ltoh.(copy(reinterpret(UInt32, bytes))))
    all(isfinite, values) || error("artifact contains nonfinite values")
    return permutedims(reshape(values, reverse(shape)))
end

function atomic_write(writer, path)
    mkpath(dirname(path))
    temporary, stream = mktemp(dirname(path))
    try
        writer(stream)
        close(stream)
        mv(temporary, path; force=true)
    finally
        isopen(stream) && close(stream)
        isfile(temporary) && rm(temporary)
    end
    return path
end

function write_artifact(base, name, specification, values)
    validate_artifact(specification, size(values))
    transport_values = Float32.(values)
    all(isfinite, transport_values) || error("generated artifact contains nonfinite Float32 values")
    path = artifact_path(base, specification)
    atomic_write(path) do stream
        for value in vec(permutedims(transport_values))
            write(stream, htol(reinterpret(UInt32, value)))
        end
    end
    return Dict("name" => name, "path" => specification["path"],
        "shape" => collect(size(values)),
        "element_type" => "F32_LE", "layout" => "ROW_MAJOR", "units" => specification["units"],
        "sha256" => bytes2hex(sha256(read(path))))
end

function reference_slopes(flat_adc, background, descriptor, base)
    rows, columns = size(flat_adc)
    (descriptor["detector_height"], descriptor["detector_width"]) == (rows, columns) ||
        error("SH detector geometry differs from installed detector")
    subrows = Int(descriptor["subaperture_height"])
    subcolumns = Int(descriptor["subaperture_width"])
    origins = [Int.(origin) for origin in descriptor["subaperture_origins"]]
    count = length(origins)
    count > 0 || error("SH calibration requires subapertures")
    active = Bool.(descriptor["active"])
    length(active) == count || error("SH active extent differs")
    coordinates = read_artifact(base, descriptor["coordinates"], (subrows * subcolumns, 2))
    thresholds = read_artifact(base, descriptor["thresholds"], (count, 2))
    pixel = FGA.prepare_algorithm(FGA.PixelCalibrationU16F32,
        FGA.PixelCalibrationU16F32Configuration(; image_rows=rows, image_columns=columns,
            initial_flat=nothing, initial_background=nothing))
    FGA.replace_parameter!(pixel, :background, background)
    FGA.replace_parameter!(pixel, :flat, ones(Float32, rows, columns))
    calibrated = zeros(Float32, rows, columns)
    FGA.process!(calibrated, pixel, flat_adc)
    sensing = FGA.prepare_algorithm(FGA.ShackHartmannImageF32,
        FGA.ShackHartmannImageF32Configuration(; image_rows=rows, image_columns=columns,
            image_schema=FGA.CALIBRATED_PIXELS_V1, subaperture_rows=subrows,
            subaperture_columns=subcolumns, subaperture_count=count,
            initial_subaperture_origins=origins, coordinate_scale=1.0f0,
            pixel_threshold=0.0f0, flux_threshold=0.0f0,
            reference_slopes=zeros(Float32, 2 * count), active))
    FGA.replace_parameter!(sensing, :coordinates, coordinates)
    FGA.replace_parameter!(sensing, :thresholds, thresholds)
    slopes = zeros(Float32, count, 2)
    flux = zeros(Float32, count)
    validity = fill(false, count)
    FGA.process!(slopes, flux, validity, sensing, calibrated)
    # Verify centering through the same public operation, without changing validity.
    FGA.replace_parameter!(sensing, "reference-slopes", slopes)
    residual = similar(slopes)
    FGA.process!(residual, flux, validity, sensing, calibrated)
    diagnostics = Dict("flux_adc" => flux, "validity" => validity, "active" => active,
        "invalid_subapertures_zero_based" => findall(!, validity) .- 1,
        "invalid_active_subapertures_zero_based" => findall(active .& .!validity) .- 1,
        "valid_count" => sum(validity),
        "all_active_subapertures_valid" => all(validity[active]),
        "invalid_reference_policy" => "estimator returns zero; offsets are not calibrated for invalid subapertures",
        "reference_residual_max_abs" => maximum(abs, residual),
        "estimator" => "FilterGraphAlgorithms.ShackHartmannImageF32",
        "reference_order" => "pair-interleaved x,y in descriptor subaperture order",
        "flat_policy" => "zero OPD, zero PDM command, noiseless installed detector; simulated dark subtracted")
    return (; slopes, diagnostics)
end

function calibrate(options)
    specification = JSON3.read(read(options.specification, String), Dict{String,Any})
    specification["version"] == 1 || error("unsupported calibration descriptor version")
    specification["profile"] == String(options.profile) || error("descriptor profile differs")
    base = dirname(options.specification)
    installed = installed_definition(options.graph, options.profile)
    detector = installed.definition.nodes[5]
    shape = (detector.config.rows, detector.config.columns)
    expected_shape = options.profile === :classic ? (352, 352) : (64, 64)
    shape == expected_shape || error("installed detector geometry differs from profile")
    artifacts = specification["artifacts"]
    validate_artifact(artifacts["background"], shape; units="ADC")
    dark = acquire_dark(detector; samples=options.dark_frames)
    generated = [write_artifact(base, "background", artifacts["background"], dark.background)]
    flat_diagnostics = nothing
    if options.profile === :classic
        validate_artifact(artifacts["reference_slopes"], (length(specification["shack_hartmann"]["active"]), 2);
            units="detector coordinate")
        flat_graph = prepare_flat_graph(installed, options.profile)
        step_graph!(flat_graph)
        flat_adc = zeros(UInt16, shape)
        encode_adc!(flat_adc, graph_output(flat_graph, :frame))
        if haskey(artifacts, "optical_flat")
            validate_artifact(artifacts["optical_flat"], shape; units="ADC")
            push!(generated, write_artifact(base, "optical_flat", artifacts["optical_flat"], Float32.(flat_adc)))
        end
        reference = reference_slopes(flat_adc, dark.background, specification["shack_hartmann"], base)
        push!(generated, write_artifact(base, "reference_slopes", artifacts["reference_slopes"], reference.slopes))
        flat_diagnostics = reference.diagnostics
    else
        validate_artifact(artifacts["system_flat"], (277,); units="micrometre OPD")
        push!(generated, write_artifact(base, "system_flat", artifacts["system_flat"], zeros(Float32, 277)))
    end
    report = Dict("version" => 1, "profile" => String(options.profile),
        "model_sha256" => bytes2hex(sha256(read(options.graph))),
        "specification_sha256" => bytes2hex(sha256(read(options.specification))),
        "dark_frames" => options.dark_frames, "acquisition_sequence" => dark.acquisition_sequence,
        "target" => "CPU HostComputeDevice", "detector_config" => installed.document["nodes"][5]["config"],
        "independent_detector_owner" => true, "rng_seed" => detector.config.rng_seed,
        "rng_reset_between_samples" => false, "production_rng_consumed" => false,
        "electronic_bias_model" => "unconfigured; zero additive electronic bias",
        "electronic_bias_configured" => false, "dark_incident_photon_rate" => 0,
        "dark_detector_config_preserved" => true,
        "adc_encoding" => "UInt16 nearest ties-to-even before averaging",
        "background_average_adc_range" => collect(extrema(dark.background)),
        "background_population_std_adc_range" => collect(extrema(dark.std_adc)),
        "standard_deviation_convention" => "population, divisor dark_frames",
        "flat_diagnostics" => flat_diagnostics,
        "artifacts" => Dict(record["name"] => record for record in generated),
        "limitations" => ["finite noisy dark estimate", "provisional plant; no convergence claim",
            "reconstructor, projections, controller coefficients and thresholds are unchanged"])
    atomic_write(options.output) do stream
        JSON3.write(stream, report)
        write(stream, '\n')
    end
    return report
end

main(arguments=ARGS) = calibrate(parse_options(arguments))

end # module

if abspath(PROGRAM_FILE) == @__FILE__
    HILDetectorCalibration.main()
end
