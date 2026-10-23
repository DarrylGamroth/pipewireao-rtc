# Opt-in isolated CPU sessions: optional analysis may stall or die while exact
# detector/control transport, Stop, Reset and Quit remain independently usable.
module ClassicOptionalAnalysis
using Test, LinearAlgebra, Libdl
using PipeWireAORTC, PipeWireAO, FilterGraphIsland, JuliaFilterGraph
using AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL
using AdaptiveOpticsSim.AlgorithmGraphs: reset_hil_boundary!
include("classic_wfs_summary.jl")
const W = ClassicWFSSummary
const M = W.M
const R = PipeWireAORTC.SessionRuntime
const S = PipeWireAORTC.SystemdOwners
const C = PipeWireAORTC.Common

function analysis_unit(handle)
    runtime = R._ledger(handle)["runtime"]
    receipt = C.read_json(joinpath(runtime, "analysis.json"))
    @test isempty(receipt["errors"])
    isempty(receipt["errors"]) || error("Optional startup failed: $(receipt["errors"])")
    @test !haskey(R._ledger(handle)["owners"], "analysis-wfs")
    return receipt["analysis"]["analysis-wfs"]["unit"]
end

function analysis_pid(unit)
    properties = S.properties(unit)
    return parse(Int, properties["MainPID"])
end

function signal(unit, name)
    result = C.run_checked(["systemctl", "--user", "kill", "--kill-whom=all",
        "--signal="*name, unit]; timeout=10)
    result.returncode == 0 || error(result.stderr)
end

function await_analysis(handle, stage, prefix, unit; failed=false)
    deadline = R.monotonic()+160
    while R.monotonic() < deadline
        properties = S.properties(unit)
        if failed
            properties["ActiveState"] == "failed" && return nothing
        else
            properties["ActiveState"] == "failed" &&
                error("Optional analysis exited before becoming ready")
            logs = C.run_checked(["journalctl", "--user", "-u", unit, "--no-pager", "-o", "cat"];
                timeout=5, maximum_output_bytes=1024*1024)
            if occursin("PIPEWIREAO_ANALYSIS_READY", logs.stdout) && analysis_pid(unit) > 0
                graph = M.dump_graph(handle, stage, prefix, "analysis-ready")
                nodes = filter(graph) do object
                    get(object,"type",nothing) == "PipeWire:Interface:Node" &&
                        get(get(get(object,"info",Dict()),"props",Dict()),"node.name",nothing) == "rtc-wfs-analysis"
                end
                length(nodes) == 1 && return only(nodes)["id"]
            end
        end
        sleep(0.1)
    end
    error("Optional analysis did not reach expected state")
end

function capture_control(handle, stage, prefix; on_running=()->nothing)
    mkpath(stage)
    _, initial = M.source_snapshot(M.dump_graph(handle,stage,prefix,"graph-ready"))
    @test !initial["running"] && initial["sequence"] == 0
    records = Any[]
    factory = capture -> begin
        record=M.PrefixCapture(capture,W.COUNT); push!(records,record); record
    end
    fault = Ref{Union{Nothing,Task}}(nothing)
    observation = try
        M.observe_classic(R._ledger(handle)["remote"]; timeout=140,
        stream_specs=W.STREAMS[1:5], selected_streams=string.(W.NAMES[1:5]),
        drive_interval=0.005, expected_generation=UInt64(initial["generation"]),
        process_capture=factory,
        on_ready=() -> begin
            @test M.request(handle,stage,"start",["session-start"])["state"] == "Running"
            fault[] = on_running()
        end,
        finished=_ -> length(records)==5 && all(record -> all(record.seen), records))
    finally
        fault[] === nothing || fetch(fault[])
    end
    @test M.request(handle,stage,"stop",["session-stop"])["state"] == "Ready"
    _, snapshot=M.source_snapshot(M.dump_graph(handle,stage,prefix,"graph-stopped"))
    @test snapshot["completed"] && !snapshot["running"] && snapshot["sequence"]==W.COUNT
    @test snapshot["generation"]==initial["generation"]
    C.write_json(joinpath(stage,"observation.json"),observation)
    return NamedTuple{W.NAMES[1:5]}(Tuple(records)),snapshot
end

