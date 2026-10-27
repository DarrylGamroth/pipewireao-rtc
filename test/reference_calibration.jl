# Optional science selector. Without an application it runs CPU numerical and
# contract checks only. Set PIPEWIREAORTC_REFERENCE_APPLICATION and --threads=4
# for the actual caller-owned private-core campaign and cancellation checks.
module ReferenceCalibrationTests
using Test, SHA
using PipeWireAORTC, FilterGraphIsland, FilterGraphPipeWire, JuliaFilterGraph
using AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL, AdaptiveOpticsCalibration

const C = PipeWireAORTC.InstrumentCalibration
const P = PipeWireAORTC.CalibrationPreparation
const R = AdaptiveOpticsCalibration.ReferenceFrames
const A = AdaptiveOpticsCalibration
const E = Base.get_extension(PipeWireAORTC,:PipeWireAORTCCalibrationExt)

function reference_recipe()
    Dict("references"=>Dict("source"=>"internal-source",
        "dark"=>Dict{String,Any}("samples"=>16,"discard_exposures"=>0),
        "lamp"=>Dict{String,Any}("samples"=>16,"discard_exposures"=>0),
        "qualification"=>Dict{String,Any}("samples"=>16,"discard_exposures"=>16)))
end

@testset "reference recipe bounds and independent reset-simulator windows" begin
    @test E !== nothing
    @test E.reference_counts(reference_recipe()) == (
        dark=(samples=16,discard=0),lamp=(samples=16,discard=0),qualification=(samples=16,discard=16))
    @test_throws ArgumentError E.reference_counts(Dict())
    for (stage,key,value) in (("dark","samples",1),("lamp","samples",0),
            ("lamp","samples",true),("lamp","samples",4097),
            ("dark","discard_exposures",-1),("qualification","discard_exposures",15),
            ("qualification","discard_exposures",4097),("lamp","unexpected",2))
        recipe = reference_recipe()
        recipe["references"][stage][key] = value
        @test_throws ArgumentError E.reference_counts(recipe)
    end
    recipe = reference_recipe()
    recipe["references"]["source"] = "calibration"
    @test_throws ArgumentError E.reference_counts(recipe)
    recipe = reference_recipe()
    recipe["references"]["lamp"]["discard_exposures"] = 2
    @test_throws ArgumentError E.reference_counts(recipe)
    recipe["references"]["qualification"]["discard_exposures"] = 18
    @test E.reference_counts(recipe).qualification.discard == 18
end

@testset "online reference composition agrees with retained-input AOC oracle" begin
    raw = reshape(UInt16.(1:24),2,3,4)
    dark_plan = A.prepare(R.DarkFrameMoments(),R.DarkFrameSpecification(2,3,4))
    dark_state = R.DarkFrameState(dark_plan)
    for exposure in axes(raw,3)
        A.process!(dark_state,dark_plan,view(raw,:,:,exposure))
    end
    online = E.reference_product(dark_plan,dark_state)
    batch = A.process(dark_plan,raw)
    @test online.status == batch.status == R.Valid
    @test online.mean == batch.mean
    @test online.variance == batch.variance

    indices = [2,4] # Explicit scientific coordinates, not a guessed mask length.
    frozen = Float32[1 2; 3 4; 5 6; 7 8]
    frozen_before = copy(frozen)
    plan = A.prepare(R.LampReference([1,1],UInt16(4095)),R.LampReferenceSpecification(2,3,2,4))
    state = R.LampReferenceState(plan)
    centroids = zeros(Float64,4,4)
    flux = zeros(Float32,2,4)
    valid = fill(true,2,4)
    for exposure in 1:4
        slopes = Float32[exposure/8+roi/32+coordinate/16 for roi in 1:4,coordinate in 1:2]
        sample = (;arrays=(;raw=copy(raw[:,:,exposure]),slopes,
            flux=fill(2.0f0,4),validity=fill(true,4)))
        E.reference_lamp_update!(state,plan,sample,indices,frozen)
        centroids[:,exposure] = vec(permutedims(Float64.(slopes[indices,:]).+Float64.(frozen[indices,:])))
        flux[:,exposure] .= 2
    end
    online = E.reference_product(plan,state)
    input = R.LampReferenceInputs(centroids,flux,valid,raw;centroids_are_absolute=true)
    batch = A.process(plan,input)
    @test online.status == batch.status == R.Valid
    @test online.reference_centroids == batch.reference_centroids
    @test online.eligible == batch.eligible
    @test online.minimum_flux == batch.minimum_flux
    @test online.all_training_valid == batch.all_training_valid
    @test online.adc_maximum == batch.adc_maximum
    @test frozen == frozen_before
    @test_throws ArgumentError E.reference_product(plan,R.LampReferenceState(plan))

    mktempdir() do directory
        artifacts = Dict{String,Any}()
        source = E.reference_source!(directory,"active",Bool[true,false];artifacts)
        metadata = artifacts["active"]
        @test metadata["target_type"] == "Bool"
        @test metadata["target_shape"] == [2]
        @test metadata["axes"] == [1]
        @test metadata["sha256"] == C.digest(source.path)
        @test PipeWireAORTC.Artifacts.prepare(source,Bool,(2,)).data == Bool[true,false]
    end
