# Optional CPU selector: actual FGA/JFG frontend, no core, service or accelerator.
using Test, PipeWireAORTC, PipeWireAO, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL
using AdaptiveOpticsCalibration, FilterGraphAlgorithms, FilterGraphIsland, FilterGraphPipeWire, JuliaFilterGraph
using LinearAlgebra
const ChoppedCalibration = Base.get_extension(PipeWireAORTC,:PipeWireAORTCCalibrationExt)
const ChoppedGraphOwner = Base.get_extension(PipeWireAORTC,:PipeWireAORTCGraphExt)
const C = PipeWireAORTC.Common
const E = PipeWireAORTC.InstrumentExport

@testset "signed chopped residuals require explicit numerical selection" begin
    surface = command -> reshape(Float32[command[1],command[2],command[3],command[4],
        -command[1]-command[2],-command[3]-command[4]],2,3)
    observe = opd -> (;llowfs=10f0 .+ opd,scc=-opd)
    options = (;pupil_support=trues(2,3),branch_modes=(llowfs=1:2,scc=3:4),
        pixel_masks=(llowfs=trues(2,3),scc=trues(2,3)),poke_m=0.01f0,
        tsvd_rtol=1f-5,derivative_tolerance=0.001,reconstruction_tolerance=0.001)
    P=Matrix{Float32}(I,4,4)
    @test_throws ArgumentError PipeWireAORTC.InstrumentCalibration.calibrate_optical(surface,observe,P;options...)
    result=PipeWireAORTC.InstrumentCalibration.calibrate_optical(surface,observe,P;
        options...,signed_measurements=(:scc,))
    @test result.report["status"]=="accepted"
    @test result.report["branches"]["scc"]["measurement_kind"]=="chopped-pixel-residual"
    @test result.report["branches"]["llowfs"]["measurement_kind"]=="intensity"
    @test all(iszero,result.branches.scc.reference)
    @test result.validation.accepted
end

function chopped_calibration_document()
    nodes = [
        Dict("name"=>"pixels","type"=>"ndarray","label"=>"pixel-selection-f32","config"=>Dict(
            "image_size"=>[2,3],"mask"=>fill(true,6),"input_schema"=>"test.relative-image/1","output_schema"=>"test.relative-pixels/1")),
        Dict("name"=>"validity","type"=>"ndarray","label"=>"pixel-validity-f32","config"=>Dict(
            "extent"=>6,"input_schema"=>"test.relative-pixels/1")),
        Dict("name"=>"pair","type"=>"ndarray","label"=>"chopped-image-difference-f32","config"=>Dict(
            "pixel_count"=>6,"input_schema"=>"test.relative-pixels/1","trigger_high_is_fringed"=>true,"require_acquisition_identity"=>true)),
        Dict("name"=>"residual","type"=>"ndarray","label"=>"scc-pixel-residual-f32","config"=>Dict(
            "pixel_count"=>6,"mask"=>fill(true,6),"initial_reference_image"=>nothing,"minimum_valid_fraction"=>1)),
    ]
    links = [Dict("output"=>output,"input"=>input) for (output,input) in (
        ("pixels:selected-pixels","validity:input"),("pixels:selected-pixels","pair:image"),
        ("validity:validity","pair:input-validity"),("pair:difference","residual:difference"),
        ("pair:output-validity","residual:difference-validity"),("pair:pair-status","residual:pair-status"))]
    return Dict("node.name"=>"test.chopped-calibration","filter.graph"=>Dict("nodes"=>nodes,"links"=>links,
        "inputs"=>[Dict("name"=>"image","endpoint"=>"pixels:image"),
            Dict("name"=>"scc-reference-difference","endpoint"=>"residual:reference-image")],
        "outputs"=>[Dict("name"=>"measurements","endpoint"=>"residual:selected-residuals")]))
end

