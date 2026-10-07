# WirePlumber NDArray compatibility

Date: 2026-10-06. RTC base `c89ff6c`, initially clean; branch
`feat/wireplumber-compatibility-pilot-20261006`, worktree
`/tmp/rtc-wireplumber-pilot-20261006`. WirePlumber `bdc17eb` (0.5.18) was built
against `/opt/pipewireao` without source edits or global installation. See the
[build/fixture instructions](../../../deployment/wireplumber/README.md).

## Observed checks

The final four checks also pass with Python optimization enabled (`python3 -O`);
acceptance checks use explicit exceptions. The graceful gate requires SIGTERM
completion with exit code 0 and has no SIGKILL fallback. Kill-case return code
is −9. Forced cleanup remains available only after a check fails or completes.

| Case | Delivery | Link disposition |
| --- | --- | --- |
| Graceful WirePlumber exit | 32/32 buffers, ordered digest matches | Removed; core remains alive |
| WirePlumber SIGKILL | 32/32 buffers, ordered digest matches | Removed; core remains alive |
| Required source removal | 32/32 buffers, ordered digest matches | Removed; WirePlumber and core remain alive |
| Stale source serial | Zero delivered buffers | No link created by the five-second fixture deadline |

The three delivery cases each check 32 data blocks, 768 payload/digest bytes,
zero protocol errors and FNV-1a `8808077142377848178`. The input data are a
generated unsigned 16-bit FITS cube with shape `[4, 3, 32]`, samples 1–384.
WirePlumber parses native EnumFormat and Meta parameters, including shape,
element type, layout, rate, schema and Header size. Actual negotiated link
format matches the source contract. The graph uses the ordinary generic Link
factory and exact node/port IDs plus serials. The stale case has the same current
object ID with a different requested serial; it creates no fallback link.

[Receipts](receipts.json) bind the selected identities, link, counters, revisions
and file hashes. The small per-case logs preserve Lua observations and native
warnings; trailing whitespace in the retained logs is removed. Full registry snapshots remain in the receipt's temporary run paths;
they are not needed for routine context loading.

## Counter observation correction

An initial run had an active NDArray link but repeatedly observed zero discard
counters. The native node implementation caches parameters by default
(`src/pipewire/impl-node.c`, `pw_impl_node_for_each_param`). The Lua object manager
activates all supported features, including parameter reads; subsequent reads
can receive that earlier cached Props snapshot. This is not evidence of missing
pixel delivery.

Changing only the fixture's dynamic diagnostic nodes to
`node.cache-params = false` made the same delivery check observe 32 buffers and
the correct digest. No transport or scientific processing source was changed.
This establishes a diagnostic read requirement for this fixture. It does not
justify disabling all parameter caches across deployed graphs.

## Limits and warnings

The prefix lacks the optional `support/libspa-dbus` module, producing a warning.
The core also logs `can't setup mixer` for the NDArray input, a busy format
unset during teardown and buffer negotiation `EBUSY` on source removal.
Delivery and link cleanup checks pass despite these
warnings; they are retained, not described as repaired. This fixture has exactly
one input link and provides no fan-in or mixing qualification.

Desktop audio and the already-running GUI/HIL session were left untouched. The
fixture requests no RT scheduling and does not establish cadence, latency,
allocation, numeric RTC equivalence, progressive delivery or maximum rate.
The 100/1 advertised rate is not a measured timing result.

No Copper FGN/JFG or AOS ownership has moved. Required-owner cohort teardown,
held admission, withdrawal while links are pending, owner replacement, coordinated
reset, delayed commands, shared model time and multiple-endpoint adapter behavior
still require the next session pilot. A fork or native WirePlumber patch is not
needed for the demonstrated complete-frame discovery/format/link path; other AO
types and native live controls retain separate compatibility gates.

## Independent review

The independent review accepted this bounded evidence and identified four
findings. WPC-001's silent escalation in the graceful gate is fixed by strict
SIGTERM completion. WPC-002's optimization-sensitive acceptance assertions are
replaced with explicit checks and the four cases rerun under `python3 -O`.
WPC-003's cached build selection is addressed by requiring a fresh build root;
an existing-root invocation now fails explicitly. WPC-004's native warnings
remain recorded above. Endpoint reset/reuse and full RTC lifecycle remain open.
