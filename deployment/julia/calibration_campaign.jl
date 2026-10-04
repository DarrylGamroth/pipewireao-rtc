module CalibrationCampaign

using JSON3, Sockets, TOML
import ..Common: read_json, write_json, sha256_file, run_checked, cli_arguments
import ..Deployment
import ..CalibrationExport
import ..HILExport
import ..Common

export validate_recipe, positive_integer, wire_float32, same_figure, validate_batches,
       verify_capture, run_stage, stage_base, campaign, main, copy_tree, file_identity,
       check_identity, set_model_setting, validate_detector_rail, capture_contract,
       orchestration_sources

const CLASSIC_CHANNELS = Dict(
    "raw" => ("U16_LE", [352,352], 247808, "raw.u16le"),
    "slopes" => ("F32_LE", [188,2], 1504, "slopes.f32le"),
    "flux" => ("F32_LE", [188], 752, "flux.f32le"),
    "validity" => ("BOOL8", [188], 188, "validity.u8"),
)
const COPPER_CHANNELS = Dict(
    "raw" => ("U16_LE", [64,64], 8192, "raw.u16le"),
    "pixels" => ("F32_LE", [4,900], 14400, "pixels.f32le"),
    "intensity" => ("F32_LE", [1], 4, "intensity.f32le"),
)

isint(value) = value isa Integer && !(value isa Bool)
number(value) = value isa Real && !(value isa Bool) && isfinite(value)
function positive_integer(value, name, maximum; minimum=1)
    isint(value) && minimum <= value <= maximum || throw(ArgumentError("$name requires an integer in $minimum..$maximum"))
    return value
end
function wire_float32(value)
    number(value) || throw(ArgumentError("command requires a finite numeric value"))
    result = Float32(value)
    isfinite(result) && (iszero(value) || !iszero(result)) ||
        throw(ArgumentError("command is not finite non-underflowed Float32"))
    return result
end
same_figure(a,b) = a isa AbstractVector && b isa AbstractVector && length(a)==length(b) &&
    all(isequal(wire_float32(x),wire_float32(y)) for (x,y) in zip(a,b))
function fields(value, expected, label)
    value isa AbstractDict && Set(keys(value)) == Set(expected) || throw(ArgumentError("$label fields differ"))
    return value
end
function capture_contract(profile)
    profile == "classic" && return CLASSIC_CHANNELS, 250252
    profile == "copper" && return COPPER_CHANNELS, 22596
    throw(ArgumentError("capture requires declared Classic or Copper profile"))
end

function validate_settling(value; copper=false)
    value isa AbstractDict || throw(ArgumentError("settling must be an object"))
    if !copper && Set(keys(value)) == Set(["kind"]) && value["kind"] == "immediate"
        return value
    elseif Set(keys(value)) == Set(["kind","frames"]) && value["kind"] == "discard_exposures"
        positive_integer(value["frames"],"settling frames",4096)
    elseif Set(keys(value)) == Set(["kind","duration_ns"]) && value["kind"] == "model_time"
        positive_integer(value["duration_ns"],"settling duration",typemax(Int64))
    else
        throw(ArgumentError("unsupported settling rule"))
    end
    return value
end

function validate_recipe(value)
    expected = ("version","dark_frames","training_frames","qualification_frames","seeds",
        "lamp_magnitude","candidate_mask","minimum_flux","adc_upper_rail",
        "maximum_reference_residual","reference","amplitudes","frames_per_probe",
        "settling","request_timeout_ns","stage_timeout_seconds")
    fields(value,expected,"Classic recipe")
    isint(value["version"]) && value["version"] == 1 || throw(ArgumentError("unsupported Classic recipe"))
    for name in ("dark_frames","training_frames","qualification_frames")
        positive_integer(value[name],name,64;minimum=2)
    end
    positive_integer(value["frames_per_probe"],"frames_per_probe",64)
    positive_integer(value["request_timeout_ns"],"request_timeout_ns",30_000_000_000)
    positive_integer(value["stage_timeout_seconds"],"stage_timeout_seconds",3600)
    seeds = fields(value["seeds"],("dark","training","qualification","interaction"),"detector seeds")
    all(x -> isint(x) && 0 <= x <= typemax(UInt32), values(seeds)) && length(Set(values(seeds)))==4 ||
        throw(ArgumentError("four distinct UInt32 detector seeds required"))
    mask = value["candidate_mask"]
    mask isa AbstractVector && length(mask)==188 && all(x->x isa Bool,mask) && any(mask) ||
        throw(ArgumentError("nonempty 188-position candidate mask required"))
    for (name,count,positive) in (("minimum_flux",188,true),("reference",277,false),("amplitudes",277,true))
        data = value[name]
        data isa AbstractVector && length(data)==count && all(number,data) &&
            (!positive || all(>(0),data)) || throw(ArgumentError("$name requires $count finite values"))
    end
    for name in ("lamp_magnitude","maximum_reference_residual")
        number(value[name]) || throw(ArgumentError("$name must be finite"))
    end
    value["maximum_reference_residual"] > 0 || throw(ArgumentError("maximum residual must be positive"))
    positive_integer(value["adc_upper_rail"],"ADC upper rail",65535)
    validate_settling(value["settling"])
    result = deepcopy(value)
    result["reference"] = Float64.(wire_float32.(value["reference"]))
    result["amplitudes"] = Float64.(wire_float32.(value["amplitudes"]))
    return result
