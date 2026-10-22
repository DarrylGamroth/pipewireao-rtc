# Independent wavefront RMS series review

Review date: 2026-10-22. Scope: the shared optional optical producer and its CPU tests, against RTC base `1e13ecfa8c18718fad2a5a3ebf8c0f57e6d6db40`, in branch `codex/wavefront-series-20261022`. The worktree already contained implementation, test, dependency and documentation edits; this reviewer owns only this repository file. Follow-up analysis also created the three explicitly authorized offline Julia experiments described below under the raw evidence directory. No services, GPU work or builds were started by this review.

Disposition: accept the scoped CPU diagnostic and final live subscription evidence; no remaining blocker within this review's scope. WS-001 is corrected and WS-002 is closed. The original managed suite remains failed, 1024 passes and 2 failures; independent verification of its retained capture and a controlled analysis-on/off experiment support this narrower acceptance, with the unresolved reference discrepancy retained in WS-003. The initial GUI GPU audit failure and corrected deployment are retained in WS-004. This is not a claim that strict Clippy passed, a rendered live screenshot was inspected, cross-preparation bitwise identity was established, or timing/GPU/hardware qualification was completed.

## Numerical meaning and ownership

The new `org.calculon.ao.pupil-opd-rms.nm.f32/1` product is a Float32 array of shape `(1, 2)`: wire channel 0 is uncorrected atmosphere RMS and channel 1 is corrected pupil RMS. For either OPD array x in metres, with P the actual transmitting pupil, the calculation is:

```text
μ = Σ(i ∈ P) xᵢ / |P|
RMS_nm = 10⁹ √[Σ(i ∈ P) (xᵢ − μ)² / |P|]
```

`pupil_rms_nm` uses Float64 Welford accumulation and rounds the final result to Float32. The population denominator is correct; pupil piston is removed and tip/tilt remain included. Both channels use the same Boolean pupil mask and uniform spatial weighting, not flux weighting. Off-pupil nonfinite values are excluded; nonfinite transmitting samples and empty pupils are rejected. There is no additional mirror-surface factor of two because the input quantity is already OPD.

The atmosphere reference is an atmospheric contribution, not a universal counterfactual that includes arbitrary static aberrations. This distinction must remain explicit in the schema documentation. In the inspected Classic graph, the atmosphere feeds the pupil composition directly. In `GPI2Sim.jl/src/graphs.jl`, atmosphere precedes the woofer, while `:pupil_opd` follows woofer, tweeter and tip/tilt composition. Thus the producer does not assume a single mirror. This GPI conclusion is source analysis, not a GPI runtime validation. Preparation still requires exactly one declared guide sensor.

The scalar pair is computed in the existing optional analysis worker, independent of GUI attachment. The existing 50 ms admission interval limits attempted sampling to at most 20 Hz of wall time; it is not a guaranteed delivery cadence or the simulation sample rate. Two values within one RMS payload share an acquisition identity. Focal, residual-image and RMS endpoints stage independently and may drop independently; their delivery is not an atomic three-stream transaction.

## Cohort, faults and reset

Reviewed `ext/aos/optical_observation.jl` against the released AOS snapshot phase protocol in `AdaptiveOpticsSim/lMUpG/src/algorithm_graphs/output_snapshot.jl` and the RTC source/reset call sites. One science producer captures both graph outputs before advancing the graph. Atomic busy admission remains held until the consumer has released both snapshots. A consumer polling between the two submissions cannot obtain a complete cohort until both are ready; metadata equality is checked before products are formed. The atomic snapshot phase publications retain the existing transfer ownership and visibility protocol.

Partial admission or transfer failure retains ownership until cold drain rather than reusing one slot. The source marks observation failed without propagating the optional failure into science processing. Reset stops and joins the worker, attempts reset of every retained snapshot, then clears busy; the surrounding owner drains observation before resetting the scientific graph and rewarms it afterward. Close similarly attempts all snapshots. These are source-derived conclusions plus the focused CPU fault test below, not an exhaustive concurrent schedule proof or injected GPU-transfer test.

