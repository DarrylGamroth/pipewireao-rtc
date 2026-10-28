# Optional bounded CPU selector. No PipeWire core, accelerator or optical source
# mutation. The linear plant establishes independent matrix/order/sign oracles;
# instrument propagation must additionally pass its own model replay.
using Test, LinearAlgebra, PipeWireAORTC, UUIDs
const OpticalCalibration = PipeWireAORTC.InstrumentCalibration

# The standalone CPU environment may expose AOC only as AOS's dependency. Load
# that exact resolved package, without resolving or modifying the environment.
const OpticalCalibrationAOC = Base.require(Base.PkgId(
    UUID("3c8b5851-926e-4ebb-af30-f8544b98d45f"),"AdaptiveOpticsCalibration"))
if Base.get_extension(PipeWireAORTC,:PipeWireAORTCCalibrationExt) === nothing
    @eval module OpticalCalibrationTestImplementation
        const PipeWireAORTC = Main.PipeWireAORTC
        const IC = PipeWireAORTC.InstrumentConfiguration
        const Calibration = Main.OpticalCalibration
        const AdaptiveOpticsCalibration = Main.OpticalCalibrationAOC
        const LA = Main.LinearAlgebra
        include(joinpath(@__DIR__,"..","ext","optical_calibration.jl"))
    end
end

@testset "physical optical calibration, row-major pixels and disjoint authority" begin
    # Physical commands produce different, non-unit pupil-RMS responses. Image
    # rows deliberately differ so a column-major pixel gather fails this oracle.
    response = Float32[1 0 0 0; 0 2 0 0; 0 0 3 0; 0 0 0 4; -1 -2 0 0; 0 0 -3 -4]
    surface = command -> reshape(response*command,2,3)
    observation = Float32[1 2 3 4 0 0; 0 1 2 3 4 0; 0 0 1 2 3 4; 4 0 0 1 2 3; 3 4 0 0 1 2; 2 3 4 0 0 1]
    observe = opd -> (llowfs=reshape(10f0 .+ observation*vec(opd),2,3),
        scc=reshape(12f0 .+ reverse(observation;dims=1)*vec(opd),2,3))
    support = trues(2,3)
    mask = Bool[1 1 1; 1 1 1]
    options = (;pupil_support=support,branch_modes=(llowfs=1:2,scc=3:4),
        pixel_masks=(llowfs=mask,scc=mask),poke_m=0.01f0,tsvd_rtol=1f-5,
        derivative_tolerance=0.01,reconstruction_tolerance=0.01)
    result = OpticalCalibration.calibrate_optical(surface,observe,Matrix{Float32}(I,4,4);options...)
    @test result.report["status"] == "accepted"
    @test result.report["validated_operating_domain"]["held_out_maximum_absolute_coefficient_m"] ≈ 0.00125
    @test first(result.report["validated_operating_domain"]["held_out_coefficient_norms_m"]) ≈ 0.0025
    @test result.physical_to_modes*result.projection ≈ Matrix{Float32}(I,4,4) atol=1e-5
    @test occursin(r"^sha256:[0-9a-f]{64}$",result.report["calibration_identity"])
    @test result.normalization ≈ sqrt.(vec(sum(abs2,response;dims=1))./6)
    @test all(j -> sqrt(sum(abs2,result.pupil_modes[:,j])/6) ≈ 1,1:4)
    # Julia vec order is [11,21,12,22,13,23]; the declared pixels are row-major.
    expected = (observation*response*result.projection)[[1,3,5,2,4,6],:]
    @test result.branches.llowfs.interaction ≈ expected rtol=1e-3
    @test result.branches.llowfs.recovery ≈ Diagonal(Float32[1,1,0,0]) atol=2e-5
    @test result.branches.scc.recovery ≈ Diagonal(Float32[0,0,1,1]) atol=2e-5
    @test all(iszero,result.branches.llowfs.reconstructor[3:4,:])
    @test all(iszero,result.branches.scc.reconstructor[1:2,:])
    validation = OpticalCalibration.validate_optical(surface,observe,result;
        coefficients=Float32[0.001 -0.002; -0.003 0.001; 0.002 0.003; -0.001 -0.001])
    @test validation.accepted
    @test maximum(validation.reconstruction_errors) < 0.001
    @test maximum(validation.pupil_rms_ratios) < 0.001
    @test result.validation.accepted
    mktempdir() do directory
        output = joinpath(directory,"optical")
        report = Dict("recipe"=>Dict("kind"=>"relative-intensity-optical"),
            "source_prescription_identity"=>"independent linear test plant",
            "source_graph_sha256"=>repeat("a",64))
        OpticalCalibration.calibrate_optical(result,output;report,context=Dict(),
            concrete_graph=Dict("filter.graph"=>Dict("nodes"=>[],"links"=>[])))
        bundle = OpticalCalibration.read_bundle(output)
        source = PipeWireAORTC.Artifacts.FITSArtifact(bundle.artifacts["command-projection.fits"];axes=(2,1))
        restored = PipeWireAORTC.Artifacts.prepare(source,Float32,size(result.projection)).data
        @test restored == result.projection
        @test bundle.report["held_out"]["accepted"]
        open(bundle.artifacts["command-projection.fits"],"a") do file
            write(file,UInt8(0))
        end
        @test_throws ArgumentError OpticalCalibration.read_bundle(output)
        branch_output = joinpath(directory,"llowfs")
        OpticalCalibration.calibrate_optical(result,branch_output;report,context=Dict{String,Any}(),
            concrete_graph=Dict("filter.graph"=>Dict("nodes"=>[],"links"=>[])),branch=:llowfs)
        branch_bundle = OpticalCalibration.read_bundle(branch_output)
        @test Set(branch_bundle.parameter_names) == Set(["command-projection","llowfs-reconstructor","llowfs-modal-reference"])
        @test haskey(branch_bundle.artifacts,"physical-to-modes.fits")
        @test branch_bundle.context["pixel_selection_mask"]["sha256"] == branch_bundle.report["artifact_sha256"]["selection-mask.fits"]
    end
    @test_throws ArgumentError OpticalCalibration.calibrate_optical(surface,observe,Matrix{Float32}(I,4,4);
        options...,branch_modes=(llowfs=1:3,scc=3:4))
    @test_throws ArgumentError OpticalCalibration.validate_optical(surface,observe,result;coefficients=zeros(4,1))

    blind = opd -> (llowfs=fill(10f0,2,3),scc=observe(opd).scc)
    rejected = OpticalCalibration.calibrate_optical(surface,blind,Matrix{Float32}(I,4,4);
        options...,require_observable=false)
    @test rejected.report["status"] == "rejected"
    @test rejected.branches.llowfs.retained_rank == 0
    @test rejected.branches.llowfs.recovery_error ≈ 1 rtol=eps(Float32)
    @test_throws ArgumentError OpticalCalibration.calibrate_optical(surface,blind,Matrix{Float32}(I,4,4);options...)

    nonlinear = opd -> begin
        changed = opd .+ 1f4 .* opd.^3
        observe(changed)
    end
    rejected = OpticalCalibration.calibrate_optical(surface,nonlinear,Matrix{Float32}(I,4,4);
        options...,require_observable=false)
    @test rejected.report["status"] == "rejected"
    @test rejected.branches.llowfs.derivative_error > options.derivative_tolerance
