# Standard application links review — 2026-10-21

Disposition: independent source review and focused software verification pass.
No blocking source finding remains in the reviewed replacement. This record
establishes the scoped upstream Link/SessionItem interface result below, not
compatibility with an entirely unmodified upstream library. Coordinator
integration evidence and investigative fail-before receipts below are
distinguished from this reviewer's independent reruns.

## Scope and starting evidence

The RTC worktree is `/home/dgamroth/workspaces/codex/worktrees/rtc-standard-links-20261021`,
branch `codex/standard-links`, starting at
`60556ad871748939c297492a57b2721188f19f74`. The WirePlumber worktree is
`/home/dgamroth/workspaces/codex/worktrees/wireplumber-standard-links-20261021`,
starting at `2c55a872`. Both were clean at the start of this review. Parallel
implementation edits subsequently appeared; this reviewer owns only this record.

Reviewed the relevant RTC instructions, task index, RTC-ARCH-026 design, prior
headless/reuse review findings, direct Link implementation, object activation,
proxy disposal, Lua bindings and the 13 original standard-link test cases.
The intended change removes the unnecessary exact-link SessionItem extensions
while preserving exact application topology, negotiated Format validation,
bounded cleanup, callback retirement, no resurrection and unrelated resources.
No workstation session, service, GPU workload or installed prefix is changed.

## Design findings

### STL-001 — Pending activation needs explicit retirement before absence proof

- **Classification / severity / confidence:** confirmed design constraint, P1
  if omitted, high. This is not a demonstrated defect in upstream linking.
- **Observed evidence:** `lib/wp/object.c:wp_object_deactivate` masks requested
  features to the active feature set. `lib/wp/proxy.c:wp_proxy_deactivate`
  destroys its native proxy only for BOUND. A factory-created proxy can exist
  before BOUND is active. Lua `object_activate` supplies no cancellable, while
  public C `wp_object_abort_activation` completes queued/ongoing transitions.
  `wp_proxy_dispose` destroys a native proxy even when it is not yet bound.
  `wp_global_proxy_request_destroy` only acts when a registry global exists.
- **Derived constraint:** Lua deactivation or a registry-absence check alone
  cannot prove that an unbound factory effect is retired. Waiting indefinitely
  for activation also loses the bounded cleanup contract.
- **Remediation:** retain application links in RTC, fence the cohort first,
  then use a small RTC-local bridge to public C abort/dispose on a later main
  context iteration. Delay disposal until a currently executing created/bound
  callback has unwound. Complete cleanup only after activation callbacks have
  settled, native proxies are destroyed, the manager Core synchronizes and
  the existing exact-incarnation/cohort absence check succeeds. Deadline or
  uncertainty remains a failure with the cohort retained.
- **Required validation:** queued, unbound, created, bound and failed activation;
  late callbacks; duplicate completion; cleanup deadline; no later creation;
  correlated absence and unrelated resource preservation.
- **Disposition:** closed. `native/modules/ao-link.c` uses public abort/dispose
  from an idle callback and retains the Link through a `GTask`. Lua retains every
  created proxy, increments pending before activation, fences terminal before
  retirement, registers all expected retirement completions before issuing any
  action, and requires both pending and retirement counts to reach zero before
  synchronization. Native queued/unbound/created/bound/error and dropped-owner
  tests pass. Lua tests preserve deadline/unknown outcomes and late-success
  prevention. No application-specific library extension is needed.

### STL-002 — Standard Link creation is narrower than stock-library compatibility

- **Classification / severity / confidence:** confirmed compatibility-claim
  constraint, P2, high.
- **Observed evidence:** WirePlumber commit `9e339138` added
  `wp_link_get_format`, the Link `format` property/notification and Lua getter;
  `Core.get_monotonic_time`; and the Lua ObjectManager feature-mask argument.
  These predate the exact SessionItem extension removed in this change.
  Public C `wp_pipewire_object_get_native_info` already exposes the public
  `pw_link_info` snapshot. Stock Lua ObjectManager requests all features.
- **Derived constraint:** replacing extended SessionItems with ordinary Link
  construction does not alone prove compatibility with an otherwise upstream
  libwireplumber/Lua binding. Silently removing selective discovery or Format
  notifications would weaken the existing contract.
