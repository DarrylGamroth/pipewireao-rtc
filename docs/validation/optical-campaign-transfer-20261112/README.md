# Offline optical calibration campaign transfer

The [scope review](../../reviews/20261112-calibration-scope/REVIEW.md#cal-scope-04--split-offline-optical-calibration-by-responsibility-before-transferring-it)
places the offline campaign in the shared instrument tools. The
`OpticalCalibration` Julia module sits behind `tools/calibrate-optical.jl` in
the instrument repository. Instrument YAML selects the recipes, graph
templates and acceptance criteria. AdaptiveOpticsCalibration supplies the
numerical methods. RTC retains live acquisition, cold graph preparation
and typed artifact validation for deployment.

## CAL2 CPU comparison

RTC baseline `c9a32dc` ran the launcher from instrument revision `3691478`.
The candidate ran the shared module with the matching RTC API changes.
Both used Julia 1.13.3, one BLAS thread, the same retained GPI2 upstream
application and the same fresh CAL2 optical-calibration CPU export from
instrument revision `3691478`. The science manifests differ only in the RTC
checkout. Both select AdaptiveOpticsCalibration 0.17.4, AdaptiveOpticsSim
0.3.22, AdaptiveOpticsSimPipeWireHIL 0.5.1, FilterGraphAlgorithms 0.12.2,
FilterGraphs 0.10.2, FilterGraphPipeWire 0.5.3, Proper 0.4.1, PipeWireAO 0.9.2
and PipeWireAO_jll 4.0.2+0.

| Input | SHA-256 |
| --- | --- |
| GPI2 `deployment.conf` | `a529a2329b62f40cc60c0d7dba4eac3f7ca1dacffa485f8c548f35c955820b13` |
| CAL2 `deployment.conf` | `5a96690f7e3632dd6978df890c8ec6e5776cd02df4941658699c6f449ab1bac1` |
| CAL2 `calibration/optical.yaml` | `c4b0599fc6a8ddb57b4be6cd40015c3b2cf5df195ea419603513a832a31acdc2` |
| CAL2 `calibration/materialize.yaml` | `9e6bef57e1eb0cde2a297b2b2b33c525b3fb421144aa4044db6626db904a8675` |

Both runs processed 36 poses, with 512 samples and 128 rounding samples
per the retained upstream `host-expectation` recipe. Both produced accepted,
deployable LLOWFS and SCC candidates. Each branch's published graph passed
preparation with its typed FITS inputs.

Of 65 output files, 56 were byte-identical. These include the full- and
half-poke interaction matrices for both optical branches, both reconstructors
and published graph files, and the held-out coefficients. The optical
held-out diagnostics were identical. The maximum reconstruction error was
0.001285095 and the maximum residual pupil RMS ratio was 0.001459474.

| Upstream reference check | Baseline | Shared tool | Recipe limit |
| --- | ---: | ---: | ---: |
| Full-to-half derivative upper estimate | 0.004377966 | 0.004376145 | 0.05 |
| Worst held-out prediction upper estimate | 0.010596417 | 0.010572202 | 0.05 |

The upstream full- and half-poke reference matrices had relative L2
differences of 1.966×10⁻⁵ and 3.853×10⁻⁵. The upstream flat residual had a
relative L2 difference of 2.043×10⁻⁶ and a maximum absolute difference of
2.386×10⁻¹³ m. These three FITS artifacts occur in both branch bundles. Their
hashes changed, as did the upstream numerical diagnostics, branch reports and
index. Every published artifact and result hash validated in its own bundle.
The resulting calibration identities were
`sha256:6aa2c457daec23e391285f92f4b1723ee1ab1646fb434afbefa62371b862634c`
and
`sha256:07545a2971045faf4e7ebac747c4713a76a7f33e763f26718819786c18e9177f`,
respectively. AdaptiveOpticsSim uses measured FFT planning on CPU. The
comparison did not capture selected FFT plans or isolate the source of the
upstream roundoff differences.

## Regression selectors

| Selector | Passing assertions |
| --- | ---: |
| RTC `test/runtests.jl` | 10,571 |
| Instrument `test/calibration_command_domain.jl` (includes `calibration_optical.jl`) | 211 |
| Instrument `test/calibration_chopped.jl` | 58 |
| Instrument `test/calibration_optical_publication.jl` | 72 |
| Instrument `test/calibration_detector_observation.jl` | 25 |
| Instrument `test/captured_optical_calibration.jl` on CPU | 47 |

The optical selectors and campaign run offline. The CPU comparison covers
simulated optical calibration and cold graph preparation. Live instrument
operation, accelerated targets and closed-loop qualification are outside
this verification.
