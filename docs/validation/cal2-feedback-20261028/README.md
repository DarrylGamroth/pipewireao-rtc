# CAL2 external pupil and physical-offset validation — 2026-10-28

This record supports RTC 0.2.34–0.2.36 and RTC-DEV-037/038. The parent increment is
`fec49dd` / `565e744` on `cal2-external-pupil-gpu`, PR #19. Scientific acceptance,
software verification, private receiver integration and combined-loop
qualification are separate claims.

## Implemented boundaries

The version-4 external-pupil owner uses the existing native bootstrap and source
controls, with independent SCC/LLOWFS exposure streams and no simulated CAL2 DM.
CAL2 projects modes to 2,304 physical tweeter commands. GPI owns admission and
holds an absolute contribution per branch; one adopted snapshot supplies the
post-VDM physical offset and `r′ = r − CQu` reference compensation before final
conditioning. Calibration identity, command order, cohort, age and limits are
checked without introducing another authority or supervisor.

`InstrumentExport.prepare`, `compose`, `materialize_calibration` and
`prepare_feedback` retain the ordinary data-only application workflow. The
optical-calibration mode needs no dummy controller FITS. Materialization writes
`generated/calibration/rtc.yaml` and a path/hash receipt, preserves authored RTC
bytes, and controller mode selects that generated configuration. Feedback
preparation validates both accepted branches, executed frontend/settings,
selected RTC closure and all actual typed graph/physical factors before sealing.

## Software and integration evidence

Julia 1.13.3, no CUDA use. Source validation environments remain outside built
application runtime closures. Selected dependency releases are AOS 0.3.10,
HIL 0.2.10, Proper 0.4.1, FGA 0.8.11 and FGPW 0.1.15. Host expected-reference
qualification applies only to a CPU GPI detector producer; CAL2 propagation has
an independent CPU/AMDGPU selection.

| Selector | Observed result and scope |
| --- | --- |
| `test/runtests.jl` | 7,365 assertions pass; retained log `/tmp/cal2-rtc-core-followup.log` |
| Physical-offset core / native receiver | 79 core and 127 private-core assertions pass; no combined application claim |
| `test/calibration_optical.jl` | 90 CPU assertions pass: physical order/units, native pupil orientation, recipe admission, expected-response cold guards and executed settings |
| `test/calibration_optical_publication.jl` | 18 CPU assertions pass, including actual typed graph/FITS publication |
| `test/integration/test_managed_session_cal2.jl` | 23 cold assertions pass; no core, service or accelerator action |
| Source-only CAL2 build | Fresh ordinary optical-calibration build succeeds without controller FITS; default controller mode requires accepted selection |

The opt-in `managed_session_cal2.jl` derives contracts and roles from an accepted
sealed composed application. It checks native open properties, bounded complete
acquisitions, independent cadences, Pause/Reset/new acquisition generations and
exact owned cleanup. Physical, adopted-offset, reference-before/after and CAL2
modal vectors retain per-frame payloads. Its zero-reference oracle compares the
same receiving GPI physical-output frames; CAL2 exposure/input latency is a
separate quantity. The selector has not yet run against the normal combined
cohort, and exact-zero equality proves no nonzero `CQu` adoption.

## Accepted calibration and limits

The retained accepted bundle is `/tmp/cal2-native-calibration-20261028-r3`, identity
`sha256:a627376461693bfdd355babf7b7872283edeca2bf37debcc54366e212a320b5e`.
Its `calibration.yaml` SHA-256 is
`9faffb622e968bde0886d16d65564a1640a4e83343eec234fa8cda992b9d8833`.
Both indexed reports are accepted, deployable and non-diagnostic; application
acceptance remains false. Actual native `PupilOutput.pack!` fixes the GPI `[x,y]`
to transported `[quantity,y,x]` convention. Earlier uncorrected optical results
do not qualify this boundary.

