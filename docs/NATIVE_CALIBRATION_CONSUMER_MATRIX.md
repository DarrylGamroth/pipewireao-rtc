# Small installed native calibration and correction matrix

## Scope and checkpoint

Read-only reconnaissance, 2026-10-06, against coordinator repair `f2ad422`
(integrated by the primary agent at `635990f`). This document plans remaining
RTC #5/#6/#7 installed consumer checks under RTC-ARCH-024 / RTC-DEV-030;
it records no new execution or scientific acceptance. Runner maintenance and
an explicit CPU reservation precede every SCI command below. Existing caches
were inspected without copying packages or running Julia/builds.

All paths below use these existing roots:

```sh
FINAL=/home/dgamroth/.cache/rtc-native-final-deployment-20261006
CAL=/home/dgamroth/.cache/rtc-native-calibration-final-20261006
OLD=/home/dgamroth/.cache/rtc-calibration-completion-20261003
QUALITY=/home/dgamroth/.cache/rtc-calibration-quality-20261003
RTC=/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-native-controls
JULIA=/home/dgamroth/.julia/juliaup/julia-1.12.7+0.x64.linux.gnu/bin/julia
```

`RUNNER` and `CALIBRATOR` must name the qualified binaries after maintenance;
the earlier preparation receipt recorded runner `7968051f...23f9a341` and
calibrator `ce0ba26c...9b1cb`. Do not silently reuse an earlier installed
binary when the selected final binary changes. Package seals, runtime source
checkpoint, exact executable hashes and native `--help` must be recorded anew.

## Frozen plans and capacities

| Plan | Existing file | Physical figures / measurements | Small run |
| --- | --- | --- | --- |
| Classic | `$QUALITY/method-smoke-reverse-v2/canonical-plan.json` | 277 / 376 | run82; four ±0.02 µm OPD probes at physical coordinates 12 and 65; 16 accepted frames each, discard1; 69 total exposures including final Restore |
| Copper | `$OLD/heart-calibration-copper-nondebug-n2-prepared1/heart-calibration-plan.json` | 277 / 3600 | run1; two ±0.04 µm OPD probes at coordinate139; 2 accepted frames each, discard1; 7 total exposures including final Restore |

Classic plan SHA256 is
`f6d8d2a29119ac437a0b36e60d0d88cbe986f4dce27c1691179f8ac1c181d011`.
Copper plan SHA256 is
`043cfdaef6896fbf09ed2a477a771026cb7045f4cf8b8aa68bf1a14deb990fc5`;
`$OLD/heart-functional-n2-method1/interaction-plan.json` is an exact copy.
Both references are the existing zero physical figure. Preserve chronology,
figures, timeouts, detector/plant settings and numerical limits.

The existing checked SPA size grammar gives successful Collect replies of
2568 bytes (Classic376/16) and 14904 bytes (Copper3600/2), with an empty message.
The owner must still call its exact message-aware capacity preflight before
effects. A separate first-probe Capture of two frames requires payload budget
500504 bytes for Classic or 45192 bytes for Copper, plus the existing metadata
bound. Both captures consume four exposures with the existing discard1
settling and restoration. Never substitute file length for Capture admission.

## Owner matrix

| Consumer | Reusable scientific input | Plan / required work |
| --- | --- | --- |
| Classic FGN | `$FINAL/classic-fgn-v6-installed` | Classic plan. `$CAL/classic-fgn-native-calibration-v1-installed` is already sealed/prepared; no actual calibration SCI yet. Check final runner receipt before use. |
| Classic JFG | `$FINAL/classic-jfg-v5-installed` | Same Classic plan. Fresh public CalibrationExport splits existing WFS/command graphs; retain JFG algorithms, calibration and plant bytes. |
| Copper FGN | `$FINAL/copper-fgn-v5-installed` (v4 retained) | Copper plan. Fresh CalibrationExport and the small qualifier changes below. |
| Copper JFG | `$FINAL/copper-jfg-v4-installed` | Same Copper plan, same physical/WFS extents; fresh CalibrationExport and qualifier changes. |
| Classic HEART calibration | `$OLD/backend-bases/classic-fgn-cuda-selected-v3`, frozen transfer corpus `$OLD/classic-native-selected-proof-v1/native-probe-plan-v1` | Fresh HEART export must retain its declared run98 transfer plan/seed98/lamp0.5/accepted operational inverse. Separately use the Classic small plan for native action effects only, as adjudicated by the primary agent. |
| Copper HEART calibration | Original CPU native pilot scientific input in `$OLD/heart-calibration-copper-nondebug-n2-prepared1` and its frozen CPU HIL base | Copper plan is already the frozen native pilot plan. Bind exact old base provenance before upgrading transport/SDK only; do not use an old prepared owner as live authority. |

Current ordinary HEART functional CPU64 packages
`$FINAL/{classic,copper}-heart-native-v1-installed` prove ordinary lifecycle
preparation only. They are not interchangeable with the transfer/correction
scientific inputs: their frozen model is 10Hz and the Classic base uses the
historical simulated offset condition. No backend conversion or new detector
background/reference acquisition is proposed here.

