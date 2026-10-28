# Optional CPU selector: real linear numerical calibration, no core or service.
using Test, LinearAlgebra, PipeWireAORTC, PipeWireAO
using AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL, AdaptiveOpticsCalibration
using FilterGraphAlgorithms, FilterGraphIsland, FilterGraphPipeWire, JuliaFilterGraph

const E = PipeWireAORTC.InstrumentExport
const C = PipeWireAORTC.Common
const D = PipeWireAORTC.DeploymentConfiguration
const Calibration = PipeWireAORTC.InstrumentCalibration
const Implementation = Base.get_extension(PipeWireAORTC,:PipeWireAORTCCalibrationExt)
const PREFIX = String(PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir)
ENV["PIPEWIREAO_PREFIX"] = PREFIX
include("composition_documents.jl")

function optical_template(name)
    reference(path) = Dict("\$ref"=>path)
    node(name,label,config) = Dict("name"=>name,"type"=>"ndarray","label"=>label,"config"=>config)
    dense = Dict("input_count"=>4,"output_count"=>4,"initial_reconstructor"=>nothing,
        "input_schema"=>"test/modes/1","output_schema"=>"test/modes/1","reconstructor_schema"=>"test/matrix/1")
    reconstruction = merge(dense,Dict("input_schema"=>"test/pixels/1"))
    nodes = [node("pixels","pixel-selection-f32",Dict("image_size"=>[2,3],
        "mask"=>reference("/calibration/pixel_selection_mask"),
        "input_schema"=>reference("/calibration/"*name*"/frame_schema"),"output_schema"=>"test/pixels/1")),
        node("reconstruction","dense-vector-reconstructor-f32",reconstruction),
        node("reference","vector-offset-f32",Dict("extent"=>4,"schema"=>"test/modes/1")),
        node("projection","dense-vector-reconstructor-f32",dense)]
    link(output,input) = Dict("output"=>output,"input"=>input)
    port(name,endpoint) = Dict("name"=>name,"endpoint"=>endpoint)
    return Dict("node.name"=>name*"-controller","filter.graph"=>Dict("nodes"=>nodes,
        "links"=>[link("pixels:selected-pixels","reconstruction:ordered-input"),
            link("reconstruction:output","reference:requested"),link("reference:output","projection:ordered-input")],
        "inputs"=>[port("image","pixels:image"),port(name*"-reconstructor","reconstruction:reconstructor"),
            port(name*"-modal-reference","reference:offset"),port("command-projection","projection:reconstructor")],
        "outputs"=>[port("physical-offset","projection:output")]))
end

