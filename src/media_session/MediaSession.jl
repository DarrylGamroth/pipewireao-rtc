"""The headless RTC's sole serialized session policy.

Hsm handlers own lifecycle decisions. The application executes their bounded
effects outside dispatch; native callbacks transfer owned observations only.
Scientific graphs retain their separate processes and PipeWire data threads.
"""
module MediaSession

import Hsm
using Hsm: @hsmdef, @statedef, @on_initial, @on_event
import ..Common
import ..RunnerCodec
import ..SessionCodec
import ..ControlCodec
import ..ControlClient
import ..OwnerBootstrapCodec
import ..AcquisitionLifecycleCodec
import ..SourceControl
import ..ParameterSource
using PipeWireAO

"Owned native observations, applied by the session owner after loop dispatch."
abstract type Event end

include("machine.jl")
include("controls.jl")
include("correction.jl")
include("journal.jl")
include("ingress.jl")

end
