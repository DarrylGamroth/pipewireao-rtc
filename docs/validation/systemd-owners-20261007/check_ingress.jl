# Run in a fresh Julia process for each selected source revision.
using PipeWireAODeployment, SHA
const ROOT = normpath(joinpath(@__DIR__, "../../.."))
const REVISION = only(ARGS)
const SOURCE = REVISION == "baseline" ? read(Cmd(Cmd(["git","show","dde0bf4:deployment/julia/src/deploy.jl"]);dir=ROOT),String) : read(joinpath(ROOT,"deployment/julia/src/deploy.jl"),String)
const FIRST = findfirst("function _stop_processes(",SOURCE).start
const LAST = findnext("\nfunction stop(deployment",SOURCE,FIRST).start-1
const IMPLEMENTATION = SOURCE[FIRST:LAST]
println("revision=", REVISION, " function_sha256=", bytes2hex(sha256(IMPLEMENTATION)))
Base.include_string(PipeWireAODeployment.Deployment, IMPLEMENTATION, "review_"*REVISION*"_stop_processes.jl")
include(joinpath(ROOT,"deployment/julia/test/test_ingress_cleanup.jl"))
