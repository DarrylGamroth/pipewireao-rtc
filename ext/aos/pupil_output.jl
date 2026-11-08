module PupilOutput

import PipeWireAORTC
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

"One-based host snapshot [x,y] becomes [quantity,y,x]; no display transform."
function pack!(
    packet::Array{Float32,3}, opd::AbstractMatrix{Float32}, amplitude::Matrix{Float32}
)
    Base.require_one_based_indexing(opd)
    axes(opd) == axes(amplitude) && size(packet) == (2, size(opd, 2), size(opd, 1)) ||
        throw(DimensionMismatch("scientific pupil packet axes differ"))
    for x in axes(opd, 1), y in axes(opd, 2)
        value = opd[x, y]
        isfinite(value) || throw(ArgumentError("scientific pupil OPD must be finite"))
        packet[1, y, x] = value
        packet[2, y, x] = amplitude[x, y]
    end
    return packet
end

end
