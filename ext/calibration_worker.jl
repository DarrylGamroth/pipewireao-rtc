module CalibrationWorkers

import PipeWireAO as PW
import PipeWireAORTC
import FilterGraphAlgorithms
import FilterGraphPipeWire
import JuliaFilterGraph
import Hsm
using Hsm: @hsmdef, @statedef, @on_initial, @on_event

"Request shutdown on the node lifecycle's control thread."
struct StopGraph end

abstract type GraphReceipt end
struct GraphReady <: GraphReceipt
    sender::PW.CommandSender{StopGraph}
    control_thread::Int
end
struct GraphCompleted{E} <: GraphReceipt
    error::E
    control_thread::Int
    released::Bool
end

"Controller-owned status; completion follows native receiver and node cleanup."
struct GraphStatus{E}
    ready::Bool
    done::Bool
    released::Bool
    error::E
    control_thread::Union{Nothing,Int}
end

"""Controller-local handle. Only queues and the native command sender cross threads.

The prepared graph is lent exclusively to PipeWire's data-thread processing
until completion and task join. The node lifecycle and Hsm stay on a separate
control thread. Neither node nor Hsm is published to the caller. One stop
command and two lifecycle receipts bound each worker's traffic.
"""
mutable struct CalibrationGraphWorker
    const task::Task
    const receipts::Channel{GraphReceipt}
    const preparation_commands::Channel{StopGraph}
    const controller_thread::Int
    sender::Union{Nothing,PW.CommandSender{StopGraph}}
    completion::Union{Nothing,GraphCompleted}
    control_thread::Union{Nothing,Int}
    stop_sent::Bool
end

struct RunGraphLoop{N}
    node::N
end

@hsmdef mutable struct Lifecycle{N,O,F}
    const node::N
    const outputs::O
    const receipts::Channel{GraphReceipt}
    const preparation_commands::Channel{StopGraph}
    const notify::F
    const owner_thread::Int
    receiver::Union{Nothing,PW.CommandReceiver}
    effect::Union{Nothing,RunGraphLoop{N}}
end

@statedef Lifecycle :Active
@statedef Lifecycle :Cold :Active
@statedef Lifecycle :Constructed :Cold
@statedef Lifecycle :Prepared :Cold
@statedef Lifecycle :Connected :Cold
@statedef Lifecycle :Running :Active
@statedef Lifecycle :Stopping
@statedef Lifecycle :Stopped

@on_initial function(sm::Lifecycle, ::Root)
    return Hsm.transition!(sm, :Constructed)
end
@on_event function(sm::Lifecycle, ::Constructed, ::Prepare, _)
    FilterGraphPipeWire.prepare!(sm.node; execution=:complete_frame,
        required_outputs=sm.outputs)
    return Hsm.transition!(sm, :Prepared)
end
@on_event function(sm::Lifecycle, ::Prepared, ::Connect, _)
    FilterGraphPipeWire.connect!(sm.node)
    return Hsm.transition!(sm, :Connected)
end
@on_event function(sm::Lifecycle, ::Connected, ::Publish, _)
    sm.receiver = FilterGraphPipeWire.command_endpoint(sm.node,
        command -> dispatch!(sm, :StopRequested, command), StopGraph; capacity=1)
    # This queue transaction also serializes the preparation/native handoff
    # with quit_calibration_graph!. A controller either queues a cold stop or
    # observes the native sender; there is no interval with neither route.
    lock(sm.preparation_commands) do
        if isready(sm.preparation_commands)
            take!(sm.preparation_commands)
            Hsm.transition!(sm, :Stopping)
        else
            put!(sm.receipts, GraphReady(PW.commands(sm.receiver), sm.owner_thread))
        end
    end
    sm.notify()
    return Hsm.EventHandled
end
@on_event function(sm::Lifecycle, ::Connected, ::Run, _)
    sm.effect = RunGraphLoop(sm.node)
    return Hsm.transition!(sm, :Running)
