# Classic instrument definition independent review

Review date: 2026-10-22. Scope: the approved shared scientific definition,
sealed operational publication, and exact-session GUI resolution. CPU software
review only. The reviewer did not operate services, access accelerators, edit
production source, register packages, or publish commits.

## Source boundary

The implementation agreement is `CONTRACT.md` in the
`worktrees/classic-instrument-definition-20261022` preparation directory.
The initially clean dedicated worktrees started at:

| Repository | Starting revision | Reviewed state |
| --- | --- | --- |
| REVOLTClassicSim | `603e58ba8ab278369d3b1ac138952a8fc6234db8` | Scientific API commit `803dc0c` |
| pipewireao-rtc | `033580bc004e046c79320899e1e12971748cec34` | Implementation working tree, including schema remediation |
| pipewireao-gui | `c0e7a7e651dd246885dcbf5de9d69a7d2ff0aefe` | Instrument consumer working tree |
| revolt-classic-rtc | `d81e3de9bfe6a3bf2d9ccc1604d55fd97f0aef96` | Generator, profile migration and application tests |

This record describes inspected source and received test evidence. Final
package pins, installation and live publication remain primary-agent gates.
The final cold review has no outstanding source finding. All three findings
below have corrected implementations; the separate application offline and
live integration gates remain with the primary agent.

## Finding INSTR-001 — detector schema absent from compatibility check

- Severity: P2. Confidence: high. Classification: confirmed source defect.
- Affected code: `src/instrument_definition.jl`, `verify_plant`.
- Observed: initial source checked detector shape and all fields from the
  scientific WFS layout, but omitted operational `expected_schema`. That field
  is added by the RTC application, so iterating the scientific layout cannot
  check it.
- Derived consequence: an independently changed operational detector schema
  passed the plant compatibility check while causing GUI sample rejection.
  The normal generator uses the correct configuration value; this was an
  invalid-configuration rejection gap, not evidence of changed numerical data.
- Remediation: compare the published `expected_schema` with
  `options.frame_schema` before execution; test mismatches on both sides.
- Disposition: primary agent added the exact comparison and both mismatch
  cases in `test/test_instrument_definition.jl`. Source remediation reviewed;
  the final focused regression passed, including both schema mismatch cases.
- Fail-before evidence: source-path inspection. No pre-fix execution claimed.

## Finding INSTR-002 — malformed operational bounds admitted

- Severity: P2. Confidence: high. Classification: confirmed validation defect,
  identified by the RTC test worker and independently checked in source.
- Affected code: `src/instrument_definition.jl`, `validate`.
- Observed: the initial loader bounded generic JSON but did not validate the
  operational amplitude limiter. Even the original test helper supplied
  scalar bounds despite the consumer contract requiring command-sized arrays.
  The primary agent reported the worker's reversed-bound experiment passing
  publication and plant verification before remediation.
- Consequence: malformed operational metadata could be published and admitted
  by RTC while the GUI correctly refused it. This does not demonstrate unsafe
  actuation; the executing graph retains its own limiter implementation.
- Remediation: require finite positive non-Boolean command scale and finite,
  non-Boolean, ordered, command-sized amplitude-bound arrays.
- Disposition: source remediation reviewed. Review also caught and corrected a
  local `values` binding that initially shadowed `Base.values` in the new loop.
  Final tests passed with valid vector bounds and 24 rejection assertions for
  invalid operational declarations. Closed for the cold software boundary.

## Finding INSTR-003 — offline diagnostic selects both control endpoints

- Severity: P2. Confidence: high. Classification: confirmed diagnostic defect.
- Affected code: application `check-offline.jl`, new publication assertions.
- Observed: filtering components only by module name selects both public
  session and controller endpoints; applying `only` therefore throws.
- Consequence: the offline preparation gate fails before checking instrument
  metadata, despite a valid configuration.
- Remediation: select the public component by `provides ==
  "ao.session-control"`, as the RTC publication regression already does.