end

function validate_detector_rail(detector,recipe)
    bits = positive_integer(detector["bits"],"detector bits",16)
    (1 << bits)-1 == recipe["adc_upper_rail"] || throw(ArgumentError("declared ADC rail differs from deployed detector"))
end

function validate_batches(batches)
    batches isa AbstractVector && 1 <= length(batches) <= 32 || throw(ArgumentError("batches require 1..32 captures"))
    return [begin
        fields(item,("figure","frames"),"batch")
        item["figure"] isa AbstractVector && length(item["figure"])==277 ||
            throw(ArgumentError("batch figure requires 277 coordinates"))
        Dict{String,Any}("figure"=>Float64.(wire_float32.(item["figure"])),
                         "frames"=>positive_integer(item["frames"],"batch frames",64;minimum=2))
    end for item in batches]
end

function regular(path)
    parent=abspath(path)
    while true
        islink(parent) && throw(ArgumentError("linked evidence is unsupported: $parent"))
        next=dirname(parent)
        next==parent && break
        parent=next
    end
    isfile(path) || throw(ArgumentError("missing file: $path"))
    return path
end
function copy_tree(source,target)
    isdir(source) && !islink(source) && !ispath(target) || throw(ArgumentError("copy requires ordinary source and fresh target"))
    for (dir,dirs,files) in walkdir(source)
        relative = relpath(dir,source)
        destination = relative == "." ? target : joinpath(target,relative)
        mkpath(destination)
        for name in vcat(dirs,files)
            islink(joinpath(dir,name)) && throw(ArgumentError("linked copy input: $(joinpath(dir,name))"))
        end
        for name in files
            cp(joinpath(dir,name),joinpath(destination,name);force=false)
        end
    end
    return target
end
function file_identity(root)
    isdir(root) && !islink(root) || throw(ArgumentError("identity requires ordinary directory"))
    result=Dict{String,String}()
    for (dir,dirs,files) in walkdir(root)
        for name in vcat(dirs,files)
            islink(joinpath(dir,name)) && throw(ArgumentError("linked package input"))
        end
        for name in files
            path=joinpath(dir,name)
            result[relpath(path,root)] = sha256_file(path)
        end
    end
    return result
end
check_identity(root,identity) = file_identity(root)==identity || throw(ArgumentError("frozen package identity changed"))

function orchestration_sources()
    files=[path for path in readdir(@__DIR__;join=true)
        if endswith(path,".jl") && !startswith(basename(path),"test_")]
    append!(files,[joinpath(@__DIR__,name) for name in ("Project.toml","Manifest.toml")])
    for directory in ("hil","templates")
        root=joinpath(HILExport.ROOT,directory)
        for (parent,_,names) in walkdir(root), name in names
            startswith(name,"test_") || push!(files,joinpath(parent,name))
        end
    end
    assets=joinpath(@__DIR__,"assets")
    if isdir(assets)
        for (parent,_,names) in walkdir(assets), name in names
            startswith(name,"test_") || push!(files,joinpath(parent,name))
        end
    end
    push!(files,joinpath(@__DIR__,"..","pipewireao-rtc@.service.in"))
    return Dict(abspath(path)=>sha256_file(regular(path)) for path in unique(files))
end

function cursor(value)
    fields(value,("domain","generation","sequence","model_ns"),"cursor")
    all(isint(x) && 0 <= x <= typemax(UInt64) for x in values(value)) && value["domain"]==1 && value["generation"]>=1 ||
        throw(ArgumentError("malformed acquisition cursor"))
    return value
end

