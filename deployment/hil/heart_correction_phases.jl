"""Strict public native telemetry ownership across active control phases.

Native state changes rotate file writers asynchronously. File record counts
restart in each file while CB bucket and exposure sync counters remain global.
The active owner gates publication on all five new empty phase headers.
"""
module HeartCorrectionPhases

using SHA
import ..HeartCalibrationTelemetry, ..HeartCorrectionTelemetry, ..HeartCorrectionProfiles
const Telemetry=HeartCalibrationTelemetry
const CorrectionTelemetry=HeartCorrectionTelemetry
const Profiles=HeartCorrectionProfiles
const STREAMS=(("cbHoPixelsRaw0",7,(64,64)),("cbHoPixelsCalib0",8,(64,64)),
    ("cbHoGrad0",8,(3600,1)),("cbClUnclipped0",16,(253,1)),("cbDmCmd0",20,(277,1)))
const PHASES=(:startup_run,:correcting,:restore_run)
phase_state(phase)=phase===:correcting ? "CORRECTING" : phase in (:startup_run,:restore_run) ? "RUNNING" : throw(ArgumentError("undeclared native telemetry phase"))

stream_contract(profile::Symbol)=Tuple((tag,datatype,shape) for (tag,datatype,shape,_) in Profiles.streams(profile,256))

mutable struct PhaseStore
    profile::Symbol
    streams::NTuple{5,Tuple{String,Int,Tuple{Int,Int}}}
    current::Union{Nothing,Symbol}
    paths::Dict{Symbol,Dict{String,String}}
end
PhaseStore(profile::Symbol=:copper)=PhaseStore(profile,stream_contract(profile),nothing,Dict{Symbol,Dict{String,String}}())
digest(path)=bytes2hex(open(sha256,path))

function paths_for(root,tag)
    pattern=Regex("^\\d{4}-\\d{2}-\\d{2}_\\d{2}-\\d{2}-\\d{2}_"*tag*"_(RUNNING|CORRECTING)_[0-9]{8}T[0-9]{6}\\.[0-9]+\\.tel\$")
    candidates=filter(path->endswith(path,".tel") && occursin("_"*tag*"_",basename(path)),readdir(root;join=true))
    all(path->occursin(pattern,basename(path)) && !islink(path) && isfile(path),candidates) || error("undeclared or linked native phase file")
    length(candidates)<=3 || error("native telemetry phase file bound exceeded")
    return sort(candidates)
end

function open_reader(path,tag,datatype,shape,budget)
    return datatype==16 ? CorrectionTelemetry.vdm_reader(path;tag,maximum_bytes=budget,coordinates=shape[1]) :
        Telemetry.TelemetryReader(path;tag,datatype,shape,maximum_bytes=budget)
end

function expected_count(phase,tag,frames)
    phase in PHASES || error("undeclared native telemetry phase")
    return phase===:correcting ? frames : tag=="cbDmCmd0" ? 1 : 0
end

function first_bucket(phase,tag,frames)
    return phase===:startup_run ? 0 : phase===:correcting ? (tag=="cbDmCmd0" ? 1 : 0) : tag=="cbDmCmd0" ? frames+1 : frames
end

function require_file_counters(path,phase,tag,frames,count)
    header=open(io->read(io,1024),path)
    length(header)==1024 || error("native phase header is incomplete")
    first=first_bucket(phase,tag,frames)
    Telemetry.value_at(UInt64,header,128)==first && Telemetry.value_at(UInt64,header,136)==first+count &&
        Telemetry.value_at(UInt64,header,144)==count || error("native phase per-file/global counters differ")
    return nothing
end

function require_paths(store,root)
    for (tag,_,_) in store.streams
        known=[files[tag] for files in values(store.paths)]
        paths_for(root,tag)==sort(known) || error("unexpected native phase file for $tag")
    end
    all_paths=filter(path->endswith(path,".tel"),readdir(root;join=true))
    expected_paths=[path for phase in values(store.paths) for path in values(phase)]
    sort(all_paths)==sort(expected_paths) || error("undeclared native telemetry stream remains")
    return nothing
end

function require_identity(reader,path)
    !islink(path) && isfile(path) || error("native phase path was replaced")
    metadata=stat(path)
    metadata.device==reader.device && metadata.inode==reader.inode || error("native phase file identity changed")
    return nothing
end

function drained!(session,store,frames)
    phase=store.current
    phase!==nothing || error("native telemetry phase has not started")
    for (tag,_,_) in store.streams
        reader=get(session.readers,tag,nothing)
        reader!==nothing || error("native phase reader is absent")
        require_identity(reader,store.paths[phase][tag])
        count=expected_count(phase,tag,frames)
        reader.frames==count && Telemetry.next_frame!(reader)===nothing &&
            filesize(store.paths[phase][tag])==1024+count*(64+reader.spec.data_bytes) ||
            error("native phase has missing, extra or partial records")
        require_file_counters(store.paths[phase][tag],phase,tag,frames,count)
    end
    return nothing
end

