# Three-package graph reconciliation

Source: cleanup branch `codex/julia-session-policy-20261104`, based on `c2f0fd4`;
RTC implementation commit `b18ac10`.
The worktree was clean before this migration. The original checkout, installed
applications and independent scientific worktrees are not migration targets.

## Decision and naming authority

The user selected the installed three-package migration while preserving the
completed RTC cleanup. RTC 0.6.1 reconciles that cleanup with the package boundary
already registered in RTC 0.6.0; it does not replace this branch with that older
implementation baseline. No package is published by this work.

| Identifier | Meaning and authority | Boundary |
| --- | --- | --- |
| `FilterGraphAlgorithms` | Numerical algorithms; upstream 0.12.0 package | Optional science dependency |
| `FilterGraphs` | Graph engine; upstream 0.9.0 package, UUID `8053475d-7091-4a8a-adbc-8ed688b6da8d` | Optional graph extension |
| `FilterGraphPipeWire` | PipeWire integration and standalone application; upstream 0.5.0 baseline, reconciled 0.5.1 source | Public preparation, threading configuration and node APIs |

The upstream package manifests, README and public function documentation are the
naming/API authority. `JuliaFilterGraph` and `FilterGraphIsland` are retired Julia
package identities. Their native protocol strings, historical evidence, repository
paths and generated schema provenance remain exact boundary artifacts. The
standalone executable remains `filtergraph-island`.

## Implementation boundary

Graph contracts, initial FITS bindings, calibration projections, bundle staging,
chopped measurement frontends and optional analysis delegate preparation and
execution cleanup to public `FilterGraphPipeWire.prepare_service_graph(path; ...)`
and `close_execution`. Library callers no longer construct command-line options
just to prepare graphs. Startup parameters, explicit row-worker placement,
matrix layout and capture selection are passed through the public keywords.
The ordinary graph-owner CLI still parses its actual command-line arguments.

RTC retains its native bootstrap admission, application metadata, correction and
physical-offset composition. The standalone application's event-file orchestration
cannot replace those controls. Composition feedback rejection uses type dispatch.
Analysis retains the reserved second default thread and GC-safe waits because the
retired application's monitor helpers are not public integration APIs. This does
not introduce another graph executor or session authority.

The development manifest is regenerated through Pkg with the reconciled
PipeWireAO 0.9.2 source and native JLL 4.0.1+0. The relative sibling source path
is a development dependency; it is never copied into an exported application.
Native command validation uses an explicit temporary 4.0.2 SDK. The development test workspace stays in the source project; exported
applications still consume registered dependencies without copying RTC or its tests.
Agent/Clocks/Hsm, the AOS-only optics extension, simulator-owned detector/sampling
implementations, generic `CaptureFiles`, journal removal and the Julia session
policy remain on the cleanup branch.

## Receiving API gaps and source cohort

The first real calibration-worker check failed with missing
`command_endpoint(::PipeWireNode, ...)` and `parameter_ports` methods. Inspection
confirmed that the three-package migration baseline omitted the earlier upstream
cleanup commit `07f08a9`. This was an observed API omission, not a numerical or
thread-affinity hypothesis. Reverting to shared graph access was rejected.

Installed PipeWireAO 0.9.1 and native 4.0.1 likewise omit the cleanup's command
endpoint and borrowed-loop accessor. Required preservation ports are therefore
prepared on separate branches:

| Component | Source baseline and reconciliation | Verification |
| --- | --- | --- |
| Native PipeWire 4.0.2 | `036e70ee7` plus the borrowed-loop port, commit `156daf39e` | Five native ndarray/filter, admission, metadata and publication suites pass |
| PipeWireAO 0.9.2 | Released `ec57daf` plus the five cleanup API commits, receiving commit `59f52c5`; preserves the released metadata host and zero-allocation duration binding | Full package suite: 2,315 assertions across 81 reported sets; bindings regenerated from the matching SDK |
| FilterGraphPipeWire 0.5.1 | Three-package baseline `4423eb9`, receiving commit `ec378d4` | 48 parameter-port and 7 owner-loop endpoint assertions; same selectors fail on 0.5.0 with the missing-method errors |

These are unpublished source versions. Registration, JLL packaging and coordinated
application release remain separate work; the installed three-package cohort is
unchanged. RTC requires PipeWireAO 0.9.2 / FilterGraphPipeWire 0.5.1 so an old
published package cannot silently satisfy the missing Julia APIs. The existing
native JLL remains the metadata ABI baseline; the endpoint additionally needs the
4.0.2 source SDK's accessor. Current minimum JLL alone does not establish that
capability. Release the accessor-bearing native/JLL cohort before publishing a
standalone RTC runtime that uses these APIs.

## Verification

The initial registered-cohort core suite passed 11,047 assertions across 514
reported testsets. That suite alone did not expose the omitted endpoint API; the
private worker selector did. The same worker selector now passes all 206
assertions, including the 97 ownership, cancellation, lifecycle and cleanup checks,
with the reconciled source packages and native 4.0.2 library/daemon. Generic
capture passes 173 assertions on that final source cohort as well.

Focused no-core checks pass for FITS startup adoption (25), analysis metadata (20),
synchronized inputs (3), analysis statistics (50), correction controls/observation
(39/46), prepared session schemas (32), chopped calibration (58), typed composition
warmup/admission (27), thread policy (6) and temporary controller/projection/bundle
parameter and numerical equivalence (11). The temporary projection check covers
real FITS loading, remapped data ports, invalid-cut rejection, preserved source
hashes and bundle adoption; full acquired Classic staging was not exercised.

The final source-cohort core suite passes 11,048 assertions across 514 reported
testsets, exit 0. Its isolated test environment combines root and test dependencies and directly selects PipeWireAO_jll so JLL
library preferences take effect. Without that direct dependency preferences by
package name are ignored; this startup-selector error was corrected before
native source validation. Client library and private daemon are explicitly the
same temporary 4.0.2 SDK. The optional environment adds AOS 0.3.21 from the existing
ownership worktree, HIL 0.5.0, AOC 0.17.3, FGA 0.12.0, FilterGraphs 0.9.0 and the
reconciled FGPW/PipeWireAO sources. Core imports remain independent of science.

Logs are `/tmp/rtc-reconciled-final-core-20261106.log`,
`/tmp/rtc-reconciled-worker-private-core-after-20261106.log` and
`/tmp/rtc-reconciled-capture-private-core-after-20261106.log`; focused logs use
`/tmp/rtc-reconciled-*.log`. Receiving-package logs use
`/tmp/pipewireao-rtc-reconciliation-*.log`,
`/tmp/fgpw-rtc-reconciliation-*.log` and
`/tmp/pipewire-rtc-reconciliation-*.log`.

Documentation checks pass 777 assertions for local links/anchors, structure,
whitespace and preserved requirement IDs. All 90 changed Julia files pass formatting idempotence with AST/literal equality.
Independent source reviews found no defects in the RTC public API/ownership
reconciliation, native accessor lifetime, FGPW port or PipeWireAO port. PWAO bindings
were regenerated with the supported Clang generator from the matching SDK; its
existing system `timespec` warning remains and the generated delta is exactly
the accessor. Protocol data and frozen/generated schema provenance are unchanged.

No live installed session is changed. These checks do not establish full-instrument
staging, GPU behavior, hardware correctness, cadence or deadline qualification.
