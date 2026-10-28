# Opt-in CPU/native selector: run with --threads=4 and set
# PIPEWIREAORTC_INTERNAL_SOURCE_APPLICATION and PIPEWIREAORTC_INTERNAL_SOURCE_INSTRUMENT.
# Uses only a private native core; no capture store or raw-frame recording.
module CalibrationConsumerPrivateCoreTests

using Test, SHA
using PipeWireAO, PipeWireAORTC, FilterGraphIsland, FilterGraphPipeWire, JuliaFilterGraph
using AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL, AdaptiveOpticsCalibration
include("native_control_private_core.jl")

const Calibration = PipeWireAORTC.InstrumentCalibration
const Endpoint = PipeWireAORTC.NativeCalibrationEndpoint
const Actions = PipeWireAORTC.NativeCalibrationActionCodec
const Client = PipeWireAORTC.NativeCalibrationActionClient
const Native = PipeWireAORTC.NativeControlClient
const Wire = AdaptiveOpticsSimPipeWireHIL

hashes(directory) = Dict(relpath(joinpath(root,file),directory) =>
    bytes2hex(sha256(read(joinpath(root,file))))
    for (root,_,files) in walkdir(directory) for file in files)
progress(message) = (println("calibration consumer: ",message); flush(stdout))

# An explicit native demand may run a transport cycle, but must not step AOS.
function test_request_process(owner)
    condition, guard = Base.AsyncCondition(), ReentrantLock()
    requests, cycles = Threads.Atomic{UInt64}(0), Threads.Atomic{UInt64}(0)
    listener = node = nothing
    snapshot() = with_thread_loop_lock(owner.hil.loop) do _
        status = Wire.pipewire_calibration_status(owner.hil)
        (; cursor=owner.cursor, pending=status.pending_exposure,
            frame=AdaptiveOpticsSim.AlgorithmGraphs.hil_boundary_status(owner.hil.boundary).frame_sequence,
            published=owner.hil.state.transport.frame_published[], ready=owner.hil.state.transport.frame_ready[],
            publication_cycle=status.frame_publication_cycle_sequence, phase=owner.capture.phase,
            last=owner.capture.last, receipts=map(slot -> slot.receipt,owner.capture.slots))
    end
    try
        target = with_thread_loop_lock(owner.hil.loop) do _
            target = only(find_globals(owner.registry;interface="PipeWire:Interface:Node",
                properties=("node.name"=>owner.hil.configuration.frame_node_name,)))
            @test target.id == node_id(owner.hil.frame_stream)
            @test stream_state(owner.hil.frame_stream) == PipeWireAO.LibPipeWire.PW_STREAM_STATE_STREAMING
            @test is_driving(owner.hil.frame_stream)
            node = bind(owner.registry,target,Node)
            listener = add_listener!(owner.hil.frame_stream;
                on_command=(stream,pod) -> begin
                    if pod_value(SPA.Command,pod).object.id == SPA.NODE_COMMAND_REQUEST_PROCESS
                        Threads.atomic_add!(requests,UInt64(1))
                        Endpoint.wake!(condition,guard) # Only the test task waits here.
                    end
                    nothing
                end,
                on_trigger_done=stream -> begin
                    # Earlier cycles cannot satisfy the request witness.
                    if requests[] > 0
                        Threads.atomic_add!(cycles,UInt64(1))
                        Endpoint.wake!(condition,guard)
                    end
                    nothing
                end)
            target
        end
        before = snapshot()
        @test before.pending === nothing
        @test before.frame == before.cursor.sequence == before.published == before.ready == 0
        with_thread_loop_lock(owner.hil.loop) do _
            @test requests[] == cycles[] == 0
            @test find_global(owner.registry,target.id).properties["object.serial"] == target.properties["object.serial"]
            send_command!(node,node_command(SPA.NODE_COMMAND_REQUEST_PROCESS))
        end
        serviced = try
            Endpoint.await(condition,guard,Native.monotonic()+10) do
                requests[] > 0 && cycles[] > 0
            end
            true
        catch error
            error isa Native.UnknownOutcome || rethrow()
            false
        end
        progress("explicit RequestProcess requests=$(requests[]), later cycles=$(cycles[]), serviced=$serviced")
        @test requests[] >= 1
        @test serviced
        @test snapshot() == before
    finally
        with_thread_loop_lock(owner.hil.loop) do _
            node === nothing || close(node)
            listener === nothing || close(listener)
        end
        lock(guard) do
            close(condition)
        end
    end
    return nothing
end

