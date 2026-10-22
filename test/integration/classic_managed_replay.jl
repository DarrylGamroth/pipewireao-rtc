# Opt-in CPU science validation through a fresh, non-actuating headless RTC.
module ClassicManagedReplay
using Test, TOML, SHA, Libdl, LinearAlgebra, Statistics
using PipeWireAO, PipeWireAORTC, AdaptiveOpticsSim, AdaptiveOpticsSim.AlgorithmGraphs
using AdaptiveOpticsSimPipeWireHIL, REVOLTClassicSim
using FilterGraphIsland, FilterGraphPipeWire, JuliaFilterGraph
include("classic_observation.jl")
include("classic_replay.jl")
module FaultCleanup
include("session_faults.jl")
end
const R = PipeWireAORTC
const W = R.SessionRuntime
const C = R.Common
const SCALE = Float32(1e-6)
const SOURCE_HASHES = Dict(name=>C.sha256_file(joinpath(@__DIR__,name)) for name in
    ("classic_managed_replay.jl","classic_replay.jl","classic_observation.jl","session_faults.jl"))

mutable struct PrefixCapture{C,T}
    capture::C
    values::Matrix{T}
    seen::BitVector
    headers::Vector{Union{Nothing,BufferHeader}}
    identities::Vector{Union{Nothing,AcquisitionIdentity}}
end
function PrefixCapture(capture, count)
    return PrefixCapture(capture,zeros(eltype(capture.values),length(capture.values),count),
        falses(count),Union{Nothing,BufferHeader}[nothing for _ in 1:count],
        Union{Nothing,AcquisitionIdentity}[nothing for _ in 1:count])
end
function (record::PrefixCapture)(stream)
    capture = record.capture
    capture(stream) # Copies borrowed bytes and returns the native buffer first.
    capture.error===nothing && capture.header!==nothing || return nothing
    try
        sequence = capture.header.sequence
        1<=sequence<=length(record.seen) || error("sample outside selected finite prefix")
        index = Int(sequence)
        if record.seen[index]
            @views isequal(record.values[:,index],capture.values) || error("duplicate sequence changed payload")
        else
            copyto!(@view(record.values[:,index]),capture.values)
            record.headers[index]=capture.header
            record.identities[index]=capture.identity
            record.seen[index]=true
        end
    catch err
        capture.error=err
    end
    return nothing
end

function request(handle, stage, name, argv)
    reply = W.control!(handle,R.RunnerCommands.parse(argv);deadline=W.monotonic()+20)
    C.write_json(joinpath(stage,name*".json"),reply)
    @test reply["ok"]===true
    reply["ok"]===true || error("native request rejected: $name")
    return reply
end
function dump_graph(handle, stage, prefix, name)
    ledger=W._ledger(handle)
    paths=R.DeploymentConfiguration.installed_paths(prefix)
    environment=merge(Dict(ENV),Dict("LD_LIBRARY_PATH"=>paths["library"],
        "PIPEWIREAO_CONFIG_DIR"=>joinpath(ledger["runtime"],"session"),
        "PIPEWIREAO_MODULE_DIR"=>paths["modules"],"PIPEWIREAO_SPA_PLUGIN_DIR"=>paths["spa"]))
    result=C.run_checked([joinpath(prefix,"bin/pwao-dump"),"-N","-r",ledger["remote"]];
        env=environment,timeout=20,maximum_output_bytes=16*1024*1024)
    result.returncode==0 || error(result.stderr)
    path=joinpath(stage,name*".json")
    write(path,result.stdout)
    return C.read_json(path;maximum=16*1024*1024)
end
function source_snapshot(graph)
    node=only(filter(object -> get(get(get(object,"info",Dict()),"props",Dict()),
        "node.name",nothing)=="simulator-wfs",graph))
    fields=only(filter(node["info"]["params"]["Props"]) do record
        params=get(record,"params",Any[])
        !isempty(params) && first(params)=="pipewireao.source-snapshot.version"
    end)["params"]
    snapshot=Dict(replace(fields[i],"pipewireao.source-snapshot."=>"")=>fields[i+1]
        for i in 1:2:length(fields))
    return node,snapshot
