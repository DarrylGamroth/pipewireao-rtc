using PipeWireAODeployment
const P = PipeWireAODeployment
const C = P.Common
source = "/tmp/rtc-wireplumber-jfg-20261007-package"
include(joinpath(P.package_root(), "wireplumber_install.jl"))
mktempdir() do root
    package = joinpath(root, "package")
    cp(source, package; follow_symlinks=true)
    P.ScienceExport.copy_deployment_runtime(package)
    spec = C.read_json(joinpath(package, "deployment.conf"))
    spec["artifacts"] = P.HILExport._package_artifacts(package)
    C.write_json(joinpath(package, "deployment.conf"), spec)
    P.DeploymentConfiguration.profile(joinpath(package, "deployment.conf"), "/opt/pipewireao")
    for relative in ("bin/pipewireao-rtc", "bin/pipewireao-rtc-deploy",
                     "bin/pipewireao-rtc@.service.in", "pipewireao-rtc@.service.in",
                     "julia/src/deploy.jl", "julia/src/native_supervisor_client.jl",
                     "julia/deploy_cli.jl")
        @assert !ispath(joinpath(package, relative)) relative
    end
    installed = WirePlumberInstall.install((; package,
        destination=joinpath(root, "installed"), pipewire_prefix="/opt/pipewireao"))
    @assert isfile(joinpath(installed, "systemd/pipewireao-session@.service"))
    @assert isfile(joinpath(installed, "bin/pipewireao-rtc-session"))
    @assert !ispath(joinpath(installed, "bin/pipewireao-rtc"))
    println("fresh sealed package and one-shot install pass; no coordinator artifact")
end
