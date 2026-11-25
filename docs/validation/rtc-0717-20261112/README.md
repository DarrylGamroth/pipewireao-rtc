# RTC 0.7.17 Classic staging verification

[PipeWireAORTC v0.7.17](https://github.com/DarrylGamroth/pipewireao-rtc/releases/tag/v0.7.17)
tags `86616fee5db6ee630773fe2824e1d2f31cfa9cb9`. The
[registry entry](https://github.com/DarrylGamroth/PackageRegistry/commit/bf25032e8567b66631912487c2b3208b353844b1)
selects tree `93e5a73d5e46e65afc260de152db70f57e7fc3ad`. The release changes only the Project and workspace
Manifest versions from the [verified staging transfer](../calibration-staging-transfer-20261112/README.md).

## Registry-only environment

Julia 1.13.3 started with an empty depot and resolved packages through
General and DarrylGamrothRegistry. The installed RTC and AdaptiveOpticsCalibration
source trees matched their registered hashes. The resolved Manifest contained
no local package paths or repository overrides.

The Classic CPU environment selected AdaptiveOpticsCalibration 0.17.4,
AdaptiveOpticsSim 0.3.22, AdaptiveOpticsSimPipeWireHIL 0.5.1,
FilterGraphAlgorithms 0.12.2, FilterGraphs 0.10.2, FilterGraphPipeWire 0.5.3,
PipeWireAO 0.9.2 and PipeWireAO_jll 4.0.2+0.

The instrument source came from `753ca45`. The verification copied it to a
temporary directory, localized its shared assets using `InstrumentExport.copy_source`,
and used the resolved Project and Manifest for both exports. It left the
instrument's deployment pins in Git intact.

The initial install hit a temporary-filesystem space limit while
downloading FilterGraphs. Pkg completed the retry in the same isolated depot
using the same registries. The other 199 Manifest package records matched
the version and source tree of the Classic 0.7.16 release environment.

## Classic acquisition, staging and relocation

The fresh Classic export included the resolved Project and Manifest.
A new CPU acquisition produced 212 modes with retained rank 208, and the
bundle retained the source subaperture-origin FITS bytes exactly.

The shared staging selector passed 17 assertions for the selected bundle,
fresh destination, and unchanged source, application and bundle inputs.
It then exported the staged source with the registry-resolved Manifest,
moved the export to a different path and passed 46 relocation assertions.
The Project, Manifest and exported files were byte-identical after the move.
Deployment validation succeeded, the concrete graph matched the bundle,
and all 19 typed FITS bindings resolved and loaded from the relocated export.

These were export and readback checks. No PipeWire core or systemd service
was started.

The instrument repository fast-forwarded to commit `3691478` after verification.
