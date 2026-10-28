# Optional science CPU contracts. A built application enables normal-graph
# geometry/projection checks; private-core end-to-end acquisition is separate.
module PyramidReferenceCalibrationTests
using Test
using PipeWireAO, PipeWireAORTC, FilterGraphIsland, FilterGraphPipeWire, JuliaFilterGraph
using AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL, AdaptiveOpticsCalibration
const Ext = Base.get_extension(PipeWireAORTC,:PipeWireAORTCCalibrationExt)
const C = PipeWireAORTC.InstrumentCalibration
const R = AdaptiveOpticsCalibration.ReferenceFrames
const A = AdaptiveOpticsCalibration
@test Ext !== nothing && isdefined(Ext,:pyramid_references)

@testset "pyramid references require every named physical command explicitly" begin
    options = (command_input=(:tiptilt,:tweeter,:woofer),
        command_count=(woofer=2,tweeter=3,tiptilt=2))
    supplied = (woofer=Float32[1,2],tiptilt=Float32[3,4],tweeter=Float32[5,6,7])
    owned = Ext.pyramid_reference_figures(supplied,options)
    @test keys(owned) == options.command_input
    @test owned.woofer == Float32[1,2]
    supplied.woofer[1] = 99
    @test owned.woofer == Float32[1,2]
    for bad in (Float32[1,2],(woofer=Float32[1,2],),
            merge(supplied,(woofer=Float32[1],)),
            merge(supplied,(woofer=[1.0,2.0],)),
            merge(supplied,(woofer=Float32[NaN,2],)),
            merge(supplied,(extra=Float32[1],)))
        @test_throws ArgumentError Ext.pyramid_reference_figures(bad,options)
    end
end

@testset "modal units require OPD normalization and an explicit disjoint partition" begin
    parameters = Dict(:reconstructor=>zeros(Float32,3,8),
        Symbol("woofer-selection")=>Float32[0 1 0; 1 0 0],
        Symbol("tweeter-selection")=>Float32[0 0 1])
    recipe = Dict("mirrors"=>[Dict("name"=>"woofer"),Dict("name"=>"tweeter")])
    instrument = Dict("deformable_mirrors"=>Dict("woofer"=>Dict("units"=>"m OPD"),
        "tweeter"=>Dict("units"=>"m OPD")))
    normalization = "piston-removed pupil RMS OPD"
    @test Ext.pyramid_reference_units(parameters,recipe,instrument,normalization) == fill("m OPD",3)
    @test_throws ArgumentError Ext.pyramid_reference_units(parameters,recipe,instrument,"unknown")
    for selection in (Float32[1 0 0],Float32[0 0 0],Float32[0 1 1],Float32[0 0 -1],Float32[0 0 NaN])
        bad = copy(parameters)
        bad[Symbol("tweeter-selection")] = selection
        @test_throws ArgumentError Ext.pyramid_reference_units(bad,recipe,instrument,normalization)
    end
    bad = copy(parameters)
    bad[Symbol("tweeter-selection")] = zeros(Float32,1,2)
    @test_throws DimensionMismatch Ext.pyramid_reference_units(bad,recipe,instrument,normalization)
    bad = deepcopy(instrument)
    bad["deformable_mirrors"]["tweeter"]["units"] = "m surface"
    @test_throws ArgumentError Ext.pyramid_reference_units(parameters,recipe,bad,normalization)
    duplicate = Dict("mirrors"=>[Dict("name"=>"woofer"),Dict("name"=>"woofer")])
    @test_throws ArgumentError Ext.pyramid_reference_units(parameters,duplicate,instrument,normalization)
end

