module PipeWireAORTCAOSExt

using PipeWireAORTC
import PipeWireAORTC: AOSOwner
import AdaptiveOpticsSim.Optics: Zemax
using AdaptiveOpticsSimPipeWireHIL: AdaptiveOpticsSimPipeWireHIL, PipeWireHILConfiguration

const Instruments = PipeWireAORTC.InstrumentConfiguration
const OpticsExt = Base.get_extension(PipeWireAORTC, :PipeWireAORTCOpticsExt)

include("aos/simulation_export.jl")
include("aos/pupil_output.jl")
include("aos/external_pupil_owner.jl")

end
