# Minimum remaining integrated native qualification

2026-10-06. Independent read-only adjudication; execution plan only, no closure.
Reviewed RTC `e36d395e4d2f6cb29c8b59573295f75aae518cb9`, GUI
`eaa659b4b50178f30cc2db10a55a7eb29f791631`, and the current cache records.
Artifact worktree: `rtc-bootstrap-allocation-review`, initially clean at
`cc0ecebc722efbc73d31d5263f1fc6d8d7fda545`. Only this document is added.
No build, SCI, tuning or production edit. Existing GUI executables were invoked
with `--list` only, pinned to CPU15. Other evidence is inspected, not rerun.

Stable review items (all high-confidence observed source/evidence gaps, not new
production defects): **FINAL-Q001**, high, no service-attach mode in the current
qualifier; **FINAL-Q002**, high, cached HEART/observation drivers still use retired
authority; **FINAL-Q003**, medium, installed calibration/correction and GUI
sample-stall/rendered gates remain distinct from passing synthetic transport.
Disposition: primary-agent adjudication and the bounded harness/qualification
work below; no automatic production remediation.

## Acceptance map

All ten issue bodies were read through GitHub during this review or the immediately
preceding JFG review. “HEART #5” below means **RTC issue 5**, not a separate
HEART repository issue. Issue 2 is closed; the other nine remain open.

