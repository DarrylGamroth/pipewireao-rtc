# Native acquisition lifecycle helpers

These Julia helpers implement the cold transport portion of RTC-DEV-030 phase D
for the two [acquisition lifecycle profiles](NATIVE_ACQUISITION_LIFECYCLE_CONTROL.md).
They do not apply acquisition effects. The scientific and HEART calibration
owners and the HEART correction owner still need integration with their sole
serialized dispatchers.

## Runtime API

`PipeWireAODeployment.NativeAcquisitionLifecycleRuntime` provides:

```julia
Runtime(profile, remote::AbstractString, node::AbstractString, instance::Int64)
has_pending(runtime)::Bool
poll!(runtime)
take!(runtime)
lifecycle!(runtime, state::ColdLifecycle)
complete!(runtime, ticket, state::ColdLifecycle, snapshot::Union{Nothing,Snapshot};
          result::Int32=Int32(0), message::AbstractString="")
flush_terminal!(runtime, deadline::Float64; check=()->nothing)
close(runtime)
```

The constructor requires an absolute, owned private PipeWire remote. It
creates a ThreadLoop, Context, Core and inactive no-port Filter endpoint in
Preparing. Its Core error callback retains an error even if it occurs before
the Endpoint object exists. Constructor failure and `close` attempt every
owned cleanup resource, preserving cleanup errors with the primary error.

`has_pending` reads one prepared atomic wake flag. The endpoint publisher,
registry global add/remove listener and Core error callback set it. This is
the only helper call suitable for an idle scientific service hook. It does not
scan the registry or allocate after compilation. The existing serialized
owner must call `poll!` and then `take!` together when woken, outside the
scientific callback and without holding the ThreadLoop lock across effects:

```julia
function service_lifecycle!(runtime)
    has_pending(runtime) || return nothing
    poll!(runtime)
    return take!(runtime)  # apply the returned ticket later at the owner boundary
end
```

Both `poll!` and `take!` clear the flag **before** entering the generic
endpoint. A callback concurrent with either call sets it again. The caller
must not recheck `has_pending` between `poll!` and `take!`: the first call can
consume a wake while the accepted ticket remains queued. The runtime starts
no polling task. When owner effects are paused or a ticket is already being
applied, the serialized owner must make its next cold check at the relevant
boundary; the runtime does not grant permission to run effects inside a
callback.

`complete!` accepts only an applying ticket already taken from the generic
Endpoint. It encodes a typed completion and uses Endpoint matching, live
controller and deadline checks for successful results. Negative results may
truthfully carry no snapshot. For terminal Shutdown, perform the actual owner
cleanup first, publish the terminal completion, then call `flush_terminal!`
before removing the endpoint. The latter uses exact public Core `sync!` /
`on_done` sequence matching under the original absolute deadline. Failure
to observe synchronization leaves the caller with an unknown outcome.

## Client API

`PipeWireAODeployment.NativeAcquisitionLifecycleClient` provides:

```julia
connect(profile, remote, node, pid, instance, instrument::Instrument;
        deadline::Float64, check=()->nothing)::Connection
connect_owner!(connection; deadline::Float64, check=()->nothing)::Completion
status(connection; deadline::Float64, check=()->nothing)::Completion
request!(connection, operation::Symbol; deadline::Float64, check=()->nothing)
close(connection)
```

`connect` uses the generic exact private-core discovery and controller
incarnation proof. It waits for Prepared or Connected and requires a newly
processed Status completion. `connect_owner!` requires a successful Connected
snapshot. Every returned completion snapshot must have the selected Classic
or Copper instrument; a mismatch permanently faults that client. `request!`
returns the typed Completion or Rejection for one of the six fixed operations.
The generic client serializes requests and uses one absolute deadline. It
does not rebind or retry an unknown result.

## Integration boundary and evidence

The current `_run_locked` deployment sequence still waits for preparation and
connection files for non-HEART owners. `calibration_source_control!` currently
removes the native source control node option and adds legacy control request
and reply paths. Owner integration must update the descriptor and actual
callers together; these helpers are not a file-marker fallback.

The focused CPU 15 private-core fixture exercises both profiles with a
synthetic serialized owner. It checks Preparing/Prepared/Connected status,
fresh token results, instrument/profile rejection, callback staging with
effects in the stub dispatcher,
acquisition/report cursor lag, unsupported calibration Reset, correction
window/generation change, queued expiry, controller removal, terminal Core
synchronization and clean resource closure. A warmed idle `has_pending` and
service fast path each measure zero Julia heap bytes. Run it with:

```sh
taskset -c 15 julia --project=deployment/julia -e 'using PipeWireAODeployment; include("deployment/julia/test/native_acquisition_lifecycle_client.jl")'
```

The fixture has no scientific acquisition, HEART process or installed
deployment. It does not establish restoration safety, scientific equivalence
or inclusive allocation behavior of an integrated owner.
