# Classic CPU calibration campaign usage

`deployment/calibration_campaign.jl` runs a finite, non-actuating Classic
calibration campaign from an installed CPU base package. The base package may
use the native FGN graph or the external JuliaFilterGraph (JFG) graph. The
campaign makes four fresh stage packages and runtimes:

1. **Dark:** capture dark frames and estimate pixel background and sample
   variance.
2. **Training:** capture lamp frames and derive candidate Shack–Hartmann
   reference centroids and eligibility.
3. **Qualification:** capture a separate lamp set and check the frozen
   reference and selected positions.
4. **Interaction:** use the Julia completion-driven client to collect zonal
   push-pull responses and estimate an interaction matrix.

Each stage uses the deployed graph and its normal noisy ADC acquisition. The
runner performs cold startup and qualification instrumentation; it does not
log each exposure on the frame-processing path. Each finite stage holds the
probe, adopts and settles the requested figure, captures evidence, restores the
reference figure, releases ownership, and then uses the public stop and quit
controls. A stage result records restoration, release, and shutdown status.

## Example recipe

This recipe is an explicit **characterization example**, not a recommended
physical setting, default, or acceptance threshold. Its all-true candidate
mask declares the candidate universe; training derives eligibility from the
captured evidence. It does not force all positions to remain active. A prior
campaign happened to select 184 positions, but that count is not prescribed.

Save this as `write-example-recipe.jl` and run it with the
`deployment/julia` project. It writes a
JSON recipe with separate detector seeds for all four stages:

```julia
using JSON3

recipe = Dict(
    "version" => 1,
    "dark_frames" => 16,
    "training_frames" => 16,
    "qualification_frames" => 16,
    "seeds" => Dict("dark" => 0, "training" => 1, "qualification" => 2, "interaction" => 3),
    "lamp_magnitude" => 0.5,
    "candidate_mask" => fill(true, 188),
    "minimum_flux" => fill(2000.0, 188),
    "adc_upper_rail" => 4095,
    "maximum_reference_residual" => 0.1,
    "reference" => zeros(277),
    "amplitudes" => fill(0.02, 277),
    "frames_per_probe" => 2,
    "settling" => Dict("kind" => "discard_exposures", "frames" => 1),
    "request_timeout_ns" => 20_000_000_000,
    "stage_timeout_seconds" => 180,
)

write("classic-campaign-recipe.json", JSON3.write(recipe) * "\n")
```

## Run

Use absolute paths. The base package must be an installed Classic CPU
deployment. The Julia package supplies
its completion-driven acquisition client. The output directory
must not already exist; use a new short runtime root because the campaign uses
local AF_UNIX sockets.

```sh
julia --startup-file=no --project=deployment/julia deployment/calibration_campaign.jl \
  --base-package /absolute/path/to/classic-cpu-base-package \
  --output /absolute/path/to/new-campaign-output \
  --recipe /absolute/path/to/classic-campaign-recipe.json \
  --aoc-source /absolute/path/to/AdaptiveOpticsCalibration \
  --runtime /tmp/rtc-campaign-unique \
  --pipewire-prefix /opt/pipewireao \
  --julia /absolute/path/to/julia
```

`--pipewire-prefix` is optional and defaults to `/opt/pipewireao`; this
campaign currently rejects any other prefix. `--julia` is optional and
defaults to `julia` on `PATH`. Use the AOC source checkout that contains the
public `ReferenceFrames` API needed by campaign analysis. The FGN and JFG base
packages use the same command; pass the desired installed base package.

The run creates `<output>/<stage>-base`, `<output>/<stage>-package` and
`<output>/<stage>-evidence` directories. `<output>/campaign-result.json` records whether
the procedure completed as a candidate. Use a new output directory for every
run. The campaign does not install or activate the generated packages.

## Candidate artifacts and limits

The five `measured-*` candidate files are:

- `measured-background.f32le` — dark mean in ADC units;
- `measured-dark-variance.f64le` — dark sample variance in ADC units squared;
- `measured-reference-slopes.f32le` — measured reference centroid coordinates;
- `measured-active.u8` — positions eligible under the declared training rules;
- `measured-interaction-matrix.f32le` — estimated response matrix.

Raw exposures and their deployed slopes, flux, validity, manifests, and hashes
remain in the stage evidence directories for review. These files are
candidate-only outputs. Completion does not establish measurement precision,
linearity, observability, a qualified reconstructor, closed-loop correction,
GPU behavior, or cadence/rate acceptance. The campaign changes no HEART source
or operational configuration. It also makes no claim that qualification
frames from separate FGN and JFG runs will be bit-identical.

The former Python entrypoint remains a development reference. Historical
campaign evidence retains its original producer. See
[Julia deployment usage](JULIA_DEPLOYMENT_USAGE.md) for installed commands and
the [migration record](JULIA_CALIBRATION_MIGRATION_VALIDATION.md) for current
qualification.