- **Remediation:** explicitly account for these independent application seams
  in the accepted scope and dependency claims. They can be implemented by RTC
  using public APIs if full stock-library compatibility is required. The
  genuine event-properties constructor correction is a separate upstream bug
  fix, not an application linking interface.
- **Required validation:** identify the exact library build and public API
  surface actually exercised; preserve selective object features, monotonic
  absolute deadlines and Format-change validation.
- **Disposition:** primary adjudication requires upstream Link and SessionItem
  interfaces, built against PipeWireAO. Remove the earlier custom Link Format
  accessor/property/notification as part of this increment. Generic Lua time,
  selective discovery and POD bindings remain and must be explicitly inventoried;
  the result must not be described as unmodified upstream libwireplumber or as
  eliminating every downstream patch. Stock `native-info` has no change
  notification, so Format-only observation requires the public PipeWire Link
  listener at the RTC bridge. Closed by the implemented bridge and source/build
  checks below. The distinction is explicit in RTC-ARCH-026's maintained guide.

### STL-003 — Coalescing Format observations would hide transient contract loss

- **Classification / severity / confidence:** source-derived regression in the
  initial in-progress replacement, P1, high; corrected before acceptance.
- **Observed evidence:** the initial RTC observer scheduled one idle callback
  and read the latest native info there. The old `notify::format` inspected each
  update. An invalid Format followed by a valid Format before the idle would
  therefore erase the invalid observation. No deployed failure is asserted.
- **Correction:** the final public PipeWire listener emits one RTC-local signal
  per Format update, after the standard WpLink listener updates its public
  native-info snapshot. Retirement remains deferred, protecting the native
  callback stack. The getter returns a bounded independent POD copy.
- **Validation:** `/rtc-links/format-observation` dispatches invalid and then
  NDArray Format-only info through the public `pw_proxy_notify` event mechanism,
  verifies both observations arrive before any idle, overwrites the original
  buffer and checks both independent copies, then verifies a missing Format is
  observed. The separate Lua test revokes admission on missing/malformed Format.
  Both pass in the independent rerun.
- **Disposition:** closed with the investigative fail-before evidence below.

## Original test obligations

The removed 13-case executable contained legacy audio pairing, exact named-port
selection and lifetime properties, exact-selection refusal, unsupported
withdrawal, reconfiguration, and eight retirement races: queued, unbound,
created, bound, reset, deactivate, cancelled and child-error. Restoring upstream
tests preserves the legacy pairing case. Application invariants must be tested
at their new RTC owner; removed SessionItem-only interface cases require an
explicit mapping or an explained inapplicability, not silent deletion.

| Former case | Preserved obligation and present evidence |
| --- | --- |
| Legacy `main` | Restored upstream `test-si-standard-link`; audio-adapter, si-node and session-item suites pass too. |
| `exact` | RTC native `exact` and `control-selection`: different multiport declaration orders, exact node/port IDs, passive, non-lingering and path properties; no synthetic audio-channel mapping. |
| `exact-refusal` | Lua rejects invalid/sentinel/fractional exact IDs before Link creation and retains existing endpoint-direction/identity validation. Node-wide selected-context ambiguity, user-supplied property forwarding and linger overrides disappear because RTC constructs a fixed property table. No equivalent removed SessionItem configuration entry point remains. |
| `unsupported-withdrawal` | Removed custom SessionItem method has no caller. RTC retires only its owned WpLinks on the same Core; unrelated objects are not enumerated for destruction. |
| `reconfigure` | Lua refuses realization while an old cohort remains. Native `fresh-generation` proves a new independent Link can be created after retirement; no mutable SessionItem generation is reconfigured. |
| `queued`, `unbound`, `created`, `bound` | Direct native races cover these stages, callback settlement, proxy destruction and registry absence. Created/bound handlers assert retirement does not destroy the proxy within that stack. |
| `reset` | SessionItem reset surface is removed. Existing production session-hook reset/cleanup tests remain; fresh-generation and Lua cohort rejection cover replacing application link ownership. |
| `deactivate` | Native deactivation race explicitly deactivates BOUND before retirement, preserving the pending/unbound protection. |
| `cancelled` | Native cancelled-activation race; retirement has no cancellable result surface. Lua deadline tests prove a caller timeout cannot publish later success or initiate a new absence proof. Native retirement continues independently. |
| `child-error` | Native injected activation-error race; Lua activation/factory-error tests preserve failed ownership and prevent continued linking. |

