using PipeWireAO, PipeWireAODeployment
@assert Base.pkgversion(PipeWireAO)==v"0.6.17"
root = dirname(pathof(PipeWireAODeployment))
for name in ("native_owner_bootstrap_sealed", "native_owner_bootstrap", "native_owner_bootstrap_idle", "native_control_endpoint", "native_control_endpoint_faults")
    fixture=Module(gensym(Symbol(name)))
    Core.eval(fixture, :(include(path) = Base.include($fixture, path)))
    Base.include(fixture,joinpath(dirname(root),"test",name*".jl"))
end
println("MERGED_SDK_RTC_REGRESSION_COMPLETE")
