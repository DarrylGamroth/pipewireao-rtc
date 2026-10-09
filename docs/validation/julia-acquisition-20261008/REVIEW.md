# Independent Julia acquisition migration review

Date: 2026-10-08. Review baseline: `6a040187bcc5b19697329241d6e8fe5135ddafc1`.
Branch: `codex/julia-acquisition-20261008`.
Worktree: `/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-julia-acquisition`.
The implementation was an uncommitted working diff, including new acquisition,
CLI and test files. The primary agent continued editing while this independent
review ran. Review changes are confined to this evidence artifact.

## Scope and conclusion

The review compares the shared Julia acquisition driver, typed native action
client and CLI with the retained Rust acquisition/client/CLI oracle, native v1
contracts and the calibration section of `docs/JULIA_RTC_STRUCTURE_PLAN.md`.
It also inspects exporter, campaign, provenance and installer changes.

Three confirmed implementation findings required correction: cancellation during
normal restoration could suppress Release, and the shared native client's
30-second budget cap shortened otherwise valid calibration plans. A later
duplicate-field parser refinement consumed its input buffer before a second
parse. The primary agent applied fixes and the independent discriminators pass.
Active qualification
examples now use the new command. No unresolved source-review blocker remains
within this review's scope; the primary task owns the broader test/install gates.

This review does not require a full scientific calibration, hardware run or
latency campaign to accept a generic cold client implementation. Actual owner
interoperability, package installation and source-level correctness are separate
from Classic/Copper/HEART scientific acceptance. HEART source, frame callbacks,
WirePlumber session policy and systemd process ownership are outside the change.

## Findings

### JAC-001 — Cancellation after Restore suppresses Release

- Severity: P1. Confidence: high. Evidence class: observed.
- Affected code: `deployment/julia/src/calibration_acquisition.jl`, normal
  Restore/Release sequence and cancellation check in local `request`.
- Original behavior: after successful normal Restore, cancellation was checked
  by the next ordinary `request(Release())`. It threw while `phase` still read
  `Restoring`; the catch branch therefore skipped recovery and Release.
- Consequence: a completely restored run unnecessarily faulted while retaining
  ownership. This disagreed with the Rust coordinator's idempotent cancellation
  during restoration/release and the intended bounded recovery contract.
- Reproducer: construct the two-probe synthetic test connection and call
  `acquire!(client, plan(); cancelled=()->length(client.client.commands)>=8)`.
  The original code returned `phase="fault"`, `failure="Cancelled"`,
  `restoration_confirmed=true`, `resume_permitted=false` and operations
  `[1,2,3,4,2,3,4,6]`.
- Remediation: after confirmed restoration, retain the cancellation report and
  perform Release while ignoring cancellation, as in the recovery branch.
- Required validation: the same discriminator must return `aborted`, confirm
  restoration and release, permit resume and end with operations `[6,7]`.
- Disposition: fixed and independently verified, 5/5 assertions. The same
  cancellation discriminator returns `aborted`, `Cancelled`, restored/resume
  true, no recovery failure and all nine expected operations ending in Release.

### JAC-002 — Valid calibration timeouts were silently capped at 30 seconds

- Severity: P2. Confidence: high. Evidence class: derived from source.
- Affected code: `NativeCalibrationActionCodec.CalibrationActionProfile` and
  `NativeControlClient.request!` budget construction.
- Original behavior: `Plan` accepted positive Int64 nanosecond timeouts, but the
  calibration profile inherited `maximum_budget(::Profile)=30.0`. Native
  request encoding used the smaller of the remaining deadline and 30 seconds.
  The Rust endpoint encodes the remaining effect deadline without that cap.
- Consequence: a valid 60-second collection/restoration plan gave the owner only
  30 seconds, changing the accepted prepared-plan contract. Existing campaign
  recipes bounded to 30 seconds do not exercise this generic API regression.
- Remediation: give the calibration profile its positive Int64 nanosecond range
  and saturate Float64 conversion at Int64 max, which rounds upward to 2⁶³.
  Preserve ordinary lifecycle profiles' existing cap.
- Required validation: native budget construction retains 60 seconds, handles
  Int64 max without overflow, rejects nonfinite/negative durations, and retains
  the other profiles' 30-second bound. A minutes-long runtime test is unnecessary
  for this encoding discriminator.