Additional new cases cover never-activated Links, repeated retirement, loss of
the caller's reference and per-update Format observation. Existing Lua tests
also preserve separate creator/registry proxies, fresh GObject wrappers,
incarnation-sensitive removal, reused IDs, unrelated objects, late first-Link
completion before a second declared Link, remaining correlated resources and
cleanup errors. The pure Lua tests use controlled doubles; the native races use
real WpLinks and private CPU servers. Neither substitutes for the separately
scoped full array-transfer/coexistence integration.

## Independent verification

RTC command, from the recorded worktree:

```sh
meson test -C native/build --no-rebuild --print-errorlogs
```

Result: **8 suites passed, no failures/skips/timeouts**. This includes the new
14-case `ao-links` executable, existing Lua connections/owner/acquisition/
journal/hooks, native journal and real-host tests. The real-host native Status
case remains a Configuring-session check with scientific owners absent; it is
not a complete scientific lifecycle qualification.

The final independent run followed the test-environment correction that puts
the new WirePlumber library directory before the reused PipeWireAO dependency
directory in `LD_LIBRARY_PATH`. The latter also contains an older WirePlumber
library. The earlier passing invocation is not used as final dependency
evidence; the complete eight-suite selector was rerun with the corrected order.

WirePlumber command, from the recorded dependency worktree:

```sh
PIPEWIREAO_CONFIG_DIR=/home/dgamroth/.local/opt/pipewireao-wp-reuse-20261021/share/pipewire-ao \
  meson test -C build --no-rebuild test-si-node test-si-standard-link \
  test-si-audio-adapter test-session-item test-lua-event-hooks --print-errorlogs
```

Result: **5 suites passed, no failures/skips/timeouts**. The first independent
attempt omitted `PIPEWIREAO_CONFIG_DIR`; all five test harnesses failed after
reporting missing `client.conf` and using a null context. Supplying the correct
existing test configuration fixed that invocation with no source change. This
was a test-environment mistake, not fail-before evidence for link behavior.

`git diff --check` passes. Independently compared the restored SI sources/tests
with the pre-extension revision and Link sources with the pre-AO revision.
The dependency worker's receipt additionally identifies all these files as
identical to upstream 0.5.18 and verifies that the installed headers/symbols
contain neither custom withdrawal nor custom Link Format accessors. Audio and
video selection algorithms are unchanged by restoration; audio suites were
run, while no separate video runtime qualification is claimed.

Independently inspected native dynamic dependencies: the RTC control module
resolves `libwireplumber-0.5.so.0` from the isolated standard-links prefix and
`libpipewire-ao-0.3.so.0` from the existing PipeWireAO dependency prefix. No
ordinary PipeWire or GPU runtime appears in its dependency closure. The
dependency receipt records libwireplumber 0.5.18, PipeWireAO 1.7.1 and SPA AO 0.2.
The direct Link code uses public WpLink/WpObject/WpPipewireObject and public
PipeWire proxy/info interfaces, without library-private object layouts.

No workstation service or GPU was started by this reviewer. Software checks do
not establish hardware, GPU, sustained cadence, allocation, latency, complete
instrument lifecycle or process-loss/systemd qualification.

### Investigative fail-before evidence inspected

The implementation worker compiled temporary mutant binaries under `/tmp`,
using the same native test source and corrected dependency environment. This
reviewer inspected both mutant source diffs, failure logs and the passing
focused rerun; the mutants were not independently executed a second time and
were not retained in production source.

- **Pending native retirement:** replacing only abort plus dispose with BOUND
  deactivation fails `/rtc-links/race/created` at the assertion that
  `wp_proxy_get_pw_proxy(...)` is null in the retirement callback. Log:
  `/tmp/rtc-links-deactivate-fail-before.log`; mutant:
  `/tmp/rtc-ao-link-deactivate-mutant.c`. This demonstrates the missing
  unbound-proxy retirement rather than merely failing to build.
- **Per-update Format:** replacing immediate notification with an idle callback
  fails `/rtc-links/format-observation` with `observations.calls == 2`
  evaluating as `0 == 2` before the idle. Log:
  `/tmp/rtc-links-format-fail-before.log`; mutant:
  `/tmp/rtc-endpoint-format-mutant.c`. This establishes the observation-order
  regression using the same real WpLink event path.
- **Pass after:** `/tmp/rtc-links-pass-after.log` records both `ao-connections`
  and `ao-links` passing against final production source. The complete final
  native selector also passed in this reviewer's corrected-environment rerun.