@testset "OPD normalization authority binds exact FITS bytes, HDU and axes" begin
    mktempdir() do directory
        recipe = Dict("mirrors"=>[Dict("name"=>"woofer"),Dict("name"=>"tweeter")])
        values = (reconstructor=Float32[1 2;3 4],
            var"woofer-selection"=Float32[1 0],var"tweeter-selection"=Float32[0 1])
        bindings = PipeWireAORTC.GraphOwner.FITSBinding[]
        files,hashes = Dict{String,String}(),Dict{String,String}()
        for (port,array) in pairs(values)
            filename = string(port)*".fits"
            path = joinpath(directory,filename)
            C.write_fits(path,array)
            push!(bindings,PipeWireAORTC.GraphOwner.FITSBinding(port,
                PipeWireAORTC.Artifacts.FITSArtifact(path;axes=(2,1))))
            files[string(port)] = filename
            hashes[filename] = C.digest(path)
        end
        calibration = Dict("parameter_files"=>files,"artifact_sha256"=>hashes)
        expected = Dict(name=>hashes[file] for (name,file) in files)
        @test Ext.pyramid_reference_unit_sources(bindings,recipe,calibration) == expected
        for port in keys(values)
            changed = deepcopy(calibration)
            changed["artifact_sha256"][files[string(port)]] = repeat("0",64)
            @test_throws ArgumentError Ext.pyramid_reference_unit_sources(bindings,recipe,changed)
            changed = deepcopy(calibration)
            delete!(changed["parameter_files"],string(port))
            @test_throws ArgumentError Ext.pyramid_reference_unit_sources(bindings,recipe,changed)
        end
        for (hdu,axes) in ((2,(2,1)),(1,(1,2)),(1,nothing))
            changed = copy(bindings)
            original = first(changed)
            changed[1] = PipeWireAORTC.GraphOwner.FITSBinding(original.port,
                PipeWireAORTC.Artifacts.FITSArtifact(original.source.path;hdu,axes))
            @test_throws ArgumentError Ext.pyramid_reference_unit_sources(changed,recipe,calibration)
        end
        @test_throws ArgumentError Ext.pyramid_reference_unit_sources(bindings[2:end],recipe,calibration)
        @test_throws ArgumentError Ext.pyramid_reference_unit_sources([bindings;first(bindings)],recipe,calibration)
        # A generated replacement with altered values is rejected without touching
        # any copied calibration bytes or changing the claimed normalization.
        replacement = joinpath(directory,"replacement.fits")
        C.write_fits(replacement,Float32[1 2;3 5])
        changed = copy(bindings)
        changed[1] = PipeWireAORTC.GraphOwner.FITSBinding(:reconstructor,
            PipeWireAORTC.Artifacts.FITSArtifact(replacement;axes=(2,1)))
        @test_throws ArgumentError Ext.pyramid_reference_unit_sources(changed,recipe,calibration)
    end
end

@testset "borrowed pyramid samples feed the AOC dimensionless reference unchanged" begin
    matrix = Float32[1 10 100 1000 0 0 0 0]
    plan = A.prepare(R.PyramidReference(100),R.PyramidReferenceSpecification(
        2,3,2,2,matrix;row_units=["m OPD"]))
    state = R.PyramidReferenceState(plan)
    pixels = Float32[1 2;3 4;5 6;7 8]
    raw = fill(UInt16(2),2,3)
    mean = Float32[5]
    sample = (arrays=(raw=raw,reconstruction_pixels=pixels,mean_pupil_intensity=mean),)
    @test Ext.pyramid_reference_update!(state,plan,sample) === nothing
    pixels .+= 2
    mean .= 1000
    raw .= 4
    Ext.pyramid_reference_update!(state,plan,sample)
    product = Ext.reference_product(plan,state)
    @test product.status === R.Valid
    @test product.reference_pixels == [2 3;4 5;6 7;8 9]
    # Pupil-major first four entries [2,3,4,5], no current-mean normalization.
    @test product.modal_reference == [-5432.0]
    @test product.minimum_mean_pupil_intensity == 5.0
    @test product.adc_maximum == 4.0
    pixels .= 999
    raw .= 99
    @test state.reference_pixels == product.reference_pixels
end

