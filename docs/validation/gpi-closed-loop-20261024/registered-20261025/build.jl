using PipeWireAORTC
const R=PipeWireAORTC
const C=R.Common
const root="/home/dgamroth/.local/state/pipewireao/gpi2-registered-live-20261025"
profile=C.read_yaml("/home/dgamroth/.cache/pipewireao/gpi2-validation-20261025/shape-host-cuda-v8.yaml")
for role in ("julia","simulator","session")
 profile["environment"][role]["JULIA_DEPOT_PATH"]=ENV["JULIA_DEPOT_PATH"]
end
R.InstrumentExport.prepare("/home/dgamroth/.cache/pipewireao/gpi2-validation-20261025/instrument-source-v8/gpi2",joinpath(root,"application");profile,manifest=joinpath(dirname(Base.active_project()),"Manifest.toml"),prefix=ENV["PIPEWIREAO_PREFIX"])
old="/home/dgamroth/.local/state/pipewireao/gpi2-shape-live-20261025/application"
for path in ("instrument.json","rtc/graph.conf","rtc/parameters.conf","rtc/session.conf.in","simulation/definition.yaml")
 @assert read(joinpath(root,"application",path))==read(joinpath(old,path)) path
end
println("Registered JFG application prepared; instrument, controller, parameters, session declarations and simulation definition unchanged.")