@testset "chopped calibration executes the authored signed pixel prefix" begin
    document = chopped_calibration_document()
    prefix = ChoppedCalibration.optical_chopped_document(document,:scc)
    reference = Float32[1 2 3;4 5 6]
    frontend = ChoppedCalibration.prepare_optical_chopped_frontend(prefix,:scc,reference,10_000_000,true)
    try
        unfringed = Float32[1 2 3;4 5 6]
        fringed = Float32[4 7 10;13 16 19]
        expected = Float32[2 3 4;5 6 7]
        @test ChoppedCalibration.optical_chopped_measurement!(frontend,fringed,unfringed) == expected
        @test ChoppedCalibration.optical_chopped_measurement!(frontend,unfringed+reference,unfringed) == zeros(Float32,2,3)
        @test ChoppedCalibration.optical_chopped_measurement!(frontend,unfringed,fringed) == -fringed
        @test_throws DimensionMismatch ChoppedCalibration.optical_chopped_measurement!(frontend,zeros(Float32,3,2),unfringed)
        @test_throws ArgumentError ChoppedCalibration.optical_image(-ones(Float32,2,3))
        @test ChoppedCalibration.optical_image(-ones(Float32,2,3);signed=true) == -ones(Float32,2,3)
        changed=deepcopy(document);changed["filter.graph"]["nodes"][3]["config"]["require_acquisition_identity"]=false
        @test_throws ArgumentError ChoppedCalibration.optical_chopped_document(changed,:scc)
        changed=deepcopy(document);changed["filter.graph"]["inputs"][2]["name"]="wrong-reference"
        @test_throws ArgumentError ChoppedCalibration.optical_chopped_document(changed,:scc)
        changed=deepcopy(document);changed["filter.graph"]["nodes"][4]["config"]["minimum_valid_fraction"]=0.5
        @test ChoppedCalibration.optical_frontend_identity(ChoppedCalibration.optical_chopped_document(changed,:scc)) !=
            ChoppedCalibration.optical_frontend_identity(prefix)

        warmup=(;input=:image,exposure_duration_ns=10_000_000,trigger_high_is_fringed=true)
        options=(;acquisition_version=3,execution="complete-frame",feedback=nothing,capture_backend=nothing)
        samples=ChoppedGraphOwner.chopped_warmup_samples(frontend.graph,options,warmup)
        @test length(samples)==3 && samples[1].expected===SccPixelResidualIncompletePair
        @test samples[1].metadata.image.acquisition_version==3
        node=FilterGraphPipeWire.PipeWireNode(frontend.graph;connect=false,acquisition_version=3)
        try
            @test FilterGraphPipeWire.prepare!(node;samples,required_outputs=(:measurements,))===node
            @test !node.owner.active && node.owner.process_count==0
            @test FilterGraphPipeWire.node_state(node)==PipeWireAO.NDARRAY_FILTER_STATE_UNCONNECTED
            # output_metadata explicitly retains the last product even when
            # unavailable. It is not publication evidence after preparation.
            @test JuliaFilterGraph.output_metadata(frontend.graph).measurements.sequence==3
            pair=only(filter(item->item.name===:pair,frontend.graph.nodes)).prepared.workspace
            @test !chopped_image_is_primed(pair)
            live=SampleMetadata(1;terminal=true,trigger_high=true,acquisition_version=3,
                exposure_duration_nanoseconds=10_000_000,
                acquisition_identity=SampleAcquisitionIdentity(ntuple(_->UInt8(0xd2),16),1,1))
            @test JuliaFilterGraph.process!(frontend.outputs,frontend.graph,(image=fringed,),(image=live,))===SccPixelResidualIncompletePair
            @test_throws ArgumentError ChoppedGraphOwner.chopped_warmup_samples(frontend.graph,
                merge(options,(;acquisition_version=2)),warmup)
        finally
            close(node)
        end
    finally
        FilterGraphIsland.close_execution(frontend.graph)
    end
end

