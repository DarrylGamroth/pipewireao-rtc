# Three-package graph reconciliation

Source: cleanup branch `codex/julia-session-policy-20261104`, based on `c2f0fd4`.
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
| PipeWireAO 0.9.2 | Released `ec57daf` plus the five cleanup API commits; preserves the released metadata host and zero-allocation duration binding | Full package suite: 2,315 assertions across 81 reported sets; bindings regenerated from the matching SDK |
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

Final RTC source-cohort verification is in progress. Results and exact source-cohort limitations will be
recorded here before completion. No live installed session is changed. Software
checks do not establish hardware correctness, GPU behavior or deadline qualification.
