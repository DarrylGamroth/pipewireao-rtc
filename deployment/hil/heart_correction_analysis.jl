#!/usr/bin/env julia
"""Replay native correction with explicit application timing observations.

The frozen analyzer uses three historical timing field names to validate a
monotonic exchange. ReportView supplies those names only in memory. The actual
report, returned path/hash, payloads, model chronology and replay mathematics
remain unchanged. No compatibility JSON file is written and no RTC latency or
cadence is inferred from these application observations.
"""
module HeartCorrectionAnalysis

using JSON3,SHA
const LoadedSources=Dict(path=>bytes2hex(open(sha256,path)) for path in
    (@__FILE__,joinpath(@__DIR__,"analyze_correction.jl"),joinpath(@__DIR__,"correction_truth.jl"),
     joinpath(@__DIR__,"heart_calibration_telemetry.jl"),joinpath(@__DIR__,"heart_correction_telemetry.jl"),
     joinpath(@__DIR__,"heart_classic_projection.jl"),joinpath(@__DIR__,"heart_correction_flags.jl"),joinpath(@__DIR__,"heart_correction_profiles.jl"),joinpath(@__DIR__,"heart_correction_phases.jl")))
include("analyze_correction.jl")
include("heart_calibration_telemetry.jl")
include("heart_correction_telemetry.jl")
include("heart_correction_profiles.jl")
include("heart_correction_phases.jl")
const Analysis=CorrectionAnalysis
const Telemetry=HeartCalibrationTelemetry
const CorrectionTelemetry=HeartCorrectionTelemetry
const Profiles=HeartCorrectionProfiles
const Phases=HeartCorrectionPhases
all(bytes2hex(open(sha256,path))==hash for (path,hash) in LoadedSources) || error("native analyzer source changed during include")
const TIMING_SCOPE="CLOCK_MONOTONIC application whole-exchange boundaries; no exact callback, native RTC latency, RTT or cadence claim"

struct ReportView
    path::String
    original_sha256::String
    json::String
end

# These methods apply only to this owned view type. The generic frozen analyzer
# reads the in-memory view but resolves relative payloads beside the real report.
Base.read(view::ReportView,::Type{String})=view.json
Base.dirname(view::ReportView)=dirname(view.path)
Base.abspath(view::ReportView)=abspath(view.path)
function Analysis.file_hash(view::ReportView)
    hash=Analysis.file_hash(view.path)
    hash==view.original_sha256 || error("native report changed during analysis")
    return hash
end

function report_view(path)
    isfile(path) && !islink(path) && filesize(path)<=256*1024 || error("invalid native report input")
    original=read(path,String)
    report=JSON3.read(original,Dict{String,Any})
    get(report,"engine",nothing)=="heart" && get(report,"time_observation_scope",nothing)==TIMING_SCOPE ||
        error("native application timing scope differs")
    all(!haskey(report,key) for key in ("source_published_ns","command_received_ns","source_to_command_latency_ns",
        "achieved_cycle_rate_hz","source_publication_span_ns")) || error("native report contains misleading standard timing labels")
    n=report["completed_frames"]
    n isa Integer && !(n isa Bool) && 0<n<=256 || error("invalid native exchange count")
    started=report["exchange_started_monotonic_ns"];finished=report["exchange_completed_monotonic_ns"]
    durations=report["whole_exchange_durations_ns"]
    length(started)==length(finished)==length(durations)==n || error("native exchange timing counts differ")
    for index in 1:n
        start,finish,duration=started[index],finished[index],durations[index]
        all(Analysis.nonnegative_integer,(start,finish,duration)) && start<=finish && finish-start==duration ||
            error("native application exchange duration differs")
        index==1 || started[index]>finished[index-1] || error("native serialized exchanges overlap")
    end
    report["source_published_ns"]=started
    report["command_received_ns"]=finished
    report["source_to_command_latency_ns"]=durations
    return ReportView(abspath(path),bytes2hex(sha256(codeunits(original))),JSON3.write(report))
end

