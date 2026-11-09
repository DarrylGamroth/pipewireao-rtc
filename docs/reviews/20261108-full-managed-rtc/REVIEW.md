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

## Installed shutdown repeat

The sealed CPU applications reused the private 4.0.2 SDK above. They resolved
PipeWireAO 0.9.2, PipeWireAO_jll 4.0.2, AOS `c058f32f`, HIL `6e8a489` and
the following FilterGraph releases. The registry tree hashes matched the
corresponding release tags.

| Package | Version | Git tree |
| --- | --- | --- |
| FilterGraphs | 0.10.2 | `8edab78006cd7bf2d602383412da48e32d01a827` |
| FilterGraphAlgorithms | 0.12.2 | `4c419e7fc636909cc7c8ccb4eb82bb452b1c67e3` |
| FilterGraphPipeWire | 0.5.3 | `c34b29490f83167a14cc834a0c884822ddd2c568` |

GPI2 used the declared CPU profile and the separate leader CPUs from the
previous run. During owner Quit, a graph owner closes its data Nodes and Ports
before publishing its correlated `Stopped` reply. Commit `ddfc616` allows that
exact data cohort to withdraw once RTC starts the owner's Quit. RTC still
requires the bootstrap Node and its reply.

CAL2 used a temporary copy of the external-pupil CPU profile with the two
incompatible camera-to-controller image Links omitted. This allowed the sealed
export and the existing schema validation to run. The test stops systemd
startup after the publisher connects to the private core. CAL2 admission with
the original Links still requires matching calibration.

Commit `fefb72c` makes the configuring HSM start Quit when the exact publisher
that requested Warmup disappears. In the installed run at `ddfc616`, the
publisher exited via `InterruptException`, RTC reported an expired effect and
settled in a held fault, and systemd sent SIGKILL to the RTC process after its
stop deadline. Commit `597ba3d` carries local Quit through the existing
source-first fault cleanup and closes the RTC connection even if that cleanup
fails or expires. The deterministic regression failed six assertions before
that change and passed all 51 afterward.

The final runs used RTC `597ba3d` on separate private cores.

| Profile | Observed result | systemd invocation |
| --- | --- | --- |
| GPI2 | Ready after 491 seconds. All 41 declared Nodes and 32 RTC-owned Links matched the registry. The installed `ExecStop` accepted the native Quit reply and the unit exited successfully. | `3d6d7a149f384faa9cdeb43d7c67aff7` |
| CAL2 external pupil | The publisher unwound during Warmup. RTC closed its connection and returned status 1 about four seconds after the interrupt was logged. The session and its owners stopped without SIGKILL. | `3db13de81a7d492d86b6094d149bbe7f` |

Both retained receipts confirm cleanup and generated unit-file removal. The
CAL2 graph owners reported that their bootstrap controller was revoked. The
simulator exited on SIGTERM and emitted PipeWire wrong-context warnings during teardown.
The session and owner journals show no SIGSEGV or SIGABRT in the final runs.

The core suite passed the HSM and private Link selectors. It stopped at an
existing composition test that expects a port with an omitted schema to link
to a port with an explicit schema. The same assertion failed independently
with the `ddfc616` package and the same dependencies.

## CAL2 simulator process interruption

CAL2 selects the shared HIL external-pupil runner through YAML. Its
configuration supplies the optical graph and named SCC and LLOWFS outputs.
The earlier warning occurred while the managed launcher was still loading
Julia packages, after the bootstrap endpoint had been opened. Systemd's
SIGTERM sent Julia through process exit and the subsequent PipeWire
finalizers reported calls outside the owning context.

RTC `81bd10c` validates and renders the optional owner stop signal in the
generated service. HIL `a4265ff` selects SIGINT for its managed launcher.
The Julia interrupt unwinds the owner scope and dispatches cancellation to the
existing bootstrap HSM. The managed private-core selector passed 18 native
Quit assertions and four Preparing interruption assertions. The standalone
optical selector passed 33 assertions without loading RTC.

The sealed CAL2 repeat used the same FilterGraph releases and temporary
two-Link omission as the shutdown repeat. Systemd invocation
`cdad109354264cc2af1c8f51a2936914` was canceled during Warmup on its private
core. The generated simulator unit selected SIGINT and retained its
15-second stop deadline and SIGKILL fallback. In this run the simulator
observed the bootstrap controller's disappearance and exited with status 1
before systemd stopped the core, so the installed run did not need the signal.
The managed Preparing selector exercised that signal directly. The session
and all owners stopped without PipeWire wrong-context warnings, SIGSEGV,
SIGABRT or SIGKILL. The retained receipt confirmed cleanup and generated
unit-file removal.

## CAL2 matched CPU calibration

