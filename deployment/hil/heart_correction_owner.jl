#!/usr/bin/env julia
include("heart_calibration_owner.jl")
include("heart_correction_telemetry.jl")
include("heart_correction_profiles.jl")
include("heart_correction_phases.jl")
include("heart_calibration_coordinates.jl")

module HeartCorrectionOwner

using PipeWireAO, AdaptiveOpticsSimPipeWireHIL, SHA, TOML
using AdaptiveOpticsSim.AlgorithmGraphs
import ..HeartCalibrationOwner, ..HeartCorrectionTelemetry, ..Protocol
import ..HeartCalibrationCoordinates
import ..HeartCorrectionProfiles
import ..HILNativeAcquisitionLifecycle
const Profiles=HeartCorrectionProfiles
import ..HeartCorrectionPhases
const Phases=HeartCorrectionPhases
const Native = HeartCalibrationOwner
const Telemetry = Native.Telemetry
const Acquisition = Native.Acquisition
const CorrectionTelemetry = HeartCorrectionTelemetry
const TIMEOUT_NS = UInt64(30_000_000_000)
const TAGS = (Native.NATIVE_TELEMETRY_TAGS..., "cbClUnclipped0")
const FROZEN_HELPERS = ("simulator.jl","owner_protocol.jl","correction_truth.jl","analyze_correction.jl")
required_flags(profile::Symbol)=Profiles.Flags.required_flags(profile)
digest(path) = bytes2hex(open(sha256,path))

struct NativeActive
    child_pid::Int
    generation::Int
    correct_reply_sha256::String
    source_config_sha256::String
    rendered_config_sha256::String
    flag_replies::Dict{String,String}
    ingress_mode::String
    ingress_environment::String
    snapshot::Main.HILHeartControl.Codec.HeartSnapshot
end

struct QuitService{Options,Store,Control}
    options::Options
    phases::Store
    response::Base.RefValue{Union{Nothing,Telemetry.TelemetryFrame}}
    thresholds::Union{Nothing,Vector{Float32}}
    diagnostics::Profiles.ResponseDiagnostics
    control::Control
end
QuitService(options, phases, response, thresholds, diagnostics) =
    QuitService(options, phases, response, thresholds, diagnostics, () -> nothing)
function (service::QuitService)()
    service.control()
    return nothing
end

# This specialization is installed only by the active correction owner. The
# frozen held-calibration session and default reader remain unchanged.
function Native.read_native!(session::Native.Session{P,D,S,K,O,A,Service},tag,datatype,shape,until) where {P,D,S,K,O,A,Service<:QuitService}
    frame=Phases.read_frame!(session,session.service.phases,tag,datatype,shape,until;remaining=Acquisition.remaining)
    tag=="cbHoGrad0" && (session.service.response[]=frame)
    return frame
end

function enter_phase!(owner,phase,until)
    files=Phases.enter!(owner.session,owner.session.service.phases,phase,until;remaining=Acquisition.remaining,frames=owner.contract.frames)
    Native.record_evidence!(owner.session,(;kind="native_phase_admitted",window=owner.window,phase,
        no_publication_before_all_empty_headers=true,files))
    return nothing
end

function arm_native_receipt!(sink,expected::UInt64;arm=arm_array_sink!)
    expected==0 ? arm(sink,expected;allow_zero_sequence=true) : arm(sink,expected)
    return nothing
end
function require_receipt_sequence(receipt,expected::UInt64)
    receipt.header.sequence==expected || error("native receipt differs from the exact expected exposure sync")
    return nothing
end
function wait_native_receipt!(session,expected::UInt64,until)
    session.receive_task=@async wait_array_sink!(session.dm_sink;timeout_ns=Acquisition.remaining(until))
    while !istaskdone(session.receive_task)
        Acquisition.remaining(until);session.service()
        with_thread_loop_lock(main_loop(session.plant.frame_stream)) do _
            trigger_process!(session.plant.frame_stream)
        end
        sleep(0.001)
    end
    receipt=fetch(session.receive_task);session.receive_task=nothing
    require_receipt_sequence(receipt,expected)
    return copy(array_values(session.dm_sink))
end

mutable struct Owner{Session,Contract,Projection}
    session::Session
    contract::Contract
    projection::Projection
    active::Union{Nothing,NativeActive}
    completed_correct::Union{Nothing,NativeActive}
    window::Int
    retained::Bool
end

function bounded_json(path)
    !islink(path) && filesize(path) <= 1024*1024 || error("native correction JSON exceeds its bound")
    return Protocol.JSON3.read(read(path,String))
end

