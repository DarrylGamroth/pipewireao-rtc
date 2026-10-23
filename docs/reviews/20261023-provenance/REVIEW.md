# Remove prose provenance from instrument metadata

Source baselines (2026-10-23): RTC `12bb4e8`, instruments `adc13b7`, GUI
`7acdfaf`, ALPAO adapter `f01361e`. Dedicated `codex/remove-provenance` worktrees
preserved canonical state. GUI's existing uncommitted
`docs/workstation-review.md` was not touched.

## Scope and review

Removed required prose provenance fields from mirror descriptions, sensor
layouts, shared and custom modal bases, RTC publication, GUI readers/exporters
and the ALPAO parser. Physical pitch remains optional and independently
validated. Shared mirror command-order text is now simply `physical`; the actual
ordered coordinates, values, units, axes, normalization, artifact identities and
calibration records are unchanged. No numeric model, controller, payload schema
identifier or live deployment changed. Regenerated metadata content hashes can
change because the serialized declarations change; historical records remain.
This is a coordinated development metadata-contract update, not a mixed-version
live deployment. No compatibility aliases or new provenance files were added.

An independent Sol review of all four source diffs found no actionable defects.
Primary inspection confirmed the cross-consumer field lists and structured
artifact metadata. Publication-size tests now use actual sampled numeric arrays
and FITS-backed modes instead of prose padding; structural bounds remain valid.

## Verification

Julia 1.13.2 with the existing CPU SDK and explicit source validation environment
`remove-provenance-validation`; GPU visibility empty. Focused RTC selectors:

- `test/test_instrument_definition.jl`: 172 assertions.
- `test/test_instrument_declaration_schema.jl`: 62.
- Geometry: 68; catalogs: 57; influence preparation: 16; dimensions: 18.
- Exporter/environment selection: 145.

Instrument selectors passed geometry 167, modal controls 20, profiles 49 and CPU
owner/settings 14 assertions. CPU checks include a first 480-sample-pupil frame
and atmosphere settings preparation; no GPU libraries load. Formatting and
whitespace checks pass. Two test migration errors (tuple punctuation and an
obsolete pitch/provenance pairing expectation) were corrected and their affected
selectors pass. No numerical coefficient or scientific artifact bytes changed.

GUI passed 585 library, 279 application and 12 integration tests (live tests
remain ignored), plus all 151 Julia fixture assertions, formatting, WASM/browser
checks and browser dependency exclusions. Strict Clippy reports existing Rust
1.99 `chunks_exact_to_as_chunks` errors and dependency atomic API deprecations;
allowing only those baseline lints passes. The affected old expressions were not
changed. No browser visual inspection or live restart was performed.

ALPAO offline `spa-alpao-factory` and `spa-alpao-mock` tests pass with the vendor
SDK disabled. Original/current validator builds give fail-before/pass-after for
a prose-free description and independent positive pitch. Sample JSON comparison
confirms unchanged physical values and ordered geometry after prose removal.
No physical hardware, throughput, real-time or GPU qualification is claimed.

The installed RTC remained active with PID `1877367`, invocation
`d2fa50c0f07740428be9c27d0d0e4152`. No service, GUI, installed file or GPU workload
was changed.