## Additional verification and source identities

### Coordinator integration evidence inspected

Reviewed the final `test/integration/session_items.jl` diff, its production
`ao-connections` driver, `/tmp/rtc-standard-links-array-r2.log` and
`/tmp/rtc-standard-links-array-20261021-r2/receipt.json`. The coordinator's real
CPU integration passed **19/19 assertions**. This was independent inspection
of the run and its test implementation, not a second integration execution.

The installed RTC process PID 3770270 owned the observed exact Link between
source node/port 13/14 and sink node/port 15/16. Its server-observed identity was
`PipeWireAO RTC`, `wireplumber.daemon=false`; the scientific endpoints belonged
to the separate Julia harness. Three received Float32 arrays matched
`[1, −1]`, `[2, −2]` and `[3, −3]`. Production withdrawal reported success and
the harness independently observed Link absence. The unrelated node retained
its original ID, and the separate WirePlumber peer remained alive with daemon
identity. That peer loads no device monitors or automatic routing, so this
does not claim compatibility with every workstation routing policy.

The outer testset must finish successfully before the receipt records `passed`.
Cleanup records both children exited, client resources/thread loop closed,
owned private-core cleanup completed and no cleanup errors. The driver exercises
the production connection policy and native bridge, not the entire production
scientific session state machine. The separate real-host test covers the public
native Status path while Configuring.

The first integration attempt failed before linking because its former minimal
profile lacked `libpipewire-module-client-node`, now required to export the
loaded control endpoint. Its retained log reports `can't export type
PipeWire:Interface:Node` and endpoint initialization failure; cleanup reports no
errors. Adding the standard client-node module to the test profile fixed that
attempt. The production configuration already loaded it. The failed receipt
at `/tmp/rtc-standard-links-array-20261021/receipt.json` is retained separately
and is not presented as a passing run or a production retirement defect.

Also inspected `/tmp/rtc-standard-links-policy.log`: **7/7 controlled production
fault-ordering cases passed**, with the recorded policy SHA-256 matching the
reviewed source. This controlled policy evidence is distinct from complete
installed-session lifecycle/systemd qualification.

Inspected the final `/tmp/rtc-standard-links-julia.log` and independently summed
its results: **2,326/2,326 assertions across 75 testsets**. No failed/error test
summary appears. The retained `git cat-file` missing-object diagnostic belongs
to the existing negative case. The coordinator reports process exit zero.
This is log review, not a second execution of the complete Julia suite.

### Source hashes

| RTC file | SHA-256 |
| --- | --- |
| `native/modules/ao-link.c` | `01e95e5a0610b3f9e5787529dc8a2c70672a045603e57c0b5509087b9fcdb3a0` |
| `native/modules/ao-link.h` | `278737282bbf202328830e931bc74856cdf6c1dfcd2c2628ab857c2c204b428b` |
| `native/modules/module-ao-control-endpoint.c` | `18d3159e2bded9b8002387d8dcbc680bed03cc7b743aa439bf474bd735b9af9b` |
| `native/scripts/lib/ao-connections.lua` | `c79f1cb4b3fd67bb5a668a4dac04477ecd8c31d7476cfbe5ac41a9bfb8beffd6` |
| `native/tests/ao-links.c` | `1f7462f0355fa1663cffffebad6bbd12398248b5122070d98aa428bbca25fe41` |
| `native/tests/scripts/ao-connections.lua` | `053adde4cc49475bd969ad4caf184fc39f8e1a055ab60952dad7f0f7e8cda30e` |
| `native/scripts/ao/session.lua` | `abb2b16c3056a41b4895f02958e3157da9d5f0572479067350c0a1335899fafc` |
| `src/configuration/session_configuration.jl` | `285c133fbb1cc401539401288d19fa2bf1b2d77e877bfbd58bc053d9e7565851` |
| `native/tests/meson.build` | `9e9c139ac408a780cefa4ef922cb270573220b553c86bc3d603607c9342b082a` |
| `test/integration/session_items.jl` | `ac4f9e7e751339b9f8cd6b5e91b31472bbfa29da2a4744ea5faf8c825736cb9d` |
| `test/data/session_items/validation.lua` | `ad6128885b89e73fc9f8bc10c6942b0b639ce7c3facd76450b5ca7d34c702f33` |