function verify_native_records(package,report,contract)
    profile=Symbol(contract.profile)
    spec=Profiles.descriptor(profile)
    Profiles.Flags.validate_flags(contract.runtime_flags,profile)
    contract.detector_acceptance_policy==Profiles.DETECTOR_ACCEPTANCE_POLICY || error("native normal-correction detector policy differs")
    budget=spec.telemetry_max_bytes
    get(contract,:native_telemetry_max_bytes,profile===:copper ? budget : nothing)==budget && budget>=Profiles.required_file_budget(profile,256) || error("native retained telemetry capacity differs")
    active=profile===:classic ? Profiles.read_active(joinpath(package,"heart/classic-active.u8"),contract.wfs_active_sha256) : nothing
    thresholds=Profiles.read_response_thresholds(package,contract,profile)
    root=report.native_evidence_directory
    adc=report.detector_diagnostics
    adc.frames==256 || error("native detector frame count differs")
    isabspath(root) && isdir(root) && !islink(root) || error("native retained evidence directory differs")
    journal=joinpath(root,"native-evidence.jsonl")
    !islink(journal) && report.native_journal_bytes<=16*1024*1024 || error("native journal exceeds its bound")
    bytes=open(io->read(io,Int(report.native_journal_bytes)),journal)
    length(bytes)==report.native_journal_bytes && bytes2hex(sha256(bytes))==report.native_journal_prefix_sha256 || error("native journal prefix differs")
    records=[JSON3.read(line) for line in split(String(bytes),'\n') if !isempty(line)]
    commands=filter(record->get(record,:kind,nothing)=="active_command",records)
    length(commands)==256 && [record.sequence for record in commands]==collect(1:256) || error("native command journal identities differ")
    completed=filter(record->get(record,:kind,nothing)=="window_completed",records)
    length(completed)==1 && only(completed).restoration_confirmed===true && only(completed).clipping_excluded===true || error("native finite restoration evidence differs")
    proof=report.completed_correct_proof
    expected_flags=Set(vcat(["ENABLE_HRT_FLAGS-$(flag.section)-$(flag.field)-$(flag.value)" for flag in contract.runtime_flags],["INIT","RUN","CORRECT"]))
    Set(String.(keys(proof.flag_replies)))==expected_flags || error("native runtime flag proof omits an active condition")
    active_record=only(filter(record->get(record,:kind,nothing)=="native_active",records))
    active_record.proof==proof || error("native completed CORRECT proof differs from acquisition")
    for (name,expected) in pairs(proof.flag_replies)
        path=joinpath(root,"startup-command-$(proof.generation)-$name.log")
        !islink(path) && !islink(path*".stderr") && filesize(path)+filesize(path*".stderr")<=64*1024 || error("native startup ACK files exceed their bound")
        text=read(path,String)*read(path*".stderr",String)
        bytes2hex(sha256(text))==expected && occursin("ack<0><ACCEPTED>",text) && occursin("status<0><SUCCESS>",text) || error("native startup ACK differs")
    end
    replies=filter(path->endswith(path,".log.json") && Analysis.file_hash(path)==proof.correct_reply_sha256,readdir(root;join=true))
    length(replies)==1 || error("native active CORRECT reply is not retained")
    reply=JSON3.read(read(only(replies),String))
    reply.name=="CORRECT" && reply.exitcode==0 && reply.failure===nothing && reply.truncated===false &&
        occursin("status<0><SUCCESS>",reply.stdout*reply.stderr) || error("native active CORRECT ACK failed")
    archive=isdir(joinpath(root,"after-native-exit")) ? joinpath(root,"after-native-exit") : joinpath(root,"before-reset")
    snapshot=JSON3.read(read(joinpath(archive,"snapshot.json"),String))
    archive_records=Phases.read_archive(archive;frames=256,budget,profile,active,thresholds)
    actual_diagnostics=Profiles.validate_detector_diagnostics(archive_records.phases[:correcting]["cbHoPixelsRaw0"],
        archive_records.phases[:correcting]["cbHoGrad0"],profile,active,adc;thresholds)
    response_diagnostics=Profiles.validate_response_diagnostics(archive_records.phases[:correcting]["cbHoGrad0"],
        profile,active,report.native_response_diagnostics;thresholds)
    only(completed).native_response_diagnostics==report.native_response_diagnostics || error("native completed response diagnostics differ")
    report.normal_response_policy==(profile===:classic ? Profiles.CLASSIC_RESPONSE_POLICY : "native-copper-first-zero-initialization-v1") || error("native reported response policy differs")
    for (name,hash) in archive_records.files
        get(snapshot.files,Symbol(name),nothing)==hash || error("native snapshot phase hash differs")
    end
    Set(name for name in String.(keys(snapshot.files)) if endswith(name,".tel"))==Set(keys(archive_records.files)) ||
        error("native snapshot phase file set differs")
    admissions=filter(record->get(record,:kind,nothing)=="native_phase_admitted",records)
    length(admissions)==3 && String.(getproperty.(admissions,:phase))==collect(String.(Phases.PHASES)) ||
        error("native phase admissions differ")
    for (admission,phase) in zip(admissions,Phases.PHASES)
        admission.window==proof.generation && admission.no_publication_before_all_empty_headers===true || error("native phase admission was not gated")
        Set(String.(keys(admission.files)))==Set(first.(Phases.stream_contract(profile))) || error("native admitted phase streams differ")
        for (tag,_,_) in Phases.stream_contract(profile)
            entry=admission.files[Symbol(tag)]
            name=basename(entry.path)
            haskey(archive_records.files,name) && occursin("_"*Phases.phase_state(phase)*"_",name) &&
                entry.per_file_records isa Integer && !(entry.per_file_records isa Bool) && entry.per_file_records==0 &&
                entry.device>0 && entry.inode>0 || error("native phase admission file differs")
            Phases.require_file_counters(joinpath(archive,name),phase,tag,256,Phases.expected_count(phase,tag,256))
            report.native_phase_paths[Symbol(phase)][Symbol(tag)]==entry.path || error("native phase report path differs")
        end
    end
    native=Dict(tag=>vcat([archive_records.phases[phase][tag] for phase in Phases.PHASES]...) for (tag,_,_) in Phases.stream_contract(profile))
    projection_path=joinpath(package,"heart/physical-projection.f32le")
    projection=Profiles.projection((;profile,heart_projection=projection_path),contract)
    frame_bytes=2*spec.width^2
    frames=Analysis.checked_payload(joinpath(root,"science.json"),report.frame,frame_bytes*256)
    adopted=reshape(reinterpret(Float32,Analysis.checked_payload(joinpath(root,"science.json"),report.command,4*277*256)),277,256)
    for index in 1:256
        bytes2hex(sha256(reinterpret(UInt8,Telemetry.raw_pixels(native["cbHoPixelsRaw0"][index]))))==
            bytes2hex(sha256(@view frames[(index-1)*frame_bytes+1:index*frame_bytes])) || error("native raw frame differs from actual retained ADC")
        response=Profiles.normal_response(native["cbHoGrad0"][index],profile,active;thresholds)
        valid=response.valid
        commands[index].native_response_valid===valid &&
            commands[index].native_dropout_subapertures isa Integer && !(commands[index].native_dropout_subapertures isa Bool) &&
            commands[index].native_dropout_subapertures==count(response.dropout) ||
            error("native per-frame response diagnostics differ")
        profile===:classic || index==1 || valid || error("undeclared invalid native response remains")
        dm=native["cbDmCmd0"][index+1]
        figure=[Telemetry.value_at(Float32,dm.payload,4(actuator-1)) for actuator in 1:277]
        transport=Telemetry.confirm_probe(dm,figure,collect(adopted[:,index]))
        witness=CorrectionTelemetry.projection_witness(projection,CorrectionTelemetry.vdm_values(native["cbClUnclipped0"][index],UInt64(index);coordinates=spec.coordinates),transport.figure)
        commands[index].native_dm_bucket==index && commands[index].native_dm_sync==index &&
            commands[index].native_vdm_bucket==index-1 && commands[index].native_vdm_sync==0 &&
            commands[index].std_dm_metres_sha256==bytes2hex(sha256(reinterpret(UInt8,collect(adopted[:,index])))) &&
            commands[index].projection.vdm_sha256==witness.vdm_sha256 || error("native actual command journal/payload differs")
    end
    for frame in (first(native["cbDmCmd0"]),last(native["cbDmCmd0"]))
        all(iszero,Telemetry.value_at(Float32,frame.payload,4(index-1)) for index in 1:277) || error("native startup/restore is not zero")
    end
    return (;actual_raw_frames=256,actual_wfs_records=256,actual_vdm_records=256,actual_dm_records=258,
        detector_acceptance_policy=Profiles.DETECTOR_ACCEPTANCE_POLICY,detector_diagnostics=actual_diagnostics,
        normal_response_policy=report.normal_response_policy,native_response_diagnostics=response_diagnostics,
        clipping_excluded=true,restoration_confirmed=true,native_journal_prefix_sha256=report.native_journal_prefix_sha256,
        scope="retained native payload/count/ACK verification; public shutdown is a separate lifecycle gate")
