# Explicit optical pupil metadata — 2026-10-26

Baseline: `054da1956748350bb410585152172c8119c231ad`, branch
`codex/dm-pupil-gpi`, dedicated worktree `pipewireao-rtc-pupil-gpi`.
The worktree was clean before this change. Sibling source, calibration bytes
and live sessions remain unchanged.

## Contract

Physical mirror authoring accepts optional `pupil` with exactly `outer_radius`
and `inner_radius`, in the existing registered normalized-pupil x/y coordinates.
Explicit values enter physical/scientific definitions and publication unchanged,
and take precedence over the existing telescope-derived pupil. Missing explicit
metadata preserves that fallback (`outer_radius: 1`, telescope obstruction as
`inner_radius`). Publication omits the pupil only when both are unavailable.

Validation rejects Boolean, nonfinite, negative, unordered, underflowing,
overflowing and Float32-indistinguishable radii. Radii and supplied command-sized
x/y coordinates have magnitude strictly below `Float32_MAX / 4`; nonzero values
survive Float32 conversion. A pupil requires registered coordinates. Scientific
source verification compares the actual pupil, accounting for the telescope
fallback in older definitions. The 1 MiB publication limit, controlled actuator
masks, named command checks and optical calculations remain intact.

## Cold software verification

Julia `1.13.2`; fresh processes, existing local dependencies, no package
resolution or network operation. From the dedicated worktree:

| Command | Result |
| --- | --- |
| `julia --startup-file=no --project=. test/test_instrument_definition.jl` | 230 assertions passed |
| `julia --startup-file=no --project=. test/test_instrument_declaration_schema.jl` | 93 assertions passed |
| `julia --startup-file=no --project=. test/test_instrument_export.jl` | 181 assertions passed |

The declaration tests distinguish explicit mirror precedence, preserved telescope
fallback, and a minimal declaration/publication with neither mirror pupil nor
telescope. They retain coordinates, layouts and required fields, check changed
scientific/prescription identities, and round-trip generated JSON. The initial
telescope test used a text aperture revision; this was corrected to the existing
required positive integer before the passing run.

The baseline instrument-definition module was loaded under a separate name.
Identical documents with an underflowing positive inner radius, an overflowing
Float32 coordinate, and a pupil changed independently of scientific source
identity passed the baseline checks and fail current checks (6 assertions).

## Real instrument publication export

The validation environment is a private copy of the existing
`/tmp/gpi2-integration-validation`, with the new RTC source override. Stale FGA/JFG
source paths were replaced with the clean `JuliaFilterGraph.jl` source at
`3e053b7`; private RTC manifest dependencies and extension triggers were refreshed
from the selected RTC Project. Initial attempts exposed those stale environment
entries before export; no production dependency metadata was changed.

The export script copies the actual instrument source into fresh output, then
calls `InstrumentConfiguration.prepare_publication`. It preserves and prepares
the authored controlled actuator masks through the existing FilterGraphIsland
graph/FITS path. It checks explicit pupil values against authoring and physical
definitions, coordinate/mask command counts, source hashes and absence of loaded
CUDA/AMDGPU modules. It does not install or launch an application.
The final run passed 19 publication/source/mask assertions and the additional
no-GPU-module assertion. Classic and GPI JSON are retained under
`exports-matched/revolt-classic/instrument.json` and
`exports-matched/gpi2/instrument.json` in the local validation directory below.
GPI's publication is 304,865 bytes, within the retained 1 MiB limit.

| Mirror | Outer radius | Inner radius | Commands | Controlled |
| --- | --- | --- | --- | --- |
| Classic `hsdm277` | 1.0 | 0.20491803 | 277 | 212 |
| GPI `woofer` | 1.0 | 0.13178893 | 97 | 97 |
| GPI `tweeter` | 1.0 | 0.13178893 | 2304 | 1412 |

Classic publication SHA-256:
`2cf58ced549c9a834d1700b3bf24b97182678c54cb78d2529329e598d7496345`.
GPI publication SHA-256:
`698cd3cf829ff71211eb813a109d8371c55e3484425432ff48447bcbf832c972`.

Local command and retained artifacts:

```sh
julia --startup-file=no \
  --project=/tmp/pipewireao-pupil-gpi-validation-20261026-N4qfCS \
  /tmp/pipewireao-pupil-gpi-validation-20261026-N4qfCS/check-exports.jl \
  /home/dgamroth/workspaces/codex/instruments-pupil \
  /tmp/pipewireao-pupil-gpi-validation-20261026-N4qfCS/exports-matched
```

The baseline comparison uses
`julia --startup-file=no --project=. /tmp/pipewireao-pupil-gpi-validation-20261026-N4qfCS/check-baseline.jl`.
`git diff --check` and the newly introduced Markdown links pass.

## GUI runtime configuration preparation

The metadata-only copy retains GUI authoring references, so it cannot directly
serve as a runtime GUI configuration. A second cold check used the normal
exporter graph preparation, `graph_context` and `graph_contract_context`, then
`Common.configuration_value` and the existing YAML configuration writer. GUI
reference roots were exactly within `schemas`, `instrument` and `graphs`; no
simulator context or GPU package was needed. It resolved the actual copied
Classic/GPI GUI documents without removing fields or defaults, and left both
publication hashes above unchanged. Eight preparation assertions and the
additional no-GPU-module assertion passed.

```sh
julia --startup-file=no \
  --project=/tmp/pipewireao-pupil-gpi-validation-20261026-N4qfCS \
  /tmp/pipewireao-pupil-gpi-validation-20261026-N4qfCS/prepare-gui.jl \
  /tmp/pipewireao-pupil-gpi-validation-20261026-N4qfCS/exports-matched
```

The resolved `gui/operator-views.yaml` files are retained inside the same
Classic/GPI export directories. Their SHA-256 values are
`9f7c660d2c5071ed18b39f79bf90a25e965e92b5594f2fd91261a23149469971`
and `4fa906f9a972d0135844701b3278d31ef288e6da0e71d78d01b669916ccafd92`,
respectively. This prepares runtime client configuration; GUI loading and
instrument resolution remain separate client interoperability checks.

## Boundaries

These are cold metadata/export checks. They establish no live-session behavior,
physical optical registration, hardware correctness, sustained cadence, latency
or real-time qualification. The earlier `9c35477` investigation and its checks
are historical, not validation of this GPI-based change.

## Client interoperability and review

The GUI's ignored `rtc_exported_pupil_metadata_resolves_configured_products`
test loaded both exact publications and the prepared runtime view configurations,
then resolved every configured demanded/applied/offset/residual DM product.
The test passed, preserving pupil, actuator coordinates and source layout for
all three mirrors. Initial client loading of unresolved authoring correctly
failed before the normal GUI-reference preparation step above.

An independent source review found no actionable issues in precedence, fallback,
identity checks, bounds, or the GUI display default. This does not extend the
cold-export evidence into live RTC, scientific or hardware qualification.

Portable copies of the exact local check programs are retained as
[export checks](check-exports.jl), [GUI preparation](prepare-gui.jl), and
[baseline comparison](check-baseline.jl). Use the same dependencies and fresh
output arguments documented above; these programs never install or start an RTC.
