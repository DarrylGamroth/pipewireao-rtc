# Classic registered-package deployment

## Classic completion for review — 2026-10-20

User direction: complete Classic's managed integration and its RTC-owned panel
profile, then review correctness and completeness before moving on to Copper.
The selected development profile is the independent Classic Julia plant on
CUDA with the CPU JFG controller. Released AOS 0.2.1, shared HIL adapter 0.2.2,
PipeWireAO 0.6.18 and native artifact 1.7.1 remain selected. The RTC and Classic
instrument additions are local immutable package candidates for this review;
new public releases are not inferred from a working development checkout.

Starting commits are RTC `fb4efbe`, Classic `e6569a1` and GUI `566b521`.
Implementation uses their dedicated worktrees. The running old Classic cohort,
canonical RTC/REVOLT source-control WIP and GUI review document remain preserved.
The old sealed application is a source of retained controller/artifact bytes,
not a qualification of the new dependency closure. Native source controls keep
RTC-ARCH-024/025 and their existing v1 IDs; the common adapter supersedes the
historical instrument-specific wrapper named in early RTC-DEV-017 text.

The implementation uses version 2 simulation configuration with a lazy instrument
package and immutable settings. The package's Julia graph builder is the sole
plant definition. Wire schemas, dimensions, cadence and exposure are explicit
and checked against that prepared plant before admission. Version 1 remains
available for existing sealed TOML/FITS applications. This does not imply FGN
parity, physical-device authority, an on-instrument calibration, or a guaranteed
500 Hz wall-clock rate; those remain separate supported-profile claims.

| Governing contract / selected obligation | Implementation allocation | Acceptance evidence | Status |
| --- | --- | --- | --- |
| Registered migration / immutable closure | Sealed independent application and candidate registry; released AOS/HIL | Fresh resolve, relocate and instantiate; no path/repository overrides or copied runtime code | Pass: isolated private registry; final sealed application `c52ceb5` validates and relocates with shared caches |
| RTC-DEV-014/025/026 / prepared plant | Shared AOS owner, Classic settings builder | Early Preparing; strict config and wire rejection; one warm/reset of actual CPU/CUDA boundary; explicit unavailable-device failure | Pass: CPU/CUDA preparation and actual managed CUDA owner |
| RTC-DEV-003/004/009/021/025/030 / lifecycle | Existing WirePlumber authority and systemd owners | Held Ready; Start, pause/resume, stopped Reset, fresh generation, invalid-control survival, orderly Quit and exact cleanup | Pass: managed session 68/68 |
| RTC-DEV-005/007/014/024 / scientific transport | Unchanged JFG controller, physical command mapping and HIL boundary | Every accepted command/frame identity; next-frame causality; replay through direct graph at stated tolerances; scalar/parameter adoption and restoration | Pass: ADC transport 44/44, managed adoption/restoration and finite composed replay 1,318/1,318 |
| RTC-DEV-024/027 / calibration identity | Retained hybrid reconstructor/projections and simulation-derived offsets | Exact unchanged controller/matrix hashes; background/reference provenance checked against current prepared plant; no implicit mask/threshold/gain changes | Pass: retained 16 FITS and graph exact; archived operational lineage/current estimator replay |
| RTC-DEV-006 / operator views | RTC-owned schema-11 profile and generic GUI views | Real SHWFS/image/DM/focal bindings, actual geometry/units, readonly simulator properties; missing/lost-source behavior; rendered profile inspection | Pass: SHWFS/DM/focal, 21 Status/Settings values, grouped layout, GUI detach/reconnect and native endpoint-loss invalidation |
| RTC-DEV-006 / bounded observation | Existing copy/drop-oldest exports | No observer, attached, slow, detached and reattached observation; compare accepted deterministic results and continuing lifecycle | Pass: eight-stream progress; exact detector/demanded/adopted results over 16 exchanges in each of four observer modes |
| RTC-DEV-003/009/013/021/025 / faults | Existing policy and exact owned-cohort fault tests | Required endpoint/controller loss faults and holds ingress; bounded cleanup; unrelated session preserved; explicit fresh admission | Pass: link loss 41/41, controller exit 40/40; both emergency cleanup and fresh admission |
| RTC-DEV-026 / resources and cadence | Existing bounded phase recorder and declared placement | Actual target/device/threads, achieved wall cadence/missed periods, bounded storage and warmed allocation counters; keep timing scope explicit | Characterized: 32,768 warmed rows, 429 Hz, 5,421 skipped release slots; 160 whole-process bytes per adjacent exchange, no 500 Hz claim |
| Engineering completion / review | Independent source and final evidence review | All selected rows covered, fresh committed heads, usable launch/stop instructions and retained review candidate | Pass: selected gates independently accepted; fresh committed application and Running GUI review cohort retained |

