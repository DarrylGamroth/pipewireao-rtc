# Standard SPA-JSON generation — 2026-10-21

Generated RTC configurations now load with clean upstream libwireplumber 0.5.18
built against PipeWireAO. The component-loader string patch is removed; its
source is byte-identical to upstream blob
`6650e5e66da2aa92b8054f21e11eed6da845ce81`.

The existing `write_spa_config` function prints conventional `key = value`
objects and whitespace-separated arrays. Simple strings such as dependency
feature names are bare. JSON3 handles quoted strings and numeric/boolean/null
scalars. Numeric-looking and primitive-looking strings, special characters,
escapes and Unicode remain quoted. This is the documented
[PipeWire SPA-JSON format](https://docs.pipewire.org/page_man_pipewire_conf_5.html),
not a new configuration language. Standard JSON was already valid SPA-JSON;
its dependency spelling exposed an upstream loader defect.

The dependency's `pwao-spa-json-dump` parser normalizes each completed document;
`Common.parse_json` and `isequal` check the result before replacing the target.
The bounded, deadline-controlled parser invocation is cold configuration work,
not frame processing. There is no custom parser or new package dependency.
The formatter alone was investigated and rejected: `pwao-spa-json-dump -s` keeps
quoted string values, including dependency names, so it could not fix this case.

## Verification

| Check | Result | Evidence |
| --- | --- | --- |
| Full Julia 1.13.2 suite | 2,409 assertions / 77 testsets pass | [log](julia.log) |
| Focused serializer checks | 80 assertions pass | [log](focused.log), [tests](../../../test/test_spa_config.jl) |
| Independent direct native-parser checks | 925 assertions pass | [review](../../reviews/20261021-spa-json/REVIEW.md) |
| Generated production configuration | Clean upstream receives native Status Configuring; child exits 0 | [receipt](generated-stock/receipt.json), [configuration](generated-stock/rtc.conf) |
| Independent review | No blocking findings | [review](../../reviews/20261021-spa-json/REVIEW.md) |

Tests preserve Int64/UInt64 boundaries, values beyond 2⁵³, signed zero, nested
containers and string types. They cover delimiters, comment markers, escaping,
Unicode and control characters. Unsupported/nonfinite/out-of-range values,
malformed UTF-8, NUL and native-parser key-limit violations are rejected with
`ArgumentError` while the original file and directory contents remain unchanged.
The existing strict-JSON semantic check continues to reject inexact Float32
serialization; this is not a new change to the accepted data model.

The [prior failing stock receipt](../upstream-bindings-20261021/generated-stock/receipt.json)
and [log](../upstream-bindings-20261021/generated-stock/rtc.log) record exit 78
because the loader looked for a quoted feature name. The new probe uses the
same production generator entrypoint, unchanged native RTC prefix and clean
library prefix; its generated `requires` values are bare. The unchanged
[Julia probe source](../upstream-bindings-20261021/generated-configuration-probe.jl)
asserts a real native Status response while the RTC process is alive. The
review inspected both configurations and receipts. This directly supersedes
the earlier need for a component-loader patch on the generated path.

The test leaves scientific owners absent. Its [log](generated-stock/rtc.log)
retains a control-publication Fault during probe/controller teardown, as in the
preceding increment. Acceptance is one native Configuring Status exchange,
not scientific readiness, full Start/Stop/Reset/Quit or graceful lifecycle
qualification. The existing native/link/CPU-array suites have unchanged
runtime source and library identities; their earlier evidence retains its scope.

## Dependency boundary and reproduction

The qualified library is
`~/.local/opt/pipewireao-wp-upstream-stock-20261021`, built from upstream commit
`81606cbb` with only two build dependency-name selections for
`libpipewire-ao-0.3` and `libspa-ao-0.2`. Its library/runtime source is unmodified.
The RTC prefix is `~/.local/opt/pipewireao-rtc-upstream-bindings-20261021`.
[receipt.json](receipt.json) records source and library identities. No live
workstation prefix was replaced.

The WirePlumberAO checkout still retains two separate genuine fixes for large
POD filtering and Lua event-property construction, plus device-policy scripts.
This task removes only the component-loader fix. Those remaining changes are
not present in the clean library tested here and are not implied requirements
of this generated RTC startup path.

```sh
julia +1.13 --startup-file=no --project=. test/test_spa_config.jl
julia +1.13 --startup-file=no --project=. test/runtests.jl
julia +1.13 --startup-file=no --project=. \
  docs/validation/upstream-bindings-20261021/generated-configuration-probe.jl \
  "$PWD" /absolute/clean-wireplumber-prefix /absolute/rtc-prefix \
  /absolute/fresh-evidence-directory configuring
```

All checks used CPU/private sessions only. The simulator remains inactive with
MainPID zero. No GPU, physical-device, cadence, allocation, latency, live
workstation deployment or artifact-management work was performed.

The tested commits are integrated into the normal RTC `main` and WirePlumberAO
`master` checkouts. [integration.json](integration.json) records their identities
and removal of the two temporary worktrees; unrelated historical worktrees remain.
