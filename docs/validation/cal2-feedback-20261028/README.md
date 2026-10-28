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
