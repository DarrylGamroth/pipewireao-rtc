# Independent Classic SPA readiness and Position review

Date: 2026-09-30. Scope: source/lifecycle review and inspection of retained
verification evidence. The reviewer did not run builds or live transport tests.
No blocking defect remains in the targeted changes below. Production integration
and timing qualification remain the primary agent's responsibility.

## Reviewed revisions and boundaries

- Core wrapper worktree:
  `/home/dgamroth/workspaces/codex/pipewire/pipewireao-spa-plugins-core-classic-readiness`,
  baseline `a498b10427dd56220aa01b006012d23ab8438133`.
  That baseline snapshots pre-existing unrelated changes; only the subsequent
  `factory.rs` and `test-frame-assembly.c` changes were reviewed here.
- FITS worktree:
  `/home/dgamroth/workspaces/codex/pipewire/pipewireao-spa-plugin-fits-classic-graph-io`,
  branch `codex/classic-fits-graph-io`, baseline `db4b891`.
  Scope is `source.c` and `test-source.c` Position support.
- PipeWire source inspected read-only at `a4de38e0d7257d98e5c03c51f248f84e6a822c26`.
  No core activation-version bypass is proposed or approved by this review.

Reviewed file SHA-256 values:

| File | SHA-256 |
| --- | --- |
| wrapper `crates/pipewireao-spa-node/src/factory.rs` | `f98af51fe2aa32a4d6d4013594143711c0965ba8ce8a8da9b5961eb672387dab` |
| wrapper `spa/plugins/ndarray/test-frame-assembly.c` | `34a4ab24a18e0dbe080f318349a055ce21d5f734195ae757217d88bb5e8b4c45` |
| FITS `spa/plugins/fits/source.c` | `e1ba27487a8174ac4d306da482937efd5c3beeaa064097e3bddaea0a92ef8df6` |
| FITS `spa/plugins/fits/test-source.c` | `88f652609de19f67dc9403e74b159679a30b4edfac8caafab81ceaeab5e8d89b` |

## Findings and disposition

### SR-01 — missing readiness notification after failed format change

**P2, high confidence, confirmed from source; resolved in reviewed change.**
The wrapper clears a port's buffer pool before its `format_changed` callback.
On callback failure it restores the format, but preserves the existing pool
withdrawal behavior. Once NEED_CONFIGURE depends on complete port readiness,
returning the callback error without a new FLAGS event leaves listeners with an
obsolete ready indication. Actual Start then fails because buffers are absent.
This is a generic wrapper failure path; reachability through a particular current
plugin was not necessary to establish the API inconsistency.

The repair snapshots changed node info after rollback, drops the state claim,
emits the FLAGS event, then returns the original error. It does not invent a
buffer rollback. The regression checks restored format, zero remaining buffers,
Start readiness failure and published NEED_CONFIGURE. Retained
`evidence/sr01-fail-before.txt` demonstrates failure before notification repair;
`evidence/rust-tests-position.txt` includes its passing result afterward.

### SR-02 — rejected Position prevents local driver acknowledgement

**P2, high confidence, source-confirmed interoperability obstruction; resolved
for the tested graph by the reviewed plugin changes.**
In `pw_impl_node_set_io`, a local activation has `client_version=2` and updates
`active_driver_id` only after a successful synchronous I/O call. FITS and the
clock-unaware video-view wrapper rejected both Position and Clock, leaving this
field at its initial value. `node_ready` resets dependency state, then skips the
activation status transition and pending accounting when active and current
driver IDs differ. This can prevent source/view process callbacks despite links
being active.

The SPA API permits `-ENOENT` for unknown I/O; upstream test `fakesrc` returns
`-ENOTSUP`. Therefore this finding does not establish a universal SPA requirement
that every node consume Position. The targeted implementation now acknowledges
valid Position setup/clear and advertises the same capability. Clock remains
unsupported. FITS and non-consuming generic nodes do not retain or dereference
the pointer. Nodes with NEEDS_POSITION still receive the callback, including
clear, and their error is propagated. Size checking occurs first. The wrapper's
four-entry parameter storage remains sufficient (two property entries, I/O,
process latency).

Retained tests demonstrate positive acknowledgement failing with old code,
passing with new code, short-size rejection, clear, unknown Clock rejection and
consumer callback/error propagation. The same seven-frame source graph and
unchanged installed PipeWire core produced zero packets before the combined
plugin changes and224 exact header/pixel datagrams afterward. This establishes
that the reviewed changes together repair the observed transport obstruction;
it does not isolate each plugin's contribution in a full factorial experiment.

### SR-03 — configuration cycle / reentrant notification concern

**Investigated hypothesis; no new defect found in the reviewed change.**
NEED_CONFIGURE now follows the same required/configured-port readiness predicate
as Start. PipeWire link preparation still negotiates formats, allocates buffers
and installs SPA_IO_Buffers before scheduler Start. The scheduler's Start guard
does not prevent those operations. No normal negotiation cycle follows from the
source path inspected.

Changed-node notifications own their parameter snapshots and occur after dropping
the mutable state claim. The C regression exercises buffers-first/IO-last and
IO-first/buffers-last orders. A callback triggered by final buffer assignment
reenters Start and succeeds. Buffer/IO withdrawal republishes NEED_CONFIGURE.
No additional lifetime or reentrancy defect was found in this bounded review.
Plugin-specific `Node::ready()` conditions can still reject Start independently;
that behavior predates these changes.

## Evidence inspected

Wrapper evidence is under the wrapper worktree's `evidence/` directory:
`fail-before.txt`, `sr01-fail-before.txt`, `position-fail-before.txt`,
`pass-after-reviewed.txt`, and `rust-tests-position.txt`. The latter records
12 ndarray tests and20 wrapper tests passing, including all three new Rust
regressions. The compiler's unused `size` warning in installed SPA compare.h
is unrelated to the changes.

FITS evidence is under its candidate worktree's `evidence/` directory:
`fail-before.txt` shows the positive Position assertion failing with the old DSO.
The C pass-after logs are empty because successful tests are silent. An empty log
alone does not establish exit status; the implementing worker was asked to retain
explicit commands and successful exit codes from those completed executions.

The reviewer inspected `report.json` and `udp-summary.json` in:

- `/home/dgamroth/.cache/rtc-classic-spa-position-before-seven-20260930`
- `/home/dgamroth/.cache/rtc-classic-spa-position-seven-20260930`

Both use the same source cube SHA-256, identical generated config SHA-256
`bfb55a2e39922ed4f91f9c0aa69cae6a25f42bc03305914d704b942ffd2c77e3`,
and `/opt/pipewireao/bin/pipewire-ao`. Before:0 packets, source timeout.
After:224 packets, frame IDs0–6,7 source frames sent,0 rejected frames,0 send errors,
normal process exit0. Candidate plugin hashes and the unchanged HEART sink hash
are retained in the report. Private plugin paths distinguish candidates from
installed artifacts.

This is a finite source-transport and interface/lifecycle result. It does not
qualify source mean rate, jitter, deadline performance, RTC numerical behavior,
indefinite operation or physical application accuracy. No live experiment was
run concurrently by the reviewer.
