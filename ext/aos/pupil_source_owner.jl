# An ordinary non-HIL AOS graph owns its physical command and model clock.
# Controllers contribute held absolute vectors; their cadence never drives it.
module PupilSourceOwner
using ..PipeWireAORTCAOSExt: Owner, Bootstrap, SourceControl, Backends, target, OwnerState, PupilOutput
using AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL, PipeWireAO
using AdaptiveOpticsSim.AlgorithmGraphs
using AdaptiveOpticsSim.AlgorithmGraphs: poll_graph_output_snapshot!, snapshot_values,
    release_graph_output_snapshot!, reset_graph_output_snapshot!
import PipeWireAORTC
const IC=PipeWireAORTC.InstrumentConfiguration
const Offsets=PipeWireAORTC.PhysicalOffsets
const Extension=parentmodule(@__MODULE__)

function Owner.prepare_pupil_source_science(options;check=()->nothing)
    check()
    device=target(options)
    execution=options.backend===:cpu ? StreamGraphExecution() : CapturedGraphExecution()
    system=IC.prepare_system(options.plant.definition;settings=options.plant.settings,
        simulation_graph=options.plant.graph,target=device,execution)
    system.boundary===nothing || throw(ArgumentError("pupil source cannot own an HIL camera boundary"))
    command=graph_input(system.graph,options.command_input)
    eltype(command)===Float32 && size(command)==(options.command_count,) ||
        throw(DimensionMismatch("pupil source command differs from physical Float32 vector"))
    all(iszero,Array(command)) || throw(ArgumentError("pupil source physical command must start at zero"))
    driver=FixedStepModelTimeDriver(PeriodicSchedule(;period_ns=options.period_ns))
    science=merge(system,(;driver,command))
    publisher=PupilOutput.prepare(options,science)
    try
        warmup!(science,publisher;check)
    catch
        PupilOutput.close!(publisher)
        rethrow()
    end
    return merge(science,(;publisher))
end

"Warm the actual graph and packet packing, then restore the first model phase."
function warmup!(science,publisher;check=()->nothing)
    try
        check()
        step_graph_at!(science.graph,science.driver)
        check()
        PupilOutput.sample!(publisher;generation=UInt64(1),model_ns=Int64(0)) ||
            error("pupil source warmup snapshot unavailable")
        deadline=time_ns()+UInt64(30_000_000_000)
        while !poll_graph_output_snapshot!(publisher.snapshot)
            check()
            time_ns()<deadline || error("pupil source warmup snapshot timed out")
            yield()
        end
        try
            PupilOutput.pack!(publisher.packet,snapshot_values(publisher.snapshot),publisher.amplitude)
        finally
            release_graph_output_snapshot!(publisher.snapshot)
        end
    finally
        reset_graph_output_snapshot!(publisher.snapshot)
        reset_science!(science)
    end
    return nothing
end

function reset_science!(science)
    fill!(science.command,0)
    reset_graph!(science.graph)
    reset_model_time!(science.driver)
    return nothing
end

function step!(science,publisher,receiver,command;generation::UInt64)
    publisher.failed[] && error("required scientific pupil output failed")
    copyto!(science.command,command)
    timestamp=step_graph_at!(science.graph,science.driver)
    sequence=model_time_sequence(science.driver)
    pts=model_nanoseconds(timestamp)
    Offsets.observe_clock!(receiver,AcquisitionIdentity(publisher.domain,generation,sequence),pts,publisher.period_ns) ||
        error("pupil source clock regressed")
    # A busy snapshot drops this publication, never the model step. The next
    # snapshot carries its actual graph sequence and model timestamp.
    PupilOutput.sample!(publisher;generation,model_ns=pts)
    return sequence
end