### Commands after reservation

For the four ordinary owners, use the public exporter, explicitly binding the
`native-functional` stage used by the current Classic qualifier:

```sh
taskset -c "$COLD_CPU" "$JULIA" --startup-file=no --project="$RTC/deployment/julia" \
  "$RTC/deployment/export_calibration.jl" --deployment \
  --base-package "$BASE" --output "$FRESH_STAGE" --pipewire-prefix /opt/pipewireao \
  --rtc-binary "$RUNNER" --calibration-binary "$CALIBRATOR" \
  --calibration-stage native-functional --illumination lamp \
  --capture-max-bytes "$CAPTURE_BUDGET"
```

The common CLI accepts stage/illumination through its named defaults; the Julia
API also supports typed arguments. Install each validated stage to a fresh path using public
`deployment/deploy.jl install` and the selected Julia executable. Then run two
separate admitted runs with fresh runtime/evidence directories:

```sh
taskset -c "$RESERVED_CPUS" env OPENBLAS_NUM_THREADS=1 JULIA_PKG_OFFLINE=true \
  "$JULIA" --startup-file=no --project="$INSTALLED/julia" \
  "$RTC/deployment/qualify_calibration_native.jl" \
  "$INSTALLED" "$FRESH_RUNTIME" "$FRESH_EVIDENCE" "$FROZEN_PLAN" collect
# Repeat with new runtime/evidence paths and mode capture.
```

The maintained qualifier runs Rust Collect internally using freshly proved
native remote/node/owner PID/incarnation and plan-bound UInt64 run/serial:

```sh
"$INSTALLED/bin/rtc-calibrate" --remote "$PROVED_ABSOLUTE_REMOTE" \
  --node "$PROVED_ACTION_NODE" --owner-pid "$PROVED_OWNER_PID" \
  --owner-instance "$PROVED_OWNER_INSTANCE" --plan "$FROZEN_PLAN"
```

Standalone CLI output is insufficient qualification: retain the supervisor
client, verify final native owner facts/report, and complete owned cleanup.
Julia Capture uses the existing typed client sequence
Hold→Adopt(first probe)→Settle→Capture(2)→Restore(reference)→Release.

## Small cold qualifier changes before broader execution

`deployment/qualify_calibration_native.jl` currently hardcodes Classic instrument,
startup profile and Capture profile/stage. Derive these from the sealed selected
profile and source calibration provenance, validate plan extents against that
profile, and retain the existing two-frame bound. This is necessary even for a
fresh default-stage ordinary Classic export. Keep the corrected cleanup reducer
and Reset lifecycle/report-cursor invariance checks unchanged.

HEART additionally needs an exact retained `NativeHeartClient` from the freshly
proved `ready["heart_endpoint"]`. Check Ready, child PID, generation, liveness,
required flags and ingress before effects and before report use; retain exact
native command/child evidence and include child cleanup. The calibration owner
already records `native_controller_held` and a hashed `native-evidence.jsonl`.
Compare that proof with the live child rather than trusting report JSON as
authority. HEART source calibration Reset remains explicitly unsupported.

Classic HEART strict export binds run98/24 probes/64 frames/discard1, 1561
exposures and 25 DM records. Its declared plan SHA256 is
`583fcb45ba2cd637852b105f63095e005c220734c970debfe576d531e0a91c1b`.
Preserve that plan and the separately called small plan hashes and labels.
Small run82 may qualify action effects; it does not pass `run_plan`'s declared
chronology/full-transfer or inverse-science acceptance. Derive Capture stage and
budget from the sealed HEART owner. Short external evidence paths must leave
`probe-UInt64.csv` under the native 127-byte path bound.

## Correction consumers: retained full256 inputs

The existing ordinary FGN/JFG normal correction remains part of the frozen
installed lifecycle/cohort checks. HEART active correction is a separate native
consumer: both public HEART correction exporters require **FGN / 256 frames**.
The final 16-retained/512-total packages and JFG engines do not meet that gate.

| HEART correction | Frozen ready input and accepted proof |
| --- | --- |
| Classic | Normal base `$OLD/backend-bases/classic-fgn-cuda-selected-v3`; prepared scientific assets `$OLD/heart-native-classic-correction-prepared-v5`; actual transfer package `$OLD/classic-native-transfer-v2`, evidence directory with suffix `-evidence`, lifecycle `$OLD/classic-native-transfer-v2-evidence.lifecycle.json`, score `$OLD/classic-native-transfer-managed-v5.json` (directly hashed SHA `1f51e4914936491a61f950815037d5911b9ca1e31b2e94de4179a2167d29363a`); forward `$QUALITY/method-selection-analysis/hadamard-forward.f64le`, accepted preparation beside it. |
| Copper | Normal base `$OLD/backend-bases/copper-fgn-cuda`; prepared scientific assets `$OLD/heart-native-correction-prepared-v6`; locked utility `$OLD/native-locked-v1/locked-test.json` SHA `fa3f23719478ed21b6807d99c9ad3788902dba20d5e834aefbaf8a37f7b4627c`, selecting native controller SHA `7b65491be869943e8b56f05ecba792950fdbcdf795d0bdd38927f323c6144858`. |