- Disposition: the primary agent changed the selector to the exact public
  `provides` identity; source correction independently verified. Closed source
  defect. Execution of the complete pinned offline diagnostic is a separate
  primary-agent integration gate.

## Verified design properties

Observed from source and associated tests:

- The scientific package reads no RTC or GUI configuration. Its command map,
  mask and detector prescription generate the cold immutable definition.
  Existing graph values 16, 22 and 352 were factored into shared constants
  without numerical changes.
- Command positions retain physical command order. Source-row Zernike and
  Fourier coordinates remain distinct from provisional optical pupil
  coordinates. Fourier values retain their original Float32 rounding;
  Zernike values retain the original Float64 normalization.
- The application generator selects limiter bounds from the actual
  `pdm-command` graph configuration and calibration identity from the existing
  calibration-result asset. Its independent FITS test checks WFS origin order
  against the calibrated subaperture asset.
- RTC publication checks the sealed asset and publishes exact UTF-8 bytes and
  their SHA-256 only on the existing public session endpoint. Deployments
  without an instrument retain their existing path. No native command or
  frame-processing API was added. The final seal comparison uses the digest
  of the same loaded bytes that are published, avoiding a separate hash/read
  gap.
- The GUI captures metadata only after the full bound NodeInfo identity
  checks. Changed bytes, removal or addition within the binding retires the
  transport. Native request submission drains already available events before
  sending. The UI requires fresh selected-session Status and admitted adapter
  state before resolving geometry.
- GUI resolution validates all products against one component layout and
  existing native contracts. Invalid or missing definitions leave instrument
  panels unavailable. Replacing the panels drops old drafts and observations.
  Preview cannot substitute instrument geometry. Workspace persistence strips
  resolved DM and WFS scientific fields while retaining configured bindings
  and presentation.

No further actionable finding survived review. Mechanical naming/length
signals were considered in repository context and did not establish defects.

## Evidence inspected

Preparation-directory logs:

| Evidence | Result |
| --- | --- |
| `science-tests.log` | 17 geometry and 248 scientific-definition assertions passed |
| `app-instrument-tests-final.log` | 17 application assertions passed on the corrected validator |
| `rtc-instrument-final.log` | 103 assertions passed: 40 bounded publication, 24 invalid operational declarations, 17 plant compatibility, 11 cold AOS selection, 11 public-endpoint publication |

The initial `rtc-tests.log` run loaded pre-remediation package source while
tests were still being edited, and subsequently failed a new rejection
assertion. It is not final-source evidence. `rtc-tests-final.log` is the fresh
complete-suite run; the primary agent owns its final process-exit assessment.

GUI worker logs under `/tmp`:

| Evidence | Result |
| --- | --- |
| `gui-instrument-lib-tests.log` | 40 operator-view tests passed |
| `gui-instrument-panel-tests.log` | 268 panel tests passed |
| `gui-instrument-native-tests.log` | 3 instrument transport/session tests passed |
| `gui-instrument-session-tests.log` | 34 native-session tests passed |
| `gui-instrument-rtc-tests.log` | 31 passed, 5 opt-in tests ignored |
| `gui-instrument-wasm.log` | Shared WASM compilation passed |
| `gui-instrument-native-check.log` | Native compilation passed |
| `gui-instrument-exact-contract.log` | Actual 34,605-byte application definition resolved: 277 actuators, 188 subapertures, 10 views; scientific persistence excluded |

The exact-contract document SHA-256 was
`dddf56a551d87f24faecbb3980d6be88abceeb3842552dca4665c82ef9ccc1bb`.
Compilation emitted existing vendored Smithay warnings and existing atomic
`fetch_update` deprecation warnings; those lines are not introduced by this
change. The reviewer independently checked whitespace in RTC and GUI diffs.

These are software and cold contract checks. They do not establish installed
NodeInfo delivery, rendered native-window behavior, physical calibration,
hardware safety, or real-time performance. Full-suite and read-only live
exact-session publication evidence must be recorded separately before claiming
those gates complete.
