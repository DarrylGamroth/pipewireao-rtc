# RTC 0.7.6 generic calibration verification

The [release](https://github.com/DarrylGamroth/pipewireao-rtc/releases/tag/v0.7.6)
tags commit `65fa046ac5c7d6826d8c78d9f0fcead0726f425d`. The
[registry entry](https://github.com/DarrylGamroth/PackageRegistry/commit/c64c6057b400df9a76c8cba1e4ba26a50764e283)
records tree `c07ada0eeec79d12a6566b158d01fb8d63ae662e`. The release changes
reference procedure selection to follow the sensor declared in YAML and
acquisition projections to follow the graph's declared Ports and Links.

## Registry-only environments

Julia 1.13.3 on Linux x86-64 used one initially empty depot. Pkg added public
General at tree `d7fafea2947cd4dca3d2b233e1d87b14b47cb6d2` and
DarrylGamrothRegistry at `c64c6057b400df9a76c8cba1e4ba26a50764e283`.
Both environments used instrument source
`e76d921897dea4259ddd193b0248bd383b9788f8`. The validation Projects selected
RTC 0.7.6 and added YAML for the Classic selector. The other instrument pins
came from that revision.

| Dependency | Classic | GPI2 |
| --- | --- | --- |
| FilterGraphAlgorithms | 0.12.0 | 0.12.2 |
| FilterGraphs | 0.10.0 | 0.10.2 |
| FilterGraphPipeWire | 0.5.2 | 0.5.3 |
| AdaptiveOpticsCalibration | 0.17.3 | 0.17.3 |
| AdaptiveOpticsSim | 0.3.22 | 0.3.22 |
| AdaptiveOpticsSimPipeWireHIL | 0.5.1 | 0.5.1 |
| PipeWireAO | 0.9.2 | 0.9.2 |
| PipeWireAO_jll | 4.0.2+0 | 4.0.2+0 |
| PipeWireAOQueue_jll | 0.1.0+0 | 0.1.0+0 |

The two Pkg Manifest SHA-256 values are
`6afce031cb270de17404d9b72d55087867482650c0b269c2f2d2c1d69b52fcc7`
for Classic and
`1eb4b32266b4d6db10c3f8f13776e2dd2b613b17873792382d5acd7408e9b4d2`
for GPI2. The registered SDK artifact is
`b84754cc61ae9a8e33d31ec4352f188fa5405581`.

Both CPU exports carried their exact resolved Manifest. Each passed 50 checks
covering registry tracking, installed tree hashes, SDK selection and the
separate queue artifact `20afa07132938ae663c7cf4c10f00172ca40e70f`.
The depot contained no source or artifact overrides. The private cores used
the registered SDK.

## Calibration checks

Use the instrument repository's `tools/build.jl` with each instrument's
`profiles/simulator/profile.yaml`, `host.cpu.example.yaml` and the resolved
Manifest. Start Julia with the resulting application as the project and set
`PIPEWIREAO_PREFIX` to
`String(PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir)`. Run the selectors
from `joinpath(pkgdir(PipeWireAORTC), "test")` in the installed package.

### REVOLT Classic

The instrument repository's full `test/calibration.jl` passed 169 assertions,
including graph recompilation, command limits and all five GUI parameter
bindings. The installed `test/reference_calibration.jl` passed 43 cold and 57
private-core assertions with four default Julia threads and one interactive
thread. Set `PIPEWIREAORTC_REFERENCE_APPLICATION` to the Classic export to
include the live campaign.

The three stages collected 16 exposures each and restored and released their
owners. The qualification product was valid with 176 eligible ROIs and an RMS
reference difference of 0.0087528 pixels. The selector checked cancellation and
candidate isolation as well as the accepted path.

### GPI2

Set `PIPEWIREAORTC_PYRAMID_REFERENCE_APPLICATION` to the GPI2 export and
`PIPEWIREAORTC_PYRAMID_REFERENCE_LIVE=true` to include the private-core
campaign in `test/pyramid_reference_calibration.jl`. The run used six
default Julia threads and one interactive thread. The cold selector passed
91 assertions and resolved 2,776 selected pixels per pupil and 1,509
controller coordinates from the built graph.

The private-core campaign collected 16 dark, 512 lamp and 512 qualification
exposures. The lamp stage discarded one normalization exposure and
qualification discarded 514 to exclude the training window. The receipt
records restoration and release of all three stages and a distinct
acquisition domain per stage. Dark, lamp and qualification products were
valid. The frozen pupil reference differed from qualification by an RMS of
0.0549592 in dimensionless pupil-pixel units. The modal reference uses
metres of OPD. All 66 private-core assertions passed, including cancellation
after a known Hold and candidate isolation. The full GPI2 selector took
20 min 48 s in its first process. Both test cores exited.

The full RTC core suite passed 10,822 assertions on `ac3956d` before the
version-only release update. The registry runs above exercised the installed
release and its optional science and transport extensions.

These checks cover simulated candidate acquisition, PipeWire transport,
and the published artifact contracts. They use the authored reference
recipe and its separate qualification window.

## GitHub review

The [GitHub triage](github-triage.md) records which issues and draft PRs still
match the maintained RTC.
