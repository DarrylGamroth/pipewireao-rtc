# acquisition lifecycle helpers

These helpers implement the RTC-DEV-030 cold native control boundary for the two
[acquisition lifecycle profiles](ACQUISITION_LIFECYCLE_CONTROL.md). They stage
requests and publish correlated replies; the profile's serialized owner applies
acquisition effects.
Historical selector names are mapped in the [naming migration](reviews/20261104-naming-cleanup/REVIEW.md).

## Current transport API

`PipeWireAORTC.ControlEndpoint.Transport` is the common owner of the
ThreadLoop, Context, Core, registry listener and inactive no-port endpoint.
Construct it with a lifecycle profile and an owned private remote:

```julia
ControlEndpoint.Transport(profile, remote, name, instance, initial_lifecycle;
                          clock=Clocks.SystemNanoClock(), application_name=nothing,
                          loop_name="rtc-control")
ControlEndpoint.has_pending(transport)::Bool
ControlEndpoint.poll!(transport)
ControlEndpoint.take!(transport)
ControlEndpoint.state!(transport.endpoint, lifecycle)
ControlEndpoint.complete!(transport, ticket, lifecycle, details...;
                          result::Int32=Int32(0), message::AbstractString="", terminal=false)
ControlEndpoint.flush_terminal!(transport, deadline; check=()->nothing)
close(transport)
```

Profiles provide the existing server codecs and `ControlClient.command_type`,
which returns their bounded command union. Calibration and correction use the
profiles and commands in `AcquisitionLifecycleCodec`; bootstrap uses its
existing profile. The transport keeps callbacks limited to staging and wake
hints. The owner applies effects outside callbacks and the PipeWire loop lock.

`has_pending` reads the atomic notification hint. `poll!` and `take!` consume
the prior hint before entering the common endpoint; a concurrent callback can
set a new hint. For serialized acquisition hooks, call `poll!` followed by
`take!` in the same owner turn when the hint is set. Do not recheck between
those calls: `poll!` may consume a hint while its staged ticket remains queued.
The endpoint starts no polling task and does not authorize effects inside a
callback. Bootstrap retains its reserved monitor: it consumes the old atomic
wake once, checks the underlying endpoint under its loop lock, then calls the
endpoint poll/take methods directly.

`ControlEndpoint.complete!(transport, ticket, lifecycle, details...;
result, message, terminal)` encodes the selected profile's existing typed
completion. The endpoint checks ticket correlation, controller presence and
the original deadline for successful results. `state!(transport.endpoint,
lifecycle)` publishes a lifecycle update. For terminal Shutdown, perform owner
cleanup, publish the terminal completion, call `flush_terminal!` with the
ticket's absolute deadline, then remove the endpoint. The flush matches the
public Core `sync!` / `on_done` sequence; failure to observe it leaves the
outcome unknown.

When the owner's lifecycle requires controller-release proof, it retains the
exact controller with `ControlEndpoint.retain_controller!` before terminal
publication and calls `wait_terminal_release!` before teardown. Bootstrap keeps
this sequence under the original deadline. A Core synchronization acknowledgement
alone does not establish controller release.

## Migration note

`AcquisitionLifecycleRuntime` has been removed. Its tests now use the shared
`ControlEndpoint.Transport`; there is no acquisition-specific resource owner
or wrapper API. Existing borrowed `ControlEndpoint.Endpoint` constructors
remain available for loops and cores whose lifetime is owned elsewhere.

## Client API

`PipeWireAORTC.AcquisitionLifecycleClient` provides:

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

## Historical integration receipt

The following dated receipt describes the earlier integration boundary. Its
selector and deployment statements are historical and are not current API
guidance.

The focused CPU 15 private-core fixture exercised both profiles with a
synthetic serialized owner. It checks Preparing/Prepared/Connected status,
fresh token results, instrument/profile rejection, callback staging with
effects in the stub dispatcher,
acquisition/report cursor lag, unsupported calibration Reset, correction
window/generation change, queued expiry, controller removal, terminal Core
synchronization and clean resource closure. A warmed idle `has_pending` and
service fast path each measure zero Julia heap bytes. Run it with:

```sh
taskset -c 15 julia --project=. -e 'using PipeWireAORTC; include("test/native_acquisition_lifecycle_client.jl")'
```

The fixture has no scientific acquisition, HEART process or installed
deployment. It does not establish restoration safety, scientific equivalence
or inclusive allocation behavior of an integrated owner.
