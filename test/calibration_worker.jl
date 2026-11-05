# Optional private-core selector: --threads=3,1 and the command-endpoint SDK.
module CalibrationWorkerTests

using Test, Hsm, PipeWireAO, PipeWireAORTC, FilterGraphPipeWire, JuliaFilterGraph
using FilterGraphIsland, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL, AdaptiveOpticsCalibration
include("control_private_core.jl")
include("calibration_named_commands.jl")
const Ext = Base.get_extension(PipeWireAORTC, :PipeWireAORTCCalibrationExt)
const Workers = Ext.CalibrationWorkers
const CalibrationEndpoint = PipeWireAORTC.CalibrationEndpoint
const Control = PipeWireAORTC.ControlClient

struct FailedGraphCleanup end
Base.close(::FailedGraphCleanup) = error("graph cleanup failed")

function stopped_before_running(remote, phase, condition, guard)
    projection = CalibrationNamedCommandTests.prepare_command(2,"test.worker-cold/1")
    node = receiver = machine = nothing
    receipts = Channel{Workers.AbstractGraphReceipt}(2)
    commands = Channel{Workers.StopGraph}(1)
    notify() = CalibrationEndpoint.wake!(condition, guard)
    try
        node = FilterGraphPipeWire.PipeWireNode(projection.graph;
            remote, name="test.worker.$phase", rate=500//1, connect=false)
        machine = Workers.Lifecycle(node, Tuple(keys(JuliaFilterGraph.output_formats(projection.graph))),
            receipts, commands, notify, Threads.threadid(), nothing, nothing)
        phase === :constructed || Workers.dispatch!(machine, :Prepare)
        phase === :connected && Workers.dispatch!(machine, :Connect)
        put!(commands, Workers.StopGraph())
        Workers.dispatch_preparation_commands!(machine)
        @test Hsm.current(machine) === :Stopping
        for event in (:Prepare, :Connect, :Publish, :Run)
            Workers.dispatch!(machine, event)
        end
        @test !isready(receipts)
        Workers.dispatch!(machine, :Finish)
        @test Hsm.current(machine) === :Stopped
        completion = take!(receipts)
        @test completion.error === nothing
        @test completion.released
        @test completion.control_thread == Threads.threadid()
    finally
        node === nothing || close(node)
        FilterGraphIsland.close_execution(projection.graph)
    end
end

function queued_before_run(remote, condition, guard)
    projection = CalibrationNamedCommandTests.prepare_command(2,"test.worker-prerun/1")
    node = machine = nothing
    notify() = CalibrationEndpoint.wake!(condition, guard)
    receipts = Channel{Workers.AbstractGraphReceipt}(2)
    try
        node = FilterGraphPipeWire.PipeWireNode(projection.graph;
            remote, name="test.worker.prerun", rate=500//1, connect=false)
        machine = Workers.Lifecycle(node, Tuple(keys(JuliaFilterGraph.output_formats(projection.graph))),
            receipts, Channel{Workers.StopGraph}(1), notify, Threads.threadid(), nothing, nothing)
        for event in (:Prepare, :Connect, :Publish)
            Workers.dispatch!(machine, event)
        end
        ready = take!(receipts)
        @test Hsm.current(machine) === :Connected
        @test try_send!(ready.sender, Workers.StopGraph()) === COMMAND_ACCEPTED
        # Run enters the native dispatcher after the Run handler returns. Its
        # first command must stop the loop without recursive Hsm dispatch.
        Workers.dispatch!(machine, :Run)
        @test Hsm.current(machine) === :Stopping
        Workers.dispatch!(machine, :Finish)
        @test take!(receipts).error === nothing
        @test try_send!(ready.sender, Workers.StopGraph()) === COMMAND_CLOSED
    finally
        machine === nothing || machine.receiver === nothing || close(machine.receiver)
        node === nothing || close(node)
        FilterGraphIsland.close_execution(projection.graph)
    end
end

function worker_trials(remote, directory, daemon)
    condition, guard = Base.AsyncCondition(), ReentrantLock()
    notify() = CalibrationEndpoint.wake!(condition, guard)
    await(predicate) = CalibrationEndpoint.await(predicate, condition, guard, Control.monotonic()+30)
    try
        @testset "controller tasks submit one stop under queue contention" begin
            commands = Channel{Workers.StopGraph}(1)
            worker = Workers.CalibrationGraphWorker(Task(() -> nothing),
                Channel{Workers.AbstractGraphReceipt}(2), commands, Threads.threadid(),
                nothing, nothing, nothing, false)
            lock(commands)
            first = @async Ext.quit_calibration_graph!(worker)
            second = @async Ext.quit_calibration_graph!(worker)
            try
                yield()
                @test !istaskdone(first) && !istaskdone(second)
            finally
                unlock(commands)
            end
            wait(first)
            wait(second)
            @test worker.stop_sent
            @test take!(commands) === Workers.StopGraph()
            @test !isready(commands)
            worker.stop_sent = false
            put!(commands, Workers.StopGraph())
            @test_throws InvalidStateException Ext.quit_calibration_graph!(worker)
            take!(commands)
            close(commands)
            @test_throws InvalidStateException Ext.quit_calibration_graph!(worker)
        end
        @testset "controller status tasks consume one completion without waiting" begin
            receipts = Channel{Workers.AbstractGraphReceipt}(2)
            put!(receipts, Workers.GraphCompleted(nothing, Threads.threadid(), true))
            task = Threads.@spawn nothing
            fetch(task)
            worker = Workers.CalibrationGraphWorker(task, receipts,
                Channel{Workers.StopGraph}(1), Threads.threadid(),
                nothing, nothing, nothing, false)
            lock(receipts)
            first = @async Ext.calibration_graph_status(worker)
            second = @async Ext.calibration_graph_status(worker)
            try
                yield()
                @test !istaskdone(first) && !istaskdone(second)
            finally
                unlock(receipts)
            end
            completed = timedwait(() -> istaskdone(first) && istaskdone(second), 5)
            @test completed === :ok
            if completed !== :ok
                # Unblock a regressed consumer so the diagnostic cannot strand
                # the selector after recording its failed finite completion.
                put!(receipts, Workers.GraphCompleted(nothing, Threads.threadid(), true))
            end
            @test fetch(first).released && fetch(second).released
            @test !isready(receipts)
        end
        @testset "cold cancellation is handled by the lifecycle hierarchy" begin
            for phase in (:constructed, :prepared, :connected)
                stopped_before_running(remote, phase, condition, guard)
            end
        end
        @testset "native commands remain pending across Run entry" begin
            queued_before_run(remote, condition, guard)
        end
        @testset "worker messages preserve affinity, cancellation and cleanup" begin
            for trial in 1:12
                projection = CalibrationNamedCommandTests.prepare_command(2,"test.worker-race/1")
                worker = nothing
                try
                    worker = Ext.start_calibration_graph(projection, remote,
                        "test.worker.$trial", 500//1; notify)
                    if iseven(trial)
                        await(() -> Ext.calibration_graph_status(worker).ready || istaskdone(worker.task))
                        @test Ext.calibration_graph_status(worker).ready
                        GC.gc()
                    end
                    Ext.quit_calibration_graph!(worker)
                    Ext.quit_calibration_graph!(worker)
                    await(() -> istaskdone(worker.task))
                    status = Ext.finish_calibration_graph!(worker)
                    @test status.done && status.released && !status.ready && status.error === nothing
                    @test status.control_thread != Threads.threadid()
                    @test isempty(worker.receipts) && isempty(worker.preparation_commands)
                    @test fetch(Threads.@spawn try
                        Ext.calibration_graph_status(worker)
                        false
                    catch error
                        error isa ArgumentError
                    end)
                finally
                    worker === nothing || Ext.quit_calibration_graph!(worker)
                    worker === nothing || await(() -> istaskdone(worker.task))
                    worker === nothing || Ext.finish_calibration_graph!(worker)
                    FilterGraphIsland.close_execution(projection.graph)
                end
            end
        end
        @testset "failed cleanup never releases scientific storage" begin
            receipts = Channel{Workers.AbstractGraphReceipt}(2)
            commands = Channel{Workers.StopGraph}(1)
            machine = Workers.Lifecycle(FailedGraphCleanup(), (), receipts, commands,
                notify, Threads.threadid(), nothing, nothing)
            Workers.dispatch!(machine, :Finish, ErrorException("graph failed"))
            task = Threads.@spawn nothing
            fetch(task)
            worker = Workers.CalibrationGraphWorker(task, receipts, commands,
                Threads.threadid(), nothing, nothing, nothing, false)
            status = Ext.calibration_graph_status(worker)
            @test status.done && !status.released && !status.ready
            @test status.error isa CompositeException
            @test length(status.error.exceptions) == 2
            @test !Ext.calibration_graph_released(worker)
            @test_throws CompositeException Ext.finish_calibration_graph!(worker)
        end
        @testset "startup failure still transfers cleanup acknowledgement" begin
            projection = CalibrationNamedCommandTests.prepare_command(2,"test.worker-failure/1")
            worker = Ext.start_calibration_graph(projection, joinpath(directory,"absent"),
                "test.worker.absent", 500//1; notify)
            try
                await(() -> istaskdone(worker.task))
                status = Ext.calibration_graph_status(worker)
                @test status.done && !status.ready
                @test status.error !== nothing
                @test status.released && Ext.calibration_graph_released(worker)
                @test_throws Exception Ext.finish_calibration_graph!(worker)
                Ext.quit_calibration_graph!(worker)
            finally
                FilterGraphIsland.close_execution(projection.graph)
            end
        end
    finally
        close(condition)
    end
end

@testset "calibration worker command ownership" begin
    Threads.nthreads(:default) >= 2 || error("use --threads=3,1")
    with_control_private_core(worker_trials)
end

end
