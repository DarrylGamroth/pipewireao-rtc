# Simulator settings and cold application replacement

Date: 2026-10-21. Scope: local non-actuating Classic, CUDA plant / CPU JFG.
Managed replacement and GUI verification are separate from cadence, latency,
physical instruments and remote/browser service qualification.

## Sources and immutable closure

- RTC implementation: `335922270c46d7b8b4270851139ad27725ec703d`, registered
  privately as PipeWireAORTC 0.1.11, tree `e16a9c06993094cf27c22f8e791937cbdfcd57f7`.
- AOS 0.2.2 tree `e30d64c3ba04733cae74b63eaaa4de67119a06d6` and Classic 0.2.2
  tree `ca08d9483c482ee424ffe43dddbd633934762f8c`; shared HIL 0.2.2, AOC 0.17.0,
  CUDA 6.4.2, Julia 1.13.2. The application has no path or repository overrides.
- Native prefix: `/home/dgamroth/.local/opt/pipewireao-classic-journal-20261020`.
- Registry/mirrors: `/home/dgamroth/.local/share/classic-review-20261020/`.
  This increment does not publish a public release or change global registries.
- Independent source review found no confirmed blockers in the RTC implementation
  and GUI `8a49ddc`; it did not substitute for the integration tests below.

## Software checks

Workstation evidence root:
`/home/dgamroth/workspaces/codex/worktrees/simulator-settings-validation-20261021/`.

`rtc-tests-final.log` records 2,301 assertions across the complete local RTC suite.
It covers shape/read-only admission, cold preflight rejection, stale identities,
reservation bounds and the exact invocation lock/fence. The GUI's initial full
checks passed 534 shared, 268 native and 12 integration tests (external/live tests
remain opt-in). Formatting, browser/WASM compilation and dependency isolation
passed. Strict Clippy encountered existing Rust 1.99 baseline warnings; scoped
Clippy allowed only the recorded existing deprecation/chunks warnings.

`launch-smoke.log` demonstrates an actual systemd one-shot worker continuing after
its launching Julia process exits, then failing before live effects on a missing
application. The service uses Type=oneshot, TimeoutStartSec=2400 and
TimeoutStopSec=30; RemainAfterExit retains the outcome. Per-invocation file locks
serialize clients even when their management roots differ. Uncertain effects are
retained without automatic retry.

## Managed CUDA evidence

The initial isolated startup failed because the copied application declared a
480×480 focal image while the 480-sample pupil produces 960×960 with the existing
padding. WirePlumber rejected the format; `managed-initial/start-failure.json`
confirms cleanup. The source contract was corrected; the same optical/model code
then reached Ready. An intervening isolated start was explicitly cancelled before
its ledger existed; its unit had MainPID=0, empty cgroup and empty runtime. That
incomplete start is retained separately and is not a passing cleanup receipt.

`initial-native-status.json` proves Ready for session
`83013cca-62c0-4039-bba2-4dc0910cd083`, invocation
`94eba6d0233048f486a2b36d98642f8a`. Invalid layer strengths (all ones) failed plant
preparation with `fractional_cn2 must sum to 1`.
`invalid-no-effects.json` confirms the original native Ready state, PID/invocation
and absence of an effect fence after rejection.

Valid headless job `c33b638c954c4965adef1e4c552f5cad` changed r0 to 0.17 m and the
first layer's wind speed to 9 m/s. Its submitting Julia process exited before
completion. `valid-result.json` and `valid-live-proof.json` prove the replacement
session `f7ceb0c8-cd5c-48a2-9ecb-5330fe1ab64e` reached native Running, the startup
report/configuration matches its source incarnation, and reconstructor, offset
and interaction-matrix bytes were preserved. The original isolated unit was
cleaned and its owned unit link removed before replacement.

The former live Classic session received one native Quit. Its endpoint vanished
before the completion reply, so that reply was retained as unknown. Read-only
`reconcile_cleanup!` then confirmed stopped owners and cleanup; no Quit retry was
sent. `old-live-final-cleanup.json` retains the final ledger. The former GUI was
stopped separately.

Actual GUI job `94a19b5e26264db998488d6539cf6722` changed r0 to 0.16 m and
first-layer wind speed to 8 m/s. `gui-live-proof.json` confirms both settings in
the actual Running source. Its explicit reconnect then exposed a GUI bug:
the native `.pod` discovery locator was passed to the older JSON-locator path
(`expected value at line 1 column 1`). The replacement session remained healthy;
ordinary native picker attachment succeeded. This failing UI evidence is retained
in `/tmp/simulator-settings-reconnect.png`; the failure is corrected at GUI `0e5166c3a87a5ab599166b0d4fe75278f9caf99a`.

GUI `9ed34ed` clears obsolete description errors on session changes while
preserving retained jobs and uncertain outcomes. GUI `3e85bb7` makes the generic
layer table fill the available pane and moves explanatory paragraphs to tooltips.
Seventeen focused tests pass, including fail-before/pass-after status and actual
paint-geometry regressions across 360→1200→360→180 widths. The minimum column
width remains readable with horizontal scrolling in narrow panes. The tests
also confirm that resizing does not mutate settings.

## Limits

A rebuild reloads saved startup configuration and resets controller/scientific
state. It does not checkpoint unsaved live controls/artifact updates. Profile and
pupil resolution are read-only in this form. The GUI supports editing existing
layer rows; changing layer count requires the headless interface and plant validation.
The mirror is the provisional Gaussian HSDM277 model, with fresh simulation-local
480-sample calibration. No measured-mirror, hardware, sustained 500 Hz or
latency/cadence qualification follows from these finite checks. Artifact-management
expansion remains paused.

## Final GUI and deployment gate

GUI `0e5166c` binds the reported replacement UUID and native discovery locator,
refreshes discovery, and uses ordinary asynchronous native session selection.
Explicit Disconnect cancels a pending reconnect; intervening selections and
changed generations are rejected. Independent final review found no confirmed
blockers. The native binary suite passes 271 tests (15 existing opt-in ignores);
18 focused shared settings tests pass (one external input test ignored).
Formatting, browser/WASM compilation and scoped Clippy pass. An initial native
test lacked the installed SPA runtime paths; that failure and the corrected
passing run are retained in `gui-checks/` without a production workaround.

With the exact inspection release, actual GUI job
`5230addccd5f4e0e93eb1b25086a39b0` restored r0=0.15 m and wind speeds
[5,5,7,10,10] m/s. Its native session
`80c69d20-3397-4ed9-a89c-5c26b4a35b82` reached Running. Clicking the fixed
Reconnect button selected that exact UUID through native verification; Settings
then automatically loaded 0.15 and 5 for the edited fields. The calibration
matrices and 480-sample CUDA plant were preserved. `final-job.json`,
`final-live-proof.json`, `verify-final.log` and
`gui-screenshots/simulator-settings-reconnect-passed.png` retain the evidence.
The layer table fills the actual widened Settings pane, and the short panel
text is visible in `simulator-settings-responsive.png`.

The deployed binary is
`/home/dgamroth/.local/opt/pipewireao-classic-journal-20261020/bin/pipewireao-gui-0e5166c`,
SHA-256 `bcf36b0929c4f2e089fd8aee622d34cc4d8eaed123471c5b3e6ac5283db33f1c`.
`native-prefix-sha256.json` records the native prefix inputs. The owned Rust
build target was cleaned after deployment (9.8 GiB reported by Cargo); the
installed binary and evidence remain. One simulator GPU process remains.