function options(arguments)
    names = ("heart-client", "heart-native-runtime", "heart-probe-directory", "heart-telemetry-max-bytes",
        "heart-active-contract", "heart-projection", "heart-native-ingress-mode")
    native = Dict{String,String}(); ordinary=String[]
    iseven(length(arguments)) || error("each correction option requires a value")
    for index in 1:2:length(arguments)
        name,value=arguments[index:index+1]
        key=startswith(name,"--") ? name[3:end] : ""
        if key in names || key=="heart-classic-active"
            !haskey(native,key) && !isempty(value) || error("duplicate or empty native correction option")
            native[key]=value
        else
            append!(ordinary,[name,value])
        end
    end
    all(haskey(native,name) for name in names) || error("missing native correction option")
    prepared=Protocol.parse_options(ordinary; native_lifecycle=true)
    prepared.transport===:heart && prepared.correction_diagnostics ||
        error("active native owner requires HEART and direct truth diagnostics")
    spec=Profiles.descriptor(prepared.profile)
    native["heart-native-ingress-mode"]==spec.ingress || error("active native ingress differs from the qualified profile")
    (prepared.profile===:classic)==haskey(native,"heart-classic-active") || error("Classic requires its exact active eligibility; Copper permits no Classic eligibility")
    directory=abspath(native["heart-probe-directory"])
    !ispath(directory) && !islink(directory) && isdir(dirname(directory)) || error("correction evidence root must be fresh")
    Native.native_probe_path(joinpath(directory,"window-2"),typemax(UInt64))
    budget=tryparse(UInt64,native["heart-telemetry-max-bytes"])
    budget!==nothing && budget==spec.telemetry_max_bytes && budget>=Profiles.required_file_budget(prepared.profile,prepared.frames) || error("correction telemetry budget differs from declared profile capacity")
    return merge(prepared,(;heart_client=abspath(native["heart-client"]),
        heart_native_runtime=abspath(native["heart-native-runtime"]),heart_probe_directory=directory,
        heart_telemetry_max_bytes=budget,heart_native_ingress_mode=spec.ingress,
        heart_slope_scale=(1.0,1.0),heart_classic_order=collect(1:188),
        active_path=prepared.profile===:classic ? abspath(native["heart-classic-active"]) : nothing,
        heart_active_contract=abspath(native["heart-active-contract"]),heart_projection=abspath(native["heart-projection"])))
end

function load_contract(options)
    contract=bounded_json(options.heart_active_contract)
    admission_path=joinpath(dirname(options.heart_active_contract),"heart-cold-admission.json")
    digest(admission_path)==contract.cold_admission_sha256 || error("native correction cold admission differs")
    !islink(admission_path) && filesize(admission_path)<=64*1024*1024 || error("native cold admission exceeds its bound")
    admission=Protocol.JSON3.read(read(admission_path,String))
    if options.profile===:copper
        admission.passed===true && admission.actual_native_captures_revalidated==10 &&
        admission.actual_native_references_revalidated==2 &&
        admission.actual_training_grid_reproduced===true && admission.actual_validation_selection_reproduced===true &&
        admission.actual_locked_utility_reproduced===true && admission.locked_test_sha256==contract.locked_test_sha256 &&
        admission.selected_controller_sha256==contract.selected_controller_sha256 || error("native correction lacks actual cold science replay")
    else
        admission.passed===true && admission.actual_native_transfer_reproduced===true &&
            admission.actual_native_captures_revalidated==1 && admission.actual_native_frames_revalidated==1561 &&
            admission.actual_native_accepted_frames_revalidated==1536 &&
            admission.transfer_score_sha256==contract.transfer_score_sha256 &&
            admission.selected_controller_sha256==contract.selected_controller_sha256 || error("Classic correction lacks actual native transfer replay")
    end
    spec=Profiles.descriptor(options.profile)
    contract.detector_acceptance_policy==Profiles.DETECTOR_ACCEPTANCE_POLICY || error("native normal-correction detector policy differs")
    get(contract,:native_telemetry_max_bytes,options.profile===:copper ? spec.telemetry_max_bytes : nothing)==options.heart_telemetry_max_bytes || error("native telemetry bound differs from active contract")
    contract.version==1 && contract.profile==String(options.profile) && contract.controller_coordinates==spec.coordinates &&
        contract.frames==options.frames && contract.native_ingress_mode==options.heart_native_ingress_mode ||
        error("native correction contract differs from this owner")
    Set(String.(keys(contract.frozen_helpers)))==Set(FROZEN_HELPERS) || error("frozen scientific helper set differs")
    Profiles.Flags.validate_flags(contract.runtime_flags,options.profile)
    contract.gain==spec.gain && contract.pole==spec.pole && contract.integration_scalar==1.0 && contract.controller_sign==spec.sign ||
        error("native correction recurrence differs")
    for (name,hash) in pairs(contract.frozen_helpers)
        digest(joinpath(@__DIR__,String(name)))==hash || error("frozen scientific helper changed")
    end
    digest(options.graph)==contract.plant_sha256 || error("native correction plant differs")
    if options.profile===:classic
        isfile(options.active_path) && !islink(options.active_path) && filesize(options.active_path)==188 &&
            digest(options.active_path)==contract.wfs_active_sha256 || error("Classic correction eligibility differs")
    end
    Profiles.read_response_thresholds(dirname(options.heart_active_contract),contract,options.profile)
    projection=Profiles.projection(options,contract)
    return contract,projection
end

function acknowledged_log!(session,source,name)
    stdout=Native.bounded_text(source)
    stderr=Native.bounded_text(source*".stderr",Native.MAX_COMMAND_REPLY_BYTES-ncodeunits(stdout.text))
    output=stdout.text*stderr.text
    !stdout.truncated && !stderr.truncated && occursin("ack<0><ACCEPTED>",output) &&
        occursin("status<0><SUCCESS>",output) || error("native startup $name ACK is absent or unsuccessful")
    destination=joinpath(session.options.heart_probe_directory,"startup-"*basename(source))
    write(destination,stdout.text);write(destination*".stderr",stderr.text)
    return bytes2hex(sha256(output))
end

function read_native_extrapolation(options,contract)
    name=contract.extrapolation_native_file
    path=realpath(joinpath(options.heart_native_runtime,"config",name))
    digest(path)==contract.runtime_inputs[name] || error("native loaded extrapolation input differs")
    return Profiles.sparse_extrapolation(path)
