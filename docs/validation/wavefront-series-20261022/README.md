# Wavefront time-series validation evidence

This directory preserves compact evidence for the generic pupil-wavefront and time-series work dated 2026-10-22. Raw captures and local test applications remain at `/home/dgamroth/workspaces/codex/worktrees/wavefront-series-20261022`; the Julia analysis scripts here retain references to those raw inputs. Task Git worktrees are merged and removed after validation. Binary captures, installed package trees, generated GUI bundles, and screenshots are intentionally excluded from this bundle.

## Headless package evidence

`logs/optical-tests-expanded.log` and `logs/registered-optical-tests.log` each report 16/16 piston-removed pupil OPD presentation tests and 82/82 shared optical observation CPU product tests passing. `logs/package-metadata.log` reports 190/190 package and deployment checks passing. `logs/offline-final.log` reports 71/71 offline preparation checks passing; its receipt is `logs/offline-check.json`.

The registered PipeWireAORTC package is version 0.2.4, tree `742ec6818dcaf3d241bdd1d17f788997dfc9638f`, from candidate commit `ea5bd18b5a9e7097085ea452733ebabc78aaddff` (`logs/registration.log`). The app resolver changed only PipeWireAORTC from 0.2.3 to 0.2.4; other locked dependencies were preserved (`logs/resolve-app.log`).

The image product is pupil OPD in nm, with piston removed and tilt retained. Pixels outside the pupil are NaN. The headless interface provides a residual pupil OPD image and one paired stream containing uncorrected-atmosphere and corrected-pupil RMS measurements. These are generic optical products; they do not require an instrument-specific GUI handler.

## Managed numeric-oracle run: failed

`managed/failed-original-numeric-oracle/` preserves the managed CPU replay and its lifecycle receipts. Its result is **not a pass**: 1024 checks passed and 2 failed. Both reset-separated generations failed the same detector comparison at frame 10, row 276, column 189: observed ADC value 110, expected 109. The accompanying RMS, image, header, controller, and reset checks passed. No cause is established by this observation.

## Independent offline checks

The scripts and compact results under `analysis/` examine the same captured command sequence through independent CPU analyses:

- `independent-oracle-check/` reports exact agreement across fresh preparations and public-reset replays, including the frame-10 optical inputs and ADC output. Its purpose is to check whether the one-count mismatch repeats across independent runs; it does not change the failed managed oracle result.
- `independent-observation-invariance/` reports exact equality of science outputs with optional analysis disabled and enabled for one fixed prepared CPU owner and the same 32 commands. This test is synchronous and does not cover native transport or a concurrent worker.
- `independent-retained-metrics/` reports 222/222 checks passing on that captured command sequence: exact controller replay, 31 wavefront/RMS samples, matching pupil masks, and maximum wavefront pixel, wavefront RMS, and paired RMS errors of about 1.53 × 10⁻⁵ nm, 1.05 × 10⁻⁸ nm, and 1.46 × 10⁻⁵ nm, respectively.

These offline checks support reproducibility and analysis invariance for their stated CPU fixtures. They do not establish a root cause for the failed managed numeric-oracle gate, validate live PipeWire transport, or constitute hardware validation. Their scripts refer to source captures in the raw worktree named above; the large binary inputs are not duplicated here.

## GUI software and live CPU evidence

`gui/validation.txt` records GUI source and software checks, including 10/10 focused `time_series` tests and passing full Rust, WASM/browser, and Julia checks. The new panel uses generic time-series measurements; it is not tied to an RTC instrument handler. Browser review used software rendering. The strict Clippy command reported existing Rust 1.99 lint/deprecation failures; the documented command with those existing lints allowed passed. `gui/task_series_profile.rs` preserves the actual operator-profile parser check. The local GUI binary, generated browser assets, and screenshots are omitted.

The final live application is main commit `dbf8af57b111cfa51dad1a8e8d31bbf93ff815e1`.
The GUI source is `630198f88fd07cdba5c0c316f1c0307b4f58c2f2`; its standalone
Glow binary has SHA-256
`14dbfbc20c97ccc917c76bd0cfa354118ea667fa5828bfa87c0c645ed8c46aab`.
`integration.json` verifies the registered production source, all 44 sealed
application assets and 26 unchanged scientific/calibration files. Only the
private review registry was updated; no public release or GitHub push was made.

`live/live-rms-check.json` records 32 fresh paired RMS samples, with matching
wavefront image identities/PTS, the actual pupil mask and image-RMS agreement
within 1.85 × 10⁻⁶ nm. The final short window averages 200.33 nm uncorrected
atmospheric RMS and 48.35 nm corrected RMS. These are spatial piston-removed
RMS values with tip/tilt retained, not temporal RMS or a long-run performance
qualification. The GUI has an active queue subscription for the generic
**Simulator → Wavefront RMS** chart. It plots elapsed simulation time from the
source sequence and 2 ms period. Channel selections, time window, pause and clear
are GUI presentation choices; the measured values exist independently of it.
No rendered live screenshot was captured.

The first GUI handoff accidentally used a dev-dependency-unified Wgpu binary
after Cargo's integration test overwrote the native executable. The resource
audit rejected its GPU device handles, and the GUI was stopped immediately;
the simulator stayed on CPU. `gui/gpu-first-launch.json` records the observed
devices; `gui/glow-artifact-handoff-note.txt` explains the confirmed artifact
selection error. A temporary Lavapipe launch passed the narrow compute-runtime
and device-handle audit. The final handoff was rebuilt and copied immediately,
and its retained fingerprint selects Glow without Wgpu. Its final launcher
explicitly selects Mesa EGL and llvmpipe. `live/live-graphics-audit.json`
records no listed NVIDIA/hardware-Vulkan modules or GPU device handles in that
GUI; `live/live-gpu-audit.json` records no CUDA/HIP compute-library mappings or
GPU device handles across all six owned processes. Mapped libraries and active
device use remain distinct claims.

The previous CPU session was cleaned up completely. The new CPU RTC and GUI
are intentionally left running. The task-owned Cargo cache was removed after
the immutable binary was installed, reclaiming 13.05 GiB
(`resource-cleanup.json`). Software, CPU simulation and live subscription
evidence do not establish hardware or cadence qualification. The original
managed ADC oracle failures and unchanged strict-Clippy baseline failures
remain recorded rather than being presented as passing checks.
