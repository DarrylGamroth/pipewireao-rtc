# Live residual wavefront diagnostic: independent review

Date: 2026-10-22. Status: reviewed numerical, packaging, finite managed reset/replay and live CPU/GUI-subscription gates passed.

## Scope and disposition

No blocking finding remains for the reviewed CPU diagnostic scope. The corrected finite two-generation managed test passes 716/716 with unchanged exact detector assertions, wavefront pixels/RMS/identity checks, native Reset and clean shutdown. The sealed application and subsequent live CPU cutover/GUI subscription are verified below. The prior two detector mismatches remain unexplained historical evidence (WF-005), not a proven production root cause. The new product presents an owned simulator pupil-OPD snapshot; it neither reconstructs wavefront from measurements nor changes scientific state or commands. No rendered-screenshot, GPU, hardware, sustained-cadence or worst-case-latency qualification is claimed.

Reviewed RTC worktree: `/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-wavefront`, branch `codex/live-wavefront-20261022`, base `94d8c63fdc6a2d2b62d0056a62475d3b505e9b2a`. Reviewed application worktree: `/home/dgamroth/workspaces/codex/pipewire/revolt-classic-rtc-wavefront`, base `b0637ac3e61e339dfc1fed8bbd3600c83a69bcff`. The relevant changes are `ext/aos/optical_observation.jl`, `test/aos_optical_observation.jl`, and the instrument's declarative source, queue, link, ownership and operator-view additions. The reviewer owns only this review artifact and did not operate services or GPUs.

The review used repository `AGENTS.md`, `docs/README.md`, the current roadmap and the affected authority boundaries: RTC-ARCH-026, RTC-DEV-006 optional observation and the AOS/HIL ownership section in `docs/architecture.md`. Scientific execution remains in the existing AOS graph, transport remains in HIL/PipeWireAO, the headless RTC remains lifecycle owner and the GUI remains an optional observer.

## Numerical semantics

Let P be the declared telescope's Boolean pupil mask and qᵢ the snapshot pupil OPD in metres. For N transmitting samples, the new image is:

```text
μ = Σᵢ∈P qᵢ / N
wᵢ = 10⁹ (qᵢ − μ) nm,  i ∈ P
wᵢ = NaN,                i ∉ P
RMS = √(Σᵢ∈P wᵢ² / N)
```

`form_wavefront!` accumulates piston in Float64, subtracts in Float64, converts metres to nm and stores Float32 output. It validates matching axes, a nonempty transmitting mask and finite OPD on that mask. Nonfinite off-pupil inputs are excluded and overwritten with NaN. Input OPD and the graph output are not modified. Only piston is removed: tip and tilt remain. Weighting is uniform per transmitting sample, matching the existing CPU replay metric; this is not amplitude- or irradiance-weighted RMS.

The actual telescope configuration supplies the mask, including the central obstruction. The image is 480 × 480 in the reviewed Classic application; the generic source derives its dimensions from the prepared telescope. The schema `org.calculon.ao.residual-pupil-opd.nm.f32/1` declares the quantity and units. There is no extra reflection factor of two: the source already represents OPD, not mirror displacement.

The existing GUI's `src/array_display/measurements.rs` computes raw statistics over finite samples and defines RMS as √(Σx²/N). Therefore NaN outside the pupil excludes those pixels from the denominator, and the configured whole-image RMS reports the intended pupil quantity in nm, subject to Float32 output rounding. The generic colormap also excludes nonfinite values. No specialized GUI wavefront calculation is needed or introduced. A future query-region readout would describe that region's already globally piston-removed samples; it would not independently refit local piston.

## Snapshot, generation and bounded ownership

`Observation` adds one preallocated host Float32 wavefront matrix and the fixed pupil mask to the existing optional optical worker. `form_products!` obtains focal intensity and the new wavefront from the same retained graph-output snapshot. `process_sample!` stages each with the same snapshot sequence, original WFS PTS and acquisition generation, then releases the snapshot in `finally`. A sample with a stale generation is rejected before formation. Completion accounting occurs after releasing the slot.

These two publications are separate staging operations, not an atomic pair. HIL may drop either optional image independently. Their metadata identifies their common originating sample when both are observed; the implementation does not guarantee paired delivery or simultaneous GUI display.

The unchanged HIL 0.2.2 image source accepts Float32 NaN payloads, copies them into owned storage and serializes matrices to row-major transport. Its staging call rejects stale generations and unavailable buffers without waiting for an observer. Each source has a bounded pending snapshot and three prepared transport buffers; image callbacks use the existing independent image loop. The instrument adds a capacity-one `copy`/`drop-oldest` queue behind the new source. The GUI binds the queue output, rather than attaching to required controller dataflow.

