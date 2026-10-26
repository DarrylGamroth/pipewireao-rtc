using Test,PipeWireAORTC,PipeWireAO,AdaptiveOpticsSim,AdaptiveOpticsSimPipeWireHIL,CUDA
using AdaptiveOpticsSim.AlgorithmGraphs
using AdaptiveOpticsSim.AlgorithmGraphs: try_snapshot_graph_output!
include("/home/dgamroth/workspaces/codex/worktrees/rtc-gpi2-registered-20261025/test/native_control_private_core.jl")
const Q="/home/dgamroth/.cache/pipewireao/quit-investigation-20261025"
const D=joinpath(Q,"optical-cleanup-private")
const C=PipeWireAORTC.Common
const Owner=PipeWireAORTC.AOSOwner
const Ext=Base.get_extension(PipeWireAORTC,:PipeWireAORTCAOSExt)
const Obs=Ext.OpticalObservation
const SourceControl=PipeWireAORTC.NativeSourceControl
const RTC="/home/dgamroth/workspaces/codex/worktrees/rtc-gpi2-registered-20261025"
@assert pathof(PipeWireAORTC)==joinpath(RTC,"src/PipeWireAORTC.jl")
const receipt=Dict{String,Any}("diagnostic_only"=>true,"source"=>pathof(PipeWireAORTC),
    "aos_source"=>pathof(AdaptiveOpticsSim),"hil_source"=>pathof(AdaptiveOpticsSimPipeWireHIL),
    "source_sha256"=>C.sha256_file(joinpath(RTC,"ext/PipeWireAORTCAOSExt.jl")),
    "project"=>Base.active_project(),"load_path"=>LOAD_PATH,"depot_path"=>DEPOT_PATH,
    "configuration"=>joinpath(Q,"application-registered/simulation.conf"),
    "configuration_sha256"=>C.sha256_file(joinpath(Q,"application-registered/simulation.conf")),
    "full_session"=>false,"bootstrap_authority"=>false,"backend"=>"cuda")
save()=C.write_json(joinpath(D,"receipt-v2.json"),receipt;atomic=true)
stats(t)=Dict("elapsed_seconds"=>t.time,"compile_seconds"=>t.compile_time,
    "recompile_seconds"=>t.recompile_time,"bytes"=>t.bytes,"gc_seconds"=>t.gctime)
function prepare_transport(options,science,observation)
    mailbox=Ext.prepare_source_control(options,Ext.OwnerState(),Int64(1001))
    mirror=PipeWireAORTC.InstrumentDefinition.mirror_properties(options)
    command=Ext.command_mirror_properties(options,options.command_node,mirror)
    pipewire=prepare_pipewire_hil(science.boundary,science.configuration;
        frame_buffers=options.detector_observation ? 3 : 2,
        command_buffers=options.command_observation ? 3 : 2,
        applied_command_node_name=Ext.applied_command_names(options.command_node,options.applied_command_observation),
        applied_command_buffers=3,
        applied_command_properties=merge(Dict("node.group"=>"pipewireao-applied-observation",
            "node.sync-group"=>"sync.pipewireao-applied-observation","node.loop.name"=>"telemetry-loop"),mirror),
        image_sources=Obs.source_options(observation),
        frame_properties=merge(SourceControl.source_properties(mailbox),Ext.simulation_properties(options,science)),
        frame_params=mailbox.parameters.params,on_frame_param_changed=SourceControl.ParameterChanged(mailbox),
        frame_param_buffer=PodBuffer(4096),on_frame_param_overflow=SourceControl.ParameterOverflow(mailbox))
    with_thread_loop_lock(pipewire.loop) do _;Ext.publish_mirror_properties!(pipewire.command_stream,command);end
    with_applied_command_stream(pipewire) do streams;Ext.publish_mirror_properties!(streams,command);end
    PipeWireAORTC.Placement.pin_loop!(pipewire.loop,2)
    return pipewire
end
function core_roundtrip(remote)
    loop=ThreadLoop("cleanup-health")
    context=core=nothing
    try
        with_thread_loop_lock(loop) do _
            context=Context(loop)
            core=CoreConnection(context;properties=Dict("remote.name"=>remote))
        end
        start!(loop)
        roundtrip(core)
        return true
    finally
        with_thread_loop_lock(loop) do _
            core===nothing || close(core)
            context===nothing || close(context)
        end
        close(loop)
    end
end
function check_transport_open(pipewire)
    @test !pipewire.closed
    @test isopen(pipewire.loop) && isrunning(pipewire.loop)
    @test isopen(pipewire.core) && isopen(pipewire.context)
    @test with_frame_stream(isopen,pipewire)