"""Verify a declared capture, including per-exposure payload contracts and hashes."""
function verify_capture(root,completion;run,serial,stage,frames,after,startup,profile="classic",probe=0)
    isint(probe) && 0 <= probe <= typemax(UInt64) || throw(ArgumentError("expected probe must be UInt64"))
    channels,payload_bytes=capture_contract(profile)
    startup["profile"]==profile || throw(ArgumentError("capture startup profile differs"))
    for field in ("frames","bytes","metadata_bytes")
        positive_integer(completion[field],"capture $field",typemax(Int64))
    end
    relative="$(serial)/manifest.json"
    completion["manifest"]==relative || throw(ArgumentError("noncanonical capture path"))
    manifest_path=regular(joinpath(root,relative))
    size=filesize(manifest_path)
    size==completion["metadata_bytes"] && size <= 16384+4096*frames &&
        sha256_file(manifest_path)==completion["sha256"] || throw(ArgumentError("manifest size or hash mismatch"))
    manifest=read_json(manifest_path;maximum=16384+4096*frames)
    for name in ("version","run","serial","probe","frames","bytes")
        isint(manifest[name]) || throw(ArgumentError("capture header requires integer $name"))
    end
    (manifest["version"],manifest["run"],manifest["serial"],manifest["stage"],manifest["frames"],manifest["probe"]) ==
        (1,run,serial,stage,frames,probe) || throw(ArgumentError("capture identity differs"))
    manifest["profile"]==profile && manifest["illumination"]==startup["illumination"] ||
        throw(ArgumentError("capture stage settings differ"))
    settings=Dict(name=>startup[name] for name in ("detector_config","graph_sha256","wfs_active_sha256"))
    manifest["settings"]==settings && manifest["acquisition_domain_mapping"]==startup["acquisition_domain_mapping"] &&
        manifest["settings_sha256"]==startup["capture_settings_sha256"] ||
        throw(ArgumentError("capture startup snapshot differs"))
    completion["frames"]==frames && manifest["bytes"]==frames*payload_bytes &&
        completion["bytes"]==frames*payload_bytes || throw(ArgumentError("capture payload budget differs"))
    exposures=manifest["exposures"]
    exposures isa AbstractVector && length(exposures)==frames || throw(ArgumentError("capture exposure count differs"))
    mapping=manifest["acquisition_domain_mapping"]
    bytes=mapping["complete_domain"]
    isint(mapping["opaque_domain"]) && mapping["opaque_domain"]==1 && bytes isa AbstractVector &&
        length(bytes)==16 && any(!iszero,bytes) && all(x->isint(x) && 0<=x<=255,bytes) ||
        throw(ArgumentError("missing complete acquisition domain"))
    expected_duration=round(Int,startup["detector_config"]["exposure_duration_s"]*1e9)
    cursor(after)
    after["generation"]==startup["acquisition_generation"] || throw(ArgumentError("settled generation differs"))
    previous=nothing
    for (index,exposure) in enumerate(exposures)
        for field in ("domain","generation","sequence","start_model_ns","duration_ns")
            isint(exposure[field]) && 0<=exposure[field]<=typemax(UInt64) ||
                throw(ArgumentError("invalid exposure integer: $field"))
        end
        exposure["directory"]==string(index) && exposure["domain"]==1 && exposure["generation"]>=1 &&
            exposure["duration_ns"]==expected_duration && exposure["valid"] isa Bool ||
            throw(ArgumentError("invalid exposure identity or duration"))
        if previous===nothing
            exposure["generation"]==after["generation"] &&
                Int128(exposure["sequence"])==Int128(after["sequence"])+1 &&
                exposure["start_model_ns"]>=after["model_ns"] || throw(ArgumentError("capture does not follow settled cursor"))
        else
            exposure["generation"]==previous["generation"] &&
                Int128(exposure["sequence"])==Int128(previous["sequence"])+1 &&
                Int128(exposure["start_model_ns"])>=Int128(previous["start_model_ns"])+Int128(previous["duration_ns"]) ||
                throw(ArgumentError("capture is not consecutive"))
        end
        Set(keys(exposure["files"]))==Set(keys(channels)) || throw(ArgumentError("capture channel set differs"))
        for (name,(element,shape,channel_bytes,filename)) in channels
            record=exposure["files"][name]
            record["path"]==filename && record["element_type"]==element && record["shape"]==shape &&
                record["layout"]=="ROW_MAJOR" && record["bytes"]==channel_bytes ||
                throw(ArgumentError("capture channel contract differs: $name"))
            payload=regular(joinpath(root,string(serial),string(index),filename))
            filesize(payload)==channel_bytes && sha256_file(payload)==record["sha256"] ||
                throw(ArgumentError("capture payload differs: $name"))
        end
        previous=exposure
    end
    final_model_ns=Int128(previous["start_model_ns"])+Int128(previous["duration_ns"])
    final_model_ns<=typemax(UInt64) || throw(ArgumentError("capture completion model time overflowed"))
    final=Dict("domain"=>1,"generation"=>previous["generation"],"sequence"=>previous["sequence"],
               "model_ns"=>final_model_ns)
    cursor(completion["cursor"])
    completion["cursor"]==final || throw(ArgumentError("capture completion cursor differs"))
    return manifest
