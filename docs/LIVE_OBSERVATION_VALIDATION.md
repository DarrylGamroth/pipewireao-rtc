# Live HIL detector observation validation

Status: optional observation implementation and bounded CPU software checks are
complete; installed controlled-preparation checks pass. Default
cold whole-trajectory reproducibility and the selected GUI integration remain
open. No new RTC-DEV-006 qualification, cadence or physical-device claim is made.

The current selected increment is isolated in `work/observation-qualified-20261005`
at `/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-systemd-julia`, based on
canonical RTC `f3f0815dc0ffa074e4265aebc51fb07a0d39dac4`. The original dirty
observation candidate is preserved read-only. Earlier sections retain the
historical tests and failed experiments; the final controlled case table below
states the currently demonstrated scope.

## Scope and source admission

The isolated `work/live-observation-20261005` worktrees started from RTC
`03770074b590a73156c664ea0d4ea816b5853921`, GUI `f6b33b7` and HIL adapter
`0960d980b28db36d0d1d6714f7d75791d1233f37`. Original worktrees, the active
native-control migration and existing operator deployments remain untouched.
The increment composes the public capacity-one copy/drop-oldest queue around
raw HIL detector frames; it creates no scientific AO publication protocol.

Package synchronization means the newest **compatible** owner sources, not
unconditionally using every development HEAD. The clean AOS calibration branch
`8b6364cd064ca707006613bab9e14a13b7c1033a` supplies the public calibration
boundary required by the current HIL adapter. A fresh environment using AOS
development HEAD `ed9a3f30f2834662a746961ee3f920b23823d8de` instead fails import:
`AlgorithmGraphs.PreparedGraphCalibrationBoundary` is absent. This is an
existing cross-package compatibility failure, not a consequence of the new
source-buffer option. No local compatibility shim or scientific-owner edit
was introduced.

The sealed earlier Classic/Copper packages contain that boundary, despite
stamping the earlier AOS commit `d30db3f`. Their artifact hashes identify those
bytes; the stamp must not be treated as proof they equal that commit.
Fresh exports must record their selected sources and seal the actual bytes.
Copper's recorded base has a non-exact PipeWireAO `0.6.11` compatibility bound;
it permits fresh resolution to `0.6.16`. No JFG compatibility patch is needed.

| Selected package/source | Revision |
| --- | --- |
| PipeWireAO.jl 0.6.16 | `3545127` |
| PipeWireAO_jll 1.7.0+19 | artifact `02332925c3953742006b7b962621affb654fc265` |
| AdaptiveOpticsCalibration.jl | `f79104ddec1fcd609ea60d5a081f72dfb280ff73` |
| AdaptiveOpticsSim calibration branch | `8b6364cd064ca707006613bab9e14a13b7c1033a` |
| FilterGraphAlgorithms 0.5.6 | committed archive from parent `f2f4cd4e269a63887c6d55f915d97d674fd18687` |
| REVOLT Classic plant | `e0fbdab9a5483d92fa6df5539019624d40b84f1e` |
| REVOLT Copper plant | `cb840cd076ce20a4229bfe82dc1d390f7a1c4f55` |
| HIL adapter 0.1.2 | `15fd37d` |

The temporary FilterGraphAlgorithms archive has no `.git`, so export logs a
non-Git revision diagnostic; the table records its committed origin while
sealed artifact hashes record actual bytes. No dirty scientific-owner changes
were copied or modified to obtain this package set.

## Independent adversarial review

| ID | Severity | Observed defect or risk | Remediation and required evidence |
| --- | --- | --- | --- |
| OBS-001 | High | Replacing stored LinkInfo with a state-only delta discarded passive-link evidence | Retain evidence according to public state/properties change masks. Regression checks include state-only, format-only, missing initial properties and explicit passive=false. |
| OBS-002 | Medium | Export admitted adapter 0.1.1 while invoking the new source-buffer keyword | Require adapter ≥0.1.2 in deployment compatibility and cold export admission; test rejection before export effects. |
| OBS-003 | Medium | Adding an ordinary data loop changes default least-recent loop selection; capture placement was implicit | Explicit capture placement and supported-selector exclusion need actual public context/loop verification, not configuration assertions alone. |
| OBS-004 | High | The proposed 16-character loop name is truncated to 15, so explicit selection and expected thread name cannot match | Use a common short loop/selection/thread name and verify actual native loop selection and thread naming. |
| OBS-005 | Medium | GUI RT driver still selects the critical default data loop, even though queue playback selects its separate loop | Native queue-output selector inheritance after initial full NodeInfo; retire/recreate on selector changes; actual daemon placement remains required. |
| OBS-006 | High | The installed branch rejects matching queue identities because Registry globals do not advertise them | Read bounded owned NodeInfo properties, retain property-delta evidence and fence all endpoint incarnations throughout asynchronous preparation. Sparse-global and live regressions are required. |
| OBS-007 | Medium | GUI whole-object POD decoding silently rejects negotiated fixed ChoiceNone Array/String properties | Use the existing public SPA ndarray parsers in the native adapter. The same negotiated POD fails the old decoder and passes the new parser; Classic successive-frame attachment now passes. |
| OBS-008 | High | Rejected replacement formats retain the previous capture format and can mislabel subsequent bytes | Clear format/pool/queued samples and enter existing failed-observation retirement. Same-byte-count rank-two → rank-three and GRAY8 rejection regressions pass; null notifications still clear and wait. |

