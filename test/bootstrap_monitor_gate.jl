# Privileged test instrumentation: pause the sole mailbox consumer, while native
# ingress remains live. This replaces tests borrowing the old application lock.
struct BootstrapMonitorGate <: PipeWireAORTC.OwnerBootstrapRuntime.AbstractOwnerMessage
    reply::Channel{PipeWireAORTC.OwnerBootstrapRuntime.OwnerReply}
    entered::Channel{Nothing}
    release::Channel{Nothing}
end
function PipeWireAORTC.OwnerBootstrapRuntime._dispatch_owner!(
    sm,
    message::BootstrapMonitorGate,
)
    put!(message.entered, nothing)
    take!(message.release)
    put!(message.reply, PipeWireAORTC.OwnerBootstrapRuntime.OwnerReply(nothing, nothing))
    return nothing
end
function pause_bootstrap_monitor(runtime)
    gate = BootstrapMonitorGate(
        Channel{PipeWireAORTC.OwnerBootstrapRuntime.OwnerReply}(1),
        Channel{Nothing}(1),
        Channel{Nothing}(1),
    )
    PipeWireAORTC.OwnerBootstrapRuntime._enqueue!(runtime.mailbox, gate)
    take!(gate.entered)
    return gate
end
function resume_bootstrap_monitor(gate::BootstrapMonitorGate)
    put!(gate.release, nothing)
    take!(gate.reply)
    return nothing
end
