# Core package validation — 2026-10-14

Scope: PipeWireAORTC package rename/API, owned-memory FITS, sparse startup
preloads and shared owner entry points. Julia 1.12.7, Linux x86_64, FITSIO 0.17.5.
This is software verification. No live RTC, GUI, GPU or hardware was changed.

## Package checks

`julia --startup-file=no --project=. -e 'using Pkg; Pkg.test()'` passes:
**53 testsets, 1,848 assertions**, exit 0. [Full output](Pkg.test.log).
The normal Pkg test environment, native codec records, configuration, calibration
client fixtures, export/relocation and new artifact/owner checks are included.
Native process integration is a separate opt-in suite and was not run.

The first Pkg test attempt failed before running tests: the Manifest still named
the package `PipeWireAODeployment`, despite the new Project/module name. Main
environment import checks had not exercised this boundary. The unchanged UUID
caused Pkg.resolve to preserve the stale name. The isolated loader regression is
reproducible with the same command on both sources:

```sh
julia --startup-file=no --project=test -e 'using PipeWireAORTC'
```

- Committed rename baseline `fdc3f24`, clean detached worktree:
  exit 1, [required-but-not-installed error](rename-before.log).
- Corrected implementation worktree: exit 0, [empty successful output](rename-after.log).

[Manifest.before.toml](Manifest.before.toml) is the preserved pre-repair lock with
the new FITS dependency closure already present. This is evidence, not an active
environment. Repair used public Pkg operations: an anonymous metadata-only scratch
application temporarily listed the stale self as a direct dependency; manifest-mode
Pkg.rm removed it while preserving the other dependencies. The generated lock
was moved back to the package, test self-dependency/source declarations were
restored, and a fresh Pkg.resolve added the canonical self record. All **59 full
non-self records are exactly unchanged**, including versions, tree hashes, source
pins and dependency edges. The self record changes only its table name. The
project hash changes as expected. No Manifest was edited by hand.

A permanent package test now checks the canonical Manifest self name. Astra
independently verified the loader failure/success and exact record preservation;
see [IV-08](../../reviews/20261014/IMPLEMENTATION_VERIFICATION.md#iv-08--stale-manifest-package-identity-blocked-isolated-test-loading-repaired).

## Policy checks

WirePlumber branch `codex/session-rejection-20261014`, commit
`63f2df2ff88c07add386e28912e54bdeb345661b`, passes its isolated Lua regression:
44 malformed/state cases plus valid/duplicate requests, post-handoff errors,
core/identity loss and expiry. Root and Astra replayed this result. The original
wrong-arity causal claim is withdrawn; the same malformed operation-14 type
field faults before and preserves health after the fix. This policy is not
installed in the existing live service.

## Open application gates

Core registration, scientific owner migration and the small Classic application
have distinct gates in [the migration contract](../../REGISTERED_RTC_MIGRATION.md).
These checks do not qualify scientific numerics, resource timing, FGN parity,
Copper/SPIDERS acquisition, warmup/Quit reliability or physical operation.