end
@on_event function(sm::Lifecycle, ::Active, ::StopRequested, _)
    return Hsm.transition!(sm, :Stopping)
end
@on_event function(sm::Lifecycle, ::Running, ::StopRequested, _)
    FilterGraphPipeWire.quit!(sm.node)
    return Hsm.transition!(sm, :Stopping)
end
@on_event function(sm::Lifecycle, ::Stopping, ::StopRequested, _)
    return Hsm.EventHandled
end
@on_event function(sm::Lifecycle, ::Stopping, ::Prepare, _)
    return Hsm.EventHandled
end
@on_event function(sm::Lifecycle, ::Stopping, ::Connect, _)
    return Hsm.EventHandled
end
@on_event function(sm::Lifecycle, ::Stopping, ::Publish, _)
    return Hsm.EventHandled
end
@on_event function(sm::Lifecycle, ::Stopping, ::Run, _)
    return Hsm.EventHandled
end

combine_errors(::Nothing, cleanup) = cleanup
combine_errors(primary, cleanup) = CompositeException([primary, cleanup])

@on_event function(sm::Lifecycle, ::Root, ::Finish, primary)
    failure = primary
    released = true
    for resource in (sm.receiver, sm.node)
        resource === nothing && continue
        try
            close(resource)
        catch error
            failure = combine_errors(failure, error)
            released = false
        end
    end
    Hsm.transition!(sm, :Stopped)
    put!(sm.receipts, GraphCompleted(failure, sm.owner_thread, released))
    sm.notify()
    return Hsm.EventHandled
end

execute!(::Nothing) = nothing
execute!(effect::RunGraphLoop) = (FilterGraphPipeWire.run!(effect.node); nothing)

function dispatch!(sm::Lifecycle, event::Symbol, argument=nothing)
    Threads.threadid() == sm.owner_thread ||
        throw(ArgumentError("calibration graph lifecycle belongs to another thread"))
    Hsm.dispatch!(sm, event, argument)
    # Enter the native dispatcher only after the Hsm handler has returned.
    # Its callbacks may then dispatch commands without recursive Hsm dispatch.
    effect = sm.effect
    sm.effect = nothing
    execute!(effect)
    return nothing
end

function dispatch_preparation_commands!(sm::Lifecycle)
    command = lock(sm.preparation_commands) do
        isready(sm.preparation_commands) ? take!(sm.preparation_commands) : nothing
    end
    command === nothing || dispatch!(sm, :StopRequested, command)
    return nothing
end

function run_graph(descriptor, remote, name, rate, reference_clock, commands, receipts, notify)
    current_task().sticky = true
    owner_thread = Threads.threadid()
    node = machine = failure = nothing
    try
        cancelled = lock(commands) do
            isready(commands) ? (take!(commands); true) : false
        end
        cancelled && return nothing
        node = FilterGraphPipeWire.PipeWireNode(descriptor.graph;
            remote, name, rate, connect=false, reference_clock,
            input_metadata=PipeWireAORTC.Common.telemetry_metadata_ports(keys(JuliaFilterGraph.input_formats(descriptor.graph));
                required=FilterGraphPipeWire.required_input_metadata(descriptor.graph)),
            output_metadata=PipeWireAORTC.Common.telemetry_metadata_ports(keys(JuliaFilterGraph.output_formats(descriptor.graph)),
                keys(JuliaFilterGraph.input_formats(descriptor.graph)), JuliaFilterGraph.output_metadata_source_inputs(descriptor.graph);
                required=FilterGraphPipeWire.required_input_metadata(descriptor.graph)),
            fifo_inputs=true, parameter_ports=false,
            boundary_layout=FilterGraphAlgorithms.RowMajorLayout())
        machine = Lifecycle(node, Tuple(keys(JuliaFilterGraph.output_formats(descriptor.graph))),
            receipts, commands, notify, owner_thread, nothing, nothing)
        for event in (:Prepare, :Connect, :Publish, :Run)
            dispatch_preparation_commands!(machine)
            dispatch!(machine, event)
        end
    catch error
        failure = error
    finally
        if machine === nothing
            released = true
            try
                node === nothing || close(node)
            catch error
                failure = combine_errors(failure, error)
                released = false
            end
            put!(receipts, GraphCompleted(failure, owner_thread, released))
            notify()
        else
            dispatch!(machine, :Finish, failure)
        end
    end
    return nothing