application = get(ENV,"PIPEWIREAORTC_PYRAMID_REFERENCE_APPLICATION",nothing)
if application !== nothing
    @testset "built GPI normal graph geometry and optical-only frontend projection" begin
        @info "Checking built GPI geometry and projections"
        flush(stdout)
        before = Ext.reference_application_hashes(application)
        recipe = C.read_recipe(application)
        options = PipeWireAORTC.AOSOwner.configuration(joinpath(application,"simulation.conf"))
        parameters = C.read_parameters(application)
        declaration = Ext.IC.load_simulation(options.plant.definition)
        geometry = Ext.pyramid_reference_geometry(application,parameters,options,recipe,declaration)
        @info "GPI geometry checked" selected_pixels=geometry.selected controller_coordinates=geometry.modes
        flush(stdout)
        @test geometry.probe_command == Symbol(first(recipe["mirrors"])["name"])
        @test Set(keys(geometry.commands)) == Set(options.command_input)
        @test geometry.row_units == fill("m OPD",geometry.modes)
        dark = C.calibration_graph(application;inputs=(raw="pixel-calibration:raw",),
            outputs=(calibrated="pixel-calibration:calibrated",))
        try
            @test JuliaFilterGraph.output_formats(dark.graph).calibrated.shape == options.frame_shape
            @test all(node["label"] != "pyramid-pupil-image-f32" for node in dark.document["filter.graph"]["nodes"])
        finally
            FilterGraphIsland.close_execution(dark.graph)
        end
        frontend = C.calibration_graph(application;inputs=(raw="pixel-calibration:raw",),
            outputs=(reconstruction_pixels=Symbol("reconstruction-pixels"),
                mean_pupil_intensity=Symbol("mean-pupil-intensity")))
        try
            formats = JuliaFilterGraph.output_formats(frontend.graph)
            @test formats.reconstruction_pixels.shape == (4,geometry.selected)
            @test formats.mean_pupil_intensity.shape == (1,)
            @test frontend.parameters[:flat] == parameters[:flat]
            @test frontend.parameters[Symbol("pupil-mask")] == parameters[Symbol("pupil-mask")]
            @test frontend.parameters[Symbol("pupil-origins")] == parameters[Symbol("pupil-origins")]
        finally
            FilterGraphIsland.close_execution(frontend.graph)
        end
        @test Ext.reference_application_hashes(application) == before
    end
