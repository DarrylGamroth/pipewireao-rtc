# Existing SessionItem link ownership — 2026-10-21

The [independent review](../../reviews/20261021-wireplumber-reuse/REVIEW.md)
accepted the implementation with no remaining blocking finding. This increment
extends existing WirePlumber interfaces and removes AO's duplicate child-Link
mechanism. It follows the earlier [hook-only increment](README.md); that earlier
GPU session receipt does not qualify this later link-owner implementation.

## Allocation

| Owner | Responsibility |
| --- | --- |
| Existing `si-node` | Wrap a captured Node; select a resolved global port ID in its declared direction through the existing port-context interface. |
| Existing `si-standard-link` | Require an explicit singleton pair when requested; create the native Link through its common creator; retain its associated proxy; cancel and drain activation and destroy the proxy during withdrawal. |
| Existing `WpSiLink` | Provide conventional `wp_si_link_withdraw` / `_finish`, exposed as `item:withdraw(callback)` in Lua. Unsupported implementations report unsupported. |
| AO policy | Resolve declarations to exact incarnations, check ownership and scientific Format, order declared links downstream-first, bound operations and verify Core synchronization plus correlated registry absence. |
| RTC tooling | Require, package and validate the existing `si.node` and `si.standard-link` components. It does not enable desktop audio selection policy. |

`ao-connections.lua` contains no raw `Link(...)` creation, child proxy
deactivation/destruction or child-activation counter. Retained Link references
are for observation and admission evidence. A pending node-wrapper callback is
fenced before it can create a Link after withdrawal.

Exact mode currently supports non-adapter linkables without acquisition hooks
and rejects `object.linger=true` before creation. The usual automatic audio
pairing is still the default. This avoids claiming retirement guarantees for
adapter callbacks or remote lingering objects that the bounded extension does
not implement. No instrument-specific SessionItem factory, parallel link
protocol or scientific scheduler was added.

Identity, finite operation deadlines and cleanup are session correctness rules:
they prevent wrong-instance connections, indefinitely pending requests and stale
links. They are not a new hard real-time deadline or physical-device safety
claim. Scientific shape, element type, schema, layout and cadence checks remain
AO policy. Unknown retirement remains a fault and cannot authorize another
realization. Ordinary desktop sessions do not acquire AO admission policy.

## Source and build

Work remains on the two isolated `codex/wireplumber-reuse` worktrees recorded
in the [earlier receipt](README.md). The earlier hook refactor was already an
uncommitted part of this feature branch when the SessionItem work began. Neither
canonical checkout was reset or modified. The candidate was installed only at
`/home/dgamroth/.local/opt/pipewireao-wp-reuse-20261021`.

[Evidence manifest](session-items/evidence.json) records source, test, candidate
binary/library and receipt SHA-256 values. The independently reviewed native
module hash is
`1756bb90fe9d33d155ad512a12aa413cf49de9cf9368f861aa1f95ad13f444b6`;
the AO connection policy hash is
`664c7e33b61439cd2164cfece04045f78871e2bdb397716f081677bf43f99abf`.
Build uses the preceding bundled-Lua/Meson environment and four build jobs;
no Rust build or GPU runtime is involved.

## Verification

- [Native results](session-items/native-summary.json): **10/10 tests pass**,
  zero skips/timeouts. This includes `si-node`, `si-standard-link`, the existing
  audio adapter, event hooks, AO connection/owner/acquisition/session hooks and
  both journal layers. The selector/link binaries exercise **15 internal cases**,
  including default audio linking, exact NDArray endpoints in opposing declaration
  orders, explicit control ports, malformed/missing/foreign/wrong-direction IDs,
  singleton refusal, property forwarding, lingering refusal, child activation
  failure and cancellation/reset/deactivation during queued or pending creation.
- Review finding WPR-007 exposed an exact-item reconfiguration assertion while
  deferred retirement still owned the generation. The same new regression
  [fails before the preflight fix](session-items/reconfigure-fail-before.log)
  and [passes afterward](session-items/reconfigure-pass-after.log). Reconfiguration
  is rejected without replacing an active or unactivated generation; explicit
  reset followed by settled retirement permits a new configuration. Withdrawal
  permanently retires the item. Destruction inside `pw-proxy-created` is deferred
  until the native binding stack unwinds and has its own regression coverage.
- [RTC tests](session-items/rtc-tests.log): **75/75 assertions pass** for generated
  module dependencies, staging/validation, missing-module rejection and preservation
  of prior staged assets. Run with Julia 1.13.2:
  `julia +1.13 --startup-file=no --project=. -e
  'include("test/test_wireplumber_configuration.jl");
  include("test/test_installed_wireplumber.jl")'`.
- [CPU integration result](session-items/cpu-integration.log): **13/13 checks pass**.
  The retained [receipt](session-items/cpu-receipt.json) shows real Float32 arrays
  `[1,-1]`, `[2,-2]`, `[3,-3]` delivered through an actual private PipeWire core
  using production `ao-connections` and the installed SessionItems. The declared
  wire element type is `F32_LE`, shape `[2]`, row-major layout, rate `100/1` and
  schema `org.pipewireao.test.session-items/1`. Node/client and link port identities
  are checked, then native withdrawal plus Core sync/registry absence completes.
  The owned WirePlumber child, source/sink client and private daemon all clean up.

The maintained CPU fixture is `test/integration/session_items.jl`, with its Lua
driver under `test/data/session_items/`. Its two arguments are an installed
candidate prefix and a fresh evidence directory; see the
[integration procedure](../../../test/integration/README.md). It binds Client
information to read process identity rather than assuming registry announcements
contain that field. The outermost testset completes before its JSON receipt can
report success. Earlier harness attempts used an incorrect Julia Process PID
accessor, the Julia type spelling instead of the wire element type, and a
registry-only Client PID query; these were corrected before accepting the
13-check result. Earlier incomplete receipts are not acceptance evidence.

Raw Meson logs contain inherited environment details. Only whitelisted results
and case names are retained in the native summary, rather than copying that
environment into the repository. Both repository diffs pass whitespace checks.

## Limits and workstation state

This establishes the selected native mechanisms and a CPU NDArray link/data
path. It does not establish a complete RTC application lifecycle for every
instrument, sustained rate, latency, row-block scheduling, physical actuation,
generic audio-adapter withdrawal or lingering-object cleanup.

No GPU simulation was started for this increment. The previously stopped live
Classic RTC remains stopped; its GUI was not restarted or redeployed. The
candidate prefix does not replace the live prefix. Artifact-management work,
scientific algorithms and instrument terminology were not changed here.
