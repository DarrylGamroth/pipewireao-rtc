# Finite CPU verification. Never opens a PipeWire core or installed services.
# Usage: julia --project=SOURCE_ENV verify-pipeline.jl INSTRUMENT_REPO NAME FRESH_ROOT REGISTERED_MANIFEST
length(ARGS)==4 || error("expected INSTRUMENT_REPO NAME FRESH_ROOT REGISTERED_MANIFEST")
instruments,name,output,manifest=abspath(ARGS[1]),ARGS[2],abspath(ARGS[3]),abspath(ARGS[4])
include(joinpath(instruments,"tools/calibration-runtime.jl"))
include(joinpath(instruments,"tools/build.jl"))
const K=PipeWireAORTC.InstrumentCalibration
source=joinpath(instruments,name)
profile=joinpath(source,"profiles/simulator/profile.yaml")
host=joinpath(source,"profiles/simulator/host.cpu.example.yaml")
application=joinpath(output,"application")
bundle=joinpath(output,"bundle")
staged=joinpath(output,"staged")
rebuilt=joinpath(output,"rebuilt")
build(source,application,profile;host,manifest)
recipe=K.read_recipe(application)
@assert occursin("\$ref",read(joinpath(application,recipe["graph_source"]),String))
@assert !occursin("\$ref",read(joinpath(application,recipe["graph"]),String))
result=K.calibrate_system(application,bundle)
println("acquired modes=",result["mode_count"]," rank=",result["retained_rank"]);flush(stdout)
ext=Base.get_extension(PipeWireAORTC,:PipeWireAORTCCalibrationExt)
graph=ext.bundle_graph(bundle)
FilterGraphIsland.close_execution(graph)
K.validate_system(application,bundle,joinpath(output,"validation.yaml"))
K.stage_calibration(source,application,bundle,staged)
@assert !isfile(joinpath(staged,"rtc/application.conf"))
for entry in PipeWireAORTC.InstrumentExport.source_application(staged)["runtime-configurations"]
    @assert !ispath(joinpath(staged,entry["path"]))
end
build(staged,rebuilt,profile;host,manifest)
@assert K.read_recipe(rebuilt)==recipe
println("calibration/validation/staging/rebuild passed ",name)
