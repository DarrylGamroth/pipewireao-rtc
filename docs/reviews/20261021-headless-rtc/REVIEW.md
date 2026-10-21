# Headless RTC ownership review — 2026-10-21

Disposition: independent source review and focused software verification passed
after the corrections below. No blocking defect remains in the reviewed native
host and deployment changes. The coordinator's actual-array/coexistence gate
also passed; its source and receipt were inspected separately, as described
below. That inspection is not an independent repeat of the integration run.

## Scope and authority

This review applies the user-selected [RTC-ARCH-026 boundary](../../HEADLESS_RTC_DESIGN.md):
the RTC application owns session lifecycle and its explicitly declared links;
WirePlumber owns devices, access and shared routing policy. The review preserves
existing source-first hold, held reset, exact discovery, retirement, deadline,
identity and native protocol guarantees. It does not propose a replacement
protocol or a second authority.

| Repository | Worktree | Baseline revision |
| --- | --- | --- |
| PipeWireAORTC | `/home/dgamroth/workspaces/codex/worktrees/rtc-wireplumber-reuse-20261021` | `c1b7895b4032624a1024aafb1e858f029fce391b` |
| WirePlumberAO | `/home/dgamroth/workspaces/codex/worktrees/wireplumber-reuse-20261021` | `0f64f9ef9d7f080a2668470f3904aa3d0ebf92af` |

Both worktrees use `codex/wireplumber-reuse`. Existing uncommitted hook,
SessionItem and documentation changes were present before this review and were
preserved. The reviewer made no production edits. The earlier
[WirePlumber reuse review](../20261021-wireplumber-reuse/REVIEW.md) remains the
separate record for the generic hook and SessionItem work.

Reviewed `native/main.c`, the moved native modules and Lua policy, generic
WirePlumber loading/Core behavior, generated configuration, runtime staging,
installation, systemd template, exact process verification and one-shot
publication/discovery paths. The low-latency design review workflow was applied
to control-path ownership and boundedness. No data-path performance claim is
made.

## Ownership and preserved behavior

The executable creates one ordinary application `WpCore` and loads its fixed
`ao-rtc` profile through public libwireplumber APIs. It does not select the
manager socket, advertise daemon authority or load desktop automatic linking.
The generated profile contains the Lua engine, existing generic SessionItem
factories, RTC endpoint/journal modules and the absolute RTC policy entrypoint.
Native endpoint creation and exact Link creation use this same Core. Endpoint
owner PID comes from `getpid()`; connection admission still verifies
`client.id == Core.get_own_bound_id()` along with exact endpoints, serials,
negotiated scientific Format, passive state and cohort path.

The two native RTC modules and the control, owner, acquisition and ingress Lua
helpers are byte-identical to their WP baseline versions. The moved
`ao-connections.lua` has the same hash as the final previously reviewed
SessionItem implementation. Lifecycle policy changes only add the successful
Quit publication-fence marker. The marker is set after source/consumer stop,
Link withdrawal, owner shutdown acknowledgement and successful Core sync;
publication failure or deadline expiry does not mark success. Connection loss
without that marker exits unsuccessfully. Signal termination leaves existing
systemd emergency cleanup responsible for the process cohort.

Single-operation admission, epoch/session fencing, bounded effect timers,
source-first hold, downstream-before-upstream start, held reset and explicit
fault compensation remain in RTC-owned Lua. The generic `WpSiLink` withdrawal
implementation remains responsible for child activation retirement and proxy
destruction. RTC then synchronizes the Core and checks correlated absence.
These control operations do not add an RTC frame scheduler.

Staging now distinguishes generic WP dependency assets from RTC executable,
modules and scripts. The WP build/install source no longer contains AO modules,
policy or their tests. Generated session paths and module/data search paths are
sealed by the launcher; registered application declarations cannot override
the protected invocation bindings. Publication and retained-ledger inspection
verify the exact executable and command line in addition to existing
PID/start-time/cgroup/incarnation evidence. Operational modules are renamed to
`Session*`; the native wire protocol and frozen `wireplumber_pid` /
`wireplumber_start_ticks` report fields remain. The explicitly authorized
authority label becomes `rtc_session`.

This is a trusted local deployment boundary, not an operating-system sandbox
against code running as the same user. The selected library must include the
reviewed WirePlumberAO SessionItem extensions; an upstream version number alone
does not prove their availability.

## Findings and dispositions

### HRTC-001 — Configuration could replace the fixed application identity

- **Class / severity / confidence:** confirmed startup defect, P1, high.
- **Observed evidence:** `lib/wp/core.c` loads `context.properties` over the
  constructor properties. The first host implementation supplied its profile
  and application identity only to the constructor. A configuration could
  replace the profile, assert daemon authority or pre-set the successful-Quit
  marker.
- **Impact:** the process could load another profile or misclassify a lost
  connection as an acknowledged Quit, contrary to its declared application
  boundary.
- **Correction:** `native/main.c` reasserts the fixed profile, application
  name/ID, `wireplumber.daemon=false` and `quit-complete=false` after the
  constructor merge and before connection/component activation. WpConf opens
  with `no-fragments`, preventing adjacent configuration fragments from
  replacing the generated invocation.
