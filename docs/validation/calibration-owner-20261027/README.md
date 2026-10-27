# Native initial calibration — 2026-10-27

The shared initial-session endpoint now derives its exact WFS frontend and PDM
conditioner from a built regular graph, accepts the existing native action
profile, adopts transported absolute commands, and collects correlated owned
raw/slopes/flux/validity data. There is one authored RTC graph. The cold builder
rechecks selected graph/FITS authority; it adds no flat, offset, threshold or
mask. The existing Procedure remains the acquisition coordinator.

The [plan](PLAN.md) records ownership and gates; the [independent review](REVIEW.md)
records findings and dispositions. Normal configured ADC, photon noise and
readout noise remain enabled. No GPU, installed session or device was used.

## Observed verification

Julia 1.13.3, CPU, registered scientific dependencies with explicit RTC/HIL source
overrides only in the validation environment. The selected Classic application
was the existing registered-0.2.21 build, graph SHA-256
`a9e39891219b83e5a3327027951395c9fdfe74f2e9b8a1cecd511f3f7eb2a575`; its complete application-file hash map was unchanged.
The final optical selector uses public APIs throughout.

| Check | Result | Scope |
| --- | --- | --- |
| RTC complete software suite | 5,624 assertions, 213 testsets passed | Includes 22 native dispatch/idle-loss checks; software/private-core qualification |
| Cold regular-graph projections | 29 passed | Exact declarations, parameter arrays, typed ports and source immutability |
| Same-graph stale FITS rejection | 6 passed independently | Reject before plant/transport creation |
| Four-stream capture | 80 unit + 16 private-core assertions passed | Row-major data, full identities, copied metadata, validity preservation and deadlines |
| Command transport | 19 passed | Actual conditioner clipping, matching feedback, restoration and worker cancellation |
| HIL full package suite | 2,993 passed, including Aqua | Private cores, publication-cycle witness and failure/reset fences |
| Actual Classic safety integration | 106 passed | Scientific rejection, early cancellation, idle controller loss, closure, unchanged files and no loaded GPU package |
| Plan diagram | Rendered with repository-prescribed Mermaid container | Documentation structure |

Logs are retained in the external `standard-calibration-validation` evidence
workspace. Relevant basenames are `calibration-owner-root-tests-20261027-r3.log`,
`calibration-capture-primary-20261027.log`,
`calibration-transport-drain-20261027.log`,
`hil-publication-cycle-Pkg-test.log` and
`initial-calibration-classic-private-core-20261027-r8-adjudicated-safety.log`.
Failed ordering experiments remain separate evidence, not passing gates.

The complete RTC `Pkg.test()` invocation also passed 5,624 assertions on Julia
1.13.3 (`calibration-owner-Pkg-test.log`). Its stale workspace-hash warning was
addressed by resolving the final release metadata through Pkg; no manifest was
edited by hand. The final release package selector passed 326 assertions, with public API,
version and docstring smoke checks also passing. The tracked workspace manifest
changed only its project hash and this package's version; dependencies did not
change. Registered-package smoke checks are recorded below when complete.

## What the optical test establishes

A genuine transported probe is adopted before an exposure executes. Raw UInt16
pixels and all WFS outputs carry the same full wire acquisition identity,
model start and duration. The endpoint retains the full wire domain and its
explicit coordinator-domain-ID association. Header PTS remains a separate clock.
Native source queueing, source-cycle completion and complete sink capture are
separate facts. The shared HIL publication-cycle witness orders one downstream
progress request; it does not establish WFS success or advance the optical model.

The selected frozen estimator has 184 active subapertures. Under the selected
normal noisy, turbulent plant, positions 85 and 104 measured fluxes 932 and 975
against the existing threshold 1,000. All response values were finite. The owner
correctly returned invalid scientific evidence; the Procedure rejected it,
restored the reference and released exactly once. The online numerical consumer
was not called with the invalid batch. This is a verified rejection, not an
accepted interaction calibration. Noise versus atmospheric contribution was
not distinguished, and no mask or threshold was changed to force acceptance.

Cancellation before Hold also restored/released without exposing a frame. Loss
of the exact idle controller after Hold faulted and fenced the endpoint without
restoration, another probe or any exposure. All graph workers, borrowed buffers,
streams, listeners, cores, timers and owned notifications were closed.

## Remaining gates

A stationary calibration-source/eligibility procedure and an accepted complete
basis remain prerequisites for AOC estimation and an activatable bundle. This
increment does not qualify accepted optical acquisition, optical consumer-failure
recovery, controller loss during an exposure, multi-WFS/named-corrector coherence,
physical settling, deadline performance, GPU execution or running-controller
state preservation. Existing Procedure unit tests cover online consumers and
known processing failure; they are not substituted for those optical gates.

An in-flight synchronous HIL call resolves or reaches its finite deadline before
cooperative revocation checks. No immediate hard cancellation is claimed. Unknown
outcomes never authorize retry, rebind or ordinary-loop resumption. The optional
native Capture file-export action remains unsupported by this initial endpoint.
