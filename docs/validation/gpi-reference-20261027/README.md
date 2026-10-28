# GPI online reference calibration — 2026-10-27

Status: source and fresh registered-release CPU/private-core qualification
passed. Products remain candidates; no activation claim. The maintained delivery status
is in the roadmap's Current work section.

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


## Registered release cohort

All four changes are merged to GitHub main, tagged, published and registered:

| Package | Release | Registered tree |
| --- | --- | --- |
| AOC | [0.17.3](https://github.com/DarrylGamroth/AdaptiveOpticsCalibration.jl/releases/tag/v0.17.3) | `b3e6fda93f3bd1a1c8a94fd5472dc170aa051e65` |
| AOS | [0.3.5](https://github.com/DarrylGamroth/AdaptiveOpticsSim.jl/releases/tag/v0.3.5) | `a9eecf2c1b70c5644abca50e226a91d9653271b3` |
| HIL | [0.2.8](https://github.com/DarrylGamroth/AdaptiveOpticsSimPipeWireHIL.jl/releases/tag/v0.2.8) | `33d1575c5efb076fd9dcf12be0447c5c968001c0` |
| RTC | [0.2.32](https://github.com/DarrylGamroth/pipewireao-rtc/releases/tag/v0.2.32) | `9f02db32756d18abd73f791da857000370020b36` |

Fresh registry-only GPI and Classic environments resolve their authored exact
pins. Every installed package tree above matches its registered hash; neither
manifest contains path or repository overrides. Classic retains FGA 0.8.5 /
FGPW 0.1.11; GPI retains FGA 0.8.6 / FGPW 0.1.12. Both CPU builds passed with
unchanged source and manifest hashes and no GPU modules loaded. Manifest hashes:

- GPI: `bfe244d51aab720f6e4f4e7657bbeca17b1987452a7feb5d200d7bab6a3b77c3`.
- Classic: `c39a48b925903badc0856cda4662b4c40cb23c9b48c8e4db138020fa3a94ee57`.

The installed Classic selector passes 87 checks; all three stages are Valid,
restored and released, with 176 eligible ROIs and diagnostic RMS
0.008752788613187231 pixels. The instrument calibration selector passes 161
checks in a tools environment whose resolved package entries exactly match the
Classic release environment, promoting only the same YAML 0.4.17 to a direct
dependency. The installed-release scalar/named CLI selector passes 7 checks.
The installed GPI selector passes 153 checks (67 grouped helper checks, two
standalone extension/no-GPU guards, 18 built-graph checks and 66 campaign/
cancellation checks). All three stages are Valid, restored and released. Its
reference-window RMS is 0.3108964362989337 dimensionless pupil pixels, maximum
1.2179779743310064, with the same source and detector settings. These diagnostics
match the source cohort but establish no precision acceptance or activation.
The final conversion barrier is present in this fresh cohort. Both owned
private-core processes exited, package trees and manifests stayed unchanged,
and no GPU module loaded. No repeat was needed.

Validation runners `registered-build.jl` and `registered-selector.jl`, build
receipts, complete logs and candidate receipts remain in the existing separate
validation directory. The selector loads tests from the installed registered
RTC package, checks the package tree and manifest before/after execution, and
uses caller-owned private cores. No diagnostic hooks, stack signals, tracing,
pulses or automatic retries are used for this registered cohort.