The added two-pass O(N) mask conversion runs in the existing optical worker, sampled at most once per 50 ms of wall time. It does not add an FFT, controller operation, model-time advancement, service owner or native callback computation. Sharing the worker means a slow focal calculation can delay the wavefront product; its nominal 20 Hz declaration is not a latency guarantee. The inspected implementation introduces fixed image storage and copy cost, but no measured resource or deadline claim follows from source inspection.

Reset ordering was checked in `ext/PipeWireAORTCAOSExt.jl`: the owner drains/stops the optional worker before resetting the HIL graph, updates the generation, then rewarms observation. Rewarming clears all optional image pools, including the new one. Thus the added image follows the existing generation/reset lifecycle rather than introducing another reset authority. Worker errors remain contained in optional observation during ordinary execution; the existing preparation/rewarm validation can still reject startup/reset if configured optical observation cannot initialize. Neither product participates in the mandatory frame-command exchange.

## Evidence inspected

Raw evidence root: `/home/dgamroth/workspaces/codex/worktrees/live-wavefront-20261022`.

`optical-tests-final.log` records 60/60 passing assertions: nine direct conversion assertions and 51 shared-optical-product assertions. The tests cover piston/shift behavior, nm scaling, RMS equivalence, excluded pixels, source immutability, invalid mask/input rejection, both product declarations, and four real CPU graph snapshots with sequence/PTS/generation checks. They assert that no CUDA/AMDGPU/GPUCompiler module or matching GPU runtime library is loaded.

The test environment is explicitly created from the pinned instrument environment with a local RTC development override; this is source-validation evidence, not the final released application package. The reviewed script uses CPU science with AOS 0.2.2 and HIL 0.2.2 and does not connect to a live RTC. The focused tests call product formation and snapshot metadata directly; they do not establish actual image transport, stale-pool rejection across a live reset, GUI attachment, observer stall/disconnect behavior or a published image's sample identity. Final evidence must keep those distinctions explicit.

A later source cleanup at commit `61fcdf6` factored source properties into a local variable but passed `properties` positionally after keyword arguments. The private 0.2.2 candidate failed `registered-optical-tests.log` during source declaration. Explicit `properties=properties` on both constructors fixes the call; `corrected-optical-tests.log` records the corrected source passing 60/60 again. The failed private candidate is retained. The corrected private package is 0.2.3 at commit `fc52a699` (tree `07c4146c0e62d318b369d2fc55fbdbfc022e310c`). A separate initial `classic_wavefront.jl` import failed to parse `==@__FILE__ &&`; parenthesizing `(@__FILE__)` fixes it, and the import check now completes without starting services. Neither failed check is live deployment evidence.

`registered-final-tests.log` also records 60/60 passing against the corrected registered candidate, closing the distinction between the earlier development override and the final optical-product implementation.

The next managed attempt (`managed-final/`, before `managed-spa/`) failed during core startup, before scientific owners started. `core-start-failure.log` records the native `parse_modules()` malformed-object-array error for the compact JSON `context.modules` representation, followed by missing `spa-node-factory` and context creation failure. Its `final-launch.json` records `service_result = exit-code` and `cleanup_complete = true`. The failed input remains in `core-compact-failed.conf.in`. The correction uses the existing `ScienceExport.write_spa_config` generator to write native SPA-JSON; no native PipeWire parser or public API is changed. `offline-spa.log` records 71/71 passing offline checks. The reviewer independently parsed the new core file and compared it with the application base: all previous keys/modules are unchanged, with exactly one appended capacity-one copy/drop-oldest wavefront queue.

Independent application checks after this correction found `simulation.conf`, `graph.conf`, `parameters.conf` and `calibration-result.toml` byte-identical to the base, as are every file under `artifacts/`. The default remains CUDA and the existing scientific parameters/calibration are preserved. The sole changed resolved dependency is PipeWireAORTC, from 0.2.1 to 0.2.3 with tree `07c4146c0e62d318b369d2fc55fbdbfc022e310c`; the project change is the corresponding compatibility pin. Parsed deployment changes are limited to artifact hashes and new node ownership; parsed session changes are limited to the appended source, sink and link. The operator profile adds the wavefront view. The `cpu-application-spa` variant retains CPU execution for integration testing.

The new `test/integration/classic_wavefront.jl` captures two 32-frame CPU generations with native Reset between them, compares detector/controller replay, compares every observed masked wavefront against the same graph frame, and verifies RMS, PTS and acquisition identities. `classic_observation.jl` adds optional stream declarations and a payload validator while retaining the original all-finite default. The wavefront-specific validator rejects infinities but permits NaNs; scientific replay then verifies their positions against the actual pupil. These hooks do not change observer queue capacity or loss policy. The reviewer rechecked both initial oracle corrections below in the final source.

