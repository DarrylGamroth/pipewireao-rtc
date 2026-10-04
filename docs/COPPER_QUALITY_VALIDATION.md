# Copper precision and amplitude pilot validation

## Qualified scope and sources

The predeclared [plan](COPPER_QUALITY_PLAN.md) was implemented from RTC
`5565d6e` in the dedicated `work/copper-calibration-quality-20261003` worktree.
Implementation commit `5cf8182` contains the maintained Python acquisition and
thin public-AOC analysis, their portable tests and usage. The
[independent review](COPPER_QUALITY_REVIEW.md) cleared the frozen implementation
before live acquisition and audited both completed installed windows.

This is one physical direction, one detector seed and one provisional CPU plant
fixture. It qualifies bounded collection and reproducible characterization,
not scientific precision, linearity, a full interaction matrix or correction.
No HEART source, graph hot path, AOC numerical implementation, operating gain,
clipping limit or kernel setting changed. No external algorithm source was copied;
existing AOC reuse/license limitations remain in
[calibration provenance](CALIBRATION_PROVENANCE.md).

Evidence lives under `~/.cache/rtc-copper-quality-20261003/`. The
[evidence ledger](COPPER_QUALITY_EVIDENCE.json) binds recipes, sources, binaries,
package seals, receipts, manifests, numerical products, independent reduction
and test logs. Qualified source copies and release binaries are retained there,
so subsequent builds do not erase the experimental implementation.

## Installed FGN/JFG collection

The two science bases and measured dark/reference candidates remain the prior
qualified Copper fixtures. Only detector seed 444 and measured background are
selected in the new lamp package; all graphs, pupil selection, command maps,
flat and other detector/plant settings are preserved. Lamp magnitude is
5.752574989159953, exposure 2 ms and model period 100 ms. Normal photon/read
noise and ADC behavior remain enabled. This historical fixture is not a
qualified DU860 EMCCD gain/noise configuration.

Both engines acquired 16 held batches, eight exposures each: two reversed
amplitude/sign traversals of physical actuator 139 at Float32 ±0.02, ±0.04 and
±0.08 µm OPD, with four null batches. Every adoption was unclipped and matched
its requested absolute 277-coordinate figure. Each completed batch was copied
and hash-verified before advancing.

Each run has 51 correlated requests, 16 discarded settling exposures and 128
retained exposures through sequence 144. Fresh restoration ends at sequence 145.
Reference restoration, release, public stop/quit, launcher exit zero and removal
of owned runtime/processes were confirmed for both. All retained responses are
intrinsically valid, with positive current intensity and maximum ADC 66, below
rail 16383. No declared sample was removed or delivery failure hidden.

All **128 paired raw ADC, pixel and intensity samples are byte-identical**;
all four Float64 numerical products also match byte for byte. This is evidence
for the same measured acquisition and calculations in these two paths. Their
common seed is not two independent scientific repetitions.

The existing optional `support/libspa-dbus` load warning was emitted by the
headless private PipeWire contexts. Both contexts reached readiness and completed
the required transport/control/lifecycle gates; this run did not qualify DBus
integration.

## What the measurements show

| Actual Float32 amplitude label, µm OPD | Cosine between repeated derivative estimates | Relative repeat/order difference |
| --- | ---: | ---: |
| 0.02 | 0.046794 | 1.412178 |
| 0.04 | 0.165896 | 1.293006 |
| 0.08 | 0.437776 | 1.075285 |

Relative difference is ‖d₂ − d₁‖₂ / ‖d₁‖₂. The larger derivative norm at the
smallest amplitude is not evidence of greater physical sensitivity: dividing
response dispersion by a smaller command interval magnifies it.

Null-batch mean differences are 0.098311–0.101209 normalized pixel RMS
(vector norms 5.899–6.073). Multiplying each derivative discrepancy by its
represented command interval gives response-space norms 8.4586, 8.5020 and
8.5181, nearly independent of amplitude. These lie within the descriptive
√2-scaled null-difference range 8.34–8.59. This supports measurement dispersion
as an explanation for inverse-amplitude derivative disagreement. It does not
prove independent photon noise, rule out normalization/order effects or
separate causal nonlinearity.