Fresh control-only upgrade must preserve full plant, matrices, gains/poles,
maps, projected command shapes and original proof files. Prepared-package
filenames and copied preparation records are insufficient selection authority:
Copper v6 retains a base-selection record for a different controller while its
actual active contract selects the above native controller. Use the sealed
active contract and its cold-admission input map.

`deployment/julia/export_heart_correction.jl` takes base/output,
heart-root/source-config/calibration-root, source SDK and a short fresh external
owner-evidence directory, explicit runner/backend, then the above Classic
transfer arguments or Copper `--locked-test` / `--locked-test-sha256`.
Classic uses original `revolt-rtc/config/classic_config_sim.yaml`; frozen Copper
source configuration is `JuliaFilterGraph.jl/benchmark/heart/copper_config_aos_matched.yaml`.
Use the frozen unchanged vendor tree/hash and actual sealed backend; do not
force CPU onto a frozen CUDA base.

Cold replay compatibility was confirmed and corrected separately:
`HeartClassicTransfer.admit` used strict `Deployment.profile` on the historical
transfer package, which has no native owner protocols and must remain unchanged
to preserve its historical launch seal. Its replay-only validation now explicitly
uses the existing offline legacy-input mode; that mode also admits the original
HEART marker schema. Default profile validation, fresh output and runtime stay
strict. The unchanged actual historical package/evidence passes admission after
the fix; see the proof below. This is cold admission, not a new score replay.

Minimum actual correction check: fresh native child readiness; lifecycle
Connect (held window1)→Start; finite 256-frame completion and immutable
report-cursor proof; retain closed native telemetry/native CORRECT proof;
Reset while stopped must remove the old child, start a distinct child with
generation+1 and a new acquisition generation, preserve lifetime probe token;
Start completes window2; verify the existing trusted frozen trajectory analysis
and native Quit/cleanup. Both old windows remain available after Reset.
The source already implements two windows and rejects additional windows.
Use maintained `hil/heart_correction_analysis.jl --package PACKAGE --report REPORT
--output FRESH.json` after native report readiness. A small Collect plan cannot
replace this full256 correction acceptance.

## Required receipts and execution order

1. Finish runner maintenance qualification; reserve one actual owner fixture.
2. Run already prepared Classic FGN Collect and separate Capture first.
3. Make the small profile/stage and HEART child-proof qualifier changes, review
   pure failure oracles, then prepare/run one profile at a time.
4. Establish offline replay compatibility; upgrade retained full256 correction
   wrappers/runtime with full scientific file hash identity, then run both
   HEART correction windows without new matrix acquisition.

For every action run require finite Float32 response extent; full UInt64 domain,
generation, sequence/start/duration identities; exact declared discard and
nonoverlap; restored reference and prior-work fence; released/unheld final phase;
published report cursor equal to fresh actual cursor; Capture payload/metadata
hash and count; unsupported Reset with unchanged lifecycle/publication facts;
retained-client closes, shutdown and all owned process groups complete.
Fault/hold on unknown effects remains a failed gate, never cleanup Release.
No inverse computation, new tolerance, vendor change, physical-device or cadence
claim follows from these functional consumer checks.

## Historical replay compatibility proof

The exact managed-v5 score path/hash above was recovered from
`$OLD/native-classic-correction-public-preparation-v5-root-command.json` and
directly hashed. The differently named characterization-v6 score has SHA
`8af4dc82...01ebb9` and cannot replace it.

The historical transfer's 514 package files still match its actual preparation
ledger. Three large telemetry files are preserved in
`$OLD/historical-telemetry-archive-20261005`, leaving 202 expanded evidence files
in the original directory. A fresh RAM copy restored those three archived blobs
and copied the 202 present files: all 205 hashes, sizes, modes, UID/GID and mtimes
verified, 1,175,417,302 bytes total. A private user/mount namespace bound that
copy read-only at the original evidence path, preserving absolute launch identity.
The host tree remained unchanged. No daemon, vendor child or scientific helper
was started. The owned RAM copy was removed after proof; the archive and all
original files remain.

The same cold oracle fails before (9 pass / 2 fail, exit1: native-bootstrap
admission and masked malformed-marker validation) and passes after (13/13,
exit0). It also checks strict-default rejection of the old HEART package;
tampered launch-driver, preparation and descriptor hashes; malformed marker
rejection; immutable package and exact score hash retention. Existing Classic
transfer tests pass24/24 and portable deployment tests pass267/267. The current
installed calibration and native HEART packages also retain default strict
profile admission (2/2).

Receipts, exact oracle scripts and logs are in
[`validation/native-calibration-20261006`](validation/native-calibration-20261006).
`historical-transfer-namespace-before.log` and
`historical-transfer-namespace-after.log` are the same fully restored fixture
comparison; `historical-transfer-ram-receipt.json` records restoration identity.
This does not pass a new full transfer, score-replay or active-correction gate.