function applied_command_option(options)
    options.applied_command_observation || return nothing
    properties=merge(PipeWireAORTC.InstrumentDefinition.mirror_properties(options,Symbol(options.mirror)),
        Dict("node.loop.name"=>"telemetry-loop","node.group"=>"pipewireao-applied-observation",
            "node.sync-group"=>"sync.pipewireao-applied-observation",
            "aos.simulation.command-order"=>options.command_order,
            "aos.simulation.calibration-identity"=>options.calibration_identity))
    return PipeWireArrayStreamOptions(;node_name="simulator-"*options.mirror*"-applied",media_name="dm-applied",
        buffers=3,schema=PipeWireAORTC.Schemas.identifier("applied_dm_command_opd_um"),
        format=NdArrayFormat(NdArray.F32_LE,(options.command_count,);layout=NdArray.ROW_MAJOR,
            rate=SPA.Fraction(UInt32(options.rate),UInt32(1))),properties)
end

function observe_command!(inputs,values,command,publisher,state)
    index=inputs.applied_command
    index==0 && return nothing
    # The completed model step adopted exactly this source-owned command.
    # Convert metres to the established applied-command micrometre schema.
    @. values=command/1f-6
    identity=AcquisitionIdentity(publisher.domain,UInt64(state.generation),state.sequence)
    pts=Base.checked_sub(inputs.prepared.receiver.clock_end_ns,Int64(publisher.period_ns))
    if stage_pipewire_array!(inputs.transport,index,values;identity,pts,duration=publisher.period_ns)
        with_array_stream(inputs.transport,index) do stream
            stream_state(stream)==PipeWireAO.LibPipeWire.PW_STREAM_STATE_STREAMING && is_driving(stream) && trigger_process!(stream)
        end
    end
    return nothing
end

function report!(options,mailbox,state)
    Owner.write_report(options,state,state.generation,mailbox.instance)
    SourceControl.report_ready!(mailbox,state.generation,state.sequence)
    return nothing
end

function consume_control!(options,mailbox,filter,state,reset_owner!)
    mailbox.ready[] || return nothing
    loop=options.bootstrap_runtime.transport.loop
    kind,token,running=with_thread_loop_lock(loop) do _
        SourceControl.pending(mailbox)
    end
    if kind!=SourceControl.INITIAL
        result=SourceControl.apply!(state,kind,token,running,time_ns(),max(options.pacing_period_ns,UInt64(1)),reset_owner!)
        if result==0
            # Pause commits this source cursor. Its already committed snapshot
            # may finish below that watermark; retain it across Pause/Run.
            kind==SourceControl.RESET && report!(options,mailbox,state)
        end
        with_thread_loop_lock(loop) do _
            SourceControl.publish!(mailbox,filter,kind,token,result,state,state.generation)
        end
    end
    with_thread_loop_lock(loop) do _
        SourceControl.publish_rejection!(mailbox,filter,state,state.generation)
    end
    return nothing
end

