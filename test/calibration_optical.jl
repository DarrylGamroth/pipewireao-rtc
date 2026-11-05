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
        const FGA = Base.require(Base.PkgId(Main.UUID("8914fa96-dfe6-4d3c-aced-40e6da1f6420"),"FilterGraphAlgorithms"))
        include(joinpath(@__DIR__,"..","ext","optical_calibration.jl"))
    end
end

@testset "native mirror units normalize through the measured OPD response" begin
    # A 1 µm/native-unit response used to fail a dimensionful null-mode test.
    surface = command -> reshape(Float32[command[1],-command[1],command[2],-command[2]],2,2) .* 1f-6
    observe = opd -> (;scc=1f0 .+ opd .* 1f6)
    projection = Float32[1 1;1 -1]
    result = OpticalCalibration.calibrate_optical(surface,observe,projection;
        pupil_support=trues(2,2),branch_modes=(scc=1:2,),pixel_masks=(scc=trues(2,2),),
        poke_m=1f-8,normalization_probe=0.01f0,tsvd_rtol=1f-5,
        derivative_tolerance=0.001,reconstruction_tolerance=0.001,
        provenance=Dict("mirror_response"=>Dict("command_units"=>"native command")))
    @test result.report["physical_projection"]["command_projection_units"] == "native command / m OPD"
    @test result.report["physical_projection"]["physical_to_modes_units"] == "m OPD / native command"
    mktempdir() do directory
        output = joinpath(directory,"bundle")
        report = Dict("recipe"=>Dict("kind"=>"linear-test"),"source_prescription_identity"=>"test", "source_graph_sha256"=>repeat("a",64))
        OpticalCalibration.calibrate_optical(result,output;report,context=Dict(),concrete_graph=Dict("filter.graph"=>Dict("nodes"=>[],"links"=>[])))
        FITSIO = PipeWireAORTC.Artifacts.FITSIO
        for (file,units) in (("command-projection.fits","native command / m OPD"),("physical-to-modes.fits","m OPD / native command"))
            FITSIO.FITS(joinpath(output,"artifacts",file),"r") do fits
                @test FITSIO.read_header(fits[1])["BUNIT"] == units
            end
        end
    end
    @test result.report["status"] == "accepted"
    @test result.normalization ≈ fill(1f-6,2)
    @test result.projection ≈ projection .* 1f6
    @test result.physical_to_modes * result.projection ≈ Matrix{Float32}(I,2,2) atol=1e-5
    @test result.validation.accepted
    @test_throws ArgumentError OpticalCalibration.calibrate_optical(surface,observe,projection;
        pupil_support=trues(2,2),branch_modes=(scc=1:2,),pixel_masks=(scc=trues(2,2),),
        poke_m=1f-8,normalization_probe=0,tsvd_rtol=1f-5)
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

