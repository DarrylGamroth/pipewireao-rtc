using PipeWireAODeployment
const P = PipeWireAODeployment
const C = P.Common
include(joinpath(P.package_root(), "wireplumber_install.jl"))
source = "/tmp/rtc-wireplumber-jfg-20261007-package"
mktempdir() do root
    binary = realpath(Sys.which("true"))
    exported = joinpath(root, "calibration")
    P.CalibrationExport.export_package((; base_package=source, output=exported,
        pipewire_prefix="/opt/pipewireao", deployment=true,
        calibration_binary=binary, illumination="lamp", calibration_stage="interaction"))
    spec = P.DeploymentConfiguration.profile(joinpath(exported, "deployment.conf"), "/opt/pipewireao")
    @assert haskey(spec, "session-manager")
    @assert isfile(joinpath(exported, "wireplumber/scripts/ao/session.lua"))
    installed = WirePlumberInstall.install((; package=exported,
        destination=joinpath(root, "installed"), pipewire_prefix="/opt/pipewireao"))
    @assert isfile(joinpath(installed, "systemd/pipewireao-session@.service"))
    @assert !ispath(joinpath(installed, "bin/pipewireao-rtc"))
    println("calibration export to one-shot install passed with sealed inherited WirePlumber assets")
end