end

@testset "physical-unit upstream reference prediction errors" begin
    implementation = Base.get_extension(PipeWireAORTC,:PipeWireAORTCCalibrationExt)
    implementation === nothing && (implementation=OpticalCalibrationTestImplementation)
    measured = Float32[3e-9,4e-9]
    @test implementation.optical_reference_prediction_error(measured,zeros(Float32,2)) ≈ 1
    @test implementation.optical_reference_prediction_error(measured,measured./2) ≈ 0.5
    @test implementation.optical_reference_prediction_error(measured,measured) == 0
    @test implementation.optical_reference_prediction_error(measured.*1f9,measured.*5f8) ≈
        implementation.optical_reference_prediction_error(measured,measured./2)
    @test isinf(implementation.optical_reference_prediction_error(zeros(Float32,2),zeros(Float32,2)))
    # Independent linear response oracle for the acquisition callback kernel;
    # this establishes no detector or hardware model.
    interaction = Float64[2 1; -1 3; 4 -2]
    calibration = (projection=Matrix{Float32}(I,2,2),held_out_coefficients=Float32[1e-10 -2e-10; 2e-10 1e-10])
    measured = command -> (frame=fill(UInt16(1024),2,3),residual=interaction*Float64.(command))
    acquired = implementation.optical_reference_response(measured,calibration,Float32[5e-9],.05)
    @test acquired.chosen !== nothing
    @test acquired.chosen.interaction ≈ interaction
    @test maximum(only(acquired.trials)["held_out_errors"]) < 1e-6
end

