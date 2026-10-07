# Source-local terminal helpers, tested in a fresh process with cached dependencies.
using PipeWireAODeployment, SHA
const ROOT = normpath(joinpath(@__DIR__, "../../.."))
const SOURCE = read(joinpath(ROOT,"deployment/julia/src/deploy.jl"),String)
const FIRST = findfirst("function _finalize_record!(",SOURCE).start
const LAST = findnext("\nfunction _run_locked(",SOURCE,FIRST).start-1
const IMPLEMENTATION = SOURCE[FIRST:LAST]
println("terminal_helpers_sha256=",bytes2hex(sha256(IMPLEMENTATION)))
Base.include_string(PipeWireAODeployment.Deployment,IMPLEMENTATION,"review_terminal_helpers.jl")
include(joinpath(ROOT,"deployment/julia/test/test_terminal_cleanup.jl"))
