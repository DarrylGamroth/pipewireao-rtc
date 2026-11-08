# Full RTC verification of managed HIL profiles

The earlier [managed HIL checks](../20261108-managed-hil/REVIEW.md) exercised
source owners with test-owned peers. This gate uses the installed headless RTC
and its normal systemd startup and native admission. Each invocation creates
its own core and uses the sealed profile's cold HIL launcher. The verification
compares declared Node names and owning process identities against the live
registry. It resolves the declared output and input Ports to global IDs and
checks the corresponding RTC-owned Links. A held, negotiated Link may be
paused. Full admission also requires the native Ready acknowledgement.

## Cohort

Julia 1.13.3, PipeWireAO 0.9.2, native 4.0.2+0, FilterGraphAlgorithms 0.12.0,
FilterGraphs 0.10.0, FilterGraphPipeWire 0.5.2, AdaptiveOpticsCalibration 0.17.3,
AOS `c058f32f`, HIL `75a062b`, and instrument profiles `ac8ec0c`. The RTC
baseline was `cef5972`. Deployed manifests used immutable Git trees for the
unpublished RTC, AOS and HIL versions. The AVX2 native artifact was
`b84754cc61ae9a8e33d31ec4352f188fa5405581`. The installed profiles require
`libpipewire-module-queue`, which is provided separately from that artifact.
The private SDK added the module from `pipewireao-spa-plugins-core` at
`1119e13`, built against the 4.0.2 headers and library. A launcher for the
SDK's `pwao-dump` selected its relocated plugin and configuration directories.

All seven profiles exported. For the Classic and CAL2 diagnostic retries, host
CPU assignments separated cold control compilation from the shared example
CPUs. The instrument definitions, graph declarations and requested Links were
held fixed. These are functional CPU checks for non-actuating sessions.

## Observed startup defects

- `be85433` applies the configured startup deadline to control Node discovery
  and Warmup inspection. The prior publisher could expire before cold dispatch
  preparation finished in Classic and while CAL2 was creating Links. Admission
  and operational request bounds are separate.
- `01b7ae1` increases the bounded observation queue from 256 to 2048 records.
  Classic reproduced the startup overflow before this change. The larger queue
  admitted the controller and progressed to owner Connect. The 4 MiB byte
  limit and fault on overflow remain.
- `e2c8f78` prepares the sparse parameter owner's inactive streams and callbacks
  before it reports Prepared. The prior Classic owner expired during Connect.
  The new owner connected and quit on a private core with Classic's real
  parameter declarations. The full Classic retry also reached source Connected.
- `19592b8` exposes the retained failure when the startup publisher receives a
  failed Warmup reply. A focused check verifies the original text survives the
  Hsm reply and the administrative completion.

The RTC process selector passed eight checks. MediaSession state, transport and
object selectors passed 696 checks, including exact Link ownership and
acknowledged withdrawal on a private core.

## Calibration provenance

The ordinary GPI2 pupil/CAL2 composition rejects the retained calibration.
The recorded upstream prescription begins `6b960d1e`. The built upstream
prescription begins `053f7521`. RTC 0.7.1 reproduces the mismatch. The test-only
pupil receiver uses one synthetic mode and a disconnected offset input. It
cannot establish calibrated physical feedback through the ordinary composition.

## Full-profile outcomes

| Profile | Declared Nodes | Declared Links | Observed result |
| --- | ---: | ---: | --- |
| Classic | 25 | 20 | HIL reached Connected and held at sequence zero after the startup changes. The private core reported a mixer setup warning during linking and RTC rejected Warmup. The exact Link cohort was unconfirmed. |
| GPI2 | 41 | 32 | Cold HIL and the graph host were launched. One invocation reached HIL Prepared and exceeded the startup deadline. The retry lost the RTC control proxy during admission. No complete Link cohort was observed. |
| GPI2 pupil source | 3 | 1 | Ordinary composition rejected calibration provenance before launch. The diagnostic receiver allowed a private full RTC launch, which exceeded its startup deadline. |
| CAL2 external pupil | 13 | 10 | The full RTC discovered the optical source and both controller owners. An exact `cal2-llowfs-controller:modal-residual` to `cal2-llowfs-modal-residual-queue-input:playback_1` Link negotiated row-major Float32, shape 8 and rate 500/1 while held. Full admission failed. |
| SPIDERS nominal | 12 | 10 | The SCC graph host rejected the configured recovery controller before admission. |
| SPIDERS Proper | 12 | 10 | The same SCC graph host rejection. |
| SPIDERS fitted | 12 | 10 | The same SCC graph host rejection. |

The three SPIDERS profiles declare `correction:closed` for recovery in the
single-controller SCC graph. The selected `correction` Node uses
`leaky-integrator-f32`. FilterGraphPipeWire 0.5.2 requires a
`ClosedLoopCorrectionWorkspace` for that role and rejected it. Changing a
scientific controller or disabling a protection requires separate qualification.

CAL2 first expired while the publisher was polling Warmup. Its isolated retry
connected the owners and reached Link creation, then failed warmup. A separate
registry observation caught the retained error in another retry,
`pw_core failed: unknown resource 91 op:7 (-2)`. The observer opens short-lived
registry clients during startup. This run identifies the native failure without
establishing which object was retired or whether the observer contributed.

The full seven-profile admission and Link gate remains open. The results cover
software startup and the stated partial Link observation. The standalone source
checks and the focused RTC Link ownership test remain separate evidence.
