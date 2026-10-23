# Shared authoring independent review — 2026-10-23

## Scope and source

Read-only independent implementation review of the `codex/shared-authoring`
working changes in these dedicated worktrees:

| Repository | Worktree | Base commit |
| --- | --- | --- |
| PipeWireAORTC | `rtc-shared-authoring` | `f13ead4639475315971ed50627ebd15c2b191797` |
| Instruments | `instruments-shared-authoring` | `1c034ddee474e8a63bd7b2d2f02d3c3d0db6db56` |

The review covers YAML mirror authoring and native JSON publication, package-owned
basis and simulator-schema definitions, controller-derived execution dimensions,
calibration rewrites, and the Classic data migration. It applies the repository
ownership instructions and `preserve-domain-language` review workflow. Scientific
and protocol terms retain their existing owners; the new `template` selector is a
cold configuration mechanism. No protocol or scientific algorithm is changed by
this work.

## Findings and disposition

Accepted for the requested source and CPU software scope. No unresolved findings
or pending checks remain in that scope.

| ID | Severity / confidence | Evidence and analysis | Remediation / disposition |
| --- | --- | --- | --- |
| SA-001 | Low / confirmed | The instrument READMEs initially referenced the removed `hsdm277.json` source and described every execution dimension as an integer in `dimensions`. The new authoring uses YAML, controller-coordinate counts and JSON Pointer references. This could direct authors to the wrong file or duplicate derived dimensions. | Resolved. File references, format descriptions and dimension guidance were corrected and inspected during review. |
| SA-002 | Low / confirmed | The new architecture description initially claimed zero hidden modes were supported without qualification. Declaration resolution accepts an empty list, but `FilterGraphAlgorithms/src/algorithms/control/closed_loop_correction.jl` requires `hidden_mode_count > 0` for its current native Algorithm constructor. | Resolved. The architecture now distinguishes declaration support from the selected algorithm's dimension constraints. No FGA change was requested or made. |
| SA-003 | Medium / confirmed | Profile `settings_schema` historically maps property names to schemas. The new `shared_settings_schema` discriminator treated any map containing `template` as a catalog selection. A valid inline property map `{template: {type: string}}` consequently failed `load_simulation` with `ArgumentError: invalid catalog template`. An independent copied-source probe reproduced the failure. | Resolved. `resolve_profile_settings_schema` dispatches on the template value and preserves schema-valued inline properties. Four focused resolver checks and two source-load/settings regression checks were added. The independent copied-source probe passed after the fix (4/4), including inline property configuration and measured-template resolution. |

## Source assessment

- Both mirror geometry and native publication now use the same validated reader.
  YAML input and serialized JSON are each bounded to 64 KiB. Existing valid JSON
  retains its publication bytes; duplicate fields are rejected in both forms.
- Package catalog names cannot select arbitrary paths. Resolved basis definitions
  retain the application's ID, name, units and coefficient limit. Inline analytic
  and sampled definitions retain ordinary validation, including sampled artifact
  shape and command-order checks.
- Simulator schemas resolve before declaration validation, settings handling and
  prescription identity. Profile names come from the instrument's own profile
  declarations. The measured-influence profile schema also resolves from package
  data before those consumers. Schema and basis results are independently owned
  copies.
- Controller command count and hidden-mode count derive from explicit controller
  coordinates. Physical count derives from the selected mirror description.
  Active VDM dimensions remain explicit or reference controller coordinates;
  state length remains a graph-specific declaration. No FITS array supplies an
  execution-dimension authority.
- `load_rtc` retains separate raw authoring and resolved values. Calibration writes
  the raw controller and basis selections, preserving shared templates and
  references. The added hidden-projection shape check occurs before file writes.
  Publication consumes resolved basis definitions and therefore includes their
  scientific values in the existing scientific identity.

## Independent verification

An independent ten-assertion probe passed using Julia in
`shared-authoring-validation`, invoked through
`classic-mirror-description-20261022/with-cpu-sdk.sh` (10/10, 27.7 s). It verified:

- Changing a resolved simulator schema changes prescription identity.
- Raw controller dimensions and template-bearing controls remain separate from
  derived dimensions and resolved bases; the raw controls do not alias resolved
  controls.
- Classic derives 212 controller commands and 277 physical commands.
- The source mirror YAML equals the published JSON object, which passes the
  ordinary mirror-description validator with 277 commands.

The SA-003 fail-before/pass-after probe used the same copied-source profile
property and the same `load_simulation` entry point. After the fix it also checked
the configured value and the resolved measured-influence profile (4/4, 9.0 s).

The implementation owner reported these focused software checks passing against
the final source (Julia 1.13.2, CPU validation environment, one Julia/BLAS thread):

| Selector | Passing assertions |
| --- | ---: |
| Controller dimensions | 18 |
| Declaration schema | 62 |
| Shared catalogs, including measured schema and SA-003 regressions | 57 |
| Mirror geometry / mirror publication | 78 / 175 |
| RTC source export / influence helpers | 132 / 16 |
| Instrument configuration / modal controls | 59 / 20 |
| Instrument geometry / hardware-profile export | 167 / 33 |
| CPU owner and settings worker, including a 480-sample first frame | 14 |
| Calibration, including raw-template/reference preservation and pre-write projection rejection | 147 |
| Instrument graph references | 39 |
| Full offline application modes | 841 |
| Optional legacy-package CPU preparation through the YAML-to-JSON boundary | 65 |
| Complete baseline equalities | 8 |

`git diff --check` passed in both worktrees at the review checkpoint; the
repository formatter check also passed. The eight baseline equalities cover four
complete optical graphs, root settings schema, the entire simulation definition
including the measured profile, controls and complete RTC publication. The
captured baseline JSON has SHA-256
`9378a78a71f16ce90394374ec03e8d574790dfd606911c3ddfc11bcfcd0b0816`.
Legacy-package CPU preparation reports a 352 × 352 detector frame, 277 commands
and first sequence 1. These final integration results were supplied by the
implementation owner after source freeze.

The reproducible command prefix uses the existing CPU SDK wrapper and private
source-validation environment. For example, the catalog selector is:

```sh
/home/dgamroth/workspaces/codex/worktrees/classic-mirror-description-20261022/with-cpu-sdk.sh \
  julia --project=/home/dgamroth/workspaces/codex/worktrees/shared-authoring-validation \
  /home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc/test/test_instrument_catalogs.jl
```

The same prefix accepts the absolute instrument selector paths, for example
`/home/dgamroth/workspaces/codex/adaptive-optics-simulations/test/configuration.jl`.
The instrument `MIGRATION.md` records integration selector arguments and their
software-only scope. No extra full-suite or billed CI run was needed for this
bounded authoring change.

## Limits

This is source and CPU software evidence. It does not establish live session,
GPU, device, physical-loop, deadline or tail-latency qualification. The review did
not connect to, stop, replace or install a live RTC session.
The implementation owner verified that live PID `1877367` and systemd invocation
`d2fa50c0f07740428be9c27d0d0e4152` remained unchanged.