function replay_control(application, baseline, records)
    current=W.controller_storage(application)
    original=W.controller_storage(baseline)
    allocations=Int[]
    try
        @test keys(current.outputs)==keys(original.outputs)
        for storage in (current,original)
            W.warm_controller!(storage,records)
            W.process_allocations(storage)
            JuliaFilterGraph.reset!(storage.graph);fill!(storage.feedback,0)
        end
        for index in 1:W.COUNT
            for storage in (current,original)
                M.ClassicReplay.load_frame!(storage.raw,records.detector.values,index)
                allocated=W.process_allocations(storage)
                @test allocated==0
                push!(allocations,allocated)
            end
            for name in keys(original.outputs)
                @test W.bitwise_equal(getproperty(current.outputs,name),getproperty(original.outputs,name))
            end
            for name in W.NAMES[2:5]
                @test W.bitwise_equal(W.row_major(getproperty(current.outputs,name)),
                    @view(getproperty(records,name).values[:,index]))
            end
            for storage in (current,original)
                copyto!(storage.feedback,getproperty(storage.outputs,M.ClassicReplay.FEEDBACK_OUT))
            end
        end
    finally
        FilterGraphIsland.close_execution(current.graph)
        FilterGraphIsland.close_execution(original.graph)
    end
    return allocations
end

function audit_analysis(unit, stage)
    pid=analysis_pid(unit)
    @test pid>0
    maps=readlines("/proc/$pid/maps")
    @test isempty(filter(line -> occursin(r"(?i)(libcuda|libcudart|libcublas|libcufft|libamdhip|libhsa-runtime)",line),maps))
    tasks=Dict{String,Any}()
    for tid in readdir("/proc/$pid/task")
        status=read("/proc/$pid/task/$tid/status",String)
        affinity=match(r"Cpus_allowed_list:\s*([^\n]+)",status).captures[1]
        @test strip(affinity) in ("6-7","6,7","6","7")
        policy=ccall(:sched_getscheduler,Cint,(Cint,),parse(Int,tid))
        @test policy in (0,3,5) # ordinary, batch or idle; never FIFO/RR/deadline
        tasks[tid]=Dict("affinity"=>affinity,"policy"=>policy)
    end
    C.write_json(joinpath(stage,"analysis-cpu-audit.json"),Dict("pid"=>pid,"tasks"=>tasks))
end

