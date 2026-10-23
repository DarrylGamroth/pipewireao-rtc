"""Cold simulator configuration and one-shot managed application replacement.

This is deployment tooling. RTC retains native session admission and
lifecycle authority; systemd retains process lifetime. No runtime control proxy
or frame-processing work is provided by this management interface.
"""
module SimulatorConfiguration

using JSON, UUIDs
import ..InstrumentConfiguration
import ..Common
import ..AOSOwner
import ..DeploymentConfiguration
import ..SessionRuntime
import ..SessionCLI
import ..SystemdOwners
import ..NativeSessionCodec
import ..NativeSessionDiscovery
import ..ConfigurationStoreCLI

const C = Common
const D = DeploymentConfiguration
const R = SessionRuntime
const PROTOCOL = "pipewireao.simulator-settings/1"
const MAX_REQUEST_BYTES = 64 * 1024
const MAX_REPLY_BYTES = 1024 * 1024
const TERMINAL = ("complete", "failed", "unknown")

public describe, start_rebuild, job, serve, main

include("simulator_configuration/settings.jl")
include("simulator_configuration/jobs.jl")
include("simulator_configuration/cli.jl")

end
