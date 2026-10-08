# RTC deployment tools

Maintained export, installation, calibration and control tools use Julia ≥ 1.12.
WirePlumberAO owns session admission, lifecycle and external links. systemd user
services own processes and placement; FGN/JFG and AOS own their scientific work.

Start with the [session quickstart](../README.md#launch-a-sealed-session-package),
[Julia usage](../docs/JULIA_DEPLOYMENT_USAGE.md) and
[installed runtime](../docs/INSTALLED_RUNTIME.md).

## Layout

| Path | Purpose |
| --- | --- |
| `julia/` | `PipeWireAODeployment` package, native clients and one-shot session tools |
| `hil/` | Julia simulator, graph owners and calibration acquisition/analysis |
| `templates/` | PipeWire configurations embedded into exported packages |
| `wireplumber/` | Development Lua policy and native-interface probes |
| `*.jl` | Thin export and calibration command entrypoints |
| `pipewireao-session@.service.in` | Private systemd user session service template |

Instantiate and run the package tests from the repository root:

```sh
julia --startup-file=no --project=deployment/julia -e 'using Pkg; Pkg.instantiate(); Pkg.test()'
```

Calibration uses a sealed scientist-authored base package and native acquisition
controls. Follow the [Julia command and recipe guide](../docs/JULIA_DEPLOYMENT_USAGE.md)
for Classic/Copper and the selected backend. Scientific qualification remains
separate from package installation and lifecycle checks.

The Python exporters, launchers, checks and campaign scripts have been removed.
Their [original source](https://github.com/DarrylGamroth/pipewireao-rtc/tree/6b893b7e98e474580f53ff913751963b62f8db2a/deployment)
and dated validation records remain available as historical evidence.
