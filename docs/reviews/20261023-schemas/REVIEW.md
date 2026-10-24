# Typed scientific schema migration review — 2026-10-23

Independent source review of the coordinated, uncommitted migration on branch
`codex/schema-contracts`. The following dedicated worktrees were reviewed against
their base commits; pre-existing migration edits were preserved.

| Repository | Worktree under `/home/dgamroth/workspaces/codex/worktrees/` | Base commit |
| --- | --- | --- |
| JuliaFilterGraph | `schema-contracts-jfg` | `b95e1759c7134f48772ede8671c592b2d7478045` |
| PipeWireAORTC | `schema-contracts-rtc` | `e4004582106edfb797309b510e998d710117808b` |
| Instruments | `schema-contracts-instruments` | `42b08c947b4ac322c68bd16ea708a62b62a6f460` |
| GUI | `schema-contracts-gui` | `6eb53450f4eb3a26d0aca5d9ed1c0d38a0421288` |
| HIL adapter | `schema-contracts-hil` | `38047637398c64eb6fd5198dc166ba194ccc3a82` |

## Scope and evidence

Reviewed the shared catalog/generator, scientific Port declarations, RTC source
reference resolution and runtime packaging, instrument authoring, GUI consumers,
and HIL observation declarations. Checks focused on exact identifiers and element
types, external schemas, consumer drift, physical meaning, generic instrument
support, and cold preparation versus frame execution. Frozen historical receipts
and externally owned HEART schemas remain outside the namespace rewrite.

The reviewer independently ran, successfully, from the JFG worktree:

```sh
julia scripts/generate_schemas.jl --check --rtc ../schema-contracts-rtc --gui ../schema-contracts-gui --hil ../schema-contracts-hil
```

This was repeated successfully after remediation. No live sessions, deployment,
or production files were changed by this review. Direct RTC import in the default
Julia 1.13 project failed because that environment lacked YAML; this is an
environment limitation, not evidence about the migration. Focused test results
reported by the coordinating agent are distinguished below from reviewer-run
checks. Subsequent reassessment covered the three fixes only.

## Findings and disposition

### SCHEMA-001 — P1: applied-command observation advertised incorrect units

**Confidence:** confirmed by source. The migrated HIL
`src/applied_command.jl` advertised `applied-dm-command-opd-um-f32/1`, but staging
divided the adopted plant command by the configured input scale. A metre-OPD
input with scale 1 therefore emitted metre values under a micrometre declaration,
an error of 10⁶. The AOS HIL boundary accepts arbitrary floating graph inputs, so
assuming every plant command is physical DM OPD would not repair the contract.

**Remediation inspected:** optional DM observation preparation now accepts only
the declared micrometre-DM or metre-actuator command schema with its matching
input-to-metre scale. It converts adopted metre OPD to micrometres using a fixed
scale. Mandatory external/custom command exchange remains available. Observation
storage and format derive their actuator count from the command vector instead
of fixing it to 277. Returned units explicitly identify micrometre OPD.

**Disposition:** closed. The coordinator reports fail-before/pass-after unit
evidence, 79 passing applied-command, contract, allocation, and concurrency
assertions, and 141 passing private-core assertions. The reviewer inspected the
updated HIL README observation section: its schema, dynamic shape, qualified
input meanings, and fixed micrometre conversion match the implementation.

### SCHEMA-002 — P1: copied runtimes omitted their required schema catalog

**Confidence:** confirmed by source. RTC `src/schemas.jl` eagerly reads
`data/schemas.yaml`, while `ScienceExport.RUNTIME_ENTRIES` initially omitted
`data`. `copy_deployment_runtime` consequently omitted a required module-load
resource; operational source hashing omitted the catalog as well.

**Remediation inspected:** `data` is included in `RUNTIME_ENTRIES`, bringing the
catalog into both copying and operational hashing.

**Disposition:** closed. The coordinator reports 276 passing package assertions
(29 + 241 + 6), including copied/relocated-runtime loading, and 49 passing runtime
export assertions using a complete validation environment. The validation
Manifest was corrected after the checked-in runtime Manifest lacked YAML; the complete source-validation
Manifest was used temporarily for this selector and then restored.

### SCHEMA-003 — P2: concrete sessions bypassed schema/type validation

**Confidence:** confirmed by source. RTC
`src/deployment/session_configuration.jl` returned immediately for documents with
no references, before reaching the new schema validation. A concrete known
identifier with a contradictory element type was therefore accepted; an unrelated
reference changed whether it was checked.

**Remediation inspected:** the no-reference branch validates every input document
before returning. The reference branch still resolves and validates all documents
before rewriting any of them.

**Disposition:** closed. The focused regression exercises a concrete known
command schema with F64 rejection and matching F32 acceptance; the coordinator
reports both assertions passed.

## Final evidence and limits

