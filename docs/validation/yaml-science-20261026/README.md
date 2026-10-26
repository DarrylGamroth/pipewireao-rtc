# Named optical components and science imaging — 2026-10-26

This is local source-validation evidence. The RTC baseline is
`6b3b47c35beea917faf21b9308da23a7ad60e973`; the instrument baseline is
`c82b43470b62a69eab3e88d5452fd9a88eedc63f`. Work used the dedicated
`codex/yaml-science-components-20261026` branch in each repository, with clean
starting trees. The numerical environment copies the registered GPI2 application
manifest into a temporary directory and overrides only RTC and AOS with the
reviewed source worktrees. It does not alter installed applications.

The implementation uses the existing cold component expansion and AOS graph
compiler. Shared `pyramid` and `emccd` templates remove repeated guide-source,
Pyramid and camera declarations from GPI2 calibration/production graphs. Raw
camera dimensions remain separate from the padded transported detector frame.
Calibration retains its exact photon/read noise, multiplication-noise and
clock-induced-charge overrides. Atmosphere components select the guide source;
signed source separation follows the AOS `Source` convention.

Optional `imaging.source` names ordinary source photometry and wavelength;
`imaging.zero_padding` uses the existing direct-imaging API. The observer still
uses the guide-direction composed pupil OPD, rejects a different source
direction, and admits no finite source height. Omitting `imaging` preserves the
exact guide-source image with padding 2. Both instruments explicitly select
`source: guide` to retain their existing diagnostic without a second photometric
authority. Callers can declare a distinct science source when its photometry is
specified.
No long-exposure accumulation or Strehl estimate is added.