end

mutable struct Endpoint
    socket::IO
    run::Int
    serial::Int
    timeout_ns::Int
    records::Vector{Any}
    can_restore::Bool
end

function endpoint_connect(path,run,timeout_ns)
    task=@async Sockets.connect(path)
    status=timedwait(() -> istaskdone(task), timeout_ns/1e9;pollint=0.001)
    status==:ok || throw(ErrorException("calibration socket connection timed out"))
    return Endpoint(fetch(task),run,0,timeout_ns,Any[],false)
end

function request!(endpoint::Endpoint,action,expected)
    endpoint.can_restore=false
    endpoint.serial+=1
    sent=Dict{String,Any}("version"=>1,"run"=>endpoint.run,"serial"=>endpoint.serial,
                          "timeout_ns"=>endpoint.timeout_ns,"action"=>action)
    payload=JSON3.write(sent)*"\n"
    ncodeunits(payload)<=16384 || throw(ArgumentError("calibration request exceeds protocol limit"))
    started=time_ns()
    task=@async begin
        write(endpoint.socket,payload)
        reply=UInt8[]
        while length(reply)<65536
            byte=read(endpoint.socket,UInt8)
            push!(reply,byte)
            byte==0x0a && return reply
        end
        throw(ArgumentError("oversized calibration completion"))
    end
    status=timedwait(() -> istaskdone(task),endpoint.timeout_ns/1e9;pollint=0.001)
    if status!=:ok
        close(endpoint.socket)
        throw(ErrorException("calibration request expired; outcome unknown"))
    end
    reply=fetch(task)
    Int128(time_ns())-Int128(started) < endpoint.timeout_ns ||
        throw(ErrorException("late calibration completion; outcome unknown"))
    document=Common.parse_json(String(reply))
    fields(document,("version","run","serial","result"),"completion")
    for key in ("version","run","serial")
        isint(document[key]) && document[key]==sent[key] || throw(ArgumentError("uncorrelated completion; outcome unknown"))
    end
    push!(endpoint.records,Dict("request"=>sent,"reply"=>document))
    result=document["result"]
    result isa AbstractDict || throw(ArgumentError("malformed completion; outcome unknown"))
    if get(result,"kind",nothing)=="failed"
        if Set(keys(result))==Set(["kind","reason"]) && result["reason"]=="invalid_evidence"
            endpoint.can_restore=true
        end
        throw(ArgumentError("calibration rejected $(action["kind"]): $(result)"))
    end
    shapes=Dict("held"=>("kind","cursor"),"adopted"=>("kind","cursor","figure","clipped"),
        "settled"=>("kind","cursor"),"captured"=>("kind","cursor","manifest","sha256","frames","bytes","metadata_bytes"),
        "restored"=>("kind","figure","clipped"),"released"=>("kind",))
    haskey(shapes,expected) || throw(ArgumentError("unknown completion kind"))
    get(result,"kind",nothing)==expected && Set(keys(result))==Set(shapes[expected]) ||
        throw(ArgumentError("malformed completion; outcome unknown"))
    haskey(result,"cursor") && cursor(result["cursor"])
    if haskey(result,"clipped")
        result["clipped"] isa Bool && result["figure"] isa AbstractVector && length(result["figure"])==277 &&
            all(number,result["figure"]) || throw(ArgumentError("malformed command completion"))
    end
    endpoint.can_restore=expected!="restored" || !result["clipped"]
    return result
end

function stage_remaining(deadline,limit)
    remaining=(Int128(deadline)-Int128(time_ns()))/1e9
    remaining>0 || throw(ErrorException("calibration stage deadline expired"))
    return min(remaining,limit)
end