Absence of a declared atmosphere output produces no RMS endpoint and no invented baseline; the original two image endpoints remain available. The actual flat-calibration preparation test exercises this path.

## Findings and gates

### WS-001 — Preparation must close both retained snapshots on failure

Severity: low, cold error-path ownership defect. Confidence: high. Disposition: corrected in the reviewed working tree.

The initial implementation's preparation catch closed the pupil snapshot first; if that close threw, the atmosphere snapshot close was skipped and the original preparation error was lost. The correction uses `finalize_snapshots!(close, tuple)` to attempt every close and retains the original error alongside a cleanup failure in a `CompositeException`. The focused regression injects a failure on the first operation and verifies that both operations were attempted. Fail-before behavior was established by source control flow; no real backend cleanup failure was reproduced. The regression tests the common cleanup helper, not every preparation exception branch.

### WS-002 — Final package, managed and live evidence

Severity: acceptance gate, not an observed producer defect. Confidence: high in the scoped recorded evidence. Disposition: closed with WS-003 and WS-004 limitations retained.

Reviewed the expanded CPU test source and `/home/dgamroth/workspaces/codex/worktrees/wavefront-series-20261022/optical-tests-expanded.log`: 16 presentation checks plus 82 shared optical checks passed, 98/98 total. Coverage includes independent `Statistics.std(...; corrected=false)` comparisons, metadata equality, rejection of a second admission, deliberately unavailable second snapshot, retention of the first snapshot after partial admission, drain/reuse, first-close failure, and actual atmosphere-free calibration preparation. The test also checks loaded modules and shared libraries for GPU runtime absence. This reviewer inspected the recorded run rather than rerunning it.

The registered RTC 0.2.4 tree is `742ec6818dcaf3d241bdd1d17f788997dfc9638f`; its producer and focused test files match the hashes below. `registered-optical-tests.log` also records 98/98. The managed integration retained exact detector/controller replay and added both RMS channels compared with direct same-sequence graph outputs, plus generation and PTS checks across Reset. `managed.log` records **1024 passes and 2 failures**, with both failures described in WS-003. Both generations captured 32 detector/command samples and 31 image/RMS samples; new RMS, image, mask, identity, generation and controller checks passed. Final-launch records successful service exit and complete cleanup, shutdown was accepted, and the recorded GPU mappings are empty. There is correctly no successful `wavefront-result.json` for that failed suite.

The final app is `dbf8af57b111cfa51dad1a8e8d31bbf93ff815e1`. Its diff from `4c8cf50` leaves `simulation.conf`, the scientific graph, parameters, calibration and FITS artifacts unchanged; the declared default CUDA selection is therefore unchanged. The live deployment selects CPU explicitly. The final offline preparation receipt records 71/71. GUI worker evidence in `gui/validation.txt` records 10 focused time-series tests, full native tests, browser/Wasm checks and parsing of the actual application profile. This reviewer inspected that evidence rather than independently repeating the GUI implementation review. Strict Clippy **failed** on recorded baseline `chunks_exact_to_as_chunks` warnings; the command allowing that lint and pre-existing deprecations passed. The exceptions are not a strict-Clippy pass.

Final live evidence is under `/home/dgamroth/.local/state/pipewireao/classic-cpu-wavefront-series-live-20261022`, with the checker and `check-live-glow-mesa.log` in the raw evidence directory. Reviewed `check-live.jl`, `live-rms-check.json`, `live-observation.json`, `live-identity.json`, `live-gpu-audit.json`, `live-graphics-audit.json`, `status-verified.json` and `previous-session-final.json`. There are 32 scalar pairs and 32 residual images, all matched by complete acquisition identity and PTS, sequences 8393–8424 in generation 1. The actual pupil mask, finite interior, NaN exterior and near-zero pupil piston were checked. Maximum disagreement between scalar corrected RMS and image-derived RMS was 1.6474811346256502e−6 nm. Mean sampled atmosphere RMS was 200.32607173919678 nm and mean corrected RMS was 48.35219466686249 nm. These are means over the stated sample window, not an overall performance or stability guarantee.

