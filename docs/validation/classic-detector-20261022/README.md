# Classic detector reproducibility investigation — 2026-10-22

This record separates a controlled CPU reproduction from the unresolved cause
of an earlier exact-ADC comparison failure. It preserves compact scripts,
result records, logs, FFTW wisdom and retained plan descriptions. The large
captured ADC, photon-rate and wavefront binary arrays remain in the raw
evidence directory at `/home/dgamroth/workspaces/codex/worktrees/classic-detector-20261022/`.
That directory is retained data, not a Git worktree. The copied experiment
scripts were executed from that raw directory; their `@__DIR__` references
expect the omitted binary inputs there. They are not standalone reproductions
when run inside this compact bundle.

## Controlled detector comparison

The independent detector replay compares `FFTW_MEASURE` and `FFTW_MEASURE |
FFTW_NO_SIMD` with the same RNG state and the same normal draw at one pixel.
The input photon rates differ by 0.0625 photon/s: 802437.0625 versus
802437.125. The high-count photon-noise sampler rounds to 438 versus 439 electrons, moving the
sampler argument across a half-integer boundary. The ADC value changes from
305 to 306. Each replay reproduces its retained full ADC frame, and swapping
the target rate reproduces the opposite full-frame result. This establishes a
controlled mechanism for this comparison; it does not establish the cause of
the historical failed run.

A separate frame-10 counterfactual lowers one rate by one Float32 ULP,
325130.3125 to 325130.28125, while preserving RNG state and normal draw. That
moves the sampled photon count from 165 to 164 and changes one ADC value from 110 to
109. The other ADC pixels remain identical. This demonstrates sensitivity to
a one-ULP input change. The original failed run's FFT plans and photon-rate
arrays were not retained, so this counterfactual cannot prove its cause.

Seven CPU probe variants are retained under `variants/`: `measure-a`,
`measure-b`, `measure-c`, `estimate`, `nosimd`, `nosimd-b` and `reverse`. Each
has its result record, run log and FFTW wisdom; selected frame RNG-state
receipts are included where captured. These probes help compare planner
choices under the saved inputs. They are not a reconstruction of missing
historical inputs.

FFTW documents that `FFTW_MEASURE` and `FFTW_PATIENT` select algorithms using
runtime measurements and may give slightly different results between runs;
saved wisdom or `FFTW_ESTIMATE` makes the selection deterministic for a given
environment. See [FFTW FAQ, question 3.8](https://www.fftw.org/faq/section3.html).
This supports controlling plan provenance when comparing
exact ADC output; it does not establish that planning caused the historical
discrepancy.

## Exact-plan oracle and managed replay

The test-only native owner witness exports the measured FFTW wisdom and the
descriptions of retained plans. The CPU oracle imports that wisdom, requires
repeated transforms to use `FFTW_WISDOM_ONLY`, and checks the retained plan
descriptions before replay. Its 11 precondition assertions passed; the log
is `managed-all-plans/oracle-preconditions.log`. This constrains the oracle to a matching
FFT execution contract. Exact ADC comparisons remain exact; no ADC tolerance
was added.

The final managed CPU replay (`managed-all-plans/`) passed 1,027 of 1,027 assertions over two 32-frame
generations, with reset and restart and completed cleanup. The retained
generation observations and combined wavefront result show exact detector
and controller replay, matching pupil masks and acquisition identity/PTS, and
wavefront pixel error no greater than 1.5258179359989299 × 10⁻⁵ nm against a
0.0001 nm check threshold. The GPU audit lists no GPU libraries. These are
finite CPU simulation and software-test results; they do not establish
cadence, latency, GPU execution, hardware behavior or qualification.

The preliminary `managed/` run also passed, but its 15-path plan inventory
skipped plans stored in the atmosphere-layer vector. Final review caught that
coverage defect. The corrected traversal skips numerical buffers and inspects
bounded owner collections, with negative tests for missing/changed nested
plans and collection bounds. The final 20-path witness includes all five
atmosphere transforms; retained plan descriptions are checked before replay.
`WISDOM_ONLY` constrains repeated WFS transforms, while ordinary atmosphere
planning retains its existing behavior and is checked through that inventory.

No production AdaptiveOpticsSim or RTC implementation, gains or tolerances
were changed for this investigation. The historical failed wavefront-series
record remains unchanged. The [independent review](../../reviews/20261022-classic-detector/REVIEW.md)
accepts this finite matching-plan gate and preserves the historical uncertainty.

## Generic charts and live CPU deployment

GUI commit `758a6b3e5bb8dd252167cd070d7859c021917938` adds ordinary mouse-wheel
zoom about the pointer, a shared cursor reporting the nearest actual sample
for all enabled channels, and generic ndarray source/channel selection in
Settings. Exploratory source overrides use Header PTS rather than inheriting
the original source's model period. History and runtime input contracts clear
on source replacement; changed schema/type/layout/rank/shape requires explicit
acceptance through Reload source. No instrument renderer or scientific WFE
calculation was added to the GUI.

The GUI software checks pass 847 Rust assertions (564 library, 271 binary,
12 integration; 16 opt-in tests ignored), including 20 focused chart checks,
and 151 Julia assertions. WASM/browser checks pass. Wheel/cursor regressions
have fail-before evidence. Strict Clippy still fails on existing Rust 1.99
`chunks_exact_to_as_chunks` and atomic deprecation warnings; allowing only
those existing lint classes passes. The build receipt, logs and actual
Glow-only eframe fingerprint are in `gui/`.

Classic app adds the closed-by-default Charts group with
DM command and WFS slope histories. Exact source/schema/channel declarations
pass the GUI's real TOML parser; all 44 sealed application assets remain valid.
The view file and README artifact hashes change. Scientific inputs, package locks,
controller parameters, calibration and simulation configuration are unchanged.
The GUI's live profile preserves its existing session-label filter.

The CPU RTC `pipewireao-session@e0592e2d878f.service` remains running with its
original simulator/RTC PIDs; only the GUI was replaced. `live/` records at least
eight fresh sequences each from demanded DM commands, WFS slopes and WFS flux,
with exact negotiated schemas, finite samples and valid Header/acquisition
identities. The new GUI PID is 1378246 and its installed binary SHA-256 is
`6bc15b26647b552fd6cd1171935a6537c915bfd9e9b53248f851453b9989b2d3`.
It uses Mesa EGL/llvmpipe. The six-role audit records no GPU device handles,
CUDA/HIP libraries or listed hardware graphics libraries. No live rendered
screenshot or manual interaction claim is made; chart interactions are covered
by software tests. The first GUI restart attempted to start a collected
transient unit; recreating that exact GUI unit succeeded, without restarting
the RTC or simulator. The task's Rust build cache was removed after the
standalone binary handoff.

## Retained files

- `independent_detector_causal.jl` and `counterfactual/` preserve the detector
  replay code, controlled comparison records and frame-10 counterfactual.
- `prepare_probe.jl`, `variants/` and their FFTW wisdom files preserve the
  planner variants and compact outputs, without the large sample arrays.
- `prepare_managed.jl` and `managed/` preserve the preliminary run setup and
  its incomplete inventory. `managed-all-plans/` preserves the corrected helper,
  precondition checks, final witness, launch/reset/shutdown/GPU audit and
  two-generation observations/replay receipts. The maintained
  `test/integration/prepare_classic_wavefront.jl` is the reusable preparation tool.
- `SHA256SUMS` covers every other file in this directory.
