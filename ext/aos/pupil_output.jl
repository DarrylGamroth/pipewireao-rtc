module PupilOutput

import PipeWireAORTC
import AdaptiveOpticsSimPipeWireHIL.ExternalPupil: pack_pupil! as pack!
using AdaptiveOpticsSim.AlgorithmGraphs: external_pupil_contract
using PipeWireAO: NdArray

const IC = PipeWireAORTC.InstrumentConfiguration

function PipeWireAORTC.InstrumentExport.pupil_output_port_contract(
    path::AbstractString; settings = Dict(), simulation_graph = "production"
)
    declaration = IC.load_simulation(path)
    boundary = contract(declaration, IC.settings(declaration, settings); simulation_graph)
    return Dict(
        "schema" => boundary.schema,
        "shape" => collect(boundary.shape),
        "element-type" => string(NdArray.F32_LE),
        "layout" => "ROW_MAJOR",
    )
end

function contract(declaration, configured; simulation_graph = "production")
    output = IC.pupil_output(declaration, configured; simulation_graph)
    output === nothing && throw(ArgumentError("scientific pupil output is not declared"))
    optical = output.optical
    boundary = external_pupil_contract(;
        output.pupil_resolution,
        diameter_m = optical["diameter_m"],
        plane = optical["plane"],
        curvature = optical["curvature"],
        registration = optical["registration"],
    )
    PipeWireAORTC.Artifacts.checked_shape(boundary.shape, sizeof(Float32))
    return boundary
end

end