The detailed commands, initial failures, intermediate candidate identities and
raw evidence live under
`/home/dgamroth/workspaces/codex/worktrees/classic-completion-20261020/`.
[The compact final evidence record](validation/classic-completion-20261020/README.md)
retains the review and final session identity. Later sections retain the earlier
application's exact historical claims.

### Simulator settings and restart

The agreed interactive configuration workflow is **edit, apply and restart the
simulation**. Ordinary source Stop/Start pauses and resumes the existing
prepared model; it does not adopt a new exposure. The current candidate displays
startup facts and acknowledged protocol values, without claiming an editable
simulator-configuration interface.

Exposure is currently part of both the prepared detector and the HIL contract.
A future configuration apply must validate the instrument builder settings and
the timing contract, stop the old simulation, prepare the replacement and admit
it through the existing WirePlumber/systemd ownership. Classic's 500 Hz model
period is 2 ms; exposure must fit that period and the selected detector model.
Changing exposure also changes the detector calibration conditions. The apply
workflow must report that mismatch rather than treating the retained background
and references as newly qualified. Backend/device, geometry and frame layout
likewise require preparation; existing RTC gain and engineering-offset updates
remain native live transactions.

## Baseline and scope

Approved by the user on 2026-10-19: complete a configuration/FITS-only Classic
application with current JFG, CUDA AOS on the RTX 3080, integration checks, then
launch the headless session and attach the GUI.

Starting revisions: RTC `fdc2c55`, JFG `71585ee`, AOS `23b9dc19`, HIL `3c3de5b`.
RTC and JFG changes use dedicated `codex/classic-*20261019` worktrees. The
original REVOLTRTC working tree has four pre-existing changes; they are preserved.
The old `revolt-classic-pipewireao/deployments/baseline-001` is preserved.

The governing contracts are RTC-ARCH-024/025, RTC-DEV-003/004/006/009/013/021/022/030
and [the registered migration contract](REGISTERED_RTC_MIGRATION.md).
This delivery claims only non-actuating Classic CPU JFG with CUDA AOS. Physical
devices, other instrument profiles and real-time/scientific qualification are
outside this increment. Hsm and Agent remain deferred.

## Ownership

The application contains Project/Manifest, graph/session/simulation configuration,
FITS artifacts, provenance and GUI bindings. Registered Julia packages contain
all executable implementations. Installed native PipeWireAO/WirePlumber assets
remain external dependencies; the installer generates only operational wrappers
and an exact systemd unit outside the scientist's source application.

WirePlumber retains sole admission, links and lifecycle authority. systemd owns
process lifetime. Scientific owner extensions publish Preparing before loading
optional science, prepare validated owned arrays, then follow existing connect,
source-first control and teardown order. No new coordinator or frame scheduler
is introduced. Native live parameter encoding remains unchanged.

## Delivery and coverage

| Allocation | Work | Acceptance | State |
|---|---|---|---|
| AAR-01 | Immutable registered dependency closure and small application | Fresh resolve/instantiate, relocate, no copied source/path dependencies/raw artifacts | Final registered 0.1.5 passes sealed relocation and isolated instantiation |
| AAR-02/04 | Package JFG owner and FITS startup | Type/axis/shape/duplicate rejection, cancellation, parameters before capture/publication | Cold checks, all 16 startup bindings and live parameter adoption pass |
| AAR-03/04 | Package AOS owner and explicit geometry | Exact Classic grid/order comparison, GPU preparation, held startup and frame/command association | Selected CPU/CUDA science comparisons and actual CUDA lifecycle pass |
| RTC-DEV-003/004/009/013/021/022/030 | Registered application installer, native controls | Ready/start/stop/reset, parameter submission and exact cleanup on owned sessions; cold cancellation checks | Selected normal lifecycle passes; broader loss/readmission and calibration campaign remain separate |
| RTC-DEV-006 | Shared GUI profile and optional observation | SHWFS, DM and focal image available; GUI closure does not stop RTC | Eight queue streams and GUI attachment/closure pass; final 0.1.5 RTC and GUI retained Running |