The earlier independent-reference residual of about 0.0984 normalized pixel RMS
is consistent in size with this null-batch variability. The two eight-frame
traversals are too weakly repeatable to justify selecting a full physical matrix
or a reconstructor. No instrument tolerance was supplied or invented. Preserve
pair-midpoint, intensity and first-versus-later diagnostics in `analysis.json`;
no drift correction, sample rejection or active reference subtraction was applied.

## Independent numerical checks

A cold NumPy audit reads the hashed operational payloads and independently
calculates batch means, N−1 variances and signed secants using the actual
represented command intervals. It checks all four saved products and 378 report
scalars per engine. Maximum product differences from public AOC are:

| Product | Maximum absolute difference |
| --- | ---: |
| Batch means | 1.1102 × 10⁻¹⁶ |
| Batch variances | 8.3267 × 10⁻¹⁷ |
| Repeated derivatives | 2.6645 × 10⁻¹⁵ |
| Mean derivatives | 1.7764 × 10⁻¹⁵ |

These are within the declared machine-roundoff comparison bounds, unrelated to
scientific acceptance. Three portable audit tests verify a synthetic pass,
rejection of rehashed biased variance and rejection of changed payload bytes.
The independent reviewer separately rehashed every source/package/capture
identity and recomputed arrays and principal metrics; its review distinguishes
that pass from the parent's full report-scalar audit.

## Software verification and failure evidence

- Deployment Python suite: 185 cases, two existing environment-dependent skips.
- Focused acquisition/quality Python suite: 24 cases.
- New Julia quality analysis: 230 assertions, also rerun by the primary agent.
- Existing Julia reference analysis: 232 assertions.
- Existing calibration server/client regressions: 524 / 105 assertions.
- Whitespace checks passed; Rust runtime code was unchanged in this increment.

CQR-5's initial batched implementation copied payloads only after all probes,
so later failure would lose earlier raw data at runtime cleanup. A reconstructed
pre-fix copy placement fails the same retained-payload test that passes current
source. Both logs and the reconstructed experimental source are preserved;
this is a portable mechanism reproduction, not a historical live failure.
The repaired path saves/verifies each completed batch immediately and retains
its receipts on a later failure, restoring only when the existing known-outcome
rules permit it.

The initial 18 failures in six new lexical-number mutation cases exposed
JSON3's integral-number normalization, rather than a numerical association
failure. Review CQR-6 rejected an added lexical spelling requirement. The helper
uses the documented public parser, validates parsed integer values and rejects
nonintegral identities/extents and Booleans; it introduces no custom JSON parser.
The original failing-policy evidence and final 230-assertion pass remain retained.

## Calibration wall costs

| Cost | FGN | JFG |
| --- | ---: | ---: |
| Startup readiness | 45.463 s | 77.647 s |
| Held acquisition and evidence storage | 51.255 s | 50.534 s |
| Public shutdown | 1.058 s | 1.253 s |
| Total live stage | 97.777 s | 129.434 s |
| Cold analysis process | 11.513 s | 11.483 s |
| Total workflow | 110.452 s | 142.250 s |

The multi-batch session amortizes startup across all probes. These are single
cold workflow observations including simulator, first-use compilation, control
and storage costs; per-operation costs are not isolated. They do not compare
steady-state RTC latency or establish a maximum simulator/RTC frame rate.
Configured exposure/model duration is not wall pacing. Placement admitted CPUs
2–15, with CPU 0 and CPU 1 excluded; live windows were serialized.

## Next scientific gate

The cheapest proposed discriminator holds physical amplitude 0.04 µm OPD and
N8 fixed, uses opposite sign orders and null brackets with a fresh detector
seed, and declares ten times brighter calibration illumination (magnitude
3.252574989159953). Keep detector/gain/background/settling unchanged and measure
achieved intensity, ADC rails and response-space dispersion. This is a proposed
new frozen experiment, not permission to silently change the current recipe or
accept a matrix. The current CLI requires its producing reference candidate to
use the same lamp magnitude. A changed-lamp experiment needs a separately
reviewed configuration/contract extension or a matching new producer candidate. A same-setting N16 window is an alternative if lamp change is
not selected; variance scaling remains conditional on correlation.

Copper scientific precision and linearity, full 277-coordinate calibration,
composition into 253 controller coordinates, held-out inverse selection,
deployed correction, unchanged HEART and accelerator qualification remain open.
RTC-DEV-029 remains partial for its full selected scope.