At the unchanged 5% gates, optical held-out reconstruction errors are
1.543–3.254%; the Host expected-reference combined upper estimates are
0.990–1.059%, with h/h2 derivative upper estimate 0.4378%. The recipe uses 512
samples, 128 rounding samples, and independent training/validation seeds
200002/400002. The ideal independent Poisson/Gaussian model, qualified native
Host arithmetic/ADC envelope and empirical uncertainty estimates are explicit.
This accepts held physical-pose mean response, not individual noisy exposures,
finite PRNG-period or hardware-tail behavior, global stability or a noisy loop.
Previous held-frame reference failures remain rejected.

## Independent review dispositions

- C-R1: fixed. Composition protects the selected runtime Project/Manifest and
  validates the final registered runtime closure before publication.
- F-R1/F-R2/F-R3: fixed. Executed frontend projection/static bindings, every
  indexed branch and effective source/ADC settings are checked. Generated RTC
  path/hash and executed selection are bound; Host reference calibration cannot
  qualify an accelerator GPI producer.
- EXP-SW-01: fixed. Temporary frontend cleanup covers all work after creation.
- EXP-SW-02: fixed. Expected-response acquisition requires the exact executed
  photon-rate diagnostic, direct detector→ADC path and HIL frame alias, with no
  competing input/delayed producer. Rewire and runtime/calibration mismatch
  regressions pass. The accepted acquisition preceded this admission-only guard;
  the exact report-bound executed GPI graph passes it separately in
  `/tmp/cal2-chain-guard-smoke.log`. It does not change calibrated arrays.

Final source review found no remaining blocking parser, binding or cleanup
finding within this scope. Numerical uncertainty received a separate review.
Explicit wall pacing preserves the 2 kHz model timestep: CPU examples use 0.1 Hz
with longer branch silence limits; AMDGPU examples use 1 Hz. Neither setting
establishes a deadline. Normal combined lifecycle, nonzero physical/reference
adoption above Float32 quantization uncertainty, sustained simultaneous-loop
science and physical hardware qualification remain pending.

## Explicit mixed runtime follow-up — RTC 0.2.35

Feedback profile version 1 optionally selects `upstream: {backend: cpu, device:
0}` independently of the component's root backend/device. Omission preserves the
previous requirement that both match. The actual upstream still passes the Host
reference backend guard. Both selections reject unknown fields, invalid device
types and unsupported backends.

The ordinary host profile's optional `runtime-backends: [amdgpu]` promotes the
source's declared accelerator package in the generated Project only. Explicit
selection requires canonical UUID and compatibility metadata; it never changes
simulation selection, imports GPU code or relaxes composition's exact registered
runtime closure. A Manifest entry alone does not make a weak root dependency
loadable from `Main`; the negative cold probe confirms this distinction.

Focused source checks pass 53 profile, 198 export, 70 feedback and 31 existing
composition assertions. The explicit mixed feedback regression fails against
registered RTC 0.2.34 and passes with this follow-up. The actual ordinary GPI cold
build with `host.cpu-cal2.example.yaml` retains CPU/device 0, generates direct
AMDGPU 2.9.2 metadata, leaves all source file hashes unchanged and loads neither
CUDA nor AMDGPU. Its fresh final-header output is recorded separately in
`/tmp/cal2-runtime-backend-gpi-build-r3.log`; no generated file is edited by hand.
The retained r2 source-hash failure coincided with the parent's GPI Project pin
and README edits during the build; it does not establish generator mutation.
These are cold preparation checks. Normal combined native and simultaneous
noisy-loop qualification remain pending.

## Declared cross-link contracts and capture schemas

The registered 0.2.35 application's first cold capture preflight exposed a harness
assumption: `graph_port_contracts` provides shape and element type, not schema.
Capture now reads public prepared JFG output formats, whose schemas are the ones
published by FGPW, and closes every prepared graph. Mandatory products reject
missing schemas; truly unschematized optional modal taps record missing
observability. Native controller output, session declaration and receiver branch
schemas must agree. The focused harness checks pass 33 assertions, including a
real small prepared JFG graph, with no GPU imports or service actions.

This inspection also found an application data error: the receiver's authored
`pipewireao/requested-pdm-command-opd-m-f32/1` string differed from the existing
native `requested_pdm_command` declaration,
`pipewireao/requested-pdm-command-f32/1`. The authored receiver was corrected and
composition regenerated without changing calibration or graphs. Earlier direct
array/mean receipts and custom-schema receiver tests did not prove these
application return links negotiated or adopted a native contribution.

