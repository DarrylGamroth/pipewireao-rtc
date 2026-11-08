module PipeWireAORTCAOSExt

using PipeWireAORTC
import PipeWireAORTC: AOSOwner
using AdaptiveOpticsSim
using AdaptiveOpticsSim.AlgorithmGraphs
using AdaptiveOpticsSimPipeWireHIL
using PipeWireAO
using YAML

const Backends = AdaptiveOpticsSim.Backends

include("aos/optical_observation.jl")
include("aos/optical_model_paths.jl")

"Compose AOS scientific factories with application-relative optical model paths."
configured_graph_node_types(directory = nothing) =
    instrument_optical_factories(builtin_graph_node_types(), directory)

include("aos/instruments.jl")
include("aos/simulation_export.jl")
include("aos/pupil_output.jl")

function copy_to_target(device, values)
    destination = Backends.allocate_device_array(device, eltype(values), size(values)...)
    copyto!(destination, values)
    return destination
end

include("aos/external_pupil_owner.jl")

end
