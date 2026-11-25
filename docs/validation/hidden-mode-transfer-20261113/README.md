# Hidden-mode controller preparation transfer

The shared instrument tools at `a4f81a1` own the offline hidden-mode controller
preparation through `tools/prepare-hidden-controller.jl`. They use
AdaptiveOpticsCalibration for the numerical reduction and the existing RTC
bundle and graph binding interfaces. RTC retains live calibration acquisition
and removes the former `InstrumentCalibration.calibrate_hidden_modes` entry point.

## CPU verification

The baseline used registered RTC 0.7.19. The candidate used the shared tool
module in the same registry environment. Both read the saved GPI2 reference
bundle from the [0.7.19 check](../rtc-0719-20261112/README.md). The two FITS
transforms and the result YAML were byte-identical.

| Product | SHA-256 |
| --- | --- |
| `hidden-to-shape.fits` | `3b356db7969f595a20fb9fb6c28b96c58e49761519181ed3ef499c2b1b006e1e` |
| `shape-to-hidden.fits` | `3c32fce496c3fd18d67b060d4ea41cb149e22bfa018fbb9f748df087db011e81` |
| `result.yaml` | `2775973b48cc3e65926910fe7ba29a7448dd1e2cb22e420339704dd44f3b241c` |

The result retained rank 1445 and selected 64 hidden modes. The reconstructor
relative error was zero, the idempotence residual was
`1.5722545459025379e-6`, and the discarded measurement relative response was
`0.003603506212751827`.

The shared hidden-mode selector passed 65 assertions. The GPI2 graph selector
passed 27 assertions across the integrator and hidden-mode profiles. In a
disposable copy of the authored GPI2 configuration, the shared controller
launcher regenerated the declared `rtc/heart` output. RTC exported the profile
and its typed FITS bindings loaded. The modified RTC checkout passed the core
suite. These checks cover offline CPU preparation and export.