OBS-001 through OBS-004 fixes passed independent source review. The native placement test
passes 117 assertions: explicit observer/main selection, repeated unqualified,
empty-property and `data.rt` selection, and actual Linux thread names. It uses
PipeWireAO JLL 1.7.0+19 with RT priority and affinity disabled for this API test.
This closes the selected configuration defect, not installed graph placement.
An arbitrary unmatched class is not covered by the supported-selector claim.
No co-location failure was observed in a running HIL deployment; OBS-003 is a
demonstrated selection risk, not a measured failure.

## Software checks

- HIL fail-before: adapter 0.1.1 rejects `buffers=3` on the parameter helper.
  Pass-after: the public POD decoder reads exactly three source buffers.
- HIL suite with the sealed compatible AOS: 1,313 assertions passed, including
  private-core node publication and held-probe failure/deadline cases.
  Source cardinalities 2, 3 and 64, default 2, malformed choices and bounds are
  checked. These tests do not prove observer isolation.
- RTC SDK final full suite: 1,643 assertions across 71 testsets, including final
  boundary 41, export 152 and native loop selection 117.
- GUI: package-scoped format check, 380 Rust tests, WebAssembly shared-layer
  check, warnings-as-errors Clippy and 117 Julia fixture assertions passed.
  Ten opt-in native live tests remain ignored; they are not integration proof.
- Task-owned Cargo artifacts were cleaned after verification, recovering
  approximately 1.4 GiB. No shared or sibling target was cleaned.

## Open installed acceptance