end

function bounded_until(deadline::Union{Nothing,Float64}, maximum::UInt64=TIMEOUT_NS)
    deadline === nothing && return Acquisition.deadline(maximum)
    remaining = deadline - Main.HILHeartControl.Client.monotonic()
    remaining > 0 || error("native correction lifecycle deadline expired")
    return Acquisition.deadline(min(maximum,
        UInt64(max(1, floor(Int64, min(remaining, Float64(maximum) / 1e9) * 1e9)))))
end
function require_lifecycle_deadline(deadline::Union{Nothing,Float64})
    deadline===nothing || Main.HILHeartControl.Client.deadline_check(deadline,()->nothing)
    return nothing
end

function startup_proof(owner,expected_generation; deadline::Union{Nothing,Float64}=nothing)
    session=owner.session; options=session.options
    status_deadline=deadline===nothing ? Main.HILHeartControl.Client.monotonic()+30.0 :
        min(deadline,Main.HILHeartControl.Client.monotonic()+30.0)
    snapshot,status=Main.HILHeartControl.Heart.generation_report(options.controller_control,
        options.heart_native_runtime;deadline=status_deadline,check=session.service)
    status.generation==expected_generation && status.sequence==0 && status.state=="paused" &&
        status.error===nothing && status.child_returncode===nothing && isdir("/proc/$(status.child_pid)") ||
        error("active correction requires the owned successfully initialized native generation")
    Acquisition.cursor(session).sequence==0 && pipewire_calibration_status(session.plant).pending_exposure===nothing ||
        error("native generation proof must precede every exposure")
    contract=owner.contract
    Profiles.Flags.validate_flags(contract.runtime_flags,options.profile)
    status.source_config_sha256==contract.native_config_sha256 && digest(status.source_config)==contract.native_config_sha256 ||
        error("native source config differs from the active contract")
    expected=replace(read(status.source_config,String),"@PACKAGE@"=>dirname(dirname(status.source_config)))
    read(status.rendered_config,String)==expected || error("actual native rendered config differs")
    !status.native_diagnostics.wfs_proc_debug && status.native_diagnostics.stdio_wrapper===nothing ||
        error("diagnostic native sessions cannot authorize scientific correction")
    digest(first(status.native_diagnostics.child_argv))==contract.native_executable_sha256 ||
        error("actual native executable differs")
    for (name,hash) in pairs(contract.runtime_inputs)
        digest(joinpath(options.heart_native_runtime,"config",String(name)))==hash || error("native loaded calibration input differs")
    end
    if options.profile===:copper
        projection_path=realpath(joinpath(options.heart_native_runtime,"config",contract.projection_native_file))
        native_projection=HeartCalibrationCoordinates.floating_matrix(projection_path;shape=(277,253))
        reinterpret(UInt32,vec(native_projection))==reinterpret(UInt32,vec(owner.projection)) ||
            error("wire projection differs from the actual native Float32 FITS projection")
    else
        threshold_path=realpath(joinpath(options.heart_native_runtime,"config",contract.flux_threshold_native_file))
        digest(threshold_path)==contract.flux_threshold_native_sha256 || error("native loaded flux threshold differs")
        native_E=read_native_extrapolation(options,contract)
        reinterpret(UInt32,vec(native_E))==reinterpret(UInt32,vec(owner.projection.extrapolation)) ||
            error("Classic wire E differs from actual native sparse Float32 entries")
    end
    flags=Dict{String,String}()
    for flag in contract.runtime_flags
        name="ENABLE_HRT_FLAGS-$(flag.section)-$(flag.field)-$(flag.value)"
        source=joinpath(options.heart_native_runtime,"command-$expected_generation-$name.log")
        flags[name]=acknowledged_log!(session,source,name)
    end
    for name in ("INIT","RUN","CORRECT")
        source=joinpath(options.heart_native_runtime,"command-$expected_generation-$name.log")
        flags[name]=acknowledged_log!(session,source,name)
    end
    observed=Native.validate_ingress_status(status,options.heart_native_ingress_mode)
    Protocol.write_json_atomic(joinpath(options.heart_probe_directory,"startup-owner-status.json"),status)
    return (;status,snapshot,flags,observed,rendered_sha256=digest(status.rendered_config))
end

function hold_window!(owner,expected_generation; deadline::Union{Nothing,Float64}=nothing)
    session=owner.session
    proof=startup_proof(owner,expected_generation; deadline)
    Native.native_command!(session,"RUN",String[],bounded_until(deadline))
    session.native_controller_held=Native.NativeHold(Int(proof.status.child_pid),expected_generation,true,true,
        "startup CORRECT",proof.flags["CORRECT"],0,session.options.heart_native_ingress_mode,proof.observed,proof.snapshot)
    session.state.held=true
    return nothing
end

