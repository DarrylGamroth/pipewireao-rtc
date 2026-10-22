# Opt-in, isolated CPU transport/replay/reset validation of shared optical images.
module ClassicWavefront
using Test, Statistics, Libdl
using PipeWireAORTC, PipeWireAO, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL
using AdaptiveOpticsSim.AlgorithmGraphs
include("classic_managed_replay.jl")
const M=ClassicManagedReplay
const R=PipeWireAORTC.SessionRuntime
const C=PipeWireAORTC.Common
const O=Base.get_extension(PipeWireAORTC,:PipeWireAORTCAOSExt).OpticalObservation
const COUNT=32
const WAVEFRONT=(name="wavefront",node="simulator-residual-wavefront-queue-output",
    media="residual-wavefront",type=Float32,wire=NdArray.F32_LE,shape=(480,480),
    schema=O.WAVEFRONT_SCHEMA,rate=SPA.Fraction(20,1))

function capture(handle,stage,prefix)
    mkpath(stage)
    records=Any[]
    factory=capture -> begin
        record=M.PrefixCapture(capture,COUNT);push!(records,record);record
    end
    observation=M.observe_classic(R._ledger(handle)["remote"];timeout=90,
        stream_specs=(M.CLASSIC_OBSERVATION_STREAMS...,WAVEFRONT),
        selected_streams=("detector","demanded","wavefront"),drive_interval=0.005,
        process_capture=factory,
        valid_payload=c->c.schema==O.WAVEFRONT_SCHEMA ? all(x->isfinite(x)||isnan(x),c.values) : c.finite,
        on_ready=()->M.request(handle,stage,"start",["session-start"]),
        finished=_ -> all(records[1].seen) && all(records[2].seen) && count(records[3].seen)>=2)
    @test M.request(handle,stage,"stop",["session-stop"])["state"]=="Ready"
    _,snapshot=M.source_snapshot(M.dump_graph(handle,stage,prefix,"graph-stopped"))
    @test snapshot["completed"] && !snapshot["running"] && snapshot["sequence"]==COUNT
    C.write_json(joinpath(stage,"observation.json"),observation)
    return records,snapshot
end

function replay(application,records,destination)
    detector,demanded,wavefront=records
    adopted=demanded.values .* 1f-6
    @test M.ClassicReplay.replay(application,detector.values,adopted)==adopted
    base=PipeWireAORTC.AOSOwner.configuration(joinpath(application,"simulation.conf"))
    instrument=PipeWireAORTC.AOSOwner.load_instrument(base.plant.package)
    options=merge(base,(;plant_module=instrument,remote="/tmp/unused-wavefront-replay",control_node="simulator-wfs"))
    science=PipeWireAORTC.AOSOwner.prepare_science(options)
    config=only(filter(!isnothing,map(n->O.sensor_configuration(n.config),science.definition.nodes)))
    telescope=AdaptiveOpticsSim.Optics.prepare_telescope(config.telescope,science.target)
    pupil=AdaptiveOpticsSim.Optics.pupil_mask(telescope)
    rms=Float64[];sequences=Int[]
    expected_pixels=zeros(UInt16,352,352)
    for index in 1:COUNT
        stamp=step_hil_frame_at!(science.boundary,science.driver)
        M.ClassicReplay.load_frame!(expected_pixels,detector.values,index)
        @test expected_pixels==round.(UInt16,hil_frame_buffer(science.boundary))
        if wavefront.seen[index]
            @test wavefront.identities[index]==detector.identities[index]==demanded.identities[index]
            @test wavefront.headers[index].pts==detector.headers[index].pts
            image=permutedims(reshape(wavefront.values[:,index],reverse(WAVEFRONT.shape)))
            @test all(isnan,image[.!pupil])
            @test all(isfinite,image[pupil])
            opd=Float64.(graph_output(science.graph,:pupil_opd)[pupil])
            expected=(opd .- mean(opd)) .* 1e9
            @test Float64.(image[pupil]) ≈ expected atol=1e-4
            measured=sqrt(mean(abs2,Float64.(image[pupil])))
            @test measured ≈ std(opd;corrected=false)*1e9 atol=1e-4
            push!(rms,measured);push!(sequences,index)
        end
        copyto!(hil_command_buffer(science.boundary),@view(adopted[:,index]))
        adopt_hil_command!(science.boundary,stamp.sequence)
    end
    report=Dict("frames"=>COUNT,"wavefront_samples"=>length(sequences),"sequences"=>sequences,
        "rms_nm"=>rms,"exact_detector_and_controller_replay"=>true,
        "pupil_mask_matches"=>true,"piston_removed"=>true,"wavefront_pixel_tolerance_nm"=>1e-4,
        "shared_acquisition_identity_and_pts"=>true,"schema"=>O.WAVEFRONT_SCHEMA)
    C.write_json(destination,report)
    return report
end

function main(application,stage,prefix)
    options=PipeWireAORTC.AOSOwner.configuration(joinpath(application,"simulation.conf"))
    @assert options.backend===:cpu && options.total_exchanges==COUNT && options.wall_rate==2
    @assert options.optical_observation
    handle=R.start!(application,stage;prefix,deadline=R.monotonic()+1030)
    reports=Any[]
    @testset "Managed CPU residual wavefront and reset" begin
        try
            M.gpu_audit(handle,stage)
            previous=nothing
            for generation in 1:2
                directory=joinpath(stage,"generation-$generation")
                records,snapshot=capture(handle,directory,prefix)
                if previous!==nothing
                    @test snapshot["generation"]!=previous
                end
                push!(reports,replay(application,records,joinpath(directory,"wavefront-replay.json")))
                previous=snapshot["generation"]
                generation==1 && M.request(handle,stage,"reset",["reset"])
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
        "scope"=>"Two finite32-frame CPU generations with transport, pixels, RMS and reset; no cadence or hardware qualification"))
end
abspath(PROGRAM_FILE)==(@__FILE__) && main(ARGS...)
end