function run_stage(package,output,runtime,recipe,stage;frames=nothing,batches=nothing)
    batches===nothing || frames===nothing || throw(ArgumentError("frames and batches are mutually exclusive"))
    normalized=batches===nothing ? nothing : validate_batches(batches)
    profile=nothing
    if frames!==nothing || normalized!==nothing
        profile=read_json(joinpath(package,"provenance.json"))["profile"]
        _,payload_bytes=capture_contract(profile)
        if normalized!==nothing
            profile=="copper" || throw(ArgumentError("batches require Copper profile"))
            required=sum(item["frames"]*payload_bytes for item in normalized)
            provenance=read_json(joinpath(package,"provenance.json"))
            provenance["capture_max_payload_bytes"]==required || throw(ArgumentError("exported capture budget differs"))
        end
    end
    !ispath(output) && !islink(output) && !ispath(runtime) && !islink(runtime) ||
        throw(ArgumentError("stage output and runtime must be fresh"))
    stage_started=time_ns()
    deadline=Int128(stage_started)+Int128(recipe["stage_timeout_seconds"])*1_000_000_000
    mkpath(output)
    command=[Base.julia_cmd().exec[1],"--startup-file=no","--project="*@__DIR__,
             joinpath(@__DIR__,"deploy_cli.jl"),"run",
             "--deployment",joinpath(package,"deployment.conf"),"--runtime",runtime,
             "--pipewire-prefix","/opt/pipewireao"]
    result=Dict{String,Any}("stage"=>stage,"run_argv"=>command,
        "restoration_confirmed"=>false,"release_confirmed"=>false,"shutdown_confirmed"=>false,
        "timing_ns"=>Dict{String,Any}(name=>nothing for name in
            ("startup_readiness","acquisition","public_shutdown","total_stage")),
        "timing_confirmed"=>Dict{String,Any}(name=>false for name in
            ("startup_readiness","acquisition","public_shutdown")))
    normalized===nothing || (result["captures"]=Any[])
    endpoint=nothing
    process=nothing
    acquisition_started=nothing
    shutdown_started=nothing
    startup_started=time_ns()
    try
        open(joinpath(output,"deployment.log"),"w") do log
            process=run(pipeline(Cmd(command),stdout=log,stderr=log);wait=false)
            ready=Deployment.wait_state(runtime,s->get(s,"phase",nothing)=="running";
                timeout=stage_remaining(deadline,recipe["stage_timeout_seconds"]),process=process)
            isint(ready["pid"]) && ready["pid"]==getpid(process) ||
                throw(ArgumentError("runtime state belongs to another launcher"))
            ready_ns=time_ns()
            result["timing_ns"]["startup_readiness"]=ready_ns-startup_started
            result["timing_confirmed"]["startup_readiness"]=true
            acquisition_started=ready_ns
            instance=dirname(ready["socket"])
            result["ready"]=ready
            result["startup_report"]=read_json(joinpath(instance,"simulator-result.json"))
            if frames!==nothing || normalized!==nothing
                limit=Int(recipe["request_timeout_ns"])
                endpoint=endpoint_connect(joinpath(instance,"calibration.sock"),1,
                    Int(floor(stage_remaining(deadline,limit/1e9)*1e9)))
                request=(action,expected)->begin
                    endpoint.timeout_ns=max(1,Int(floor(stage_remaining(deadline,limit/1e9)*1e9)))
                    request!(endpoint,action,expected)
                end
                held=request(Dict("kind"=>"hold"),"held")
                commands=normalized===nothing ? [Dict("figure"=>recipe["reference"],"frames"=>frames)] : normalized
                previous=held["cursor"]
                captures=normalized===nothing ? Any[] : result["captures"]
                normalized===nothing || mkdir(joinpath(output,"captured"))
                for (index,batch) in enumerate(commands)
                    probe=index-1
                    adopted=request(Dict("kind"=>"adopt","probe"=>probe,"figure"=>batch["figure"]),"adopted")
                    !adopted["clipped"] && same_figure(adopted["figure"],batch["figure"]) &&
                        adopted["cursor"]==previous || throw(ArgumentError("figure adoption clipped or moved cursor"))
                    settled=request(Dict("kind"=>"settle","probe"=>probe,"after"=>adopted["cursor"],
                                         "rule"=>recipe["settling"]),"settled")
                    capture=request(Dict("kind"=>"capture","probe"=>probe,"after"=>settled["cursor"],
                                         "frames"=>batch["frames"]),"captured")
                    serial=endpoint.serial
                    push!(captures,Dict("probe"=>probe,"serial"=>serial,"figure"=>batch["figure"],
                        "settled_cursor"=>settled["cursor"],"completion"=>capture))
                    if normalized!==nothing
                        copy_tree(joinpath(instance,"captured",string(serial)),joinpath(output,"captured",string(serial)))
                        verify_capture(joinpath(output,"captured"),capture;run=1,serial,stage,
                            frames=batch["frames"],after=settled["cursor"],startup=result["startup_report"],profile,probe)
                        stage_remaining(deadline,recipe["stage_timeout_seconds"])
                        previous=capture["cursor"]
                    end
                end
                restored=request(Dict("kind"=>"restore","figure"=>recipe["reference"],
                                      "rule"=>recipe["settling"]),"restored")
                !restored["clipped"] && same_figure(restored["figure"],recipe["reference"]) ||
                    throw(ArgumentError("reference restoration clipped or changed"))
                result["restoration_confirmed"]=true
                request(Dict("kind"=>"release"),"released")
                result["release_confirmed"]=true
                result["timing_ns"]["acquisition"]=time_ns()-acquisition_started
                result["timing_confirmed"]["acquisition"]=true
                result["requests"]=endpoint.records
                close(endpoint.socket)
                endpoint=nothing
                if normalized===nothing
                    copy_tree(joinpath(instance,"captured"),joinpath(output,"captured"))
                    item=only(captures)
                    verify_capture(joinpath(output,"captured"),item["completion"];run=1,serial=4,stage,
                        frames,after=item["settled_cursor"],startup=result["startup_report"],profile,probe=0)
                    result["capture"]=item["completion"]
                end
            else
                argv=[joinpath(package,"bin","rtc-calibrate"),"--endpoint",joinpath(instance,"calibration.sock"),
                      "--plan",joinpath(dirname(output),"interaction-plan.json")]
                response=run_checked(argv;timeout=stage_remaining(deadline,recipe["stage_timeout_seconds"]))
                write(joinpath(output,"rtc-calibrate.json"),response.stdout)
                write(joinpath(output,"rtc-calibrate.stderr"),response.stderr)
                response.returncode==0 || throw(ErrorException("rtc-calibrate exited $(response.returncode)"))
                matrix=Common.parse_json(response.stdout)
                matrix["phase"]=="complete" && matrix["failure"]===nothing &&
                    matrix["recovery_failure"]===nothing && matrix["restoration_confirmed"]===true &&
                    matrix["resume_permitted"]===true || throw(ArgumentError("interaction stage incomplete"))
                result["restoration_confirmed"]=result["release_confirmed"]=true
                result["timing_ns"]["acquisition"]=time_ns()-acquisition_started
                result["timing_confirmed"]["acquisition"]=true
            end
            shutdown_started=time_ns()
            final=Deployment.shutdown(runtime,process;timeout=stage_remaining(deadline,55.0))
            result["shutdown_confirmed"]=true
            result["final"]=final
            result["timing_ns"]["public_shutdown"]=time_ns()-shutdown_started
            result["timing_confirmed"]["public_shutdown"]=true
            stage_remaining(deadline,recipe["stage_timeout_seconds"])
        end
    catch error
        failed=time_ns()
        result["timing_ns"]["startup_readiness"]===nothing && (result["timing_ns"]["startup_readiness"]=failed-startup_started)
        acquisition_started!==nothing && result["timing_ns"]["acquisition"]===nothing &&
            (result["timing_ns"]["acquisition"]=failed-acquisition_started)
        shutdown_started!==nothing && result["timing_ns"]["public_shutdown"]===nothing &&
            (result["timing_ns"]["public_shutdown"]=failed-shutdown_started)
        result["failure"]=sprint(showerror,error)
        if endpoint!==nothing && endpoint.can_restore && !result["release_confirmed"]
            try
                endpoint.timeout_ns=Int(recipe["request_timeout_ns"])
                restored=request!(endpoint,Dict("kind"=>"restore","figure"=>recipe["reference"],
                        "rule"=>recipe["settling"]),"restored")
                !restored["clipped"] && same_figure(restored["figure"],recipe["reference"]) ||
                    throw(ArgumentError("abort restoration clipped or changed"))
                result["restoration_confirmed"]=true
                request!(endpoint,Dict("kind"=>"release"),"released")
                result["release_confirmed"]=true
            catch recovery
                result["recovery_failure"]=sprint(showerror,recovery)
            end
        end
        endpoint===nothing || (result["requests"]=endpoint.records)
        if process!==nothing && result["release_confirmed"] && !result["shutdown_confirmed"] &&
                !process_exited(process) && isfile(joinpath(runtime,"state.json"))
            try
                shutdown_started=time_ns()
                grace=min(55.0,max(5.0,(deadline-Int128(time_ns()))/1e9))
                result["final"]=Deployment.shutdown(runtime,process;timeout=grace)
                result["shutdown_confirmed"]=true
                result["timing_ns"]["public_shutdown"]=time_ns()-shutdown_started
                result["timing_confirmed"]["public_shutdown"]=true
            catch cleanup
                result["cleanup_failure"]=sprint(showerror,cleanup)
            end
        end
        rethrow()
    finally
        if endpoint!==nothing
            try close(endpoint.socket) catch end
        end
        if process!==nothing
            if !process_exited(process)
                try kill(process,Base.SIGINT) catch end
                timedwait(() -> process_exited(process),Deployment.CLEANUP_TIMEOUT_SECONDS;pollint=0.01)==:ok ||
                    (try kill(process,Base.SIGKILL) catch end)
                timedwait(() -> process_exited(process),5.0;pollint=0.01)
            end
            result["launcher_exit"]=process_exited(process) ? process.exitcode : nothing
        else
            result["launcher_exit"]=nothing
        end
        finished=time_ns()
        acquisition_started!==nothing && result["timing_ns"]["acquisition"]===nothing &&
            (result["timing_ns"]["acquisition"]=finished-acquisition_started)
        shutdown_started!==nothing && result["timing_ns"]["public_shutdown"]===nothing &&
            (result["timing_ns"]["public_shutdown"]=finished-shutdown_started)
        result["timing_ns"]["total_stage"]=finished-stage_started
        write_json(joinpath(output,"stage-result.json"),result)
    end
    return result
