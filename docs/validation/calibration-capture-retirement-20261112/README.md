# Calibration capture-file retirement verification

The changes implement the CaptureFiles and CalibrationCLI retirements
identified in the [scope review](../../reviews/20261112-calibration-scope/REVIEW.md).

The acquisition CLI removal passed the focused acquisition and package
tests before commit `f2d8eb5`. The focused retirement checks passed
983 assertions and the full RTC core suite passed 10,454 assertions with
the registered PipeWireAO_jll prefix. The native codec tests retained byte-for-byte
checks for the supported operations and rejected the frozen Capture request
and Captured reply. Operation ID and result tag 5 remain reserved. Recipe
validation rejects a former file capture declaration. The private-core
collector test passed 16 assertions for consecutive multi-port exposures,
payload and metadata correlation, and rejection of a mismatched identity.

## Reference calibration on private cores

The selectors ran with Julia 1.13.3 against the candidate checkout in
separate temporary Julia projects and existing CPU exports. The Classic
selector used four default and one interactive Julia thread, and GPI2 used
six default and one interactive thread. The selectors checked that the
exported applications remained unchanged. Both used the PipeWireAO_jll
4.0.2+0 daemon and PipeWireAO 0.9.2. The science cohort was
AdaptiveOpticsCalibration 0.17.3, AdaptiveOpticsSim 0.3.22,
AdaptiveOpticsSimPipeWireHIL 0.5.1, FilterGraphAlgorithms 0.12.2 and
FilterGraphs 0.10.2. FilterGraphPipeWire was 0.5.3 for Classic and 0.5.5
for GPI2.

Classic passed 43 cold and 57 live assertions. Dark, lamp training and
qualification each collected 16 exposures through live Collect. Each
stage restored and released its owner. Qualification was valid, with
176 eligible ROIs and a reference difference of 0.0087528 pixels RMS.

GPI2 passed 91 cold and 66 live assertions. Dark collected 16 exposures,
lamp training collected 512 and qualification collected 512 through live
Collect. Each stage restored and released its owner. Qualification was
valid, with a dimensionless reference difference of 0.0549590 RMS. The
live test finished in 14 minutes 26 seconds and closed its private core.
