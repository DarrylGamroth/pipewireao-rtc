using PipeWireAORTC, Proper, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL, CUDA
using FilterGraphPipeWire
include(ARGS[1])
app, out = ARGS[2:3]
recipe = "calibration/optical-dark-hole.yaml"
OC = OpticalCalibration
CUDA.allowscalar(false)
B = AdaptiveOpticsSim.Backends
selected = OC.optical_recipe(app, recipe)
plan = OC.optical_publication_plan(app, selected; graphs=Dict("llowfs" => "calibration/templates/llowfs-branch.conf", "scc" => "calibration/templates/scc-branch.conf"),
    configuration="calibration/materialize-dual.yaml", prefix=ENV["PIPEWIREAO_PREFIX"])
result = OC.calibrate_optical(app, app; recipe, publication_plan=plan,
    target=B.AcceleratorComputeDevice(B.CUDABackend(), 0))
PipeWireAORTC.Common.write_json(joinpath(out, "biased-calibration.json"), result.report; atomic=true)
dimensions = plan.rtc.document["dimensions"]
dimensions["controller_command_count"] = length(result.calibration.normalization)
prepared = OC.optical_publication_graphs(plan, result.calibration)
OC.publish_optical_bundles(result, joinpath(out,"calibration"), prepared.graphs, prepared.contexts)