`managed-spa.log` preserves a later failed run: 326 assertions passed, 31 failed and one errored. Generation one delivered 31 wavefront images with passing mask, scalar RMS and identity comparisons, but the pixel check used array `isapprox(atol=1e-4)`, whose aggregate norm does not express the intended per-pixel bound. The corrected check explicitly requires maxᵢ|observedᵢ − expectedᵢ| ≤ 10⁻⁴ nm and records the measured maximum; the scalar RMS tolerance remains unchanged.

The same run's second observer attached while held and consumed a retained prior-generation display-queue sample, then rejected the legitimate new generation under its ordinary single-generation policy. The correction queries the source's current generation before attachment and passes it as `expected_generation`. The helper discards older generations before storing payload, header or counters; missing or future generation metadata fails. The native buffer is returned through the existing `finally` path. Default observation behavior is unchanged. `prefix-tests-verified.log` records 3/3 masked-duplicate and 5/5 selected-generation tests passing. These are diagnostic-oracle corrections, not production changes. The original failed run remains preserved and does not count as a complete reset gate; the subsequent `managed-verified` discrepancy and final passing run are recorded in WF-005.

`managed-reset-oracle.log` records the final finite gate passing 716/716. Its `wavefront-result.json` contains two 32-frame generations, each with 31 observed wavefront samples (sequences 1–31), no detector differences, exact controller replay, correct pupil mask, matching acquisition identity/PTS and maximum pixel error 1.5258179359989299 × 10⁻⁵ nm, below the retained 10⁻⁴ nm bound. The missing sequence-32 optional image is permitted by the bounded drop semantics and is not described as observed. The reviewer independently SHA-256 compared retained detector, demanded and wavefront arrays across generations: each corresponding pair is byte-identical. The native Reset reply is successful and Ready; Quit is accepted; `final-launch.json` records service success and complete cleanup. GPU audit mappings are empty for all five owners. The receipt binds selected calibration `1837924beaf3a198726c096cfc3922d30529935be3f73974a1979169cb2962e4` and application manifest `ea2a4be5e665b42ccbec7947985de1f8008e5171d90dcc71cd13986432fc40ac`.

## Final live CPU acceptance

The promoted application is `4c8cf50b55cd97b96f423254988867c91caf93a8`, with private RTC 0.2.3/tree `07c4146c0e62d318b369d2fc55fbdbfc022e310c`. Live evidence is retained under `/home/dgamroth/.local/state/pipewireao/classic-cpu-wavefront-live-20261022`; the launch and checking scripts/logs remain under the raw evidence root. The launcher creates a separately sealed CPU copy, requests 10 Hz wall pacing, clears GPU visibility, and configures software GUI rendering. It shuts down the previous CPU session through the existing lifecycle API, verifies complete cleanup, and starts the replacement. `previous-session-final.json` records service success and complete cleanup; the replacement `status-verified.json` records Running. The source application's CUDA default remains unchanged.

`live-wavefront-check.json` records 16 consecutive images at generation 1, sequences 507–522, with increasing PTS, the expected 480 × 480 schema/shape and selected calibration identity. RMS ranges from 42.05637265586493 to 48.11913580443939 nm; residual mean piston is below 4.6 × 10⁻⁹ nm in magnitude. The reviewer inspected the check script: it selects the acknowledged generation, requires finite values on the actual configured pupil, NaN everywhere else, and computes RMS from those finite raw samples. Independent recomputation from `live-wavefront.bin` exactly matches every recorded RMS. Each image has the same 173356-sample finite mask as the validated managed wavefront capture.

The checker identifies the actual wavefront queue-to-GUI link, rather than inferring subscription from an unrelated GUI process. Independent inspection of `live-graph.json` confirms one active GUI link with the wavefront schema, Float32 row-major 480 × 480 format and no link error. This supports GUI subscription, not a claim that a rendered screenshot was inspected. `live-gpu-audit.json` records empty GPU runtime mappings and device-handle lists for the controller, parameter owner, simulator, RTC, core and GUI. The reviewer read retained evidence only; it did not change services or use a GPU.

## Findings and remaining gates

### WF-001 — Shared origin does not imply atomic delivery

Severity: informational. Confidence: high, from the two staging calls and independent HIL source pools. Affected code: `OpticalObservation.process_sample!` and `source_options`.

Disposition: accepted property of bounded optional observation, not a defect. Describe products as sharing snapshot metadata; do not claim every focal image has a matching delivered wavefront image. Any numerical live comparison must match sequence and generation, rather than compare whichever two frames are latest.

### WF-002 — Final release and live acceptance evidence

