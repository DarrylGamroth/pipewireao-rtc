# Julia calibration migration delivery record

## Baseline and claim

Implementation starts from clean RTC `395c8bf` on branch
`work/julia-calibration-migration-20261003`, in the dedicated
`pipewireao-rtc-julia-calibration` worktree. The selected language requirement
is RTC-DEV-029 and the closure is defined by the
[migration plan](JULIA_CALIBRATION_MIGRATION.md). RTC-DEV-020 through RTC-DEV-028
continue to govern deployment, placement, source/owner control and the HEART
bridge; migration does not replace their lifecycle or scientific contracts.

The selected Julia operational migration is complete. Portable regressions,
installed acquisition, cold preparation, unchanged HEART exchange and actual
systemd user-service lifecycle checks pass within the bound scope below.
CPU Classic/Copper FGN/JFG are the installed acquisition surfaces; CUDA/AMDGPU
configuration remains backend selection, without a new cadence claim. HEART
source remains unchanged. Existing Python workflows and prior qualification
evidence remain identifiable development references.

## Closure and evidence allocation

| Obligation | Implementation allocation | Verification allocation | State |
| --- | --- | --- | --- |
| Shared parsed-value validation, finite bounds and CLI admission | `deployment/julia/common.jl` | Exact UInt64 identities, lexical float types, strict JSON grammar, overflow and CLI failures | Portable checks pass |
| Standard graph/package contracts, finite payloads, hashes and scientific source identity | Julia export modules | Malformed payload/hash/path cases; staged dependency replacement preserves sealed input | Portable and final cold chain checks pass |
| Placement, foreground lifecycle, control broker, deadlines and process cleanup | Julia Deployment/Placement modules | All supervisor native threads pinned; prompt-close replies, owned descendant cleanup and direct main-process notification | Portable checks and installed Copper/Classic FGN/JFG stages pass |
| HEART configuration and external owner without Python | Julia HeartExport/HeartOwner modules | Native YAML/offset fixtures and installed cold exports | Portable, cold and final foreground/service checks pass |
| Classic dark/reference/qualification/interaction and selectable methods | Julia CalibrationCampaign/CalibrationMethod modules | Recipe/receipt failures, retained-input reductions and installed FGN/JFG stages | Both engines pass four-stage campaign and method selection |
| Copper reference and multi-batch amplitude pilot | Julia CopperReference/CopperQuality modules | Producer/seal guards, preserved batches, known/unknown outcomes and installed paired stages | Both engines passed reference and pilot |
| Installed entry points, dependency closure and systemd user service | Julia wrappers and deployment install | Restricted executable path/exec tracing; relocation/reinstallation preserves seals and versioned resources | Portable, installed foreground and actual user-service checks pass |
| Numerical estimator reuse and hot-path boundary | Existing Julia analysis/AOC; unchanged graph callbacks | Independent Float64 reductions and prior-run payload/product hashes | Copper and Classic retained-input audits pass; acquisition variation remains open |

Every installed run must bind its implementation, recipe, package, binary,
detector/plant, settings and evidence hashes. Required lifecycle outcomes are
exact delivery and response association, acknowledged restoration and release,
public shutdown, process reaping and owned-runtime removal. Failure evidence
must identify whether an outcome is known; unknown mutations cannot resume
ordinary integration. Each completed batch is preserved before advancement.

## Final HEART and service qualification

Fresh installed v8 packages, with explicitly selected compatible scientific
sources, pass all four routes. Every route completes two batches, each with
16 simulated frames and 16 DM commands, without reported delivery failure.
Public stop, reset and restart renew native HEART generations 1 → 2; both
native placements are validated before exchange. Foreground shutdown records
`stopped`, clears admission and reaps owned processes. Service stop reports
`inactive/dead`, `Result=success`, `ExecMainStatus=0` and `MainPID=0`.
All owned instances and runtime directories are removed. The six temporary
qualification unit links are removed after inactive/MainPID-zero checks;
installed packages, unit templates and evidence remain available. Unowned
services are preserved.

| Instrument | Foreground | Systemd user service |
| --- | --- | --- |
| Classic | Pass: 16 + 16 frame/command pairs | Pass: 16 + 16 frame/command pairs |
| Copper | Pass: 16 + 16 frame/command pairs | Pass: 16 + 16 frame/command pairs |

