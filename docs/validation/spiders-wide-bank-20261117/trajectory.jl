using PipeWireAORTC
C = PipeWireAORTC.Common
root, seed = ARGS
period = 0.01
# Prepare independent perturbations from the authored source and optical definition.
source = C.read_yaml(joinpath(root, "simulation/source.yaml"))
facility = only(node for node in source["nodes"] if node["name"] == "facility_ao")
facility["config"]["rng_seed"] = parse(Int, seed)
facility["config"]["atmosphere_step"] = period
relative = "generated/held-out"
directory = mkpath(joinpath(root, relative))
header = "Generated from simulation/source.yaml and simulation/definition-fitted.yaml for the held-out trajectory."
C.write_yaml(joinpath(directory, "source.yaml"), source; header)
definition = C.read_yaml(joinpath(root, "simulation/definition-fitted.yaml"))
definition["instrument"] = "../../instrument.yaml"
definition["frame_period_s"] = period
definition["graphs"]["source"] = relative * "/source.yaml"
definition["id"] = "spiders-held-out-$seed"
C.write_yaml(joinpath(directory, "definition.yaml"), definition; header)
path = joinpath(root,"simulation/configuration-dual.yaml")
configuration = C.read_yaml(path)
configuration["plant"]["definition"] = relative * "/definition.yaml"
C.write_yaml(path, configuration; atomic=true)
