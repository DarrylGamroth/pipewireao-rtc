# Included in CorrectionSupervision. All native effects stay on a serialized
# control client, outside the scientific frame callback.
import ..CorrectionRecovery
import ..SessionClient
import ..RunnerCodec
import ..ControlClient

public Client, poll!

const Recovery = CorrectionRecovery

"""One bounded protection client for an exact connection and declared feedback outputs.

`poll!` reads owner-produced supervision, never display observations. A
monitor-only trip has no effect. An explicitly configured restore-reference trip
enters the existing admitted recovery and returns its retained Operation in
Holding. Neither polling nor recovery closes correction. Uncertain effects
latch this client; construct no automatic retry or replacement client.

After protection this client performs status reads only. Recovery release,
closure and observer rearm remain separate explicit operations.
"""
mutable struct Client{T,N}
    const channel::Recovery.RecoveryChannel{T}
    const graph::String
    const outputs::NTuple{N,Symbol}
    owner_instance::Int64
    state::Symbol
end

Client(connection::SessionClient.Connection, graph::AbstractString, outputs::Tuple) =
    Client(Recovery.SessionTransport(connection), graph, outputs)
function Client(
    transport::Recovery.AbstractRecoveryTransport,
    graph::AbstractString,
    outputs::NTuple{N,Symbol},
) where {N}
    1 <= N <= 8 && allunique(outputs) ||
        throw(ArgumentError("protection requires 1 to 8 unique feedback outputs"))
    isempty(graph) && throw(ArgumentError("protection graph is absent"))
    channel = Recovery.RecoveryChannel(
        transport,
        Recovery.transport_instance(transport),
        Recovery.transport_initial_token(transport),
    )
    return Client(channel, String(graph), outputs, Int64(0), :Monitoring)
end

"""Read one correlated native snapshot and consume at most one protective trip.

Use an absolute signed Int64 nanosecond deadline. A replacement owner, unavailable observation,
malformed publication or uncertain native request cannot authorize an effect.
Unknown outcomes are not retried. The returned recovery Operation belongs to the
caller and must be retained even if later operator-directed closure fails.
"""
function poll!(client::Client; deadline::Int64, check = ControlClient.NO_CHECK)
    client.state === :Unverified &&
        throw(ControlClient.UnknownOutcome("supervision client is unverified"))
    try
        Recovery.running!(client.channel; deadline, check)
        reply = Recovery.native_request!(
            client.channel,
            RunnerCodec.RunnerCommand(:properties, client.graph);
            deadline,
            check,
        )
        reply.result.details.graph == client.graph ||
            throw(ArgumentError("supervision graph changed"))
        properties = reply.result.details.properties
        value(name, kind, type) = Recovery.scalar_value(properties, name, kind, type)
        value(OBSERVATION_PREFIX * "version", :int, Int32) == 1 ||
            throw(ArgumentError("unsupported supervision status"))
        instance = value(OBSERVATION_PREFIX * "owner-instance", :long, Int64)
        instance > 0 &&
        instance == value("pipewireao.correction-control.owner-instance", :long, Int64) ||
            throw(ArgumentError("supervision owner mismatch"))
        client.owner_instance == 0 && (client.owner_instance = instance)
        client.owner_instance == instance ||
            throw(ControlClient.UnknownOutcome("supervision owner replaced"))
        now = Clocks.time_nanos(Recovery.transport_clock(client.channel.transport))
        observed = map(client.outputs) do output
            prefix = OBSERVATION_PREFIX * string(output) * "."
            state = value(prefix * "state", :string, String)
            action = value(prefix * "action", :string, String)
            state in string.(OBSERVATION_STATES) ||
                throw(ArgumentError("invalid supervision state"))
            action in ("none", "monitor_only", "restore_reference") ||
                throw(ArgumentError("unsupported protective action"))
            counter(field, T) =
                something(tryparse(T, value(prefix * field, :string, String)))
            sequence, trip_sequence = map(
                field -> counter(field, UInt64), ("sequence", "trip-sequence")
            )
            observed_ns, trip_ns, max_gap_ns = map(
                field -> counter(field, Int64), ("observed-ns", "trip-ns", "max-gap-ns")
            )
            max_gap_ns > 0 &&
            observed_ns <= now &&
            trip_sequence <= sequence &&
            (state != "Tripped" || trip_ns <= observed_ns) ||
                throw(ArgumentError("contradictory supervision evidence"))
            state == "Tripped" ?
            (
                action != "none" ||
                throw(ArgumentError("missing supervision trip identity"))
            ) :
            (action == "none" || throw(ArgumentError("action without a supervision trip")))
            # Native queries can return cached Props. Recompute age in the same
            # host monotonic domain; a once-fresh Boolean is not current proof.
            published_fresh = value(prefix * "fresh", :bool, Bool)
            fresh =
                state in ("Clear", "Pending", "Tripped") &&
                published_fresh &&
                within(now, observed_ns, max_gap_ns)
            return (;
                output,
                state,
                action,
                fresh,
                sequence,
                observed_ns,
                trip_sequence,
                trip_ns,
                max_gap_ns,
            )
        end
        observer_state = value("pipewireao.frame-observer.state", :string, String)
        observer_state in ("active", "failed") ||
            throw(ArgumentError("invalid frame observer status"))
        client.state === :Holding &&
            return (; state = :Holding, observed, operation = nothing)
        observer_state == "active" ||
            return (; state = :Unknown, observed, operation = nothing)
        any(item -> item.state != "Disabled" && !item.fresh, observed) &&
            return (; state = :Unknown, observed, operation = nothing)
        restore = any(
            item -> item.state == "Tripped" && item.action == "restore_reference", observed
        )
        restore || return (; state = :Monitoring, observed, operation = nothing)
        expiry = minimum(
            item -> Base.checked_add(item.observed_ns, item.max_gap_ns),
            filter(
                item -> item.state == "Tripped" && item.action == "restore_reference",
                observed,
            ),
        )
        # Latch before the first possible native effect. Any failure retains it.
        client.state = :Unverified
        operation = Recovery.protective_open!(
            client.channel.transport,
            client.graph;
            deadline,
            check,
            reason = :saturation,
            expected_owner = client.owner_instance,
            admission_deadline = min(deadline, expiry),
        )
        client.state = :Holding
        return (; state = :Holding, observed, operation)
    catch
        client.state = :Unverified
        rethrow()
    end
end
