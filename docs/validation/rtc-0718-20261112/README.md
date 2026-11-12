# RTC 0.7.18 CAL2 optical calibration verification

[PipeWireAORTC v0.7.18](https://github.com/DarrylGamroth/pipewireao-rtc/releases/tag/v0.7.18)
tags `a2a4feab2b4bf3928db698e9cbd9b99078331095`. The
[registry entry](https://github.com/DarrylGamroth/PackageRegistry/commit/98039637b80ab460d6fda99f2abd3b1be71485ec)
selects tree `b90986c812134bc89f943847abc349da3ef540b6`. The release commit
updates the Project and workspace Manifest versions after the
[optical campaign transfer](../optical-campaign-transfer-20261112/README.md).

Julia 1.13.3 instantiated an empty depot with General and
DarrylGamrothRegistry. The 200-package Manifest contains no local package
paths or repository overrides. The installed RTC and AdaptiveOpticsCalibration
source trees matched their registered hashes. The other 199 Manifest entries
matched the earlier CPU comparison. The environment includes
AdaptiveOpticsCalibration 0.17.4, AdaptiveOpticsSim 0.3.22,
AdaptiveOpticsSimPipeWireHIL 0.5.1, FilterGraphAlgorithms 0.12.2, FilterGraphs
0.10.2, FilterGraphPipeWire 0.5.3, PipeWireAO 0.9.2, PipeWireAO_jll 4.0.2+0,
and Proper 0.4.1.

The test uses the shared launcher and module at instrument revision `692cd7e`.
The CAL2 optical CPU profile is exported with the resolved Project and Manifest
in a temporary application. The upstream GPI2 application is the retained
input from the transfer comparison. The experiment uses one BLAS thread
and the PipeWire prefix from the depot's artifact.

The exported Project and Manifest matched the resolved environment
byte-for-byte. The Manifest SHA-256 was
`ed9c39268e159e3d5fc0d3f81cfa9278f80315a1edc5c015d5d6a6bd72e2ee3b`.
The CAL2 deployment catalog, optical recipe and materialization recipe
had the same hashes as the earlier CPU comparison.

## CAL2 CPU results

The campaign completed 36 poses with 512 samples and 128 rounding samples.
Both LLOWFS and SCC passed the optical and upstream reference acceptance gates.
The published graph for each branch prepared successfully with its typed
FITS startup arrays, and all artifact and report hashes validated.

Compared with the pre-transfer RTC baseline, 56 of 65 files matched
byte-for-byte. These include both optical branches' full- and half-poke
interaction matrices, reconstructors, held-out coefficients and concrete
graphs. Optical held-out diagnostics matched exactly. The maximum
reconstruction error was 0.001285095 and the maximum residual pupil RMS
ratio was 0.001459474.

| Upstream reference check | Baseline | RTC 0.7.18 | Recipe limit |
| --- | ---: | ---: | ---: |
| Full-to-half derivative upper estimate | 0.004377966 | 0.004377368 | 0.05 |
| Worst held-out prediction upper estimate | 0.010596417 | 0.010606811 | 0.05 |

Relative L2 differences were 1.742×10⁻⁵ for the full-poke reference matrix,
3.502×10⁻⁵ for the half-poke reference matrix, and 1.623×10⁻⁶ for the upstream
flat residual. The two branches share these products. Their differing bytes
changed the reports and index hashes. The registered release produced
calibration identity
`sha256:8abcddc752dc2ace42c6307574690940eaa560c74928b95b609c3b424ef5eea1`.

This was an offline CPU calibration and publication check. No PipeWire core,
systemd service or physical instrument was started.

Instrument main fast-forwarded to `355c1392f790b4db9445eeaf382d98753f450081` after verification.
