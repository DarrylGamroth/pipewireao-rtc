# Optional circular mirror clear aperture — 2026-10-26

RTC baseline: `23db2ab35a7e743d98d7fe45a6067cef60a997b7`, branch
`codex/dm-pupil-gpi`, initially clean dedicated worktree
`/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-pupil-gpi`.
This record covers cold metadata and export behavior only.

## Contract and source

The [maintained contract](../../architecture.md#shared-instrument-definition)
adds optional `clear_aperture_diameter_m` to intrinsic mirror description schema 1;
it requires `actuator_pitch_m`. Physical/scientific definitions and schema 2
publication carry optional `clear_aperture: {radius: ...}` in registered pupil
coordinates. The radius is `diameter_m / actuator_pitch_m × actuator_pitch_pupil_radius / 2`.
Missing metadata stays absent. A radius requires registered coordinates and
must remain positive, finite and renderable under the existing Float32 bounds.
Source verification compares the actual aperture independently of its fingerprint.

Clear aperture, illuminated optical pupil, actuator footprint and full mechanical
face-sheet edge remain distinct. The explicit nominal legacy ALPAO DM277-15
24.5 mm clear aperture and 1.5 mm pitch resolve to approximately 1.0208333 with
Classic's unchanged registration of 0.125. Source references and applicability
limits are in the maintained contract. No mechanical face-sheet edge is inferred;
actuator coordinates, scientific calculations, units and controls are unchanged.

## RTC software checks

Julia 1.13.2, fresh processes, existing private dependency environment, no
resolution, installation, GPU preparation or live-session operations. From the
RTC worktree, use the same dependency versions in the local validation project:

```sh
validation_project=/tmp/pipewireao-pupil-gpi-validation-20261026-N4qfCS
julia --project="$validation_project" test/test_instrument_geometry.jl
julia --project="$validation_project" test/test_instrument_definition.jl
julia --project="$validation_project" test/test_instrument_declaration_schema.jl
julia --project="$validation_project" test/test_instrument_export.jl
julia --project="$validation_project" docs/validation/clear-aperture-20261026/check-baseline.jl
```

| Gate | Passed assertions |
| --- | --- |
| Geometry and intrinsic YAML/JSON authoring | 85 |
| Publication, bounds and scientific-source verification | 250 |
| Physical/scientific/publication propagation and identity | 105 |
| Export/profile/template regression | 181 |
| Same-input baseline comparison | 4 |

Focused suite output was observed directly; separate raw RTC log files were not
saved. The [retained baseline program](check-baseline.jl) loads the baseline
module under a separate name. The same underflowing published radius and valid
radius changed independently of the scientific identity pass baseline validation
and source verification, respectively, and fail the new checks. Its original
local path is `$validation_project/check-aperture-baseline.jl`.

## Real instrument exports and GUI interoperability

The primary integration checks used actual Classic and GPI source with the same
private project and fresh output at `$validation_project/exports-aperture`.
The existing export and GUI-preparation programs are retained in the
[optical-pupil record](../optical-pupil-20261026/README.md). Export passed
19 assertions plus absence of loaded GPU modules; GUI reference preparation
passed eight assertions plus the same GPU check. The GUI's actual-export
interoperability test passed with the added clear-aperture assertion. Independent
GUI source review reported no actionable findings; GUI runtime evidence remains
with its owner.

| Exported `instrument.json` | SHA-256 |
| --- | --- |
| `revolt-classic/instrument.json` | `bffb582430ac907f92886f831c4a6dfcdf87b22715031263d4c1d9c631a7acf7` |
| `gpi2/instrument.json` | `698cd3cf829ff71211eb813a109d8371c55e3484425432ff48447bcbf832c972` |

Classic carries the nominal aperture; GPI's publication is unchanged. These
exports were not installed into or adopted by the existing Classic RTC owner.

## ALPAO reader compatibility

The strict ALPAO schema 1 reader needed the same optional field before an enriched
description could pass end to end. The change is isolated on branch
`codex/clear-aperture-metadata`, initially clean base
`1657c75b459b52c03824e9299989c63901f05c0b`, at
`/home/dgamroth/workspaces/codex/pipewire/pipewireao-spa-plugin-alpao-aperture`.
Only its description validator, SDK-free tests and README changed.

```sh
PKG_CONFIG_PATH=/opt/pipewireao/lib/x86_64-linux-gnu/pkgconfig:/opt/pipewireao/share/pkgconfig \
  meson setup /tmp/pipewireao-alpao-aperture-build-20261026 \
  -Dalpao-sdk=disabled -Dtests=enabled -Dfits=disabled
meson test -C /tmp/pipewireao-alpao-aperture-build-20261026 --print-errorlogs
```

All four configured gates pass: image-frame, FGN command normalization, factory
and mock. New valid-aperture mock inputs failed before the reader extension and
pass after. Tests retain absent/default descriptions and exact owned NodeInfo
bytes, and reject invalid JSON numbers, Boolean/null/nonfinite values, overflow,
underflow, duplicate fields and missing pitch. The [retained Meson log](alpao-testlog.txt)
omits the inherited-environment line and trims trailing whitespace; the original is
`/tmp/pipewireao-alpao-aperture-build-20261026/meson-logs/testlog.txt`.
Installed headers/libraries were used only for compilation; no ASDK backend,
hardware, installation or daemon restart was involved.

These checks establish no physical aperture metrology, optical registration,
hardware correctness, sustained cadence, timing or real-time qualification.
Static GUI asset deployment is separate and does not adopt the new RTC metadata;
the existing RTC unit/process remains unchanged.