function main(application,stage,prefix,baseline)
    settings=PipeWireAORTC.AOSOwner.configuration(joinpath(application,"simulation.conf"))
    @assert settings.backend===:cpu && settings.total_exchanges==W.COUNT && settings.pacing_rate_hz==2
    BLAS.set_num_threads(1); AdaptiveOpticsSim.Backends.set_fft_provider_threads!(1)
    reports=Any[]
    @testset "Optional analysis cannot gate CPU control" begin
        unit=nothing
        science=nothing
        handle=R.start!(application,stage;prefix,deadline=R.monotonic()+1030)
        try
            unit=analysis_unit(handle)
            @test M.request(handle,stage,"ready",["status"])["state"]=="Ready"
            await_analysis(handle,stage,prefix,unit)
            audit_analysis(unit,stage)
            M.gpu_audit(handle,stage)
            fft_directory=joinpath(R._ledger(handle)["runtime"],"fft-oracle")
            contract=W.ClassicFFTOracle.restore!(fft_directory)
            science=Base.invokelatest(W.prepare_plant,application)
            @test W.ClassicFFTOracle.verify(science,contract)
            cp(fft_directory,joinpath(stage,"fft-oracle"))
            for (index,mode) in enumerate((:normal,:stalled,:resumed))
                directory=joinpath(stage,string(mode))
                mode===:resumed && signal(unit,"CONT")
                elapsed=@elapsed begin
                    records,snapshot = mode in (:normal,:resumed) ?
                        W.capture(handle,directory,prefix) : capture_control(handle,directory,prefix;
                            on_running=()->(@async begin sleep(3); signal(unit,"STOP") end))
                    if hasproperty(records,:summary)
                        W.check_cohort(records,snapshot["generation"])
                    end
                    allocations=replay_control(application,baseline,records)
                    @test W.replay_detector!(science,records,snapshot["generation"])
                    push!(reports,Dict("mode"=>string(mode),"generation"=>snapshot["generation"],
                        "completed_control_frames"=>W.COUNT,"exact_controller_replay"=>true,
                        "exact_detector_replay"=>true,"allocations"=>allocations))
                end
                reports[end]["capture_and_replay_seconds"]=elapsed
                @test M.request(handle,stage,"status-"*string(mode),["status"])["state"]=="Ready"
                if index<3
                    M.request(handle,stage,"reset-"*string(mode),["reset"])
                    reset_hil_boundary!(science.boundary,science.driver)
                end
            end
            # Whole-session teardown must also reap a completely stopped worker.
            signal(unit,"STOP")
        finally
            R.shutdown!(handle;deadline=R.monotonic()+320)
            W.check_cleanup(handle,stage)
            unit===nothing || @test analysis_pid(unit)==0
        end
    end
    @testset "Crashed analysis leaves required RTC usable" begin
        crash_stage=stage*"-crashed"
        unit=nothing
        handle=R.start!(application,crash_stage;prefix,deadline=R.monotonic()+1030)
        try
            unit=analysis_unit(handle)
            await_analysis(handle,crash_stage,prefix,unit)
            records,snapshot=capture_control(handle,joinpath(crash_stage,"crashed"),prefix;
                on_running=()->(@async begin sleep(3); signal(unit,"KILL") end))
            await_analysis(handle,crash_stage,prefix,unit;failed=true)
            allocations=replay_control(application,baseline,records)
            @test M.request(handle,crash_stage,"status-after-crash",["status"])["state"]=="Ready"
            push!(reports,Dict("mode"=>"crashed","generation"=>snapshot["generation"],
                "completed_control_frames"=>W.COUNT,"exact_controller_replay"=>true,
                "allocations"=>allocations,"stage"=>crash_stage))
            M.request(handle,crash_stage,"reset-after-crash",["reset"])
        finally
            R.shutdown!(handle;deadline=R.monotonic()+320)
            W.check_cleanup(handle,crash_stage)
            unit===nothing || @test analysis_pid(unit)==0
        end
    end
    @testset "Analysis preparation failure does not reject required RTC" begin
        broken=joinpath(stage,"bad-analysis-application")
        cp(application,broken)
        graph=joinpath(broken,"analysis-graph.conf")
        write(graph,replace(read(graph,String),"shack-hartmann-summary-f32"=>"unknown-analysis-algorithm"))
        deployment=joinpath(broken,"deployment.conf")
        spec=C.read_json(deployment)
        spec["artifacts"]["analysis-graph.conf"]=C.sha256_file(graph)
        C.write_json(deployment,spec)
        bad_stage=stage*"-startup-failure"
        unit=nothing
        handle=R.start!(broken,bad_stage;prefix,deadline=R.monotonic()+1030)
        try
            unit=analysis_unit(handle)
            await_analysis(handle,bad_stage,prefix,unit;failed=true)
            @test M.request(handle,bad_stage,"ready-after-preparation-failure",["status"])["state"]=="Ready"
            records,snapshot=capture_control(handle,joinpath(bad_stage,"control"),prefix)
            allocations=replay_control(application,baseline,records)
            push!(reports,Dict("mode"=>"analysis-preparation-failure",
                "generation"=>snapshot["generation"],"completed_control_frames"=>W.COUNT,
                "exact_controller_replay"=>true,"allocations"=>allocations,"stage"=>bad_stage))
        finally
            R.shutdown!(handle;deadline=R.monotonic()+320)
            W.check_cleanup(handle,bad_stage)
            unit===nothing || @test analysis_pid(unit)==0
        end
    end
    C.write_json(joinpath(stage,"optional-analysis-result.json"),Dict("complete"=>true,
        "backend"=>"cpu","gpu_used"=>false,"phases"=>reports,
        "analysis_schema"=>W.SUMMARY.schema,"cleanup_complete"=>true,
        "test_sha256"=>C.sha256_file(@__FILE__),
        "manifest_sha256"=>C.sha256_file(joinpath(application,"Manifest.toml")),
        "scope"=>"Five finite 32-frame CPU generations in three sessions, analysis SIGSTOP/SIGCONT/SIGKILL and preparation failure, exact controller replay, exact detector replay in three normal/stalled/resumed generations, Reset/Stop/Quit; no cadence or hardware qualification"))
end
abspath(PROGRAM_FILE)==(@__FILE__) && main(ARGS...)
end