@testset "correlated Collect consumer, frozen response and latched failure" begin
    Threads.nthreads(:default) >= 4 || error("run this CPU selector with --threads=4")
    application = ENV["PIPEWIREAORTC_INTERNAL_SOURCE_APPLICATION"]
    source = ENV["PIPEWIREAORTC_INTERNAL_SOURCE_INSTRUMENT"]
    before, source_before = hashes(application), hashes(source)
    simulation = PipeWireAORTC.DeploymentConfiguration.decode(joinpath(application,"simulation.conf"),
        get(ENV,"PIPEWIREAO_PREFIX","/opt/pipewireao"))
    @test simulation["backend"] == "cpu"
    @test simulation["frame_encoding"] == "uint16"
    model_period_ns = round(UInt64,1e9 / simulation["rate"])
    recipe = Calibration.read_recipe(application)
    reference = zeros(Float32,simulation["command_count"])
    measurements = UInt32(recipe["estimator"]["measurement_count"])
    callback_count = Ref(0)
    sample_count = Ref(0)
    expected_mean = zeros(Float32,Int(measurements))
    expected_valid = Ref(true)
    last_raw_sum = Ref(UInt64(0))
    # Fixed-size provenance only. Borrowed arrays never escape the callback.
    observed = fill!(Vector{Union{Nothing,Actions.Exposure}}(undef,3),nothing)
    owner_ref = Ref{Any}()
    function consume(sample, exposure)
        owner = owner_ref[]
        callback_count[] += 1
        @test callback_count[] <= length(observed)
        observed[callback_count[]] = exposure
        @test exposure.domain == owner.cursor.domain == UInt64(1)
        @test exposure.generation == owner.cursor.generation
        @test exposure.sequence == owner.cursor.sequence
        @test exposure.start_model_ns + exposure.duration_ns == owner.cursor.model_ns
        @test exposure.duration_ns == simulation["exposure_ns"]
        @test Wire.pipewire_calibration_status(owner.hil).pending_exposure === nothing
        @test Wire.pipewire_probe_values(owner.hil) == reference
        @test eltype(sample.arrays.raw) === UInt16
        @test size(sample.arrays.raw) == (352,352)
        @test maximum(sample.arrays.raw) <= 0x0fff
        for receipt in values(sample.metadata)
            @test receipt.identity.domain == owner.acquisition_domain
            @test receipt.identity.generation == exposure.generation
            @test receipt.identity.sequence == exposure.sequence
            @test receipt.model_start_ns == exposure.start_model_ns
            @test receipt.duration_ns == exposure.duration_ns
            @test receipt.header == sample.metadata.raw.header
        end
        callback_count[] == 3 && error("deliberate bounded consumer failure")
        sample_count[] += 1
        expected_mean .+= vec(permutedims(sample.arrays.slopes)) ./ Float32(2)
        intrinsic = all(i -> !owner.active[i] || sample.arrays.validity[i],eachindex(owner.active))
        expected_valid[] &= intrinsic
        last_raw_sum[] = sum(UInt64,sample.arrays.raw)
        # Fault injection: the response must already own its slopes/validity.
        # These two mutations would invert the batch's aggregate validity if
        # the owner read borrowed validity after invoking the consumer.
        fill!(sample.arrays.slopes,42.0f0)
        fill!(sample.arrays.validity,callback_count[] == 1 ? true : !expected_valid[])
        return nothing
    end
    try
        with_control_private_core(;temporary_prefix="calibration-consumer-") do remote,directory,daemon
            chmod(dirname(remote),0o700)
            frontend = command = server = client = serving = nothing
            try
                frontend = Calibration.calibration_graph(application;
                    inputs=(raw="pixel-calibration:raw",),outputs=(:slopes,:flux,:validity))
                command = Calibration.calibration_graph(application;
                    inputs=(requested="pdm-command:requested",),outputs=(:demanded,Symbol("constraint-feedback")))
                name, instance = "test.calibration.consumer.$(getpid())", Int64(109)
                progress("preparing CPU internal-source owner")
                server = Calibration.prepare_initial_calibration(application,remote,frontend,command;
                    reference,name,instance,deadline=Native.monotonic()+300,
                    simulation_graph="internal-source",consume)
                frontend = command = nothing
                owner = owner_ref[] = server.effects
                @test owner.capture_store === nothing
                @test owner.consume === consume
                @test !owner.consumer_failed
                @test any(owner.active)
                capture_module = parentmodule(typeof(owner.capture))
                serving = @async try Endpoint.serve!(server;deadline=Native.monotonic()+300) catch error; error end
                client = Client.connect(Client.Binding(remote,name,getpid(),instance),UInt64(1),
                    Int64(120_000_000_000);command_count=length(reference))
                complete(action) = Client.complete!(client,action;deadline=Native.monotonic()+120,record=false)
                @testset "idle native RequestProcess preserves scientific state" begin
                    test_request_process(owner)
                end
                @test complete(Actions.Hold()) isa Actions.Held
                adopted = complete(Actions.Adopt(UInt32(0),reference))
                @test adopted isa Actions.Adopted
                @test callback_count[] == sample_count[] == 0
                settled = complete(Actions.Settle(UInt32(0),adopted.cursor,Actions.DiscardExposures(UInt32(2))))
                @test settled isa Actions.Settled
                @test settled.cursor.sequence == adopted.cursor.sequence + 2
                @test callback_count[] == sample_count[] == 0
                progress("discarded settling exposures; collecting two samples")
                response = complete(Actions.Collect(UInt32(0),settled.cursor,measurements,UInt32(2)))
                @test response isa Actions.Responses
                @test length(response.exposures) == 2
                @test callback_count[] == sample_count[] == 2
                @test !owner.consumer_failed
                @test observed[1] == response.exposures[1]
                @test observed[2] == response.exposures[2]
                @test response.exposures[1].sequence == settled.cursor.sequence + 1
                @test response.exposures[2].sequence == settled.cursor.sequence + 2
                @test response.values == expected_mean
                @test response.valid == expected_valid[]
                @test any(!=(42.0f0),expected_mean)
                sampled = capture_module.snapshot(owner.capture)
                @test all(==(42.0f0),sampled.arrays.slopes)
                @test all(==(!expected_valid[]),sampled.arrays.validity)
                @test sum(UInt64,sampled.arrays.raw) == last_raw_sum[]
                @test eltype(sampled.arrays.raw) === UInt16
                adopted = complete(Actions.Adopt(UInt32(1),reference))
                @test adopted isa Actions.Adopted
                settled = complete(Actions.Settle(UInt32(1),adopted.cursor,Actions.Immediate()))
                @test settled isa Actions.Settled
                progress("injecting failure during a three-exposure Collect")
                failed_batch = complete(Actions.Collect(UInt32(1),settled.cursor,measurements,UInt32(3)))
                @test failed_batch isa Actions.Responses
                @test !failed_batch.valid
                @test owner.consumer_failed
                @test length(failed_batch.exposures) == 3
                @test callback_count[] == 3 && sample_count[] == 2
                @test observed[3] == first(failed_batch.exposures)
                for (index,exposure) in enumerate(failed_batch.exposures)
                    @test exposure.sequence == settled.cursor.sequence + index
                    @test exposure.generation == settled.cursor.generation
                    @test exposure.domain == settled.cursor.domain
                    @test exposure.duration_ns == simulation["exposure_ns"]
                    if index == 1
                        @test exposure.start_model_ns >= settled.cursor.model_ns
                    else
                        previous = failed_batch.exposures[index-1]
                        @test exposure.start_model_ns == previous.start_model_ns + model_period_ns
                        @test exposure.start_model_ns >= previous.start_model_ns + previous.duration_ns
                    end
                end
                @test owner.cursor.sequence == last(failed_batch.exposures).sequence
                sampled = capture_module.snapshot(owner.capture)
                @test sampled.metadata.raw.identity.sequence == last(failed_batch.exposures).sequence
                @test all(isfinite,failed_batch.values)
                # Admit a fresh probe/settle phase so the next rejection proves
                # the consumer latch, rather than merely an invalid phase.
                adopted = complete(Actions.Adopt(UInt32(2),reference))
                @test adopted isa Actions.Adopted
                settled = complete(Actions.Settle(UInt32(2),adopted.cursor,Actions.Immediate()))
                @test settled isa Actions.Settled
                @test server.phase === :Settled
                cursor = owner.cursor
                published = Wire.pipewire_calibration_status(owner.hil).frame_publication_cycle_sequence
                rejected = complete(Actions.Collect(UInt32(2),settled.cursor,measurements,UInt32(1)))
                @test rejected isa Actions.Failed && rejected.reason === Actions.InvalidEvidence
                @test server.phase === :Settled
                @test owner.cursor == cursor
                @test Wire.pipewire_calibration_status(owner.hil).frame_publication_cycle_sequence == published
                @test callback_count[] == 3 && sample_count[] == 2
                @test isempty(client.records)
                progress("latched Collect rejected; restoring and releasing")
                restored = complete(Actions.Restore(reference,Actions.DiscardExposures(UInt32(1))))
                @test restored isa Actions.Restored && restored.figure == reference && !restored.clipped
                @test owner.restored
                @test owner.cursor.sequence == cursor.sequence + 1
                @test Wire.pipewire_probe_values(owner.hil) == reference
                @test callback_count[] == 3 && sample_count[] == 2
                @test complete(Actions.Release()) isa Actions.Released
                close(client); client = nothing
                @test fetch(serving) === nothing && server.phase === :Released
                close(server)
                @test owner.closed && owner.hil.closed && !owner.hil.started
                @test all(worker -> istaskdone(worker.task) && worker.error[] === nothing,owner.workers)
                @test all(slot -> slot.buffer.handle == C_NULL,values(owner.capture.slots))
                @test !isopen(server.wakeup) && !isopen(server.core)
                @test all(stream -> !isopen(stream),values(owner.capture.streams))
                @test Wire.pipewire_calibration_status(owner.hil).pending_exposure === nothing
                @test owner.capture_store === nothing
            finally
                client === nothing || close(client)
                server === nothing || close(server)
                frontend === nothing || FilterGraphIsland.close_execution(frontend.graph)
                command === nothing || FilterGraphIsland.close_execution(command.graph)
            end
        end
    finally
        @test hashes(application) == before
        @test hashes(source) == source_before
        @test !any(id -> id.name in ("CUDA","AMDGPU"),keys(Base.loaded_modules))
    end
end

end # module
