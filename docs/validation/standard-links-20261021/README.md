# Standard libwireplumber Link validation — 2026-10-21

The RTC uses upstream `WpLink` creation/activation and public C abort/disposal
and native-info/PipeWire Link events through a small binding in its existing
control module. Exact discovery, endpoint provenance, negotiated Format,
passive/non-lingering ownership, deadlines, terminal fencing and synchronized
registry-absence proof remain RTC policy. No additional connection-policy owner
or command protocol was introduced.

The Link and SessionItem sources/interfaces/tests restored by this increment
match upstream WirePlumber 0.5.18. Both library and RTC link to
`libpipewire-ao-0.3` and `libspa-ao-0.2`, not ordinary PipeWire. This does **not**
claim an entirely unmodified libwireplumber: generic Lua monotonic time,
ObjectManager feature selection, POD inspection/copy/equality and C POD
property accessors remain. The exact inventory, paths, symbols, restored source
identities and dynamic dependency observations are in [dependency.json](dependency.json).

## Results

| Check | Result | Evidence |
| --- | --- | --- |
| Full Julia 1.13.2 suite | 75 testsets, 2,326 assertions pass | [julia.log](julia.log) |
| Native RTC | 8 suites pass, including 14 direct Link cases and real host/control tests | [native-tests.json](native-tests.json) |
| Generic WirePlumber | 5 suites pass: node, standard link, audio adapter, session item, Lua hooks | [native-tests.json](native-tests.json) |
| Production Lua fault ordering | 7 cases pass | [policy.log](policy.log) |
| Actual CPU-array/coexisting daemon | 19 checks pass | [array.log](array.log), [receipt](array/receipt.json) |
| Independent architecture/source review | No unresolved blocking finding | [review](../../reviews/20261021-standard-links/REVIEW.md) |

The earlier full suite had 2,330 assertions; the four removed assertions required
the now-removed SI components. Replacements assert their absence and continued
Lua/component staging. Original 13 SI test obligations are explicitly mapped
in the review; removed SI-only API tests are identified as inapplicable rather
than counted as identical tests. Queued/unbound/created/bound retirement,
cancellation, error, no resurrection, fresh generation and per-update Format
checks remain covered under their RTC owner. No separate video runtime check is
claimed; generic sources were restored exactly and the existing audio tests pass.

The array test exercises production `ao-connections` with real CPU endpoints,
three arrays, exact port IDs and RTC creator PID, withdrawal, unrelated-node
preservation and a separate minimal WirePlumber daemon. Its first invocation
failed because the expanded fixture did not load the standard client-node
module required to export its control endpoint. Production already loaded it.
That failure is retained in [array-initial-failure](array-initial-failure/receipt.json);
adding the module to the fixture produces the passing result above.

Two temporary mutants provide discriminating fail-before evidence: BOUND-only
deactivation leaves a created proxy alive; deferred Format notifications miss
the two immediate invalid→valid observations. Their assertion summaries are
[retirement](retirement-fail-before.log) and [Format](format-fail-before.log),
with a [passing final-source rerun](links-pass-after.log). The review inspected
both mutant source diffs. No mutant is installed or retained as production code.

## Independent bug fixes

The following pre-existing fixes remain separately reviewable, verbatim patches; this
link-removal change neither conflates them with API extensions nor reverts them.
Patch context lines retain their required leading space, including empty lines;
whitespace checks exclude these three preserved patch files:

- [Component-loader JSON strings](wp-component-loader-strings-fix.patch).
- [Dynamic POD-filter buffer](wp-dynamic-pod-filter-fix.patch).
- [Lua event properties](wp-event-properties-fix.patch), with fresh
  [fail-before assertion summary](event-properties-fail-before.log) and passing
  Lua hook suite in the structured results.

## Reproduction and limits

From the RTC checkout:

```sh
julia +1.13 --startup-file=no --project=. test/runtests.jl
meson test -C native/build --no-rebuild --print-errorlogs
julia +1.13 --startup-file=no --project=test test/integration/session_policy_faults.jl \
  "$PWD/native/scripts/ao/session.lua"
```

The [integration guide](../../../test/integration/README.md) gives the array
command. These runs selected isolated prefixes
`~/.local/opt/pipewireao-wp-standard-links-20261021` and
`~/.local/opt/pipewireao-rtc-standard-links-20261021`, with the existing
`pipewireao-wp-reuse-20261021` prefix providing PipeWireAO. Candidate libwireplumber
must precede that dependency directory in the loader path. The corrected native
suite was rerun after fixing this order. The independent WirePlumber run also
needed its explicit `PIPEWIREAO_CONFIG_DIR`; the initial missing-config harness
failures were corrected without changing source.

[receipt.json](receipt.json) binds source and binary hashes. Structured Meson
results deliberately omit inherited environment values. The Julia log retains
an expected missing-Git-object diagnostic from a rejection test; all assertions
pass.

The tested commits are fast-forward integrated into the normal RTC `main` and
WirePlumberAO `master` checkouts. The two temporary worktrees were removed;
unrelated historical worktrees remain. [integration.json](integration.json)
records the exact commits and cleanup.

No workstation deployment, simulator or GPU was started. The known simulator
service remained inactive with MainPID zero. These are CPU software results,
not hardware, sustained cadence, latency, allocation or all-instrument
qualification. Artifact-management work remains paused.
