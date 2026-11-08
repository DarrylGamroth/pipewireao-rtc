module ExternalPupilOwner

using PipeWireAO, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL
using AdaptiveOpticsSim.AlgorithmGraphs
using AdaptiveOpticsSim.AlgorithmGraphs: external_pupil_contract
using SHA
import PipeWireAORTC
import PipeWireAORTC.InstrumentExport: prepare_external_pupil_ports
const IC = PipeWireAORTC.InstrumentConfiguration
using AdaptiveOpticsSimPipeWireHIL.ExternalPupil: execution_properties

function pupil_contract(declaration, configured)
    optical = declaration.instrument.document["optical_input"]
    return external_pupil_contract(;
        pupil_resolution = configured["pupil_resolution"],
        diameter_m = optical["diameter_m"],
        plane = optical["plane"],
        curvature = optical["curvature"],
        registration = optical["registration"],
        wavelength_um = haskey(configured, "spectra") ? nothing :
                        configured["wavelength_um"],
    )
end

function spectral_properties(configured, name)
    spectrum =
        haskey(configured, "spectra") ? configured["spectra"][string(name)] :
        Dict(
            "wavelength_um" => configured["wavelength_um"],
            "fractional_bandwidth" => 0,
            "samples" => 1,
            "filter" => "none",
        )
    properties = Dict(
        "optics.central-wavelength-m" => string(spectrum["wavelength_um"] * 1e-6),
        "optics.fractional-bandwidth" => string(spectrum["fractional_bandwidth"]),
        "optics.spectral-samples" => string(spectrum["samples"]),
        "optics.filter" => string(spectrum["filter"]),
    )
    spectrum["fractional_bandwidth"] == 0 &&
        (properties["optics.wavelength-m"] = string(spectrum["wavelength_um"] * 1e-6))
    return properties
end

function sensor_contract(declaration, configured, plant, name, identity)
    graph = getproperty(plant.graphs, name)
    observation = getproperty(plant.observations, name)
    sampling = optical_sampling_m(
        AlgorithmGraphs.prepared_graph_node(graph, observation.sampling_node)
    )
    response = get(observation, :response, nothing)
    image =
        response === nothing ? graph_output(graph, observation.output) :
        graph_output(response.graph, response.output)
    schema =
        response === nothing ?
        "org.adaptiveopticssim.optical-intensity/sha256-" *
        bytes2hex(sha256(join((identity, name, sampling, size(image)), "\n"))) *
        "/1" : response.frame_schema
    path = declaration.instrument.document["optical_paths"][string(name)]
    sensor = declaration.instrument.document["wavefront_sensors"][path["sensor"]]
    haskey(sensor, "detector_shape") &&
        Tuple(sensor["detector_shape"]) != size(image) &&
        throw(DimensionMismatch("sensor detector_shape differs from its optical product"))
    get(sensor, "expected_schema", schema) == schema ||
        throw(ArgumentError("sensor expected_schema differs from its optical product"))
    execution = execution_properties(plant, name)
    response === nothing ||
        merge!(execution, execution_properties(response.graph; prefix = "detector."))
    if response !== nothing
        acquisition = get(sensor, "acquisition", Dict())
        execution["detector.roi-origin-known"] = string(haskey(acquisition, "roi_origin"))
        execution["detector.roi-shape"] = join(size(image), ",")
        if haskey(acquisition, "roi_origin")
            execution["detector.roi-origin"] = join(acquisition["roi_origin"], ",")
        end
    end
    if hasproperty(observation, :chopping)
        merge!(
            execution,
            execution_properties(
                plant, name; unfringed = true, prefix = "optics.unfringed."
            ),
        )
    end
    return (;
        image,
        schema,
        properties = merge(
            spectral_properties(configured, name),
            execution,
            Dict(
                "optics.model-sha256" => String(chopprefix(identity, "sha256:")),
                "optics.branch" => string(name),
                "optics.sampling-m" => string(sampling),
                "optics.axis-order" => "y,x",
                "optics.pts-units" => "simulation_nanoseconds",
                "optics.exposure-duration-ns" =>
                    string(getproperty(plant.exposures, name).duration_ns),
                "optics.units" =>
                    response === nothing ? "relative_intensity" :
                    "declared_detector_output",
                "detector.name" => sensor["detector"]["name"],
            ),
        ),
    )
end

function prepare_external_pupil_ports(
    path;
    settings = NamedTuple(),
    target = Backends.HostComputeDevice(),
    chopping = NamedTuple(),
    check = () -> nothing,
)
    declaration = IC.load_simulation(path)
    if get(get(declaration.document, "optical_model", Dict()), "format", nothing) == "zemax"
        AdaptiveOpticsSim.Optics.Zemax.validate_provenance(declaration.directory)
    end
    configured = IC.settings(declaration, settings)
    identity = IC.prescription_identity(declaration, configured)
    check()
    plant = IC.prepare_external_pupil(path; settings, target, chopping)
    # Establish immutable optical sampling without consuming detector draws.
    foreach(step_graph!, values(plant.graphs))
    sensors = map(keys(plant.graphs)) do name
        sensor_contract(declaration, configured, plant, name, identity)
    end
    reset_external_pupil!(plant)
    check()
    return (;
        plant,
        declaration,
        configured,
        identity,
        chopping,
        pupil = pupil_contract(declaration, configured),
        sensors = NamedTuple{keys(plant.graphs)}(sensors),
    )
end

function PipeWireAORTC.InstrumentExport.external_pupil_port_contracts(
    path; settings = NamedTuple(), chopping = NamedTuple()
)
    science = prepare_external_pupil_ports(path; settings, chopping)
    contract(format, schema) =
        Dict("shape" => collect(format), "element-type" => "F32_LE", "schema" => schema)
    return Dict(
        "pupil" => contract(science.pupil.shape, science.pupil.schema),
        "sensors" => Dict(
            string(name) => contract(size(sensor.image), sensor.schema) for
            (name, sensor) in pairs(science.sensors)
        ),
    )
end

end