end
if application !== nothing && get(ENV,"PIPEWIREAORTC_PYRAMID_REFERENCE_LIVE","false") == "true"
    include("native_control_private_core.jl")
    @testset "GPI pyramid candidate acquisition on a caller-owned private core" begin
        Threads.nthreads(:default) >= 6 || error("run the GPI selector with --threads=6 or higher")
        before = Ext.reference_application_hashes(application)
        options = PipeWireAORTC.AOSOwner.configuration(joinpath(application,"simulation.conf"))
        reference = NamedTuple{options.command_input}(Tuple(
            zeros(Float32,getproperty(options.command_count,name)) for name in options.command_input))
        counts = Ext.reference_counts(C.read_recipe(application))
        parameters = C.read_parameters(application)
        original = Dict(name=>copy(parameters[name]) for name in
            (:flat,Symbol("pupil-mask"),Symbol("pupil-origins"),:reconstructor))
        source = get(ENV,"PIPEWIREAORTC_PYRAMID_REFERENCE_INSTRUMENT",nothing)
        source_before = source === nothing ? nothing : Ext.reference_application_hashes(source)
        mktempdir() do directory
            with_control_private_core(;temporary_prefix="gpi-reference-campaign-") do remote,core_directory,daemon
                chmod(dirname(remote),0o700)
                requests = Any[]
                confirmation = function (request,witness)
                    push!(requests,request)
                    @info "GPI reference stage prepared" stage=request.stage witness
                    flush(stdout)
                    PipeWireAORTC.CalibrationPreparation.Confirmation(request;
                        observed_at=Ext.Control.monotonic(),witness)
                end
                output = joinpath(directory,"candidate")
                report = C.calibrate_references(application,output;remote,reference,
                    timeout_s=600,confirm=confirmation)
                @test isfile(joinpath(output,"result.yaml"))
                @test report["product"] == "reference-candidate"
                @test report["sensor"] == "pyramid"
                @test report["backend"] == "cpu"
                @test report["frame_encoding"] == "uint16"
                @test report["activation"] == "candidate-only"
                @test !report["interaction_matrix_accepted"]
                @test report["dark_status"] == "Valid"
                @test report["lamp_status"] in ("Valid","Invalid")
                @test report["qualification_status"] in ("Valid","Invalid")
                @test report["reference_pixel_units"] == "dimensionless"
                @test report["modal_reference_units"] == "m OPD"
                @test report["probe_command"] == "woofer"
                @test report["overridden_parameter_ports"] == ["background"]
                @test length(report["stages"]) == length(requests) == 3
                @test all(request.kind == :simulated for request in requests)
                @test all(stage["restored"] && stage["released"] for stage in report["stages"])
                dark,lamp,qualification = report["stages"]
                @test [stage["condition"] for stage in report["stages"]] == ["dark","internal-source","internal-source"]
                @test [stage["samples"] for stage in report["stages"]] ==
                    [counts.dark.samples,counts.lamp.samples,counts.qualification.samples]
                @test lamp["discard_exposures"] >= 1
                @test qualification["first_sequence"] > lamp["last_sequence"]
                @test qualification["first_start_ns"] >= lamp["last_end_ns"]
                @test all(occursin(stage["acquisition_domain"],stage["witness"]) for stage in report["stages"])
                @test length(unique(stage["acquisition_domain"] for stage in report["stages"])) == 3
                @test lamp["parameter_sha256"]["background"] == qualification["parameter_sha256"]["background"] ==
                    report["artifacts"]["background"]["sha256"]
                for name in ("flat","pupil-mask","pupil-origins")
                    @test lamp["parameter_sha256"][name] == qualification["parameter_sha256"][name] ==
                        report["frozen_parameter_sha256"][name]
                end
                types = Dict("Float32"=>Float32,"Float64"=>Float64)
                products = Dict{String,Array}()
                for (name,artifact) in report["artifacts"]
                    path = joinpath(output,artifact["path"])
                    @test C.digest(path) == artifact["sha256"]
                    input = PipeWireAORTC.Artifacts.FITSArtifact(path;hdu=artifact["hdu"],axes=artifact["axes"])
                    products[name] = PipeWireAORTC.Artifacts.prepare(input,
                        types[artifact["target_type"]],Tuple(artifact["target_shape"])).data
                end
                @test products["background"] == Float32.(products["dark-mean"])
                for (name,figure) in pairs(reference)
                    @test products[report["reference_figure_artifacts"][string(name)]] == figure
                    @test eltype(products[report["reference_figure_artifacts"][string(name)]]) === Float32
                end
                @test size(products["reference-pixels"]) == (4,report["selected_pixel_count_per_pupil"])
                @test size(products["modal-reference"]) == size(parameters[Symbol("modal-reference")])
                if report["lamp_status"] == "Valid"
                    expected = -(Float64.(parameters[:reconstructor]) * vec(permutedims(products["reference-pixels"])))
                    # Float64 reduction order may differ before the required Float32 publication.
                    @test isapprox(products["modal-reference"],Float32.(expected);rtol=8eps(Float32),atol=0)
                else
                    @test iszero(products["modal-reference"])
                    @test iszero(products["reference-pixels"])
                end
                if report["qualification_numerically_valid"]
                    difference = products["qualification-reference-pixels"] .- products["reference-pixels"]
                    @test products["qualification-reference-difference"] == difference
                    @test report["qualification_reference_difference_rms_dimensionless"] == sqrt(sum(abs2,difference)/length(difference))
                    @test report["qualification_reference_difference_maximum_dimensionless"] == maximum(abs,difference)
                end
                if haskey(ENV,"PIPEWIREAORTC_PYRAMID_REFERENCE_EVIDENCE")
                    PipeWireAORTC.Common.write_yaml(ENV["PIPEWIREAORTC_PYRAMID_REFERENCE_EVIDENCE"],report;
                        header="Generated by test/pyramid_reference_calibration.jl; candidate receipt only, no raw history retained.")
                end
                # Cancel after known Hold: exact restoration/release must finish,
                # no partial candidate may be published, and the private core stays alive.
                cancelled = Ref(false)
                cancel_confirm = function (request,witness)
                    cancelled[] = true
                    PipeWireAORTC.CalibrationPreparation.Confirmation(request;
                        observed_at=Ext.Control.monotonic(),witness)
                end
                cancelled_output = joinpath(directory,"cancelled")
                @test_throws InterruptException C.calibrate_references(application,cancelled_output;
                    remote,reference,timeout_s=600,cancelled=()->cancelled[],confirm=cancel_confirm)
                @test !ispath(cancelled_output)
                @test sort(readdir(directory)) == ["candidate"]
                @test !Base.process_exited(daemon)
            end
        end
        @test all(parameters[name] == values for (name,values) in original)
        @test Ext.reference_application_hashes(application) == before
        @test source === nothing || Ext.reference_application_hashes(source) == source_before
    end
end
@test !any(id.name in ("CUDA","AMDGPU") for id in keys(Base.loaded_modules))
end