function begin_window!(owner,expected_generation; deadline::Union{Nothing,Float64}=nothing)
    session=owner.session
    proof=startup_proof(owner,expected_generation; deadline)
    until=bounded_until(deadline)
    Native.native_command!(session,"RUN",String[],until)
    session.native_controller_held=Native.NativeHold(Int(proof.status.child_pid),expected_generation,true,true,
        "startup CORRECT",proof.flags["CORRECT"],0,session.options.heart_native_ingress_mode,proof.observed,proof.snapshot)
    session.state.held=true # Serialized plant command ownership; native integration remains RUN here.
    Native.native_command!(session,"SET_TELM_RECORD",["-configTelemEnable","1","-configTelemCbNames",join(TAGS,',')],until)
    enter_phase!(owner,:startup_run,until)
    adopt_figure!(owner,zeros(Float32,277),UInt32(0),UInt64(0),until)
    Phases.drained!(session,session.service.phases,owner.contract.frames)
    reply=Native.native_command!(session,"CORRECT",String[],until)
    enter_phase!(owner,:correcting,until)
    # The native public CORRECT ACK precedes active proof and every publication.
    session.native_controller_held=nothing
    owner.active=NativeActive(Int(proof.status.child_pid),expected_generation,digest(reply*".json"),
        owner.contract.native_config_sha256,proof.rendered_sha256,proof.flags,
        session.options.heart_native_ingress_mode,proof.observed,proof.snapshot)
    Native.record_evidence!(session,(;kind="native_active",proof=owner.active,
        flag_verification="strict public command SUCCESS and exact INIT inputs; no effective GMS readback"))
    return nothing
end

"""Begin native actuation only after the public owner resume admission.

The connect reply advertises ports so deployment can realize session links.
It does not authorize a DM publication. A paused reset also prepares only the
held native generation; zero adoption and CORRECT require the next resume.
"""
function admit_active_window!(owner,state; begin_window=begin_window!,
        deadline::Union{Nothing,Float64}=nothing)
    state.running || return false
    if owner.active===nothing && owner.completed_correct===nothing && !owner.retained
        begin_window(owner,owner.window; deadline)
    end
    owner.active!==nothing || error("public resume has no active native window")
    return true
end

function require_active(owner)
    proof=owner.active
    proof!==nothing && owner.session.native_controller_held===nothing || error("native controller is not actively acknowledged")
    Main.HILHeartControl.Heart.require_ready(owner.session.options.controller_control,proof.snapshot)
    isdir("/proc/$(proof.child_pid)") || error("active native child exited")
    return nothing
end

function relay_figure!(session,received,until)
    sequence=Base.checked_add(session.state.probe_sequence,UInt64(1))
    submit=Native.RelayProbe(session,received,sequence,until)
    session.state.progressing[]=true
    adopt_pipewire_probe!(session.plant,sequence;submit,timeout_ns=Acquisition.remaining(until))
    Acquisition.finish_progress!(session)
    adopted=copy(pipewire_probe_values(session.plant))
    reinterpret(UInt32,adopted)==reinterpret(UInt32,received) || error("active command relay differs from native receipt")
    session.state.probe_sequence=sequence
    return sequence
end

function adopt_figure!(owner,figure,sync,bucket,until)
    session=owner.session
    sequence=Base.checked_add(session.state.probe_sequence,UInt64(1))
    path=Native.native_probe_path(session.options.heart_probe_directory,sequence)
    !ispath(path) && !islink(path) || error("native command file already exists")
    open(path,"w") do io
        println(io,"277 1 1 float")
        foreach(value->println(io,value),figure)
    end
    expected=UInt64(sync)
    arm_native_receipt!(session.dm_sink,expected)
    Native.native_command!(session,"DM_SHAPE",["-configDmSelect","0","-configDmShape","1","-configDmFilename",path],until)
    received=wait_native_receipt!(session,expected,until)
    native=Native.read_native!(session,"cbDmCmd0",20,(277,1),until)
    native.sync==sync && native.bucket==bucket || error("native startup/restore command association differs")
    transport=Telemetry.confirm_probe(native,figure,received)
    !transport.clipped || error("native startup/restore figure differs from the requested zero")
    token=relay_figure!(session,received,until)
    session.native_dm_bucket=native.bucket
    Native.record_evidence!(session,(;kind="zero_figure",window=owner.window,sequence=token,
        native_bucket=native.bucket,native_sync=native.sync,received_sha256=bytes2hex(sha256(reinterpret(UInt8,received)))))
    return nothing
end

function read_vdm!(session,until)
    return Native.read_native!(session,"cbClUnclipped0",16,(Profiles.descriptor(session.options.profile).coordinates,1),until)
end

