# Core package validation — 2026-10-14

Scope: PipeWireAORTC package rename/API, owned-memory FITS, sparse startup
preloads and shared owner entry points. Julia 1.12.7, Linux x86_64, FITSIO 0.17.5.
This is software verification. No live RTC, GUI, GPU or hardware was changed.

## Package checks

`julia --startup-file=no --project=. -e 'using Pkg; Pkg.test()'` passes:
**53 testsets, 1,848 assertions**, exit 0. [Full output](Pkg.test.log).
Recorded logs have trailing whitespace removed; their content/order is retained.
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
project hash changes as expected. This comparison describes the rename repair
before the subsequent 0.1.1 patch-version increment. No Manifest was edited by hand.

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

## Registered-copy test boundary

A separate fresh-depot install resolved the registered 0.1.0 tree, loaded it
normally, verified a nonsquare FITS selection and found no `path` dependencies
or application `[sources]` overrides. The restarted environment verified tree
`e9536bf25171839eb6eb759d306c2efe456c75e6`.

Running the registered copy's complete test suite then exposed a test portability
defect: the intentional metadata-tamper test tried to overwrite a copied
`Project.toml` whose read-only permissions came from Julia's installed package.
The checkout run had writable source files. See [the failed registered run](registered-0.1.0-Pkg.test.log).
Production export intentionally retains source permission bits; validation only
reads the sealed files. The repair belongs in the temporary test copy, followed
by the immutable 0.1.1 patch release and registered-copy rerun recorded in
[registration](REGISTRATION.md). Version 0.1.0's registered tree was not replaced.

The test now forces the temporary Project read-only, then explicitly grants
owner-write only before its intentional corruption. It also derives the original
version from `Base.pkgversion` and asserts the corrupted bytes differ. The same
test [fails before](readonly-fail-before.log) and [passes after](readonly-pass-after.log)
on a checkout. Focused package checks pass **160 assertions**. Version 0.1.1
increments only the canonical Manifest self-version; all 59 non-self records
remain unchanged. Production copying and validation code are unchanged.

The first fresh installation also logged an unavailable registry review-branch
ref while that branch was being published. Installation completed after the ref
was available; [the installation log](fresh-install.log) ends with the explicit
fresh registered-core pass marker. The subsequent restarted test verifies the
resolved immutable tree independently of checkout paths. This transient fetch
message is not presented as a successful registry fetch or a scientific result.

## Open application gates

Core registration and the registered 0.1.1 suite are complete at the scope in
[the receipt](REGISTRATION.md). Scientific owner migration and the small Classic
application have distinct gates in [the migration contract](../../REGISTERED_RTC_MIGRATION.md).
These checks do not qualify scientific numerics, resource timing, FGN parity,
Copper/SPIDERS acquisition, warmup/Quit reliability or physical operation.
