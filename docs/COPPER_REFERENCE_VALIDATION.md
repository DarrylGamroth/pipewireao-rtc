# Copper measured dark/reference validation

## Delivered increment and sources

The maintained [candidate workflow](COPPER_REFERENCE_USAGE.md) completed paired
Copper CPU FGN/JFG dark, lamp training and independently seeded qualification
on 2026-10-03 local time. It started from RTC `2f62fd5` in the isolated
`work/copper-calibration-reference-20261003` branch. Scientific reductions use
public AOC `DarkFrameMoments` and `RepeatedResponseMoments`; no new estimator
or external licensed implementation was introduced. The active science graphs
and calibration sources remain unchanged.

The [evidence ledger](COPPER_REFERENCE_EVIDENCE.json) binds 260 local artifact
identities, frozen code, declared policy, base/package descriptors, receipts,
captured channels, products, tests and failures. Its evidence root is
`~/.cache/rtc-copper-reference-20261003/`. Source paths and hashes, rather than
the future merge commit, identify the exact uncommitted implementation tested.
The [independent review](COPPER_REFERENCE_REVIEW.md) tracks producer-binding and
campaign-snapshot repairs before live launch.

## Recipe and observed delivery

Both engines used eight exposures per stage, distinct detector seeds
111/222/333, zero 277-coordinate reference in µm OPD, lamp magnitude
5.752574989159953 and one completed discarded exposure. The 14-bit upper rail
was 16,383. Operation/stage limits were 30/300 seconds. The lamp stages received
the measured background; flat, pupil selection and command maps were retained.
The actual captured responses preserve 3,600 four-pupil values, with current
mean intensity recorded separately.

| Gate | Observed result |
| --- | --- |
| Three stages × two engines | All six stages captured eight consecutive exposures, sequence 2–9 |
| Adoption/restoration | Zero reference held and restored without clipping; final source sequence 10 |
| Lifecycle | Every stage restored, released, publicly stopped and exited with launcher status 0 |
| Cleanup | Final states stopped, no cleanup error, owned runtime removed; recorded owner PIDs absent after completion |
| ADC/lamp eligibility | No rail equality; lamp pixels/intensity finite, current intensity positive and intrinsic validity true |
| Actual paired inputs | All 24 paired raw ADC, normalized-pixel and intensity captures byte-identical, with matching sequence/model times and validity |
| Candidate products | All five FGN/JFG background, variance, reference and qualification products byte-identical |

Separate acquisitions have distinct full acquisition UUIDs. Equality was
verified from actual payloads; it is not inferred from matching seeds.
Dark maximum ADC was 5 and training maximum was 65. Dark intrinsic WFS validity
does not gate unsigned detector moments. No noisy sample was silently removed.

## Independent numerical checks

A cache-local NumPy 2.2.4 checker recomputed means and N−1 variances directly
from exported per-exposure bytes. The [ledger](COPPER_REFERENCE_EVIDENCE.json)
binds its source, synthetic tests and reports. The following differences apply
to both engine candidates:

| Product compared with independent reduction | Maximum absolute difference |
| --- | ---: |
| Float32 background | 0, byte-identical |
| Float64 dark variance | 4.44 × 10⁻¹⁶ ADC² |
| Float32 lamp reference | 1.86 × 10⁻⁹ normalized pixel, four of 3,600 entries |
| Float64 reference variance | 6.94 × 10⁻¹⁷ normalized pixel² |
| Float64 qualification mean | 2.78 × 10⁻¹⁷ normalized pixel |

Exact rational arithmetic on represented training samples shows that those
four means are exact midpoints between adjacent Float32 values. The public
moments reduction followed by Float32 conversion lands on the adjacent value
to NumPy's ties-to-even result at zero-based indices 779, 868, 875 and 986.
This is reduction rounding, not a transported-input difference. No numerical
owner was changed for this small representation effect.

The fresh qualification mean compared with the frozen Float32 reference gives
maximum absolute residual 0.4097372, RMS 0.0983978 and relative norm 0.0888074,
identical between engines. Independent metric recomputation differs by at most
2.36 × 10⁻¹⁶. These characterize this eight-frame noisy fixture. No instrument
tolerance was declared or inferred, so the reference is **not scientifically
accepted or adopted**. Previous-frame normalization can correlate successive
samples; descriptive variance is not used as a confidence interval.

## Time and software checks

| Observed time, seconds | FGN | JFG |
| --- | ---: | ---: |
| Dark acquisition, including settling/restoration/release | 9.486 | 9.432 |
| Lamp training acquisition | 14.799 | 14.939 |
| Fresh qualification acquisition | 14.927 | 14.848 |
| Complete cold campaign | 190.937 | 287.858 |

Each cold analysis subprocess took 7.2–7.6 seconds, including Julia startup and
compilation. Fresh package/owner preparation dominates the rest of the cold
campaign. JFG additionally prepares its external Julia graph. These are observed
single-run workflow durations, not steady-state algorithm or RTC throughput
benchmarks. The plant's 100 ms model period and 2 ms exposure do not establish
wall cadence.

Python deployment checks ran 175 tests with two skips; the new workflow has
eight focused portable tests. Julia's focused suite passed 232 assertions on
CPU 7, one default thread, no interactive thread, OpenBLAS one thread, bounds
checks enabled and deprecations as errors. CRR-1 retains the same tampered
reference fixture failing before the repair and rejecting after it. CRR-2
regressions detect changing base descriptors, AOC files and copied helpers.

The first FGN invocation was rejected before startup because the enclosing
single-core affinity mask excluded deployment cores. Its failed candidate and
logs remain preserved. A fresh retry admitted CPUs 2–15 without changing code
or recipe. Earlier Julia setup/test-oracle failures are preserved separately;
the final checks passed. Existing missing optional D-Bus support and cold Julia
precompilation/version notices remain in logs; they did not fail capture and
are not timing qualification.

## Remaining gates

RTC-DEV-029 remains partial. Next work must establish adequate precision and
linearity, reference centering/adoption in the science graphs, Copper's
277→253 coordinate composition, measured interaction matrix, frozen inverse
selection and correction. Unchanged HEART calibration and accelerator/cadence
qualification remain separate gates. The detector/DM plant is still provisional;
this fixture does not qualify the DU860 EMCCD or a physical instrument.