@testset "matched chopped calibration publishes its real flat difference" begin
    document=chopped_calibration_document()
    specification=document["filter.graph"]
    node(name,label,config)=Dict("name"=>name,"type"=>"ndarray","label"=>label,"config"=>config)
    modes="test/chopped-modes/1"
    dense(input_schema,output_schema,input_count)=Dict("input_count"=>input_count,"output_count"=>4,
        "initial_reconstructor"=>nothing,"input_schema"=>input_schema,"output_schema"=>output_schema,
        "reconstructor_schema"=>"test/chopped-matrix/1")
    append!(specification["nodes"],[
        node("reconstruction","dense-vector-reconstructor-f32",dense(SCC_SELECTED_PIXEL_RESIDUALS_V1,modes,6)),
        node("reference","vector-offset-f32",Dict("extent"=>4,"schema"=>modes)),
        node("projection","dense-vector-reconstructor-f32",dense(modes,"test/physical/1",4))])
    append!(specification["links"],[Dict("output"=>output,"input"=>input) for (output,input) in (
        ("residual:selected-residuals","reconstruction:ordered-input"),
        ("reconstruction:output","reference:requested"),("reference:output","projection:ordered-input"))])
    append!(specification["inputs"],[Dict("name"=>name,"endpoint"=>endpoint) for (name,endpoint) in (
        ("scc-reconstructor","reconstruction:reconstructor"),("scc-modal-reference","reference:offset"),
        ("command-projection","projection:reconstructor"))])
    specification["outputs"]=[Dict("name"=>"physical-offset","endpoint"=>"projection:output")]
    prefix=ChoppedCalibration.optical_chopped_document(document,:scc)
    flat_f=Float32[12 13 14;15 16 17]
    flat_u=fill(10f0,2,3)
    reference=flat_f-flat_u
    frontend=ChoppedCalibration.prepare_optical_chopped_frontend(prefix,:scc,reference,10_000_000,true)
    try
        surface=command->reshape(Float32[command[1],command[2],command[3],command[4],
            -command[1]-command[2],-command[3]-command[4]],2,3)
        observe=opd->(;scc=ChoppedCalibration.optical_chopped_measurement!(frontend,flat_f+opd,flat_u))
        provenance=Dict("measurement_frontend_identity"=>Dict("scc"=>ChoppedCalibration.optical_frontend_identity(prefix)))
        calibration=PipeWireAORTC.InstrumentCalibration.calibrate_optical(surface,observe,Matrix{Float32}(I,4,4);
            pupil_support=trues(2,3),branch_modes=(scc=1:4,),pixel_masks=(scc=trues(2,3),),
            poke_m=0.02f0,tsvd_rtol=1f-5,derivative_tolerance=0.001,reconstruction_tolerance=0.001,
            signed_measurements=(:scc,),provenance)
        @test calibration.report["status"]=="accepted"
        calibration=merge(calibration,(;chopped_references=(scc=(;fringed=flat_f,unfringed=flat_u,difference=reference),)))
        report=merge(Dict("recipe"=>Dict("kind"=>"linear-chopped-test"),
            "source_prescription_identity"=>"linear-chopped-test","source_graph_sha256"=>repeat("a",64)),calibration.report)
        mktempdir() do directory
            output=ChoppedCalibration.publish_optical_bundles((;calibration,report),joinpath(directory,"accepted"),
                (scc=document,),(scc=Dict(),))
            bundle=PipeWireAORTC.InstrumentCalibration.read_bundle(joinpath(output.directory,"scc"))
            @test Set(bundle.parameter_names)==Set(("command-projection","scc-reconstructor","scc-modal-reference","scc-reference-difference"))
            @test bundle.report["held_out"]["accepted"]
            @test haskey(bundle.report["artifact_sha256"],"scc-flat-fringed.fits")
            @test haskey(bundle.report["artifact_sha256"],"scc-flat-unfringed.fits")
            @test haskey(bundle.report["artifact_sha256"],"scc-flat-difference.fits")
            changed=deepcopy(document)
            changed["filter.graph"]["nodes"][4]["config"]["minimum_valid_fraction"]=0.5
            @test_throws ArgumentError ChoppedCalibration.publish_optical_bundles((;calibration,report),
                joinpath(directory,"changed"),(scc=changed,),(scc=Dict(),))
            @test !ispath(joinpath(directory,"changed"))
        end
    finally
        FilterGraphIsland.close_execution(frontend.graph)
    end
