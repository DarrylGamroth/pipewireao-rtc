pushfirst!(LOAD_PATH,"/tmp/pipewireao-sdk-bootstrap-seal")
using PipeWireAO
pushfirst!(LOAD_PATH,"/tmp/pipewireao-rtc-bootstrap-seal/deployment/julia")
using PipeWireAODeployment
for name in ("native_owner_bootstrap_sealed", "native_owner_bootstrap", "native_owner_bootstrap_idle", "native_control_endpoint", "native_control_endpoint_faults")
    module_fixture=Module(gensym(Symbol(name)))
    Core.eval(module_fixture, :(include(path) = Base.include($module_fixture, path)))
    Base.include(module_fixture,joinpath("/tmp/pipewireao-rtc-bootstrap-seal/deployment/julia/test",name*".jl"))
end
