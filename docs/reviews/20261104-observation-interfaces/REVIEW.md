# Recovery observation interfaces — 2026-11-04

Status: implemented; focused, core and warmed allocation checks pass.

## Scope and baseline

Continued package cleanup on `codex/package-cleanup-20261104` in
`pipewireao-rtc-cleanup`, based at `4658e7f676c538df01c919b4902c9df25a63a105`.
The prior authorized cleanup, Hsm, Agent and Clocks edits remain intact. Before
this increment the core suite passed 9,317 assertions. The original checkout,
installed RTCs, instrument sources and services were preserved.

Authority remains RTC-DEV-034/035: exact owner/token/generation evidence,
serialized recovery, fresh closure prerequisites and no replay of uncertain
effects. Native schema versions, fields and numerical algorithms are unchanged.
The user requested domain types, abstract interfaces, traits and multiple
dispatch rather than primitive comparison helpers and representation branches.

## Findings and disposition

### OBS-01 — Generation semantics depend on primitive storage

Accepted design improvement; implemented. `recovery.jl` previously applied
`_generation_le`, `_generation_before` and related helpers directly to integers
and tuples. Scope checks compared storage types. The Hsm could not consume a
different observation representation through a documented interface.

`AbstractObservation` supplies owner/token/serial accessors.
`AbstractLoopObservation` adds requested/applied generation and closure accessors.
The existing concrete observation constructors and field layouts remain, with
the new abstract supertypes. SingleController and CoupledControllers{N} scope
traits select observation comparison and coordinator staging behavior.

The public comparison interface consumes observations:

| Operation | Meaning |
| --- | --- |
| `generations_match(observation)` | Every requested generation has been adopted |
| `requested_before(observation, bound)` | Requested evidence strictly precedes the bound |
| `active_before(observation, bound)` | Applied evidence strictly precedes the baseline |
| `active_at_most(observation, bound)` | Every applied component is at most its bound |
| `active_at_least(observation, baseline)` | Every applied component is at least its baseline |
| `all_open` / `all_closed` | All controllers meet the selected closure condition; mixed scopes satisfy neither |

Coupled comparisons use componentwise partial order. Crossed tuples are
incomparable and conflict rather than count as stale. Close staging permits
componentwise nondecrease with some advancement; protective recovery staging
requires every controller to advance. No lexicographic Base ordering is added.

ControllerScope describes representation and cardinality. Native adapters bind
owner/token identity and ordered names separately; a cardinality match alone is
not authority. Representation classification checks requested, active and closed
values without interpreting numeric freshness. Existing stale-evidence and
failure precedence is preserved. Malformed loop evidence does not consume its
serial; a matching malformed release consumes its serial before failure.

Tests provide a Readback subtype with different field names and drive the whole
Hsm through its accessors. Valid values in `LoopObservation{Any,Any}` continue to
work, demonstrating that storage parameters are not treated as domain identity.

### OBS-02 — Malformed active representation can qualify a coordinator

Confirmed defect; fixed. A legacy explicitly parameterized receipt can carry
requested `UInt64(3)` and active `Int64(3)`. The old shape check validates only
requested generation and closure representation; numeric equality then accepts
the invalid active type.

The same concrete receipt against saved/current source gives:

| Source | State | Failure | Consumed serial |
| --- | --- | --- | --- |
| Before | Closed | none | 1 |
| After | Unverified | loop_scope_mismatch | 0 |

Both generation representations must now satisfy the UInt64 controller contract.
This is intentional hardening of malformed evidence; valid constructors, values
and native readbacks retain their behavior. Tests also cover mismatched coupled
lengths and invalid Boolean/generation components.

### OBS-03 — Native recovery snapshots store parallel controller tuples

Accepted design improvement; implemented. The native client chose behavior from
`controller isa Tuple` and stored separate name, value, generation, state and
readiness columns. Their correspondence was reconstructed by index throughout
resume and readiness handling.

The parser now builds immutable ControllerReadback records, each with its exact
name, requested/applied generation, closure, adoption state and optional typed
ControllerReadiness. RecoverySnapshot stores one record for version 1 or an
ordered tuple of records for version 2. Scope-aware construction rejects
misgrouped records, duplicate names and wrong counts. Native parsing and its
existing error precedence remain at the boundary.

