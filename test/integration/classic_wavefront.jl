# Opt-in, isolated CPU transport/replay/reset validation of shared optical images.
module ClassicWavefront
using Test, Statistics, Libdl, LinearAlgebra
using PipeWireAORTC, PipeWireAO, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL
using AdaptiveOpticsSim.AlgorithmGraphs
include("classic_managed_replay.jl")
include("classic_fft_oracle.jl")
const M=ClassicManagedReplay
const R=PipeWireAORTC.SessionRuntime
const C=PipeWireAORTC.Common
const O=Base.get_extension(PipeWireAORTC,:PipeWireAORTCAOSExt).OpticalObservation
const COUNT=32
const WAVEFRONT=(name="wavefront",node="simulator-residual-wavefront-queue-output",
    media="residual-wavefront",type=Float32,wire=NdArray.F32_LE,shape=(480,480),
    schema=O.WAVEFRONT_SCHEMA,rate=SPA.Fraction(20,1))
const RMS=(name="rms",node="simulator-wavefront-rms-queue-output",
    media="wavefront-rms",type=Float32,wire=NdArray.F32_LE,shape=(1,2),
    schema=O.RMS_SCHEMA,rate=SPA.Fraction(20,1))

function capture(handle,stage,prefix)
    mkpath(stage)
    _,initial=M.source_snapshot(M.dump_graph(handle,stage,prefix,"graph-ready"))
    records=Any[]
    factory=capture -> begin
        record=M.PrefixCapture(capture,COUNT);push!(records,record);record
    end
    observation=M.observe_classic(R._ledger(handle)["remote"];timeout=90,
        stream_specs=(M.CLASSIC_OBSERVATION_STREAMS...,WAVEFRONT,RMS),
        selected_streams=("detector","demanded","wavefront","rms"),drive_interval=0.005,
        expected_generation=UInt64(initial["generation"]),
        process_capture=factory,
        valid_payload=c->c.schema==O.WAVEFRONT_SCHEMA ? all(x->isfinite(x)||isnan(x),c.values) : c.finite,
        on_ready=()->M.request(handle,stage,"start",["session-start"]),
        finished=_ -> all(records[1].seen) && all(records[2].seen) &&
            count(records[3].seen)>=2 && count(records[4].seen)>=2)
    @test M.request(handle,stage,"stop",["session-stop"])["state"]=="Ready"
    _,snapshot=M.source_snapshot(M.dump_graph(handle,stage,prefix,"graph-stopped"))
    @test snapshot["completed"] && !snapshot["running"] && snapshot["sequence"]==COUNT
    C.write_json(joinpath(stage,"observation.json"),observation)
    for (name,record) in zip(("detector","demanded","wavefront","rms"),records)
        write(joinpath(stage,name*".bin"),record.values)
    end
    return records,snapshot
end

function prepare_replay(application)
    base=PipeWireAORTC.AOSOwner.configuration(joinpath(application,"simulation.conf"))
    instrument=PipeWireAORTC.AOSOwner.load_instrument(base.plant.package)
    options=merge(base,(;plant_module=instrument,remote="/tmp/unused-wavefront-replay",control_node="simulator-wfs"))
    return PipeWireAORTC.AOSOwner.prepare_science(options)
end

