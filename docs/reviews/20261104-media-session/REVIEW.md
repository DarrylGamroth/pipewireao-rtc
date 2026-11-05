# MediaSession migration evidence — 2026-11-04

## Scope and baseline

Implementation continues from `a0e47d2` on
`codex/julia-session-policy-20261104`. The user selected removal of both Lua and
libwireplumber, using public PipeWireAO.jl APIs, and requested a Julia module in
its own directory. Terminology follows upstream media-session, inspected at
`7376c167f1ad20b3968d7a5d6c395a8b698d31d8`, with Julia naming conventions.
The module is `MediaSession` in `src/media_session/`.

RTC-ARCH-024/026 retain one RTC application authority and a separate scientific
graph process. The [migration plan](../../SESSION_POLICY_MIGRATION.md) records
the requirement closure. The replacement is not yet integrated or qualified.

## Pure lifecycle and control slice

Observed: `test/test_media_session.jl` passes 507 assertions. The Hsm implements
prepare/warmup/admit, queries, groups, start/stop/reset, all-managed-state Quit,
source-first fault compensation, exact effect correlation, cancellation fencing
and bounded reply/cancellation slots. Opaque effect completion means the backend
has already validated native evidence; the machine does not fabricate successful
native effects. Source completion uses a typed `SourceEnd` observation.

Observed: `test/media_session_controls.jl` passes 67 assertions for cold owner,
HEART, acquisition and legacy source semantics, correction/recovery admission,
scalar property transactions and sparse parameter submission. The adapters use
existing native codecs and preserve request/receipt correlation. These tests
use controlled I/O boundaries; they do not qualify live transport.

The renamed module and both selectors were loaded together in a fresh Julia
1.13.3 process; all 574 assertions passed with exit status zero. No `Any` fields,
`isa` branches or field-presence type selectors were added to these sources.

| Finding | Classification | Disposition |
| --- | --- | --- |
| HSM-S01 — expired source Hold cancels emergency Disconnect | Confirmed by independent cached-clock reproduction | Fixed: transport teardown has an unbudgeted terminal path; later Tick/loss events cannot revoke it; same reproduction and 36 boundary checks pass |
| Quit acknowledgement cannot be fenced before publication exists | Confirmed source-ordering mismatch | Publish the accepted Offline reply before the final sync/disconnect effect; failure/expiry preserves the accepted outcome; 70 disposition checks pass |
| First control-event compilation can exceed five seconds | Observed integration risk | Main must warm the actual production machine/event types before exposing the native endpoint; real deadline qualification remains open |

Independent review inspected cancellation, hierarchy-specific expiry, fault
uncertainty and Quit fencing. No further blocking pure-machine defect was found.
Backend qualification must still prove cancellation drain before replacement,
exact native identity/format evidence and withdrawal while creation is pending.

## Native loop support

PipeWireAO.jl commit `2a95e74` provides owner-thread bounded nonblocking `iterate!` and
`enum_params!(...; sequence_out=Ref{Cint}())`. Existing enumeration callers still
receive the object. The returned native sequence, rather than the caller's
requested sequence, correlates parameter events through a core sync fence.
One native loop iteration can dispatch several callbacks; its count is not a
callback-count or time bound.

Observed upstream verification: 2,240 assertions across 75 printed testsets,
including 42 focused checks against the isolated native 4 SDK. Generated bindings,
dependencies and version are unchanged. Logs are
`/tmp/pipewireao-session-api-suite-20261104.log` and
`/tmp/pipewireao-session-api-focused-final-20261104.log`.

The discarded libwireplumber bridge experiment is preserved at `24ad2e9` on
`codex/libwireplumber-bridge-evaluation-20261104`. Its six native/sanitizer cases
do not qualify the selected direct-PipeWire implementation.

## Remaining integration gate

The direct owner loop, bounded ingress, journal persistence, exact discovery and
Link lifetime, launcher/process binding and native lifecycle selectors remain
in progress. Existing sealed/installed applications, services, devices and graph
threads are unchanged. No hardware, strict deadline, tail-latency, GPU or
sustained-cadence claim follows from these software slices.