end
function gpu_audit(handle,stage)
    ledger=W._ledger(handle)
    processes=Dict(role=>owner["pid"] for (role,owner) in ledger["owners"])
    processes["rtc"]=handle.main_pid
    audit=Dict{String,Any}()
    for (role,pid) in processes
        mappings=readlines("/proc/$pid/maps")
        gpu=filter(line -> occursin(r"(?i)(libcuda|libcudart|libcublas|libcufft|libamdhip|libhsa-runtime)",line),mappings)
        @test isempty(gpu)
        audit[role]=Dict("pid"=>pid,"gpu_mappings"=>gpu)
    end
    C.write_json(joinpath(stage,"gpu-audit.json"),audit)
end

function save_prefix(stage,records)
    names=("frames-u16-row-major.bin","demanded-f32-micrometre.bin","applied-f32-micrometre.bin")
    for (name,record) in zip(names,records)
        write(joinpath(stage,name),record.values)
    end
    C.write_json(joinpath(stage,"prefix-identities.json"),Dict(name=>Dict(
        "seen"=>record.seen,"identities"=>_classic_identity_record.(record.identities),
        "pts_ns"=>[header===nothing ? nothing : header.pts for header in record.headers])
        for (name,record) in zip(names,records)))
    return Dict(name=>C.sha256_file(joinpath(stage,name)) for name in names)
end

function capture_session(application,stage,prefix,count)
    handle=W.start!(application,stage;prefix,deadline=W.monotonic()+1030)
    records=Any[]
    observation=nothing
    failures=Exception[]
    try
        @test request(handle,stage,"ready",["status"])["state"]=="Ready"
        node,initial=source_snapshot(dump_graph(handle,stage,prefix,"graph-ready"))
        @test node["info"]["props"]["aos.simulation.backend"]=="cpu"
        @test node["info"]["props"]["aos.simulation.calibration-identity"]==
            "sha256:"*C.sha256_file(joinpath(application,"calibration-result.toml"))
        @test !initial["running"] && initial["sequence"]==0
        gpu_audit(handle,stage)
        factory=capture -> begin
            record=PrefixCapture(capture,count)
            push!(records,record)
            record
        end
        ledger=W._ledger(handle)
        settings=R.AOSOwner.configuration(joinpath(application,"simulation.conf"))
        observation=observe_classic(ledger["remote"];timeout=count/settings.wall_rate+120,
            selected_streams=("detector","demanded","applied"),drive_interval=0.005,
            process_capture=factory,
            on_ready=() -> begin
                println("Observers negotiated; releasing exact headless session");flush(stdout)
                @test request(handle,stage,"start",["session-start"])["state"]=="Running"
            end,
            finished=captures -> all(records[1].seen) && all(records[2].seen) &&
                Base.count(records[3].seen)>=2 && records[3].seen[end])
        observation["payload_sha256"]=save_prefix(stage,records)
        C.write_json(joinpath(stage,"observation.json"),observation)
        @test request(handle,stage,"stop",["session-stop"])["state"]=="Ready"
        _,final=source_snapshot(dump_graph(handle,stage,prefix,"graph-stopped"))
        @test !final["running"] && final["completed"] && final["sequence"]==count
        @test final["generation"]==initial["generation"]
        phase=joinpath(dirname(ledger["remote"]),"phase-timing","phase-timing-$(final["generation"]).json")
        cp(phase,joinpath(stage,"phase-timing.json"))
        gpu_audit(handle,stage)
    catch err
        push!(failures,err)
        if length(records)==3
            try save_prefix(stage,records) catch save_error; push!(failures,save_error) end
        end
    finally
        try
            W.shutdown!(handle;deadline=W.monotonic()+320)
        catch err
            push!(failures,err)
            C.write_json(joinpath(stage,"quit-failure.json"),Dict("error"=>sprint(showerror,err)))
            # Observe an existing policy shutdown; stop only an exact still-active unit.
            try FaultCleanup.cleanup!(handle,stage;failed=true)
            catch cleanup_error; push!(failures,cleanup_error) end
        end
    end
    isempty(failures) || throw(CompositeException(failures))
    final=W.final_record(stage)
    @test final["cleanup_complete"]===true && isempty(get(final,"cleanup_errors",Any[]))
    @test !R.SystemdOwners.old_process_exists(handle.main_pid,handle.start_ticks)
    @test R.SystemdOwners.cgroup_empty(handle.cgroup)
    for owner in values(final["owners"])
        @test !R.SystemdOwners.old_process_exists(owner["pid"],UInt64(owner["start-ticks"]))
        @test R.SystemdOwners.cgroup_empty(owner["cgroup"])
    end
    return records,observation,final
