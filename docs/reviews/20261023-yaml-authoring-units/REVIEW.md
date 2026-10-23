# YAML authoring and pitch units review — 2026-10-23

Independent source review of RTC `codex/yaml-authoring-units` from
`36d2f692cabca60dd937621144a66ccc13c7437d`, instruments
`codex/yaml-authoring-units` from `3f45c332d150c6fed8942fa98e7351ba2b611946`,
and ALPAO `codex/mirror-pitch-metadata` through
`f01361eacd0352c876b69885ab186789a62f60cc` (including `ae7495a`). The first two
contained the coordinator's uncommitted implementation; the reviewer changed
only this record. No live application or hardware was accessed.

## Findings

### YAU-01 — maintained package route rejects the shared description

- Severity: P2. Confidence: observed.
- Evidence: instruments `mirrors/alpao/hsdm277.json` adds decimal
  `actuator_pitch_m` and its provenance. The maintained
  `REVOLTClassicSim/src/mirror_description.jl` permits only integer number
  tokens and exactly five root fields. Its fixed ID is also incompatible with
  the shared file's existing `alpao-hsdm277` ID.
- Reproduction: loading the changed shared file with that parser in the source
  validation environment raises `ArgumentError: expected a positive integer,
  string, or container`. RTC `test/aos_instrument_preparation.jl` copies the
  exact `REVOLT_CLASSIC_MIRROR_DESCRIPTION` bytes into its version 2 package
  route, so the documented shared input cannot prepare that route.
- Scope: the ID restriction predates this change; decimal and optional-field
  incompatibility is newly exposed by mechanical metadata. The data-only
  version 3 route has a separate parser and is unaffected by this finding.
- Required remediation: accept generic description IDs and validate/preserve
  the optional paired mechanical fields in the legacy cold reader, preserving
  its existing pupil registration and numerical behavior.
- Disposition: resolved by `49241bd` in
  `revolt-classic-mirror-pitch-metadata` from `07d424c`. Generic IDs and paired
  mechanical fields are now accepted and retained; existing integer layout,
  manufacturer, duplicate-key, Unicode and normalized-registration checks
  remain. An independent post-fix probe parses the exact shared file that
  failed above and rejects malformed, nonfinite, boolean and underflowing pitch
  tokens. The worker reports 328 passing focused assertions, including reader,
  command-grid/order, optional metadata and pupil registration checks. The
  coordinator's actual shared-file CPU package-route selector passes all 65
  assertions, preparing a 352 × 352 frame and 277 commands and advancing its
  first graph sequence to 1 without transport.

### YAU-02 — repeated explicit YAML merge keys bypass duplicate rejection

- Severity: P2. Confidence: observed.
- Evidence: RTC `src/common.jl`, `read_yaml` skips merge-tag keys before its
  explicit-key duplicate check. Input `x:\n  <<: {a: 1}\n  <<: {b: 2}\n`
  is accepted as a mapping containing both `a` and `b`.
- Impact: newly migrated physical and RTC inputs admit duplicate explicit
  mapping keys despite their declared duplicate-rejection contract. This is
  inherited helper behavior, not a new writer defect.
- Required remediation: reject repeated merge keys within one mapping while
  preserving the existing supported merge-plus-explicit-override behavior.
- Disposition: resolved. The coordinator added a mapping-local `merge_seen`
  check and the exact regression. Independent post-fix probes reject the same
  duplicate merge input, preserve an ordinary explicit override, and permit
  separate mappings to use their own merge key.

## Reviewed boundaries

Source inspection found no additional actionable defect in YAML path resolution,
shared-description localization, startup calibration identity rewrites,
calibration dimension rewrites, or the mechanical/pupil pitch separation.
Resolved AOS node configurations retain the existing `actuator_pitch` API key
and obtain its value from `actuator_pitch_pupil_radius`; mechanical metadata
does not enter actuator-coordinate or influence-sampling equations. Native
PipeWire configuration and JSON metadata publication retain their consumers.
The ALPAO parser validates optional-field pairing, strict positive finite number
syntax and duplicate fields; publication continues to use the supplied bytes.

## Validation

Reviewer probes confirmed nested and quoted-key YAML duplicate rejection,
ordinary merge overrides, decimal/exponent loading, and both findings above.
The coordinator reports passing focused RTC schema (62), common (45), geometry
(48), influence (16), publication/compatibility (162), exporter (132), and
rectangular JFG/CPU metadata integration (36) assertions. Publication coverage
includes exact supplied JSON bytes with optional pitch fields and missing-pair
rejection.

The reviewed ALPAO build log records three passing tests, including its mock
sink. The instrument worker reports passing configuration (57), geometry (167),
camera (39), hardware profile (33), modal controls (20), graph references (39),
calibration (141), startup mask (39), owner (14), and modes/build (841)
assertions. Owner validation prepares a 480-sample CPU plant, advances its first
frame and exercises settings preparation without CUDA or GPU libraries. Four
complete resolved optical graphs equal the captured `3f45c33` baseline; the
baseline SHA-256 is
`0719a7e02a9be89d2d1a4f93e893e485ace3a6f5b697d4c18eafbdf0e0a87536`.
Formatting tests (50), formatter checks and final whitespace checks pass.

Both actionable findings are resolved and their repairs reviewed. No unresolved
actionable finding remains in the requested source migration and pitch metadata
scope; the passing checks support software acceptance of that scope.

Reproduce RTC selectors from the reviewed RTC checkout with the source
validation environment and the single-threaded CPU SDK wrapper:

```sh
/home/dgamroth/workspaces/codex/worktrees/classic-mirror-description-20261022/with-cpu-sdk.sh \
  julia --startup-file=no \
  --project=/home/dgamroth/workspaces/codex/worktrees/yaml-authoring-units-validation \
  test/test_common.jl
```

Replace the final path with `test/test_instrument_declaration_schema.jl`,
`test/test_instrument_geometry.jl`, `test/test_instrument_influences.jl`,
`test/test_instrument_definition.jl`, `test/test_instrument_export.jl`, or
`test/test_session_configuration_integration.jl` for the other reported
selectors. For the maintained package route, use the same command pattern with
`test/aos_instrument_preparation.jl cpu` and set
`REVOLT_CLASSIC_MIRROR_DESCRIPTION` to
`/home/dgamroth/workspaces/codex/worktrees/instruments-yaml-authoring-units/mirrors/alpao/hsdm277.json`.
That environment must resolve the repaired legacy package (`49241bd`). Source
overrides were validation-only; the coordinator will retarget them to the
integrated canonical checkouts while retaining the comparison baseline.

All evidence is software-only. There is no live deployment, physical-device,
metrology, deadline or latency qualification claim.
