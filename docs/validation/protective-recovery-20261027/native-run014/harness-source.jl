using Test, PipeWireAO, PipeWireAORTC, FilterGraphAlgorithms, JuliaFilterGraph, FilterGraphPipeWire, JSON, SHA
const RTC_ROOT = "/home/dgamroth/workspaces/codex/worktrees/rtc-protective-recovery-20261027"
const JFG_ROOT = "/home/dgamroth/workspaces/codex/pipewire/JuliaFilterGraph.jl"
const SDK = "/home/dgamroth/.local/opt/pipewireao-loop-controls-20261026"
const NATIVE_BUILD = "/home/dgamroth/.cache/pipewireao/protective-recovery-20261027/native-build"
const NCC = PipeWireAORTC.NativeControlClient
const NSC = PipeWireAORTC.NativeSessionCodec
const NSP = PipeWireAORTC.NativeSessionProfile
const NSD = PipeWireAORTC.NativeSessionDiscovery
const NS = PipeWireAORTC.NativeSessionClient
const NAR = PipeWireAORTC.NativeAcquisitionLifecycleRuntime
const NAC = PipeWireAORTC.NativeAcquisitionLifecycleCodec
const NE = PipeWireAORTC.NativeControlEndpoint
const CR = PipeWireAORTC.CorrectionRecovery
const CL = PipeWireAORTC.CorrectionLoops
const Bootstrap = PipeWireAORTC.NativeOwnerBootstrapRuntime
const TP = Bootstrap.ThreadPinning
const OUT = abspath(only(ARGS))
const UUID = "91a75029-b346-44ec-9cd2-26e5d133a921"
const GRAPH_NAME = "recovery-graph"
const SOURCE_NAME = "recovery-source"
const SINK_NAME = "recovery-sink"
const CONTROL_NAME = "recovery-acquisition"
const BOOTSTRAP_NAME = "recovery-graph-bootstrap"
const SESSION_NAME = "recovery-session"
const CLOCK_DOMAIN = PipeWireAO.AcquisitionDomain(ntuple(i -> UInt8(i), 16))

function prepare_graph_text(text; algorithms)
    return mktemp() do path, io
        write(io, text); flush(io)
        JuliaFilterGraph.prepare_graph(path; algorithms)
    end
end
include(joinpath(@__DIR__, "graph_definition.jl"))

function wait_for(predicate, label; seconds=20.0, check=()->nothing)
    limit = NCC.monotonic() + seconds
    while true
        check()
        predicate() && return nothing
        NCC.monotonic() < limit || error("bounded wait expired: " * label)
        sleep(0.005)
    end
end
function stop_owned(process, label)
    process === nothing && return nothing
    if !Base.process_exited(process)
        kill(process)
        if timedwait(() -> Base.process_exited(process), 5.0; pollint=0.01) !== :ok
            kill(process, Base.SIGKILL)
            timedwait(() -> Base.process_exited(process), 5.0; pollint=0.01) === :ok || error(label * " remains alive")
        end
    end
    wait(process)
    return nothing
end

mutable struct SyntheticAcquisition
    lifecycle::NAC.ColdLifecycle
    running::Threads.Atomic{Bool}
    sequence::Threads.Atomic{UInt64}
    generation::UInt64
end
SyntheticAcquisition() = SyntheticAcquisition(NAC.Prepared, Threads.Atomic{Bool}(false),
    Threads.Atomic{UInt64}(0), UInt64(1))
function acquisition_snapshot(state)
    connected = state.lifecycle === NAC.Connected
    cursor = connected ? NAC.AcquisitionCursor(UInt64(1), state.generation, state.sequence[], UInt64(0)) : nothing
    return NAC.Snapshot(NAC.Classic, cursor, nothing, state.running[], false,
        connected ? "correcting" : "initial", true, false, connected ? UInt64(1) : nothing)
end
apply!(state, ::NAC.LifecycleCommand{:status}) = nothing
apply!(state, ::NAC.LifecycleCommand{:connect}) = (state.lifecycle = NAC.Connected; nothing)
apply!(state, ::NAC.LifecycleCommand{:pause}) = (state.running[] = false; nothing)
apply!(state, ::NAC.LifecycleCommand{:resume}) = (state.running[] = true; nothing)
function apply!(state, ::NAC.LifecycleCommand{:reset})
    state.running[] && error("reset of running synthetic acquisition refused")
    state.generation += 1; state.sequence[] = 0
    return nothing