At the initial source-validation revision, RTC instrument preparation supported
graph inputs, parameters and delayed initial values while rejecting factories
requiring construction calibration arrays. The follow-on
[node-construction checks](#node-construction-calibration-bindings) below replace
that limitation with explicit binding declarations and selected FITS loading.

GPI2's wavefront-RMS `sample_period_seconds` now references
`/simulation/frame_period_s` (0.0005 s). The generic GUI computes elapsed model
time as Header sequence difference times this period
(`src/view_panel/time_series.rs`, lines 243–255 in the GUI owner). The native
observer preserves the captured graph sequence. Neither the 20 Hz optional
observation limit nor wall-clock pacing defines model time. The exporter makes
the existing cold simulation context available to generic application documents;
there is no GUI-specific resolution path.

## Vocabulary and ownership

| Identifier | Authority and meaning |
| --- | --- |
| `pyramid`, `emccd` | Existing Pyramid photon-rate / EMCCD detector scientific concepts; short component selectors, expanded to AOS graph node types at the compiler boundary |
| `source`, source photometry/direction fields | Existing named-source declaration and AOS `Source`; Cartesian angular coordinates define direction, including equivalent signed/polar representations |
| `imaging`, `zero_padding` | AOS direct imaging and `Optics.prepare_direct_imaging`; ideal cell-integrated focal photon rate and FFT padding |
| `sample_period_seconds`, `frame_period_s` | Existing generic GUI model-time and simulation cadence contracts |

No compatibility aliases or new public scientific quantities were introduced.
The semantic identifier diff was reviewed; RTC has no separate terminology gate.

## Verification

Julia 1.13.2, CPU only; unpublished AOS source `ae368dce` (project version 0.3.0),
HIL 0.2.5, unpublished RTC source (project version 0.2.10),
FGA 0.8.1, JFG 0.4.2, FGI 0.1.3 and FGP 0.1.7. The new authoring behavior is
not claimed for the registered AOS/RTC versions sharing those project labels.
Run the cold selectors with
the RTC environment, and optional science selectors with the compatible
scientific environment:

```sh
julia --project=/path/to/rtc test/test_instrument_components.jl
julia --project=/path/to/rtc test/test_instrument_declaration_schema.jl
julia --project=/path/to/rtc test/test_instrument_export.jl
julia --project=/path/to/science test/test_session_configuration_integration.jl
# In the instrument repository:
julia --project=/path/to/rtc test/simulation_components.jl
julia --project=/path/to/science test/simulation_components.jl science
julia --project=tools tools/format.jl --check
```

The full graph comparison is reproducible with
[`compare_defaults.jl`](compare_defaults.jl). Capture snapshots using clean
checkouts of the baseline revisions above, then compare the revised source:

```sh
julia --project=/path/to/baseline-rtc compare_defaults.jl snapshot /path/to/baseline-instruments /tmp/optical-baseline
julia --project=/path/to/revised-rtc compare_defaults.jl compare /path/to/revised-instruments /tmp/optical-baseline
```

- Core components: 110 checks pass, including shared photometry, exact
  calibration overrides, protected-value rejection, square optical geometry
  admission and bounded imaging declarations.
- Source declaration schema: 78 checks pass, including signed separation and
  explicit finite-height rejection.
- Cold exporter: 180 checks pass.
- Scientific defaults: 14 before/after checks pass. Settings and full resolved
  calibration/production graphs for both instruments are identical after
  removing newly explicit zero-valued source-direction fields. No detector
  coefficient, ADC setting, noise flag, command mapping or graph link changed.
- CPU observer tests: 68 checks pass. They verify exact default image/metadata equality, independent
  science wavelength, the expected flux ratio for a one-magnitude change,
  configurable focal shape and direction rejection, including equivalent signed/
  periodic directions and irrelevant on-axis position angle. They also check ordinary
  SH/Pyramid contracts and absence of GPU modules/libraries.
- Instrument cold tests: 23 checks pass. They vary the guide wavelength once and observe it in the
  WFS and camera for both graph modes, retain independent science photometry,
  and verify a changed model period updates the exported time axis.
- Initial optional instrument contracts: 13 checks passed. They verified both short detector selectors and
  explicit science source/padding through the actual cold exporter, plus explicit
  rejection of factories needing configuration calibration arrays at that revision.

Initial environment setup exposed an absent formatting-environment lock and a
publication helper's optional JFG dependency. Reusing the existing formatting
lock and using a minimal publication in the cold time-axis test resolved those
setup issues without adding dependencies. The first source-environment run
reported nonfatal Julia extension-cache build-ID warnings while shared source
was recompiled; its assertions passed. A subsequent CPU observer run was clean.
New signed/periodic direction tests initially rejected equivalent polar
representations because Float32 trigonometric rounding differed. The corrected
comparison admits a vector-distance tolerance of eight Float32 rounding units
relative to source separation; zero-offset equality remains exact. The same
tests then pass, while a distinct one-arcsecond source remains rejected.
Frozen calibration YAML has pre-existing
formatter drift in `gpi2/calibration/context.yaml` and
`gpi2/rtc/calibration.yaml`; it is kept byte-for-byte unchanged. Changed YAML
passes the maintained formatter.

This work does not install, launch, command or stop a session. It makes no
live/GPU, hardware, latency, deadline, stability or release qualification claim.

## Node-construction calibration bindings

Follow-on work starts from RTC `21fcedf82ae1dd135efcdd8079db25a103f1fd0b`
on `codex/rtc-calibration-bindings-20261026`, with a clean dedicated worktree.
It uses AOS source `17ceeb38` (based on `151a53f1`), adding the public scientific
factory contracts `graph_node_bindings` and `graph_node_configuration`.
These changes require the paired RTC/AOS source revisions. Registered AOS
0.3.0/0.3.1 and RTC 0.2.10 are not claimed to provide this new contract; a future
publication must establish matching released dependency bounds.

Nodes declare construction arrays independently of ordinary configuration:

```yaml
name: response
type: pixel_mtf
bindings:
  transfer: calibrated_transfer
config:
  input_shape: [8, 10]
  padding: 2
  input_schema: test.padded-rate/1
  output_schema: test.filtered-rate/1
```

The existing simulation `bindings.calibrated_transfer` supplies its FITS path,
HDU, logical shape, element type and axis permutation. Explicit node binding
roles cannot duplicate config keys or name undeclared arrays. Core metadata
includes construction calibration in selected artifact paths and prescription
hashes without loading AOS. AOS checks roles against the selected factory trait;
the native constructor validates and snapshots the loaded values. No alternate
array or pixel-MTF execution implementation is added to RTC.

The cold port-contract path loads only construction arrays. Runtime preparation
loads the deduplicated union with input, parameter and delayed-initial bindings;
only runtime bindings are copied to the target device. Existing 256 MiB decoded
artifact and 512 MiB aggregate binding limits remain. Declaration validation
checks path syntax without requiring files for unselected profiles. Selected
loads retain the existing canonical path/file and FITS validation.

The focused CPU HIL graph contains modal OPD expansion, a Shack-Hartmann sensor,
rectangular detector layout, pixel MTF and the ordinary short `detector: ingaas`
factory. A real FITS image stores a nontrivial 12 × 14 transfer transposed; the
explicit `[2, 1]` axes restore its logical orientation. The prepared filter is
compared with native `Detectors.prepare_pixel_mtf`/`apply_pixel_mtf!`; detector
output is compared with its explicit noiseless exposure/QE/gain scale. File and
caller-array mutation leave prepared snapshots unchanged, and reset reproduces
the original frame. Invalid bindings, absent files, unsupported type, wrong
shape/axes, NaN and nonunit DC reject before stepping. Missing unselected-profile
FITS and missing runtime-only FITS do not prevent cold port inspection.

Reproduce with Julia 1.13.2 and the compatible CPU scientific environment used
above, overriding RTC and AOS paths with the reviewed worktrees:

```sh
julia --project=/path/to/science test/test_instrument_configuration_bindings.jl
julia --project=/path/to/science test/test_aos_configuration_bindings.jl
julia --project=/path/to/science test/test_session_configuration_integration.jl
```

`test_instrument_configuration_bindings.jl` verifies explicit mapping validation,
path boundaries and construction artifact selection with no scientific/GPU
modules loaded. A second independent test factory checks generic construction
binding discovery and deduplication. Identifier changes reuse existing source
`bindings`, factory configuration and scientific calibration vocabulary; no
terminology authority, compatibility alias or scientific quantity is added.
This source-only increment makes no live, GPU, deadline, hardware or release
qualification claim.

The final focused calibration selector passes 36 assertions and the cold core
selectors pass 458: construction metadata 17, declaration schema 78, physical
Pyramid/legacy Shack-Hartmann metadata 73, reusable components 110 and cold
exporter 180. The core checks load no scientific or GPU modules. A temporary
test-environment edit initially added `Test` as a direct dependency without a
matching manifest entry, causing Julia precompilation to fail before the
scientific checks. Removing that unnecessary entry restored clean focused
calibration results.
The existing CPU session-contract/optical-observation integration selector also
passes all 68 assertions, preserving ordinary SH/Pyramid declarations and the
other cold factory paths. These 562 passing assertions are functional and
numerical software evidence, without live transport or GPU execution.

The same positive graph on RTC baseline `21fcedf` rejects cold inspection with
`configuration array bindings: response` and runtime preparation with
`no external binding named 'calibrated_transfer' was supplied`. The baseline
check supplies its otherwise-unused FITS file because that revision requires
all declared files to exist. The revised selector also checks that missing
unselected/runtime-only files do not force a cold calibration load.

## Registered release checks

AdaptiveOpticsSim 0.3.2 publishes the construction-binding interfaces used by
PipeWireAORTC 0.2.11; the RTC compatibility floor now names that release.
The complete RTC workspace tests pass on Julia 1.13.2 with one Julia thread,
using `PIPEWIREAO_PREFIX` and `LD_LIBRARY_PATH` for the installed
`pipewireao-classic-headless-20261021` prefix:

```sh
julia --project=. -e 'using Pkg; Pkg.resolve(); Pkg.test(; julia_args=["--threads=1"])'
```

The first configured run exposed a missing direct YAML dependency in the test
workspace. Adding YAML and its compatibility bound to `test/Project.toml`
restored the same full-suite command. These are package/software checks;
live deployment and calibration are recorded separately.