function exchange!(owner)
    require_active(owner)
    session=owner.session;until=Acquisition.deadline(TIMEOUT_NS)
    sequence=Base.checked_add(session.state.cursor_sequence,UInt64(1))
    arm_native_receipt!(session.dm_sink,sequence)
    result=Acquisition.acquire_exposure!(session;timeout_ns=Acquisition.remaining(until),require_valid=session.options.profile===:classic ? false : sequence!=1)
    if session.options.profile===:classic
        calibrated=Native.read_native!(session,"cbHoPixelsCalib0",8,(352,352),until)
        calibrated.bucket==sequence-1 && calibrated.sync==sequence && calibrated.state==2 &&
            calibrated.progress==calibrated.required && calibrated.timestamp_us>=0 || error("Classic calibrated association differs")
        all(index->session.active[index] || !session.validity[index],eachindex(session.active)) ||
            error("inactive Classic subaperture became valid")
    end
    # Copper retains its declared first zero-lag initialization. Classic retains
    # every normal response, including finite native flux-classified dropouts.
    if session.options.profile===:copper
        !result.valid && (sequence!=1 || any(!iszero,session.values)) && error("undeclared invalid active native response")
    end
    frame=session.service.response[]
    frame!==nothing && frame.bucket==sequence-1 && frame.sync==sequence || error("active response association differs")
    response=Profiles.normal_response(frame,session.options.profile,session.active;thresholds=session.service.thresholds)
    response.valid==result.valid || error("native response validity differs from acquired payload")
    Profiles.observe_response!(session.service.diagnostics,response)
    session.service.response[]=nothing
    received=wait_native_receipt!(session,sequence,until)
    receipt_completed=time_ns()
    native=Native.read_native!(session,"cbDmCmd0",20,(277,1),until)
    native.bucket==sequence && native.sync==sequence || error("active physical DM bucket/sync differs from admitted exposure")
    actual_um=[Telemetry.value_at(Float32,native.payload,4(index-1)) for index in 1:277]
    # Standard DM source converts native micrometres to Float32 metres. Check
    # those actual transport bytes independently of the preclip projection.
    transport=Telemetry.confirm_probe(native,actual_um,received)
    vdm_frame=read_vdm!(session,until)
    vdm=CorrectionTelemetry.vdm_values(vdm_frame,sequence;coordinates=Profiles.descriptor(session.options.profile).coordinates)
    projected=CorrectionTelemetry.projection_witness(owner.projection,vdm,transport.figure)
    token=relay_figure!(session,received,until)
    session.native_dm_bucket=native.bucket
    Native.record_evidence!(session,(;kind="active_command",window=owner.window,
        sequence,acquisition=Acquisition.cursor(session),native_response_valid=response.valid,
        native_dropout_subapertures=count(response.dropout),native_dm_bucket=native.bucket,native_dm_sync=native.sync,
        native_vdm_bucket=vdm_frame.bucket,native_vdm_sync=vdm_frame.sync,relay_sequence=token,
        native_dm_um_sha256=bytes2hex(sha256(reinterpret(UInt8,transport.figure))),
        std_dm_metres_sha256=bytes2hex(sha256(reinterpret(UInt8,received))),
        receipt_completed_monotonic_ns=receipt_completed,adoption_completed_monotonic_ns=time_ns(),projection=projected))
    return result.exposure
end

function finish_window!(owner)
    owner.retained && return nothing
    require_active(owner)
    session=owner.session;until=Acquisition.deadline(TIMEOUT_NS)
    sequence=session.state.cursor_sequence
    sequence==owner.contract.frames || error("active native window ended before its declared count")
    Phases.drained!(session,session.service.phases,owner.contract.frames)
    Native.native_command!(session,"RUN",String[],until)
    enter_phase!(owner,:restore_run,until)
    owner.completed_correct=owner.active
    owner.active=nothing
    adopt_figure!(owner,zeros(Float32,277),UInt32(sequence),sequence+UInt64(1),until)
    Native.native_command!(session,"SET_TELM_RECORD",["-configTelemEnable","0","-configTelemCbNames",join(TAGS,',')],until)
    Phases.drained!(session,session.service.phases,owner.contract.frames)
    Phases.require_paths(session.service.phases,session.options.heart_native_runtime)
    expected=Dict("cbHoPixelsRaw0"=>sequence,"cbHoPixelsCalib0"=>sequence,"cbHoGrad0"=>sequence,
        "cbClUnclipped0"=>sequence,"cbDmCmd0"=>sequence+UInt64(2))
    diagnostics=Acquisition.exposure_diagnostics(session)
    diagnostics.frames==sequence || error("active native detector frame count differs")
    archive=Phases.read_archive(session.options.heart_native_runtime;frames=Int(sequence),
        budget=session.options.heart_telemetry_max_bytes,profile=session.options.profile,active=session.active,thresholds=session.service.thresholds)
    Profiles.validate_detector_diagnostics(archive.phases[:correcting]["cbHoPixelsRaw0"],
        archive.phases[:correcting]["cbHoGrad0"],session.options.profile,session.active,diagnostics;thresholds=session.service.thresholds)
    Profiles.validate_response_diagnostics(archive.phases[:correcting]["cbHoGrad0"],session.options.profile,session.active,
        Profiles.response_diagnostics(session.service.diagnostics);thresholds=session.service.thresholds)
    Native.record_evidence!(session,(;kind="window_completed",window=owner.window,
        expected_records=expected,restoration_confirmed=true,clipping_excluded=true,
        detector_diagnostics=Acquisition.exposure_diagnostics(session),
        native_response_diagnostics=Profiles.response_diagnostics(session.service.diagnostics)))
    snapshot!(owner,"before-reset")
    owner.retained=true
    return nothing
end

function snapshot!(owner,label;deadline::Union{Nothing,Float64}=nothing)
    require_lifecycle_deadline(deadline)
    session=owner.session;root=joinpath(session.options.heart_probe_directory,label)
    !ispath(root) || error("native window snapshot already exists")
    mkdir(root;mode=0o700)
    files=Dict{String,String}()
    for path in readdir(session.options.heart_native_runtime;join=true)
        require_lifecycle_deadline(deadline)
        name=basename(path)
        (endswith(name,".tel") || name=="heart-owner-status.json" ||
            startswith(name,"command-") || occursin(r"^heart-[0-9]+\.log$",name)) || continue
        !islink(path) && isfile(path) || error("invalid native window evidence")
        if endswith(name,".tel")
            filesize(path)<=session.options.heart_telemetry_max_bytes || error("native window telemetry exceeds its bound")
            cp(path,joinpath(root,name))
        else
            write(joinpath(root,name),Native.bounded_text(path).text)
        end
        files[name]=digest(joinpath(root,name))
    end
    Protocol.write_json_atomic(joinpath(root,"snapshot.json"),(;version=1,window=owner.window,label,
        scope="owned finite native window; before-reset snapshot may precede file close metadata",files))
    require_lifecycle_deadline(deadline)
    return root
end

