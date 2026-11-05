# Optional CPU selector: real exposure/detector/frontend graphs; no core or service.
using Test, LinearAlgebra, PipeWireAORTC, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL, Proper
using AdaptiveOpticsCalibration, FilterGraphAlgorithms, FilterGraphIsland, FilterGraphPipeWire, JuliaFilterGraph
using AdaptiveOpticsSim.AlgorithmGraphs
const IC = PipeWireAORTC.InstrumentConfiguration
const Calibration = Base.get_extension(PipeWireAORTC,:PipeWireAORTCCalibrationExt)
include(joinpath(@__DIR__,"external_optical_documents.jl"))
include(joinpath(@__DIR__,"chopped_calibration_documents.jl"))

@testset "optical calibration executes the declared detector exposure and chopped prefix" begin
    mktempdir() do directory
        upstream_directory = joinpath(directory,"upstream")
        mkpath(upstream_directory)
        upstream_physical, upstream_simulation = external_optical_documents()
        PipeWireAORTC.Common.write_json(joinpath(upstream_directory,"mirror.json"), Dict("schema_version"=>1,
            "id"=>"test-mirror","manufacturer"=>"Example","model"=>"Synthetic",
            "layout"=>Dict("schema_version"=>1,"name"=>"Test grid","grid_shape"=>[2,2],
                "command_positions"=>[[1,1],[2,2]],"axis_labels"=>["column","row"],"command_order"=>"physical")))
        upstream_physical["optical_output"] = deepcopy(upstream_physical["optical_input"])
        upstream_physical["telescope"] = Dict("telescope_diameter_m"=>0.012,"central_obstruction_ratio"=>0.0,
            "pupil_reflectivity"=>1.0,"aperture_revision"=>1)
        upstream_physical["deformable_mirrors"] = Dict("primary"=>Dict("description"=>"mirror.json",
            "pupil_registration"=>Dict("actuator_pitch_pupil_radius"=>0.2),"units"=>"m","command_scale_m"=>1))
        upstream_simulation["defaults"]["profile"] = "grid_gaussian"
        upstream_simulation["settings_schema"]["properties"]["profile"]["enum"] = ["grid_gaussian"]
        upstream_simulation["profiles"] = Dict("grid_gaussian"=>Dict("template"=>"grid_gaussian"))
        upstream_simulation["bindings"] = Dict("command"=>Dict("kind"=>"zeros","type"=>"Float32","shape"=>[2]))
        upstream_simulation["components"] = Dict("primary"=>Dict("template"=>"deformable_mirror","mirror"=>"primary",
            "coupling"=>0.15,"config"=>Dict("surface_opd_schema"=>"example.surface/1","pdm_command_schema"=>"example.command/1",
                "actuator_grid_indices_schema"=>"example.grid/1")))
        upstream_simulation["graphs"] = Dict("calibration"=>Dict("schema_version"=>1,"name"=>"mirror_calibration",
            "nodes"=>[Dict("name"=>"primary")],"inputs"=>[Dict("name"=>"command","binding"=>"command","destination"=>"primary.pdm_command")],
            "outputs"=>[Dict("name"=>"opd","source"=>"primary.surface_opd")]))
        upstream_path = write_external_optical_documents(upstream_directory,upstream_physical,upstream_simulation)
        physical, simulation = external_optical_documents()
        physical["optical_paths"] = Dict("scc"=>Dict("sensor"=>"scc","lyot_stop_port"=>"transmitted"))
        physical["wavefront_sensors"]["scc"]["detector"] = Dict("name"=>"CRED2","rows"=>12,"columns"=>14,"pixel_sampling_m"=>[0.003,0.003])
        physical["wavefront_sensors"]["scc"]["acquisition"] = Dict("exposure_duration_s"=>0.002)
        config = simulation["components"]["optics"]["config"]
        config["steps"] = [Dict("op"=>"multiply","amplitude"=>0.5),Dict("op"=>"propagate","distance_m"=>0.01)]
        unfringed = deepcopy(simulation["graphs"]["scc"])
        unfringed["nodes"] = [Dict("name"=>"optics","type"=>"proper_optical_train_f64","config"=>deepcopy(config))]
        unfringed["nodes"][1]["config"]["steps"][1]["amplitude"] = 0.25
        simulation["graphs"] = Dict{String,Any}("scc"=>simulation["graphs"]["scc"],"unfringed"=>unfringed)
        path = write_external_optical_documents(joinpath(directory,"optical"),physical,simulation)
        authored_response!(dirname(dirname(path)),physical,simulation)
        simulation["observations"]["scc"] = pop!(simulation["observations"],"low_order")
        simulation["observations"]["scc"]["graph"] = "scc_response"
        simulation["graphs"]["scc_response"] = "simulation/low_order_response.yaml"
        selection = simulation["components"]["low_order_detector"]
        selection["sensor"] = "scc"
        detector = selection["config"]
        detector["pixel_sampling_m"] = [0.003,0.003]
        detector["photon_noise"] = false
        detector["readout_noise"] = false
        write_external_optical_documents(dirname(dirname(path)),physical,simulation)
        chopping = (scc=(unfringed_graph="unfringed",initial_phase="fringed",trigger_high_is_fringed=true),)
        plan = (;rtc=(;document=Dict("dimensions"=>Dict("image_rows"=>8,"image_columns"=>8,"selected_pixel_count"=>64)),
                controls=Dict("deformable_mirrors"=>Dict())),
            frames=Dict("scc"=>Dict("frame_schema"=>detector["frame_schema"],
                "image_shape"=>[detector["rows"],detector["columns"]])),
            instrument=Dict("deformable_mirrors"=>Dict(),"wavefront_sensors"=>Dict()),
            templates=(scc=chopped_calibration_document((8,8)),),chopping)
        options = (;mirror="primary",branches=(scc="scc",),chopping,publication_plan=plan)
        callbacks = Calibration.optical_callbacks(upstream_path,path;options...)
        @test callbacks.exposure_plant !== nothing
        @test callbacks.provenance["observation_quantity"]["scc"] == "declared_detector_output"
        scale = 100 * 0.002 * 0.8
        ideal_f = Array(graph_output(callbacks.systems.scc.graph,:intensity))
        ideal_u = Array(graph_output(callbacks.unfringed_systems.scc.graph,:intensity))
        @test callbacks.chopped_references.scc.fringed ≈ ideal_f .* scale
        @test callbacks.chopped_references.scc.unfringed ≈ ideal_u .* scale
        @test all(iszero,callbacks.observe(zeros(Float32,4,4)).scc)
        opd = callbacks.surface(Float32[1e-8,-2e-8])
        first = callbacks.observe(opd).scc
        @test norm(first)>0
        @test callbacks.observe(opd).scc == first
        calibrated = PipeWireAORTC.InstrumentCalibration.calibrate_optical(callbacks.surface,callbacks.observe,
            Matrix{Float32}(I,2,2);pupil_support=callbacks.pupil_support,branch_modes=(scc=1:2,),
            pixel_masks=(scc=trues(8,8),),poke_m=1e-8,tsvd_rtol=1e-5,
            derivative_tolerance=0.05,reconstruction_tolerance=0.05,signed_measurements=(:scc,),provenance=callbacks.provenance)
        @test calibrated.report["status"] == "accepted"
        @test calibrated.validation.accepted
        @test calibrated.report["branches"]["scc"]["measurement_units"] == "electron"
        @test calibrated.report["branches"]["scc"]["frame_schema"] == detector["frame_schema"]
        calibrated = merge(calibrated,(;chopped_references=callbacks.chopped_references))
        publication = PipeWireAORTC.InstrumentCalibration.calibrate_optical(calibrated,joinpath(directory,"bundle");
            report=Dict("recipe"=>Dict("kind"=>"relative-intensity-optical"),
                "source_prescription_identity"=>"detector-observation-test","source_graph_sha256"=>repeat("a",64)),
            context=Dict(),concrete_graph=chopped_calibration_document((8,8)),branch=:scc)
        for name in ("flat-fringed","flat-unfringed","flat-difference","reference-difference","reference-image")
            IC.FITSIO.FITS(joinpath(directory,"bundle","artifacts","scc-"*name*".fits"),"r") do file
                @test IC.FITSIO.read_header(file[1])["BUNIT"] == "electron"
            end
        end
        detector["photon_noise"] = true
        write_external_optical_documents(dirname(dirname(path)),physical,simulation)
        @test_throws ArgumentError Calibration.optical_callbacks(upstream_path,path;options...)
        # An unselected independent noisy camera cannot change the selected SCC
        # intensity reference or impose its detector calibration restrictions.
        physical["optical_paths"]["llowfs"] = Dict("sensor"=>"llowfs","lyot_stop_port"=>"reflected")
        simulation["graphs"]["llowfs"] = deepcopy(simulation["graphs"]["scc"])
        simulation["observations"]["llowfs"] = pop!(simulation["observations"],"scc")
        selection["sensor"] = "llowfs"
        write_external_optical_documents(dirname(dirname(path)),physical,simulation)
        mixed = Calibration.optical_callbacks(upstream_path,path;options...)
        @test mixed.provenance["observation_quantity"]["scc"] == "relative_intensity"
        @test mixed.chopped_references.scc.fringed ≈ Array(graph_output(mixed.systems.scc.graph,:intensity))
        @test all(iszero,mixed.observe(zeros(Float32,4,4)).scc)
        # The 2 ms pupil interval crosses the selected camera's 3 ms phase
        # boundary. AOS executes both variants and integrates each segment.
        physical["wavefront_sensors"]["scc"]["acquisition"]["exposure_duration_s"] = 0.003
        simulation["observations"]["scc"] = pop!(simulation["observations"],"llowfs")
        selection["sensor"] = "scc"
        detector["photon_noise"] = false
        detector["exposure_duration_s"] = 0.003
        write_external_optical_documents(dirname(dirname(path)),physical,simulation)
        asymmetric = Calibration.optical_callbacks(upstream_path,path;options...)
        @test asymmetric.chopped_references.scc.fringed ≈ 1.5 .* callbacks.chopped_references.scc.fringed
        @test asymmetric.chopped_references.scc.unfringed ≈ 1.5 .* callbacks.chopped_references.scc.unfringed
        allowance = 4eps(Float32)*norm(asymmetric.chopped_references.scc.difference)
        @test asymmetric.observe(opd).scc ≈ 1.5 .* first rtol=2e-3 atol=allowance
        @test asymmetric.exposure_plant.state.last_end_ns == 6_000_000
        @test asymmetric.exposure_plant.exposures.scc.sequence == 2
    end
end