- Disposition: fixed and independently verified, 9/9 assertions. These include
  60 seconds, Int64 max, the unchanged lifecycle cap, subnanosecond rounding and
  rejection of zero, negative, infinite and NaN durations.

### JAC-003 — Active qualification instructions still select removed flags

- Severity: P2. Confidence: high. Evidence class: observed source text.
- Affected documents: `docs/NATIVE_FINAL_QUALIFICATION_PLAN.md`, calibration
  export instructions; `docs/NATIVE_CALIBRATION_CONSUMER_MATRIX.md`, commands
  after reservation.
- Behavior: their current export examples still pass `--rtc-binary` and
  `--calibration-binary`. The first selects a retired coordinator and the second
  is removed by this migration, so these commands cannot prepare fresh exports.
- Remediation: update active instructions to use the fresh Julia calibrator
  generated by the exporter. Preserve genuinely historical receipts unchanged.
- Required validation: current commands match accepted exporter options and do
  not restore a Rust runner/session authority.
- Disposition: fixed; inspected the final document diff. Both examples remove
  the retired flags, and the qualification plan identifies the included Julia
  entrypoint. Historical validation text remains separately scoped.

### JAC-004 — Duplicate-field validation parsed a consumed byte buffer

- Severity: P1. Confidence: high. Evidence class: observed.
- Affected code: `CalibrationAcquisition.read_plan`, late parser conformance
  refinement after the initial review.
- Original behavior: the first parse called `Common.parse_json(String(bytes))`,
  then duplicate checking called `JSON3.read(bytes)`. Julia's `String` constructor
  takes ownership of a byte vector and empties it; the second parse therefore
  received an empty buffer, rejecting every valid saved plan.
- Evidence: a Julia 1.12.7 discriminator directly confirmed
  `length(bytes)==0` after `String(bytes)`. The primary full-suite run also
  caught the valid CLI plan failure, retained in its fail-before log
  `/tmp/rtc-julia-acquisition-suite-final.log`.
- Remediation: bind `text=String(bytes)` once and give both parsers the retained
  string. Add a valid `read_plan` assertion beside duplicate-key rejections so
  arbitrary parsing failure cannot satisfy all new negative tests.
- Required validation: valid UInt64-max run plans parse; top-level, nested
  timeout and nested settling duplicates reject for the duplicate-field reason.
  Escaped key spellings that decode to the same field must also reject.
- Disposition: fixed and independently verified, 9/9 assertions on CPU 13.
  The valid plan passed and all four duplicate cases produced
  `ArgumentError("duplicate calibration plan field")`. The recursive JSON3
  object walk preserves duplicate keys, including decoded Unicode escapes,
  before plan adoption. Native controls and the
  shared `Common` parser are unchanged.

## Mechanisms inspected without additional confirmed defects

- Plan preflight checks exact fields, positive full-width run identity, finite
  Float32 conversion, figure dimensions, probe/frame limits, exact encoded
  Collect capacity and retained payload bounds before Hold. `acquire!` snapshots
  mutable input vectors again before effects. Vector iteration order is the
  wire order; array index labels do not become instrument coordinates.
- Hold/adoption/settling evidence requires valid cursors, stable domain and
  generation, monotone sequence/model time and exact prepared figures. Discard
  settling advances by the declared exposure count. Model-time settling meets
  the declared lower time boundary with overflow protection.
- Accepted response batches require the declared dimensions, finite values and
  valid quality. Each exposure has the preceding sequence plus one, stable
  domain/generation, positive duration, nonoverlapping model-time interval and
  checked end time. The resulting cursor must remain representable for the
  next native action.
- Native completion matching retains the existing common controller/endpoint/
  token/operation fencing and adds exact run/serial/result-kind checks. Typed
  action failures remain known outcomes. Unresolved transport outcomes do not
  authorize retries, Restore or rebind. Failed restoration does not authorize
  Release. Partial responses are absent from unsuccessful result documents.
- The generic driver imports operational clients/codecs only and contains no
  instrument-name dispatch, probe generation or scientific estimator. Prepared
  absolute figures and their order are preserved. Session admission remains
  WirePlumber-owned and process lifetime remains systemd-owned.