Implementation proceeds through package APIs, application construction, software
checks, isolated session integration, independent review, immutable registration,
then the retained GUI session. Preparation and precompilation happen before live
startup; startup budgets are not silently increased to mask failures. Evidence
records failures and limitations separately from successful checks.

## Validation record

Software preparation gates pass on Julia 1.13.2: registered RTC 0.1.4 reports
1,993 assertions in 60 testsets; FilterGraphIsland reports 99; the optional JFG owner
integration reports 18. HIL 0.1.3 reports 1,678 including private-core transport.
[AOS preparation](validation/classic-registered-20261019/AOS_PREPARATION.md)
records exact Classic geometry and same-backend frame/OPD parity on CPU and
the RTX 3080. All 16 RTC startup FITS parameters prepare against current JFG.

The [independent Astra review](reviews/20261019/CLASSIC_DEPLOYMENT_REVIEW.md)
identified incomplete environment validation; sealed environment hashes and
dependency closure/identity validation now reject that case. Legacy source
exports now include optional extensions; the initial broad test run exposed a
relocation failure, and the updated closure plus complete stable rerun pass.

The old Classic graph's `slew_mode=independent` construction field is obsolete
in FGA 0.7 and is removed only in the new application. Its `slew_limit=null`
remains unchanged, so no slew limiter is enabled. All other science settings
and the original 16 FITS files are preserved. Simulation remains 500 Hz model
time, 1,896,000 ns exposure, initially 10 Hz wall pacing. The inherited 900,000 ms
cold startup allowance is retained, not increased.

Native `/opt/pipewireao` is 1.7.0 and lacks the acquisition-v3 trigger symbol
required by registered PipeWireAO 0.6.18. The selected external native prefix
combines the registered PipeWireAO_jll 1.7.1+0 artifact
`3c63168ffd94740be1e2ea34c1eaf12a9468622a` with installed WirePlumber 0.5.18;
`/opt` is preserved. The sealed registry-only 0.1.4 application passes isolated
instantiation and exact relocation. Live session controls, cleanup and GUI
attachment pass below; final 0.1.5 release evidence is recorded separately.

The first actual registered session exposed two distinct prerequisites. The
JLL runtime does not include the separately installed queue/SPA plugins, so
the external native prefix must compose them as well. That failed startup's
exact cleanup was confirmed. The next attempt exposed CL-R02: RTC 0.1.2's
AOS default loader resolved weak dependencies in the package rather than the
application. The three default loaders now resolve in Main, retaining early
Preparing and cancellation order. Actual-default-loader regressions fail on
immutable 0.1.2 and pass in the corrected source (CPU 22, CUDA 21 assertions),
independently verified by Astra. RTC 0.1.3 supersedes 0.1.2 for this application;
the earlier immutable release is preserved. No failed attempt admitted ingress.

The third attempt exposed a separate installed-policy mismatch: `/opt` retained
the five-minute preparation cap although the migration baseline already selects
WirePlumber `d20cd203` with an explicit maximum of one hour. The separate prefix
now copies the installed policy assets and replaces only `lib/ao-owner.lua` with
that clean baseline. Its SHA-256 is
`5fbedea5a2b6aa44bb911e864e8f66871bdcfe96303c29391d1ba404300333ec`.
The deployment's 900-second allowance is unchanged. Independent Lua checks
reproduce rejection by the old policy and acceptance by the selected baseline;
invalid and excessive budgets still reject. `/opt` and the immutable JLL artifact
are unchanged.

Registered 0.1.3 then reached native Ready and Running on the RTX 3080 and passed
the same-value scalar transaction. Attempt 004 exposed an incorrect argument
order in the integration driver before any parameter mutation; its exact Quit
and cleanup succeeded. The driver now uses the existing F32_LE command surface
and requires each parameter's requested generation to advance beyond its own
pre-submission baseline. An old active generation cannot satisfy the check.

## Ordinary-source report compatibility

The generic AOS owner must preserve the existing source-control-v1 saved-report
contract, including the empty prepared/reset report and final cleanup report.
This is an operational cursor receipt, not scientific recording or an archiver.
Its location is derived from the private invocation remote:
`dirname(remote)/simulator-wfs-report.json` for the selected Classic source.
No executable or generated raw artifact is added to the application.

