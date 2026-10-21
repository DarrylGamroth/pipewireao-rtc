# WirePlumber reuse — 2026-10-21

The later [SessionItem implementation and CPU checks](SESSION_ITEMS.md) extend
the existing interfaces and remove AO raw-Link ownership. The record below is
the preceding **hook-only increment**. Its source hashes and GPU receipts keep
that earlier scope; they do not qualify the later link-owner implementation.

The [independent audit and verification](../../reviews/20261021-wireplumber-reuse/REVIEW.md)
cover the replacement of generic AO callback sequencing with WirePlumber's
native `AsyncEventHook`, `EventDispatcher` and `WpTransition`. Prepare, Start,
Stop, source-end Stop, Reset and Quit have named steps. Domain ownership,
deadlines, ticket checks, source-first fault compensation and selective
ObjectManagers remain. No public control protocol or scientific algorithm
changed. The old raw-Link cohort remains for this increment; the audit records
the existing SessionItem interfaces to extend before transferring that ownership.

## Revisions and build

Two initially clean feature worktrees use `codex/wireplumber-reuse`:

| Repository | Baseline | Worktree |
| --- | --- | --- |
| WirePlumberAO | `0f64f9ef9d7f080a2668470f3904aa3d0ebf92af` | `/home/dgamroth/workspaces/codex/worktrees/wireplumber-reuse-20261021` |
| PipeWireAORTC | `c1b7895b4032624a1024aafb1e858f029fce391b` | `/home/dgamroth/workspaces/codex/worktrees/rtc-wireplumber-reuse-20261021` |

[Source and evidence hashes](evidence.json) identify the tested working-tree
files. Native build: Meson/Ninja, bundled Lua 5.5.0, GLib 2.84.4, existing
PipeWireAO 1.7.1 dependencies. Build uses `-Ddoc=disabled
-Dintrospection=disabled -Dsystem-lua=false -Ddbus-tests=false`, four jobs, and a
separate candidate prefix. Missing SQLite development headers were extracted
from Debian `libsqlite3-dev_3.46.1-7+deb13u2_amd64.deb` into a temporary local
directory; no system package was changed. The first configuration attempted
system Lua 5.4 but its development headers were unavailable; the maintained
bundled Lua build succeeded. No dependency declaration was changed.

The candidate `/home/dgamroth/.local/opt/pipewireao-wp-reuse-20261021` copies the
existing native dependencies and installs only the newly built WirePlumber.
GUI binaries were excluded. A copied regular library file initially prevented
Meson's versioned symlink installation; removing that candidate-only copy and
rerunning installation succeeded. The live prefix was never an install target.

## Local software checks

- [Native tests](native-tests.log): **7/7 pass**, covering event hooks, AO session
  hooks, connections, owners, acquisition, Lua journaling and C journaling.
  Command: `PIPEWIREAO_CONFIG_DIR=/usr/share/pipewire meson test -C build
  --no-rebuild test-lua-event-hooks test-lua-ao-connections test-lua-ao-owner
  test-lua-ao-acquisition test-lua-ao-session-journal test-lua-ao-session-hooks
  test-ao-journal --print-errorlogs`. The environment override supplies the test
  fixture's daemon configuration directory; it is not a production policy change.
- The native policy harness executes real WirePlumber hooks/transitions and
  controlled scientific/discovery I/O. It checks normal and interrupted phases,
  parked-hook deadlines, synchronous cancellation callbacks, late callbacks,
  cursor checks, thrown errors and ticket retention through compensation.
- The Lua event binding lacked a table lookup for the supplied `properties`
  field. The same new regression [fails without the lookup](binding-fail-before.log)
  and [passes with it](binding-pass-after.log), covering table, `Properties{}`
  and omitted values plus custom-property interest matching.
- Julia 1.13.2 and installed Lua 5.4 pass **7/7** existing production fault-ordering
  cases via `test/integration/session_policy_faults.jl` against the candidate
  policy. Its new hook stubs only permit loading the fault-only fixture; the
  native test supplies hook execution evidence.
- [RTC tests](rtc-tests.log): **118/118 assertions pass** for generated
  WirePlumber configuration and integration-helper source, identity and cleanup
  checks. Command: `julia +1.13 --startup-file=no --project=. -e
  'include("test/test_wireplumber_configuration.jl");
  include("test/integration/test_session_fault_helpers.jl")'`.
- Changed control/deployment Mermaid diagram rendered successfully with the
  locally available Mermaid CLI container. Both repository diffs pass
  `git diff --check`.

## Installed link-loss check

[Receipt](link-fault.json) and [test result](link-fault.log): **41/41 assertions
pass**. The existing `test/integration/session_faults.jl` creates fresh private
cores/services and captures exact identities before removing a Link. It ran
with the candidate prefix and the released Classic application from
`worktrees/wavelength-nm-validation-20261021/managed/installed`: Classic 0.2.4,
AOS 0.2.2, shared HIL 0.2.2, RTC 0.1.11, CPU JFG and CUDA plant, 480-sample pupil.
This reuses that sealed calibration; it does not regenerate the optical model.

The first session (`pipewireao-session@be12ca3fbb28.service`) reached Ready with
14 exact links, then Running. Removal of Link ID 143 / serial 144 produced the
first Fault naming that exact identity. Source Hold was unconfirmed, so the
policy disconnected and systemd completed emergency cleanup. This is the
`policy-shutdown` outcome, not a confirmed held-source result. The receipt
retains the reason and proves process disappearance, empty cgroups and a
quiescent manager. No source command timeout preceded or replaced that Fault.

A new session (`pipewireao-session@c1e8e59eec23.service`) admitted fresh owners,
reached Ready and Running, and cleaned up. The two starts are explicit separate
requests; a fault did not automatically replay acquisition or mutations.

## Scope

The candidate was isolated from the running GUI and Classic RTC. After the
completed fault/readmission test, a separate normal lifecycle probe was started.
At the user's request to free the GPU, its exact unit
`pipewireao-session@bad59733ce64.service` was stopped during startup. That probe
did not complete and supplies no additional lifecycle qualification. Its failure
receipt retains the interrupted startup and confirmed cleanup; it was not retried.

The live unit `pipewireao-session@1581f3130b5c.service` was also stopped through
its configured systemd/native shutdown path at the user's request. It became
inactive, both simulator PIDs exited, and `nvidia-smi` reported no compute
processes. The GUI remained open. No candidate was deployed into the live prefix
and no simulation was restarted after the stop request.

This is selected
local software/integration evidence, not sustained cadence, latency, physical
device safety, row-block or all-instrument qualification. SessionItem link
selection/properties/retirement extensions and transfer of raw-Link ownership
remain the next coherent reuse increment. No new AO-only SessionItem class,
parallel link interface or scientific scheduler was introduced.