end

function set_model_setting(text,node,field,value)
    sections=split(text,r"(?m)(?=^\[\[nodes\]\])";keepempty=true)
    matches=findall(section->occursin(Regex("(?m)^name\\s*=\\s*\""*node*"\"\\s*\$"),section),sections)
    length(matches)==1 || throw(ArgumentError("expected one plant node $node"))
    index=only(matches)
    pattern=Regex("(?m)^"*field*"\\s*=\\s*[^\\n]+\$")
    length(collect(eachmatch(pattern,sections[index])))==1 || throw(ArgumentError("expected one $node.$field"))
    sections[index]=replace(sections[index],pattern=>field*" = "*string(value);count=1)
    return join(sections)
end

function stage_base(base,output,recipe,stage,background,references,active,aoc_source,prefix)
    original=read_json(joinpath(base,"provenance.json"))
    specification=Deployment.profile(joinpath(base,"deployment.conf"),prefix)
    source=only(filter(owner->owner["role"]==specification["source-owner"],specification["owners"]))
    argv=source["argv"]
    original["profile"]=="classic" && original["mode"]=="frame" &&
        original["hil"]["backend"]=="cpu" && count(==("--backend"),argv)==1 &&
        argv[findfirst(==("--backend"),argv)+1]=="cpu" ||
        throw(ArgumentError("Classic campaign requires complete-frame CPU science"))
    for (name,payload,expected) in (("background",background,495616),
                                    ("reference-slopes",references,1504),("active",active,188))
        length(payload)==expected || throw(ArgumentError("wrong startup extent for $name"))
    end
    copy_tree(base,output)
    provenance=deepcopy(original)
    graph=Deployment.decode(joinpath(output,"graphs","graph.conf.in"),prefix)
    wfs=only(filter(node->node["label"]=="shack-hartmann-image-f32",graph["filter.graph"]["nodes"]))
    bindings=Dict(item["name"]=>item for item in vcat(provenance["parameters"],get(provenance,"construction_parameters",Any[])))
    for (name,payload) in (("background",background),("reference-slopes",references),("active",active))
        binding=bindings[name]
        path=joinpath(output,"calibration",binding["file"])
        write(path,payload)
        haskey(binding,"sha256") && (binding["sha256"]=sha256_file(path))
    end
    haskey(wfs["config"],"active") && (wfs["config"]["active"]=Bool.(active))
    write(joinpath(output,"graphs","graph.conf.in"),CalibrationExport.spa_json(graph)*"\n")
    model_path=joinpath(output,"hil","plant.toml")
    model=set_model_setting(read(model_path,String),"shwfs","source_magnitude",recipe["lamp_magnitude"])
    model=set_model_setting(model,"detector","rng_seed",recipe["seeds"][stage])
    detector=only(filter(node->node["name"]=="detector",TOML.parse(model)["nodes"]))["config"]
    validate_detector_rail(detector,recipe)
    write(model_path,model)
    target=joinpath(output,"hil","packages","AdaptiveOpticsCalibration")
    rm(target;recursive=true)
    HILExport.copy_package(aoc_source,target)
    provenance["campaign_stage_inputs"]=Dict("stage"=>stage,"recipe"=>recipe,
        "source_deployment_sha256"=>sha256_file(joinpath(base,"deployment.conf")),
        "source_aoc_files"=>file_identity(target),
        "previous_offset_provenance"=>"historical base only; startup offsets replaced by campaign inputs")
    write_json(joinpath(output,"provenance.json"),provenance)
    descriptor=read_json(joinpath(output,"deployment.conf"))
    descriptor["artifacts"]=Dict(relative=>sha for (relative,sha) in file_identity(output)
        if relative!="deployment.conf")
    write_json(joinpath(output,"deployment.conf"),descriptor)
    Deployment.profile(joinpath(output,"deployment.conf"),prefix)
    return output
