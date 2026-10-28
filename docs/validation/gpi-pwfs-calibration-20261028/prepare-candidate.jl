using PipeWireAORTC, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL, Proper, YAML
const E=PipeWireAORTC.InstrumentExport
root,output=abspath.(ARGS)
source=joinpath(output,"source")
E.copy_source(joinpath(root,"gpi2"),source;runtime_configurations=false)
path=joinpath(source,"simulation/definition.yaml")
definition=YAML.load_file(path)
definition["graphs"]["calibration"]="simulation/pwfs-dm-planes-calibration.yaml"
definition["bindings"]["relay_entrance_opd"]=deepcopy(definition["bindings"]["uncompensated_opd"])
YAML.write_file(path,definition)
path=joinpath(source,"simulation/configuration.yaml")
configuration=YAML.load_file(path)
configuration["plant"]["graph"]="pwfs-dm-planes"
YAML.write_file(path,configuration)
# Regenerate all derived optical snapshots and their receipts from authoring.
AdaptiveOpticsSim.Optics.Zemax.prepare(source;formatter_config=joinpath(root,".yamlfmt.yaml"))
profile=E.load_profile(joinpath(source,"profiles/simulator/profile.yaml");
    host=joinpath(source,"profiles/simulator/host.cuda.example.yaml"))
application=E.prepare(source,joinpath(output,"application");profile)
println("prepared ",application)