function run!(options,science,prepared,mailbox,state)
    runtime=options.bootstrap_runtime
    transport=runtime.transport
    publisher=science.publisher
    Bootstrap.prepared!(runtime)
    ticket=Bootstrap.take_connect!(runtime)
    Bootstrap.check_connect!(runtime,ticket)
    applied_command=applied_command_option(options)
    applied_values=applied_command===nothing ? Float32[] : zeros(Float32,options.command_count)
    Offsets.with_receiver(prepared;remote=options.remote,applied_command) do inputs
        cpu=get(options,:pipewire_cpu,nothing)
        cpu===nothing || PipeWireAORTC.Placement.pin_loop!(inputs.transport.loop,cpu;check=options.owner_check)
        filter=nothing
        try
            with_thread_loop_lock(transport.loop) do _
                properties=merge(SourceControl.source_properties(mailbox),Extension.simulation_properties(options,science),
                    Dict("node.name"=>options.control_node,"media.class"=>"Control","aos.simulation.mode"=>"pupil-source",
                        "aos.simulation.prescription-identity"=>options.prescription_identity,
                        "aos.simulation.command-order"=>options.command_order))
                filter=Filter(transport.core,options.control_node;properties,
                    on_param_changed=SourceControl.ParameterChanged(mailbox))
                connect!(filter;flags=FILTER_ASYNC|FILTER_INACTIVE,params=mailbox.parameters.params)
            end
            PupilOutput.start!(publisher;remote=options.remote,cpu=get(options,:pupil_output_cpu,nothing),
                check=()->Bootstrap.check_connect!(runtime,ticket))
            while true
                Bootstrap.check_connect!(runtime,ticket)
                registered=with_thread_loop_lock(transport.loop) do _
                    node_id(filter) ∉ (UInt32(0),typemax(UInt32))
                end
                registered &= all(eachindex(inputs.transport.streams)) do index
                    with_array_stream(inputs.transport,index) do stream
                        node_id(stream) ∉ (UInt32(0),typemax(UInt32)) && stream_state(stream) in
                            (PipeWireAO.LibPipeWire.PW_STREAM_STATE_PAUSED,PipeWireAO.LibPipeWire.PW_STREAM_STATE_STREAMING)
                    end
                end
                registered && break
                sleep(0.001)
            end
            Bootstrap.connected!(runtime,ticket)
            Bootstrap.await_connected!(runtime,ticket)
            reset_owner! = ()->begin
                PupilOutput.drain!(publisher;check=options.owner_check)
                Offsets.reset_inputs!(inputs)
                reset_science!(science)
                state.generation=Base.checked_add(state.generation,Int64(1))
                inputs.applied_command==0 || reset_pipewire_array!(inputs.transport,inputs.applied_command;
                    identity=AcquisitionIdentity(publisher.domain,UInt64(state.generation),UInt64(0)))
                fill!(applied_values,0)
                state.sequence=0
                state.completed=false
                state.deadline_ns=0
                PupilOutput.reset!(publisher,UInt64(state.generation);check=options.owner_check)
            end
            while !Bootstrap.cancelled(runtime)
                consume_control!(options,mailbox,filter,state,reset_owner!)
                Bootstrap.cancelled(runtime) && break
                if !state.running || time_ns()<state.deadline_ns
                    yield()
                    GC.safepoint()
                    continue
                end
                command=Offsets.poll!(inputs)
                state.sequence=step!(science,publisher,prepared.inputs.receiver,command;generation=UInt64(state.generation))
                observe_command!(inputs,applied_values,command,publisher,state)
                state.deadline_ns=options.pacing_period_ns==0 ? UInt64(0) :
                    Extension.next_deadline(state.deadline_ns,options.pacing_period_ns,time_ns())
            end
        finally
            Bootstrap.finishing!(runtime)
            PupilOutput.drain!(publisher;check=()->nothing)
            with_thread_loop_lock(transport.loop) do _
                filter===nothing || close(filter)
            end
        end
    end
    return nothing
end

function Owner.run_pupil_source_owner(options)
    options=merge(options,(;configuration_sha256=PipeWireAORTC.Common.sha256_file(options.config_path)))
    state=OwnerState()
    mailbox=SourceControl.Mailbox(Int64(rand(UInt64)%UInt64(typemax(Int64)))+Int64(1))
    failures=Exception[]
    science=nothing
    try
        prepared=Offsets.prepare(options.physical_offsets;options.command_count,options.command_order,options.calibration_identity)
        names=[row["node_name"] for row in values(prepared.inputs.declaration["branches"])]
        reserved=(options.control_node,options.bootstrap_node,PupilOutput.NODE_NAME,
            (options.applied_command_observation ? ("simulator-"*options.mirror*"-applied",) : ())...)
        all(name->name ∉ reserved,names) ||
            throw(ArgumentError("pupil source native node names collide"))
        science=Owner.prepare_pupil_source_science(options;check=options.owner_check)
        options=merge(options,(;pupil_output_status=()->PupilOutput.status(science.publisher)))
        report!(options,mailbox,state)
        run!(options,science,prepared,mailbox,state)
    catch error
        if !(error isa InterruptException && Bootstrap.clean_cancel(options.bootstrap_runtime))
            push!(failures,error)
            Bootstrap.fault!(options.bootstrap_runtime,error)
        end
    finally
        Bootstrap.finishing!(options.bootstrap_runtime)
        if science!==nothing
            fill!(science.command,0)
            PupilOutput.close!(science.publisher)
        end
        state.running=false
        try Owner.write_report(options,state,state.generation,mailbox.instance;failures) catch error; push!(failures,error) end
    end
    isempty(failures) || throw(length(failures)==1 ? only(failures) : CompositeException(failures))
    return nothing
end
end