All three confirmed findings are closed following source reassessment and the
coordinator's focused validation evidence. No additional confirmed code defects
were found in the reviewed migration paths. The coordinator also reports:

- RTC schema checks: 331 assertions passed.
- Classic instrument modes: 840 assertions passed; historical receipts retained
  through the explicit test-only identifier map.
- Instrument profiles: 49 assertions passed for offline CPU/CUDA/AMDGPU authoring
  without loading a GPU; CPU owner preparation: 14 assertions passed.
- GUI: 1,047 Rust and 151 Julia assertions passed; WASM and formatting passed.
  Clippy retained the reported baseline diagnostics.
- The running service retained PID `1877367` and invocation
  `d2fa50c0f07740428be9c27d0d0e4152`; no service mutation was performed.

These additional results are coordinator-reported, not independently rerun by
the reviewer. The generator projection check and final RTC whitespace check were
reviewer-run. CPU software and private-core checks do not establish
physical-device or real-time qualification. GPU profile authoring checks do not
establish GPU execution correctness.

## Final coordinator verification

The tracked RTC Manifest was resolved against the existing Project to include its
already-declared YAML and Interpolations dependencies and their registered
closures. No direct dependency, local source override or scientific package pin
was added. The final 276-assertion package selector passed with `--project=.`
using that actual Manifest, including copied and relocated SDK imports. The
earlier temporary source-validation Manifest was not retained in the repository.

Source-validation environment:
`/home/dgamroth/workspaces/codex/worktrees/schema-contracts-validation`.
CPU wrapper:
`/home/dgamroth/workspaces/codex/worktrees/classic-mirror-description-20261022/with-cpu-sdk.sh`.
It selects Julia 1.13.2, one Julia/BLAS thread, hidden GPUs and the existing
20261021 CPU SDK. Focused selectors were:

- JFG generator `--check` with all three consumer roots; full FGA suite
  14,000 checks; snapshot/example checks 632; final catalog/projection checks
  668. The last custom pixel-selection snapshot change passed its two hash
  checks and 29 algorithm checks. Numerical and allocation tests passed.
- RTC shared schema checks 331, catalog/component/graph/session/export selectors
  (individual passing summaries retained in tool output), rectangular JFG and
  cold SH/Pyramid observation contracts 36, runtime export 49, package 276.
- Classic configuration 59, CPU owner 14 (480-sample first frame and settings
  rebuild), profiles 49 (offline CPU/CUDA/AMDGPU), and modes 840. Mode checks
  compare the previous telemetry application with matching CPU scheduling and
  preserve source and frozen receipt bytes.
- HIL applied-command checks 79 and private-core publication 141. The metre-input
  unit case failed before normalization and passed after. Warmed allocation and
  snapshot coherence checks passed. The private core was created and closed by
  the selector; it never attached to the user's session.
- GUI Rust library 586 and native binary/import/examples 461, Julia fixtures
  151; WASM, formatting and whitespace pass. Strict Clippy encounters four
  pre-existing `chunks_exact_to_as_chunks` findings; it passes with only that
  baseline lint and the existing deprecated-atomic warnings allowed. No visual
  or browser rendering change is claimed.

Representative logs remain `/tmp/schema-{classic-owner,classic-profiles,classic-modes,
rtc-contracts,rtc-runtime,rtc-package,hil-applied,hil-units-before,hil-private,
gui-native-tests,gui-clippy-baseline-allowed}.log`; the failed initial cases are
investigation evidence, not final failures. Instrument formatter `--check` and
all five repository whitespace checks pass.

The live user service was read only. Before and after: active,
PID `1877367`, invocation `d2fa50c0f07740428be9c27d0d0e4152`. No install,
restart, GPU execution, calibration regeneration, database rewrite or Git
artifact-history migration occurred. These checks establish source-level
software/CPU behavior; they do not qualify hardware, cadence or deadlines.

## Identifier preflight and retained boundaries

| Surface | Meaning and authority | Decision |
| --- | --- | --- |
| `pipewireao/<quantity>-<type>/<version>` | User-approved project payload convention; scientific definitions in the shared catalog | Derive from one name/type/version declaration; no reverse-DNS or instrument prefix |
| `element_type`, `wire_type` | Julia scientific type and corresponding SPA enum | Generate together; never infer scientific meaning by parsing the ID |
| `/schemas/<key>/id` | Existing cold configuration reference mechanism | Resolve before native publication; no new wire parser |
| `wind_speed_m_s`, `altitude_m` | Physical wind speed in m/s and altitude in m | Author with units; map to adopted AOS constructor fields at the boundary |
| `ground`, `layer_1km`, etc. | Local stochastic atmosphere identities | Remove instrument prefix while satisfying AOS identifier syntax; realization may change |

Externally owned HEART contracts, frozen evidence, historical Git/SQLite data,
and existing `api.calculon.*` plugin factory names are separate boundaries. The
factory API was not silently renamed by the scientific-schema migration.
