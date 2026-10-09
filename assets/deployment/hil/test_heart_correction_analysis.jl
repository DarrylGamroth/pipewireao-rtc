using Test,JSON3,SHA
include("heart_correction_analysis.jl")
const NativeAnalysis=HeartCorrectionAnalysis
const FrozenAnalysis=NativeAnalysis.Analysis

function exchange_fixture(root)
    package=joinpath(root,"package");mkpath(joinpath(package,"hil"))
    graph=joinpath(package,"hil/plant.toml");write(graph,"# synthetic recording boundary\n")
    frame=joinpath(root,"frames.u16le");command=joinpath(root,"commands.f32le")
    write(frame,zeros(UInt16,2*352*352));write(command,fill(1f-8,2*277))
    report=Dict("version"=>1,"profile"=>"classic","backend"=>"cpu","completed"=>true,"failure"=>nothing,
        "completed_frames"=>2,"completed_commands"=>2,"requested_frames"=>2,"sequence"=>2,"sequences"=>[1,2],
        "model_period_ns"=>2000000,"model_timestamps_ns"=>[0,2000000],"exposure_ns"=>1000000,
        "command_limit_um"=>0.8,"command_limit_tolerance_um"=>1e-7,"graph_sha256"=>FrozenAnalysis.file_hash(graph),
        "source_published_ns"=>[100,200],"command_received_ns"=>[110,220],"source_to_command_latency_ns"=>[10,20],
        "frame"=>Dict("element_type"=>"U16_LE","layout"=>"ROW_MAJOR","shape"=>[352,352],
            "units"=>"raw detector ADC code","encoding"=>"nearest ties to even","file"=>basename(frame),
            "sha256"=>FrozenAnalysis.file_hash(frame),"schema"=>"org.calculon.ao.raw-detector-pixels/1"),
        "command"=>Dict("recorded_element_type"=>"F32_LE","shape"=>[277],"recorded_units"=>"metre OPD",
            "plant_units"=>"metre OPD","layout"=>"frame followed by 277 actuator values","file"=>basename(command),
            "sha256"=>FrozenAnalysis.file_hash(command),"schema"=>"org.calculon.ao.demanded-pdm-command/1",
            "transport_element_type"=>"F32_LE","transport_units"=>"micrometre OPD","transport_to_plant_scale"=>1e-6))
    path=joinpath(root,"report.json");write(path,JSON3.write(report))
    original=FrozenAnalysis.validate_recording(package,path)
    report["engine"]="heart";report["time_observation_scope"]=NativeAnalysis.TIMING_SCOPE
    for (before,after) in (("source_published_ns","exchange_started_monotonic_ns"),
        ("command_received_ns","exchange_completed_monotonic_ns"),("source_to_command_latency_ns","whole_exchange_durations_ns"))
        report[after]=pop!(report,before)
    end
    write(path,JSON3.write(report))
    return (;package,path,report,original)
end

include("test_heart_correction_phase_fixture.jl")

