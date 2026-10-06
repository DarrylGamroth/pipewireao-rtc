# Independent optional observation integration review

2026-10-06. This review covers observation commit
`c4c47eee0bc956ef755ba458ff5256fc95d514fc` as integrated at
`9055db3ea3d5c4f6488e6438fe0103b7725b5e04` on
`work/native-control-planes-20261005`. The independent worktree is
`/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-observation-review`,
branch `review/observation-9055db3`, created clean from that revision.
The source worktree had four existing calibration-export/test edits; this
review did not modify or incorporate them. No production code was changed.

One confirmed startup containment defect requires correction and verification
before selecting this integration. The primary agent accepted OBSR-001 and
assigned a separate remediation. The identity and public API implementation
review found no further confirmed defect. The recorded controlled numerical
evidence remains valid within its stated preparation and finite-cohort scope.

## Authority and review coverage

The review uses [RTC-DEV-006](operations.md), the selected optional HIL
allocation, [validation record](LIVE_OBSERVATION_VALIDATION.md), and public
[QUEUE-009/010/011](https://github.com/DarrylGamroth/pipewireao-spa-plugins-core/blob/163ea034dbfb4f41fabb7f0cfd218b0908a0ca75/docs/queue.md).
[RTC issue #3](https://github.com/DarrylGamroth/pipewireao-rtc/issues/3) was
fetched directly on the review date. It was OPEN, with no comments. Its actual
acceptance includes sparse Registry discovery, later NodeInfo metadata,
missing/mismatched identities, asynchronous endpoint replacement, optional
failure containment and separate live/scientific gates.

Inspected code includes
[observation_boundary.jl](../deployment/julia/src/observation_boundary.jl),
[deployment hooks](../deployment/julia/src/deploy.jl),
[HIL export](../deployment/julia/src/hil_export.jl),
[placement validation](../deployment/julia/src/placement.jl), and the HIL
observation/source-buffer and finite-pacing options. The review checked
relevant tests, the retained evidence recorder, native reader and FFTW
qualification instrumentation. It did not review or select the separate GUI
candidate or change scientific algorithms, FFT policy, models or tolerances.

| ID | Severity | Confidence | Disposition |
| --- | --- | --- | --- |
| OBSR-001 | Medium | High | Confirmed; primary accepted; remediation and independent verification pending |
| OBSR-002 | Informational | High | Identity/delta/link fencing checks pass; no defect found |
| OBSR-003 | Informational | High | Public API and post-admission retirement/cleanup evidence accepted within stated dependency scope |
| OBSR-004 | Qualification limit | High | Exact controlled-preparation evidence accepted; default cold/GUI/Julia-reader limits remain open |

## OBSR-001 — Optional startup failure still requires its observer thread

**Observed source:** HIL export adds an unconditional core placement
requirement for one `observer-loop` thread on CPU 14, FIFO priority 83
(`hil_export.jl`, lines 850–852 at the reviewed revision).
`prepare_observation!` contains optional connection failures and records
`detector-observation.state = unavailable` (`deploy.jl`, lines 1096–1113).
Immediately afterward `_run_locked` unconditionally passes every original
role placement contract to `Placement.snapshot` (lines 1246–1249).
`Placement.snapshot` requires every configured thread count, including the
observer thread (`placement.jl`, lines 122–127).

**Observed failure:** Retained cohort
`~/.cache/rtc-observation-qualified-20261005/cohorts/classic-missing-queue/`
contains supervisor exit 1 and this diagnostic in `supervisor.log`:

```text
process 3515066 requires 1 thread(s) matching ...
"name" => "observer-loop", "priority" => 83, "policy" => "fifo",
"cpus" => Any[14], "count" => 1 ... observed 0
```

The missing optional queue did not materialize the observation loop. The
subsequent `classic-missing-queue-v2` cohort reached admitted/Running with
observation unavailable, completed 256 exact detector/command records and
exited normally, but its fixture removed that placement requirement. The
validation document records this modification explicitly at lines 260–275.
Neither production export nor the reviewed deployment hook makes that
conditional adjustment.

**Derived impact:** The production optional-preparation catch does not contain
this startup failure. Required admission remains dependent on a thread used
only by the unavailable optional branch. The v2 fixture proves the timeout can
be contained under its modified contract; it does not close the corresponding
generated-package gate. Successful post-admission link-loss and replacement
cohorts do not exercise this missing-thread case.

**Proposed remediation:** Derive the effective placement contract according to
the explicitly selected optional boundary's actual availability. When that
boundary is unavailable, omit only its generated observer-thread count.
Preserve the original specification, all required science thread counts, CPU
envelope, leader placement, scheduling rules and memlock requirements. When
the boundary is available, continue checking its placement. Do not disable all
placement verification or alter numerical policy.

**Required validation:** A focused test must demonstrate the availability
decision, preserve the original contract and show that unrelated placement
violations still reject. Repeat a fresh installed missing-queue startup with
the generated observer-thread requirement retained in the package: the runtime
must reach admitted/Running with optional observation unavailable and clean up
all owned resources. Keep successful-branch placement verification intact.
Use the same controlled scientific comparison if a science-equivalence claim
is attached to that run.

**Disposition:** The primary independently verified this source path and
accepted the finding during review. A separate worker owns the proposed
correction. This review does not yet claim pass-after evidence or closure.

## OBSR-002 — Identity, property deltas and asynchronous preparation

**Observed:** Registry discovery uses stable name/global-ID/serial and port
selection fields. It does not require owner queue metadata in sparse Registry
globals. Three bound NodeInfo listeners separately establish source, input and
output metadata. Initial metadata must arrive with the properties change bit;
state-only deltas preserve prior property evidence. A properties update with
missing name/serial fails instead of inheriting stale identity. Queue input and
output must have the same nonempty owner queue ID; output must advertise the
public queue device identity.

`fence_endpoints` compares the original source, source port, queue input,
input port and queue output identities after asynchronous waits and immediately
before link creation under the thread-loop lock. Node removal/error callbacks
retain a terminal failure. The link uses exact endpoint IDs, `link.passive=true`
and `object.linger=false`; successful preparation requires the expected link
endpoints and Paused/Active state. Property-only and state-only LinkInfo deltas
preserve the appropriate passive/state evidence. A new same-name node is not
silently rebound.

**Validation:** The current cold boundary suite passed 41 assertions, including
sparse Registry discovery, delayed NodeInfo gating, property/state deltas,
missing/mismatched identity, all five asynchronous ID/serial fences, passive
link evidence and optional cleanup. The public loop suite passed 117
assertions on CPU 15 with RT and affinity requests disabled in that API fixture.
It checks explicit loop selection, repeated default/empty/`data.rt` selection
and actual Linux thread names. The retained live replacement cohorts also show
permanent retirement with changed optional IDs/serials and unchanged required
objects. These checks address issue #3's original sparse-global defect.

**Disposition:** No additional remediation proposed. The contract does not
claim protection from another authorized local client fabricating all node
properties. Actual producer/queue execution is still owned by the public SDK.

## OBSR-003 — Ownership, callbacks, retirement and queue prerequisite

**Observed:** RTC owns one passive Link proxy, three read-only Node proxies,
its Registry/core/context and a cold ThreadLoop. The observation callbacks copy
NodeInfo properties or retain LinkInfo/error state; they do not run acquisition,
scientific processing or filesystem work. Link creation and waits occur on the
cold supervisor path while ingress is held, after required runner admission.
The boundary never dequeues or holds data-plane sample loans. Those loans and
copy/drop-oldest behavior remain the queue module's responsibility.

After admission, observed optional loss closes the boundary and records
unavailability without sending source pause/reset or runner stop commands.
Retirement is permanent within the lifecycle. Ordinary shutdown first obtains
source pause or revokes the source/core, then closes the optional boundary before
finishing source cleanup; final stop also closes it idempotently. Each close
attempt proceeds through the other owned resources and collects errors.
No daemon-private objects or layouts are used by the production boundary.
The loop test's native calls use public context/data-loop APIs.

**Dependency and evidence limits:** The accepted installed cohorts use the
separately corrected QRA001 queue module, SHA-256
`8f953946733fafa3aaa766518ba3c2128fd2e6977babe3b8d478050f20664835`,
and native runner SHA-256
`71549afe3ca2f235c1264dafc0f18602936de861ad5e549cbc1b70c7c330fb4d`.
Earlier allocator and output-loan forward-progress failures remain retained
in the validation record. The RTC preflight's module-file existence check is
not evidence that an arbitrary SDK prefix includes those corrections.
Deployment claims must retain the qualified dependency identity or separately
verify their selected SDK. The observation source hash matches the ledger;
current native-control integration changes in deployment/owner entrypoints
mean the old installed cohorts are not executions of the complete reviewed
9055db3 tree.

**Disposition:** Post-admission containment and normal native teardown are
supported by the sealed cohorts. Source review found no additional ownership
defect. OBSR-001 and current-tree installed integration remain separate gates.
QUEUE-011 describes stable queue endpoints through supported restart; it does
not require this deployment to repair a deliberately retired optional branch.

## OBSR-004 — Numerical attribution and exact qualification scope

**Observed evidence integrity:** The final ledger's SHA-256 matches the
documented value
`2d9696272cf7e73289b995c1a51c09aa8c9a881f9bce422de16bf8339b88fce6`.
A read-only independent audit verified all 317 cohort evidence-file hashes
(540,963,750 bytes), 11 instrumentation hashes and the recorded provenance,
deployment configuration and runner hashes of four installed packages.
It separately rechecked all 3,584 retained science records across complete
generations against each instrument's disabled reference, and all 1,464 reader
receipts against their own retained generation/frame, exact payload, current
Acquisition version/size/timebase/flags/domain, Header sequence/PTS/flags and
owner exposure. All checks passed. Recorded exits and absence of surviving
owned/observer processes/runtime children were also rechecked.

**Observed numerical discrimination:** The two imported-wisdom Classic replays
have identical graph and command hashes and reproduce all 256 detector records.
The no-import replay keeps those same graph/command hashes, uses a different
plan preparation and differs in 16 detector records. The retained public
photon-rate hashes and wisdom entry sets further discriminate preparation.
FFTW documents runtime-selected MEASURE/PATIENT plans and small run-to-run
floating-point differences; saved wisdom fixes plan selection for this purpose.
See [FFTW FAQ 3.8](https://www.fftw.org/faq/section3.html#nondeterministic).

**Derived conclusion:** Cold planner variation is an expected source of
floating-point variability. This evidence demonstrates a preparation-dependent
trajectory in the tested case without an observer. A differing cold detector
digest alone therefore does not establish observer-caused mathematical change.
The exact stochastic/ADC branch amplification and the cause of every earlier
divergent cohort were not established. No blanket harmlessness or root-cause
claim is justified.

The twelve common-wisdom cohorts isolate observer behavior under identical
recorded preparation. Their exact disabled/unattended/stall/death/reattachment,
reset, link-retirement and replacement comparisons remain exact acceptance
evidence. They do not convert historical failed default-cold comparisons into
passes. Existing exact recorded qualification must retain its named input and
preparation scope; this review proposes no weaker tolerance or production FFT
policy change.

**Disposition:** Controlled finite CPU evidence accepted. Default cold whole-
trajectory repeatability, selected GUI native parser/loop integration and the
specific Julia async-reader EIO/zero-delivery configuration remain open.
Neither GUI pixels nor continued source progress alone satisfy metadata-aware
science equivalence. The 500 Hz model with requested 10 Hz wall pacing and zero
post-prefix timing samples establishes no achieved rate, latency bound,
convergence, real-time isolation or physical hardware result.

## Review execution

The reviewer ran only cold tests and read-only evidence checks on CPU 15.
No science cohort, GUI build, large build, owned operator service or production
numerical experiment was started. The current source tests were:

```sh
JULIA_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 taskset -c 15 julia \
  --startup-file=no --project=deployment/julia -e \
  'include("deployment/julia/test/test_observation_boundary.jl"); include("deployment/julia/test/test_observation_loop.jl")'
```

Result: 41 boundary and 117 public-loop assertions passed. Julia emitted the
existing loaded/precompiled Base64-version notice. The fail-before evidence
for OBSR-001 is the retained actual startup failure; no new production patch
or synthetic science run was needed to establish it.