The RMS endpoint has the expected F32 row-major `(1, 2)` schema, and a live active link connects its queue to a GUI consumer. The application profile labels channel 0 `Uncorrected atmosphere`, channel 1 `Corrected`, and maps sequence to simulation time with the declared 0.002 s model period. The live checker verifies subscription and data, not rendered pixels; no live screenshot claim is made. Recorded status remains Running, while the previous session reports successful shutdown and complete cleanup. The live calibration identity remains `sha256:1837924beaf3a198726c096cfc3922d30529935be3f73974a1979169cb2962e4`.

The running GUI executable (PID 797504) independently resolved to `pipewireao-gui-630198f-glow`, SHA-256 `14dbfbc20c97ccc917c76bd0cfa354118ea667fa5828bfa87c0c645ed8c46aab`, matching the retained immutable standalone binary. Its recorded eframe dependency fingerprint enables Glow and excludes Wgpu. Curated `integration.json` identifies the same registered source, application and GUI, 44 sealed application artifacts and 26 unchanged scientific files. Final GPU observations are scoped as described in WS-004.

### WS-003 — Earlier fresh-reference ADC discrepancy remains unexplained

Severity: validation limitation; no confirmed new producer defect. Confidence: high in observations, low in any proposed mechanism. Disposition: retain the failed gate and accept the narrower diagnostic evidence below; do not claim the discrepancy is fixed.

In each managed generation, sequence 10 at row 276, column 189 was captured as 110 ADU while the original direct oracle returned 109 ADU. Each generation had exactly this one differing pixel. The reference HIL frame was already quantized to 109.0, so the final UInt16 transport conversion is not the difference point. Earlier CMOS quantization or seeded photon/readout noise sensitivity is not excluded. The Classic model uses `NoisePhotonReadout` with explicit RNG state; deterministic ownership does not eliminate floating-point sensitivity upstream of discrete decisions.

All raw evidence below is under `/home/dgamroth/workspaces/codex/worktrees/wavefront-series-20261022`. The reviewer executed three bounded offline scripts with Julia 1.13.2, one Julia thread, one BLAS thread and an explicit one-thread FFT-provider request, using CPU application manifest SHA-256 `d2754c6f27ac8285dac6f42c85946bb84df052f8f6e337dab0a0c61e35bcdea0`:

1. `independent-oracle-check.jl` prepared two independent CPU science owners, each followed by a public reset/replay. All four runs matched **every** captured ADC pixel across 32 frames, including 110 at the previously failing pixel. Frame-10 pupil, atmosphere and photon-rate arrays were bitwise equal across these preparations and resets; photon rate at the target pixel was 325130.3125 photons/s. Results and retained arrays are in `independent-oracle-check/`. These two preparations shared one process and may reuse FFTW wisdom; they do not exclude cross-process planner variation.
2. `independent-observation-invariance.jl` used one fixed prepared science owner and one prepared observation owner. Analysis-disabled replay and analysis-enabled replay after public reset had identical per-frame SHA-256 values for atmosphere, pupil OPD, photon rate and detector output across all 32 captured commands. Every enabled frame performed cohort capture and product formation, and source outputs were also unchanged immediately afterward. `independent-observation-invariance/result.json` records this causal noninterference check. It was synchronous and does not test native worker scheduling or transport.
3. `independent-retained-metrics.jl` independently verified the saved first-generation capture: **222/222 checks passed**, including exact ADC and controller replay, the actual pupil mask, 31 residual images and 31 paired RMS samples. Maximum errors were 1.5258179359989299e−5 nm per image pixel, 1.0537547723288299e−8 nm in image RMS, and 1.4646695547071431e−5 nm in either scalar RMS channel. Results are in `independent-retained-metrics.json` and its log. Detector, demanded-command, image and RMS binary files have identical hashes between the two native generations; identity/PTS validation remains the managed test's evidence.