end
function main()
    Obs.ThreadPinning.pinthread(2)
    save()
    try
        with_control_private_core(;temporary_prefix="op-",remote_name="c") do remote,directory,daemon
            chmod(dirname(remote),0o700)
            receipt["private_core_pid"]=getpid(daemon)
            receipt["private_core_start_stat"]=read("/proc/$(getpid(daemon))/stat",String)
            save()
            options=merge(Owner.configuration(receipt["configuration"]),(;remote,control_node="simulator-wfs",
                bootstrap_instance=Int64(1000),owner_check=()->nothing,pipewire_cpu=2,optical_diagnostics_cpu=4))
            @assert options.backend===:cuda && options.optical_observation
            println("SMOKE science_prepare_begin");flush(stdout)
            science_time=@timed Owner.prepare_science(options)
            science=science_time.value
            receipt["science_preparation"]=stats(science_time)
            println("SMOKE science_prepared seconds=",science_time.time);flush(stdout);save()
            for enabled in (true,false)
                name=enabled ? "enabled" : "disabled"
                observation=nothing;pipewire=nothing
                result=Dict{String,Any}();receipt[name]=result
                try
                    observation=Obs.prepare(enabled ? science.definition : nothing,science.graph)
                    @test enabled ? observation isa Obs.Observation : observation===nothing
                    pipewire=prepare_transport(options,science,observation)
                    Obs.warm!(observation,pipewire;check=options.owner_check,cpu=4)
                    check_transport_open(pipewire)
                    worker=enabled ? observation.task : nothing
                    before=enabled ? observation.completed[] : UInt64(0)
                    if enabled
                        @test worker!==nothing && !istaskdone(worker)
                        @test !observation.stop[] && !observation.failed[] && !observation.busy[]
                        @test before>=1
                    end
                    println("SMOKE ",name," precompile_begin");flush(stdout)
                    compilation=Base.@trace_compile @timed precompile(Obs.close!,(typeof(observation),typeof(pipewire)))
                    @test compilation.value
                    result["precompile"]=stats(compilation)
                    repeated=@timed precompile(Obs.close!,(typeof(observation),typeof(pipewire)))
                    @test repeated.value
                    result["repeated_precompile"]=stats(repeated)
                    check_transport_open(pipewire)
                    if enabled
                        @test observation.task===worker && !istaskdone(worker)
                        @test !observation.stop[] && !observation.failed[] && !observation.busy[]
                        @test Obs.submit!(observation;generation=observation.generation)
                        deadline=time_ns()+UInt64(30_000_000_000)
                        while observation.completed[]==before
                            @test !observation.failed[]
                            time_ns()<deadline || error("post-precompile optical publication timed out")
                            yield()
                        end
                        @test observation.completed[]>before
                        @test !observation.busy[]
                        result["worker_completed_before"]=before
                        result["worker_completed_after"]=observation.completed[]
                    end
                    result["precompile_preserved_resources"]=true
                    C.write_json(joinpath(D,name*"-exact-types-v2.json"),Dict("observation"=>string(typeof(observation)),"pipewire"=>string(typeof(pipewire))))
                    println("SMOKE ",name," actual_close_begin");flush(stdout);save()
                    close_time=Base.@trace_compile @timed Obs.close!(observation,pipewire)
                    result["actual_close"]=stats(close_time)
                    if enabled
                        @test observation.task===nothing && istaskdone(worker)
                        @test observation.stop[] && !observation.failed[]
                        @test all(snapshot->!try_snapshot_graph_output!(snapshot),Obs.snapshots(observation))
                        result["worker_joined_snapshots_closed"]=true
                    end
                    @test pipewire.closed && !isopen(pipewire.core) && !isopen(pipewire.loop)
                    result["transport_closed"]=true
                    @test !Base.process_exited(daemon)
                    @test core_roundtrip(remote)
                    result["private_core_roundtrip_after_close"]=true
                    println("SMOKE ",name," closed seconds=",close_time.time);flush(stdout)
                    result["passed"]=true
                    observation=nothing;pipewire=nothing
                finally
                    if observation!==nothing || pipewire!==nothing
                        try Obs.close!(observation,pipewire) catch error;result["cleanup_error"]=sprint(showerror,error);end
                    end
                    save()
                end
            end
            receipt["private_core_alive_before_fixture_cleanup"]=!Base.process_exited(daemon)
            cp(joinpath(directory,"private-core.log"),joinpath(D,"private-core-v2.log");force=true)
        end
        receipt["fixture_cleanup_completed"]=true
        receipt["passed"]=true
    catch error
        receipt["failure"]=sprint(showerror,error)
        showerror(stderr,error,catch_backtrace());println(stderr);flush(stderr)
    finally
        @assert receipt["source_sha256"]==C.sha256_file(joinpath(RTC,"ext/PipeWireAORTCAOSExt.jl"))
        save()
    end
    println("SMOKE_RESULT ",get(receipt,"passed",false));flush(stdout)
    return get(receipt,"passed",false) ? 0 : 1
end
try
    @testset "actual CUDA optical cleanup compile preparation" begin
        @test main()==0
    end
    receipt["testset_passed"]=true
    save()
catch error
    receipt["passed"]=false
    receipt["testset_passed"]=false
    receipt["testset_failure"]=sprint(showerror,error)
    save()
    rethrow()
end
