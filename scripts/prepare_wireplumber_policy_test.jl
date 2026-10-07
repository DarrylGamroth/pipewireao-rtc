#!/usr/bin/env julia
# Development-only refresh of the runner; keep the accepted science bytes.
using PipeWireAODeployment
const D=PipeWireAODeployment.Deployment
const C=PipeWireAODeployment.Common
const E=PipeWireAODeployment.HILExport
length(ARGS)==3 || error("expected INSTALLED_BASE RUNNER_BINARY FRESH_OUTPUT")
base,binary,output=abspath.(ARGS)
!ispath(output) && !islink(output) || error("Fresh output required")
spec=D.profile(joinpath(base,"deployment.conf"),"/opt/pipewireao")
original=copy(spec["artifacts"])
cp(base,output;follow_symlinks=true)
cp(binary,joinpath(output,"bin/pipewireao-rtc");force=true)
chmod(joinpath(output,"bin/pipewireao-rtc"),0o755)
provenance=C.read_json(joinpath(output,"provenance.json"))
revision=strip(read(`git -C $(@__DIR__) rev-parse HEAD`,String))
provenance["connection_policy_test"]=Dict("base"=>base,
    "base_descriptor_sha256"=>C.sha256_file(joinpath(base,"deployment.conf")),
    "previous_runner_revision"=>provenance["rtc_revision"],
    "runner_sha256"=>C.sha256_file(binary),"source_revision"=>revision,
    "scope"=>"required-object monitor update; all science and owner bytes retained")
provenance["rtc_revision"]=revision
C.write_json(joinpath(output,"provenance.json"),provenance)
spec["artifacts"]=E._package_artifacts(output)
Set(keys(original))==Set(keys(spec["artifacts"])) || error("Artifact set changed")
for (path,digest) in original
    path in ("bin/pipewireao-rtc","provenance.json") && continue
    spec["artifacts"][path]==digest || error("Unexpected artifact change: $path")
end
C.write_json(joinpath(output,"deployment.conf"),spec)
D.profile(joinpath(output,"deployment.conf"),"/opt/pipewireao")
println(joinpath(output,"deployment.conf"))
