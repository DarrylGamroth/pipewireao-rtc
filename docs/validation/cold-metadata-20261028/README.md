# Cold physical metadata serialization — 2026-10-28

Scope: RTC cold publication, scientific identity and declaration verification.
The source base is published RTC 0.2.42, merge `d7363d82`; release `eac5dca`
has the same source tree. Work started on a clean dedicated worktree and branch
`fix/cold-metadata-json-20261028`. No package version, registered package,
instrument source, calibration selection or original application was changed.

## Cause and change

Observed native startup stacks enter `JSON.json` through `json_value` while
verifying the physical declaration. JSON/StructUtils generates one operation per
tuple field. Sealed declarations include 2,304-element command-position,
controlled-actuator and sampled-basis tuples, so the generated serializer grows
with physical command count.

`Common.metadata_json_value` now walks sealed tuples with a dynamic indexed loop
behind `@nospecializeinfer`, producing `Vector{Any}` arrays. Named tuples retain
their field names and order. Other values retain JSON's existing lowering,
including Float32 values, custom scalars, matrices and pair vectors. The helper
does not mutate or replace the scientific declaration. `json_value` and
`scientific_identity` use this representation; `prepare_publication` lowers its
body once before its existing size check and atomic writer. General JSON writers
and native protocol serialization are unchanged.

## Measurements

Fresh Julia 1.13.3 processes used default optimization (`-O2`), existing dependency
caches and `--startup-file=no`; no global caches were removed. These are diagnostic
first-call measurements on a shared workstation, not deadline benchmarks.

The same [serialization selector](serialization.jl), using GPI2's real physical
declaration, produced:

| Measurement | Published 0.2.42 | Candidate |
| --- | ---: | ---: |
| First serialization | 10.185 s | 1.120 s |
| Compilation within first serialization | 10.182 s | 1.117 s |
| First-call allocations | 4,037,932,600 B | 77,626,488 B |
| Warmed serialization | 2.335 ms | 2.915 ms |
| Warmed allocations | 3,330,880 B | 4,342,112 B |

The extra traversal allocates during this cold metadata operation. Its warmed
cost is reported explicitly; it is outside frame processing.

The [full publication selector](publication.jl) on
`gpi2/rtc/cal2-testplant/configuration.yaml` completed in 55.775 s (53.581 s
compilation; 5,396,237,320 B allocated), then 3.009 s warmed. Scientific identity
was `sha256:3c0837bab12afdbe0933e0ebf2cd1908048cd21ac056c5473b481496d9c7c63e`.
A bounded published-version run stopped after 45 s in the generated JSON tuple
writer inside controlled-actuator preparation. At the same bound, the candidate
was compiling YAML parsing; the later bounded candidate run completed. This does
not establish a full-publication speedup ratio. An exploratory `--compile=min`
compatibility run exceeded 120 s and was replaced by default-optimization checks.

## Compatibility and reproduction

`test/test_canonical_metadata.jl` checks exact bytes and SHA identity for field
order, scalar values, Float32 precision, matrices, custom lowering, empty arrays,
pair vectors and a 2,304-command physical declaration. Existing cold common,
instrument-definition, declaration-schema, pupil-source and instrument-export
selectors pass without scientific packages or a core.

The final writer selector passed in a fresh registered-runtime copy with only the
RTC source override. Full publication took 70.868 s (66.350 s compilation) in that
process. It demonstrated exact ordered bytes before writing, exact regenerated
bytes after the supported atomic writer, and unchanged original application hashes:

- Root `instrument.json`: `0e12b61a9353da16967c108bd54d2c9bfa75326cd64518b7b9a656e7e09cea37`.
- Accepted `generated/physical-offset-calibration/instrument.json`:
  `1dcc18ac18ab1f023c104123854e27f11a3a8676aeb05116342364fa367f347a`.
- Both publications retain scientific identity
  `sha256:3c0837bab12afdbe0933e0ebf2cd1908048cd21ac056c5473b481496d9c7c63e`.

The final focused canonical-metadata, declaration-schema and instrument-export
selectors passed after the writer change. Earlier common, instrument-definition
and pupil-source selectors also passed. No optional science package was imported.

For real application checks, copy the registered runtime's Project and Manifest
to a disposable validation environment, then use `Pkg.develop(path=RTC_ROOT)`.
Keep its source override out of the registered runtime and application manifests.
Run the [writer selector](writer.jl) only on a disposable copy of
`combined-testplant-0242-cuda`. It checks ordered publication bytes, regeneration,
the frozen scientific identity and the accepted materialized publication.

```sh
julia --startup-file=no --project="$VALIDATION_ENV" \
  "$RTC_ROOT/docs/validation/cold-metadata-20261028/writer.jl" "$APPLICATION_COPY"
julia --startup-file=no --project="$RTC_ROOT" \
  "$RTC_ROOT/docs/validation/cold-metadata-20261028/serialization.jl" \
  "$INSTRUMENT_ROOT/gpi2/instrument.yaml"
julia --startup-file=no --project="$RTC_ROOT" test/test_canonical_metadata.jl
```

All selectors are CPU-only and create no PipeWire core, service or GPU context.
Native owner readiness, captured optical preparation, hardware and deadline
qualification remain separate gates. Publication/version changes remain held
for independent review and integration.
