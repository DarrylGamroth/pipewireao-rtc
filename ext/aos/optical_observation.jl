module OpticalObservation

import PipeWireAORTC
using AdaptiveOpticsSim
using AdaptiveOpticsSim.AlgorithmGraphs:
    AlgorithmGraphDefinition, ShackHartmannRateNodeConfig, PyramidRateNodeConfig

const Optics = AdaptiveOpticsSim.Optics
const ZERO_PADDING = 2
const RMS_SHAPE = (1, 2)

sensor_configuration(config) = nothing
sensor_configuration(config::ShackHartmannRateNodeConfig) = config
sensor_configuration(config::PyramidRateNodeConfig) = config
atmosphere_output(output) = false
atmosphere_output(
    ::AdaptiveOpticsSim.AlgorithmGraphs.GraphOutputDefinition{:atmosphere_opd}
) = true
function guide_sensor(nodes::Tuple)
    sensors = filter(!isnothing, map(node -> sensor_configuration(node.config), nodes))
    length(sensors) == 1 ||
        throw(ArgumentError("optical observation needs exactly one declared guide sensor"))
    return only(sensors)
end

default_imaging() = (; source = nothing, zero_padding = ZERO_PADDING)

function imaging_configuration(declaration)
    haskey(declaration.document, "imaging") || return default_imaging()
    imaging = declaration.document["imaging"]
    source = declaration.document["sources"][imaging["source"]]
    return (;
        source = Optics.Source(
            band = Symbol(source["source_band"]),
            magnitude = source["source_magnitude"],
            wavelength = source["source_wavelength_m"],
            separation_arcsec = source["source_separation_arcsec"],
            position_angle_deg = source["source_position_angle_deg"],
            T = Float32,
        ),
        zero_padding = Int(get(imaging, "zero_padding", ZERO_PADDING)),
    )
end

imaging_source(::Nothing, config) = config.source
function imaging_source(source, config)
    source_xy = Optics.coordinates_xy_arcsec(source)
    guide_xy = Optics.coordinates_xy_arcsec(config.source)
    # Source construction converts polar angles in Float32; equivalent signed
    # and periodic representations may differ by a few rounding units.
    tolerance = 8eps(Float32) * max(hypot(source_xy...), hypot(guide_xy...))
    hypot(source_xy[1] - guide_xy[1], source_xy[2] - guide_xy[2]) <= tolerance || throw(
        ArgumentError(
            "imaging source direction must match the guide source of the composed pupil OPD",
        ),
    )
    return source
end

"Describe the observation boundary from cold typed sensor configuration alone."
function port_contracts(nodes::Tuple; atmosphere::Bool, imaging = default_imaging())
    config = guide_sensor(nodes)
    imaging_source(imaging.source, config)
    resolution = config.telescope.resolution
    focal_resolution = Base.checked_mul(resolution, imaging.zero_padding)
    contract(shape, name) = Dict(
        "shape" => collect(shape),
        "element-type" => PipeWireAORTC.Schemas.declaration(name)["wire_type"],
    )
    result = Dict(
        "focal-image" =>
            contract((focal_resolution, focal_resolution), "focal_photon_rate"),
        "residual-wavefront" => contract((resolution, resolution), "residual_pupil_opd_nm"),
    )
    atmosphere && (result["wavefront-rms"] = contract(RMS_SHAPE, "pupil_opd_rms_nm"))
    return result
end
port_contracts(definition::AlgorithmGraphDefinition; imaging = default_imaging()) =
    port_contracts(
        definition.nodes; atmosphere = any(atmosphere_output, definition.outputs), imaging
    )

end
