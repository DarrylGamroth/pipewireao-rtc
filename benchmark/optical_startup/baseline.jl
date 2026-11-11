using PipeWireAORTC
options = PipeWireAORTC.AOSOwner.configuration(only(ARGS))
PipeWireAORTC.AOSOwner.requires_proper(options) && PipeWireAORTC.AOSOwner.load_instrument(:Proper)
include(joinpath(@__DIR__, "workload.jl"))
@time optical_workload(only(ARGS))