The source compositor now compares shape, element type, layout and schema for
each explicitly added cross-link when both endpoints declare that field, after
receiver sinks are attached and before publishing output. No new imports or
schema identifiers are introduced. Opaque ports and omitted fields retain prior
admission; this does not prove undeclared contracts or actual native negotiation.
The same regression fails eight assertions against registered 0.2.35 because
contradictory schema/shape/type/layout outputs were published, then passes all
42 composition assertions with the gate. Retained logs are
`/tmp/cal2-link-contract-before.log` and `/tmp/cal2-link-contract-after.log`.
Native cohort results and the publication version of this cold gate remain
separate evidence.

## Native session capacity admission

The corrected registered 0.2.35 composition contains 36 normal connections:
31 retained GPI connections, two internal CAL2 connections and three explicit
cross-application connections. Native policy still admitted only 32 and rejected
startup before Run. The shared cold validator and native policy now use a finite
64-connection bound; actual native configuration compilation additionally requires
at least one connection. Zero-link offline optical-calibration exports remain
valid. Lua connection ownership uses dynamically sized tables; this change does
not alter a fixed-size transport ABI or establish a timing/deadline bound.

The same private `WpTestServer` host fixture fails with the old policy's
`Invalid declared connection count`, then admits 36 and 64 through an actual
native public-status response. It rejects 65 and zero with configuration exit 78.
Its endpoints are deliberately absent: these are policy admission tests, not
proof that 36 links negotiate or that a combined scientific cohort reaches Run.
The parent retains the normal application lifecycle run as separate evidence.

A cold audit of the composed declaration found five external owners and five
cold bootstrap controls, one auxiliary source and one execution group. These
fit the unchanged owner (8), auxiliary (7) and cold-control (32) limits. Its
17 sources, three graphs, 27 sinks and 69 ports have no corresponding native
total-count cap. The largest port rank is three (limit 32), longest declared
schema is 113 bytes (limit 4096), and largest declared format has seven fields
(limit 32). Maximum session declaration container depth is six, below the
native argument parser's depth 16 after its wrapper. Controller/client identity,
property-reply/transaction and control payload/queue limits constrain different
objects; scientific port counts do not consume those capacities. Their actual
runtime records remain subject to native admission and are not inferred from
the declared port count. No unrelated capacity was increased.

Focused Julia checks pass 407 assertions across session configuration, auxiliary
sources, composition and instrument definitions; another 331 cold assertions
pass for registered runtime, session runtime, instrument export and feedback
preparation. All 12 native Meson selectors pass. Registered 0.2.35 incorrectly publishes a 65-link composition in the same
regression (two failed assertions); the source rejects it before publication.
The full source QA suite also passes 7,428 assertions across 302 testsets in
`/tmp/cal2-session-capacity-core-r2.log` (four Julia threads, one BLAS thread,
isolated SDK). The first attempt used the narrower validation environment and
stopped on its missing direct `Hsm` test dependency; no behavior failed there.
Retained focused logs are `/tmp/cal2-session-capacity-native-before.log`,
`/tmp/cal2-session-capacity-native-after.log` and
`/tmp/cal2-session-capacity-julia.log`. The isolated SDK's earlier SQLite loader
failure and this policy capacity failure both occurred before Run; neither
establishes a coupled-loop result.

## Explicit owner thread placement

A subsequent normal startup reached native policy initialization, then the GPI
GraphOwner rejected three default Julia threads paired with only two inherited
`--pin-cpus` entries. Feedback preparation had explicitly changed the thread
count while retaining the source host's two-worker pin declaration. This was a
cold composition admission gap; it occurred before Run and does not change the
calibration or receiving equations.

Cold application validation now checks explicit pins after validating the
existing placement contract. It requires an explicit positive default Julia
thread count, one pin per default thread, pins within the declared process CPU
envelope and thread one's pin equal to the declared leader CPU. Split and equals
option forms are accepted. Interactive pool forms and one-thread metadata are
left to their existing caller contracts; repeated pins retain FGI runtime
semantics. Absent pins remain unchanged. Preparation never guesses extra CPUs or
rewrites caller affinity. Authored host scheduling must supply the intended
worker list before rebuilding and composing.