end

@testset "ordinary intensity reports cannot select chopped execution" begin
    chopping=Dict("scc"=>Dict("unfringed_graph"=>"scc_unfringed","initial_phase"=>"fringed","trigger_high_is_fringed"=>true))
    simulation=Dict("plant"=>Dict("chopping"=>chopping))
    report=Dict{String,Any}("recipe"=>Dict(),"provenance"=>Dict(),"branches"=>Dict("scc"=>Dict()))
    @test_throws ArgumentError E.validate_chopped_calibration(report,simulation)
    report["recipe"]["measurements"]=Dict("scc"=>Dict("kind"=>"chopped-pixel-residual"))
    report["provenance"]["chopping"]=chopping
    @test_throws ArgumentError E.validate_chopped_calibration(report,simulation)
    report["branches"]["scc"]["measurement_kind"]="chopped-pixel-residual"
    report["provenance"]["measurement_frontend_identity"]=Dict("scc"=>"sha256:"*repeat("a",64))
    @test E.validate_chopped_calibration(report,simulation)===nothing
    report["branch"]="scc";report["parameter_files"]=Dict();report["artifact_sha256"]=Dict()
    @test_throws ArgumentError E.validate_chopped_calibration(report,simulation)
    report["parameter_files"]["scc-reference-difference"]="scc-reference-difference.fits"
    @test_throws ArgumentError E.validate_chopped_calibration(report,simulation)
    report["artifact_sha256"]["scc-reference-difference.fits"]=repeat("b",64)
    @test E.validate_chopped_calibration(report,simulation)===nothing
    changed=deepcopy(simulation)
    changed["plant"]["chopping"]["scc"]["trigger_high_is_fringed"]=false
    @test_throws ArgumentError E.validate_chopped_calibration(report,changed)
    changed=deepcopy(simulation)
    changed["plant"]["chopping"]["scc"]["unfringed_graph"]="other_unfringed"
    @test_throws ArgumentError E.validate_chopped_calibration(report,changed)
end

@testset "chopped transport records observed model-window gaps and actual phase" begin
    owner=Base.get_extension(PipeWireAORTC,:PipeWireAORTCAOSExt).ExternalPupilOwner
    science=(;chopping=(scc=(;trigger_high_is_fringed=true),))
    first=(;sequence=UInt64(1),pts=Int64(0),duration=UInt64(10_000_000),chopped_image_kind=:fringed)
    later=(;sequence=UInt64(2),pts=Int64(30_000_000),duration=UInt64(10_000_000),chopped_image_kind=:unfringed)
    @test owner.sensor_sequence(first,true)==1
    @test owner.sensor_sequence(later,true)==4
    @test owner.sensor_sequence(later,false)==2
    @test owner.trigger_state(science,:scc,first)==PipeWireAO.ACQUISITION_TRIGGER_HIGH
    @test owner.trigger_state(science,:scc,later)==PipeWireAO.ACQUISITION_TRIGGER_LOW
    reversed=(;chopping=(scc=(;trigger_high_is_fringed=false),))
    @test owner.trigger_state(reversed,:scc,later)==PipeWireAO.ACQUISITION_TRIGGER_HIGH
    @test owner.trigger_state(science,:llowfs,later)==PipeWireAO.ACQUISITION_TRIGGER_ABSENT
    @test_throws ArgumentError owner.trigger_state(science,:scc,merge(first,(;chopped_image_kind=:unknown)))
    for metadata in (merge(first,(;pts=Int64(-1))),merge(first,(;pts=Int64(1))),merge(first,(;duration=UInt64(0))))
        @test_throws ArgumentError owner.sensor_sequence(metadata,true)
    end
end

@assert !any(id->id.name in ("CUDA","AMDGPU"),keys(Base.loaded_modules))