@testset "masked CoG and SCC share ten modes with disjoint authority" begin
    implementation = Base.get_extension(PipeWireAORTC,:PipeWireAORTCCalibrationExt)
    implementation === nothing && (implementation=OpticalCalibrationTestImplementation)
    mask = Bool[1 0 1;1 1 0]
    rectangle = Dict("kind"=>"rectangle","rows"=>[1,2],"columns"=>[2,3])
    @test implementation.optical_rectangle_mask(rectangle,(2,3)) == Bool[0 1 1;0 1 1]
    @test_throws ArgumentError implementation.optical_rectangle_mask(rectangle,(2,2))
    for invalid in (merge(rectangle,Dict("rows"=>[0,2])),merge(rectangle,Dict("columns"=>[3,2])),
            merge(rectangle,Dict("rows"=>Any[true,2])),merge(rectangle,Dict("unknown"=>1)))
        @test_throws ArgumentError implementation.optical_rectangle_mask(invalid,(2,3))
    end
    @test implementation.optical_centroid_coordinates(mask) == Float32[1 1;3 1;1 2;2 2]
    @test implementation.optical_centroid(Float32[1 100 3;2 4 200],mask) ≈ Float32[2,1.6]
    @test_throws ArgumentError implementation.optical_centroid(zeros(Float32,2,3),mask)
    @test_throws ArgumentError implementation.optical_centroid(fill(Float32(Inf),2,3),mask)
    @test_throws ArgumentError implementation.optical_centroid(fill(-1f0,2,3),mask)
    @test_throws ArgumentError implementation.optical_centroid(fill(floatmax(Float32),2,3),mask)
    surface = command -> reshape(vcat(command,-sum(command),0f0),3,4)
    observe = opd -> begin
        x,y = opd[1],opd[2]
        (;llowfs=Float32[1-x-y 100 1+x;1+y 1 200],scc=10f0 .+ opd)
    end
    calibration = OpticalCalibration.calibrate_optical(surface,observe,Matrix{Float32}(I,10,10);
        pupil_support=trues(3,4),branch_modes=(llowfs=1:2,scc=3:10),
        pixel_masks=(llowfs=mask,scc=trues(3,4)),centroid_measurements=(:llowfs,),
        poke_m=.01f0,tsvd_rtol=1f-5,derivative_tolerance=.001,reconstruction_tolerance=.001)
    branch = calibration.branches.llowfs
    @test branch.measurement_kind === implementation.CenterOfGravity()
    @test calibration.branches.scc.measurement_kind === implementation.SelectedPixels()
    @test calibration.command_coordinates === implementation.PhysicalCommandCoordinates()
    @test implementation.optical_measurement_count(branch.measurement_kind,branch) == 2
    # Extra diagnostic fields cannot change a prepared selected-pixel branch's
    # algorithm, identity fields or admission to centroid-only nulling.
    pixel = merge(calibration.branches.scc,(coordinates=zeros(Float32,12,2),reference_centroid=zeros(Float32,2)))
    @test implementation.optical_measurement(pixel.reference,pixel) == implementation.optical_pixels(pixel.reference,pixel.mask)
    @test implementation.optical_measurement_count(pixel.measurement_kind,pixel) == 12
    diagnostic_branches = merge(calibration.branches,(scc=pixel,))
    @test implementation.optical_identity(calibration.projection,calibration.physical_to_modes,diagnostic_branches) ==
        implementation.optical_identity(calibration.projection,calibration.physical_to_modes,calibration.branches)
    @test_throws ArgumentError("measurement nulling requires a centroid branch") implementation.optical_nulling_projection(
        merge(calibration,(branches=diagnostic_branches,)),:scc;tsvd_rtol=1f-5)
    @test calibration.report["status"] == "accepted"
    @test size(branch.reconstructor) == (10,2)
    @test branch.retained_rank == 2
    @test branch.reference_centroid == Float32[1.75,1.5]
    @test branch.interaction[:,1:2] ≈ Float32[.5calibration.projection[1,1] 0;0 .25calibration.projection[2,2]] rtol=1e-4
    @test all(iszero,branch.reconstructor[3:10,:])
    @test all(iszero,calibration.branches.scc.reconstructor[1:2,:])
    @test branch.recovery ≈ Diagonal(Float32[1,1,0,0,0,0,0,0,0,0]) atol=1e-4
    @test branch.cross_talk == 0
    @test calibration.physical_to_modes*calibration.projection ≈ Matrix{Float32}(I,10,10) atol=1e-5
    @test calibration.validation.accepted
    @test calibration.report["branches"]["llowfs"]["measurement_units"] == "px"
    mktempdir() do directory
        report = Dict("recipe"=>Dict("kind"=>"linear-test"),"source_prescription_identity"=>"test",
            "source_graph_sha256"=>repeat("a",64))
        OpticalCalibration.calibrate_optical(calibration,joinpath(directory,"llowfs");report,
            context=Dict{String,Any}(),concrete_graph=Dict("filter.graph"=>Dict("nodes"=>[],"links"=>[])),branch=:llowfs)
        bundle = OpticalCalibration.read_bundle(joinpath(directory,"llowfs"))
        @test "llowfs-coordinates" in bundle.parameter_names
        @test haskey(bundle.artifacts,"llowfs-reference-centroid.fits")
        artifact = name -> PipeWireAORTC.Artifacts.prepare(PipeWireAORTC.Artifacts.FITSArtifact(
            bundle.artifacts[name*".fits"];axes=(2,1)),Float32,size(getproperty(branch,Symbol(name=="llowfs-coordinates" ? "coordinates" : "reconstructor")))).data
        @test artifact("llowfs-coordinates") == branch.coordinates
        @test artifact("llowfs-reconstructor") == branch.reconstructor
    end