@testset "native retained streams bind raw ADC, demands and exact counts" begin
  for profile in (:copper,:classic)
    spec=NativeAnalysis.Profiles.descriptor(profile)
    active=profile===:classic ? fill(true,188) : nothing
    profile===:classic && (active[[86,87,102,103]].=false)
    mktempdir() do root
        package=joinpath(root,"package");mkpath(joinpath(package,"heart"))
        projection=zeros(Float32,277,spec.coordinates)
        if profile===:classic
            for index in 1:277;projection[index,index]=1;end
            write(joinpath(package,"heart/native-extrapolation.f32le"),vec(permutedims(projection)))
            write(joinpath(package,"heart/classic-active.u8"),UInt8.(active))
            mkpath(joinpath(package,"heart/calibration"))
            write(joinpath(package,"heart/calibration/threshold.fits"),"synthetic sealed native thresholds")
            write(joinpath(package,"heart/classic-flux-thresholds.f32le"),fill(1000f0,188))
        end
        write(joinpath(package,"heart/physical-projection.f32le"),vec(permutedims(projection)))
        native=joinpath(root,"native");mkpath(joinpath(native,"before-reset"))
        archive=joinpath(native,"before-reset")
        files=Dict{String,String}()
        phase_paths=Dict{Symbol,Dict{String,String}}()
        for phase in NativeAnalysis.Phases.PHASES
            phase_paths[phase]=phase_fixture_set(archive,NativeAnalysis.Phases.stream_contract(profile),phase,256;science=true,active)
            for path in values(phase_paths[phase]);files[basename(path)]=FrozenAnalysis.file_hash(path);end
        end
        snapshot=joinpath(archive,"snapshot.json");write(snapshot,JSON3.write((;files)))
        stdout="ack<0><ACCEPTED> status<0><SUCCESS>"
        flag_rows=[(;section,field=name,value) for (section,name,value) in NativeAnalysis.Profiles.Flags.required_flags(profile)]
        flag_names=vcat(["INIT","RUN","CORRECT"],["ENABLE_HRT_FLAGS-$(row.section)-$(row.field)-$(row.value)" for row in flag_rows])
        flags=Dict(name=>bytes2hex(sha256(stdout)) for name in flag_names)
        for name in keys(flags)
            path=joinpath(native,"startup-command-1-$name.log");write(path,stdout);write(path*".stderr","")
        end
        reply=joinpath(native,"command-4.log.json")
        write(reply,JSON3.write((;name="CORRECT",exitcode=0,failure=nothing,truncated=false,stdout,stderr="")))
        proof=(;generation=1,flag_replies=flags,correct_reply_sha256=FrozenAnalysis.file_hash(reply))
        zero_vdm=bytes2hex(sha256(reinterpret(UInt8,zeros(Float32,spec.coordinates))))
        zero_dm=bytes2hex(sha256(reinterpret(UInt8,zeros(Float32,277))))
        records=Any[(;kind="native_active",proof)]
        for phase in NativeAnalysis.Phases.PHASES
            entries=Dict(tag=>(;path,device=stat(path).device,inode=stat(path).inode,per_file_records=0) for (tag,path) in phase_paths[phase])
            push!(records,(;kind="native_phase_admitted",phase,window=1,no_publication_before_all_empty_headers=true,files=entries))
        end
        response_diagnostics=(;frames=256,dropout_frames=0,dropout_subaperture_samples=0,per_subaperture_dropout_frames=zeros(UInt64,profile===:classic ? 188 : 0))
        for index in 1:256
            push!(records,(;kind="active_command",sequence=index,native_response_valid=profile===:classic || index>1,native_dropout_subapertures=0,native_dm_bucket=index,native_dm_sync=index,
                native_vdm_bucket=index-1,native_vdm_sync=0,std_dm_metres_sha256=zero_dm,projection=(;vdm_sha256=zero_vdm)))
        end
        push!(records,(;kind="window_completed",restoration_confirmed=true,clipping_excluded=true,native_response_diagnostics=response_diagnostics))
        journal=joinpath(native,"native-evidence.jsonl");write(journal,join(JSON3.write.(records),'\n')*"\n")
        raw=zeros(UInt16,spec.width^2*256);raw[1:spec.width^2:end].=1
        frame=joinpath(native,"science.frames.u16le");write(frame,raw)
        command=joinpath(native,"science.commands.f32le");write(command,zeros(Float32,277*256))
        report=JSON3.read(JSON3.write((;native_evidence_directory=native,native_journal_bytes=filesize(journal),
            native_journal_prefix_sha256=FrozenAnalysis.file_hash(journal),completed_correct_proof=proof,native_phase_paths=phase_paths,
            native_response_diagnostics=response_diagnostics,normal_response_policy=profile===:classic ? NativeAnalysis.Profiles.CLASSIC_RESPONSE_POLICY : "native-copper-first-zero-initialization-v1",
            detector_diagnostics=(;raw_available=true,adc_upper_rail=2^spec.adc_bits-1,frames=256,maximum_adc=1,
                upper_rail_frames=0,upper_rail_pixels=0,invalid_frames=profile===:classic ? 0 : 1),
            frame=(;file=frame,sha256=FrozenAnalysis.file_hash(frame)),command=(;file=command,sha256=FrozenAnalysis.file_hash(command)))))
        contract=JSON3.read(JSON3.write((;runtime_flags=flag_rows,profile=String(profile),
            normal_response_policy=profile===:classic ? NativeAnalysis.Profiles.CLASSIC_RESPONSE_POLICY : nothing,
            flux_threshold_native_file="threshold.fits",
            flux_threshold_native_sha256=profile===:classic ? FrozenAnalysis.file_hash(joinpath(package,"heart/calibration/threshold.fits")) : nothing,
            flux_threshold_wire_sha256=profile===:classic ? FrozenAnalysis.file_hash(joinpath(package,"heart/classic-flux-thresholds.f32le")) : nothing,
            runtime_inputs=profile===:classic ? Dict("threshold.fits"=>FrozenAnalysis.file_hash(joinpath(package,"heart/calibration/threshold.fits"))) : Dict(),
            native_telemetry_max_bytes=spec.telemetry_max_bytes,physical_projection_mode="native-default-copy",projection_native_file=nothing,
            extrapolation_wire_sha256=profile===:classic ? FrozenAnalysis.file_hash(joinpath(package,"heart/native-extrapolation.f32le")) : nothing,
            wfs_active_sha256=profile===:classic ? FrozenAnalysis.file_hash(joinpath(package,"heart/classic-active.u8")) : nothing,
            detector_acceptance_policy=NativeAnalysis.Profiles.DETECTOR_ACCEPTANCE_POLICY,
            projection_wire_sha256=FrozenAnalysis.file_hash(joinpath(package,"heart/physical-projection.f32le")))))
        verified=NativeAnalysis.verify_native_records(package,report,contract)
        @test verified.actual_raw_frames==verified.actual_vdm_records==256
        @test verified.actual_dm_records==258
        @test verified.clipping_excluded && verified.restoration_confirmed
        original_report=JSON3.read(JSON3.write(report),Dict{String,Any})
        changed=deepcopy(original_report)
        changed["native_response_diagnostics"]["dropout_frames"]=1
        @test_throws ArgumentError NativeAnalysis.verify_native_records(package,JSON3.read(JSON3.write(changed)),contract)
        changed=deepcopy(original_report)
        changed["normal_response_policy"]="calibration-all-active"
        @test_throws ErrorException NativeAnalysis.verify_native_records(package,JSON3.read(JSON3.write(changed)),contract)
        changed=deepcopy(original_report)
        changed["native_phase_paths"]["startup_run"]["cbDmCmd0"]="unrelated.tel"
        @test_throws ErrorException NativeAnalysis.verify_native_records(package,JSON3.read(JSON3.write(changed)),contract)
        journal_original=read(journal,String)
        changed_records=JSON3.read.(split(chomp(journal_original),'\n'),Ref(Dict{String,Any}))
        changed_records[2]["files"]["cbDmCmd0"]["per_file_records"]=1
        write(journal,join(JSON3.write.(changed_records),'\n')*"\n")
        changed=deepcopy(original_report)
        changed["native_journal_bytes"]=filesize(journal)
        changed["native_journal_prefix_sha256"]=FrozenAnalysis.file_hash(journal)
        @test_throws ErrorException NativeAnalysis.verify_native_records(package,JSON3.read(JSON3.write(changed)),contract)
        write(journal,journal_original)
        dm_path=phase_fixture_path(archive,:restore_run,"cbDmCmd0");open(io->write(io,UInt8(0)),dm_path,"a")
        files[basename(dm_path)]=FrozenAnalysis.file_hash(dm_path);write(snapshot,JSON3.write((;files)))
        @test_throws ErrorException NativeAnalysis.verify_native_records(package,report,contract)
    end
  end
