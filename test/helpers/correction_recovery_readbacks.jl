# Exact property reply inputs for native normalization tests. Existing selectors
# provide CR/Runner/Envelope and the scripted source of ordinary owner properties.
mutable struct ReadbackTransport <: CR.RecoveryTransport
    properties::Dict{String,Runner.RunnerScalar}
    token::Int64
end
CR.transport_instance(::ReadbackTransport) = Int64(912)
CR.transport_initial_token(::ReadbackTransport) = Int64(0)
CR.transport_clock_ns(::ReadbackTransport) = UInt64(1_000_000_000)
function CR.request_native!(transport::ReadbackTransport, command::Runner.RunnerCommand{:properties};
        deadline::Float64, check)
    check()
    transport.token += 1
    header = Envelope.ReplyHeader(Envelope.ControllerIdentity(UInt32(1), UInt64(2), Int64(3)),
        Int64(912), transport.token, Runner.operation_id(command), Int32(0))
    details = (; graph=only(command.args), properties=transport.properties)
    return Runner.Completion(header, Runner.Running,
        Runner.RunnerResult{:properties,typeof(details)}(Runner.Observed, details), nothing)
end
function native_readback(properties)
    transport = ReadbackTransport(properties, Int64(0))
    channel = CR.RecoveryChannel(transport, Int64(912), Int64(0))
    return CR.native_snapshot!(channel, "science"; deadline=2.0, check=() -> nothing)
end
owner_properties(transport) = CR.request_native!(transport,
    Runner.RunnerCommand(:properties, "science"); deadline=2.0, check=() -> nothing).result.details.properties
function replace_readbacks(snapshot, scope, readbacks)
    CR.RecoverySnapshot(scope, snapshot.serial, snapshot.owner_instance, readbacks,
        snapshot.request_token, snapshot.release_token, snapshot.requested_generation,
        snapshot.active_generation, snapshot.recovery_generation, snapshot.recovery_state,
        snapshot.inhibited, snapshot.reference_reached, snapshot.source_sequence,
        snapshot.source_ns, snapshot.reference_timeout_ns)
end
readback_error(f) = try f(); nothing catch error; error end
