# Calibration staging transfer verification

This completes standard bundle staging from
[CAL-SCOPE-03](../../reviews/20261112-calibration-scope/REVIEW.md).
The baselines were RTC `1d0252b` and the instrument repository `1f2c65b`.
The shared instrument tool writes the staged source copy. RTC retains
source copying, graph reference resolution, typed bundle preparation,
publication validation and export.

## Fresh Classic CPU workflow

Julia 1.13.3 ran with the candidate RTC checkout, AdaptiveOpticsCalibration
0.17.4, AdaptiveOpticsSim 0.3.22, AdaptiveOpticsSimPipeWireHIL 0.5.1,
FilterGraphAlgorithms 0.12.2, FilterGraphs 0.10.2,
FilterGraphPipeWire 0.5.3, PipeWireAO 0.9.2 and the PipeWireAO_jll
4.0.2+0 prefix. The instrument source and CPU profile were the checked-out
Classic configuration and `profiles/simulator/host.cpu.example.yaml`.

1. Export the authored source through `InstrumentExport.prepare`.
   Acquire a fresh standard bundle with 212 modes and retained rank 208.
2. Run the shared instrument selector `test/calibration_staging.jl` with
   source, application, bundle, fresh destination, profile and host paths.
   The staging checks passed 17 assertions. They verified typed selection,
   path rejection and unchanged input directories.
3. Export the staged source through the same exporter, move that fresh
   application to a different path, and validate it there. The relocation
   checks passed 44 assertions. The deployment and file hashes validated,
   the concrete graph matched the bundle, and all 19 FITS parameter paths
   resolved inside the relocated application and passed typed readback.

The first staging attempt rejected a fresh bundle because regenerating
`subaperture-origins.fits` changed the bytes of a prescription input.
The typed arrays were equal. RTC now verifies the values and retains the
source bytes when that FITS file is also emitted as a bundle parameter.
The retained-bundle acquisition reproduced rank 208, staged with an
unchanged prescription identity and kept the origin file byte-for-byte.
The bundle selector passed 71 assertions, including rejection of a retained
FITS source whose values differ. A 160-frame Classic replay also passed
with the corrected acquisition and validation receipt source path.

The standalone CLI wrote the same staged receipt as the integration selector.
The full RTC core suite passed 10,491 assertions with the registered native
prefix.

The exports were offline. The test opened no PipeWire core, installed no
service and used no accelerator or physical device.
