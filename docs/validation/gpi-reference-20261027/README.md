# GPI online reference calibration — 2026-10-27

Status: source integration qualification passed; registered-release application
qualification remains pending. No activation claim. The maintained delivery status is in the roadmap's Current work section.

The shared initial-calibration owner holds the explicitly named woofer, tweeter
and tip/tilt figures coherently. GPI uses projections of its normal built graph.
Dark reduction consumes full UInt16 ADC frames online; consumer-only Collect
returns complete exposure receipts without duplicating an image in its bounded
control reply. Lamp/qualification consume the normal normalized pyramid pixels.
AOC owns the means and negative pupil-major reconstruction. The first successful
lamp frame is discarded for previous-frame normalization. Source brightness,
detector electronics, pupil geometry/mask, reconstructor and 25 Hz filter remain
unchanged. GPI preparation is manual or scripted; physical services and a future
instrument sequencer are separate work.

## Source cohort

- Instrument merge base c7d31d3; authored selections/CLI commit 2f2ba33.
- AOC bounded reduction 2a09ee5657e9082a161a9d6ac7a07dd8fbde9f98.
- AOS named boundary 64b302425a6d1d2920f34a19e6c4d26b0fff0e60.
- HIL named transport 8fcbaba6a0836d8851d5ea4363f48ff2c497af43.
- RTC named owner 8dce9e0, packing 3bbe907, reference procedure aa33e17,
  ADC layout correction 26a1ecd, consumer-only Collect 31c5078, bounded stage
  receipts 7a4e20c and conversion specialization a9e31d2.

Validation uses Julia 1.13.3, CPU and caller-owned private cores. The explicit
source environment still carries the previous package version metadata; it is
not evidence for a new registered release. No GPU, desktop core or physical
instrument is used. Applications and frozen source/FITS bytes remain unchanged.

## Observed checks

- AOC: 255 focused assertions and full required CPU package tests; independent
  dark/lamp 110 and actual FGA 0.8.6 parity 19.
- AOS: algorithm graphs 1,085 and quality 67.
- HIL: core/quality 1,134; isolated scalar 1,632; named private-core 110, also
  independently repeated by the parent. Unchanged HIL 0.2.7 passed the same
  isolated scalar selector.
- RTC named contracts 40, generic capture 94, aliases 48, named transport 16,
  scalar transport 27, Classic initial lifecycle 106 and stale FITS bindings 6.
- Full Classic reference campaign 87: all three stages restored/released;
  176 eligible ROIs, valid frozen qualification, RMS 0.008752788613187231 pixels
  in this explicit source environment. Do not infer exact parity with a
  different registered dependency cohort.
- Packing: 238 focused checks. The unchanged byte loop is specialized once on
  its concrete permutation. Exact types/ranks/order/cancellation checks pass.
  The actual 1,509×11,104 Float32 R packs in 0.08–0.13 s after warmup on this
  host. This is a scoped serialization measurement, not RTC latency evidence.
- Core suite after consumer-only extension: 6,580 assertions across 246 sets.
  The later unchanged conversion-loop extraction additionally passes all 238
  artifact checks and exact actual-R data/hash/callback parity.
- Collect0 focused checks 318; unchanged acquisition regression 234, revised
  native client independently 56. Native consumer-only capture 29 includes
  capacity rejection before exposures, full ADC consumption, failure drain,
  restoration and release. Final native selectors pass 29 consumer-only and
  211 positive-measurement capture checks.
- GPI cold geometry/projections 18; ADC/authority focused checks 69. The
  production, dark and lamp selections have identical detector/layout settings:
  UInt16 [242,240], scale 1/64, bias 1024, nearest-even range [0,16383].
- Combined GPI helper/cold/live selector: 153 checks passed, including 66
  complete campaign/cancellation checks. All three stages are Valid and
  restored/released. At unchanged source level the later reference-window
  difference is 0.3108964362989337 RMS dimensionless pupil pixels (maximum
  1.2179779743310064). Minimum lamp/qualification mean pupil intensities are
  2.9864888191223145 and 2.991450786590576; maximum ADC values 2892 and 2759.
  This demonstrates numerical validity, not scientific precision acceptance.
  This source cohort includes one nonterminating diagnostic stack snapshot;
  fresh registered qualification must run without instrumentation.
- Instrument source selections 34, CLI named/scalar FITS bindings 7 and
  formatter check pass.

## Review findings and retained failures

- RTC-N01: a failing projection close could skip another close and hide the
  preparation error. Fixed; the same injected failures pass 13 checks.
- RPC-01: Pyramid recipe rejected the new references key. Original public cold
  selector failed; bounded allowlist corrected and public cold pass-after passes.
- RPC-02: OPD authority was not bound to actual R/selection bytes. Exact receipt
  hashes, HDU and axes are now enforced; 13 mismatch checks pass. No incorrect
  current calibration data were observed.
- RPC-04: GPI ADC range belongs to its declared frame-layout node, not the
  EMCCD detector's bits field. Actual public pre-stage failure retained;
  explicit endpoint/layout validation and 28 malformed-layout checks added.
- PACK-01: dynamic permutation indexing dominated packing. Owned-process stack,
  Base inference and an identical-loop experiment established the cause before
  the minimal function-barrier fix. Wire/artifact bytes are unchanged.
- PACK-02: FITS decode/permutation left repeated value conversion dynamic.
  An owned-process stack, concrete closure inference and identical-loop
  experiment established the cause. The second minimal barrier preserves
  exact converted values, hashes and cancellation checkpoints; 238 checks pass.
- CZ-01: optional stronger client dimension fencing changed known-invalid
  restoration behavior. Reverted that unrelated policy change. The unchanged
  acquisition selector went from 10 failures to 234/234 passing; callers retain
  scientific batch validation, including exact counts in the reference stage.

Complete local logs and independent review artifacts are retained in the
separate gpi-reference-validation-20261027 validation directory. The initial
recipe rejection, deliberate cold-only interruption, ADC lookup failure and
all earlier failed transport evidence are retained; successful repeats do not
erase them. The earlier aggregate scalar HIL WFS timeout remains unexplained.
The historical publication-cycle witness is not immutable cycle ownership
across resets. Fresh owners/domains are used per stage. Physical readiness,
scientific precision/acceptance, interaction-matrix activation, wall cadence
and resource/deadline qualification are not established by these CPU tests.