@testset "scientific pupil publisher coordinates" begin
    @eval using AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL
    implementation = Base.get_extension(PipeWireAORTC,:PipeWireAORTCCalibrationExt)
    implementation === nothing && (implementation=OpticalCalibrationTestImplementation)
    publisher = Base.get_extension(PipeWireAORTC,:PipeWireAORTCAOSExt).PupilOutput
    opd = Float32[11 12 13; 21 22 23]
    amplitude = Float32[.1 .2 .3; .4 .5 .6]
    published = publisher.pack!(zeros(Float32,2,3,2),opd,amplitude)
    input_opd,input_amplitude = zeros(Float64,3,2),zeros(Float64,3,2)
    implementation.optical_pupil_inputs!(input_opd,input_amplitude,zeros(Float32,2,3,2),opd,amplitude)
    @test input_opd == published[1,:,:] == Float32[11 21; 12 22; 13 23]
    @test input_amplitude == published[2,:,:] == Float32[.1 .4; .2 .5; .3 .6]
end

@testset "bounded optical recipe and built-application boundary" begin
    mktempdir() do directory
        mkpath(joinpath(directory,"calibration"))
        recipe = Dict{String,Any}("version"=>1,"kind"=>"relative-intensity-optical",
            "upstream_simulation"=>"simulation/definition.yaml","optical_simulation"=>"generated/simulation.yaml",
            "mirror"=>"tweeter","branches"=>Dict("llowfs"=>"llowfs","scc"=>"scc"),
            "spatial_frequencies"=>[[.5,0],[0,.5],[1,0],[0,1]],
            "branch_modes"=>Dict("llowfs"=>[1,2,3,4],"scc"=>[5,6,7,8]),
            "controlled_actuators"=>Dict("kind"=>"declared-pupil"),"pixels"=>Dict("kind"=>"full-image"),
            "poke_m"=>5e-9,"tsvd_rtol"=>1e-4,"derivative_tolerance"=>.05,"reconstruction_tolerance"=>.05)
        path = joinpath(directory,"calibration","optical.yaml")
        PipeWireAORTC.Common.write_yaml(path,recipe)
        implementation = Base.get_extension(PipeWireAORTC,:PipeWireAORTCCalibrationExt)
        implementation === nothing && (implementation=OpticalCalibrationTestImplementation)
        parsed = implementation.optical_recipe(directory,"calibration/optical.yaml")
        @test parsed.frequencies == Float64[.5 0;0 .5;1 0;0 1]
        @test parsed.branch_modes == (llowfs=[1,2,3,4],scc=[5,6,7,8])
        @test_throws ArgumentError OpticalCalibration.calibrate_optical(directory,directory;target=nothing)
        for (key,value) in (("unknown",1),("version",true),("pixels",Dict("kind"=>"guessed")),
                ("branch_modes",Dict("llowfs"=>[1,2,3,4],"scc"=>[4,5,6,7,8])),("poke_m",0))
            invalid = merge(recipe,Dict(key=>value))
            PipeWireAORTC.Common.write_yaml(path,invalid)
            @test_throws ArgumentError implementation.optical_recipe(directory,"calibration/optical.yaml")
        end
        @test_throws ArgumentError implementation.optical_recipe(directory,"../outside.yaml")
    end
end

@testset "effective upstream execution settings" begin
    fixtures = Module(:OpticalExecutionFixtures)
    Core.eval(fixtures,:(const PipeWireAORTC = Main.PipeWireAORTC))
    Base.include(fixtures,joinpath(@__DIR__,"external_optical_documents.jl"))
    implementation = Base.get_extension(PipeWireAORTC,:PipeWireAORTCCalibrationExt)
    implementation === nothing && (implementation=OpticalCalibrationTestImplementation)
    mktempdir() do directory
        physical,simulation = fixtures.external_optical_documents()
        path = fixtures.write_external_optical_documents(directory,physical,simulation)
        execution = Dict("plant"=>Dict("definition"=>"simulation/definition.yaml","graph"=>"scc",
            "settings"=>Dict{String,Any}("resolution"=>16)))
        configuration = joinpath(directory,"simulation.conf")
        PipeWireAORTC.Common.write_json(configuration,execution)
        selected = implementation.optical_upstream_execution(directory,path,Dict())
        @test selected.effective["resolution"] == 16
        @test selected.effective["wavelength_um"] == 1.55
        @test selected.effective_settings_identity == PipeWireAORTC.InstrumentDefinition.scientific_identity(
            PipeWireAORTC.InstrumentConfiguration.canonical(selected.effective))
        @test_throws ArgumentError implementation.optical_upstream_execution(directory,path,Dict("resolution"=>32))
        execution["plant"]["settings"]["wavelength_um"] = 1.7
        PipeWireAORTC.Common.write_json(configuration,execution)
        changed = implementation.optical_upstream_execution(directory,path,Dict())
        @test changed.effective_settings_identity != selected.effective_settings_identity
        @test changed.execution_graph_identity != selected.execution_graph_identity
    end
end