The selected historical calibration bound CAL2 prescription `cdc2e50f`
and upstream GPI2 prescription `6b960d1e`. The current sealed applications
identify them as `485b800e` and `053f7521`. The old controller inputs therefore
disagreed with the camera schemas. The CAL2 recipe now references the generated
GPI2 definition that the sealed application executes with its `optical-reference`
graph.

The shared optical calibrator ran the authored probes and Host expected-reference
method against both sealed applications. Each branch retained rank eight. The
full/half-probe derivative error was 0.0043% for LLOWFS and 0.060% for SCC.
The largest held-out reconstruction error was 0.126%. The upstream expected-reference
derivative upper estimate was 0.438%, within the authored 5% bound.
Materialization selected calibration
`sha256:df64cea5b7c02af1d7f9a931cde15470b2b850edeb9a23ba33bc5c0f9a2cc054`
in `generated/chopped-calibration-cpu-20261109`. The historical bundles retain
their original bytes.

The controller export kept both camera Links. Its LLOWFS and SCC ends matched
the camera schemas at `0e9deef1` and `ce65b4da`, respectively. RTC `67bb46d`
rejects a conflict between two explicit schemas at export and keeps the
existing behavior for an omitted schema. The full RTC suite passed 10,704
assertions. The instrument CLI and mode selector passed 59.

Instrument commits `ffc501e`, `200ca1d` and `07ed194` update the calibration
launcher, recipe and selected artifacts. The CPU GPI2–CAL2 feedback
composition sealed successfully with the new bindings. The installed
standalone CAL2 run used RTC `67bb46d`, HIL `a4265ff` and the same FilterGraph
releases as the shutdown repeat.

Invocation `8e8a06261d634046a79e384a37e966a7` reached Ready after 421 seconds
on its private core. The registry matched all 13 declared Nodes and 10
RTC-owned Links, including both camera-to-controller image Links. PipeWire
logged mixer setup warnings during startup. The installed `ExecStop`
accepted native Quit, and the session and all owners exited successfully.
The receipt confirms cleanup and unit-file removal. The journals show no
wrong-context teardown warnings, crash signals or SIGKILL. This is functional
software admission and teardown evidence for the held CPU profile.

## Released CAL2 cohort

The verified instrument calibration and its FilterGraph pins are on instrument
`main` at `8e66280`. The package releases use the following immutable source
trees from [DarrylGamrothRegistry](https://github.com/DarrylGamroth/PackageRegistry/commit/9f4d898294f2d0931b96f458e8d88c8001f6cb54).

| Package | Version | Registered tree |
| --- | --- | --- |
| AdaptiveOpticsSim | 0.3.22 | `d0b755226a0af8df1dabd34e3c3e40bd447b85c7` |
| AdaptiveOpticsSimPipeWireHIL | 0.5.1 | `86606c9e97347083ad6667c510c649103418a3ef` |
| PipeWireAORTC | 0.7.2 | `0b81cc36a9bfadc8648ae39ab59771d3d67efe72` |

Julia 1.13.3 instantiated an empty depot from General and the public registry.
HIL package fetch used authenticated Git because its repository is private.
The package and artifact verifier passed 59 assertions, including the
FilterGraph releases above, Proper 0.4.1, the PipeWireAO 4.0.2 artifact and
extension activation. HIL also loaded independently in a separate process.
The sealed application manifest matched the registered consumer trees.

CAL2 uses the separately distributed queue module alongside the freshly
downloaded JLL. The private SDK added the verified `1119e13` module described
above, with SHA-256 `d7b64cf0a86111f8ca2589b2887ac6fa8dfb77f760a4814dd0428d2a18267f49`.
The test scoped the new depot to its exact systemd unit through a runtime
drop-in. The exported application and installed unit used the standard
installer and launchers.

Invocation `c2d75fa819d843ab8e89366971f8b4e3` reached Ready after 337 seconds.
The RTC, HIL and both graph owners used the isolated depot and the owners'
per-invocation cache. The live registry matched all 13 Nodes and 10 RTC-owned
Links, including both camera Links. PipeWire logged the same mixer setup
warnings during startup. The installed service acknowledged native Quit,
and every process exited successfully. The receipt confirmed cleanup and
generated unit-file removal. The journals showed no wrong-context warnings
during teardown, crash signals or SIGKILL.

The GitHub releases are
[AdaptiveOpticsSim 0.3.22](https://github.com/DarrylGamroth/AdaptiveOpticsSim.jl/releases/tag/v0.3.22),
[AdaptiveOpticsSimPipeWireHIL 0.5.1](https://github.com/DarrylGamroth/AdaptiveOpticsSimPipeWireHIL.jl/releases/tag/v0.5.1)
and [PipeWireAORTC 0.7.2](https://github.com/DarrylGamroth/pipewireao-rtc/releases/tag/v0.7.2).
