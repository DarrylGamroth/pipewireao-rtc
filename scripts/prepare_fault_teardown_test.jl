#!/usr/bin/env julia
# Development-only package refresh; retain all accepted scientific bytes.
using PipeWireAODeployment
const D=PipeWireAODeployment.Deployment
const C=PipeWireAODeployment.Common
const E=PipeWireAODeployment.HILExport
length(ARGS)==2 || error("expected INSTALLED_BASE FRESH_OUTPUT")
base,output=abspath.(ARGS)
!ispath(output) && !islink(output) || error("Fresh output required")
spec=D.profile(joinpath(base,"deployment.conf"),"/opt/pipewireao")
original=copy(spec["artifacts"])
cp(base,output;follow_symlinks=true)
source=normpath(joinpath(@__DIR__,".."))
updates=Dict(
    "julia/src/deploy.jl"=>"deployment/julia/src/deploy.jl",
    "hil/simulator_owner.jl"=>"deployment/hil/simulator_owner.jl",
    "julia/assets/deployment/hil/simulator_owner.jl"=>"deployment/hil/simulator_owner.jl")
for (destination,path) in updates
    isfile(joinpath(output,destination)) || error("Missing existing artifact: $destination")
    cp(joinpath(source,path),joinpath(output,destination);force=true)
end
provenance=C.read_json(joinpath(output,"provenance.json"))
revision=strip(read(`git -C $source rev-parse HEAD`,String))
provenance["fault_teardown_test"]=Dict("base"=>base,
    "base_descriptor_sha256"=>C.sha256_file(joinpath(base,"deployment.conf")),
    "source_revision"=>revision,"source_hashes"=>Dict(path=>C.sha256_file(joinpath(source,path)) for path in values(updates)),
    "scope"=>"shutdown coordination and private report warmup; science/runner bytes retained")
C.write_json(joinpath(output,"provenance.json"),provenance)
spec["artifacts"]=E._package_artifacts(output)
Set(keys(original))==Set(keys(spec["artifacts"])) || error("Artifact set changed")
for (path,digest) in original
    (haskey(updates,path) || path=="provenance.json") && continue
    spec["artifacts"][path]==digest || error("Unexpected artifact change: $path")
end
C.write_json(joinpath(output,"deployment.conf"),spec)
D.profile(joinpath(output,"deployment.conf"),"/opt/pipewireao")
println(joinpath(output,"deployment.conf"))