- **Validation:** the host test injects conflicting values and an unreachable
  remote in a fragment, then verifies the server-observed application
  properties. Removing the invariant correction in a temporary mutant made
  `/rtc-host/termination` fail its readiness assertion after five seconds;
  restoring it passes. The reviewer inspected the retained
  [failure excerpt](../../validation/headless-rtc-20261021/host-invariants-fail-before.txt)
  and independently reran
  the passing tests. The mutant was not retained in production source.
- **Disposition:** closed.

### HRTC-002 — Ordinary-application Lua lookup admitted a working-directory shadow

- **Class / severity / confidence:** confirmed relocation defect, P1, high.
- **Observed evidence:** WP's `module-lua-scripting/module.c:find_script` checks
  an existing relative path in the current working directory before configured
  data directories when `wireplumber.daemon` is false. The former generated
  relative `ao/session.lua` component therefore changed resolution semantics
  when moved from the daemon to an ordinary application.
- **Impact:** a working-directory script could replace the intended sealed RTC
  lifecycle despite correct module/data search paths.
- **Correction:** `SessionLaunch` binds `SESSION_SCRIPT` to the absolute RTC
  asset in the sealed package or registered installation. The configuration
  generator requires an absolute, NUL-free binding and emits it as the Lua
  component name.
- **Validation:** configuration tests reject relative/NUL bindings and check
  the absolute component path. The native host test runs from a directory with
  a conflicting script and proves the absolute trusted entrypoint loads. This
  is a source-demonstrated pre-fix defect plus a discriminating post-fix test;
  a separate pre-fix shadow-script executable was not run.
- **Disposition:** closed.

### HRTC-003 — The renamed runtime ledger path referenced an undefined module alias

- **Class / severity / confidence:** confirmed implementation defect, P1, high.
- **Observed evidence:** the added `_ledger` process check called
  `D.verify_session_process`, while `SessionRuntime` imported
  `DeploymentConfiguration` without defining `D`.
- **Impact:** an otherwise valid ledger would throw `UndefVarError` instead of
  completing identity verification.
- **Correction:** use the existing qualified `DeploymentConfiguration` name.
- **Validation:** the regression invokes `_ledger` with consistent retained
  identity and an invalid executable, requiring the intended `DeploymentError`
  rather than an undefined-name error. Independently rerun successfully. The
  original failure was established by source inspection, not a retained
  fail-before execution.
- **Disposition:** closed.

The initial unbounded pending-main-context drain was also replaced with at most
32 nonblocking iterations. Activation completion independently retains host
state, so remaining callbacks cannot refer to a freed stack owner. This closes
a source-level missing-bound concern; no hang was observed or claimed.

## Independent verification

From the RTC worktree:

```sh
meson test -C native/build --no-rebuild --print-errorlogs
```

Result: **7 passed, 0 failed/skipped/timed out**. This includes the moved Lua
connection, owner, acquisition, journal and hook tests; seven native journal
cases; and four actual-host cases for missing configuration, native public
session Status, termination and Core loss. The Status case was added and
independently rerun in the final focused check below. Host tests create their
own CPU-only server. They check fixed
identity, ordinary-client mode, configuration-fragment isolation and absolute
entrypoint resolution. They do not run the complete science session.

From the WP worktree:

```sh
PIPEWIREAO_CONFIG_DIR=/usr/share/pipewire meson test -C build --no-rebuild \
  test-si-node test-si-standard-link test-si-audio-adapter \
  test-session-item test-lua-event-hooks --print-errorlogs
```

Result: **5 passed, 0 failed/skipped/timed out**. The standard-link executable
contains 13 passing cases, including exact mode, reconfiguration and queued,
unbound, created, bound, reset, deactivate, cancellation and child-error races.

Independent Julia 1.13 command:

```sh
julia +1.13 --startup-file=no --project=. -e '
using Test
for file in ("test_session_configuration.jl", "test_registered_application.jl",
             "test_native_session_discovery.jl", "test_native_session_client.jl")
    Base.include(Module(gensym(:Review)), joinpath("test", file))
end'
```

Result: **162 assertions passed**. `git diff --check` passed. The implementation
worker separately reports 525 focused deployment/package assertions; this
reviewer inspected the relevant new regressions but does not present that
larger selection as an independent rerun.

### Final real public-endpoint check

Inspected the added `native/tests/public-session.conf.in`,
`native/tests/scripts/session-status-client.lua` and the fourth host test. It
starts the actual RTC executable with the unmodified production
`ao/session.lua` and both moved native endpoint modules. Declared scientific
owners are absent, so the production policy remains Configuring. No scientific
owner is replaced by a mock.

A second actual application process uses the production `ao-owner` and
`ao-control` native client helpers. It verifies the public endpoint has zero
data ports, the unchanged native protocol/profile, endpoint incarnation 101
and the spawned RTC process's PID. It reads published Props, sends native
Status opcode 2, and verifies a successful correlated response containing
Configuring, Observed and no admitted execution groups. The production helper
checks endpoint/controller identity, serial, incarnation, token and opcode.
The client and server exit waits each have a five-second bound. After the
client succeeds, the test terminates the server with SIGTERM; it does not
exercise an acknowledged production Quit.

