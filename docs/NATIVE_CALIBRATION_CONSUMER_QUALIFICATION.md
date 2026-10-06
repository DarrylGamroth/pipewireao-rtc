# Installed native calibration consumer qualification

2026-10-06. Cold preparation checkpoint RTC `8478ee69e1776cdfee2dad8ace8ebb46b8226490`.
Dedicated worktree `pipewireao-rtc-native-calibration-consumer`, initially clean.
This increment supports RTC-DEV-029/030 and the remaining RTC6/7/9 installed
consumer gates. It does not close those issues or establish matrix, correction,
rate, allocation or physical-device acceptance.

## Frozen first fixture

Cache root: `/home/dgamroth/.cache/rtc-native-calibration-final-20261006`.

| Input/output | Cold proof |
| --- | --- |
| Base `rtc-native-final-deployment-20261006/classic-fgn-v6-installed` | All 565 sealed artifacts match; unchanged CUDA plant at 500 Hz model period and 1,896,000 ns detector exposure |
| New `classic-fgn-native-calibration-v1-installed` | All 560 artifact hashes match; 332 retained plant/scientific package/library/selected WFS parameter files match the base exactly |
| Existing `rtc-calibration-quality-20261003/method-smoke-reverse-v2/canonical-plan.json` | Copied byte for byte as `frozen-plan.json`, SHA-256 `f6d8d2a29119ac437a0b36e60d0d88cbe986f4dce27c1691179f8ac1c181d011` |
| Plan | Run 82, zero 277-coordinate reference; four existing ±0.02 µm OPD figures on coordinates 11 and 64; 376 measurements; 16 contributing exposures per probe; discard one exposure; existing 20 s request deadlines |
| Capture | Separate fresh run of the same installed package; first existing probe, two exposures; whole-session payload budget 500,504 bytes declared before effects |
| Binaries | Runner SHA-256 `7968051f1d4d591414f6cffb995f6efbacc4099ccb881bd3a268e67423f9a341`; Rust calibration SHA-256 `ce0ba26cf04f64ea1cb730c4b89309592c5097843cc326d867c4ddd1bfe9b1cb` |

`CalibrationExport.export_package` splits the selected WFS and command nodes
using its existing public conversion. Unused integration graph assets are
omitted, not replaced by a new calibration. No dark/reference acquisition,
plant execution, inverse estimation, coefficient changes or clipping-policy
changes occur during preparation. The operational acquisition owner uses its
existing stationary lamp condition and normal configured noisy ADC detector.
CUDA acquisition follows the existing target-generic preparation implementation;
successful installed CUDA effects remain to be observed.

The installed runtime's 43 Julia sources match the checkpoint. Both Julia
environments bind to the staged public PipeWireAO 0.6.16 source (`6e4e1ee`),
and the adapter retains its qualified 0.1.2 source (`15fd37d`). The actual Julia
executable is 1.12.7. No marker or calibration-socket argument is selected.
The installed cold client printed its staged SDK/runtime source paths and
preflighted every Adopt/Restore figure. Collect replies occupy 2,568 bytes for
the selected measurement/frame counts, below the 128 KiB transport bound.

Preparation recipes, full science/seal proof, logs, binary receipts and the
fully verified redundant-stage restoration ledger are retained under the
cache root. Only the new duplicate stage was archived; the installed package,
original base, original plan and prior scientific evidence remain.

## Coordinator and evidence contract

[`deployment/qualify_calibration_native.jl`](../deployment/qualify_calibration_native.jl)
launches one fresh owned foreground deployment in `collect` or `capture` mode.
It retains the native supervisor client obtained during admission and a fresh
exact PID/incarnation acquisition-lifecycle client. The action caller binds
the same exact owner and action profile; saved metadata supplies hints only.

- **Collect:** the unchanged installed Rust coordinator performs
  Hold→Adopt→Settle→Collect for the frozen four probes, then Restore→Release.
  The qualifier checks finite Float32 response extents, batch counts, exact
  acquisition domain/generation/duration, consecutive contributing sequences,
  non-overlapping model exposures and the declared discarded-exposure gaps.
- **Capture:** the Julia native action client performs Hold→Adopt→Settle→Capture
  for two exposures, verifies the immutable manifest/payload hashes, byte counts,
  channel contracts, run/serial/probe, exposure identities and final cursor,
  then performs Restore→Release. Capture evidence is copied before shutdown.
- **Restoration/publication:** a fresh native lifecycle Status must establish
  released, unheld, restored, completed facts with an exact report cursor.
  Only then is the saved report read and checked. Collect additionally requires
  a later same-domain/generation cursor and model boundary after the final
  contributing exposure, demonstrating the selected restoration settling fence.
- **Unsupported Reset:** a paused, restored calibration owner must return -95
  requiring a fresh instance; a subsequent native Status must retain its cursor,
  phase, hold, restoration and completion facts.
- **Cleanup:** session stop and quit use the retained admitted supervisor client.
  Final report acceptance follows exit of the owned launcher and removal of its
  private runtime. Existing qualification helpers audit captured detached child
  identities and provide bounded owned-launcher reconciliation on failure.
  No speculative Restore/Release or automatic reconnect follows an unknown
  action outcome. Partial evidence and native cleanup failures remain visible.

## Cold verification and pending installed runs

Focused pure evidence tests passed **26/26** on CPU11. They discriminate wrong
run, incomplete restoration, invalid/nonfinite/wrong-length responses, stale,
duplicate, overlapping, wrong-domain/generation/duration and overflowing exposure
records, missing settling gaps, Reset changing retained owner facts, and waiting
for native report publication after the resolved Release completion. These
tests do not execute a plant or demonstrate an installed action effect.

Cold test command (worktree root):

```sh
taskset -c 11 env JULIA_PKG_OFFLINE=true \
  /home/dgamroth/.julia/juliaup/julia-1.12.7+0.x64.linux.gnu/bin/julia \
  --startup-file=no --project=deployment/julia \
  deployment/julia/test/test_qualify_calibration_native.jl
```

After explicit SCI reservation, run the following twice with distinct fresh
runtime/output paths and mode `collect`, then `capture`. The admitted original
placements require SCI CPUs 2/12/14; CPU11 is the cold coordinator. This is a
command recipe, not executed installed qualification evidence:

```sh
RTC=/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-native-calibration-consumer
CAL=/home/dgamroth/.cache/rtc-native-calibration-final-20261006
PKG="$CAL/classic-fgn-native-calibration-v1-installed"
taskset -c 2,11,12,14 env OPENBLAS_NUM_THREADS=1 JULIA_PKG_OFFLINE=true \
  /home/dgamroth/.julia/juliaup/julia-1.12.7+0.x64.linux.gnu/bin/julia \
  --startup-file=no --project="$PKG/julia" \
  "$RTC/deployment/qualify_calibration_native.jl" \
  "$PKG" "$CAL/FRESH_RUNTIME" "$CAL/FRESH_OUTPUT" "$CAL/frozen-plan.json" collect
```

Actual effect, capture, Reset and cleanup gates remain **pending** until those
separate fresh runs have been observed. Broader Classic/Copper FGN/JFG and
unchanged HEART consumers follow after this first installed discriminator;
this artifact does not silently reduce that matrix.
