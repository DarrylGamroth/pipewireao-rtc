"""The headless RTC's sole serialized session policy.

Hsm handlers own lifecycle decisions. The application executes their bounded
effects outside dispatch; native callbacks transfer owned observations only.
Scientific graphs retain their separate processes and PipeWire data threads.
"""
module MediaSession

import Hsm
import Clocks
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
import ..DeploymentConfiguration
using PipeWireAO

"""Owned observations, applied by the session task after native dispatch.

Queued records implement `update!(session, event)`; the machine's submission
and completion functions dispatch their shared records directly. Records contain
copied data and must not retain borrowed pointers or mutable producer state.
The bounded cold-control queue accounts for retained Julia size; it makes no
allocation-free or real-time callback claim.
"""
abstract type AbstractEvent end

include("machine.jl")
include("controls.jl")
include("correction.jl")
include("journal.jl")
include("ingress.jl")

end