function verify_closed_window(root,frames,budget::UInt64;profile::Symbol=:copper,active=nothing,thresholds=nothing)
    archive=Phases.read_archive(root;frames,budget,profile,active,thresholds)
    result=Dict{String,Any}()
    for (tag,_,_) in Phases.stream_contract(profile)
        values=vcat([archive.phases[phase][tag] for phase in Phases.PHASES]...)
        last=Base.last(values)
        result[tag]=(;records=length(values),last_bucket=last.bucket,last_sync=last.sync,
            phase_records=Dict(String(phase)=>length(archive.phases[phase][tag]) for phase in Phases.PHASES),
            files=Dict(name=>hash for (name,hash) in archive.files if occursin("_"*tag*"_",name)))
    end
    return result
end

function publish_report!(options,science,recorder,state,owner;failure=nothing)
    root=owner.session.options.heart_probe_directory
    retained_options=merge(options,(;output=joinpath(root,"science.json")))
    Main.write_report(retained_options,science,recorder,state;failure)
    report=Dict{String,Any}(String(key)=>value for (key,value) in pairs(bounded_json(retained_options.output)))
    # Recorder and truth payloads are unchanged. These observations enclose the
    # complete application exchange, including model generation and adoption.
    for name in ("achieved_cycle_rate_hz","source_publication_span_ns","source_to_command_latency_ns")
        pop!(report,name,nothing)
    end
    for (before,after) in (("requested_rate_hz","nominal_model_rate_hz"),
        ("measurement_span_ns","application_window_span_ns"),("cycle_durations_ns","whole_exchange_durations_ns"),
        ("source_published_ns","exchange_started_monotonic_ns"),("command_received_ns","exchange_completed_monotonic_ns"),
        ("missed_wall_periods","application_missed_wall_periods"))
        report[after]=pop!(report,before)
    end
    merge!(report,Dict("engine"=>"heart","native_active"=>owner.active,"native_controller_held"=>owner.session.native_controller_held,
        "native_window"=>owner.window,"completed_correct_proof"=>owner.completed_correct,"detector_diagnostics"=>Acquisition.exposure_diagnostics(owner.session),
        "native_evidence_directory"=>root,"native_journal_bytes"=>owner.session.evidence_bytes,
        "native_journal_prefix_sha256"=>(isfile(joinpath(root,"native-evidence.jsonl")) ? digest(joinpath(root,"native-evidence.jsonl")) : nothing),
        "native_recording_retained"=>owner.retained,"active_contract_sha256"=>digest(options.heart_active_contract),
        "native_phase_paths"=>owner.session.service.phases.paths,
        "native_response_diagnostics"=>Profiles.response_diagnostics(owner.session.service.diagnostics),
        "normal_response_policy"=>(options.profile===:classic ? Profiles.CLASSIC_RESPONSE_POLICY : "native-copper-first-zero-initialization-v1"),
        "time_observation_scope"=>"CLOCK_MONOTONIC application whole-exchange boundaries; no exact callback, native RTC latency, RTT or cadence claim",
        "qualification"=>"finite unchanged native CORRECT comparison fixture; scientific utility, reset equivalence and public shutdown require independent validation"))
    Protocol.write_json_atomic(retained_options.output,report;maximum=256*1024)
    Protocol.write_json_atomic(options.output,report;maximum=256*1024)
    Protocol.write_json_atomic(joinpath(root,"owner-report.json"),report;maximum=256*1024)
    return nothing
end

function begin_evidence_window!(session,directory)
    isdir(directory) && isempty(readdir(directory)) || error("next native evidence directory is not fresh")
    session.options=merge(session.options,(;heart_probe_directory=directory))
    session.native_command_serial=0
    session.evidence_count=0
    session.evidence_bytes=0
    return nothing
end