end

"Lend a prepared graph to one sticky owner task; receive lifecycle facts as messages."
function start_calibration_graph(descriptor, remote, name, rate;
        notify, reference_clock=PW.METADATA_CLOCK_REALTIME)
    commands = Channel{StopGraph}(1)
    receipts = Channel{GraphReceipt}(2)
    task = Threads.@spawn run_graph(descriptor, remote, name, rate, reference_clock,
        commands, receipts, notify)
    @async begin
        try
            wait(task)
        finally
            notify()
        end
    end
    return CalibrationGraphWorker(task, receipts, commands, Threads.threadid(),
        nothing, nothing, nothing, false)
end

function controller!(worker::CalibrationGraphWorker)
    Threads.threadid() == worker.controller_thread ||
        throw(ArgumentError("calibration graph handle belongs to another controller thread"))
    return nothing
end
function receive!(worker::CalibrationGraphWorker, receipt::GraphReady)
    worker.sender = receipt.sender
    worker.control_thread = receipt.control_thread
    return nothing
end
function receive!(worker::CalibrationGraphWorker, receipt::GraphCompleted)
    worker.completion = receipt
    worker.control_thread = receipt.control_thread
    worker.sender = nothing
    return nothing
end

"Consume owned lifecycle receipts on the controller thread without waiting."
function calibration_graph_status(worker::CalibrationGraphWorker)
    controller!(worker)
    return lock(worker.receipts) do
        while isready(worker.receipts)
            receive!(worker, take!(worker.receipts))
        end
        completion = worker.completion
        return GraphStatus(worker.sender !== nothing && completion === nothing,
            completion !== nothing, completion !== nothing && completion.released,
            completion === nothing ? nothing : completion.error,
            worker.control_thread)
    end
end

"Dispatch one idempotent stop request; join and consume completion before reclaiming the graph."
function quit_calibration_graph!(worker::CalibrationGraphWorker)
    controller!(worker)
    worker.stop_sent && return nothing
    lock(worker.preparation_commands) do
        worker.stop_sent && return nothing
        status = calibration_graph_status(worker)
        if !status.done
            if worker.sender === nothing
                isopen(worker.preparation_commands) ||
                    throw(InvalidStateException("calibration preparation mailbox is closed", :closed))
                Base.isfull(worker.preparation_commands) &&
                    throw(InvalidStateException("calibration preparation mailbox is full", :full))
                put!(worker.preparation_commands, StopGraph())
            else
                result = PW.try_send!(worker.sender, StopGraph())
                result == PW.COMMAND_FULL &&
                    throw(InvalidStateException("calibration stop mailbox is full", :full))
            end
        end
        worker.stop_sent = true
    end
    return nothing
end

"Join an already completed worker and return its cleanup acknowledgement."
function finish_calibration_graph!(worker::CalibrationGraphWorker)
    controller!(worker)
    istaskdone(worker.task) ||
        throw(InvalidStateException("calibration graph has not completed", :running))
    fetch(worker.task)
    status = calibration_graph_status(worker)
    status.done || error("calibration graph completed without a cleanup receipt")
    status.error === nothing || throw(status.error)
    return status
end

"Return whether successful task completion explicitly releases the borrowed scientific storage."
function calibration_graph_released(worker::CalibrationGraphWorker)
    controller!(worker)
    status = calibration_graph_status(worker)
    return istaskdone(worker.task) && !istaskfailed(worker.task) && status.done && status.released
end

end