All three offline result records have empty GPU-module and GPU-library lists. No assertion was weakened, production code changed, or native experiment repeated to obtain these results. Together they support correctness of the new diagnostic on the captured data and lack of numerical/RNG interference within a prepared owner. They do not turn the original failed suite into a passing suite or establish an FFTW root cause. AOS's maintained deterministic policy requires fixed inputs, seeds and single-threaded reference execution; repeated FFT preparation uses FFTW MEASURE on this host. The original oracle's photon-rate arrays and FFT plans were not retained, so that earlier discrepancy cannot be localized further from these artifacts. Cross-preparation bitwise reproducibility remains unqualified here.

### WS-004 — Initial GUI launch failed the GPU audit

Severity: deployment acceptance failure. Confidence: high in the failed check and final observed state. Disposition: corrected for the recorded final GUI process; preserve the failed attempt.

`check-live-gpu-failed.log` records rejection with `GPU use by gui`. The retained `gui/gpu-first-launch.json` records the actual initial observation of `/dev/nvidiactl`, `/dev/nvidia0`, `/dev/nvidia-modeset` and two DRM render nodes, plus loaded Vulkan drivers. Device opening/loading does not establish a GPU compute workload or measured interference. The GUI alone was stopped; the simulator remained CPU-owned. An intermediate launch restricted Wgpu to Vulkan/Lavapipe and passed its audit.

The final handoff diagnosis in `gui/glow-artifact-handoff-note.txt` identifies an artifact-copy error: a temporary Cargo integration test restored a dev-dependency-unified Wgpu binary at the normal executable path after the standalone Glow build, and that replacement was copied. This was not a new production Wgpu dependency or renderer source defect. The corrected handoff copied and stripped the executable immediately after the standalone build; its actual eframe fingerprint contains Glow without Wgpu. The final deployment uses that binary with OpenGL software settings.

The first Glow launch, PID 793236, passed the narrow compute-runtime/device-handle audit, but this reviewer independently observed `libEGL_nvidia.so`, `libnvidia-eglcore.so`, `libnvidia-gpucomp.so` and NVIDIA EGL platform libraries alongside Mesa EGL. The audit's CUDA/HIP regex does not cover those graphics libraries, so the result did not establish their absence. Mapped libraries alone do not demonstrate GPU rendering; the device-handle lists were empty.

The final wrapper additionally selects Mesa explicitly with `__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json`, retaining `LIBGL_ALWAYS_SOFTWARE=1` and `GALLIUM_DRIVER=llvmpipe`. After a GUI-only restart, final `live-gpu-audit.json` records empty CUDA/HIP runtime mapping lists and empty `/dev/nvidia*`, `/dev/dri/*` and `/dev/kfd` handles for all six owned roles. `live-graphics-audit.json` records Mesa EGL loaded and no listed hardware graphics mappings in final PID 797504. Independent read-only inspection of that process confirmed the exact binary hash, Mesa EGL mapping and absence of NVIDIA/Vulkan mappings in the inspected patterns. The accepted claim is CPU science, explicitly configured software rendering, and the recorded absence of current GPU device handles and specified runtime/vendor mappings. This is not universal proof about every library or past/future launch, or a hardware execution qualification.

## Reviewed source identity

At this review checkpoint, SHA-256:

- `ext/aos/optical_observation.jl`: `4d628c4fe511c6f693c933d75237838ef9b966dac92ce7b5daa479b89bfb2956`
- `test/aos_optical_observation.jl`: `01561be8c4b301468bce95e1fa6a640bc2a80c1c81aacaccb85e0dd262275e27`

Production source changes after this checkpoint require reassessment of the affected conclusions. No controller coefficients, scientific plant equations, AOS/HIL implementation or native transport APIs were changed in the inspected producer diff.
