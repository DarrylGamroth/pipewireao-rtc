using AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL, CUDA, PipeWireAORTC, Proper
using LinearAlgebra
include(ARGS[1])

app, source, out = ARGS[2:4]
OC = OpticalCalibration
C = PipeWireAORTC.Common
I = PipeWireAORTC.InstrumentCalibration
FITS = PipeWireAORTC.InstrumentConfiguration.FITSIO.FITS
CUDA.allowscalar(false)
B = AdaptiveOpticsSim.Backends
target = B.AcceleratorComputeDevice(B.CUDABackend(), 0)
recipe = OC.optical_recipe(app, "calibration/optical-dark-hole.yaml")
plan = OC.optical_publication_plan(app, recipe;
    graphs=Dict("llowfs" => "calibration/templates/llowfs-branch.conf", "scc" => "calibration/templates/scc-branch.conf"),
    configuration="calibration/materialize-dual.yaml", prefix=ENV["PIPEWIREAO_PREFIX"])
upstream = joinpath(app, "generated/fitted-exposure/definition.yaml")
original_graph = joinpath(app, "optics/generated/fitted/scc.yaml")
graph = C.read_yaml(original_graph)
only(graph["outputs"])["source"] = "scc.reference"
graph_relative = "optics/generated/fitted/scc-reference-only.yaml"
C.write_yaml(joinpath(app, graph_relative), graph;
    header="Generated from the fitted SCC graph using the pinhole-only camera product.")
definition = C.read_yaml(upstream)
definition["graphs"]["scc"] = graph_relative
reference_definition = joinpath(dirname(upstream), "reference-only.yaml")
C.write_yaml(reference_definition, definition;
    header="Generated from the fitted detector definition for the SCC main-blocker exposure.")
callbacks = OC.optical_callbacks(upstream, reference_definition;
    mirror=recipe.document["mirror"], branches=recipe.branches,
    settings=get(recipe.document, "settings", Dict()), target,
    chopping=plan.chopping, publication_plan=plan,
    mirror_response=get(recipe.document, "mirror_response", nothing),
    pixel_selections=recipe.document["pixels"]["branches"])
beam = callbacks.chopped_references.scc.fringed
assets = joinpath(source, "generated/dual-calibration/scc/artifacts")
load(name) = FITS(joinpath(assets, name * ".fits")) do file
    values = read(file[1])
    ndims(values) == 2 ? permutedims(values) : values
end
mask = load("scc-pixel-mask") .!= 0
difference = load("scc-flat-fringed") .- load("scc-flat-unfringed")
reference = load("scc-reference-difference")
ordered = findall(mask)
by_row = sort!(copy(ordered); by=index -> Tuple(index))
if norm(difference[by_row] - reference) < norm(difference[ordered] - reference)
    ordered = by_row
end
@assert norm(difference[ordered] - reference) / norm(reference) < 1e-6
@assert size(beam) == size(mask) && all(isfinite, beam) && minimum(beam) >= 0
I.write_fits(joinpath(out, "reference-only-image.fits"), beam; units="electron")
I.write_fits(joinpath(out, "reference-only-selected.fits"), beam[ordered]; units="electron")
println("Reference-only peak ", maximum(beam), " e⁻/pixel, mask mean ", sum(beam[ordered])/length(ordered))
