# Host scheduling derivation — 2026-10-23

Work started from clean RTC `1e7a50a` and instruments `4bf1d2c` in dedicated
`codex/host-scheduling` worktrees. The primary owns implementation/integration;
a bounded worker migrated the two host examples and guides, and an independent
reviewer inspected the shared normalizer, contracts, examples and tests.

## Delivered boundary

Host YAML has one `scheduling.processes` declaration. It retains the existing
process placement vocabulary and optional common `defaults`. Explicit RFC 6901
selectors in `scheduling.bindings` derive integer aliases and ordered CPU-list
arguments from those completed process contracts. Ordered scalar-reference lists
support worker subsets without changing the process CPU envelope. Native
`placement` and `bindings` are generated together; the runtime/template APIs,
readiness inspector and scheduler are unchanged. No instrument names or fixed
role/CPU mappings occur in the normalizer.

Both Classic examples preserve all previous resolved values. Existing
`RT_PRIORITY`, `_CPU` and `_CPUS` host aliases must use scheduling references;
ordinary non-scheduling arguments remain valid in top-level bindings. Arbitrary
application argument names carry no inferred scheduling meaning. Reference
selectors themselves accept no literal values or expression evaluation.

`locked-bytes` remains a minimum observed locked-memory requirement; it does
not allocate or lock memory. `threads` remains observed affinity/policy/count
requirements, not thread creation. `OPTICAL_CPU` pins optional CPU optical
observation (focal plane, residual wavefront and RMS), not the whole AOS graph
or GPU execution. These meanings are documented in the active guides.

## Review and verification

The independent review found no confirmed defect in validation, reference scope,
CPU-list order, default precedence, input mutation isolation, merge conflicts,
reserved aliases or the migrated host values. The reviewer noted that arbitrary
priority-like argument names are not inferred from spelling. This is intentional:
explicit selectors establish the scheduling mapping; the documented guards cover
existing template conventions. No extra naming heuristic was added.

Julia 1.13.2 checks used one Julia/BLAS thread, disabled GPU visibility, the
existing CPU SDK wrapper and the private `host-scheduling-validation` environment.
It selects the task RTC source and established scientific dependencies. Commands:

- RTC `test/test_instrument_profiles.jl`: 67 passed, including arbitrary owner
  names, a changed thread CPU propagating to both consumers, common defaults,
  ordered subsets, invalid selectors, duplicates and mutation isolation.
- RTC `test/test_instrument_export.jl`: 132; `test/test_loop_placement.jl`: 20.
- Instrument `test/profiles.jl`: 23; `test/hardware_profile.jl`: 35.
- Exact equality of both migrated hosts with the pre-edit compiled profile: 2.
- Instrument `test/modes.jl HOST.yaml PREVIOUS_APPLICATION`: 841. The private
  historical host was migrated with references preserving every old worker
  order, CPU, priority and memory requirement; the prior concrete application
  remains the comparison source.
- Instrument `test/owner.jl`: 14, including a first 480-sample-pupil CPU frame,
  atmosphere change and settings worker, with no GPU libraries loaded.
- Instrument `tools/format.jl --check` and both whitespace checks passed.

Only the source host examples and maintained documentation changed in the
instrument repository. No scientific arrays, calibration bytes, optical values
or native template contents changed. No real-time, cadence, hardware or actual
live scheduling qualification is claimed by these offline checks. No GitHub
Actions run was needed. The live service stayed active with PID `1877367` and
invocation `d2fa50c0f07740428be9c27d0d0e4152`; no installation or restart occurred.