end

function rms(opd,mask)
    values=Float64.(opd[mask])
    values .-= mean(values)
    return sqrt(mean(abs2,values))
end
function plant_replay(application,frames,adopted)
    options=merge(R.AOSOwner.configuration(joinpath(application,"simulation.conf")),
        (;remote="/tmp/unused-classic-replay",control_node="simulator-wfs",plant_module=REVOLTClassicSim))
    science=R.AOSOwner.prepare_science(options)
    uncorrected=R.AOSOwner.prepare_science(options)
    config=only(filter(node -> node.config isa AlgorithmGraphs.ShackHartmannRateNodeConfig,
        science.definition.nodes)).config
    telescope=AdaptiveOpticsSim.Optics.prepare_telescope(config.telescope,science.target)
    mask=AdaptiveOpticsSim.Optics.pupil_mask(telescope)
    corrected_rms=zeros(Float64,size(frames,2))
    uncorrected_rms=similar(corrected_rms)
    expected=zeros(UInt16,352*352)
    for index in axes(frames,2)
        stamp=step_hil_frame_at!(science.boundary,science.driver)
        @test stamp.sequence==index
        frame=hil_frame_buffer(science.boundary)
        for row in axes(frame,1),column in axes(frame,2)
            expected[(row-1)*size(frame,2)+column]=round(UInt16,frame[row,column])
        end
        @test expected==@view(frames[:,index])
        corrected_rms[index]=rms(graph_output(science.graph,:pupil_opd),mask)
        copyto!(hil_command_buffer(science.boundary),@view(adopted[:,index]))
        adopt_hil_command!(science.boundary,stamp.sequence)
        reference=step_hil_frame_at!(uncorrected.boundary,uncorrected.driver)
        @test reference.sequence==index
        uncorrected_rms[index]=rms(graph_output(uncorrected.graph,:pupil_opd),mask)
        adopt_hil_command!(uncorrected.boundary,reference.sequence)
    end
    @test mean(corrected_rms[129:end])<mean(uncorrected_rms[129:end])
    return (;corrected_rms,uncorrected_rms)
end

function replay_options(application)
    options=R.AOSOwner.configuration(joinpath(application,"simulation.conf"))
    @assert options.backend===:cpu && options.plant.settings.pupil_resolution==480
    count=Int(something(options.total_exchanges))
    @assert count==256 && 1<=options.wall_rate<=10 && options.period_ns==2_000_000
    deployment=C.read_json(joinpath(application,"deployment.conf"))
    owner=only(filter(item -> item["role"]==deployment["source-owner"],deployment["owners"]))
    arguments=owner["argv"]
    phase=findfirst(==("--phase-timing-directory"),arguments)
    phase!==nothing && phase<length(arguments) && arguments[phase+1]=="@RUNTIME@/phase-timing" ||
        throw(ArgumentError("managed replay requires source --phase-timing-directory @RUNTIME@/phase-timing"))
    warmup=findfirst(==("--phase-timing-warmup"),arguments)
    warmup!==nothing && warmup<length(arguments) && 0<=parse(Int,arguments[warmup+1])<count ||
        throw(ArgumentError("managed replay requires phase-timing warmup shorter than its finite frame count"))
    BLAS.set_num_threads(1)
    AdaptiveOpticsSim.Backends.set_fft_provider_threads!(1)
    return options,count
