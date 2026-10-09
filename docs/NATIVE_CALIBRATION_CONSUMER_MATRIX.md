# Small installed native calibration and correction matrix

## Scope and checkpoint

Read-only reconnaissance, 2026-10-06, against coordinator repair `f2ad422`
(integrated by the primary agent at `635990f`). This document plans remaining
RTC #5/#6/#7 installed consumer checks under RTC-ARCH-024 / RTC-DEV-030;
it records no new execution or scientific acceptance. Runner maintenance and
an explicit CPU reservation precede every SCI command below. Existing caches
were inspected without copying packages or running Julia/builds.

The coordinator/qualifier procedures below describe that historical checkpoint;
those programs were subsequently retired. Fresh exports use the Julia acquisition
entrypoint and [WirePlumber installation tools](JULIA_DEPLOYMENT_USAGE.md), with
[current acquisition usage](JULIA_CALIBRATION_ACQUISITION.md). Historical command
sequences are not current runnable instructions.

All paths below use these existing roots:

```sh
FINAL=/home/dgamroth/.cache/rtc-native-final-deployment-20261006
CAL=/home/dgamroth/.cache/rtc-native-calibration-final-20261006
OLD=/home/dgamroth/.cache/rtc-calibration-completion-20261003
QUALITY=/home/dgamroth/.cache/rtc-calibration-quality-20261003
RTC=/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-native-controls
JULIA=/home/dgamroth/.julia/juliaup/julia-1.12.7+0.x64.linux.gnu/bin/julia
```

The binary hashes in the original preparation receipt belong to its historical
coordinator/calibrator. Fresh exports now include the Julia acquisition
entrypoint; do not copy those binaries into a new package. Record the fresh
package seals, runtime sources and selected Julia executable again. Use the
[one-shot WirePlumber installation path](JULIA_DEPLOYMENT_USAGE.md).

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
  --calibration-stage native-functional --illumination lamp \
  --capture-max-bytes "$CAPTURE_BUDGET"
```

The common CLI accepts stage/illumination through its named defaults; the Julia
API also supports typed arguments. Install each validated stage to a fresh path using public
`deployment/julia/wireplumber_cli.jl install` and the selected Julia executable. Then run two
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

## Generic qualifier and remaining installed execution

`deployment/qualify_calibration_native.jl` now derives Classic/Copper instrument,
engine, backend, Capture profile/stage/budget and illumination from the strict
sealed source/provenance. It rejects mismatched 277-coordinate figures, WFS
extents, nonfinite inputs and invalid Rust-plan timeouts before launch, and
retains the two-frame Capture bound. The corrected cleanup reducer and Reset
lifecycle/report-cursor invariance checks remain selected.

HEART retains an exact `NativeHeartClient` from the freshly proved
`ready["heart_endpoint"]`. Fresh native generation reports and typed snapshots
establish child PID/generation/liveness, placed execution, disabled diagnostics,
configuration hash and ingress before effects and before report use. The
qualification records the sealed requirements hash; Ready follows the wrapper's
required flag acknowledgements, with no claim of effective flag readback. The
published calibration `native_controller_held` proof must match that live child
and native snapshot. Hashed/count-bounded `native-evidence.jsonl` is retained.
Child parent/group/session/start ticks must match the owned wrapper group;
native shutdown must remove that child and all owned groups. Calibration Reset
remains explicitly unsupported. Unknown effects never trigger speculative Release.

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
3. Review the generic profile/stage and HEART child-proof qualifier, then
   prepare/run one profile at a time after an explicit SCI reservation.
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

## Generic consumer cold evidence and command recipes

The source Capture verification discriminator fails before (3 pass / 3 fail)
and passes after (6/6) with the same injected public request/copy/verification
seams: both selected profiles and non-default stages now reach the maintained
verifier. This is a cold wiring test, not an actual Capture. Focused qualification
tests pass175/175, covering all six fixture derivations, startup instrument and
settings, wrong extents/nonfinite inputs/budgets, exact HEART child and published
hold identity, native evidence and cleanup-failure gates. The existing sealed
Classic CUDA calibration package also preflights both modes with its actual
frozen run82 plan, unchanged 500504-byte Capture budget and native-functional
stage. Actual Collect/Capture on the generic increment is still pending.

Run the common five-argument qualifier command above separately for these six
selected fresh installed calibration packages; table values describe required
inputs, not uncreated destination paths:

| Installed selected calibration | Called plan | Declared export / required scope |
| --- | --- | --- |
| Classic FGN native | Classic run82 path above | strict fresh FGN source; AOS CUDA / RTC CPU |
| Classic JFG native | Classic run82 | strict fresh JFG source; AOS CUDA / RTC CPU |
| Copper FGN native | Copper run1 path above | strict fresh FGN source; AOS CUDA / RTC CPU |
| Copper JFG native | Copper run1 | strict fresh JFG source; AOS CUDA / RTC CPU |
| Classic unchanged HEART native | Classic run82 | preserve declared run98/24×64 plan separately; functional action effects only |
| Copper unchanged HEART native | Copper run1 | preserve its frozen native pilot and selected backend |

For each choose fresh runtime/output names ending `-collect` and `-capture` and
record package descriptor, provenance, called plan, declared export plan and both
binary hashes. Preserve source libraries, plant/calibration arrays, wisdom and
startup flags. SDK/control refreshes must be explicit sealed provenance; do not
regenerate darks, references, inverse matrices or vendor algorithms.

The two HEART full256 correction consumers use
[`deployment/qualify_correction_native.jl` at its historical revision](https://github.com/DarrylGamroth/pipewireao-rtc/blob/92444413e4930e1191821b8a402301307fbaca2a/deployment/qualify_correction_native.jl).
Their source lifecycle, phases, window reports and supported stopped Reset
already exist. Old marker-based launch scripts remain historical
algorithm/evidence inputs. The coordinator's
recipe will run both restored full256 windows and the existing analyzer against
immutable reports after fresh native cursor publication, with generation+1 and
distinct child identity at Reset. A failure of the retained scientific trajectory
gate remains a failure, even if native transport and cleanup succeed.

## Native correction coordinator and installed launch proof

After a fresh sealed native correction export/install and an explicit SCI
reservation, run each selected HEART fixture independently:

```sh
taskset -c 15 julia --startup-file=no --compiled-modules=existing \
  --project="$RTC/deployment/julia" "$RTC/deployment/qualify_correction_native.jl" \
  "$FRESH_CLASSIC_HEART_CORRECTION_INSTALLED" "$FRESH_CLASSIC_RUNTIME" "$FRESH_CLASSIC_OUTPUT"