The exact registered 0.2.35 thread/pin composition regression publishes the bad
three-thread/two-pin application (two failed assertions). Source validation
rejects publication and accepts three matching pins and intentional repeated
pins. Focused owner scheduling, composition, auxiliary-source and feedback
preparation checks pass 187 assertions. Retained logs are
`/tmp/cal2-owner-pins-before.log` and `/tmp/cal2-owner-pins-after.log`.
The 7,428-assertion full-core result above precedes this additional cold guard;
its scope is recorded separately rather than claimed as a final-guard rerun.

The actual sealed applications pass the paired cold proof: `combined-r2` rejects
the exact two-pin/three-thread mismatch; `combined-r3` passes with 36 declared
connections, three default GPI Julia threads and pins `3,2,4`. All three added
cross-link contracts pass the shared declared-field gate. This read-only check
imports neither CUDA nor AMDGPU and starts no session; its retained log is
`/tmp/cal2-owner-pins-actual-pair-cold.log`. The next normal native lifecycle attempt remains separate pending evidence.

## Optional science loading at owner preparation

The next registered startup reached native initialization, then CAL2 optical
preparation failed with `Zemax graph replanning requires AdaptiveOpticsSim, Proper
and YAML`. Those dependencies were present. A fresh preparation-only replay
against the actual sealed CAL2 configuration reproduced the exact fallback:
`_main` dynamically loaded science packages, then declaration verification ran
in the caller's older Julia world and could not see the newly loaded graph
methods. No packages or instrument preload instructions were added.

The version-3/4 declaration-verification boundary now uses `Base.invokelatest`,
as the existing owner run boundary already does. The same fresh-process selector
passes 11 assertions while preparing the actual 240/1024 CAL2 optics on an
explicit CPU target, retaining prescription identity, sensor names, finite
products and reset acquisition state. It uses the default optional loaders,
injects only bootstrap admission, leaves the built configuration unchanged and
imports neither CUDA nor AMDGPU. This is CPU preparation evidence, not proof of
the selected AMDGPU owner, native lifecycle or combined-loop behavior.

Run the selector in an environment with the direct scientific dependencies:

```sh
OPENBLAS_NUM_THREADS=1 julia --threads=1 --project=/path/to/science-environment \
  --startup-file=no test/aos_owner_science_loading.jl \
  /path/to/sealed-built-cal2/simulation.conf
```

The retained fail-before and pass-after logs are
`/tmp/cal2-aos-owner-loading-before.log` and
`/tmp/cal2-aos-owner-loading-after.log`; focused owner selectors also pass 235
assertions with an explicit no-GPU-import assertion in
`/tmp/cal2-aos-owner-loading-focus.log`. The final full-source suite after the
pin and optional-loading fixes passes 7,473 assertions across 304 testsets,
exit 0, with an explicit no-CUDA/no-AMDGPU-import assertion, in
`/tmp/cal2-rtc-0236-final-core.log`. The preparation-only component still passes
its complete file/hash seal afterward (`/tmp/cal2-aos-owner-loading-seal.log`).
Failed normal startup cleanup was confirmed; no failed attempt reached Run.

The initial `fatal: git cat-file: could not get object info` is expected stderr
from `test/test_configuration_store.jl:87–88`: the test deletes a loose content
object and requires `ProcessFailedException` on retrieval. An isolated replay
produces the same diagnostic and passes with exit 0 in
`/tmp/cal2-core-git-negative-diagnostic.log`; the full catalog selector also passes.
No warning or failure was suppressed.

The final core command uses the complete QA environment, not the narrower
optional-science environment:

```sh
PIPEWIREAO_PREFIX=/path/to/isolated-sdk OPENBLAS_NUM_THREADS=1 \
  julia --threads=4 --project=/path/to/full-qa-environment --startup-file=no \
  -e 'include("test/runtests.jl"); @assert !any(id -> id.name in ("CUDA", "AMDGPU"), keys(Base.loaded_modules))'
```

## Controlled graphs and execution-group composition

