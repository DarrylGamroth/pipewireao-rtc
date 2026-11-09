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

## Repeat with registry-based binding

The repeat used RTC `2c1e462`, HIL `6e8a489`, and the same AOS, instrument,
graph and native revisions above. Pkg regenerated the launcher manifest. The
previous manifest lacked the HIL extension registration, which reproduced the
missing `managed_main` method. The resolved environment passed 18 cold managed
HIL checks and 33 standalone optical checks on private cores. The launcher
implementation needed no change.

All seven CPU profiles exported with the standard instrument exporter. A
temporary local registry supplied the unpublished package trees to the normal
sealed deployment path. The fitted export used the existing generated optical
bundle in a scratch instrument copy. The run used `SessionRuntime.start!` and
`ready` before observing the private registry with `pwao-dump`. The observer
matched exact Node names and Client PIDs, resolved Port directions and IDs, and
checked each Link's state and RTC Client PID.

| Profile | Result |
| --- | --- |
| Classic | Ready. All 25 declared Nodes and 20 RTC-owned Links matched. Shutdown lost the RTC control proxy before the reply. The final receipt confirmed cleanup and retained the service failure. |
| GPI2 | HIL reported Prepared. Admission timed out while RTC was observing a bootstrap owner. Native teardown then reported SIGSEGV. The final receipt confirmed cleanup. |
| GPI2 pupil source | The ordinary composition rejected the original calibrated mirror prescription before RTC launch. The cold HIL launcher passed ten transport checks with the existing synthetic P/Q receiver. |
| CAL2 external pupil | Admission timed out while RTC was enumerating a bootstrap owner. Timeout teardown reported a wrong-context PipeWire call and SIGABRT. The final receipt confirmed cleanup. |
| SPIDERS nominal | The SCC host rejected the configured recovery controller because it requires a CPU closed-loop correction workspace. |
| SPIDERS Proper | The SCC host reported the same recovery workspace rejection. |
| SPIDERS fitted | The SCC host reported the same recovery workspace rejection. |

The three SPIDERS attempts stopped after the owner rejection was observed.
All six launched invocations retained complete cleanup and unit-file removal
receipts. Classic closed the admission and Link gate for its CPU profile.
The other six profiles still require successful full admission.

## Bootstrap and cancellation investigation

Both profiles configure a 900-second startup window. The old default
`SessionRuntime.start!` deadline bounded the entire operation to 430 seconds.
After installation and unit setup, the original runs reached only 399 seconds
of systemd startup for GPI2 and 389 for CAL2. With an explicit deadline covering
the configured window, the same GPI2 profile reached Ready in 845 seconds and
matched 41 Nodes and 32 RTC-owned Links. A sample during the wait showed the
graph owner compiling in LLVM while RTC continued to receive PipeWire replies.
Commit `83b4070` derives the default deadline from the configured window and
preserves an explicit caller deadline.

With the full window, CAL2 completed bootstrap and proceeded to Link creation.
The core reported invalid ndarray format and the LLOWFS owner exited with
`EINVAL`. The compiled CAL2 optical prescription starts with `485b800e`.
The accepted calibration names `cdc2e50f`. The exported LLOWFS camera schema
starts with `0e9deef1`; its controller requires `02a24c6a`. The SCC camera
and controller schemas also differ. Commit `9eeecfe` rejects those incompatible
declarations in the existing deployment validation. The focused checks accepted
the sealed GPI2 application and rejected the CAL2 LLOWFS Link before launch.
The retained CAL2 calibration still needs an accepted selection for the
current prescription.

The earlier SIGSEGV and SIGABRT came from the startup publisher. The stacks
show Julia's SIGTERM exit hook calling PipeWire finalizers outside their owning
loop. Commit `d2beef3` routes systemd cancellation through Julia's interrupt
unwinding. RTC dispatches its existing shutdown event at a duty boundary. The
private process test passed native Quit and interruption. In a deliberate
installed CAL2 cancellation, the publisher had an open connection to the
private core and exited with `InterruptException`.
The RTC main process reached systemd's existing SIGKILL fallback. The initial
cleanup observer expired, then reconciliation verified the retained cleanup
and unit-file removal. The installed GPI2 rerun used the default deadline and
separated the graph and simulator leader CPUs from the RTC leader. It reached
Ready in 416 seconds and again matched 41 Nodes and 32 Links. The orderly Quit
reply was lost and systemd retained a service failure. Both installed reruns
confirmed cleanup, with no SIGSEGV, SIGABRT or wrong-context warning in their
session-unit logs.

The focused startup, launcher/transport, and deployment/export selectors
reported 206, 86, and 422 passing assertions, respectively.