function replay(science,application,records,destination,generation)
    detector,demanded,wavefront,meter=records
    adopted=demanded.values .* 1f-6
    @test M.ClassicReplay.replay(application,detector.values,adopted)==adopted
    config=only(filter(!isnothing,map(n->O.sensor_configuration(n.config),science.definition.nodes)))
    telescope=AdaptiveOpticsSim.Optics.prepare_telescope(config.telescope,science.target)
    pupil=AdaptiveOpticsSim.Optics.pupil_mask(telescope)
    display_pupil=reverse(permutedims(pupil);dims=1)
    rms=Float64[];sequences=Int[];pixel_errors=Float64[]
    uncorrected=Float64[];corrected=Float64[];meter_sequences=Int[]
    expected_pixels=zeros(UInt16,352,352)
    detector_differences=Any[]
    for index in 1:COUNT
        stamp=step_hil_frame_at!(science.boundary,science.driver)
        M.ClassicReplay.load_frame!(expected_pixels,detector.values,index)
        frame=hil_frame_buffer(science.boundary)
        quantized=round.(UInt16,frame)
        differing=findall(expected_pixels .!= quantized)
        if !isempty(differing)
            push!(detector_differences,Dict("generation"=>generation,"sequence"=>index,
                "count"=>length(differing),"samples"=>[Dict("row"=>i[1],"column"=>i[2],
                    "observed"=>Int(expected_pixels[i]),"expected"=>Int(quantized[i]),
                    "reference_frame_value"=>Float64(frame[i])) for i in differing[1:min(end,8)]]))
        end
        @test isempty(differing)
        if wavefront.seen[index]
            identity=something(wavefront.identities[index])
            @test identity.sequence==index
            @test identity.generation==generation
            @test identity==something(detector.identities[index])==something(demanded.identities[index])
            @test wavefront.headers[index].pts==detector.headers[index].pts
            image=permutedims(reshape(wavefront.values[:,index],reverse(WAVEFRONT.shape)))
            @test all(isnan,image[.!display_pupil])
            @test all(isfinite,image[display_pupil])
            opd=Float64.(graph_output(science.graph,:pupil_opd)[pupil])
            display_opd=reverse(permutedims(Float64.(graph_output(science.graph,:pupil_opd)));dims=1)
            expected=(display_opd[display_pupil] .- mean(opd)) .* 1e9
            pixel_error=maximum(abs,Float64.(image[display_pupil]) .- expected)
            @test pixel_error <= 1e-4
            measured=sqrt(mean(abs2,Float64.(image[display_pupil])))
            @test measured ≈ std(opd;corrected=false)*1e9 atol=1e-4
            push!(rms,measured);push!(sequences,index);push!(pixel_errors,pixel_error)
        end
        if meter.seen[index]
            identity=something(meter.identities[index])
            @test identity==something(detector.identities[index])
            @test identity.sequence==index && identity.generation==generation
            @test meter.headers[index].pts==detector.headers[index].pts
            atmosphere=Float64.(graph_output(science.graph,:atmosphere_opd)[pupil])
            residual=Float64.(graph_output(science.graph,:pupil_opd)[pupil])
            @test meter.values[1,index] ≈ std(atmosphere;corrected=false)*1e9 atol=1e-4
            @test meter.values[2,index] ≈ std(residual;corrected=false)*1e9 atol=1e-4
            push!(uncorrected,meter.values[1,index]);push!(corrected,meter.values[2,index])
            push!(meter_sequences,index)
        end
        copyto!(hil_command_buffer(science.boundary),@view(adopted[:,index]))
        adopt_hil_command!(science.boundary,stamp.sequence)
    end
    report=Dict("frames"=>COUNT,"wavefront_samples"=>length(sequences),"sequences"=>sequences,
        "rms_nm"=>rms,"exact_detector_and_controller_replay"=>isempty(detector_differences),
        "detector_differences"=>detector_differences,
        "max_pixel_error_nm"=>maximum(pixel_errors),
        "rms_stream_schema"=>O.RMS_SCHEMA,"rms_sequences"=>meter_sequences,
        "uncorrected_rms_nm"=>uncorrected,"corrected_rms_nm"=>corrected,
        "pupil_mask_matches"=>true,"piston_removed"=>true,"wavefront_pixel_tolerance_nm"=>1e-4,
        "shared_acquisition_identity_and_pts"=>true,"schema"=>O.WAVEFRONT_SCHEMA)
    C.write_json(destination,report)
    return report
end

function main(application,stage,prefix)
    options=PipeWireAORTC.AOSOwner.configuration(joinpath(application,"simulation.conf"))
    @assert options.backend===:cpu && options.total_exchanges==COUNT && options.pacing_rate_hz==2
    @assert options.optical_observation
    isfile(joinpath(application,"classic_fft_oracle.jl")) || throw(ArgumentError(
        "prepare the isolated test application with prepare_classic_wavefront.jl first"))
    BLAS.set_num_threads(1)
    AdaptiveOpticsSim.Backends.set_fft_provider_threads!(1)
    handle=R.start!(application,stage;prefix,deadline=R.monotonic()+1030)
    reports=Any[]
    @testset "Managed CPU residual wavefront and reset" begin
        try
            M.gpu_audit(handle,stage)
            previous=nothing
            # Exact noisy ADC replay requires the same measured FFT execution
            # contract, not a separately timed FFTW search in this process.
            fft_directory=joinpath(R._ledger(handle)["runtime"],"fft-oracle")
            fft_contract=ClassicFFTOracle.restore!(fft_directory)
            science=Base.invokelatest(prepare_replay,application)
            @test ClassicFFTOracle.verify(science,fft_contract)
            cp(fft_directory,joinpath(stage,"fft-oracle"))
            for generation in 1:2
                directory=joinpath(stage,"generation-$generation")
                records,snapshot=capture(handle,directory,prefix)
                if previous!==nothing
                    @test snapshot["generation"]!=previous
                end
                push!(reports,replay(science,application,records,joinpath(directory,"wavefront-replay.json"),snapshot["generation"]))
                previous=snapshot["generation"]
                if generation==1
                    M.request(handle,stage,"reset",["reset"])
                    reset_hil_boundary!(science.boundary,science.driver)
                end
            end
            @test !any(id->id.name in ("CUDA","AMDGPU","GPUCompiler"),keys(Base.loaded_modules))
            @test isempty(filter(p->occursin(r"(?i)(libcuda|libcudart|libcublas|libcufft|libamdhip|libhsa-runtime)",p),Libdl.dllist()))
            M.gpu_audit(handle,stage)
        finally
            R.shutdown!(handle;deadline=R.monotonic()+320)
        end
        final=R.final_record(stage)
        @test final["cleanup_complete"] && isempty(get(final,"cleanup_errors",[]))
        @test !PipeWireAORTC.SystemdOwners.old_process_exists(handle.main_pid,handle.start_ticks)
    end
    C.write_json(joinpath(stage,"wavefront-result.json"),Dict("complete"=>true,"backend"=>"cpu",
        "generations"=>reports,"reset_and_restart"=>true,"cleanup_complete"=>true,
        "calibration_identity"=>options.calibration_identity,"manifest_sha256"=>C.sha256_file(joinpath(application,"Manifest.toml")),
        "fft_execution_contract"=>C.read_json(joinpath(stage,"fft-oracle","plans.json")),
        "scope"=>"Two finite32-frame CPU generations with transport, pixels, RMS and reset; no cadence or hardware qualification"))
end
abspath(PROGRAM_FILE)==(@__FILE__) && main(ARGS...)
end