end
apply!(state, ::NAC.LifecycleCommand{:shutdown}) = (state.running[] = false; state.lifecycle = NAC.Stopped; nothing)

function native_configuration(socket, graph, source_pid)
    port(name, direction, schema) = Dict("name"=>name, "direction"=>direction,
        "element-type"=>"F32_LE", "schema"=>schema, "layout"=>"COLUMN_MAJOR", "shape"=>[1], "rate"=>"100/1")
    input_schema = graph.input_formats[Symbol("residual-error")].schema
    output_schema = graph.output_formats.demanded.schema
    session = Dict("authority"=>"none", "profile"=>"development",
        "sources"=>[Dict("node.name"=>SOURCE_NAME, "ownership"=>"external",
            "ports"=>[port("output_1", "output", input_schema)])],
        "graphs"=>[Dict("node.name"=>GRAPH_NAME,
            "ports"=>[port("residual-error", "input", input_schema),port("demanded", "output", output_schema)])],
        "sinks"=>[Dict("node.name"=>SINK_NAME, "ownership"=>"external",
            "ports"=>[port("input_1", "input", output_schema)])],
        "links"=>[Dict("output"=>SOURCE_NAME*":output_1", "input"=>GRAPH_NAME*":residual-error", "passive"=>true),
            Dict("output"=>GRAPH_NAME*":demanded", "input"=>SINK_NAME*":input_1")],
        "execution-groups"=>[Dict("name"=>"science", "nodes"=>[GRAPH_NAME])])
    component(name, type, provides; kwargs...) = merge(Dict("name"=>name,"type"=>type,"provides"=>provides), Dict(string(k)=>v for (k,v) in kwargs))
    args = Dict("instance"=>"101", "controller.instance"=>"202", "admission.controller-instance"=>"303",
        "session.uuid"=>UUID, "startup.timeout-ms"=>60000, "session"=>session,
        "owners"=>[Dict("bootstrap-node"=>BOOTSTRAP_NAME,"bootstrap-instance"=>"505",
            "pid"=>source_pid,"role"=>"graph")],
        "node.pids"=>Dict(SOURCE_NAME=>source_pid, GRAPH_NAME=>source_pid, SINK_NAME=>source_pid),
        "source"=>Dict("control-node"=>CONTROL_NAME,"control-instance"=>"404", "pid"=>source_pid,
            "role"=>"source", "instrument"=>"classic", "control-protocol"=>"pipewireao.rtc.correction-lifecycle/1"))
    components = [
        component("libwireplumber-module-lua-scripting", "module", "support.lua"),
        component("libwireplumber-module-ao-lua", "module", "ao.lua"),
        component("libwireplumber-module-ao-control-endpoint", "module", "rtc.endpoint";
            arguments=Dict("plugin.name"=>"ao-session-control","node.name"=>SESSION_NAME,
                "profile"=>"pipewireao.rtc.session/1","instance"=>101,
                "properties"=>Dict("pipewireao.rtc.session.session-uuid"=>UUID))),
        component("libwireplumber-module-ao-control-endpoint", "module", "rtc.controller";
            arguments=Dict("plugin.name"=>"ao-session-controller","node.name"=>"pipewireao.rtc.controller.recovery-policy",
                "profile"=>"pipewireao.rtc.controller/1","instance"=>202)),
        component(joinpath(RTC_ROOT,"native/scripts/ao/session.lua"), "script/lua", "rtc.policy";
            requires=["support.lua","ao.lua","rtc.endpoint","rtc.controller"], arguments=args)]
    return Dict("context.properties"=>Dict("remote.name"=>socket,"support.dbus"=>false,"library.use-fallback"=>false),
        "context.modules"=>[Dict("name"=>"libpipewire-module-protocol-native"),Dict("name"=>"libpipewire-module-client-node")],
        "wireplumber.profiles"=>Dict("ao-rtc"=>Dict(k=>"required" for k in ["support.lua","ao.lua","rtc.endpoint","rtc.controller","rtc.policy"])),
        "wireplumber.components"=>components)