The first registered 0.2.36 normal cohort prepared every owner, then faulted
before Run at native execution-group admission. The offending declarations were
`cal2-llowfs-controller` and `cal2-scc-controller`: both granted session run
control, but neither had an execution group. All 27 sinks were external and
were correctly excluded from that requirement. The CAL2 controller mode also
marked its sensor-to-controller inputs nonpassive. These declarations did not
satisfy the existing RTC-DEV-011/016 contract at baseline `7c2e862`.

The next patch preserves native authority rules. Cold application validation
and actual native configuration compilation now check ownership/run-control
compatibility, explicit group membership, unique nonempty groups with processing
graphs, and standard passive boundaries. Errors identify the offending node or
link. Composition appends disjoint declared group lists rather than requiring
the two applications' lists to be identical; it does not infer groups. The
CAL2 authored controller mode explicitly declares its two independent groups
using the controller node names and marks both sensor inputs passive. Graphs,
calibration artifacts, 500/100 Hz declared branch rates and model settings are
unchanged.

The same regression against registered 0.2.36 publishes the ungrouped component
(two failed assertions), then rejects disjoint group-list composition. The
candidate passes 191 focused cold assertions, including a three-group/36-link
composition with both branch rate rows preserved and immutable component bytes.
The actual old application is rejected cold with its first missing CAL2 graph
name before owner launch. Logs are `/tmp/cal2-group-cold-before.log`,
`/tmp/cal2-group-cold-after.log` and `/tmp/cal2-group-actual-before.log`.

All 12 native Meson selectors pass. The private-core native hook fixture rejects
missing CAL2 groups and nonpassive grouped inputs, admits corrected declarations,
and proves LLOWFS group stop/restart preserves running SCC and GPI group state;
global stop/reset/quit also completes. Native discovery/control I/O is gated in
that fixture. This is policy/lifecycle software evidence, not observed scientific
branch delivery or a completed normal cohort. Logs are
`/tmp/cal2-group-native-hooks.log` and `/tmp/cal2-group-native-full.log`.
The final full-source suite passes 7,470 assertions across 306 testsets, exit 0,
with an explicit no-GPU-import assertion (`/tmp/cal2-group-core.log`). The
concurrent snapshot test made 87 assertions in this run versus 120 in the prior
run; no old testset was omitted and the two new testsets add 30 assertions.
The actual candidate export is recorded separately; normal cohort Run,
simultaneous noisy-loop and deadline qualification remain pending.

## ROCr helper-thread placement

The corrected normal application passes native execution-group admission with
all owners prepared. It then fails the pre-Run placement audit: Julia-named
thread 3548647 has affinity 0–15 outside its owner's deployment envelope. The
historical owning PID is not recoverable: the process exited, no thread census
was retained, and the launch ledger writes placement snapshots only after every
owner passes. The error stack identifies an external-owner snapshot, not the
native session process. Subsequent link-loss messages are cleanup observations.