end

@testset "native exchange compatibility stays in memory and preserves math" begin
    mktempdir() do root
        fixture=exchange_fixture(root)
        before=read(fixture.path);files=sort(readdir(root))
        @test_throws Exception FrozenAnalysis.validate_recording(fixture.package,fixture.path)
        view=NativeAnalysis.report_view(fixture.path)
        result=FrozenAnalysis.validate_recording(fixture.package,view)
        @test result.commands==fixture.original.commands
        @test result.frames==fixture.original.frames
        @test result.period==fixture.original.period
        @test result.report.model_timestamps_ns==fixture.original.report.model_timestamps_ns
        @test result.report_sha256==bytes2hex(sha256(before))
        @test Base.abspath(view)==fixture.path
        @test FrozenAnalysis.window_ranges(result.n)==FrozenAnalysis.window_ranges(fixture.original.n)
        @test FrozenAnalysis.pupil_variance(result.commands,trues(size(result.commands)))==
            FrozenAnalysis.pupil_variance(fixture.original.commands,trues(size(fixture.original.commands)))
        @test read(fixture.path)==before
        @test sort(readdir(root))==files
        @test !haskey(JSON3.read(read(fixture.path,String)),:source_to_command_latency_ns)
        for (key,value) in (("time_observation_scope","native RTC latency"),("whole_exchange_durations_ns",[10,21]),
            ("exchange_started_monotonic_ns",[100,109]),("exchange_completed_monotonic_ns",[99,220]),
            ("source_published_ns",[100,200]),("achieved_cycle_rate_hz",500),
            ("completed_frames",true),("exchange_started_monotonic_ns",[100]))
            changed=deepcopy(fixture.report);changed[key]=value;write(fixture.path,JSON3.write(changed))
            @test_throws ErrorException NativeAnalysis.report_view(fixture.path)
        end
        write(fixture.path,JSON3.write(fixture.report))
        stale=NativeAnalysis.report_view(fixture.path);write(fixture.path,"changed")
        @test_throws ErrorException FrozenAnalysis.file_hash(stale)
    end
    @test FrozenAnalysis.file_hash(joinpath(@__DIR__,"analyze_correction.jl"))==NativeAnalysis.LoadedSources[joinpath(@__DIR__,"analyze_correction.jl")]
end