function reset_window!(owner,options,science,recorder,request_id;
        deadline::Union{Nothing,Float64}=nothing)
    require_lifecycle_deadline(deadline)
    owner.retained && owner.active===nothing || error("reset requires a completed retained native window")
    owner.window==1 || error("only two declared native correction windows are supported")
    session=owner.session
    status_deadline=deadline===nothing ? Main.HILHeartControl.Client.monotonic()+14.0 :
        min(deadline,Main.HILHeartControl.Client.monotonic()+14.0)
    status=Main.HILHeartControl.Heart.status(options.controller_control;
        deadline=status_deadline,check=session.service)
    old_pid=Int(status.child_pid);old_generation=Int(status.generation)
    require_lifecycle_deadline(deadline)
    stop!(session.plant)
    Main.reset_controller!(options,request_id; deadline)
    !isdir("/proc/$old_pid") || error("previous native child remains after public reset")
    # The new generation has not recorded or admitted a frame. Preserve the
    # closed old files before any new SET_TELM_RECORD command is issued.
    archive=snapshot!(owner,"after-native-exit";deadline)
    closed_records=verify_closed_window(archive,options.frames,options.heart_telemetry_max_bytes;profile=options.profile,active=session.active,thresholds=session.service.thresholds)
    require_lifecycle_deadline(deadline)
    Native.record_evidence!(session,(;kind="closed_native_generation",window=owner.window,
        old_child_pid=old_pid,old_generation,old_child_absent=true,closed_records))
    for path in readdir(options.heart_native_runtime;join=true)
        require_lifecycle_deadline(deadline)
        endswith(path,".tel") || continue
        digest(path)==digest(joinpath(archive,basename(path))) || error("closed native telemetry changed during reset retention")
        mv(path,joinpath(session.options.heart_probe_directory,"closed-"*basename(path)))
    end
    require_lifecycle_deadline(deadline)
    foreach(close,values(session.readers));empty!(session.readers)
    session.service.phases.current=nothing;empty!(session.service.phases.paths)
    lifetime_token=session.state.probe_sequence
    require_lifecycle_deadline(deadline)
    reset_pipewire_calibration!(session.plant,science.driver)
    session.state=Acquisition.AcquisitionState()
    session.state.probe_sequence=lifetime_token
    session.association=Telemetry.FrameAssociation();session.native_dm_bucket=nothing
    session.service.response[]=nothing
    session.service.diagnostics.frames=0;session.service.diagnostics.dropout_frames=0
    session.service.diagnostics.dropout_subaperture_samples=0;fill!(session.service.diagnostics.per_subaperture_dropout_frames,0)
    session.previous_intensity=0.0f0
    session.diagnostics=Acquisition.ExposureDiagnostics(Profiles.descriptor(options.profile).adc_bits)
    session.native_controller_held=nothing
    owner.window=2;owner.retained=false;owner.completed_correct=nothing
    directory=joinpath(options.heart_probe_directory,"window-2")
    require_lifecycle_deadline(deadline)
    mkdir(directory;mode=0o700)
    begin_evidence_window!(session,directory)
    Main.reset_recorder!(recorder)
    require_lifecycle_deadline(deadline)
    start!(session.plant)
    hold_window!(owner,old_generation+1; deadline)
    Native.record_evidence!(session,(;kind="reset",old_child_pid=old_pid,old_generation,
        old_child_absent=true,new_native_hold=session.native_controller_held,pending_public_resume=true,
        acquisition_generation=Acquisition.cursor(session).generation,
        lifetime_probe_token_preserved=lifetime_token))
    return nothing
end

function prepare_boundary(science,profile::Symbol)
    spec=Profiles.descriptor(profile)
    boundary=prepare_graph_calibration_boundary(science.graph;command_input=:pdm_command,frame_output=spec.frame_output)
    size(hil_frame_buffer(boundary))==(spec.width,spec.width) || error("native correction detector boundary extent differs")
    size(hil_command_buffer(boundary))==(277,) || error("native correction physical command boundary extent differs")
    return boundary
end