end

function analyze(package,report_path,output)
    view=report_view(report_path)
    original=JSON3.read(read(report_path,String))
    original.native_recording_retained===true && original.completed_correct_proof!==nothing &&
        original.native_active===nothing && original.native_controller_held===nothing || error("completed native CORRECT proof missing")
    contract_path=joinpath(package,"heart-active-contract.json")
    Analysis.file_hash(contract_path)==original.active_contract_sha256 || error("native active contract differs")
    contract=JSON3.read(read(contract_path,String))
    spec=Profiles.descriptor(Symbol(contract.profile))
    contract.native_ingress_mode==spec.ingress && contract.frames==original.completed_frames==256 || error("native active window contract differs")
    proof=original.completed_correct_proof
    proof.ingress_mode==spec.ingress && proof.ingress_environment==(spec.ingress=="deferred" ? "1" : "0") &&
        proof.source_config_sha256==contract.native_config_sha256 &&
        proof.generation==original.native_window || error("native active generation/config proof differs")
    native=verify_native_records(package,original,contract)
    result=Analysis.analyze(package,view,output)
    all(bytes2hex(open(sha256,path))==hash for (path,hash) in LoadedSources) || error("native replay helper changed during analysis")
    Analysis.file_hash(view)
    return merge(result,(;engine="heart",timing_observation_scope=TIMING_SCOPE,
        timing_adapter_sha256=LoadedSources[@__FILE__],
        timing_compatibility="historical field names supplied only in an in-memory report view for exchange validation; no RTC latency measurement",
        native_active_contract_sha256=original.active_contract_sha256,
        native_window=original.native_window,completed_correct_proof=proof,native_payload_verification=native))
end

function main(arguments=ARGS)
    length(arguments)==6 || error("expected --package PACKAGE --report REPORT --output FRESH.json")
    options=Dict{String,String}()
    for index in 1:2:6
        arguments[index] in ("--package","--report","--output") && !haskey(options,arguments[index]) || error("unknown or repeated native analysis argument")
        options[arguments[index]]=arguments[index+1]
    end
    output=Analysis.diagnostic_output(realpath(options["--package"]),options["--output"])
    result=try
        analyze(realpath(options["--package"]),abspath(options["--report"]),output)
    catch exception
        (;version=1,verified=false,failure=sprint(showerror,exception),engine="heart",
            timing_observation_scope=TIMING_SCOPE,scope="native correction replay failed; no utility established")
    end
    mkpath(dirname(output))
    temporary,io=mktemp(dirname(output))
    try
        write(io,JSON3.write(result),'\n');close(io)
        mv(temporary,output)
    finally
        isopen(io) && close(io)
        ispath(temporary) && rm(temporary)
    end
    return result.verified ? 0 : 1
end

end
abspath(PROGRAM_FILE)==(@__FILE__) && exit(HeartCorrectionAnalysis.main())