taskset -c 15 julia --startup-file=no --compiled-modules=existing \
  --project="$RTC/deployment/julia" "$RTC/deployment/qualify_correction_native.jl" \
  "$FRESH_COPPER_HEART_CORRECTION_INSTALLED" "$FRESH_COPPER_RUNTIME" "$FRESH_COPPER_OUTPUT"
```

These destination variables require the frozen full256 inputs listed above;
they do not identify already prepared fresh packages. The coordinator loads
its cold client code from the chosen tool project, launches the sealed installed
`julia/deploy_cli.jl` with the installed project, and records the qualifier and
installed runtime source/manifest hashes separately. The calibration qualifier
now uses the same installed launch helper. The identical cold launch oracle
fails before (1 pass / 1 fail) and passes after (2/2); it executes no deployment.

Deployment acknowledges source Connect and automatically Resumes window1
before announcing Running. The coordinator observes fresh window1 native
Status and HEART generation/health; it does **not** claim to observe the initial
hold or issue a second Resume. It waits for restored/unheld completion with
report_cursor equal to cursor before reading the saved report. The 256 hashed
native journal acquisition records must match the full UInt64 domain/generation,
sequences and exposure-end model times of that current cursor. The historical
report field `acquisition_generation=0` supplies no authority.

The retained supervisor performs session-stop→Reset. Fresh native source Status
must prove held window2, sequence0, unchanged domain and acquisition generation+1;
fresh HEART Status must prove child generation2 and a distinct owned child, with
the old process identity absent. Session-start admits window2. Its journal must
retain the reset hold, acquisition generation and advancing lifetime probe
token. Each original published owner report is copied with exact byte/hash
identity before a later control can update the live report. External native
evidence remains in the sealed fresh directory; large telemetry is not duplicated
by this coordinator and must remain available for analysis and audit.

Both restored windows must have identical ADC/command hashes and direct truth,
as required by the retained correction fixture. After native Quit and exact
owned-child/group cleanup, the maintained analyzer independently verifies the
native startup/restore references, public flag ACKs, telemetry counts and
payloads, detector policy, direct truth and frozen replay. The existing declared
17:128 and 129:256 residual-to-atmosphere variance ratios must each remain <1.
There is no new tolerance, inverse, gain or alternative acceptance criterion.
Overall success also requires failure-free retained-client/log closure and all
native cleanup facts; transport success cannot establish scientific convergence.

The exact historical file-poll function accepts a complete saved report while
the injected native owner is Stopped (1 pass / 1 fail). The same fixture under
the native coordinator rejects before any report read (2/2). This establishes
the authority discriminator in cold software; it is not an observed owner fault.
Focused current tests pass181 calibration and149 correction assertions, covering
both correction profiles, full-width cursor identities, missing publication,
fault/stopped/wrong-window negatives, child replacement, unchanged reset/utility
gates, exact report bytes and cleanup failures. Logs/oracles/source hashes are
retained beside the earlier proofs in `validation/native-calibration-20261006`.
Actual two-window correction, current native Collect/Capture and six installed
consumer gates remain pending the reserved runs; no scientific pass follows
from these cold tests.

## Current CUDA package inventory (read-only)

The following existing installed packages pass strict descriptor validation and
all sealed artifact hashes. Cold graph splitting also passes for all four
ordinary bases. This inventory started at qualifier commit `ed943b3`; exact
descriptor, provenance, plant, runner and plan hashes are in
[`current-consumer-inventory.json`](validation/native-calibration-20261006/current-consumer-inventory.json).

| Current ordinary/unchanged HEART base | Artifacts | Needed calibration preparation |
| --- | ---: | --- |
| `/tmp/classic-fgn-sdk-interrupt-final-v1-installed` | 579 | fresh public CalibrationExport; Classic run82 caller; Capture budget500504 |
| `/tmp/classic-jfg-sdk-interrupt-final-v1-installed` | 709 | fresh public CalibrationExport; same Classic run82/budget |
| `/tmp/copper-fgn-sdk-interrupt-final-v1-installed` | 581 | fresh public CalibrationExport; Copper run1 caller; Capture budget45192 |
| `/tmp/copper-jfg-sdk-interrupt-final-v1-installed` | 710 | fresh public CalibrationExport; same Copper run1/budget |
| `/tmp/classic-heart-sdk-interrupt-final-v2-installed` | 601 | ordinary HEART scope only; use current Classic FGN base for public frozen-transfer calibration export |
| `/tmp/copper-heart-sdk-interrupt-final-v2-installed` | 601 | ordinary HEART scope only; use current Copper FGN base for public native calibration export |

All six carry SDK0.6.16 with the current interrupt-safe thread-loop source
(`d6221155...ed420`), adapter0.1.2, CUDA plants and runner
`750059d1ee71783b63d1fbb96a6bc92cd9be436f551d1b450688a6aae2c2d5cb`.
They are SourceControlV1 packages, not CALIBRATION/CORRECTION-profile packages.
The shared Cargo target's runner still hashes `7968051f...9a341`; select the
verified750 binary explicitly from a current package/retained build, while
`rtc-calibrate` remains `ce0ba26cf04f64ea1cb730c4b89309592c5097843cc326d867c4ddd1bfe9b1cb`.

The already native `$CAL/classic-fgn-native-calibration-v1-installed` can be
refreshed into a new sealed destination with current SDK, runtime/HIL helpers and
runner750; its Classic CUDA plant, calibration files, split graphs, WFS/command
libraries, stage `native-functional`, called run82 and budget500504 stay exact.
Its argv already has no retired calibration socket flag. This is the one current
native calibration package located by the bounded cache inventory. The other
three ordinary calibration packages need the public export above from the
current bases; this copies/splits frozen graphs and does no matrix/background
acquisition. Do not relabel any ordinary package as calibration without that
descriptor/endpoint conversion and a fresh seal/install.

The current Classic FGN base passes `classic_transfer_inputs` against the exact
frozen run98 corpus and accepted inverse `bb9aa683...5813`. A fresh public HEART
calibration export therefore has a cold-admitted input without running the
transfer. Specify the original policy hash, full run98 plan, seed98, streaming
ingress and lamp0.5 contract; call the separate run82 small plan afterwards.
The existing `$OLD/classic-native-transfer-v2` remains an alternative immutable
scientific blueprint (plant SHA `eee98c18...a98b8`, original run98/24×64). Its
marker descriptor requires explicit native migration and new seals; replacing
only SDK bytes would leave an invalid live package.

For current Copper CUDA calibration, the current FGN base already retains the
selected 100× lamp magnitude0.752574989159953. A public native pilot export can
bind the exact existing two-probe run1 plan and original pilot detector seed700,
explicit CUDA backend, current SDK/adapter/750 runner and ce0b calibration CLI.
The declared plan's four accepted payloads require budget90384 (the standalone
two-frame Capture requires45192); telemetry bounds come from public plan_limits.
Label this a CUDA native action functional run, distinct from the historical
CPU pilot acceptance. The old CUDA
`$OLD/heart-calibration-copper-zonal-cuda-prepared4` is also a frozen scientific
blueprint: plant SHA `887ee920...6ee93`, seed531, declared554×16 plan SHA
`dfd2c32b...4ab1c`. A small caller on it cannot qualify that full method/inverse.
The old n2 native pilot uses CPU; an SDK refresh alone cannot make it CUDA.

Use the common five-argument `qualify_calibration_native.jl` recipe for each
of the six selected fresh calibration packages, with the table's called plan,
separate `collect` and `capture` admissions and fresh runtime/output names.
Both current HEART normal bases retain the same ordinary plant hashes as their
FGN equivalents, but they supply no full-transfer or active-correction authority.
The frozen correction packages listed earlier still have marker descriptors,
SDK0.6.12/adapter0.1.0 and runner490f; they need explicit native descriptor/helper
migration and current SDK/runner sealing before the new correction coordinator
can run. Preserve their active contracts, selected inverse/reference files and
immutable admission ledgers exactly. This inventory creates no packages and
starts no SCI; allocation/cleanup, calibration effects and correction utility
remain actual-run gates.