function run_owner_native(options,bridge,plant_module,target)
    Lifecycle=HILNativeAcquisitionLifecycle
    Codec=Lifecycle.Codec
    contract,projection=load_contract(options)
    mkdir(options.heart_probe_directory;mode=0o700)
    directory=joinpath(options.heart_probe_directory,"window-1");mkdir(directory;mode=0o700)
    original=Main.prepare_science(options,plant_module,target)
    boundary=prepare_boundary(original,options.profile)
    science=merge(original,(;boundary))
    recorder=Main.Recorder(options,boundary;truth=Main.prepare_correction_truth(options,science))
    state=Protocol.OwnerState()
    plant=session=owner=shutdown_ticket=nothing
    primary=control_failure=nothing
    in_effect=false
    current_cursor()=owner===nothing ? nothing : Acquisition.cursor(session)
    current_phase()=owner===nothing ? "initial" : owner.retained ? "restored" :
        session.service.phases.current===nothing ? "initial" : String(session.service.phases.current)
    current_held()=owner!==nothing && !owner.retained &&
        (session.state.held || session.native_controller_held!==nothing || owner.active!==nothing)
    current_snapshot()=Lifecycle.snapshot(bridge,state,current_cursor();phase=current_phase(),
        held=current_held(),restored=owner!==nothing && owner.retained,
        window=owner===nothing ? nothing : UInt64(owner.window))
    function save_report!()
        owner===nothing && return nothing
        cursor=current_cursor()
        HeartCorrectionOwner.publish_report!(options,science,recorder,state,owner)
        Lifecycle.report_published!(bridge,cursor)
        return nothing
    end
    function connect_effect!(ticket)
        configuration=PipeWireHILConfiguration(remote=options.remote,frame_node_name="simulator-wfs",
            command_node_name="simulator-command",frame_schema="org.heart.std-wfs.raw-pixels/1",
            command_schema="org.heart.std-dm.actuator-command/1",
            rate=SPA.Fraction(UInt32(options.rate),UInt32(1)),exposure_duration_ns=options.exposure_ns,
            frame_encoding=:uint16,command_scale=1.0f0,timeout_ns=Acquisition.remaining(bounded_until(ticket.deadline)))
        plant=prepare_pipewire_calibration(boundary,configuration)
        session_options=merge(options,(;heart_probe_directory=directory))
        active=options.profile===:classic ? Main.calibration_active(options) : nothing
        service=QuitService(options,Phases.PhaseStore(options.profile),
            Ref{Union{Nothing,Telemetry.TelemetryFrame}}(nothing),
            Profiles.read_response_thresholds(dirname(options.heart_active_contract),contract,options.profile),
            Profiles.ResponseDiagnostics(options.profile),
            () -> begin
                !in_effect && owner!==nothing && Lifecycle.has_pending(bridge;safe=false) &&
                    service_control(;safe=false)
                nothing
            end)
        session=Native.prepare_session(plant,science.driver,session_options;active,
            adc_bits=Profiles.descriptor(options.profile).adc_bits,service)
        owner=Owner(session,contract,projection,nothing,nothing,1,false)
        Native.start_session!(session)
        hold_window!(owner,1;deadline=ticket.deadline)
        save_report!()
        return nothing
    end
    function resume_effect!(ticket)
        owner===nothing && error("correction Resume requires an owned window")
        admit_active_window!(owner,state;deadline=ticket.deadline)
        save_report!()
        return nothing
    end
    function reset_effect!(ticket)
        owner===nothing && return (Int32(-22),"correction Reset requires an owned window")
        reset_window!(owner,options,science,recorder,state.last_request_id;deadline=ticket.deadline)
        state.sequence=UInt64(0)
        state.completed=false
        state.deadline_ns=UInt64(0)
        save_report!()
        return (Int32(0),"")
    end
    function service_control(;safe::Bool)
        if control_failure!==nothing
            safe && throw(control_failure)
            return nothing
        end
        Lifecycle.has_pending(bridge;safe) || return nothing
        try
            in_effect=true
            terminal=Lifecycle.dispatch!(bridge,state;safe,period_ns=options.period_ns,
                snapshot! = current_snapshot,connect! = connect_effect!,reset! = reset_effect!,
                resume! = resume_effect!,allow_shutdown=() -> owner===nothing ||
                    (owner.retained && owner.active===nothing))
            terminal===nothing || (shutdown_ticket=terminal)
        catch error
            if !safe && error isa Lifecycle.TransportFailure
                control_failure=error
                state.running=false
                return nothing
            end
            rethrow()
        finally
            in_effect=false
        end
        return nothing
    end
    Lifecycle.lifecycle!(bridge,Codec.Prepared)
    try
        while owner===nothing && shutdown_ticket===nothing
            service_control(;safe=true)
            sleep(0.005)
        end
        while shutdown_ticket===nothing
            service_control(;safe=true)
            shutdown_ticket===nothing || break
            if !state.running
                sleep(0.005);continue
            end
            now=time_ns()
            if now<state.deadline_ns
                sleep(min((state.deadline_ns-now)/1e9,0.001));continue
            end
            started=time_ns()
            exposure=exchange!(owner)
            finished=time_ns();sequence=exposure.identity.sequence
            state.sequence=sequence
            timing=(;sequence,source_published_nanoseconds=Int64(started),
                command_received_nanoseconds=Int64(finished),end_to_end_latency_nanoseconds=finished-started)
            Main.record!(recorder,boundary,sequence,science.driver,model_nanoseconds(exposure.timestamp),
                timing,finished-started,started,finished)
            Main.record_correction_truth!(recorder,science,sequence,model_nanoseconds(exposure.timestamp))
            if state.running
                state.deadline_ns,missed=Protocol.next_deadline(state.deadline_ns,options.period_ns,time_ns())
                recorder.missed_wall_periods+=missed
            end
            if recorder.count==options.frames
                state.running=false;state.completed=true;state.deadline_ns=0
                finish_window!(owner)
                save_report!()
            end
        end
    catch error
        primary=error
        if !(error isa Lifecycle.TransportFailure)
            try Lifecycle.lifecycle!(bridge,Codec.Fault) catch end
        end
    end
    state.running=false
    stopped_cursor=try current_cursor() catch; nothing end
    cleanup=Exception[]
    if owner!==nothing
        try
            !owner.retained && snapshot!(owner,"failure-or-shutdown")
            report=primary===nothing ? nothing : sprint(showerror,primary)
            HeartCorrectionOwner.publish_report!(options,science,recorder,state,owner;failure=report)
            Lifecycle.report_published!(bridge,stopped_cursor)
        catch error
            push!(cleanup,error)
        end
    end
    if session!==nothing
        try Acquisition.close_session!(session) catch error;push!(cleanup,error) end
    elseif plant!==nothing
        try close(plant) catch error;push!(cleanup,error) end
    end
    if shutdown_ticket!==nothing && primary===nothing && isempty(cleanup)
        try
            Lifecycle.lifecycle!(bridge,Codec.Stopped)
            final=Lifecycle.snapshot(bridge,state,stopped_cursor;phase=current_phase(),
                held=current_held(),restored=owner!==nothing && owner.retained,
                window=owner===nothing ? nothing : UInt64(owner.window))
            Lifecycle.complete!(bridge,shutdown_ticket,Codec.Stopped,final)
            Lifecycle.flush_terminal!(bridge,shutdown_ticket.deadline)
        catch error
            push!(cleanup,error)
        end
    end
    primary===nothing || throw(isempty(cleanup) ? primary : CompositeException([primary;cleanup]))
    isempty(cleanup) || throw(CompositeException(cleanup))
    return nothing
end

function main(arguments=ARGS)
    prepared=options(arguments)
    Protocol.require_fresh_instance(prepared)
    bridge=HILNativeAcquisitionLifecycle.Bridge(prepared,
        HILNativeAcquisitionLifecycle.Codec.CORRECTION_PROFILE)
    try
        return Main.HILHeartControl.with_controller(prepared) do admitted
            Base.invokelatest(run_owner_native,admitted,bridge,
                Main.load_plant(admitted.profile),Main.load_target(admitted.backend))
        end
    catch error
        if !(error isa HILNativeAcquisitionLifecycle.TransportFailure) &&
                bridge.runtime.endpoint.lifecycle!==HILNativeAcquisitionLifecycle.Codec.Stopped
            try HILNativeAcquisitionLifecycle.lifecycle!(bridge,
                HILNativeAcquisitionLifecycle.Codec.Fault) catch end
        end
        rethrow()
    finally
        close(bridge)
    end
end

end

abspath(PROGRAM_FILE)==(@__FILE__) && HeartCorrectionOwner.main()