end

if haskey(ENV,"PIPEWIREAORTC_REFERENCE_APPLICATION")
    include("native_control_private_core.jl")
    @testset "Classic dark/lamp/frozen qualification candidate on private core" begin
        Threads.nthreads(:default) >= 4 || error("run the native selector with --threads=4")
        application = ENV["PIPEWIREAORTC_REFERENCE_APPLICATION"]
        before = E.reference_application_hashes(application)
        parameters = C.read_parameters(application)
        parameters_before = deepcopy(parameters)
        simulation = PipeWireAORTC.DeploymentConfiguration.decode(joinpath(application,"simulation.conf"),
            get(ENV,"PIPEWIREAO_PREFIX","/opt/pipewireao"))
        reference = zeros(Float32,simulation["command_count"])
        source = get(ENV,"PIPEWIREAORTC_REFERENCE_INSTRUMENT",nothing)
        source_before = source === nothing ? nothing : E.reference_application_hashes(source)
        counts = E.reference_counts(C.read_recipe(application))
        mktempdir() do directory
            with_control_private_core(;temporary_prefix="classic-reference-campaign-") do remote,core_directory,daemon
                chmod(dirname(remote),0o700)
                output = joinpath(directory,"candidate")
                requests = Any[]
                confirm = function (request,witness)
                    push!(requests,request)
                    @info "Reference stage prepared" stage=request.stage witness
                    flush(stdout)
                    flush(stderr)
                    P.Confirmation(request;observed_at=E.Control.monotonic(),witness)
                end
                report = C.calibrate_references(application,output;remote,reference,timeout_s=600,confirm)
                @info "Classic reference candidate" eligible_rois=report["eligible_roi_count"] qualification_status=report["qualification_status"] qualification_eligibility_passed=report["qualification_eligibility_passed"] reference_difference_rms_pixels=report["qualification_reference_difference_rms_pixels"]
                @test isfile(joinpath(output,"result.yaml"))
                @test report["activation"] == "candidate-only"
                @test !report["interaction_matrix_accepted"]
                @test report["dark_status"] == "Valid"
                @test report["lamp_status"] in ("Valid","Invalid","NoEligible")
                @test length(report["stages"]) == (report["eligible_roi_count"] == 0 ? 2 : 3)
                @test length(requests) == length(report["stages"])
                @test all(request.kind == :simulated for request in requests)
                @test all(stage["restored"] && stage["released"] for stage in report["stages"])
                @test report["stages"][1]["samples"] == counts.dark.samples
                @test report["stages"][2]["samples"] == counts.lamp.samples
                @test report["stages"][1]["condition"] == "dark"
                @test report["stages"][2]["condition"] == "internal-source"
                @test all(occursin(stage["acquisition_domain"],stage["witness"]) for stage in report["stages"])
                @test length(unique(stage["acquisition_domain"] for stage in report["stages"])) == length(report["stages"])
                if length(report["stages"]) == 3
                    lamp,qualification = report["stages"][2:3]
                    @test qualification["first_sequence"] > lamp["last_sequence"]
                    @test qualification["first_start_ns"] >= lamp["last_end_ns"]
                    @test qualification["samples"] == counts.qualification.samples
                    @test qualification["parameter_sha256"]["active"] == report["artifacts"]["active"]["sha256"]
                    @test qualification["parameter_sha256"]["reference-slopes"] == report["artifacts"]["reference-slopes"]["sha256"]
                end
                types = Dict("Bool"=>Bool,"Float32"=>Float32,"Float64"=>Float64)
                products = Dict{String,Array}()
                for (name,artifact) in report["artifacts"]
                    path = joinpath(output,artifact["path"])
                    @test C.digest(path) == artifact["sha256"]
                    input = PipeWireAORTC.Artifacts.FITSArtifact(path;hdu=artifact["hdu"],axes=artifact["axes"])
                    products[name] = PipeWireAORTC.Artifacts.prepare(input,types[artifact["target_type"]],Tuple(artifact["target_shape"])).data
                end
                @test products["background"] == Float32.(products["dark-mean"])
                @test count(products["active"]) == report["eligible_roi_count"]
                @test findall(products["active"]) == report["active_roi_indices"]
                @test all(iszero,products["reference-slopes"][.!products["active"],:])
                @test all(products["training-active"])
                @test all(iszero,products["training-reference-slopes"])
                @test report["detector"]["config"]["photon_noise"]
                @test report["detector"]["config"]["readout_noise"]
                @test report["detector"]["config"]["rng_seed"] == 0
                @test report["adc_upper_rail"] == 4095

                # Cancellation after known native Hold resolves through an exact
                # Restore/Release. No candidate is published and no raw recorder exists.
                cancelled = Ref(false)
                cancelled_output = joinpath(directory,"cancelled")
                cancel_confirmation = function (request,witness)
                    cancelled[] = true
                    P.Confirmation(request;observed_at=E.Control.monotonic(),witness)
                end
                @test_throws InterruptException C.calibrate_references(application,cancelled_output;
                    remote,reference,timeout_s=600,cancelled=()->cancelled[],confirm=cancel_confirmation)
                @test !ispath(cancelled_output)
                stale_output = joinpath(directory,"stale")
                stale_confirmation = function (request,witness)
                    other = P.Request(request.run,request.serial+1,request.stage,request.condition,
                        request.configuration_identity,request.kind,request.issued_at,request.deadline)
                    P.Confirmation(other;observed_at=E.Control.monotonic(),witness)
                end
                @test_throws ArgumentError C.calibrate_references(application,stale_output;
                    remote,reference,timeout_s=600,confirm=stale_confirmation)
                @test !ispath(stale_output)
                wrong_witness_output = joinpath(directory,"wrong-witness")
                wrong_witness = (request,witness)->P.Confirmation(request;
                    observed_at=E.Control.monotonic(),witness="other-owner")
                @test_throws ArgumentError C.calibrate_references(application,wrong_witness_output;
                    remote,reference,timeout_s=600,confirm=wrong_witness)
                @test !ispath(wrong_witness_output)
                timeout_output = joinpath(directory,"timeout")
                @test_throws ArgumentError C.calibrate_references(application,timeout_output;
                    remote,reference,timeout_s=1e-9)
                @test !ispath(timeout_output)
                @test sort(readdir(directory)) == ["candidate"]
                @test !Base.process_exited(daemon)
            end
        end
        @test parameters == parameters_before
        @test C.read_parameters(application) == parameters_before
        @test E.reference_application_hashes(application) == before
        @test source === nothing || E.reference_application_hashes(source) == source_before
        @test !any(id.name in ("CUDA","AMDGPU") for id in keys(Base.loaded_modules))
    end
end
end