- Evidence files use exclusive creation, bounded record charging and an explicit
  overflow marker. The driver disables the action client's duplicate record
  accumulation. The budget is a retained-payload/evidence bound, not a process
  RSS or science-frame allocation claim. Evidence format version 2 explicitly
  distinguishes the new completion journal from the old Rust journal.
- Fresh calibration exports copy the current Julia runtime and seal a generated
  `bin/rtc-calibrate` wrapper with `implementation="julia"` provenance. Campaign
  source snapshots cover the new shared sources. The installer preserves an
  already sealed older Rust calibrator rather than rewriting its contents.
- `scripts/refresh_qualification_runtime.jl` predated this migration and referred
  to the already retired `Deployment` module and runner. No maintained caller
  was found outside historical evidence. The primary agent removed it and
  changed the historical Copper receipt to link its exact Git revision. This
  preserves reproduction history without reviving its session coordinator.

## Verification record

The initial independent run loaded the source before the JAC-001 fix and ran
`deployment/julia/test/test_calibration_acquisition.jl`: **224/224 assertions
passed**. The additional JAC-001 discriminator then produced the failure above.
The run used Julia 1.12.7, initially CPU 15; its process and all threads were
moved to CPU 14 when the primary agent reported its private-core suite on CPU
15. No private core, scientific owner, hardware or external service was started
by this reviewer. CPU 0 and 1 were excluded throughout.

The initial synthetic suite covers the three settling rules, clipping, causal
exposure violations, known action failures, unknown outcomes at every action,
failed restoration/release, cancellation before Hold and between probes,
elapsed completion, plan mutation/preflight, output shape and bounded exclusive
evidence. Those tests did not cover the restoration-boundary cancellation that
JAC-001 demonstrated; the primary agent added that regression.

Final independent remediation checks used CPU 13 and Julia 1.12.7. JAC-001 passed
5/5 assertions using the same synthetic endpoint and cancellation trigger.
JAC-002 passed 9/9 budget assertions. The first budget-check attempt referenced
the review harness's nonexistent lifecycle `PROFILE` constant; correcting it to
`CALIBRATION_PROFILE` resolved that harness error without a production change.
The final source and documentation diffs were inspected for each finding.

Reviewed production source SHA-256 values:

| File under `deployment/julia/src/` | SHA-256 |
| --- | --- |
| `calibration_acquisition.jl` | `dcfb2dde2436d48dff505549ef27ad75325fd4dea34d4c2c6882bdd8604891e6` |
| `calibration_cli.jl` | `30d07106272438952722e56ae2d7173c93456b8702307608f7d132af3f334152` |
| `native_calibration_action_client.jl` | `cb9ac1a39bce6207d1ecc02d3d5c4430f776364a43e9c4a446400221df81e6fd` |
| `native_calibration_action_codec.jl` | `f71e398cb3d2d6314684e7fe396cfaa2b9e4ae422fb79a40fd911d170530d7f6` |
| `native_control_client.jl` | `7ce77d3a59f60bf4e841160f18afb59cd7c7c4de2d66a39b6ea578cdabd4777d` |

Broader native interoperability and export/install checks belong in the primary
task's companion receipt. Neither the passing synthetic suite nor this source
review establishes instrument science, cadence, latency, physical-loop or
hardware qualification.

## Installer refinement review

The final extraction of `validate_sealed_wrappers` in
`deployment/julia/wireplumber_install.jl` was independently inspected after the
core review. It preserves the previously reviewed loop and explicitly handles
missing/null historical `calibration_command` metadata as legacy. A Julia-marked
sealed calibrator must still match the selected interpreter's generated wrapper.
This compatibility branch does not bypass artifact validation:
`session_spec` calls `DeploymentConfiguration.profile`, which checks each sealed
artifact's SHA-256 before wrapper checks. The installation write loop still
skips rewriting sealed entrypoints.

The new `test_calibration_install.jl` contains 11 focused assertions for the
matching Julia wrapper, changed-wrapper rejection, read-only behavior, binary
bytes with legacy/null/missing metadata and absent artifacts. The reviewer
inspected those cases without rerunning the primary agent's completed focused
test. No new finding arose; prior finding dispositions remain closed.
`git diff --check` passes. Reviewed installer SHA-256:
`ac480aa169b571b428db649bb777f28559a2a4fd3ebe87cb68a222fa9d60f0f9`.