end

function verify_science(application,records,observation,ledger,source)
        options,count=replay_options(application)
        detector,demanded,applied=records
        @test all(detector.seen) && all(demanded.seen)
        @test Base.count(applied.seen)>=2 && applied.seen[end]
        for index in 1:count
            @test detector.identities[index]==demanded.identities[index]
            @test detector.identities[index]!==nothing
            @test detector.identities[index].sequence==index
            @test detector.headers[index].pts==demanded.headers[index].pts
            if applied.seen[index]
                # The released applied-command product has Header, not Acquisition metadata.
                @test applied.identities[index]===nothing
                @test applied.headers[index].pts==detector.headers[index].pts
            end
        end
        adopted=demanded.values .* SCALE
        @test applied.values[:,applied.seen]==adopted[:,applied.seen] ./ SCALE
        @test all(isfinite,adopted) && any(!iszero,adopted)
        @test ClassicReplay.replay(application,detector.values,adopted)==adopted
        metrics=plant_replay(application,detector.values,adopted)
        @test !any(id -> id.name in ("CUDA","AMDGPU","GPUCompiler"),keys(Base.loaded_modules))
        @test isempty(filter(path -> occursin(r"(?i)(libcuda|libcudart|libamdhip64|libhsa-runtime64|libcublas|libcufft)",path),Libdl.dllist()))
        @test all(C.sha256_file(joinpath(application,path))==hash for (path,hash) in source)
        @test all(C.sha256_file(joinpath(@__DIR__,path))==hash for (path,hash) in SOURCE_HASHES)
        return Dict("complete"=>true,
            "frames"=>count,"backend"=>"cpu","pupil_resolution"=>480,
            "model_rate_hz"=>options.rate,"requested_wall_rate_hz"=>options.wall_rate,
            "exact_controller_replay"=>true,"exact_plant_detector_replay"=>true,
            "applied_observation_count"=>Base.count(applied.seen),
            "collection"=>"Unchanged capacity-one display queues; assert complete detector/command prefix at slow functional pacing; applied queue may drop samples",
            "corrected_rms_m"=>metrics.corrected_rms,"uncorrected_rms_m"=>metrics.uncorrected_rms,
            "discarded_initial_frames"=>128,
            "corrected_mean_rms_nm"=>mean(metrics.corrected_rms[129:end])*1e9,
            "uncorrected_mean_rms_nm"=>mean(metrics.uncorrected_rms[129:end])*1e9,
            "calibration_identity"=>options.calibration_identity,
            "application"=>abspath(application),"manifest_sha256"=>C.sha256_file(joinpath(application,"Manifest.toml")),
            "payload_sha256"=>observation["payload_sha256"],
            "application_sha256"=>source,"harness_sha256"=>SOURCE_HASHES,
            "session_uuid"=>ledger["session_uuid"],"cleanup_complete"=>ledger["cleanup_complete"],
            "scope"=>"Finite seeded managed CPU loop and matched direct replay; no cadence, latency, long-run stability, hardware or GPU qualification")
end

function main(application,stage,prefix)
    _,count=replay_options(application)
    source=Dict(path=>C.sha256_file(joinpath(application,path)) for path in
        ("deployment.conf",keys(C.read_json(joinpath(application,"deployment.conf"))["artifacts"])...))
    report=nothing
    @testset "Managed Classic CPU closed-loop replay" begin
        records,observation,ledger=capture_session(application,stage,prefix,count)
        report=verify_science(application,records,observation,ledger,source)
    end
    # Failed Test assertions throw at the testset boundary; success is published afterward.
    C.write_json(joinpath(stage,"science-result.json"),report)
end
abspath(PROGRAM_FILE)==(@__FILE__) && main(ARGS...)
end