The service's actual `ExecMainPID` equals the admitted Julia supervisor PID;
readiness is sent directly by that process with `NotifyAccess=main`.
Invocation-scoped journals contain readiness and no error-priority entries.
Foreground `execve`/`execveat` traces contain no Python execution. Service
qualification uses the same sealed launcher under the restricted executable
PATH; no tracer replaces its main process. This does not claim a separate
service execution trace. Native HEART source is unchanged. These are finite
CPU functional checks, not throughput, tail-latency or physical-loop tests.

A separate installed Classic active-session interruption also passes. The
source acknowledges Running before SIGINT to the proven owned Julia supervisor;
its post-signal report records one of 16 frames/commands, incomplete with no
reported failure. The supervisor exits zero, records stopped/unadmitted, and
removes its instance; all six recorded process identities are absent. The
pre-signal source file was a stale zero-frame preparation report, so this
establishes an admitted active-session abort before finite completion, not
proof of an exposure in flight at the signal. It is a deliberate incomplete
run, not a completed-delivery test or arbitrary stalled-cleanup bound.

## Numerical evidence and limits

The independent Julia audit uses direct two-pass Float64 moments, without AOC
reducers. For both Copper reference runs, all five published products and all
72 capture-channel files match the corresponding Python-owned runs and each
other byte-for-byte. The independent maximum differences are 4.44 × 10⁻¹⁶ for
dark variance, 6.94 × 10⁻¹⁷ for training variance and 2.78 × 10⁻¹⁷ for the
qualification mean. Four exact midpoint coordinates differ by one Float32 ULP
from rounding the direct sum; the existing offset-Welford estimator explains
these values and reproduces them in both old and new workflows.

Both Copper pilots preserve 16 batches and 128 accepted exposures, with 51
correlated receipts in hold/adopt/settle/capture/restore/release order. All 384
channel payloads per engine and nine compared numerical products match their
prior pilots. Every adopted and restored figure is unclipped.

The Classic FGN campaign's five products and 554 recorded interaction responses
match the prior Python-owned campaign. Dark/training capture payloads match;
four qualification frames differ in raw pixels, slopes and flux while the
qualification analysis agrees. The cause of that input variation is not
established, and capture byte-equivalence is not claimed for that stage. The
native interaction client's persisted result contains response objects and
restoration/resume flags, but lacks per-command serial receipts; migration
reuses the unchanged client and does not improve that evidence boundary.

The successful Classic JFG retry matches its prior run's dark, training and
qualification payloads and four candidate products. Its matrix differs in
737 of 104,152 Float32 entries; 81 of the 554 stored interaction responses
differ in measured values while exposure metadata agrees. The maximum response
difference, approximately 0.03661, is consistent with the maximum matrix
difference of 0.915253 after division by the approximately 0.04 µm represented
push-pull interval. This does not identify the cause of response variation or
establish interaction capture equivalence. Independent Float64 secants from
the retained response values and represented Float32 commands reproduce all
four old/new physical matrices with maximum absolute residual 1.83 × 10⁻⁷
and relative Frobenius residual about 3.48 × 10⁻⁸. The observed new FGN/JFG
matrix difference has relative Frobenius norm 0.0332043. The stored response
variation explains the matrix variation; its acquisition cause remains open.

These checks establish language/estimator parity within the recorded scope.
They do not accept Copper's dim pilot, a new interaction matrix, reconstructor,
physical calibration, correction, accelerator cadence or latency.

Both Classic method-selection runs preserve the original reverse-order plan:
four signed batches with 16 frames each and two selected physical directions.
Their saved responses vary from the prior runs. The new FGN and JFG modal
artifacts differ in eight of 752 values, with maximum absolute difference
0.00052918. Independent Float64 secants reproduce each old/new artifact within
1.61 × 10⁻⁷ maximum absolute residual and approximately 4.02 × 10⁻⁸ relative
Frobenius residual. These are bounded method-selection checks, not acceptance
of a full Hadamard or spatial-mode interaction campaign.

## Installed qualification allocation

The final v8 source snapshot covers 47 reviewed files with aggregate SHA-256
`e813aa3f612515a360379c7f8d5b7c93c3414412f20775cd525da3dc8048244f`.
All 343 assertions pass in seven fresh Julia processes: common 32, deployment
86, HEART configuration 29, HEART owner 19, exports 71, campaigns 75 and
Copper 31. The [evidence ledger](JULIA_CALIBRATION_MIGRATION_EVIDENCE.json)
binds the individual sources, logs, result files, executable traces and audits.