The initial report must exist before source snapshot Props become visible.
Successful stopped reset and finite completion must save the new generation and
last adopted sequence before advancing the mailbox's report cursor or issuing a
successful acknowledgement. Final reporting follows transport/optical cleanup;
report failures prevent successful bootstrap termination. The source instance,
bootstrap instance and PID bind the record to the actual owner. The report has
runtime-limited retention; tests copy selected receipts into their evidence
stage. There is no durable instrument-state or science-recording claim.

## Selected live integration and observation

Evidence is retained under
`/home/dgamroth/.local/state/classic-registered-20261019`. The complete fresh
`session-integration-008` run passes **42/42** assertions in 3m25.7s with
registered RTC 0.1.4. Its exact unit is
`pipewireao-session@03fff0b17275.service`, invocation
`4548ebf30beb40a4900807740b69a97a`; qualification and final launch receipts
both confirm cleanup. It exercises held Ready, native Start/Stop/Reset,
same-value scalar transaction, offset replacement and restoration with distinct
active generations, resumed samples, native Quit and exact owned cleanup.

All eight observation queues deliver at least two distinct sequences with
validated finite payloads: detector, slopes, flux, validity, demanded, offset,
applied and focal image. The four SHWFS products share acquisition generation 2,
sequence 71. Applied samples have no acquisition identity; focal snapshots can
lag the WFS. Neither is claimed to match the complete WFS tuple.

The integration observer initially required two pool buffers, while capacity-one
queues require three. Its negotiation now matches the GUI's bounded range.
An additional observer SIGSEGV reproduced without the GUI. The test client now
checks completion before triggering, requires Streaming and active links, and
uses the GUI's two acknowledged retirement stages before releasing callback
resources. It passes six eight-stream probes (three plain and three debugger
runs with allocator poisoning), followed by the complete 008 lifecycle run.
No native SDK production patch was made. These results qualify this observer;
they do not establish the precise native crash mechanism or general SDK safety.
Earlier failed attempts 001–007 and their cleanup evidence remain preserved.

A separate GUI trial attaches seven running ndarray streams. Closing that GUI
leaves the native session Running; that session subsequently passes normal
Stop, Quit and cleanup. This proves optional attachment/closure for the selected
profile, not the broader stalled-observer/trajectory or fault/readmission matrix.

RTC 0.1.5 packages the corrected integration client and evidence. Its runtime
`src/` and `ext/` are byte-identical to registered 0.1.4 commit
`572c55311077971e05349bde1149976409da3678`; the full 008 lifecycle evidence is
reused on that explicit basis. The final registered package suite, sealed
relocation and retained-session smoke are recorded after release below.

## Final release identity

| Package | Version | Registered Git tree |
|---|---|---|
| PipeWireAORTC | 0.1.5 | `e63114f59bbb20bf1ad0bfa7aad404f883a2de2e` |
| JuliaFilterGraph | 0.4.0 | `a6c81ed737e4dbf828cdc45ffc21b2f9c9c2c9f3` |
| FilterGraphAlgorithms | 0.7.0 | `2fcfb7675152673c076d9a29adef34ab1be8fff9` |
| FilterGraphPipeWire | 0.1.3 | `683c2e32d16d6889a00c3f985c25f8e72a0af991` |
| FilterGraphIsland | 0.1.2 | `15c9c5ef8dd4222e36f90e5434e3bcabc3b7e182` |
| AdaptiveOpticsSim | 0.1.0 | `ee0a2a24f600954045d08d48971f1ce0d0d61b4b` |
| AdaptiveOpticsSimPipeWireHIL | 0.1.3 | `abe043eab6cd3bb240e83c16792d1bd3466a5320` |
| PipeWireAO | 0.6.18 | `14dcef6fff816e5fc89459aca21cd1742b497be3` |

RTC source commit is `d06010c8a5a3f223a62278714b2cfa647533b558`.
The HIL release is stored in the user-authorized private repository
`DarrylGamroth/AdaptiveOpticsSimPipeWireHIL.jl` at commit
`48407618405ce8e906f245b59fd49d5a9ba5c00e`.
The registry review branch `codex/classic-registration-20261019` is pushed at
`3b7bd02aecb7e4df036ed1bfa6d29d05b93a5c12`. Installed registry local commit
`07641c0f7ec926487e54828a23bc127674e29d18` has identical complete tree
`41bf712fca70f8eaecd010755cf3734ffac4631c`; existing local history is preserved.
Remote default branches have not been promoted or rewritten.