end

@testset "Fourier commands exclude measured physical pupil tip and tilt" begin
    coordinates = Float64[point[column] for point in collect(Iterators.product(range(-.8,.9;length=6),range(-.7,.6;length=6)))[:],column in 1:2]
    # Nonuniform native response deliberately makes coordinate-space and
    # measured pupil-space orthogonalization differ.
    weights = Float32.(range(.6,1.4;length=36))
    surface = command -> reshape(vcat(weights.*command,-sum(weights.*command)),1,37)
    observe = opd -> (;scc=10f0 .+ opd)
    calibration = OpticalCalibration.calibrate_optical(surface,observe;
        actuator_coordinates=coordinates,controlled_actuators=trues(36),tip_tilt=true,
        spatial_frequencies=Float64[.5 0;0 .5;1 0;0 1],pupil_support=trues(1,37),
        branch_modes=(scc=1:10,),pixel_masks=(scc=trues(1,37),),
        poke_m=.01f0,tsvd_rtol=1f-5,derivative_tolerance=.001,reconstruction_tolerance=.001)
    @test size(calibration.projection) == (36,10)
    @test calibration.report["provenance"]["basis"]["kind"] == "tip-tilt-and-sinusoidal"
    @test maximum(abs,calibration.pupil_modes[:,1:2]'*calibration.pupil_modes[:,3:10])/37 < 1e-6
    @test calibration.validation.accepted
    # The detector responds to a higher pupil mode as well as tip/tilt.
    # Nulling that response must retain the original pupil-removal provenance
    # while admitting the compensating pupil tip/tilt in the final basis.
    modal_inverse = pinv(calibration.pupil_modes)
    measured = opd -> begin
        coefficients = modal_inverse*vec(opd)
        x,y = 10coefficients[1]+6coefficients[3],10coefficients[2]
        (;llowfs=Float32[1-x-y 100 1+x;1+y 1 200],scc=observe(opd).scc)
    end
    nulled = OpticalCalibration.calibrate_optical(surface,measured;
        actuator_coordinates=coordinates,controlled_actuators=trues(36),tip_tilt=true,
        spatial_frequencies=Float64[.5 0;0 .5;1 0;0 1],pupil_support=trues(1,37),
        branch_modes=(llowfs=1:2,scc=3:10),pixel_masks=(llowfs=Bool[1 0 1;1 1 0],scc=trues(1,37)),
        centroid_measurements=(:llowfs,),measurement_nulling=(:llowfs,),poke_m=.01f0,tsvd_rtol=1f-5)
    basis = nulled.report["provenance"]["basis"]
    @test basis["tip_tilt_removal"] == calibration.report["provenance"]["basis"]["tip_tilt_removal"]
    @test basis["source_mode_order"] == calibration.report["provenance"]["basis"]["mode_order"]
    @test occursin("compensation",basis["mode_order"])
    @test maximum(abs,nulled.pupil_modes[:,1:2]'*nulled.pupil_modes[:,3:10])/37 > .1
    @test nulled.validation.accepted
end

@testset "explicit centroid measurement nulling removes higher-mode leakage" begin
    largest_command = Ref(0f0)
    surface = command -> begin
        largest_command[] = max(largest_command[],maximum(abs,command))
        maximum(abs,command) < .1f0 || throw(ArgumentError("native normalization probe exceeded its declared scale"))
        reshape(1f-6 .* vcat(command,-sum(command),0f0),2,3)
    end
    observe = opd -> begin
        x,y,higher = 1f6 .* opd[1:3]
        (;llowfs=Float32[1-x-.6higher-y 100 1+x+.6higher;1+y 1 200],scc=10f0 .+ 1f6 .* opd)
    end
    options = (;pupil_support=trues(2,3),branch_modes=(llowfs=1:2,scc=3:4),
        pixel_masks=(llowfs=Bool[1 0 1;1 1 0],scc=trues(2,3)),centroid_measurements=(:llowfs,),
        poke_m=1f-9,normalization_probe=.005f0,tsvd_rtol=1f-5,
        provenance=Dict("mirror_response"=>Dict("command_units"=>"native command")))
    projection = Matrix{Float32}(I,4,4)
    leaking = OpticalCalibration.calibrate_optical(surface,observe,projection;options...,require_observable=false)
    @test leaking.report["status"] == "rejected"
    @test maximum(leaking.validation.reconstruction_errors) > .2
    @test leaking.branches.llowfs.cross_talk > .3
    corrected = OpticalCalibration.calibrate_optical(surface,observe,projection;
        options...,measurement_nulling=(:llowfs,))
    @test corrected.report["status"] == "accepted"
    @test corrected.validation.accepted
    @test corrected.branches.llowfs.cross_talk < .01
    @test corrected.report["derivative_tolerance"] == corrected.report["reconstruction_tolerance"] == .05
    @test largest_command[] < .1f0
    record = corrected.report["provenance"]["measurement_nulling"]
    @test record["branch"] == "llowfs"
    @test record["owned_modes"] == [1,2]
    @test record["unowned_modes"] == [3,4]
    @test record["response_units"] == "px / m OPD"
    @test record["coefficient_units"] == "1"
    @test record["source_calibration_identity"] == leaking.report["calibration_identity"]
    @test maximum(record["column_scales"]) > 1f6
    @test !haskey(leaking.report["provenance"],"measurement_nulling")
    metadata = merge(options.provenance,Dict("basis"=>Dict("kind"=>"authored")))
    authored = OpticalCalibration.calibrate_optical(surface,observe,projection;
        options...,provenance=metadata,measurement_nulling=(:llowfs,))
    @test authored.report["provenance"]["basis"] == metadata["basis"] == Dict("kind"=>"authored")
    implementation = Base.get_extension(PipeWireAORTC,:PipeWireAORTCCalibrationExt)
    implementation === nothing && (implementation=OpticalCalibrationTestImplementation)
    zero_response = deepcopy(leaking)
    zero_response.branches.llowfs.interaction[:,3:4] .= 0
    proposed = implementation.optical_nulling_projection(zero_response,:llowfs;tsvd_rtol=options.tsvd_rtol)
    @test proposed.record["relative_null_residual"] == 0
    mktempdir() do directory
        report = Dict("recipe"=>Dict("kind"=>"linear-test"),"source_prescription_identity"=>"test",
            "source_graph_sha256"=>repeat("a",64))
        OpticalCalibration.calibrate_optical(corrected,joinpath(directory,"nulled");report,context=Dict(),
            concrete_graph=Dict("filter.graph"=>Dict("nodes"=>[])))
        retained = OpticalCalibration.read_bundle(joinpath(directory,"nulled")).report["provenance"]["measurement_nulling"]
        @test retained["source_calibration_identity"] == leaking.report["calibration_identity"]
        @test retained["source_status"] == "rejected"
        @test retained["retained_rank"] == 2
    end
    for invalid in ((:scc,),(:missing,),(:llowfs,:llowfs),(:llowfs,:scc))
        @test_throws ArgumentError OpticalCalibration.calibrate_optical(surface,observe,projection;
            options...,measurement_nulling=invalid)
    end
    blind = opd -> begin
        x,higher = 1f6*opd[1],1f6*opd[3]
        (;llowfs=Float32[1-x-.6higher 100 1+x+.6higher;1 1 200],scc=observe(opd).scc)
    end
    @test_throws ArgumentError OpticalCalibration.calibrate_optical(surface,blind,projection;
        options...,measurement_nulling=(:llowfs,))
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
        ten_mode = merge(recipe,Dict("tip_tilt"=>true,
            "measurements"=>Dict("llowfs"=>Dict("kind"=>"center-of-gravity")),
            "branch_modes"=>Dict("llowfs"=>[1,2],"scc"=>collect(3:10)),
            "held_out_coefficients"=>[[1e-10] for _ in 1:10]))
        PipeWireAORTC.Common.write_yaml(path,ten_mode)
        @test implementation.optical_recipe(directory,"calibration/optical.yaml").branch_modes ==
            (llowfs=[1,2],scc=collect(3:10))
        PipeWireAORTC.Common.write_yaml(path,merge(ten_mode,Dict("measurement_nulling"=>["llowfs"])))
        @test implementation.optical_recipe(directory,"calibration/optical.yaml").document["measurement_nulling"] == ["llowfs"]
        for invalid in ("llowfs",["missing"],["scc"],["llowfs","llowfs"],["llowfs","scc"],[1])
            PipeWireAORTC.Common.write_yaml(path,merge(ten_mode,Dict("measurement_nulling"=>invalid)))
            @test_throws ArgumentError implementation.optical_recipe(directory,"calibration/optical.yaml")
        end
        PipeWireAORTC.Common.write_yaml(path,merge(ten_mode,Dict("tip_tilt"=>1)))
        @test_throws ArgumentError implementation.optical_recipe(directory,"calibration/optical.yaml")
        measurements=Dict("scc"=>Dict("kind"=>"chopped-pixel-residual"))
        PipeWireAORTC.Common.write_yaml(path,merge(recipe,Dict("measurements"=>measurements)))
        @test implementation.optical_recipe(directory,"calibration/optical.yaml").document["measurements"]==measurements
        for invalid in (Dict("other"=>Dict("kind"=>"chopped-pixel-residual")),
                Dict("scc"=>Dict("kind"=>"guessed")),Dict("scc"=>Dict("kind"=>"chopped-pixel-residual","gain"=>1)),[])
            PipeWireAORTC.Common.write_yaml(path,merge(recipe,Dict("measurements"=>invalid)))
            @test_throws ArgumentError implementation.optical_recipe(directory,"calibration/optical.yaml")
        end
        reference = Dict("raw_endpoint"=>"pixel-calibration:raw",
            "residual_endpoint"=>"reconstruction:reconstructed","poke_amplitudes_m"=>[5e-9],
            "derivative_tolerance"=>.05,"method"=>"host-expectation","samples"=>512,
            "rounding_samples"=>128,"training_seed"=>200002,"validation_seed"=>400002)
        PipeWireAORTC.Common.write_yaml(path,merge(recipe,Dict("upstream_reference"=>reference)))
        @test implementation.optical_recipe(directory,"calibration/optical.yaml").document["upstream_reference"]["method"] == "host-expectation"
        for (key,value) in (("method","guessed"),("samples",127),("rounding_samples",513),
                ("validation_seed",200002),("poke_amplitudes_m",[5e-9,1e-8]),("method","held-frame"))
            invalid = merge(recipe,Dict("upstream_reference"=>merge(reference,Dict(key=>value))))
            PipeWireAORTC.Common.write_yaml(path,invalid)
            @test_throws ArgumentError implementation.optical_recipe(directory,"calibration/optical.yaml")
        end
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

@testset "Host expected-response uncertainty and qualified cold envelope" begin
    implementation = Base.get_extension(PipeWireAORTC,:PipeWireAORTCCalibrationExt)
    implementation === nothing && (implementation=OpticalCalibrationTestImplementation)
    document = Dict("filter.graph"=>Dict("nodes"=>[
        Dict("name"=>"raw","label"=>"pixel-calibration-u16-f32"),
        Dict("name"=>"pupils","label"=>"pyramid-pupil-image-f32"),
        Dict("name"=>"residual","label"=>"pwfs-pupil-reconstructor-f32")]))
    @test implementation.optical_expectation_nodes(document) ==
        (raw="raw",pyramid="pupils",reconstruction="residual")
    chain = Dict("nodes"=>[
        Dict("name"=>"detector","type"=>"detector","config"=>Dict("photon_noise"=>true)),
        Dict("name"=>"adc","type"=>"detector_frame_layout_f32","config"=>Dict("bias"=>1024))],
        "links"=>[Dict("source"=>"pyramid.photon_rate","destination"=>"detector.photon_rate"),
            Dict("source"=>"detector.frame","destination"=>"adc.detector_frame")],
        "outputs"=>[Dict("name"=>"frame","source"=>"adc.frame"),
            Dict("name"=>"photon_rate","source"=>"pyramid.photon_rate")])
    @test implementation.optical_expectation_chain(chain,deepcopy(chain),"frame")["photon_source"] == "pyramid.photon_rate"
    for (section,index,key,value) in (("links",2,"source","pyramid.photon_rate"),
            ("outputs",1,"source","detector.frame"),("outputs",2,"source","another.photon_rate"))
        invalid = deepcopy(chain)
        invalid[section][index][key] = value
        # All admitted detector/ADC cold settings are unchanged by this rewire.
        @test invalid["nodes"] == chain["nodes"]
        @test_throws ArgumentError implementation.optical_expectation_chain(invalid,chain,"frame")
        @test_throws ArgumentError implementation.optical_expectation_chain(chain,invalid,"frame")
    end
    for section in ("inputs","delayed_links")
        invalid = deepcopy(chain)
        invalid[section] = [Dict("destination"=>"detector.photon_rate","binding"=>"competing",
            "source"=>"another.photon_rate")]
        @test_throws ArgumentError implementation.optical_expectation_chain(invalid,chain,"frame")
        @test_throws ArgumentError implementation.optical_expectation_chain(chain,invalid,"frame")
    end
    invalid = deepcopy(chain)
    invalid["nodes"][2]["config"]["bias"] = 1025
    @test_throws ArgumentError implementation.optical_expectation_chain(chain,invalid,"frame")
    @test implementation.optical_standard_error([1.0,3.0]) ≈ 1
    @test implementation.optical_standard_error([1e-10,3e-10]) ≈ 1e-10
    @test implementation.optical_vector_standard_error([[1.0,0.0],[0.0,1.0]],[.5,.5]) ≈ inv(sqrt(2))
    @test_throws ArgumentError implementation.optical_standard_error([1.0])
    @test isnothing(implementation.optical_expectation_options(512,128,200002,400002))
    @test_throws ArgumentError implementation.optical_expectation_options(512,128,400003,400002)
    @test_throws ArgumentError implementation.optical_conditional_envelopes(
        gain=5000,factor=1,scale=1/64,bias=1024,readnoise_e=0)
    envelopes = implementation.optical_conditional_envelopes(
        gain=5000,factor=Float64(sqrt(2f0)^2-1f0)^.5,scale=1/64,bias=1024,readnoise_e=678.3218668753427)
    @test all(>(0),envelopes.adc)
    @test issorted(envelopes.adc)
    @test envelopes.calibrated_input_lipschitz > envelopes.adc_lipschitz > envelopes.adc[9]
    # Exact Host threshold mapping is distinct from the configured input mean.
    cic = Float32(.000828)
    @test implementation.optical_host_poisson_mean(cic) == -log(Float64(exp(-cic)))
    @test implementation.optical_host_poisson_mean(0) == 0
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

@testset "calibration mirror matches the executed physical model" begin
    implementation = Base.get_extension(PipeWireAORTC,:PipeWireAORTCCalibrationExt)
    implementation === nothing && (implementation = OpticalCalibrationTestImplementation)
    contract = Dict("nodes"=>[Dict("name"=>"dm","type"=>"measured","config"=>Dict("schema"=>"opd"))],
        "parameters"=>[Dict("destination"=>"dm.influences","binding"=>"measured")],
        "inputs"=>[Dict("name"=>"command","destination"=>"dm.pdm_command","binding"=>"zero")])
    copy = deepcopy(contract)
    @test implementation.verify_optical_mirror_identity(contract,copy,"dm") === nothing
    copy["parameters"][1]["binding"] = "other"
    @test_throws ArgumentError implementation.verify_optical_mirror_identity(contract,copy,"dm")
    copy = deepcopy(contract)
    copy["nodes"][1]["config"]["schema"] = "other"
    @test_throws ArgumentError implementation.verify_optical_mirror_identity(contract,copy,"dm")
end

@testset "clocked calibration uses the owner physical inputs and settings" begin
    implementation = Base.get_extension(PipeWireAORTC,:PipeWireAORTCCalibrationExt)
    implementation === nothing && (implementation = OpticalCalibrationTestImplementation)
    verify = implementation.verify_clocked_calibration_inputs
    options = (;source_amplitude_binding="pupil",plant=(;definition="model.yaml"))
    response = Dict("input"=>"dm_opd","pupil_amplitude"=>"pupil")
    settings = Dict("wavelength"=>1.55)
    branches = (;scc="scc")
    paths = Dict("scc"=>Dict(),"llowfs"=>Dict())
    @test verify(response,options,"model.yaml",settings,settings,branches,paths) === nothing
    @test_throws ArgumentError verify(merge(response,Dict("input"=>"pupil_opd")),options,"model.yaml",settings,settings,branches,paths)
    @test_throws ArgumentError verify(merge(response,Dict("pupil_amplitude"=>"other")),options,"model.yaml",settings,settings,branches,paths)
    @test_throws ArgumentError verify(response,options,"model.yaml",Dict("wavelength"=>1.6),settings,branches,paths)
    @test_throws ArgumentError verify(response,options,"other.yaml",settings,settings,branches,paths)
end

@testset "virtual mirror completion is measured and limited in physical coordinates" begin
    implementation = Base.get_extension(PipeWireAORTC,:PipeWireAORTCCalibrationExt)
    implementation === nothing && (implementation = OpticalCalibrationTestImplementation)
    completion = Float32[1 0; 0 1; 0.5 0.5; 0 0]
    direct = Bool[1,1,0,0]; healthy = Bool[1,1,1,0]
    @test implementation.validate_optical_completion(completion,direct,healthy) == [1,2]
    bad = copy(completion); bad[4,1] = 0.1
    @test_throws ArgumentError implementation.validate_optical_completion(bad,direct,healthy)
    bad = copy(completion); bad[1,1] = 0.9
    @test_throws ArgumentError implementation.validate_optical_completion(bad,direct,healthy)
    physical = command -> reshape(Float32[command[1],command[2],command[3],-sum(command)],2,2)
    domain = implementation.bounded_optical_surface(physical,fill(-0.2,4),fill(0.2,4))
    virtual = command -> domain.surface(completion*command)
    @test virtual(Float32[0.1,0.1]) == physical(Float32[0.1,0.1,0.1,0])
    @test_throws ArgumentError virtual(Float32[0.3,0])
    @test domain.record["tested_maximum_absolute_command"] ≈ 0.1
    result = OpticalCalibration.calibrate_optical(virtual,opd -> (;scc=1f0 .+ opd),Matrix{Float32}(I,2,2);
        pupil_support=trues(2,2),branch_modes=(scc=1:2,),pixel_masks=(scc=trues(2,2),),
        poke_m=0.01f0,normalization_probe=0.02f0,tsvd_rtol=1f-5,
        derivative_tolerance=0.001,reconstruction_tolerance=0.001)
    @test result.report["status"] == "accepted"
    @test size(result.projection) == (2,2) && size(result.physical_to_modes) == (2,2)
    @test result.physical_to_modes * result.projection ≈ Matrix{Float32}(I,2,2) atol=1e-5
end