| Issue | Reusable evidence; minimum outstanding acceptance |
| --- | --- |
| [RTC 2](https://github.com/DarrylGamroth/pipewireao-rtc/issues/2) | Closed absolute-Julia installer/generated-service proof. Do not redo the old PATH failure. Verify final installed wrappers still select the same executable and service launch uses it. |
| [RTC 5](https://github.com/DarrylGamroth/pipewireao-rtc/issues/5) | Unchanged real Classic/Copper vendor process tests, 60 checks each, and earlier installed reset cycles are retained. Final installed calibration **and correction** consumers still need native child/generation/health and restoration checks. |
| [RTC 6](https://github.com/DarrylGamroth/pipewireao-rtc/issues/6) | Reuse native lifecycle private fixtures. Actual Classic/Copper FGN/JFG and unchanged HEART admission, held/faulted state, authoritative cursors, supported reset or explicit calibration-reset rejection, and cleanup remain installed gates. |
| [RTC 7](https://github.com/DarrylGamroth/pipewireao-rtc/issues/7) | Reuse 161 native action assertions, full-width wire/size/inactivity and restoration fixtures. Qualify actual deployed action sequence/capture artifact/restoration against frozen inputs. Rust Collect and Julia Capture are distinct callers. |
| [RTC 8](https://github.com/DarrylGamroth/pipewireao-rtc/issues/8) | Reuse exact public endpoint/two-controller/capacity/partial-result tests and reviewed GUI adapter. Final installed operator control/property/parameter adoption, source ordering, pending status and cleanup remain; discovery and observer claims stay separate. |
| [RTC 4](https://github.com/DarrylGamroth/pipewireao-rtc/issues/4) | Duplicate names, stopped sessions, stale/permissions/replacement and retained read-only selection already have private-core evidence. Exercise the actual picker/adapter against installed published sessions; verify exact identity and observation remote, no mutation on listing/selection, no lifecycle ownership by GUI. |
| [RTC 3](https://github.com/DarrylGamroth/pipewireao-rtc/issues/3) | Sparse Registry/full NodeInfo, rejection/replacement, bounded queue, optional loss and controlled-FFTW trajectories already have evidence. Final native deployments still need Classic FGN **and Copper JFG** GUI negotiation/placement, rendered view, stalled/terminated/reattached consumer and exact required trajectory/lifecycle comparison. |
| [PipeWireAO 1](https://github.com/DarrylGamroth/PipeWireAO/issues/1) | Released FIFO and later native queued/starved-output tests are not to be reinvented. Selected JFG source has exact short 352-callback proof; connected target/near-limit/overload/recovery remains separate. |
| [RTC 9](https://github.com/DarrylGamroth/pipewireao-rtc/issues/9) | Final source retirement/bootstrap/private fixtures exist. Complete installed foreground **and user-service** matrix, current consumers, numerical/acquisition/allocation evidence, timeout reconciliation, final source/release/inventory review. JFG31 is explicitly not a prerequisite. |
| [JFG 31](https://github.com/DarrylGamroth/JuliaFilterGraph.jl/issues/31) | Separate CPU/CUDA/HIP investigation; see JFG `docs/ISSUE_31_QUALIFICATION_REVIEW.md`, review commit `0a8d79a`. Do not fold it into native qualification or silently close it with CPU lifecycle results. |

The literal RTC9 installed matrix is Classic/Copper × FGN/JFG/unchanged HEART
in foreground and user-service operation: six profiles in each launch mode.
Do not silently replace that with two representative profiles. Equivalent
covered clauses can reuse evidence; an omitted profile needs explicit primary
adjudication and an honest remaining limit. No physical-device qualification is
requested or implied by this matrix.

## Available artifacts and non-ready harnesses

Use these abbreviations in the commands below, with actual absolute paths:

```sh
RTC=/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-native-controls
GUI=/home/dgamroth/workspaces/codex/pipewire/pipewireao-gui-native-rtc
FINAL=/home/dgamroth/.cache/rtc-native-final-deployment-20261006
CONTROL=/home/dgamroth/.cache/rtc-live-controls-20261005
OBS=/home/dgamroth/.cache/rtc-observation-qualified-20261005
JULIA=/home/dgamroth/.julia/juliaup/julia-1.12.7+0.x64.linux.gnu/bin/julia
GUI_TEST=/home/dgamroth/workspaces/codex/pipewire/pipewireao-gui-native-rtc/target/debug/deps/pipewireao_gui-58b27f436766f125
```

Observed at inspection:

- `FINAL/classic-fgn-v6-installed` and `classic-jfg-v5-installed` each have
  `*-evidence.lifecycle.json` with `success=true`, reset mode, two recorded
  cohorts and confirmed cleanup. Neither has `lifecycle_test=true`; stopped
  reset does not establish a midrun pause. Root is running Copper FGN v4 and
  preparing Copper JFG; do not duplicate those runs or infer their outcome.
- `FINAL/copper-fgn-v4-installed` and `copper-jfg-v4-installed` exist. Presence
  and cold seals do not imply science success. Final preparation validator:
  `validate_final_bootstrap_preparation.py` takes the **export path without
  `-installed`**, verifies source/export/install/protected hashes and writes a
  preparation record. It requires original exports still present; archived
  inputs need their retained validation record or an explicit restored copy.
- `FINAL/qualify_sustained-final-native-launch.jl` is a retained source snapshot;
  the maintained entrypoint is `RTC/deployment/qualify_sustained.jl`. It accepts
  `PACKAGE FRESH_RUNTIME FRESH_EVIDENCE [lifecycle|reset]`. It launches foreground,
  retains the admission client, requires fresh native report cursors, checks
  unchanged inclusive allocation, and audits owned cleanup. It has **no
  service-attach mode**. Snapshot hashes must match the actual launch version.
- `~/.cache/rtc-heart-native-20261006/{classic,copper}-heart-installed-qualified`
  and vendor hash ledger exist. Its old `qualify_installed.jl` is **not ready**:
  it uses `state["socket"]`, `D.control(socket,...)` and the old private-path
  inference. Reuse the immutable vendor/science inputs and historical evidence,
  not this control harness unchanged. Current `HeartExport`,
  `HeartCalibrationExport`, `HeartCorrectionExport` are maintained entrypoints.
- `OBS/cohort_gui-current.py` and related old cohort drivers are **not ready**:
  they read `state.json` for admission and open a Unix JSON socket. They must
  be replaced/adapted to the current retained native owner contract before
  qualification. The old observation packages/FFTW wisdom and comparison
  artifacts remain valuable controlled inputs, not current-native admission.
- GUI_TEST lists 132 tests, including all five native/session/queue tests below.
  Record its SHA-256 and build/source receipt before reuse; `--list` establishes
  entrypoints, not source provenance. `pipewireao_gui-d3d6d641090a8616` is the
  shared 270-test binary, not this native fixture. The older `ceb3...` candidate
  exits nonzero under `--list`; do not select binaries by filename age alone.
- `GUI/scripts/check_rtc_session.py --test-executable` avoids a Cargo build and
  runs exact installed systemd update/lifecycle tests. It **only accepts a
  recorded FGN/no-external-owner** profile with a declared Float property and
  one F32 parameter. None of the four current HIL packages fits that contract.
  A fresh recorded fixture is required; this script cannot qualify HIL by
  passing a HIL path or deleting its admission checks.

## Smallest integrated execution sequence

### 1. Freeze final inputs and finish the foreground matrix

Reuse the two successful Classic reset records; finish the already assigned
Copper runs. Freeze final supervisor/runner/SDK/adapter/GUI source and installed
artifact hashes. Preserve every failed prior run. Do not reseal packages during
execution or silently recast old source as the final version.

An executable maintained foreground command is:

```sh
taskset -c "$COHORT_CPUS" env OPENBLAS_NUM_THREADS=1 \
  "$JULIA" --startup-file=no --project="$RTC/deployment/julia" \
  "$RTC/deployment/qualify_sustained.jl" \
  "$PACKAGE" "$FRESH_RUNTIME" "$FRESH_EVIDENCE" reset
```

The CPU mask must contain the package's admitted roles and exclude CPU0/1;
CPU15 is for the cold reviewer, not a substitute science mask. `lifecycle`
instead of `reset` adds midrun Stop/Start after twelve two-second polls; a
finite source can finish before that checkpoint, in which case the test
correctly fails. The 512-frame fast reset packages are not automatically a
ready midrun test. Use an admitted sufficiently long/wall-paced cohort or an
explicit bounded native lifecycle harness, without altering science/warmup or
letting a timing race count as a pass. HEART needs fresh current-native export
and a current coordinator before equivalent foreground execution.

### 2. Use service cohorts to cover remaining midrun and installed controls

Install each sealed export to a new task-owned instance under
`~/.config/pipewireao-rtc/INSTANCE` through `deployment/deploy.jl install`
(`--package`, `--destination`, `--pipewire-prefix /opt/pipewireao`, selected
`--julia-executable`). Copy its generated `systemd/pipewireao-rtc@.service`
to a **fresh instance-specific** user-unit filename; never overwrite a shared
operator template. The generated unit's `%h/.../%i/deployment.conf` requires
that standard destination. Then `systemctl --user daemon-reload` and start
only that new unit. Record MainPID, `/proc/PID/exe`, Result/ExecMainStatus,
journal, actual CPU/thread placement, and unchanged manager environment.

Use `D.wait_state(...; process=owned_process)` for foreground; a service
coordinator must instead verify fresh native UUID/PID against **systemd
MainPID**, retain that exact client, and respect service disappearance. This
service coordinator is a remaining harness task; the foreground qualifier
cannot merely be pointed at an existing service. `check_rtc_session.py` already
contains the native MainPID/readiness pattern for its recorded fixture.

Within each service cohort cover Status, midrun pause (frozen source sequence
and discard count), resume, stopped reset (new generation), report-ready cursor
and artifact hashes, final native shutdown and service cleanup. Capture related
source/runner/HEART outcomes, not merely command acknowledgement. Run the
recorded GUI fixture once for real property and parameter adoption rather than
changing science gains/parameters during a frozen HIL numerical comparison:

```sh
taskset -c 15 python3 -B "$GUI/scripts/check_rtc_session.py" \
  --test-executable "$GUI_TEST" --package "$RECORDED_INSTALLED_PACKAGE" \
  --pipewire-prefix /opt/pipewireao --scenario all
```

The recorded harness uses fresh transient units, checks unchanged required
topology and unrelated publications, and cleans only its own service. It does
not replace the six HIL service profiles or prove scientific equivalence.

### 3. Qualify real calibration/restoration consumers, not another codec sweep

Use current Julia `deployment/export_calibration.jl --deployment` with
`--base-package`, `--output`, `--pipewire-prefix`, explicit final
`--rtc-binary` and `--calibration-binary`. HEART variants use
`deployment/julia/export_heart_calibration.jl` and
`export_heart_correction.jl`; both need the frozen vendor/config/calibration
roots and source SDK. Specify `--simulator-backend cpu` explicitly: correction
currently defaults to CUDA. Fresh export/install must precede service admission.

Minimum actual cycle for each applicable Classic/Copper FGN/JFG/HEART owner:
Hold→Adopt→Settle→Collect, exact contributing exposure/model identities and
Float32 outputs, Restore (including prior-work fence)→Release, fresh final
cursor and verified immutable report. Run Julia Capture on a separate admitted
run to verify commit/hash/counts/cursor; the Rust coordinator has no Capture
action. Reuse small existing frozen plans, not a new full inverse campaign.
Retain hold/fault on clipping, invalid evidence, disconnect or unknown outcome;
never use Release merely to clean up an unresolved acquisition. Verify explicit
unsupported calibration Reset rejection and native cleanup. HEART correction
must read current native child PID/generation/liveness before report use, and
its current finite correction trajectory must match the frozen reference.

Private protocol negatives already cover malformed/oversize/full-width values,
busy/stale/conflict/duplicate, competing controllers, removal, long-action
inactivity and expiry. Reuse them when source matches; add only the actual owner
effect/restoration or final-binary boundary missing from their scope. The
cached `native-calibration-rust-interop-final.log` passes 21 checks; later
`retirement-native-calibration-interop-20261006.log` failed **setup** because its
selected project lacked AdaptiveOpticsSim. It is not passing final evidence.
If the final Rust binary needs requalification, this existing focused invocation
uses the available HIL environment without rerunning the legacy socket suite:

```sh
taskset -c 15 env OPENBLAS_NUM_THREADS=1 JULIA_NUM_THREADS=1 \
  LD_LIBRARY_PATH=/opt/pipewireao/lib/x86_64-linux-gnu \
  REVIEW_SOURCE_ROOT="$RTC" \
  PIPEWIREAO_RTC_CALIBRATE_TEST_BINARY="$CONTROL/native-filter-target/debug/rtc-calibrate" \
  "$JULIA" --startup-file=no \
  --project=/home/dgamroth/.cache/rtc-heart-native-20261006/classic-fgn-cpu-base/hil \
  "$CONTROL/native-calibration-rust-interop.jl"
```

Verify its printed SDK_SOURCE and final binary hash. This is synthetic native
interop, not an installed acquisition or scientific result.

### 4. Combine discovery/picker with two observation cohorts

Keep two **fresh harness-owned** installed sessions published with duplicate
display labels; distinguish by UUID, include a stopped session, and demonstrate
read-only listing and explicit selection. Existing private negative fixtures
cover inaccessible/stale/replaced records; the installed UI must render those
statuses and never choose the internal runner as supervisor. Exercise the
actual picker/rendered view, not just an adapter test or screenshot alone.

Exact tests can run against an already admitted fresh owner using the same
per-user XDG registry as its publisher, on an agreed cold core:

```sh
taskset -c 15 env LD_LIBRARY_PATH=/opt/pipewireao/lib/x86_64-linux-gnu \
  PIPEWIREAO_GUI_NATIVE_SESSION_UUID="$EXACT_UUID" \
  "$GUI_TEST" rtc_adapter::live_tests::native_supervisor_stall_disconnect_and_reselect \
  --ignored --exact --nocapture --test-threads=1
```

Read-only selection uses
`rtc_adapter::live_tests::native_supervisor_session_selection_and_read_only_status`.
Explicit HIL stop/start uses
`rtc_adapter::live_tests::native_hil_session_pause_and_resume` plus
`PIPEWIREAO_GUI_NATIVE_HIL_LIFECYCLE=fresh-non-actuating`; it requires a still
advancing simulator, not a completed finite owner. The control-stall test does
not create an ndarray stream and cannot establish stalled-observer isolation.

For Classic FGN and Copper JFG, compare identical controlled input/preparation
with observation disabled, enabled unattended, and an observer that attaches,
stalls, dies and is explicitly reattached. Include stopped reset, optional-link
retirement/replacement, required object identities, bounded capture ownership
and actual loop/driver CPU placement throughout. Reuse prior controlled FFTW
wisdom and strict full-trajectory comparators; preserve default-cold mismatch
records. No production FFT policy or numerical tolerance change is authorized.

Existing sample-worker exact test:
`pipewire_worker::tests::receives_a_frame_from_the_ndarray_queue_output`, with
`PIPEWIREAO_REMOTE` from the verified owner's observation remote,
`PIPEWIREAO_NDARRAY_QUEUE_NODE=simulator-detector-queue-output` and a fresh
`PIPEWIREAO_GUI_OBSERVATION_EVIDENCE` directory. This gives native sample/format
evidence, not the complete rendered/stall matrix. GUI generic pixels lack
Acquisition identity; RTC-DEV-006 explicitly permits the independent current
metadata reader for that evidence. Ready retained reader invocation:

```sh
taskset -c "$OBSERVER_CPU" "$OBS/metadata_observer-v2" \
  "$VERIFIED_REMOTE" "$FRESH_RECEIPTS_JSONL" "$DIMENSION" "$DURATION_SECONDS"
```

Dimension is 352 or 64. Its `.go`/`.stall` files are **test-reader scheduling**,
not RTC lifecycle authority. Use the matching retained cohort source for their
order. Validate metadata/domain/generation/sequence/PTS and each payload against
retained science; an optional latest observer need not receive every frame.
Never run the old JSON cohort wrapper against the final native deployment.

### 5. Final discrimination, cleanup and evidence reconciliation

Preserve `native-runner-client-sealed.log`'s pre-binding link timeout. Existing
unchanged serial replay passed; contention remains a hypothesis. Use one final
fresh installed startup as the discriminating replay with recorded readiness,
link identity, actual affinity/load and unchanged synchronization deadline.
If it fails, preserve detailed native link/sync state before cleanup and stop
causal speculation. Success supports bounded current startup, not an invented
historical scheduling root cause or arbitrary-contention guarantee.

For every cohort require native report-ready before reading artifacts, exact
PID/incarnation/global ID/full serial, clean process-group/runtime/unit/locator
retirement, and unrelated object/publication preservation. Reuse private
pre-publication failure, stale-locator/report and native cleanup-failure proofs
where source unchanged; installed failures need attributable bounded results.
Reconcile final merged source, installed bytes, build/install/GUI native/WASM
receipts, retirement inventory and independent findings; no Yggdrasil push.

## Non-negotiable evidence boundaries

Quiet fixed-connection inclusive zero allocation has separate evidence. Public
SDK registry callbacks and cold native actions allocate; late GUI/controller
creation cannot be called process-zero on the strength of the quiet test.
Keep the unchanged required scientific allocation interval and GC enabled,
preserve failures, and record cold ingress intervals explicitly. If acceptance
requires arbitrary discovery inside that same inclusive zero-allocation
interval, that is an unresolved implementation gate, not something this plan
can exclude by relabeling the measurement. No longer warmup or quieter source
may silently replace the declared oracle.

Functional private fixtures, finite numerical replay, installed service
lifecycle, rendered GUI, allocation, latency/cadence and hardware validation
remain distinct. There is no single existing turnkey command that closes all
the remaining clauses: current service-attached qualification, native observation
cohort orchestration, fresh installed calibration/correction consumers and the
recorded GUI fixture still require the bounded preparation noted above.
