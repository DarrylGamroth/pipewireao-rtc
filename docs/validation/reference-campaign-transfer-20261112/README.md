# Shared instrument reference campaign verification

This implements CAL-SCOPE-03 from the
[RTC calibration scope review](../../reviews/20261112-calibration-scope/REVIEW.md).
The source baselines are RTC `29eaea6` and adaptive-optics-simulations
`97fbb82`. The reference campaigns and selectors moved to the shared
instrument tools. The moved module uses the existing RTC preparation HSM,
PipeWire action client and native acquisition endpoint. It queries the
endpoint's acquisition domain and the client's restoration permission through
public APIs. Recipe dispatch, ordered command figures, sample reduction,
independent qualification and candidate publication remain in the shared tool.

## Test setup

Julia 1.13.3 ran the moved Classic and GPI2 selectors against their existing
CPU exports. Each selector used its own HIL test helper private core and
selected the matching registered PipeWireAO_jll daemon. The numerical
environments selected the candidate RTC checkout. They used registered
Clocks 0.4.0, AdaptiveOpticsCalibration 0.17.4, AdaptiveOpticsSim 0.3.22,
AdaptiveOpticsSimPipeWireHIL 0.5.1, FilterGraphAlgorithms 0.12.2,
FilterGraphs 0.10.2, PipeWireAO 0.9.2 and PipeWireAO_jll 4.0.2+0.
Classic used FilterGraphPipeWire 0.5.3 with four default and one interactive
Julia thread. GPI2 used FilterGraphPipeWire 0.5.5 with six default and one
interactive thread. The deployed instrument Projects and existing exports
were kept in their verified cohorts.

## Classic

The moved selector passed 43 cold and 57 live assertions. Dark, lamp
training and qualification each collected 16 exposures, then restored
and released the owner. The qualification result was valid with 176
eligible ROIs and a reference difference of 0.0087527886 pixels RMS.
The 11 FITS product hashes matched the
[pre-transfer campaign](../calibration-capture-retirement-20261112/README.md).
The selector also checked cancellation, rejected preparation evidence,
and unchanged application inputs.

The launcher read both a single FITS command vector and a named YAML
FITS binding in temporary directories. The RTC named-command selector
passed 96 assertions and the optical publication selector passed 72.

## GPI2

The moved selector passed 91 cold and 66 live assertions. Dark, lamp
training and qualification collected 16, 512 and 512 exposures respectively.
All stages restored and released the named command owners. Qualification
was valid at 0.05495888 dimensionless RMS. The selector checked the prepared
graph, retained calibration artifacts, cancellation and unchanged built
application inputs. It closed its private core on completion.

Compared with the pre-transfer run, the GPI2 qualification RMS differed by
9.66 × 10⁻⁸ and five of 13 FITS product hashes differed. This comparison
also changed the resolved science environment, including
AdaptiveOpticsCalibration from 0.17.3 to 0.17.4. The measured difference
does not isolate a cause. Both runs passed their numerical qualification
and artifact readback checks.

The full RTC core suite passed 10,492 assertions with the registered
PipeWireAO_jll prefix. These checks cover the CPU simulation and the
acquisition interface.
