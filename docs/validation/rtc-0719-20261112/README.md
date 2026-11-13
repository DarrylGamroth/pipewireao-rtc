# RTC 0.7.19 offline calibration verification

[PipeWireAORTC v0.7.19](https://github.com/DarrylGamroth/pipewireao-rtc/releases/tag/v0.7.19)
tags `73f1fa27f1cb7b92c296ff77574b6ac82d1a3f02`. The
[registry entry](https://github.com/DarrylGamroth/PackageRegistry/commit/d9591acea81bb7cfa364d7d6e420b2637578c6fd)
selects tree `e03cea72382b14801a6e48737c890dcb23365c13`.
The shared launchers are from instrument main `08fa4e6`.

Julia 1.13.3 resolved a 200-package environment from an empty depot with
General and DarrylGamrothRegistry. The Manifest contained no local paths or
repository overrides. The installed RTC and AdaptiveOpticsCalibration trees
matched their registry hashes. The other 199 Manifest entries matched the
[transfer comparison](../interaction-campaign-transfer-20261112/README.md).
The resolved Manifest SHA-256 was
`75079694dd203b4ba0f51d8c323a8390c6a1c05207e29da1975a93bea3451946`.

The shared `calibrate.jl` and `validate-calibration.jl` ran in separate
processes using the retained built Classic and GPI2 applications from the
transfer comparison. Each used one BLAS thread and the PipeWire prefix from
the new depot's artifact. Classic used default FFT planning. GPI2 reused the
same experiment-only `FFTW.ESTIMATE` control as the matched comparison.

## Results

| Instrument | Modes | Retained rank | Verified FITS artifacts | Offline replay |
| --- | ---: | ---: | ---: | --- |
| Classic | 212 | 208 | 25 | 512 frames, zero clipped actuator samples, 48.3800 nm mean pupil RMS after frame 128 |
| GPI2 | 1,509 | 1,445 | 36 | Four 48-step cases passed, worst residual ratio 0.00738855 |

GPI2 reproduced the fixed-plan baseline bundle byte-for-byte. All four replay
traces and scientific report fields matched after excluding per-step elapsed
times. Both runs checked the hashes in their generated bundles and matched
each validation report to the corresponding bundle. These are offline CPU
checks with simulated inputs.