end

phase(name) = (println("PHASE ", name, " at ", NCC.monotonic()); flush(stdout); nothing)

function main()
    !ispath(OUT) || error("fresh evidence directory required")
    mkpath(OUT; mode=0o700)
    cp(@__FILE__,joinpath(OUT,"harness-source.jl"))
    cp(joinpath(@__DIR__,"graph_definition.jl"),joinpath(OUT,"graph-definition-source.jl"))
    runtime = joinpath(OUT,"runtime"); mkpath(runtime; mode=0o700)
    configuration = joinpath(OUT,"configuration"); mkpath(configuration)
    remote = "recovery-private"
    socket = joinpath(runtime,remote)
    write(joinpath(configuration,"private-core.conf"), """
    context.properties = { core.daemon = true core.name = $remote support.dbus = false library.use-fallback = false }
    context.spa-libs = { support.* = support/libspa-support }
    context.modules = [
      { name = libpipewire-module-scheduler-v1 }
      { name = libpipewire-module-protocol-native }
      { name = libpipewire-module-client-node }
      { name = libpipewire-module-link-factory args = { allow.link.passive = true } }
      { name = libpipewire-module-metadata }
      { name = libpipewire-module-access }
    ]
    """)
    write(joinpath(configuration,"client.conf"), """
    context.properties = { support.dbus = false }
    context.spa-libs = { support.* = support/libspa-support }
    context.modules = [ { name = libpipewire-module-protocol-native }
      { name = libpipewire-module-client-node } { name = libpipewire-module-metadata } ]
    """)
    env = Dict("XDG_RUNTIME_DIR"=>runtime, "PIPEWIREAO_RUNTIME_DIR"=>runtime,
        "PIPEWIREAO_CONFIG_DIR"=>configuration, "PIPEWIREAO_DEBUG"=>"0")
    receipt = Dict{String,Any}("passed"=>false,"julia"=>string(VERSION),"gpu_work"=>false,
        "live_services_changed"=>false,"runtime"=>runtime,"source_is_synthetic"=>true,
        "rtc_source"=>RTC_ROOT,"jfg_source"=>JFG_ROOT,
        "rtc_commit"=>readchomp(`git -C $RTC_ROOT rev-parse HEAD`),
        "jfg_commit"=>readchomp(`git -C $JFG_ROOT rev-parse HEAD`),
        "rtc_status"=>readchomp(`git -C $RTC_ROOT status --short`),
        "jfg_status"=>readchomp(`git -C $JFG_ROOT status --short`),"samples"=>[]) 
    receipt["file_sha256"] = Dict(path=>bytes2hex(sha256(read(path))) for path in (
        @__FILE__, joinpath(@__DIR__,"graph_definition.jl"),
        joinpath(@__DIR__,"environment/Project.toml"), joinpath(@__DIR__,"environment/Manifest.toml"),
        joinpath(RTC_ROOT,"native/scripts/ao/session.lua"), joinpath(RTC_ROOT,"native/scripts/lib/ao-correction.lua"),
        joinpath(RTC_ROOT,"src/owners/correction_recovery.jl"), joinpath(RTC_ROOT,"src/owners/correction_recovery_client.jl"),
        joinpath(NATIVE_BUILD,"pipewireao-rtc"), joinpath(NATIVE_BUILD,"modules/libwireplumber-module-ao-lua.so"),
        joinpath(NATIVE_BUILD,"modules/libwireplumber-module-ao-control-endpoint.so")))
    save() = write(joinpath(OUT,"receipt.json"),JSON.json(receipt,2))
    daemon = manager = nothing
    corelog = open(joinpath(OUT,"core.log"),"w")
    rtclog = open(joinpath(OUT,"rtc.log"),"w")
    loop = context = core = registry = node = source = sink = acquisition = admin = connection = bootstrap = nothing
    shutdown = Threads.Atomic{Bool}(false)
    source_state = SyntheticAcquisition()
    residual = Threads.Atomic{Float32}(2f0)
    sample_lock = ReentrantLock()
    producer_gate = ReentrantLock()
    samples = Tuple{UInt64,Float32}[]
    failure_lock = ReentrantLock()
    failures = Exception[]
    workers = Task[]
    owner_task = source_task = nothing
    owner_ready = Threads.Atomic{Bool}(false)
    record_failure(error) = lock(failure_lock) do; push!(failures,error); end
    function health()
        lock(failure_lock) do
            isempty(failures) || throw(first(failures))
        end
        daemon === nothing || !Base.process_exited(daemon) || error("owned private core exited")
        manager === nothing || !Base.process_exited(manager) || error("owned RTC exited")
        return nothing
    end
    deadline(seconds=10.0) = NCC.monotonic()+seconds
    try
        withenv(env...) do
            phase("start_private_core")
            daemon = run(pipeline(`$(joinpath(SDK,"bin/pipewire-ao")) -c private-core.conf`;
                stdout=corelog,stderr=corelog);wait=false)
            receipt["core_pid"]=getpid(daemon);save()
            wait_for(() -> ispath(socket),"private core socket";check=health)
            chmod(runtime,0o700)
            loop = ThreadLoop("recovery-e2e-exchange")
            with_thread_loop_lock(loop) do _
                context = Context(loop)
                core = CoreConnection(context;properties=Dict("remote.name"=>socket))
                registry = Registry(core)
            end
            start!(loop)
            phase("prepare_scientific_graph")
            graph = prepared_recovery_graph()
            bootstrap = Bootstrap.Runtime(socket,BOOTSTRAP_NAME,Int64(505))
            owner_task = TP.@spawnat 3 begin
                @assert Threads.threadid() == 3
                println("GRAPH_OWNER_THREAD ",Threads.threadid());flush(stdout)
                observer=nothing
                try
            observer = CL.Observer(["correction:closed"],Int64(505);timeout_ms=60000)
            node = FilterGraphPipeWire.PipeWireNode(graph;name=GRAPH_NAME,remote=socket,
                rate=100//1,connect=false,feedback=CALLBACK_FEEDBACK_PAIR,run_control=true,
                recovery=(controller=:correction,participants=(:temporal,:command),reference_timeout_ms=60000),
                property_observer=observer,property_info=CL.property_info(observer),property_getter=observer)
            FilterGraphPipeWire.prepare!(node)
            CL.check_ready(observer)
            CL.attach_timers!(observer,bootstrap.transport.loop,() -> PipeWireAO.notify_properties!(node.filter))
            Bootstrap.preparation_check!(bootstrap)
            Bootstrap.prepared!(bootstrap)
            owner_ready[]=true
            ticket=Bootstrap.take_connect!(bootstrap)
            Bootstrap.connecting!(bootstrap,ticket;
                ready=() -> FilterGraphPipeWire.node_id(node)!==nothing && PipeWireAO.isrunning(node) &&
                    FilterGraphPipeWire.node_state(node) in
                        (PipeWireAO.NDARRAY_FILTER_STATE_PAUSED,PipeWireAO.NDARRAY_FILTER_STATE_STREAMING),
                quit=() -> FilterGraphPipeWire.quit!(node))
            Bootstrap.check_connect!(bootstrap,ticket)
            FilterGraphPipeWire.connect!(node)
            Bootstrap.check_connect!(bootstrap,ticket)
            FilterGraphPipeWire.run!(node)
                catch error
                    Bootstrap.fault!(bootstrap,error)
                    shutdown[] || record_failure(error)
                finally
                    Bootstrap.finishing!(bootstrap)
                    observer === nothing || close(observer)
                    node === nothing || close(node)
                end
            end
            wait_for(() -> owner_ready[],"graph owner preparation";seconds=90,check=health)
            format = NdArrayFormat(NdArray.F32_LE,(1,);layout=NdArray.COLUMN_MAJOR,rate=SPA.Fraction(100,1))
            source = NdArraySource(core,SOURCE_NAME,zeros(Float32,1),format;
                schema=graph.input_formats[Symbol("residual-error")].schema)
            sink = NdArraySink(core,SINK_NAME,zeros(Float32,1),format;schema=graph.output_formats.demanded.schema)
            start!(source); start!(sink)
            phase("prepare_acquisition_endpoint")
            acquisition = NAR.Runtime(NAC.CORRECTION_PROFILE,socket,CONTROL_NAME,Int64(404))
            NAR.lifecycle!(acquisition,NAC.Prepared)
            push!(workers,@async try
                while !shutdown[]
                    if NAR.has_pending(acquisition)
                        NAR.poll!(acquisition)
                        ticket = NAR.take!(acquisition)
                        if ticket !== nothing
                            println("ACQUISITION_TICKET ", typeof(ticket.command), " at ", NCC.monotonic());flush(stdout)
                            NE.check_ticket(acquisition.endpoint,ticket)
                            apply!(source_state,ticket.command)
                            NAR.lifecycle!(acquisition,source_state.lifecycle)
                            NAR.complete!(acquisition,ticket,source_state.lifecycle,acquisition_snapshot(source_state))
                        end
                    end
                    sleep(0.001)
                end
            catch error
                record_failure(error)
            end)
            config_path=joinpath(configuration,"rtc.conf")
            PipeWireAORTC.ScienceExport.write_spa_config(config_path,native_configuration(socket,graph,getpid()))
            manager_env=Dict("WIREPLUMBER_MODULE_DIR"=>joinpath(NATIVE_BUILD,"modules")*":"*joinpath(SDK,"lib/wireplumber-0.5"),
                "WIREPLUMBER_DATA_DIR"=>joinpath(RTC_ROOT,"native")*":"*joinpath(SDK,"share/wireplumber"),
                "WIREPLUMBER_DEBUG"=>"2")
            phase("start_production_rtc")
            manager=run(pipeline(addenv(`$(joinpath(NATIVE_BUILD,"pipewireao-rtc")) -c $config_path`,manager_env);
                stdout=rtclog,stderr=rtclog);wait=false)
            receipt["rtc_pid"]=getpid(manager);save()
            phase("connect_admission_controller")
            admin=NCC.connect(NSP.Profile(),socket,SESSION_NAME,getpid(manager),Int64(101);
                deadline=deadline(30),check=health,controller_instance=Int64(303))
            warmup_polls=Ref(0)
            wait_for("RTC warmup";seconds=70,check=health) do
                reply=NCC.request!(admin,NSC.WarmupCommand();deadline=deadline(),check=health)
                warmup_polls[]+=1
                if warmup_polls[] in (1,10,100)
                    println("WARMUP_REPLY ",reply," source_state=",source_state.lifecycle,
                        " source_pending=",acquisition.endpoint.pending," source_wake=",NAR.has_pending(acquisition));flush(stdout)
                end
                reply.header.result == 0 && reply.warmed === true
            end
            phase("admit_ready")
            ready=NCC.request!(admin,NSC.AdmitCommand();deadline=deadline(),check=health)
            @test ready.lifecycle === NSC.Runner.Ready
            record=NSD.SessionRecord("protective recovery private CPU",UUID,UInt32(getpid(manager)),Int64(101),socket,SESSION_NAME)
            entry=NSD.DiscoveryEntry(record,NSD.Unverified,"")
            connection=NS.select_direct_session(entry;deadline=deadline(),check=health)
            @test connection isa NS.Connection
            # The application owner publishes actual finite synthetic residual
            # arrays. The production policy alone creates/starts the links.
            source_task = TP.@spawnat 4 try
                values=zeros(Float32,1)
                while !shutdown[]
                    if !source_state.running[]
                        sleep(0.001); continue
                    end
                    lock(producer_gate) do
                    sequence=source_state.sequence[]+UInt64(1)
                    values[1]=residual[]
                    arm_array_sink!(sink,sequence)
                    token=submit_array!(source,values,BufferHeader(UInt32(0),UInt32(0),Int64(0),Int64(0),sequence);
                        identity=AcquisitionIdentity(CLOCK_DOMAIN,source_state.generation,sequence))
                    sequence==1 && (println("FIRST_SOURCE_SUBMITTED at ",NCC.monotonic());flush(stdout))
                    allowance = sequence == 1 ? 60.0 : 5.0
                    wait_array_source!(source,token;timeout_ns=round(Int,allowance*1e9))
                    sequence==1 && (println("FIRST_SOURCE_ACK at ",NCC.monotonic());flush(stdout))
                    # Maintained C-RED2 replay uses the same asynchronous filter
                    # clock: source publication is acknowledged before graph
                    # completion. Advance native driver cycles without staging
                    # or resubmitting another scientific sample.
                    timedwait(allowance;pollint=0.001) do
                        with_thread_loop_lock(loop) do _
                            trigger_process!(source.stream)
                        end
                        sink.state.phase[] != PipeWireAO._ARRAY_PENDING
                    end === :ok || error("native graph output deadline expired")
                    wait_array_sink!(sink;timeout_ns=5_000_000_000)
                    sequence==1 && (println("FIRST_SINK_ACK at ",NCC.monotonic());flush(stdout))
                    demanded=only(array_values(sink))
                    source_state.sequence[]=sequence
                    lock(sample_lock) do
                        push!(samples,(sequence,demanded))
                    end
                    end
                    sleep(0.01)
                end
            catch error
                receipt["graph_process_count_at_source_failure"]=node.owner.process_count
                receipt["graph_state_at_source_failure"]=string(FilterGraphPipeWire.node_state(node))
                receipt["graph_error_at_source_failure"]=string(FilterGraphPipeWire.last_error(node))
                receipt["source_phase_at_failure"]=source.state.phase[]
                receipt["sink_phase_at_failure"]=sink.state.phase[]
                if !shutdown[]
                    diagnostic=PipeWireAORTC.Common.run_checked([joinpath(SDK,"bin/pwao-dump"),"-r",socket,"-N"];timeout=5)
                    write(joinpath(OUT,"native-failure-dump.json"),diagnostic.stdout)
                    write(joinpath(OUT,"native-failure-dump.stderr"),diagnostic.stderr)
                    record_failure(error)
                end
            end
            phase("start_session")
            start_reply=NS.request!(connection,NSC.RunnerCommand(:session_start);deadline=deadline(),check=health)
            @test start_reply.lifecycle === NSC.Runner.Running
            wait_for("saturated command";check=health) do
                lock(sample_lock) do
                    length(samples)>=8 && last(samples)[2]≈0.8f0
                end
            end
            saturated_sequence=source_state.sequence[]
            receipt["saturated_sequence"]=saturated_sequence
            residual[]=0f0
            phase("protective_open")
            operation=CR.protective_open!(connection,GRAPH_NAME;deadline=deadline(90),timeout_ms=60000,reason=:saturation,check=health)
            @test CR.state(operation.coordinator) === :Holding
            receipt["bootstrap_lifecycle_at_holding"]=string(bootstrap.transport.endpoint.lifecycle)
            receipt["bootstrap_owner_instance"]=bootstrap.transport.endpoint.instance
            receipt["holding_coordinator_state"]=string(CR.state(operation.coordinator))
            receipt["recovery_generation"]=operation.coordinator.recovery_generation
            phase("verified_holding")
            held_sequence=source_state.sequence[]
            lock(producer_gate) do
            @test lock(sample_lock) do; last(samples)[2]≈0.2f0; end
            @test only(recovery_node(graph,:correction).prepared.workspace.committed_output)==0f0
            @test all(iszero,recovery_node(graph,:temporal).prepared.workspace.committed_state)
            @test all(iszero,node.owner.feedback.slot)
            @test only(recovery_node(graph,:command).prepared.workspace.committed_current)≈0.2f0
            end
            props=Dict("correction:closed"=>NSC.RunnerScalar(:bool,true))
            blocked=NS.request!(connection,NSC.RunnerCommand(:properties_set,GRAPH_NAME,props);deadline=deadline(),check=health)
            @test blocked.header.result<0
            @test !recovery_node(graph,:correction).prepared.plan.closed
            @test CR.state(operation.coordinator) === :Holding
            receipt["ordinary_close_blocked"]=true
            receipt["holding_sequence"]=held_sequence
            save()
            # Fresh source frames continue while held. Explicit resume alone
            # releases inhibition and closes against the zero residual.
            wait_for(() -> source_state.sequence[]>held_sequence+2,"fresh held source";check=health)
            phase("explicit_resume")
            CR.resume!(operation;deadline=deadline(90),check=health)
            @test CR.state(operation.coordinator) === :Closed
            resume_sequence=source_state.sequence[]
            wait_for(() -> source_state.sequence[]>resume_sequence+5,"post-resume source frames";check=health)
            post=lock(sample_lock) do; filter(x -> x[1]>resume_sequence,samples); end
            @test all(x -> x[2]≈0.2f0,post)
            lock(producer_gate) do
                @test all(iszero,recovery_node(graph,:correction).prepared.workspace.committed_output)
            end
            all_samples=lock(sample_lock) do; copy(samples); end
            recovery_samples=filter(x -> saturated_sequence<x[1]<=held_sequence,all_samples)
            @test any(x -> 0.2f0<x[2]<0.8f0,recovery_samples)
            @test all(x -> abs(x[2]-all_samples[max(1,findfirst(==(x),all_samples)-1)][2])<=0.10001f0,recovery_samples)
            receipt["samples"]=[Dict("sequence"=>x[1],"demanded"=>x[2]) for x in all_samples]
            receipt["holding_sequence"]=held_sequence
            receipt["resume_sequence"]=resume_sequence
            receipt["ordinary_close_blocked"]=true
            receipt["final_coordinator_state"]=string(CR.state(operation.coordinator))
            receipt["recovery_generation"]=operation.coordinator.recovery_generation
            phase("passed")
            receipt["passed"]=true
            save()
        end
    catch error
        receipt["failure"]=sprint(showerror,error)
        if node !== nothing
            receipt["graph_process_count_at_failure"]=node.owner.process_count
            witness=FilterGraphPipeWire._recovery_observation(node.owner)
            receipt["local_recovery_observation_at_failure"]=Dict(string(k)=>v for (k,v) in pairs(witness))
        end
        if connection !== nothing
            matched=with_thread_loop_lock(connection.client.loop) do _
                connection.client.observation.completion
            end
            if matched !== nothing && matched.value.header.token == connection.client.last_token
                receipt["last_matched_native_completion"]=NS.render_direct(connection,matched.value)
                println("LAST_NATIVE_COMPLETION ",receipt["last_matched_native_completion"]);flush(stdout)
            end
        end
        receipt["backtrace"]=sprint(showerror,error,catch_backtrace())
        rethrow()
    finally
        phase("cleanup_owned_resources")
        shutdown[]=true; source_state.running[]=false
        # End this fixture's owned policy process while all native endpoints
        # remain present, before withdrawing graph/link/control incarnations.
        # Full application Quit validation is outside this recovery proof.
        stop_owned(manager,"RTC")
        receipt["cleanup_order"]=["owned RTC termination with endpoints retained",
            "graph quit/join", "producer/acquisition join", "native endpoints", "private core"]
        if owner_task !== nothing
            if !istaskdone(owner_task) && node !== nothing
                FilterGraphPipeWire.quit!(node)
            end
            timedwait(() -> istaskdone(owner_task),10;pollint=0.01) === :ok ||
                (receipt["owner_task_cleanup_timeout"]=true)
        end
        for task in (source_task,workers...)
            task === nothing && continue
            timedwait(() -> istaskdone(task),5;pollint=0.01)
        end
        for resource in (connection,admin,acquisition,bootstrap,source,sink)
            resource===nothing && continue
            try close(resource) catch error
                receipt["cleanup_failure_"*string(typeof(resource))]=sprint(showerror,error)
            end
        end
        if loop !== nothing
            with_thread_loop_lock(loop) do _
                for resource in (registry,core,context)
                    resource === nothing || close(resource)
                end
            end
            close(loop)
        end
        stop_owned(manager,"RTC");stop_owned(daemon,"private core")
        receipt["owned_rtc_exited"]=manager===nothing || Base.process_exited(manager)
        receipt["owned_core_exited"]=daemon===nothing || Base.process_exited(daemon)
        receipt["owned_pid_absent_after_cleanup"]=Dict(string(pid)=>!ispath("/proc/"*string(pid))
            for pid in (get(receipt,"rtc_pid",0),get(receipt,"core_pid",0)) if pid>0)
        receipt["samples"] = lock(sample_lock) do
            [Dict("sequence"=>x[1],"demanded"=>x[2]) for x in samples]
        end
        receipt["last_source_sequence"]=source_state.sequence[]
        save();close(rtclog);close(corelog)
    end
    return nothing
end
@testset "isolated native protective recovery" begin
    main()
end
