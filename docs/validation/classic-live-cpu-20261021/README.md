# Classic live CPU and GUI validation — 2026-10-21

This gate uses a separate sealed CPU copy of Classic. The normal application
retains its CUDA default, 480-sample pupil, scientific configuration and
calibration. No GPU is needed by the simulator or GUI: the latter uses Xvfb
and Mesa llvmpipe software rendering. Only fresh task-owned units and private
PipeWire remotes are started or stopped; the pre-existing GUI is untouched.

**Result: passed.** GUI Stop/Start, atmosphere Apply/restart, explicit reconnect
and final native Quit/cleanup pass. All task-owned simulation processes, GUI and
virtual display are stopped. The default deployment remains CUDA.

Both normal checkouts are on `main`, with Classic pinned to RTC 0.2.1. The two
task worktrees and merged branches are removed; historical worktrees and
unrelated edits are preserved. The [integration receipt](integration.json) and
[canonical checker log](canonical-check.log) record a fresh 64-check pass from
the normal Classic directory and a final stopped-service check.

## Results

| Check | Observed result | Evidence |
| --- | --- | --- |
| Full RTC Julia suite | 2,416 assertions, 77 test sets | [Log](rtc-tests.log) |
| Focused configuration/identity regression | 69 assertions | [Log](cleanup-regression.log) |
| Independent observation of original stopped incarnation | Six assertions | [Log](independent-stopped-observation.log) |
| Final sealed Classic offline configuration | 64 assertions | [Log](offline-final.log), [receipt](configuration-final.json) |
| Fresh CPU session | Native Running, CPU metadata, no owner GPU libraries | [Receipt](fixed-running.json) |
| GUI atmosphere replacement | Complete; r₀ = 0.20 m, L₀ = 25 m; new exact session | [Request](after/request.json), [result](after/result.json) |
| Replacement verification | Native Running, matching configuration hash and settings | [Native observation](replacement-running.json), [description](replacement-description.json) |
| GUI replacement Stop → Start → Stop | Running and Ready observations; final source sequence 3,333 | [Final native observation](final-ready.json), [GUI Running](replacement-restarted.png), [GUI Ready](final-gui-ready.png) |
| Final shutdown | Accepted Quit, all four owner processes gone, empty cgroups, locator removed | [Receipt](final-shutdown.json), [read-only confirmation](final-confirmation.log), [stopped ledger](after/final-launch.json) |
| GPU and host cleanup | llvmpipe, no GUI GPU device handles/libraries, all task sessions stopped | [Renderer](software-renderer.log), [GUI](gui-gpu-free.json), [final safety](final-safety.json) |
| Scientific preservation | All 32 assets and all other package entries unchanged | [Receipt](preservation-fixed.json) |

The full suite exits successfully; its `git cat-file` error is emitted by the
expected missing-object negative test.

The final shutdown command completed successfully before a harness postcheck
incorrectly indexed an optional absent `cleanup_errors` field. Its
[failure log](final-shutdown.log) is retained. The corrected
[read-only confirmation](confirm-shutdown.jl) checks the already accepted Quit,
stopped ledger, absent processes and empty cgroups using the optional field's
empty default. It sends no second Quit and does not repeat a rebuild.

The [completed-job GUI](replacement-completion.png) offers explicit reconnect;
the [new settings GUI](replacement-settings-confirmed.png) shows the applied
values, CPU backend and new configuration hash. The reference wavelength is
displayed as 500 nm. The [SHWFS image and DM view](replacement-shwfs.png) receive
live samples after reconnect. A [wind draft](wind-draft.png) changes the ground
layer to 8 m/s and 45° without applying it; Reload is selected afterward. Wind
changes are not claimed as a second applied replacement.

The successful replacement's exact old session has an
[accepted Quit fence](after/previous-shutdown-attempt.json) and
[successful cleanup ledger](after/previous-final-launch.json).
The original failed operation remains [unknown](before/result.json), with its
[accepted fence](before/shutdown-attempt.json), [stopped ledger](before/final-launch.json)
and [separate corrected observation](reconciled-first.json) retained unchanged.

## Source

- RTC correction: `4d13493f6e4e91e260c71e6ba65636dc5483b32e`, version 0.2.1,
  registered tree `eba8af0f017060d784df5ecbcbf2f0449794b3ba`.
- Private review registry: `a3e16d15ee4b4241606d709bcb634c38cac201fc`.
  No public release or remote push is part of this gate.
- GUI: `4a3d94ecc1489efca5314380d39259b78c16e6a3`, unchanged native binary.
- Native prefix: `~/.local/opt/pipewireao-classic-headless-20261021` with
  upstream libwireplumber built against PipeWireAO, without the optional fixes.
- Julia 1.13.2; AOS 0.2.2, HIL 0.2.2, Classic 0.2.4 and calibration 0.17.0.

The preceding [offline record](../classic-headless-offline-20261021/README.md)
identifies the native dependencies and the prefix's host/symlink limitations.
All other Classic package entries and all 32 scientific assets remain unchanged.
CPU selection and empty GPU visibility are explicit in the separate deployment;
the GUI profile changes only its session label to bind that exact CPU deployment.

## Confirmed shutdown defect and correction

The first GUI workflow on RTC 0.2.0 admitted Classic and completed
Ready → Running → Ready → Running. Apply and restart submitted r₀ = 0.20 m
and L₀ = 25 m, and CPU preflight succeeded. Native Quit was acknowledged Offline;
the old process and owners exited with a successful stopped cleanup ledger.

The client then incorrectly required `/proc/<old-pid>/exe` while reading that
stopped ledger. This contradicted its preceding check that the exact old
process had exited. The management result correctly remained **unknown**, and
no replacement started. The failed operation remains retained and is not retried.

RTC 0.2.1 separates retained ledger identity validation from live executable
verification. Live callers still verify the exact executable/configuration.
Stopped reconciliation reads the retained ledger only after confirming the
unit identity, no pending job, old PID/start-time absent and empty cgroup; all
cleanup/phase/error checks remain. The exact original stopped incarnation now
passes reconciliation without another Quit. Independent read-only validation
passes six assertions on that same incarnation; focused regression passes 69
assertions, and the full RTC suite passes 2,416 assertions in 77 test sets.

See the [independent review](../../reviews/20261021-classic-live-cpu/REVIEW.md).

## Procedure and evidence boundaries

The rendered GUI is operated through standard X11 mouse/keyboard input, rather
than treating a helper-protocol request as a GUI click. Session controls use
fresh native status. After each lifecycle command the GUI's Refresh obtains
the independent observed state. The Simulator Settings editor uses its ordinary
headless helper and systemd-owned rebuild job. A completed job requires explicit
Reconnect to rebuilt session and fresh verification of its new identity.

`SessionRuntime.ready` is a calibration-source compatibility projection, as
documented in [the integration guide](../../../test/integration/README.md).
It rejects the ordinary AOS source-control profile. This gate uses native session
Status for AOS admission and lifecycle, following the maintained integration path.

Native source snapshots are acknowledgements, not continuous telemetry. The
read-only observation script checks their identity/run state alongside backend
metadata and process GPU-library mappings. GUI image/DM observations demonstrate
received data; none of these checks establishes a qualified wall-clock rate.

Model rate and requested wall rate remain 500 Hz; this is functional CPU
validation, not a sustained 500 Hz, latency, stability, GPU or hardware gate.
Artifact-management development remains paused.
