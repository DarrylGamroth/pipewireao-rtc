# Julia deployment and calibration entrypoints

Operational calibration preparation, acquisition orchestration and process
supervision use Julia ≥ 1.12. The numerical estimators and probe bases remain
in AdaptiveOpticsCalibration. Detector acquisition and graph algorithms retain
their existing owners. The migration does not change illumination, noise,
matrices, gains or scientific acceptance.

## Source entrypoints

Instantiate the cold orchestration environment once:

```sh
julia --startup-file=no --project=deployment/julia -e 'using Pkg; Pkg.instantiate()'
```

Run a wrapper with the same project, for example:

```sh
julia --startup-file=no --project=deployment/julia deployment/copper_reference.jl \
  --base-package /absolute/path/to/sealed-copper-base \
  --output /absolute/path/to/fresh-candidate \
  --recipe /absolute/path/to/recipe.json \
  --aoc-source /absolute/path/to/AdaptiveOpticsCalibration.jl \
  --rtc-binary /absolute/path/to/pipewireao-rtc \
  --calibration-binary /absolute/path/to/rtc-calibrate \
  --runtime /short/absolute/path/to/fresh-runtime
```

`calibration_campaign.jl` uses these options for Classic. `copper_quality.jl`
also requires `--reference-candidate`. `calibration_method.jl` also requires
`--method` and uses `--prefix` for the PipeWire prefix. The other campaign
wrappers use `--pipewire-prefix`; the supported prefix is `/opt/pipewireao`.
See the maintained Copper reference and quality usage documents for recipes
and product contracts. Output and runtime directories must be new.

## Installed entrypoints

Install a sealed exported package with `deployment/deploy.jl install`, supplying
`--package`, `--destination` and `--pipewire-prefix`. Its `bin` directory contains
`pipewireao-rtc-deploy`, `calibration_campaign`, `calibration_method`,
`copper_reference`, `copper_quality`, `export_calibration`, `export_hil` and
`export_heart_hil`. The wrappers
select the package's Julia project and load its packaged modules. Packages carry
their cold export resources separately from the resolved simulator environment;
preparing another package does not replace its plant or local dependencies.

All four campaigns require a sealed scientist-authored complete-frame
`--base-package`. Existing Python generators and audits remain development
tools for creating or inspecting those inputs. They are not invoked by the
operational Julia workflow. Legacy Python command lines in historical evidence
identify the original producer and must not be relabeled.

Foreground launch and the generated systemd user service use the same deployment
owner. The service sends SIGINT for bounded graceful cleanup. Placement admission
checks the configured CPU envelopes, worker policies and resource limits;
the supervisor pins every existing Julia native thread before starting children.
This is functional deployment behavior, not a scheduler-latency qualification.

## Qualified scientific dependencies

Scientific source inputs must form a compatible set. The selected CPU HEART
qualification uses adapter `277d822` and seals the actual supplied AOS and
PipeWireAO files. It does not infer source equality from a Git revision alone.
Adapter `39efcf5` requires an AOS graph-calibration boundary absent from the
selected AOS checkout and fails import before admission. Select compatible
`--aos-root` and `--adapter-root` inputs when exporting; the
[migration record](JULIA_CALIBRATION_MIGRATION_VALIDATION.md) binds the tested
files and preserves that failed attempt.

## Failure and scientific boundaries

Requests and captures are correlated by run, serial, probe and exposure identity.
Completed batches are copied and verified before another figure is adopted.
Known rejections permit bounded restoration; unknown mutation outcomes remain
held or faulted. Shutdown, release, restoration and owned-process cleanup are
reported separately. A partial campaign cannot replace active calibration.

HEART uses its unchanged native executable with the SPA stdWfs/stdDM bridge;
its Julia owner handles placement and public lifecycle commands. Accelerator
selection in an HIL export does not establish CUDA or AMDGPU cadence.
Migration qualification is recorded separately from interaction-matrix
precision, physical suitability and correction acceptance.