Snapshot implements AbstractLoopObservation. Old property reads are projections
of the records, rather than separately stored columns. Its existing native
recovery-transaction generation fields remain distinct from the loop-generation
accessors. A version-2 singleton remains a coupled scope.

Initial qualification still explicitly uses token zero. Bound observations use
the real persisted native request token after existing token/scope guards; old
token 7 is not silently relabeled as the current operation. Scope dispatch selects
scalar/coupled coordination. Effect dispatch selects ReleaseRecovery versus
CloseLoop: first closure releases once, later partial closure does not release
again. Fresh reference/readiness and selected/unselected controller checks remain.

### OBS-04 — Unsupported sensor procedures fall through to Pyramid validation

Confirmed defect; fixed with the existing sensor-kind Val trait. SCC and LLOWFS
recipes previously received Pyramid requirements and could pass them before a
later graph or missing-procedure error, despite the documented cold rejection.

The identical 20-assertion selector against saved/current recipe source yields
14 pass / 6 fail before and 20 pass after. The six cases cover `read_recipe`,
`calibrate_system` and `validate_system` for both unsupported sensors. They use
otherwise valid Pyramid-shaped recipes, so missing-field rejection cannot mask
the defect. Supported SH/Pyramid validation-order assertions pass 11/11 on both
sources. Tests confirm no optional science/accelerator loading or output creation.

## Broader source audit

The following verified representation-coupling sites remain separate optional
science work. They are design improvements, not established numerical defects:

| Site | Interface opportunity | Required verification before changing it |
| --- | --- | --- |
| `ext/calibration_owner.jl`, `ext/calibration_graphs.jl` | Give graph projections an explicit type; dispatch single/named commands instead of excluding NamedTuple field shapes | Actual projection/name/schema/reference-copy checks in `test/calibration_named_commands.jl`, named transport and teardown |
| `ext/optical_calibration.jl` measurement preparation | Represent center-of-gravity versus selected-pixel measurement explicitly instead of inferring it from optional coordinates | Identical numerical measurements, centroid cancellation, masks, FITS units and content identities in optical/publication selectors |
| `ext/optical_calibration.jl` publication | Represent physical versus completed virtual-mirror command coordinates explicitly | Exact artifact/report paths, mappings, units and completed inverse residuals |

Those changes need their actual optional CPU science environments and numerical
or publication oracles. This increment changes no optical arithmetic, gains,
thresholds or artifacts. Native version/tag checks, heterogeneous saved-document
validation and strict frame metadata presence checks remain legitimate boundary
validation. Repository guidance now records the domain-interface convention.

## Verification

- Five focused selectors pass **605 assertions across 46 testsets**: recovery
  interfaces, coordinator, native scalar client, coupled client and cold recipe.
- The interface selector contributes 63 assertions, including a custom layout,
  scalar/coupled-singleton distinction, partial ordering and refusal boundaries.
  Client selectors pass 261 assertions, including 81 normalization regressions.
- `Test.detect_ambiguities(CorrectionRecovery; recursive=false)` reports zero.
  Independent source review reports no confirmed issues in the observation,
  coordinator or frozen client/controller changes.
- The allocation selector passes 17 assertions. After warmup, 1,000 correction
  loop cycles, scalar recovery cycles, coupled recovery cycles and ready
  preparation checks each allocate zero bytes. Constructors, parsing, transport,
  failures and scientific execution are outside that region.

The full core command uses the explicit artifact prefix:

```sh
julia --startup-file=no --project=. -e 'using PipeWireAO; ENV["PIPEWIREAO_PREFIX"] = String(PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir); include("test/runtests.jl")'
```

The core suite passes **9,519 assertions across 426 testsets**, exit 0. Its
existing intentional missing-Git-object test emits the known `cat-file`
diagnostic; every testset passes. Six changed Markdown files parse, the new
interface guide's Julia example executes, and all newly public interface names
have help documentation. Changed link targets, fences, final newlines and
`git diff --check` pass. No requirement identities or Mermaid diagrams changed.

Verification uses Julia 1.13.3. No live core, service, science graph or device
was changed. Software and warmed allocation checks do not qualify hardware or
RT deadlines. Optional optical/science selectors were not rerun.