A paired, isolated preparation uses the actual registered AMDGPU CAL2 owner,
configuration, runtime and `taskset` mask 10–11. With the ROCr setting absent,
two Julia-named helper threads acquire affinity 0–15 during AMDGPU import and
retain it through full optical preparation and an additional propagation.
`strace -f -k` attributes the explicit full-mask thread creation to
`AMDGPU.__init__` through the system ROCr library
`/opt/rocm-7.2.1/lib/libhsa-runtime64.so.1.18.70201`. With only
`HSA_OVERRIDE_CPU_AFFINITY_DEBUG=0` changed, all 25 final threads remain on 10–11
at every checkpoint. The library SHA-256 is
`6a05f324199ef5a8f4f66258e1263f203e7c72929dda4aec137e7eeade6ec8c2`;
the comparison and evidence hashes are in
`/tmp/cal2-amdgpu-affinity-receipt.json`. This establishes the reproduced ROCr
cause without assigning the vanished historical thread to a particular owner.
The [ROCr environment-variable contract](https://rocm.docs.amd.com/projects/ROCR-Runtime/en/docs-7.1.0/api-reference/environment_variables.html)
defines zero as inheriting the parent's CPU affinity.

The shared `SystemdOwners.service_unit` environment boundary now defaults that
setting to zero after inherited and authored environment merges, before any
Julia or accelerator initialization. Explicit conflicting values are rejected;
the caller's environment is unchanged. CPU-only preparation does not import a
GPU package. The existing per-thread audit is unchanged, and its affinity error
now includes the owning PID so future failures can be matched to the retained
launch ledger. No instrument-specific preload or affinity correction is added.

The same focused selector produces four failures against registered 0.2.36 and
passes all 56 assertions against the candidate, with an explicit no-GPU-import
assertion (`/tmp/cal2-rocr-placement-before-all.log` and
`/tmp/cal2-rocr-placement-after.log`). The isolated preparation comparison does
not qualify normal cohort Run, nonzero simultaneous correction, deadline
behavior or physical devices; those gates remain separate.

The final source suite exits 0 with 7,517 assertions across 308 testsets and an
explicit no-GPU-import assertion (`/tmp/cal2-rocr-placement-core.log`). The two
new testsets add 10 assertions; the concurrent snapshot loop makes 124 rather
than 87 assertions in this run, accounting for the remaining count difference
from the preceding group suite. No previous testset is omitted. Independent
review passes all 56 focused checks and cold import validation with no findings
(`/tmp/cal2-rocr-launch-independent-review.json`). Native policy is unchanged
from the preceding 12-selector pass. Release and normal native qualification
remain held; subsequent Running observations are recorded below.

## Running observations and initial exposure coverage

With explicit inherited ROCr affinity, later cohorts pass placement, reach
Running and produce genuine GPI pupil, CAL2 LLOWFS, physical-command and
reference packets. The latest strict capture rejects the first LLOWFS product:
sequence 1 has model PTS 2 ms, so the initial 0–2 ms exposure is absent. These
observations establish real delivery, not a completed normal cohort or noisy
simultaneous-loop acceptance.

An isolated actual AMDGPU full-feed probe takes 3.272 s on its first call,
including 2.594 s compilation, versus 0.390–0.540 s on the next 20 calls. This
supports a startup-stall hypothesis; it does not establish the historical cause
of the missing exposure. Runtime full-feed/emitter warmup passes 29 CPU checks
and independent review, with publication disabled and owner state reset before
Ready. No deadline or complete lifecycle qualification is inferred.

The isolated AMDGPU follow-up uses the exact old sealed application,
`taskset` 10–11 and inherited ROCr affinity, with no core, publication or CUDA.
Warmup takes 8.962 s including 4.590 s compilation; reset leaves pristine source
state. First live feed takes 0.394619 s with 1.642 µs compilation. Across 21
accepted feeds, minimum/median/maximum are 0.390651/0.395054/0.412044 s. The first
LLOWFS and SCC products both have sequence 1 and PTS zero, and LLOWFS PTS is
contiguous at 0/2/4/6/8 ms. Output domain/source state is restored after warmup.
The timing receipt is `/tmp/cal2-owner-warmup-validation.toml`; raw evidence is
`/tmp/cal2-amdgpu-warmed-first-feed-probe.{json,log,jl}`. CPU coverage is 16
chopped, five cancellation/bound and eight seeded detector draw/reset assertions
in `/tmp/cal2-owner-warmup-after-r4.log`, with no GPU imports. The reviewed owner
source SHA is `319558c2b2fc2bc1d4da2c213f19e4bf9ab072b63f4dd7b746eacdedc33811a4`;
test SHA is `be855b08850ba6702a8d23b4fab541e0cc17996c95095611bbded5b67964b6da`.
This is bounded software/functional timing evidence on the old application,
not a managed cohort pass, the confirmed historical cause, deadline acceptance
or physical-device qualification.

## Alternating SCC acquisition and matched pixel residuals

The chopped candidate uses two generated static optical variants, with explicit
initial phase and trigger polarity in `plant.chopping`. AOS owns the completed
exposure's fringed/unfringed classification. RTC publishes that classification
as Acquisition Version 3 and uses the aligned model-window ordinal for chopped
Header/acquisition sequence. A source-and-adapter CPU test emits AOS counters
1/2 at model PTS 0/30 ms for 10 ms exposures and proves wire identities 1/4.
Missing complete exposures therefore cannot form an adjacent pair. Optical kind
is never inferred from those counters. Ordinary LLOWFS Version 2 and sequence
behavior are preserved.

The retained SCC measurement prefix is full-image PixelSelection, finite-only
PixelValidity, strict-identity ChoppedImageDifference and SccPixelResidual.
Calibration executes that same prefix for static F/U push/pull and held-out
pairs. A newly measured SCC reconstructor and real flat F−U FITS parameter are
published with flat-image diagnostics; frontend subtraction makes the modal
reference zero. Prefix identity and source chopping enter provenance. Old
ordinary-intensity bundles, changed polarity/variant choices and changed
publication prefixes are rejected. No carrier/FIR/ROI or remote phase-command
feedforward is selected. Static calibration does not establish rolling-loop
stability or simultaneous noisy-loop acceptance.

The FGP opt-in preparation API executes an explicitly labelled unpublished
F/U/F sequence: exact `SccPixelResidualIncompletePair`, then two successes with
required outputs. Its `finally` reset clears pair history and availability.
JFG's documented retained last-product metadata remains inspectable; it is not
publication evidence. The native callback regression proves the first real F
cannot use warmup history, real U completes with Version 3 acquisition identity
and Header PTS, a missing window re-primes, and reset re-primes again. This uses
native buffer callbacks without connecting a node or starting a core.

The complete FGP source suite also exits 0 with 2,238 assertions across 103
testsets and `FGP_NO_GPU_IMPORTS_PASS` in `/tmp/cal2-chopped-fgp-full.log`.
Its validation-only environment copies the existing source QA environment and
adds direct access to the already installed ForwardDiff 1.4.6 test dependency;
the manifest's package closure and frozen application environments are unchanged.

Focused CPU evidence, all with no CUDA/AMDGPU imports:

- RTC cold owner/warmup authoring: 123 assertions;
  `/tmp/cal2-chopped-rtc-cold.log`.
- Authored/generated variant parsing: 75 assertions;
  `/tmp/cal2-chopped-source-variants.log`.
- Actual AOS owner preparation and model-window adapter: 40 assertions;
  `/tmp/cal2-chopped-owner-preparation.log`.
- FGP ordinary/labelled preparation and native callback: 73 assertions;
  `/tmp/cal2-chopped-fgp-native-callback-r3.log`.
- Exact-prefix signed calibration, typed flat-difference publication, prefix
  tamper and old-selection rejection: 51 assertions;
  `/tmp/cal2-chopped-calibration-final.log`.
- Ordinary optical publication: 18 assertions; bounded optical/numerical
  regressions: 95 assertions; ordinary materialization: 20 assertions; feedback
  preparation: 70 assertions. Logs are
  `/tmp/cal2-chopped-publication-existing.log`,
  `/tmp/cal2-chopped-optical-regressions.log`,
  `/tmp/cal2-chopped-materialization-feedback.log` and
  `/tmp/cal2-chopped-feedback-r2.log`.

The first metadata-reset assertion was rejected as stricter than JFG's public
contract; no JFG implementation change or release is required. A native callback
test also stopped decoding unavailable output metadata and now checks the
publication flag first. The first feedback regression exposed an assumed
`plant` field in legacy ordinary test data; absent chopping remains the ordinary
case and the existing 70 assertions pass. Instrument formatting and whitespace
checks pass. Independent review of this candidate is recorded when complete.
The initial software checks precede the full-sampling chopped acceptance below;
no completed live chopped cohort is claimed.

The first full-sampling calibration attempt was interrupted before publication
after about 18 minutes compiling frontend-identity serialization. The retained
stack identifies JSON/StructUtils generated-field compilation after
`canonical(AbstractVector)` converted the million-pixel mask to a tuple. The
shared canonicalizer now maps arrays without encoding their length in the type,
preserving the prior serialized JSON identity bytes. Nine focused checks cover
ordinary JSON hash parity, a full million-pixel mask, last-pixel sensitivity and
snapshot ownership; they complete in 0.7 s. This was a software scaling failure,
not a failed numerical gate. Final post-fix QA is recorded separately below.

The metadata-version audit also found that both offset receivers still selected
HIL's default Version 2, while the chopped SCC controller forwards Version 3.
The receiver now accepts an explicit per-branch `acquisition_version` of 2 or 3,
defaulting to 2; unsupported values and types are rejected. The authored SCC
receiver selects 3 and LLOWFS selects 2. The same cold selector fails before the
change and passes 29 assertions afterward. The existing four-scenario native
private receiver test passes 147 assertions, including 20 new checks of actual
Version 3 trigger receipts, identity/model time and SCC adoption alongside
Version 2 GPI/LLOWFS streams. This tests real metadata transport without starting
an instrument session. Logs are `/tmp/cal2-chopped-offset-v3-before.log`,
`/tmp/cal2-chopped-offset-v3-cold.log` and
`/tmp/cal2-chopped-offset-v3-private.log`; the last asserts no GPU imports.

Pre-canonical-fix RTC source QA exits 0 with 7,675 assertions across 317 testsets and
`FULL_CORE_NO_GPU_IMPORTS_PASS` in `/tmp/cal2-chopped-rtc-core-final.log`.
Relative to the preceding 7,517-assertion run, nine new testsets add 81 assertions,
the concurrent snapshot loop increases from 124 to 199, and the named deployment
source-closure checks add two. No previous testset is omitted. This includes the
runtime warmup owner source at SHA-256
`319558c2b2fc2bc1d4da2c213f19e4bf9ab072b63f4dd7b746eacdedc33811a4`.
The first full-suite attempt stopped on an unqualified `include` in the isolated
capture-test module; the owning test now uses `Base.include` and the final run
passes. The initial Git missing-object stderr is the unchanged negative test in
`test_configuration_store.jl`, which deliberately removes a loose object and
expects retrieval to fail.

The final post-canonical-fix RTC source run passes 7,687 assertions across 319
testsets, exit 0 with `FULL_CORE_NO_GPU_IMPORTS_PASS` in
`/tmp/cal2-chopped-rtc-core-canonical.log`. The two canonical testsets add nine
assertions, and concurrent snapshots increase from 199 to 202. No prior testset
is omitted. This validates the frozen feature snapshot before upstream integration.

## RTC 0.2.38 merged release checks

The isolated release integrates feature commit `db87604` with registered RTC
0.2.37 (`cbb5704`) in merge `cca60893643db326a9d9a28b12c558448cef04b2`, tree
`61db0e4574b9b63f3d080e465d2ba7613128799e`. The resolution preserves upstream
generated HIL optics, contained authored sources, receipt validation and authored
prescription identity, alongside strict standalone variant descriptors and the
array canonicalizer. Independent review of the three overlapping source files
finds no confirmed defect.

The isolated source environment uses AOS 0.3.12, HIL 0.2.11, FGA 0.8.13 and FGP
0.1.16, with JFG 0.4.3 retained. Focused checks pass 680 assertions: cold metadata,
canonicalization, variant and export checks 452; generated-component output,
settings, identity and source/graph-byte tamper checks 79; chopped calibration
51; owner preparation 40; owner warmup 29; receiver validation 29. Logs are
`/tmp/cal2-rtc-0238-{cold,components,chopped,owner,warmup,receiver}.log`.

Final merged core QA passes 7,604 assertions across the same 319 testsets, exit
0 with `MERGED_FULL_CORE_NO_GPU_IMPORTS_PASS` in `/tmp/cal2-rtc-0238-core.log`.
No testset is omitted: the count difference from 7,687 comes entirely from the
concurrent snapshot loop changing from 202 to 119. These selectors import no
GPU module and start no instrument service. Frozen calibration worktrees and
application environments remain unchanged.

The fresh full-sampling chopped calibration at
`/tmp/cal2-chopped-optical-calibration-20261028-r2` publishes identity
`sha256:65f31bb7f44b94f6241dd9d144037cfce1d7f4b876a1bce2bd1415a2aa83a7f9`.
Both branch reports are accepted and deployable at the unchanged 5% gates,
using AMDGPU optical propagation and Host expected-reference acquisition.
`application_accepted` remains false. This establishes matched static calibration
on the frozen feature source; normal managed coverage, simultaneous noisy-loop,
physical-device and deadline qualification remain separate.