"""Wait for the next declared empty file set before any new publication.

The previous phase must already be fully consumed. Once all new headers exist,
the native writer has closed its preceding file; old readers are checked again
and closed. No filename or command ACK supplies a frame identity.
"""
function enter!(session,store,phase,until;remaining,frames)
    expected=store.current===nothing ? :startup_run : store.current===:startup_run ? :correcting : store.current===:correcting ? :restore_run : nothing
    phase===expected && !haskey(store.paths,phase) || error("native telemetry phase transition differs")
    old=store.current
    old===nothing || drained!(session,store,frames)
    selected=Dict{String,String}()
    readers=Dict{String,Telemetry.TelemetryReader}()
    try
        while length(readers)<length(store.streams)
            remaining(until);session.service()
            for (tag,datatype,shape) in store.streams
                known=[files[tag] for files in values(store.paths)]
                new=setdiff(paths_for(session.options.heart_native_runtime,tag),known)
                length(new)<=1 || error("duplicate new native phase files")
                isempty(new) && continue
                path=only(new)
                occursin("_"*phase_state(phase)*"_",basename(path)) || error("unexpected native state rotation")
                if haskey(readers,tag)
                    selected[tag]==path || error("new native phase path changed")
                    Telemetry.next_frame!(readers[tag])===nothing || error("native record arrived before phase admission")
                elseif filesize(path)>=1024
                    reader=open_reader(path,tag,datatype,shape,session.options.heart_telemetry_max_bytes)
                    readers[tag]=reader;selected[tag]=path
                    Telemetry.next_frame!(reader)===nothing && filesize(path)==1024 || error("native phase is not initially empty")
                    require_file_counters(path,phase,tag,frames,0)
                end
            end
            length(readers)==length(store.streams) || sleep(0.001)
        end
        for (tag,_,_) in store.streams
            require_identity(readers[tag],selected[tag])
            Telemetry.next_frame!(readers[tag])===nothing && filesize(selected[tag])==1024 ||
                error("native record arrived before phase admission")
            require_file_counters(selected[tag],phase,tag,frames,0)
        end
        old===nothing || drained!(session,store,frames)
        foreach(close,values(session.readers));empty!(session.readers)
        merge!(session.readers,readers);empty!(readers)
        store.paths[phase]=selected;store.current=phase
        require_paths(store,session.options.heart_native_runtime)
        return Dict(tag=>(;path=selected[tag],device=session.readers[tag].device,inode=session.readers[tag].inode,
            per_file_records=0) for (tag,_,_) in store.streams)
    finally
        foreach(close,values(readers))
    end
end

function read_frame!(session,store,tag,datatype,shape,until;remaining)
    store.current!==nothing || error("native phase is not admitted")
    (tag,datatype,shape) in store.streams || error("native active stream contract differs")
    require_paths(store,session.options.heart_native_runtime)
    reader=get(session.readers,tag,nothing)
    reader!==nothing || error("native active phase reader is absent")
    require_identity(reader,store.paths[store.current][tag])
    frame=Telemetry.await_frame!(reader;timeout_ns=remaining(until),service=session.service)
    require_paths(store,session.options.heart_native_runtime)
    require_identity(reader,store.paths[store.current][tag])
    return frame
end

function validate_frame(frame,phase,tag,index,frames;profile::Symbol=:copper,active=nothing,thresholds=nothing)
    expected_bucket=tag=="cbDmCmd0" ? (phase===:startup_run ? 0 : phase===:restore_run ? frames+1 : index) : index-1
    expected_sync=tag=="cbClUnclipped0" ? 0 : tag=="cbDmCmd0" ? (phase===:startup_run ? 0 : phase===:restore_run ? frames : index) : index
    frame.bucket==expected_bucket && frame.sync==expected_sync || error("native phase global bucket/exposure sync differs")
    if tag=="cbHoPixelsCalib0"
        frame.state==2 && frame.progress==frame.required && frame.timestamp_us>=0 || error("native calibrated phase record differs")
    else
        Telemetry.require_complete(frame)
    end
    tag=="cbClUnclipped0" && CorrectionTelemetry.vdm_values(frame,UInt64(index);coordinates=Profiles.descriptor(profile).coordinates)
    if tag=="cbHoGrad0" && profile===:classic
        Profiles.normal_response(frame,profile,active;thresholds)
    end
    return nothing
end

"""Decode every retained phase file, including both empty WFS RUN sets."""
function read_archive(root;frames::Int,budget::UInt64,profile::Symbol=:copper,active=nothing,thresholds=nothing)
    0<frames<=256 || error("native retained phase frame bound differs")
    result=Dict{Symbol,Dict{String,Vector{Telemetry.TelemetryFrame}}}()
    files=Dict{String,String}()
    for phase in PHASES
        selected=Dict{String,Vector{Telemetry.TelemetryFrame}}()
        for (tag,datatype,shape) in stream_contract(profile)
            candidates=filter(path->occursin("_"*phase_state(phase)*"_",basename(path)),paths_for(root,tag))
            length(candidates)==(phase===:correcting ? 1 : 2) || error("native retained phase file set differs")
            count=expected_count(phase,tag,frames)
            matching=filter(candidates) do path
                header=open(io->read(io,1024),path)
                length(header)==1024 && Telemetry.value_at(UInt64,header,128)==first_bucket(phase,tag,frames)
            end
            length(matching)==1 || error("native retained phase global starting bucket differs")
            path=only(matching)
            before=digest(path)
            reader=open_reader(path,tag,datatype,shape,budget)
            records=Telemetry.TelemetryFrame[]
            try
                for index in 1:count
                    frame=Telemetry.next_frame!(reader)
                    frame!==nothing || error("native retained phase record is absent")
                    validate_frame(frame,phase,tag,index,frames;profile,active,thresholds);push!(records,frame)
                end
                Telemetry.next_frame!(reader)===nothing && reader.frames==count &&
                    filesize(path)==1024+count*(64+reader.spec.data_bytes) || error("extra or partial native phase records remain")
                require_file_counters(path,phase,tag,frames,count)
            finally
                close(reader)
            end
            digest(path)==before || error("native retained phase changed during decoding")
            selected[tag]=records;files[basename(path)]=before
        end
        result[phase]=selected
    end
    Set(keys(files))==Set(basename(path) for path in readdir(root;join=true) if endswith(path,".tel")) || error("undeclared retained native telemetry file remains")
    return (;phases=result,files)
end

end