| Installed workflow | Engine | Implementation snapshot | Result |
| --- | --- | --- | --- |
| Copper reference | FGN and JFG | v5 | Complete candidate; three stages each |
| Copper amplitude pilot | FGN and JFG | v5 | Complete candidate; 16 batches each |
| Classic four-stage campaign | FGN | v5 | Complete candidate; 554 interaction responses |
| Classic four-stage campaign | JFG | v7 | Complete candidate; 554 interaction responses |
| Classic selected-method campaign | FGN and JFG | v7 | Complete candidate; four signed batches each |
| Final endpoint capture and terminal cleanup | FGN and JFG | v7 | Eight accepted frames each; restoration, release, shutdown and cleanup pass |

The earlier v5 acquisitions are not relabeled as v7 or v8 runs. The intervening
production changes remove the redundant endpoint flush and correct cold
packaging/resource selection; selected estimators, recipes and algorithm
implementations are unchanged. Final v7 portable regressions, cold preparation
and real endpoint terminal-stage checks exercise those changes. The subsequent
v8 change is confined to the native SPA configuration emitter and its three
HIL/HEART core/client call sites; machine artifacts and scientific calculations
are unchanged. Fresh v8 cold exports and native startup checks cover this path.
Qualification
preparation and live owners run sequentially after the retained cache failure.

Cold exports from the installed v7 and final v8 SDKs pass for Classic/Copper CPU HIL and
unchanged HEART bridge packages. The SDK and runtime package paths contain
spaces. Entry points run under a restricted executable PATH without Python;
foreground preparation/acquisition traces record executed programs. The
recorded scientific input generator is an external development preparation step,
outside this operational boundary. No installed exporter invokes it.

## Corrections and retained failures

The [independent review](JULIA_CALIBRATION_MIGRATION_REVIEW.md) records stable
findings, reproductions and dispositions. Corrections include exact JSON and
time arithmetic, all-thread supervisor placement, immutable installed resources,
sealed-file preservation, owned-descendant reaping, main-process service
notification and inherited child diagnostics. Redundant socket flushes caused
EPIPE after a complete reply and prompt peer close; identical probes pass after
their removal from control and calibration requests.

Installed failures remain separate: a missing `id` in the qualification PATH,
an invalid `Base.Process.pid` access, a control flush race, and cold export
input/staging errors. The intentional diagnostic replay without a calibration
client hit its existing connection timeout; it is not a delivery failure.
Completed evidence was retained, and failed candidates were not promoted.

The first Classic JFG interaction startup failed before admission because a
shared-depot `.ji` file disappeared between Julia's cache enumeration and open.
Cold HIL preparation was running concurrently. Julia's source contains both
that unguarded open and cache pruning, but the exec-only traces do not identify
the deleting process. Preparation and live qualification are serialized for the
fresh retry; no speculative cache or application-retry patch was made.

The first final HEART foreground attempt failed before admission: PipeWire
rejected the compactly serialized `context.modules` array and exited 254.
A native counterfactual with the same modules, properties and objects, using
unique private core names, starts successfully with formatted JSON. The Julia
SPA emitter now preserves parsed values and places object-array delimiters on
separate lines. Only HIL core and HEART core/client configuration writes use it;
protocol and machine-artifact serialization retain their existing writers.
The regression includes roundtrip, delimiter and finite-value checks. Failed
v7 startup remains separate from the fresh v8 qualification.

The fresh v8 HEART package then passed core startup but failed before admission
when importing the selected HIL adapter. Adapter `39efcf5` requires
`AdaptiveOpticsSim.AlgorithmGraphs.PreparedGraphCalibrationBoundary`, absent
from the selected AOS `d30db3f`. This is an observed dependency incompatibility,
not a demonstrated orchestration or detector failure. Final bridge qualification
selects adapter `277d822`, previously accepted with the recorded AOS revision
`d30db3f`, supplied explicitly from an isolated cached checkout. The current
AOS input reports that same commit but its embedded source bytes differ from
the prior package. Fresh packages seal those actual bytes and require fresh
functional qualification; equal Git revisions do not establish source equality.
The incompatible exports and failed admission are retained. No source or
scientific coefficient is changed to conceal that failure. The current adapter
and AOS API must be reconciled before claiming support for that newer pair.

## Calibration work after migration

RTC-DEV-029 remains partial for scientific calibration. Resume flat-mirror
illumination qualification, repeatability and linearity characterization,
controller-coordinate composition, held-out reconstructor validation and
correction. The dim Copper pilot and new interaction matrices remain
unaccepted. Classic interaction response variation remains an acquisition
investigation; an estimator mismatch has not been demonstrated. Reconcile the
newer adapter/AOS graph-calibration API before selecting that dependency pair.
Accelerator cadence, physical endpoints and new RTC latency claims remain
outside this migration qualification.
