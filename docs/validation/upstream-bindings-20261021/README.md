# RTC-owned Lua/POD bindings — 2026-10-21

The RTC now supplies the missing bindings through its `ao-lua` native plugin
and local Lua module. Upstream `GLib.get_monotonic_time` replaces the redundant
Core extension directly. Discovery, POD inspection/copying and event construction
use public C/SPA interfaces. There are no private wplua imports, global Lua
constructor overrides, new command protocols or alternate lifecycle owners.

The separate WirePlumber removal commit restores its Lua/POD API and matching
documentation. Existing device-policy scripts and genuine fixes remain separate.
[Library source/ABI evidence](library.json), [restoration identities](restoration.json)
and the [library report](library-report.md) identify the exact boundaries.

## Two independently identified library cohorts

| Cohort | Source | Scope |
| --- | --- | --- |
| Clean upstream | WirePlumber 0.5.18, `81606cbb`, with only two Meson dependency-name changes | Unmodified library/runtime source, built against PipeWireAO. |
| Three fixes | The same upstream source plus component dependency strings, dynamic POD filtering and Lua event properties | Genuine fixes only; no custom API or routing-policy extensions. |

The clean build's complete patch is [build selection](upstream-build-selection.patch).
The optional cohort's [complete patch](upstream-threefixes.patch) is distinct.
Both expose identical C symbols and upstream-identical POD headers. Neither
exports the removed property flags/ID, Link Format or SI withdrawal extensions.
Both link to `libpipewire-ao-0.3`; ordinary PipeWire is not the NDArray/AO ABI.
Candidate libwireplumber must precede the reused PipeWireAO SDK directory in
`LD_LIBRARY_PATH`, because that SDK also contains an older library.

## Results

| Check | Clean upstream | Three fixes | Evidence |
| --- | --- | --- | --- |
| Generic WirePlumber suite | 55 pass | 55 pass | [stock](generic-stock.log), [fixed](generic-threefixes.log) |
| Native RTC suite | 10 pass | 10 pass | [stock](native-stock.json), [fixed](native-threefixes.json) |
| Real CPU arrays / independent daemon | 19 checks pass | 19 checks pass | [stock receipt](array-stock/receipt.json), [fixed receipt](array-threefixes/receipt.json) |
| Generated JSON configuration | Refused quoted dependency names, exit 78 | Real Julia native Status returns Configuring | [stock](generated-stock/rtc.log), [fixed receipt](generated-threefixes/receipt.json) |

The full Julia 1.13.2 suite passes 2,329 assertions in 75 testsets
([log](julia.log)); production Lua fault ordering passes seven cases
([log](policy.log)). The three added Julia assertions check that generated
configuration requires/stages the RTC-owned module. This does not turn the
unit suite into live workstation qualification.

The ten native suites preserve the earlier eight suites and add Lua and native
binding checks. Native binding tests cover seven cases, including exact BOUND |
INFO discovery without parameter/port activation, high/duplicate property IDs,
full flags, owned children after parent/iterator release, malformed child extents,
fixed choices/trailing alternatives, opaque unused nested values and event
properties/source/subject lifetime. Lua tests cover Int64 endpoints and values
beyond 2⁵³, exact types, signed zero, and catchable rejection of invalid inputs.
The existing fourteen native Link cases and native-hook fault/deadline cases
remain. [Independent review](../../reviews/20261021-upstream-bindings/REVIEW.md)
records the mapped guarantees and two corrected binding defects.

The final CPU-array runs exchange three arrays, verify exact endpoint IDs and
RTC link ownership, withdraw owned links, preserve an unrelated node and clean
up only owned children while coexisting with a minimal WirePlumber daemon.
They load the final installed RTC module in each library cohort.

## Genuine upstream fixes remain separate

Exact regression probes demonstrate failure on clean upstream and success with
only the following independent patches:

- [Quoted component dependency strings](wp-component-loader-strings-fix.patch).
- [Large POD-filter output](wp-dynamic-pod-filter-fix.patch).
- [Lua event properties](wp-event-properties-fix.patch).

The generated configuration probe uses the production Julia generator, without
rewriting its JSON or replacing the component loader. Thus **generated deployment
still requires the component-loader fix on upstream 0.5.18**. Clean native test
configurations use supported bare SPA-JSON tokens; their success does not remove
this deployment limitation. The RTC's native event constructor avoids the Lua
constructor defect while keeping upstream dispatch/hooks. It does not repair
the generic Lua binding or claim the genuine fixes are unnecessary everywhere.

The [probe source](generated-configuration-probe.jl) is retained as dated
workstation evidence, not a supported deployment tool. Its first fixed-library
attempt failed the client's private-directory check because the owned temporary
runtime directory was mode 0755. The corrected probe sets it to 0700 and receives
Configuring. [Initial failure](generated-initial-harness-failure.log) is retained.
Closing the probe/controller also logs a publication-failure Fault; this is one
Configuring Status exchange with scientific owners absent, **not** full
Start/Stop/Reset/Quit or graceful lifecycle qualification.

## Review corrections and reproduction

The review independently reproduced an iterator backing-array lifetime defect
(exit 139 with the transfer-full handoff omitted) and a boxed-NULL error path
(exit 133 instead of a Lua error). Final-source tests pass with the same inputs.
The [iterator probe](iterator-investigation.c), [NULL probe](null-investigation.lua)
and [review](../../reviews/20261021-upstream-bindings/REVIEW.md) retain the evidence.
Boolean payload checks and owned iterator storage resolve these within RTC;
no upstream marshaller patch is introduced.

The native build used `/tmp/rtc-lua-bindings-build`, `--libdir=lib`, the stock
upstream source for test-only harness inclusion and these isolated prefixes:

```text
~/.local/opt/pipewireao-wp-upstream-stock-20261021
~/.local/opt/pipewireao-wp-upstream-threefixes-20261021
~/.local/opt/pipewireao-rtc-upstream-bindings-20261021
```

Use the [native build guide](../../../native/README.md) and
[integration procedures](../../../test/integration/README.md). The full Julia
command is `julia +1.13 --startup-file=no --project=. test/runtests.jl`.
[receipt.json](receipt.json) binds source/binary hashes and selected results.
Structured Meson evidence omits inherited environments; verbatim patch files
retain unified-diff context spaces and are excluded from whitespace checks.
The Julia log retains an expected missing-Git-object rejection diagnostic.

The tested changes are fast-forward integrated into the normal RTC `main` and
WirePlumberAO `master` checkouts. [integration.json](integration.json) records
the commits and removal of the three temporary worktrees/builds; unrelated
historical worktrees remain intact.

No live workstation deployment, simulator or GPU workload was started. The
known simulator service remained inactive with MainPID zero. These results
are CPU software verification, not hardware, all-instrument, allocation,
sustained-cadence or latency qualification. Artifact-management work stays paused.
