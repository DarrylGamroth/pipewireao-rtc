# RTC 0.7.16 reference calibration verification

[PipeWireAORTC v0.7.16](https://github.com/DarrylGamroth/pipewireao-rtc/releases/tag/v0.7.16)
tags `bd5f06192d0fdd6fb4bb93d2cfd554ab73938bc1`. The
[registry entry](https://github.com/DarrylGamroth/PackageRegistry/commit/15ac9db7028a952b26415bdbdbc19307228d4dc9)
selects tree `5beeed110fd1707615be5b456be3d4428ef1652d` and requires AdaptiveOpticsCalibration 0.17.4
or a newer compatible release when the science extension is used.
The release commit changes only the Project and workspace Manifest
version from the [verified acquisition transfer](../reference-campaign-transfer-20261112/README.md).

## Fresh registry installation

Julia 1.13.3 resolved separate Classic and GPI2 environments in one empty
depot using General and DarrylGamrothRegistry. The RTC and
AdaptiveOpticsCalibration source trees matched the registered hashes
in both environments. Neither Manifest contained a local package path
or repository override. The shared instrument selectors came from
adaptive-optics-simulations `f45e5f7` and used the existing built CPU
applications.

Both environments used Clocks 0.4.0, AdaptiveOpticsCalibration 0.17.4,
AdaptiveOpticsSim 0.3.22, AdaptiveOpticsSimPipeWireHIL 0.5.1,
FilterGraphAlgorithms 0.12.2, FilterGraphs 0.10.2, PipeWireAO 0.9.2,
and PipeWireAO_jll 4.0.2+0. Classic used FilterGraphPipeWire 0.5.3
with four default and one interactive Julia thread. GPI2 used
FilterGraphPipeWire 0.5.5 with six default and one interactive Julia
thread. Each selector started and closed its own private PipeWire core
using the registered JLL daemon.

For each profile, the other 199 Manifest package records matched the
version and source tree in the transfer verification environment.

## Classic

The moved selector passed 43 cold and 57 live assertions. Dark, lamp
training and qualification collected 16 exposures each. All three stages
confirmed restoration and release. Qualification was valid with 176
eligible ROIs and 0.0087527886 pixels RMS reference difference.
All 11 FITS product hashes matched the pre-release transfer run.
The selector passed its cancellation, rejected-preparation and unchanged
application input checks and closed its private core.

## GPI2

The moved selector passed 91 cold and 66 live assertions. Dark, lamp
training and qualification collected 16, 512 and 512 exposures,
respectively. All stages confirmed restoration and release. Qualification
was valid with a dimensionless reference difference of 0.05495918 RMS.
The selector passed artifact readback, cancellation and unchanged
application input checks and closed its private core.

Compared with the transfer run, ten of thirteen FITS products matched.
The three qualification products had different hashes, and qualification
RMS differed by 3.01 × 10⁻⁷. The release commit changed only version metadata.
The runs did not isolate the source of the variation.

The shared launcher also read both the single FITS command vector and
named YAML FITS bindings using the registered release.

The instrument checkout fast-forwarded to the verified campaign changes
and recorded the released environment in commit `1f2c65b`. The existing
deployment Projects and Manifests were preserved.