Severity: acceptance gate, not an observed implementation defect. Confidence: high in the scoped recorded evidence.

Disposition: closed for the reviewed packaging, finite CPU transport/reset/replay and bounded live CPU/GUI-subscription scope. The 71/71 offline check, registered 60/60 optical checks, 716/716 finite integration gate and final live evidence above support that conclusion. Numerical mask, RMS, acquisition identity/PTS and native Reset are supported by the finite managed evidence; the live window independently confirms valid wavefront images and an active GUI subscription. Observer independence is supported by the reused bounded design; additional stall/disconnect claims require corresponding observations. No rendered screenshot, GPU, hardware, cadence, worst-case latency or controller-performance qualification is established.

### WF-003 — Identical masked-image duplicates fail ordinary equality

Severity: medium for the new integration oracle; no production defect identified. Confidence: high from source semantics. Affected code: `ClassicManagedReplay.PrefixCapture` reused by `classic_wavefront.jl`.

The duplicate-sequence path uses array `==` to compare an earlier payload with a repeated one. A valid wavefront necessarily contains off-pupil NaNs, and NaN does not compare equal to itself under `==`. An identical repeated wavefront can therefore be incorrectly rejected as a changed payload. This was identified statically before relying on the new live result.

Disposition: corrected. The retained-payload comparison now uses `isequal`. `test/integration/prefix_capture.jl` checks initial capture, acceptance of an identical masked duplicate, and rejection of a changed finite value; `prefix-tests.log` records 3/3 passing. This accepts NaN equality and preserves exact comparison of finite values (including signed-zero distinctions).

### WF-004 — Identity equality alone permits missing metadata

Severity: medium for the new integration claim. Confidence: high from source inspection. Affected code: `ClassicWavefront.replay` and the selected observation streams.

The expression `wavefront.identity == detector.identity == demanded.identity` can pass when all three identities are `nothing`. The observation helper intentionally permits missing acquisition metadata for some ordinary products; its four-WFS-stream identity gate is not enabled by the selected detector/demanded/wavefront set. Equality alone therefore does not establish the receipt's shared-acquisition-identity claim.

Disposition: corrected and exercised in the passing finite managed run. Replay uses `something` on all three identities, rejecting absent metadata, checks the expected sequence and source generation, and then compares identities. The caller passes the captured source snapshot generation to each replay. Cross-reset stale-image rejection is therefore an explicit test obligation. These are acceptance-oracle changes; the inspected production image source already supplies the metadata.

### WF-005 — Two exact detector replay comparisons remain unexplained

Severity: historical reproducibility discrepancy; current exact replay gate passed, no production root cause established. Confidence: high in both the earlier failures and final passing evidence, insufficient evidence for causation.

`managed-verified.log` records 714 passing and two failed assertions, both exact UInt16 detector-frame comparisons over two 32-frame generations. Controller replay, observed wavefront pixel errors, RMS, mask, sequence/PTS and generation checks passed; the maximum recorded wavefront pixel error is approximately 1.526 × 10⁻⁵ nm. The run shut down cleanly, but did not pass the full gate. Raw captured arrays were not retained, so the failing pixel coordinates and magnitudes cannot be reconstructed from its truncated assertion output. FFT plan/rounding variation remains a hypothesis, not an established explanation.

The previous harness constructed a fresh direct science oracle for each generation. Preparing one oracle and calling the public `reset_hil_boundary!(boundary, driver)` between generations better matches the live owner's reset semantics, including retention of FFT plans. Set the same one-thread FFT/BLAS preparation policy as the existing managed reference. This removes one uncontrolled difference between direct generations; it does not guarantee identical plans between independent live and direct preparations.

Disposition: exact detector replay gate passed in `managed-reset-oracle` without weakening its assertions or changing production science. The corrected harness sets FFT/BLAS threads before preparation, prepares one direct science oracle and resets it between generations, retains captured arrays before replay, and records detector mismatch details if present. Both final generations have empty mismatch lists; all 716 assertions pass. Its detector equality field now derives from the measured difference list. Controller equality remains asserted separately, so the overall testset result remains authoritative for that part of the combined field. Prior per-generation booleans remain subordinate to their failed test logs.

The old mismatches' initiating cause is still unconfirmed because their raw frames were not saved; the later success does not prove FFTW caused them. The final captured detector/command/wavefront arrays are identical across reset, establishing repeatability for this prepared live instance. If exact cross-preparation reproducibility later requires investigation, compare fresh and reused direct oracles offline using the retained inputs and preserve prequantization frames and FFT plan descriptions. Near-half-integer values alone do not establish what the earlier live prequantization values were. No speculative production change or tolerance relaxation is justified by the available evidence.