@testset "measured optical contexts publish real typed graph inputs" begin
    response = Float32[1 0 0 0;0 2 0 0;0 0 3 0;0 0 0 4;-1 -2 0 0;0 0 -3 -4]
    observation = Float32[1 2 3 4 0 0;0 1 2 3 4 0;0 0 1 2 3 4;4 0 0 1 2 3;3 4 0 0 1 2;2 3 4 0 0 1]
    surface = command -> reshape(response*command,2,3)
    observe = opd -> (llowfs=reshape(10f0 .+ observation*vec(opd),2,3),
        scc=reshape(12f0 .+ reverse(observation;dims=1)*vec(opd),2,3))
    mask = Bool[1 0 1;0 1 1]
    calibration = Calibration.calibrate_optical(surface,observe,Matrix{Float32}(I,4,4);
        pupil_support=trues(2,3),branch_modes=(llowfs=1:2,scc=3:4),pixel_masks=(llowfs=mask,scc=mask),
        poke_m=.01f0,tsvd_rtol=1f-5,derivative_tolerance=.01,reconstruction_tolerance=.01)
    @test calibration.report["status"] == "accepted"
    dimensions = Dict("image_rows"=>2,"image_columns"=>3,"selected_pixel_count"=>4,
        "controller_command_count"=>4,"physical_command_count"=>4)
    plan = (;rtc=(document=Dict("dimensions"=>dimensions),controls=Dict("deformable_mirrors"=>Dict())),
        frames=Dict("llowfs"=>Dict("frame_schema"=>"test/llowfs/1"),"scc"=>Dict("frame_schema"=>"test/scc/1")),
        templates=(llowfs=optical_template("llowfs"),scc=optical_template("scc")),
        instrument=Dict("deformable_mirrors"=>Dict(),"wavefront_sensors"=>Dict()))
    prepared = Implementation.optical_publication_graphs(plan,calibration)
    @test first(prepared.graphs.llowfs["filter.graph"]["nodes"])["config"]["mask"] == Bool[1,0,1,0,1,1]
    @test prepared.contexts.scc["scc"]["frame_schema"] == "test/scc/1"
    @test haskey(first(plan.templates.llowfs["filter.graph"]["nodes"])["config"]["mask"],"\$ref")
    invalid = deepcopy(plan)
    invalid.rtc.document["dimensions"]["selected_pixel_count"] = 6
    @test_throws DimensionMismatch Implementation.optical_publication_graphs(invalid,calibration)
    @test_throws ArgumentError Implementation.validate_optical_graphs(prepared.graphs,nothing,(:llowfs,:scc))
    mktempdir() do directory
        report = merge(Dict("recipe"=>Dict("kind"=>"linear-test"),"source_prescription_identity"=>"linear-test",
            "source_graph_sha256"=>repeat("a",64)),calibration.report)
        result = (;calibration,report)
        output = Implementation.publish_optical_bundles(result,joinpath(directory,"accepted"),prepared.graphs,prepared.contexts)
        @test keys(output.reports) == (:llowfs,:scc)
        bundle = Calibration.read_bundle(joinpath(output.directory,"llowfs"))
        @test Set(bundle.parameter_names) == Set(["command-projection","llowfs-reconstructor","llowfs-modal-reference"])
        @test PipeWireAORTC.InstrumentConfiguration.calibration_context(bundle.context,joinpath(output.directory,"llowfs"))["pixel_selection_mask"] == Bool[1,0,1,0,1,1]
        @test bundle.report["held_out"]["accepted"]
        invalid_graphs = deepcopy(prepared.graphs)
        first(invalid_graphs.scc["filter.graph"]["nodes"])["label"] = "unsupported-optical-node"
        @test_throws JuliaFilterGraph.GraphConfigurationError Implementation.publish_optical_bundles(result,
            joinpath(directory,"unsupported"),invalid_graphs,prepared.contexts)
        @test !ispath(joinpath(directory,"unsupported"))
        rejected = merge(calibration,(report=merge(calibration.report,Dict("status"=>"rejected")),))
        @test_throws ArgumentError Implementation.publish_optical_bundles((;calibration=rejected,report),
            joinpath(directory,"rejected"),prepared.graphs,prepared.contexts)
        @test !ispath(joinpath(directory,"rejected"))
    end
end

@testset "optical publication validates both application seals before acquisition" begin
    mktempdir() do directory
        upstream = composition_fixture(joinpath(directory,"upstream"),"upstream","simulator","pupil")
        optical = composition_fixture(joinpath(directory,"optical"),"optical","simulator","sensor")
        write(joinpath(optical,"graph.conf"),"changed after sealing")
        @test_throws D.DeploymentError Calibration.calibrate_optical(upstream,optical,joinpath(directory,"output");prefix=PREFIX)
        @test !ispath(joinpath(directory,"output"))
        write(joinpath(optical,"graph.conf"),"{}");E.seal!(optical)
        write(joinpath(upstream,"graph.conf"),"changed upstream after sealing")
        @test_throws D.DeploymentError Calibration.calibrate_optical(upstream,optical,joinpath(directory,"output");prefix=PREFIX)
    end
    @test !any(id->id.name in ("CUDA","AMDGPU"),keys(Base.loaded_modules))
end
