# Optical authoring and Classic consistency review — 2026-10-23

Work started from clean RTC `b4b3497` and instruments `f7b52e2` in dedicated
`codex/optical-authoring` worktrees. The independent reviewer inspected the full
active Classic authoring tree, build/calibration tools, maintained guides and
affected shared RTC loaders, rather than only the final diff. The primary
reviewed the implementation, interfaces, validation results and final changes.

## Findings and dispositions

| ID | Severity / confidence | Observed issue | Disposition and evidence |
| --- | --- | --- | --- |
| OPA-001 | P2 / high | Component config could replace instrument/settings references, including detector gain and mirror dimensions. | Fixed: component and graph overrides accept only template-declared schema/value inputs; canonical physical/settings references stay authoritative. Regression cases reject gain, exposure, geometry and count overrides while retaining calibration detector noise overrides. |
| OPA-002 | P2 / high | Mirror graph config/props overrides were accepted, then discarded by profile replacement. | Fixed: reject graph-local mirror overrides explicitly; mirror components/profiles own settings. The same two schema/props cases failed before and passed after. |
| OPA-003 | P2 / high | Explicit profiles were implicitly classified as Gaussian, producing a missing-coupling error for an otherwise valid measured profile. | Fixed: only selected template profiles introduce Gaussian bindings. Explicit profile nodes remain authoritative; measured profiles do not acquire Gaussian settings. |
| OPA-004 | Consistency improvement / high | Active guides and selectors still referred to old source `.conf` files and the hardware example directory. | Updated all five active README guides, source readers, build CLI and selectors to named profiles and YAML authoring; native output contracts and frozen source receipts are preserved. |

Independent final reproduction passed three protected/ignored-override checks
and three explicit-profile preservation checks. No residual confirmed finding
remained. The hotspot scan identified the component expansion function for manual
inspection; length alone was not treated as a defect. No additional graph
executor or instrument-specific handler was introduced.

## Scope and format boundaries

Classic names optical components and connections in ordinary AOS graph YAML.
Package-owned component templates supply reference-only numerical plumbing;
physical values, detector response, schemas and topology remain declared data.
Multiple mirror/sensor references and caller-owned inline AOS nodes are tested.
Selected templates/catalogs, expanded graphs and scientific assets contribute to
prescription identity. Measured influence data remains optional and explicit.

Portable simulation/hardware profiles are distinct from optical mirror profiles.
Host placement and backend selection are separate YAML. Optional analysis CPU
examples use CPUs disjoint from required process envelopes. Hardware calibration,
serials and owner contracts remain explicitly missing; no hardware is claimed.

Application/mode, simulator/analysis process, calibration recipe and FITS binding
sources use YAML. Explicit mappings materialize native JSON/SPA-JSON only in a
fresh copied application. Native queues, graphs, session templates and adapter
files retain SPA-JSON. Strict JSON cannot carry comment headers; deployment
seals identify generated JSON, while generated YAML/SPA-JSON carries notices.
Package metadata, frozen provenance/result TOML and unmigrated other instrument
packages are intentional scope boundaries, not competing active Classic inputs.

## Verification

Validation uses Julia 1.13.2, one Julia/BLAS thread, disabled GPU visibility and
the existing CPU SDK wrapper. The private `optical-authoring-validation`
environment pins the changed RTC source and scientific dependencies.
Focused selectors live in RTC `test/test_instrument_*.jl` and instrument `test/`;
the instrument README documents build, formatting and CPU commands.

- Component expansion: 76; declaration schema: 62; portable/host profiles: 41;
  YAML-to-native materialization: 25; export: 132; dimensions: 18;
  catalogs: 57; measured influences: 16 assertions passed.
- Exact pre-edit baseline: four complete resolved Gaussian optical graphs,
  GUI settings schema, defaults and wire order (7); RTC controls and complete
  publication (2) passed equality checks.
- Classic configuration: 59; hardware profile: 35; camera: 39; graph references:
  39; frozen session-source receipts: 135; geometry: 167; modal controls: 20.
- CPU owner: 14, including a first 480-sample-pupil frame, changed atmosphere
  settings and scientific settings worker, with no GPU libraries loaded.

- Calibration: 147; startup FITS mask: 39; named-profile/CLI: 23; formatter: 50.
- Full simulation/hardware mode comparison: 841 assertions against the earlier
  concrete application with equivalent host settings. Repository format and
  both whitespace checks passed.

Optional-extension loading emitted Julia build-ID cache warnings during concurrent
source iteration; final selectors passed without behavioral failures. The actual
CLI build failed on an overlapping analysis CPU example before that configuration
was corrected, then passed with disjoint analysis CPUs. No GitHub Actions run
was needed. Command families and native output paths are in the instrument guide.

These are offline software and CPU optical checks. Frozen calibration bytes and
package metadata are unchanged; native hardware templates are byte-identical
moves. No calibration, physical-device, GPU, cadence, latency or hardware
qualification is implied. Live RTC PID `1877367` and invocation
`d2fa50c0f07740428be9c27d0d0e4152` remained unchanged; no live deployment was made.