end

function checked_analysis(argv,output,name,timeout)
    response=run_checked(argv;timeout,env=Dict("OPENBLAS_NUM_THREADS"=>"1"))
    write(joinpath(output,name*".stdout"),response.stdout)
    write(joinpath(output,name*".stderr"),response.stderr)
    response.returncode==0 || throw(ErrorException("analysis $name exited $(response.returncode)"))
    return response
end

function campaign(arguments)
    started=time_ns()
    Base.ENDIAN_BOM==0x04030201 || throw(ArgumentError("packed calibration requires little-endian host"))
    recipe=validate_recipe(read_json(arguments.recipe))
    output=abspath(arguments.output)
    !ispath(output) && !islink(output) || throw(ArgumentError("campaign output must be fresh"))
    aoc=abspath(arguments.aoc_source)
    isfile(joinpath(aoc,"src","reference_frames","reference_frames.jl")) ||
        throw(ArgumentError("AOC ReferenceFrames source is required"))
    source_identity=orchestration_sources()
    base_identity=file_identity(abspath(arguments.base_package))
    aoc_identity=file_identity(aoc)
    recipe_sha=sha256_file(arguments.recipe)
    binary_identity=Dict(abspath(path)=>sha256_file(regular(path)) for path in
        (arguments.rtc_binary,arguments.calibration_binary))
    mkpath(output)
    write_json(joinpath(output,"recipe.json"),recipe)
    background=zeros(UInt8,495616)
    references=zeros(UInt8,1504)
    active=UInt8.(recipe["candidate_mask"])
    record=Dict{String,Any}("version"=>1,"phase"=>"candidate","stages"=>Dict{String,Any}(),
        "scope"=>"Classic CPU simulated calibration; no precision, correction or cadence acceptance",
        "source_files"=>source_identity,"base_files"=>base_identity,"aoc_files"=>aoc_identity,
        "recipe_input_sha256"=>recipe_sha,"binary_files"=>binary_identity)
    check_inputs=()->begin
        orchestration_sources()==source_identity && file_identity(abspath(arguments.base_package))==base_identity &&
            file_identity(aoc)==aoc_identity && sha256_file(arguments.recipe)==recipe_sha &&
            all(sha256_file(path)==hash for (path,hash) in binary_identity) ||
            throw(ArgumentError("Classic campaign source input changed"))
    end
    try
        for (stage,frame_key) in (("dark","dark_frames"),("training","training_frames"),
                                  ("qualification","qualification_frames"),("interaction",nothing))
            check_inputs()
            base=stage_base(abspath(arguments.base_package),joinpath(output,stage*"-base"),recipe,
                stage,background,references,active,aoc,arguments.pipewire_prefix)
            package=joinpath(output,stage*"-package")
            frames=frame_key===nothing ? nothing : recipe[frame_key]
            CalibrationExport.export_package((;base_package=base,output=package,
                pipewire_prefix=arguments.pipewire_prefix,deployment=true,
                rtc_binary=arguments.rtc_binary,calibration_binary=arguments.calibration_binary,
                illumination=stage=="dark" ? "dark" : "lamp",calibration_stage=stage,
                capture_max_bytes=frames===nothing ? nothing : frames*250252))
            package_identity=file_identity(package)
            evidence=joinpath(output,stage*"-evidence")
            if stage=="dark"
                checked_analysis([arguments.julia,"--startup-file=no","--project="*joinpath(package,"hil"),
                    joinpath(HILExport.ROOT,"hil","calibration_campaign_analysis.jl"),"prepare",output,output],
                    output,"preparation",recipe["stage_timeout_seconds"])
            end
            record["stages"][stage]=run_stage(package,evidence,joinpath(arguments.runtime,stage),recipe,stage;frames)
            check_identity(package,package_identity)
            check_inputs()
            checked_analysis([arguments.julia,"--startup-file=no","--project="*joinpath(package,"hil"),
                joinpath(HILExport.ROOT,"hil","calibration_campaign_analysis.jl"),stage,output,evidence],
                evidence,"analysis",recipe["stage_timeout_seconds"])
            check_identity(package,package_identity)
            check_inputs()
            if stage=="dark"
                background=read(joinpath(output,"measured-background.f32le"))
            elseif stage=="training"
                references=read(joinpath(output,"measured-reference-slopes.f32le"))
                active=read(joinpath(output,"measured-active.u8"))
            end
        end
        check_inputs()
        record["phase"]="complete-candidate"
    catch error
        record["failure"]=sprint(showerror,error)
        rethrow()
    finally
        record["artifacts"]=Dict(basename(path)=>sha256_file(path) for path in
            readdir(output;join=true) if startswith(basename(path),"measured-") && isfile(path))
        record["timing_ns"]=Dict("total_campaign"=>time_ns()-started)
        Deployment.atomic_record(joinpath(output,"campaign-result.json"),record)
    end
    return joinpath(output,"campaign-result.json")
end

function main(argv=ARGS)
    arguments=cli_arguments(argv;required=["base-package","output","recipe","aoc-source","rtc-binary",
        "calibration-binary","runtime"],defaults=(pipewire_prefix="/opt/pipewireao",julia="julia"))
    arguments.pipewire_prefix=="/opt/pipewireao" || throw(ArgumentError("only /opt/pipewireao is supported"))
    println(campaign(arguments))
end

end # module