Independent final command:

```sh
meson test -C native/build --no-rebuild rtc-host --print-errorlogs
```

Result: **1 suite passed, all 4 internal cases passed, no skips or failures**.
This closes real native endpoint publication/Status coverage for the moved
process. Start/Stop/Reset and complete scientific admission retain their
separately stated hook/source evidence and deployment qualification limits.

### Coordinator integration evidence inspected after the independent checks

Inspected `test/integration/session_items.jl`, its
`test/data/session_items/validation.lua` policy driver, the private-core child
cleanup helper and the coordinator's
[CPU coexistence receipt](../../validation/headless-rtc-20261021/cpu-coexistence-receipt.json).
The run passed **19 assertions**. Its outer testset must complete successfully
before the receipt can report `passed`; bounded child cleanup also must return.

The test starts the actual installed `pipewireao-rtc` executable on a fresh
private CPU core and invokes production `ao-connections` through a small
validation script. It verifies exact source/sink node and port identities and
binds the Link's Client to inspect its server-observed process metadata. The
receipt records RTC PID `3721692`, application name `PipeWireAO RTC` and
`wireplumber.daemon=false`. The Link is owned by that RTC client, while the
source and sink belong to the Julia harness. Three received Float32 arrays
match `[1, -1]`, `[2, -2]` and `[3, -3]`.

The driver reports withdrawal only from the successful production retirement
callback. The harness then independently observes correlated Link absence on
its own registry. An unrelated node remains present with its expected ID.
An independent WirePlumber process, PID `3721691`, remains alive and represented
by a server Client with `wireplumber.daemon=true`. That peer deliberately loads
no device monitors or automatic routing: the evidence establishes coexistence
with an independent daemon, not compatibility with every desktop/device policy.
The receipt records both children exited, the client resources and thread loop
closed, the owned private-core helper returned, and no cleanup errors.

This integration profile does **not** load the production `ao/session.lua`
lifecycle or native session endpoints. It proves relocated executable/Link
ownership, array transfer, exact retirement and scoped coexistence. It does not
establish end-to-end native Start/Stop/Reset/Quit or endpoint publication for a
complete instrument. The independent public-endpoint check above separately
establishes real publication and native Status while Configuring. Native policy/
hook tests, discovery tests and source review provide further separate evidence;
they are not promoted to full deployed-session qualification.

Also inspected the coordinator's full
[Julia result log](../../validation/headless-rtc-20261021/julia-tests.log):
**2,330 of 2,330 assertions across 75 testsets**, with no `Test Failed` or
`ERROR:` markers. One `git cat-file` missing-object diagnostic belongs to a
negative case. This was a log inspection, not a second full-suite run. The
coordinator additionally reports seven passing controlled production-policy
fault cases; those do not exercise an installed systemd session.

Final architecture/operations inspection confirms `RTC-ARCH-026` explicitly
supersedes the former ownership allocation while preserving the existing
requirement identities and lifecycle/cleanup obligations. AGENTS, the task
index and the roadmap's current-work section point to the headless authority;
later dated roadmap sections are expressly historical. Current documentation
keeps device/access/shared-routing authority in WirePlumber and one-shot
process supervision in systemd. Reviewed production source hashes below remain
unchanged after the integration run.

No workstation service, systemd session or GPU was started by this reviewer.
Hardware, GPU, sustained cadence, allocation, latency, complete instrument
endpoint/lifecycle behavior and process-loss/systemd qualification remain
outside these results. No additional source-review blocker was found.

## Reviewed source identities

| RTC file | SHA-256 |
| --- | --- |
| `native/main.c` | `337cd3bd2957e9d998a0c740c32ed2ebfd971fa8f15b501fd26b879c777ac1b9` |
| `native/scripts/ao/session.lua` | `0e3ba1aae2991ed8982b6e849a2718bacb14a2dcad3268c2d7812b494e35f914` |
| `native/scripts/lib/ao-connections.lua` | `664c7e33b61439cd2164cfece04045f78871e2bdb397716f081677bf43f99abf` |
| `src/configuration/session_configuration.jl` | `8cd1f913f931f3958d6b9c473efda41a02e8b0b7a5d68cb9150c41e1b7d364a9` |
| `src/deployment/session_launch.jl` | `affa4311f0a6e34c0250ad2d03ee6b441bebf3eede5454cfcc6905d9edb4fe88` |
| `src/deployment/session_runtime.jl` | `69f238ff42d408dfbce090d17b50698cc117fbf9d621201321ae9204a7b844a3` |
| `native/tests/host.c` | `590da2d638b2fa38280d87524e81f8f67e5799d83a41d3f5623d5db900d4faab` |
| `native/tests/public-session.conf.in` | `a50faefaee4dd112679f2588f1c19520aba6784a0fe1379d97f37b49fbbff046` |
| `native/tests/scripts/session-status-client.lua` | `ba42c266b1a7a9b99e6e16df47880a80f0faf3a6589e1cfe5057abb934da7f9f` |