The final scientist application is `/home/dgamroth/workspaces/revolt-classic-rtc`.
Its 30 sealed inputs comprise Project/Manifest, configuration, README and 17 FITS
files; it contains no executable Julia source or path dependencies.

| Application file | SHA-256 |
|---|---|
| Project.toml | `de22a5955984ff131d4cf73bb295747a8727b6c9bb812c13633c561ee5cacbfe` |
| Manifest.toml | `e38333ecf57674956db16e027ce852a6fe61ded3e3190ed3bfb6b67dbe1a1315` |
| deployment.conf | `c62b3790892eaf680d1887ceb11b06d781433e7bd63727a05fef67f550c01ac4` |

Final registered 0.1.5 verification passes **1,993/1,993** assertions in 60
testsets and fresh default-loader checks (CPU 22/22, CUDA 21/21), with
`Pkg.test(...; allow_reresolve=false)` and unchanged Project/Manifest hashes.
See `rtc-0.1.5-verification.txt` and the corresponding three logs in the evidence
root. The actual loaded package is the immutable registered `XnB8N` source.

An exact regular-file copy at `relocated-application` validates in an isolated
depot containing its own packages, registry and compiled cache; only binary
artifacts share the host cache. `isolated-instantiate-0.1.5.log` records successful
installation and sealed profile validation. A prior invocation omitted
`--project` and tested the wrong default environment; its failure is preserved
as `isolated-instantiate-0.1.5-no-project.log`. The corrected invocation passes
without changing the application or its dependency versions.

The first final-launch trial, `gui-session-001`, reached Running. An auxiliary
smoke script then used nonexistent `session-reset` instead of the maintained
`reset` command. Parsing rejected it before a reset request, and the script's
cleanup established native Stopped and exact cleanup with no error. Its log
and terminal receipt are preserved. The script was corrected and all four
command spellings checked before launching a fresh session; no RTC package or
scientific input changed.

## Retained session for GUI review

This section records the initial 10 Hz session. It was subsequently shut down
with exact cleanup and replaced by the
[500 Hz target session](validation/classic-rate-20261019/README.md), which
currently achieves only 280–300 frames/s. The receipts below retain their
original scope and identify the earlier invocation.

The final registered 0.1.5 session is left **Running**, with the GUI attached.
Its final smoke check passes Stop, Reset to generation 2/sequence 0, Start,
all eight advancing observation streams and matching SHWFS acquisition identity.
The operational reset report identifies the actual simulator PID and source
instance, with no failures. Seven GUI ndarray nodes are independently observed
Running; the native session still reports Running after attachment.

| Identity | Value |
|---|---|
| Evidence stage | `/home/dgamroth/.local/state/classic-registered-20261019/gui-session-002` |
| Session UUID | `fcbaf60c-eb5e-4bfa-a815-3ad623ac0b49` |
| Native systemd unit | `pipewireao-session@78b9be40f481.service` |
| Native invocation | `c515aae008e147f2977d0d4acf76f3f8` |
| Simulator PID | `3993476` |
| GPU | RTX 3080, `GPU-ace438b4-a57b-9194-d519-bdcbe42cb770` |
| GUI unit | `pipewireao-gui-classic-20261019.service` |
| GUI PID | `4015903` |

`retained-verification.json` binds those identities to registered 0.1.5, the
unchanged application hashes, GPU process query and active GUI unit.
`retained-observation.json`, `smoke-reset-report.json`,
`retained-final-status.json`, `gui-attached-status.json` and
`gui-attached-graph.json` retain the data/control evidence. Parent logs are
`retained-launch-0.1.5-002.log`, `retained-smoke-0.1.5-002.log`,
`gui-retained-launch-0.1.5.log` and `gui-retained-verification-0.1.5.log`.
Closing the GUI is optional observation only; native Quit owns RTC shutdown.

This completes the requested selected Classic deployment and GUI attachment.
It remains a non-actuating simulation at 10 Hz wall pacing and 500 Hz model
time, using software GUI rendering. No physical-DM, real-time, broader
fault/readmission or calibration-campaign qualification is claimed.