A fresh sealed Classic FGN CPU export/install completed using the compatible
clean scientific sources and PipeWireAO 0.6.16/JLL 1.7.0+19. The task-owned
`pipewireao-rtcw-classic-observation-v1.service` reached RUNNING on private
remote `rtc-6e386092a509`. The source cursor advanced to sequence 1,088 while
the optional branch reported unavailable, with the exact OBS-006 error
`detector queue endpoints do not share an owner identity`. Read-only NodeInfo
inspection showed both endpoints share `pipewireao.queue.id=3299274-14`.
The core's actual `rtc-data-loop` thread was on CPU 2 and `observer-loop` on
CPU 14. No GUI or observer was attached. This establishes one optional-failure
containment observation, not scientific equivalence or full isolation.
The defect and acceptance checks are tracked in
[RTC issue #3](https://github.com/DarrylGamroth/pipewireao-rtc/issues/3);
the report explicitly concerns this unmerged increment, not canonical main.

The v1 task service was stopped successfully without touching an existing
deployment. A fresh sealed v2 export using the NodeInfo fix reached RUNNING on
`rtc-00d627669b21`, instance `run-tlGZtz`, with the optional branch available.
The HIL adapter source is commit `15fd37d`; the RTC increment's actual bytes
are sealed by the export while the branch remains unmerged. Capture negotiated
three buffers. The native GUI worker first failed because of OBS-007, despite
mapped 247,808-byte samples and queue delivery/completion counters advancing.
After the native parser fix, the same test passed in 0.51 seconds and a separate
reattachment passed in 0.31 seconds. Both require successive sample revisions,
the advertised `observer-loop` selector and a queue driver equal to the owned
GUI capture node. No fixture overlay is involved.

A read-only dump after those attachments showed no remaining GUI nodes, all
three required links and the passive optional input link active, pending depth
one and source-buffer count three. At the first post-success inspection the
queue reported 6,379 publications, 6,319 replacements, 59 deliveries and
completions, and zero backpressure, pool exhaustion, dropped arrivals or protocol
errors. Actual core placement remained CPU 2 / CPU 14 for RTC / observation
loops. These observations do not compare accepted scientific outputs or prove
deadline isolation. Both exports are finite 8,192-exchange demonstrations,
nominal model rate 500 Hz and requested wall cadence 10 Hz; no achieved-rate
qualification follows.

Classic completed all 8,192 exchanges with no reported failure. Its 64-frame
prefix, command bytes, completed summary and deployment state were copied to
`~/.cache/pipewireao-rtcw-live-20261005/classic-v2-evidence.lSg443` before reset
or teardown. Prefix frames preceded GUI attachment: they cannot prove accepted
output equivalence under observation. Pause/status intentionally do not flush
reports; use the owner's `report-ready` generation/sequence evidence rather
than treating the initial empty report as current data.

Copper was exported from the compatible clean owners, installed and admitted
on private remote `rtc-e9654e11a490`, instance `run-mplIUb`, task unit
`pipewireao-rtcw-copper-observation-v2.service`. It reached RUNNING with the
optional branch available; the same native frame test passed (1.24 seconds)
and reattachment on the final GUI source passed (0.72 seconds). After removal,
no GUI node remained. An owner status observed source sequence 117 and RUNNING;
a following read-only dump showed 126 queue publications, two deliveries,
pending depth one, capture buffers three and zero protocol errors. This is
functional integration evidence, not full isolation acceptance.

The first Copper test service incorrectly reused Classic's CPU mask; it was
rejected before startup with `julia CPUs unavailable in inherited affinity`.
The fresh service admitted the package-declared union 2, 4, 6, 10, 14 without
editing sealed content. Both exports log `can't setup mixer` during link setup,
but proceed to RUNNING and copy samples. No cause or harmlessness claim is made
for that warning; queue and scientific-equivalence checks remain distinct.

Independent final source review accepted OBS-005 through OBS-008. The final GUI
diff audit found no further actionable design issue: public SPA/PipeWire names
stay native-only, format rejection shares one primitive, and test repetition
keeps the two format-specific regressions independent. Existing compiler warning
`spa/pod/compare.h:190` (unused C parameter) remains outside this increment.

With the selected clean AOS branch, the main HIL tests (533), model-time tests
(17), node publication (15) and calibration throw case (374) passed. The full
suite's calibration deadline case hit its ten-second WFS completion timeout
once. A fresh isolated retry passed all 374 assertions in 8.1 seconds. The
timeout is retained as an unreproduced observation; no cause or production
regression has been established and no deadline was loosened.

Fresh Classic FGN and Copper JFG exports must retain exact source admission,
three-buffer negotiation, actual loop/driver placement and lifecycle evidence.
Compare accepted detector and command bytes plus Acquisition identities with
the observation disabled, enabled without a consumer, stalled, terminated and
reattached. Exercise optional-link loss/recreation, stopped reset, asynchronous
source replacement and preparation-failure teardown. Preserve unrelated
objects and record queue capacity/counters. A successful viewer or an advancing
counter alone does not establish scientific equivalence.

The ordinary GUI pixel snapshot currently lacks transported Acquisition
identity. A retained image after reset is last-sample data, not evidence of
the new generation. WFS overlays, DM products, science metrics, artifact
adoption and removal of GUI-internal preview generators are separate open work.

The existing systemd Julia PATH failure is tracked in
[RTC issue #2](https://github.com/DarrylGamroth/pipewireao-rtc/issues/2).
An isolated transient service may supply a unit-local PATH without changing
the user manager or an existing service.

## Canonical native admission qualification — in progress

The bounded integration branch `work/observation-qualified-20261005` starts at
canonical RTC `f3f0815dc0ffa074e4265aebc51fb07a0d39dac4`. The dirty observation
candidate remains read-only. The integration retains native RunnerClient
`Ready` admission before optional preparation and ingress, source pause before
optional cleanup and consumer teardown, and unconditional control service.
Retirement after optional link loss remains permanent within that lifecycle;
recreation requires a fresh admitted lifecycle.

Evidence is under `~/.cache/rtc-observation-qualified-20261005`. Fresh exports
retain every exchange: 256 frames, 256 exchanges, a 500 Hz scientific model,
and deliberately paced 10 Hz wall execution. Classic exposure is 1,896,000 ns;
Copper exposure is 2,000,000 ns. The old rejection of finite paced runs failed
in `finite-pacing-before.log`; the unchanged gate passes three assertions in
`finite-pacing-after.log`. Existing total/frame/rate/storage bounds remain.
Because all 256 exchanges are the retained warmup prefix, there are **zero
post-prefix timing samples**. These cohorts make no achieved-rate or latency
qualification claim.

The four disabled/enabled Classic FGN and Copper JFG exports use task-owned
copies of the recorded bases. Only the native runner is replaced before
resealing: SHA-256
`71549afe3ca2f235c1264dafc0f18602936de861ad5e549cbc1b70c7c330fb4d`.
`source-staging.json` records the original runner, descriptor, provenance, and
unchanged scientific artifact hashes. Original installed bases are immutable.
Dirty plant workspaces are not copied: clean commit archives supply Classic
`e0fbdab9a5483d92fa6df5539019624d40b84f1e` and Copper
`cb840cd076ce20a4229bfe82dc1d390f7a1c4f55`. FilterGraphAlgorithms is the
`julia/FilterGraphAlgorithms` subtree archive from JuliaFilterGraph
`f2f4cd4e269a63887c6d55f915d97d674fd18687`. The clean adapter is
`15fd37d97ca9ff6b62d97a149e90ca1ed4368662`; AOS is
`8b6364cd064ca707006613bab9e14a13b7c1033a`; AOC is
`f79104ddec1fcd609ea60d5a081f72dfb280ff73`; PipeWireAO is
`354512752bc35fd9fe59fe16cc1a0585668107c6`. Paired exports have identical
calibration files and `hil/plant.toml`.

Current software checks pass: deployment SDK 2,020 assertions in 77 testsets;
HIL owner protocol 92; sustained metrics 99; sustained run 132. Initial live
harness failures (inherited CPU affinity and runtime directory permissions)
were rejected before owner startup and leaked no task-owned processes.

The scientific and lifecycle acceptance gates remain open:

- Classic disabled and enabled pilots 3 and 5 retain all 256 frames/commands,
  source report generation 1 and sequence 256, and identical raw data files.
  Pilot 4 and the first native-reader cohort differ from the disabled baseline
  within the retained dataset. A second disabled cohort retained all 256
  exchanges and has byte-identical detector/command files to the first disabled
  cohort. Attribution of the observer-cohort differences remains unresolved;
  these two baselines do not establish universal determinism.
- A Julia public Stream reader negotiated required Acquisition metadata and
  exact format, but delivered no samples and one variant returned EIO on
  `trigger_process!`. It is a compatibility observation for that reader
  configuration, not proof that all asynchronous Julia streams are unsupported.
- A development-only native public `pw_stream`/SPA reader with `RT_PROCESS`
  captured sequence 2, generation 1 and domain
  `a0000000000000000000000000000000`. Its full payload hash equals that exact
  retained owner frame. Only one delivery completed; repeated delivery,
  stall/kill/reattach, and generation/reset acceptance are still pending.
- GDB catches a private-core SIGABRT during queue module teardown. The trace is
  `free → pw_properties_free → pw_stream_destroy → queue impl_destroy →
  pw_impl_module_destroy → pw_context_destroy`. Selected queue module SHA-256
  is `b702cea6b122c834f413b7dfbea65424b762a4d337d4f6c20253a0059f845d8f`.
  `cohorts/classic-pilot5/core-gdb.log` preserves the native backtrace. A
  separately attached simulator exited normally. Supervisor exit 0, stopped
  state, and absence of owned processes therefore do **not** establish native
  lifecycle success. The disabled Classic cohort has no allocator-abort
  warning. Native queue review and remediation are prerequisites to acceptance.
- The first missing-queue negative fixture failed before admission: without
  the queue, its required observer-loop thread never materialized. All owned
  processes and runtime children were removed. This is a rejected qualification
  fixture, not a passed optional-preparation gate. A separately sealed v2
  fixture also omits that unused placement requirement so the required graph
  can reach the actual optional-preparation timeout.
  The v2 cohort passes that gate: admission records observation unavailable
  with the bounded timeout, yet all 256 detector frames and commands complete
  and are byte-identical to the disabled baseline. Supervisor exit is 0;
  all owned processes and runtime children are absent, with no allocator error.
  `cohorts/classic-missing-queue-v2/comparison.json` records the exact hashes,
  admission state and teardown evidence. Its detector hash is
  `a66dda8b2f559a2cf6a621dc9f82507be53a66a8acd647ec3d017f1ef5e5910a`;
  command hash is
  `78e457e40809fe61f402c78d72d368c1d51e5a2c747cc39e59fa3c1b1d0e4541`.

No scientific algorithm, gain, model timing, calibration coefficient, HEART
vendor source, or transport implementation is changed by this integration.

The native queue prerequisite was independently reviewed, corrected and
published as `2cd248e9960dbddd352ad24e6cf37911fa877d8e`. Selected installed module
SHA-256 is now
`08b4cd64c9da848937a3124c606ba7e2504e87869b1be625ad3678a615563149`.
The native core library is unchanged. The queue project's five release and
five sanitizer tests pass; its review records the pointer retirement invariant
and a separately reproduced fenced stats callback defect. Fresh task-owned
disabled/enabled exports and installations with suffix `queue-fixed` include
that exact module identity in sealed provenance. Every prior scientific
artifact digest is unchanged. Earlier cohorts retain their original package
and module identity; they are not retroactively qualified by this publication.
Corrected-module RTC teardown, metadata delivery and isolation reruns are in
progress.

`classic-fixed-unattended` passes the complete retained-output comparison:
all 256 detector frames and commands match the disabled baseline hashes above,
observation remains available, and source generation 1/sequence 256 is reported
complete and ready. Supervisor exit is 0, all owned processes and runtime
children disappear, and the combined log contains no allocator error. The next
instrumented teardown attaches GDB only after science completion and retained
file capture, to establish the private core's exit result directly.

`classic-fixed-native` also preserves both complete 256-record scientific data
files. Two samples, sequences 2 and 3, have exact generation 1/domain identity,
full payload hashes and Header PTS matching the corresponding retained owner
records. Driver/loop evidence separates the required source/capture graph
(driver 23, `rtc-data-loop`) from playback/observer (driver 57,
`observer-loop`). Repeated delivery still fails this reader configuration:
598 triggers and 597 RT trigger completions produce only two deliveries while
256 publications and 253 replacements accumulate, with zero queue protocol
errors and three buffers on each side. This is stronger evidence than an
advancing GUI snapshot, but does not qualify repeated observation delivery.
GDB attached after all scientific data were captured reports the exact private
core process 3524475 exited normally. Supervisor exit is 0, no allocator error
is logged, and all owned/observer processes and runtime children are absent.
The public-reader property differential against the maintained native queue
test is the next bounded compatibility measurement; no production scheduling
or queue algorithm change follows from this observation alone.

The public-reader property comparison `cl-fixed-nativeprops` retained the native
test's `node.virtual=true` and `node.pause-on-idle=false`, without the GUI pull
properties `node.supports-lazy` and `node.supports-request`. It still delivers
only two valid samples while RT completions advance, so that property hypothesis
is rejected. Whole scientific equivalence fails in this cohort: 234 detector
records differ, first at frame 14; 241 command records differ, first at 16.
Frame 14 has 140 different pixels (maximum 8 ADC codes), while frame 15 is
identical and frame 16 differs by one pixel/code. Thus the first detector
difference precedes a recorded command difference. This observation motivates
the authorized public cleanplant replay of identical recorded commands; it does
not establish an observer-coupling or model-nondeterminism cause. GDB reports
the exact core 3526029 exited normally; no owned process or runtime child remains.
The earlier overlong cohort name failed before admission at the Unix socket
108-byte bound and leaked no owned process; the shorter-name rerun preserves
the rejected fixture evidence.

Copper `co-fixed-unattended` also completes all 256 exchanges and has a normal
GDB-observed private-core exit (3527084), supervisor exit 0 and no surviving
owned process/runtime child. Whole-output equivalence fails: 89 detector
records and 101 commands differ from `copper-disabled`, first at sequence 156.
Both packages retain the same plant SHA-256
`583548bfc4cd16239db1ca8c4b8dcfd97eda92712c657e1215d7340f08504e2a`.
These cold Copper cohorts achieve approximately 3.33 wall exchanges/s with
about 513 missed deliberately requested 10 Hz wall periods. Their scientific
model is still 500 Hz, all exchanges are retained, and there remain zero
post-prefix timing samples; this is not rate qualification.

Logs retain missing D-Bus support, initial queue `no format given`,
`can't setup mixer`, and dependency-precompilation version warnings. Repeated
metadata delivery remains open; these warnings have not been dismissed as a
demonstrated root cause or declared harmless to every reader configuration.

Copper `co-fixed-native` preserves all 256 detector records and commands exactly
against the disabled baseline: detector SHA-256
`14e3c7227296a61a4a3b21cd12651fb70fca6e7818bf07be2807bb401e4d1123`,
command SHA-256
`3914dfef36885626507f3210a79e7f8ad77bd76bc6b38d359d39f19fb057b3a4`.
The required graph completes at generation 1/sequence 256, but the public
metadata reader delivers zero samples during its 30-second acquisition window:
598 triggers, 597 RT completions, 97 queue publications, 96 replacements,
three buffers on each side and zero protocol errors. Required source/capture
driver is 38 on `rtc-data-loop`; playback/observer driver is 55 on
`observer-loop`. GDB reports the private core 3529691 exited normally; all
owned and observer processes and runtime children disappear. A passing full
science comparison in this cohort does not qualify observation delivery or
explain the failed unattended comparison. The cleanplant recorded-command
discriminator remains in progress, with seeds, graph, timing and commands
unchanged and digest-only output.

The two fresh-process Classic public cleanplant replays (`replay1.json`,
`replay2.json`) both reproduce every baseline detector record and all 256
per-frame hashes exactly. They use the unchanged installed plant, 2,000,000 ns
model period, seeds, maintained `prepare_science` warmup/reset helper and exact
recorded metre-OPD command file SHA-256
`78e457e40809fe61f402c78d72d368c1d51e5a2c747cc39e59fa3c1b1d0e4541`.
Both output detector digest
`a66dda8b2f559a2cf6a621dc9f82507be53a66a8acd647ec3d017f1ef5e5910a`,
with zero differing records. No PipeWire connection or transport is started;
the instrument only calls the public scientific boundary step/adopt APIs and
records digests. Model-only nondeterminism was not reproduced by these two
fixed-command cases. This does not prove universal determinism or establish
the cause of the intermittent live scientific differences. All live cohorts
and replay processes have ended; assigned cores are released for the separate
HEART qualification before further observation workloads.

### Historical acceptance status before QRA001

| Gate | Observed result | Status |
| --- | --- | --- |
| Native Ready admission before optional preparation/ingress; unconditional controls | Integrated on canonical native client; SDK suite 2,020 assertions passes | Software checks pass |
| Sparse globals, NodeInfo owner identities and endpoint fences | Canonical regressions and successful live boundary admission | Pass |
| Optional preparation failure preserves required science | Missing-queue v2 timeout; all 256 records equal baseline; clean teardown | Pass for this fixture |
| Separate required and observer drivers/loops | Public NodeInfo plus admitted placement snapshots | Pass for recorded cohorts |
| Corrected queue allocator-clean RTC core teardown | GDB normal exits in Classic/Copper; no surviving owned resources | Pass for recorded cohorts |
| Full scientific equivalence across observation conditions | Several exact full matches; retained Classic/Copper failures also occur | Open; cause unresolved |
| Repeated metadata-aware observation delivery | Classic two valid records; Copper zero; trigger completions continue | Fails current reader configurations |
| In-window stall/kill/reattach and generation/reset | Instrument prepared; full delivery prerequisite remains open | Pending |
| Link loss/endpoint replacement preserve required graph | Deterministic boundary regressions; actual finite science lifecycle cases remain | Pending live gate |
| Recreation after retirement | Requires fresh admitted lifecycle; no automatic repair implemented | Pending live recreation proof |

These results do not close RTC issue #3 or establish physical validation,
scientific convergence, cadence or latency qualification.


## QRA001 correction and fresh complete-frame qualification (2026-10-06)

The separate native queue investigation confirmed callback starvation from
retained unused output loans, independently of the plant and controller. The
corrected core-plugin commit is `163ea034dbfb4f41fabb7f0cfd218b0908a0ca75`.
The release queue module installed by the primary agent has SHA-256
`8f953946733fafa3aaa766518ba3c2128fd2e6977babe3b8d478050f20664835`;
the native core library remains
`083da9b7c347a40e8ce03cc1332c06774cbf766fdd71fe36010233e6d9096387`.
The separate queue review/validation documents retain mapped native traces,
identical-fixture fail-before (64 source/64 required/1 optional receipt),
pass-after (64/64/64), public Pause/Start, Header-only and same-loop controls,
and debug/release/ASan+UBSan suites of 10/10 each. These synthetic public-API
software gates do not establish scientific observation isolation.

Four fresh task-owned exports and installs carry `-qra-fixed` suffixes. Only
provenance is changed from the recorded finite exports, and every other sealed
artifact hash is checked unchanged before maintained resealing and installation.
The immutable originals are preserved. The qualification installation ledger
is `~/.cache/rtc-queue-acquisition-20261006/installation.json`; the fresh export
log is `~/.cache/rtc-observation-qualified-20261005/reseal-qra-final.log`.

Fresh Classic results retain all 256 exchanges at the original 500 Hz model
and deliberately requested 10 Hz wall pacing:

| Cohort | Detector SHA-256 prefix | Command SHA-256 prefix | Observation result |
| --- | --- | --- | --- |
| `cl-qra-off`, observation disabled | `2912f22f` | `7ac1d859` | No optional boundary or reader |
| `cl-qra-idle`, enabled unattended | `a66dda8b` | `78e457e4` | No reader attached |
| `cl-qra-native`, enabled with public native reader | `a66dda8b` | `78e457e4` | 255 receipts, sequences 2–256, zero metadata/payload mismatches or reader errors |

The native reader attaches after admission, so sequence 1 is not an eligible
receipt. Every delivered sequence is checked against its complete retained
UInt16 wire frame, Header sequence/PTS/flags, 96-byte Acquisition domain,
generation and exposure. The correction closes the prior repeated-delivery
failure for this Classic reader cohort. It does not by itself qualify Copper
or stall, death, reattachment and reset.

All three fresh Classic cohorts have supervisor exit 0, GDB-observed normal
private core exits and no surviving owned/observer processes or runtime
children. No allocator error is logged. Their full paired scientific
comparison remains **failed**: disabled versus either enabled case differs in
234 detector frames (first 14) and 241 command records (first 16). The fresh
disabled trajectory exactly reproduces the previously observed alternative
`cl-fixed-nativeprops` trajectory, showing observer attachment is not a
necessary condition for that alternative. Both fresh enabled runs reproduce
the original disabled trajectory. No cause is established from those matches.

A public cleanplant replay of the alternative disabled command timeline
(`replay-qra-off.json`) differs from its retained live detector timeline in
only eight frames: 14, 16, 19, 28, 141, 180, 225 and 226. The other 248 frames
are exact. The replay detector digest is
`2edd29848cf455fbeac1f1619d5e4eec499b79feddd12f6c74c9c9e7100b0434`.
This differs from the two exact original-command replays and motivates a
bounded development trace of the **actual public graph command input** before
frame generation and after adoption, including active command sequence and
Acquisition generation. Copies are preallocated, with hashing and file output
after acquisition. The instrumented source is task-owned and separately sealed;
no production scientific model or numerical algorithm has been changed.

Whole trajectory equivalence remains an acceptance gate. Thresholds, seeds,
calibration, frame association and numerical algorithms have not been adjusted
to turn a failed comparison into a pass. These complete finite cohorts have
zero post-prefix timing samples and make no cadence or latency claim.


The separately sealed `cl-qra-trace` development cohort reproduces both complete
alternate disabled artifacts exactly (`2912f22f` detector and `7ac1d859`
command). Its retained public graph input after each adoption equals the
recorded command file byte-for-byte, and the input before every subsequent
frame equals the prior adopted input. All 256 active command sequences are
exactly 0–255, generation is 1 and the initial command is zero. Thus an
adoption-versus-recorder mismatch is not reproduced in this tested alternative.
The trace ledger is `cohorts/cl-qra-trace/adoption-check.json` in the task cache.
No owned process remains after normal teardown.

Read-only source inspection identifies a further **hypothesis**: maintained
CPU optical repeated transforms use `FFTW.MEASURE` (AOS Backends arrays.jl),
including both Shack–Hartmann and pyramid owners. Different cold plans can
change floating arithmetic; nonlinear stochastic/ADC processing could then
change detector codes. This has not yet been demonstrated as the source of
these differences. The primary agent authorized a separate public FFTW wisdom
capture/import experiment with public photon-rate output hashes. Instrumentation
uses explicit FFTW dependency placement and public `Pkg.resolve`, verifying
that every locked Manifest dependency identity remains unchanged. No production
planning policy, science algorithm or comparison threshold is changed.


Fresh Copper `co-qra-off` reproduces all 256 original disabled detector and
command records exactly (`14e3c722` / `3914dfef`). Enabled unattended
`co-qra-idle` completes with detector digest
`5d4e64af7c34c8d48969d0881690b25ff5649cda2fa5a31b554e203cf894382a`
and command digest
`46298820553fe7ccc58bd2956f7aee07ea0003e96d272780425247c9a397dabf`:
89 detector frames and 101 commands differ, first at sequence 156.

Fresh Copper `co-qra-native` now delivers **all 256 receipts**, sequences 1–256,
with zero retained-payload or Acquisition-identity mismatches and zero reader
errors. The bounded reader window is 90 seconds for the slower Copper cohort;
all frames remain retained. This closes repeated delivery for the recorded
Copper reader configuration after QRA001. Whole trajectory equivalence remains
failed: 91 detector records differ (first 37) and 220 commands differ (first
37), detector digest
`a6ce12171e67d979aca345fb8cb678f94bd6fdc0bc1f481f60ec35ef07b73ffe`,
command digest
`f1ffc9fdb709e4fc2ab9985d068d1233c78b6c94b48f0086a870848f3a53fab0`.
Each fresh Copper cohort has supervisor exit 0, normal GDB-observed private
core teardown and no surviving owned or observer process/runtime child.

These delivery passes supersede the earlier two/zero-receipt outcomes for
these specific native reader cohorts. They do not supersede the failed science
comparisons or qualify GUI metadata handling, timing or physical hardware.


The development-only `cl-wisdom-cold` disabled cohort produces a third recorded
Classic trajectory (`f82e5dd1` detector, `1ff66afa` commands), with all 256
public photon-rate output hashes retained. Its exported FFTW wisdom file is
SHA-256 `f55df03492694cfc7762f94bb99ce812fed005ed2f0dff15ec568350ab5cb856`.
Two cold public model replays (`replay-live-wisdom1.json` and
`replay-live-wisdom2.json`) import that wisdom and replay its exact recorded
commands. Both reproduce **all 256 photon-rate hashes and noisy detector
frames exactly**. The first replay's exported wisdom file has a different
byte digest from the input because its line order differs, but every one of
95 nonempty canonical entry lines is identical, with no missing or additional
entry. This demonstrates repeatability of this controlled wisdom/input case;
a no-import differential and live paired imported-wisdom cases are still
needed before attributing the earlier differences to planning.

A separately built development reader revision additionally requires and
records the exact current Acquisition version, 96-byte allocation and explicit
MONOTONIC timebase. Its mandatory current-version ParamMeta negotiation remains
unchanged; prior cohort metadata assertions are preserved as originally run.
The new reader compiles with `-Wall -Wextra -Werror` against the installed public
SDK, using the existing system libcrypto shared library. An initial compile
attempt lacked the libcrypto development symlink; that setup failure and final
successful build log are retained. No reader-side transport or science
implementation has been introduced.


## Controlled preparation experiments and current case status

The no-import Classic cold replay (`replay-cold-no-wisdom.json`) keeps the exact
same recorded commands, graph, seeds, calibration and 2 ms model period as the
two imported-wisdom replays. Its exported wisdom entry set differs: 13 entries
occur only in the recorded live preparation and 20 only in the no-import
preparation. All 256 public photon-rate hashes differ. Sixteen noisy detector
frames differ, first at frame 14 with 140 pixels and at most eight ADC codes;
most other differences are a single pixel/code. This is **observed** numerical
repeatability dependence on the prepared transform choices for this bounded
case. The precise stochastic/quantization branch responsible for each code
change has not been traced, and prior cohorts did not retain their plans, so
this does not prove the cause of every historical divergent cohort.

The fresh separately sealed Classic `wisdom-fixed` packages import the same
recorded wisdom through the public FFTW API before the unchanged model is
prepared. No production planning policy is changed. Both disabled
`cl-wisdom-off` and enabled unattended `cl-wisdom-idle` produce all 256 frame
and command records exactly (`f82e5dd1` / `1ff66afa`), with identical public
photon-rate hashes and canonical wisdom entries.

`cl-wisdom-stress` also produces those exact full trajectories while its public
reader is pull-stalled at 2–4 seconds, suspended with SIGSTOP at 6–8 seconds,
killed at 10 seconds and reattached at 12 seconds. All affected source frames
remain retained. The first reader provides 66 valid receipts; the replacement
provides 134. Every receipt matches its own retained source frame and explicit
current Acquisition version 2, 96-byte allocation, MONOTONIC timebase, domain,
generation, exposure, Header sequence/PTS and complete payload. There are zero
reader errors or metadata/payload mismatches. The recorded required lifecycle
remains Running through these phases and completes all 256 exchanges.

`cl-wisdom-reset` retains a complete 256-frame generation 1 and complete
256-frame generation 2 after acknowledged source pause, Ready reset (sequence
0, generation 1→2) and explicit restart. Both complete detector/command
trajectories match each other and the controlled disabled reference exactly.
The first public reader supplies 255 generation-1 receipts, and the fresh reader
supplies 256 generation-2 receipts, with zero mismatches/errors and no old
generation in the second reader. Generation-aware validation uses each
generation's own retained publication timestamps and payloads.

`cl-wisdom-loss` destroys only the identified optional passive source→queue
capture link through the public task-private link API. Required Node/Link IDs
and object serials before/after are unchanged. The optional boundary retires
permanently with `optional detector link removed`; required Runner state remains
Running, source progress advances from 6 to 88 at retirement and completes 256.
All detector/command records match the controlled disabled reference exactly.
The next fresh admitted lifecycle recreates an available optional boundary;
this is explicit fresh lifecycle recreation, not automatic repair.

Each of these completed controlled Classic cohorts has supervisor exit 0,
normal GDB-observed private core teardown, no allocator error and no surviving
owned/observer process or runtime child. These experiments use the original
500 Hz model with deliberately requested 10 Hz wall pacing and all finite
exchanges retained; zero post-prefix timing samples and no achieved-rate,
latency, convergence or physical-hardware qualification claim follow.

| Gate | Current recorded result |
| --- | --- |
| Native Classic/Copper repeated metadata delivery after QRA001 | Pass in full retained cohorts (255 eligible Classic, all 256 Copper receipts) |
| Default cold whole scientific repeatability | Failed comparisons retained; transform preparation is an observed numerical reproducibility dependency |
| Controlled identical Classic preparation: disabled versus enabled unattended | Pass, all 256 frames and commands |
| Controlled Classic stall/death/reattachment | Pass, all 256 frames and commands; exact metadata/payload association |
| Controlled Classic paired reset | Pass, 256+256 frames/commands and generation-aware receipts |
| Controlled Classic optional link retirement | Pass, required identities and whole trajectories preserved |
| Controlled Classic same-name endpoint replacement | Pass, required identities and whole trajectories preserved; permanent retirement |
| Controlled Copper comparison/stress/reset | Pass, all 256 frames/commands; reset retains 256+256 and generation-aware receipts |
| Controlled Copper optional link retirement | Pass, required identities and whole trajectories preserved |
| Controlled Copper same-name replacement | Pass, required identities and whole trajectories preserved; permanent retirement |
| GUI candidate | Preserved read-only; selected native parser/loop fixes are separate from unrelated presentation changes; no new GUI target built |

The controlled preparation experiments remain distinct from production planner
policy and from the unresolved Julia async-reader compatibility configuration.


`cl-wisdom-swap` completes the same-name replacement case. Only optional
playback node 18/serial 18 is destroyed through the public task-private CLI.
The optional boundary retires while the Runner remains Running and source
sequence reaches 88. A genuine replacement loaded from the installed queue
module by task-owned CLI process 3600591 exposes the same output name with
new node 54/serial 61 and owner `3600591-22`. The SDK derives that owner identity;
the fixture does not forge it. No automatic input relink occurs. Required
Node/Link IDs and serials are unchanged, and every detector/command record
matches the controlled disabled reference. Replacement owner, private core and
supervisor exit normally; no owned process/runtime child remains.

Controlled Copper `co-wisdom-off` and `co-wisdom-idle` both reproduce all 256
original disabled detector/command records exactly (`14e3c722` / `3914dfef`).
`co-wisdom-stress` also preserves those full artifacts through the same bounded
in-window pull stall, process suspension, death and reattachment phases. Its
first reader supplies 20 receipts and its replacement 221, with zero reader
errors or own-retained-payload/identity mismatches. The stricter current-version,
96-byte and MONOTONIC assertions pass. Core and supervisor exits are normal,
and all owned/observer processes and runtime children are gone.

`co-wisdom-reset` retains complete 256-frame generations 1 and 2. Both
complete detector and command artifacts match the controlled disabled reference
exactly. Each reader supplies all 256 receipts from its expected generation,
with no mismatches, reader errors or generation leakage. Source pause and Ready
are acknowledged before reset to generation 2/sequence 0 and explicit restart.

`co-wisdom-loss` removes only optional passive link 53. The Runner remains
Running, source sequence advances from 3 before removal to 30 at retirement,
and completes all 256 exchanges. Required Node/Link identities and serials
remain unchanged, the boundary permanently reports unavailable, and both
whole-trajectory artifacts equal the controlled disabled reference. Core and
supervisor exit normally and no owned process or runtime child remains.

`co-wisdom-swap` starts with an available boundary in a fresh admitted lifecycle
and destroys only optional output node 18/serial 18. The boundary retires at
source sequence 28 while required Runner state remains Running. A genuine
installed queue loaded by task-owned CLI process 3618798 exposes the same
output name with new node 52/serial 59 and owner `3618798-22`; no automatic input
relink occurs. Required Node/Link identities and serials are unchanged. Every
retained detector and command record equals the controlled disabled reference.
Replacement owner, private core and supervisor exit 0; all owned processes and
runtime children are gone. The earlier default cold divergent Copper
comparisons remain failures and are preserved unchanged.

## Final bounded evidence and remaining qualification

The task cache is
`/home/dgamroth/.cache/rtc-observation-qualified-20261005`. Its final
`final-observation-evidence.json` SHA-256 is
`2d9696272cf7e73289b995c1a51c09aa8c9a881f9bce422de16bf8339b88fce6`.
The strict recorder `record_final_observation_evidence.py` independently asserts
all complete datasets, expected generations, normal private-core/supervisor
exits, absence of owned PIDs/runtime children, required identities for
retirement/replacement, and every reader sample's full metadata and payload.
`final-observation-evidence-check.log` records exit 0: **12 controlled cases,
3,584 retained science frames across complete generations, and 1,464 exact
metadata-aware receipts**. The ledger includes actual source-file, installed
package/provenance, instrument, log and full dataset hashes. It identifies the
native runner SHA `71549afe` and installed QRA001 module SHA `8f953946`.

All cases keep the original 500 Hz model and original calibration/seeds, with
requested 10 Hz wall pacing. Exposure remains owner-defined (Classic 1,896,000
ns; Copper 2,000,000 ns). The initial ledger script incorrectly assumed both
exposures equal the model period; its assertion failure is preserved in
`final-observation-evidence-check-before.log`. The final assertion checks each
receipt against its own owner's retained exposure, preserving both original
values. No source exposure or acceptance threshold changed.

The recorded SDK full-suite log `sdk-tests-final.log` contains 2,020 passing
assertions in 77 testsets, including selected observation boundary, loop,
cleanup, export and native-admission checks. Earlier 1,810/76 count summaries
were incomplete; the final count is the sum of all emitted passing testsets.
Negative YAML duplicate-key diagnostics and non-Git archive revision messages
are retained. Earlier standalone HIL wrapper attempts incorrectly isolated a
fixture that explicitly references `Main.HILOwnerProtocol`; those setup failures
are preserved rather than counted as successful suite completion. Fresh final
Main-scoped checks run serially on CPU 12 through the selected absolute Julia
executable and minimal PATH all exit 0: owner protocol 92, metrics 99 and
sustained executor 132 assertions (323 total). Exact commands and fresh log
hashes are retained in `final-pure-hil-checks.json`.

This bounded implementation is ready for independent review and selective
integration. **RTC issue #3 remains open:**

- Default cold whole-trajectory reproducibility retains failed comparisons.
  The public wisdom-conditioned cases demonstrate isolation under identical
  transform preparation; they do not select or change production FFT planning.
- Selected GUI native parser/loop fixes remain in the original read-only
  candidate. Historical GUI tests and pixel display are not metadata-aware
  acceptance or a newly qualified selected integration.
- The recorded Julia async-reader EIO/zero-delivery configuration remains an
  unresolved compatibility finding. Native public C instrumentation establishes
  the stated queue/metadata behavior without replacing RTC science or claiming
  all Julia Stream configurations unsupported.
- Achieved-rate, latency, hard real-time isolation, convergence and physical
  hardware validation are not established by these finite paced CPU cases.

Optional link loss retires this lifecycle permanently. Only a fresh admitted
lifecycle recreates the boundary; no automatic repair has been implemented or
qualified. All live cohorts have ended and the assigned science CPU window is
released. No unrelated operator services or source candidates were changed.
