# Classic headless deployment: offline CPU validation

Date: 2026-10-21. Result: passed within the offline scope below.

Classic now selects the headless `pipewireao-rtc` executable and upstream
libwireplumber built against PipeWireAO. RTC 0.2.0 records the breaking public
`WirePlumber*` to `Session*` namespace migration. It is registered only in the
private workstation review registry; no public release or remote push was made.

The changes are integrated into `main` in the normal RTC and Classic checkouts.
Their two task worktrees and merged branches were removed; unrelated historical
worktrees were preserved. The [integration receipt](integration.json),
[canonical checker log](canonical-check.log) and
[canonical configuration receipt](canonical-configuration.json) record a fresh
64-check pass from the normal Classic directory and the stopped service.

## Source and preservation

- RTC source commit: `fa8e4d5dcdb370f9acf3a9c28bc898e071ed919e`.
- Registered RTC tree: `77e169a9512fa557ff3ee1e4871537fc5468d0ef`.
- Classic commit: `caaf9f4b02aff543ea9e2b737a6f7e7b7b5a8d4c`, based on
  `841a6e665c5dc0d3d31eac3ba4e42b25cba5e713`.
- Julia: 1.13.2. See [registration](registration.json) and [receipt](receipt.json).

[Preservation checks](preservation.json) establish that all 32 original
scientific/configuration assets are byte-identical. Only Classic's RTC manifest
entry changes: AOS 0.2.2, shared HIL 0.2.2, Classic 0.2.4 and calibration 0.17.0
remain pinned. The application seals 37 files. The Gaussian HSDM277 model,
480-sample pupil, detector, calibration, controller and placement values are
preserved. Prior daemon-based live results remain historical evidence.

## Checks

| Check | Result | Evidence |
| --- | --- | --- |
| Full RTC Julia CPU suite | 2,409 assertions in 77 test sets | [Log](rtc-tests.log) |
| Seals, configuration generation and native SPA-JSON parsing | 64 assertions | [Log](app-check.log), [receipt](configuration.json), [configuration](rtc.conf) |
| Three-frame CPU numerical replay | 30 assertions | [Script](cpu-science.jl), [log](cpu-science-final.log), [receipt](cpu-science.json) |
| Registered CPU instrument owner loading | 33 assertions | [Log](owner-loading-cpu.log) |
| Public installer, files only | 9 assertions | [Log](install-check.log), [receipt](install-check.json) |
| Generated systemd unit verification | Exit 0 | [Unit](pipewireao-session@.service), [log](unit-verify.log) |

CPU replay compares RTC-prepared science with a separately prepared direct
Classic plant using the same deterministic inputs. Detector frames, pupil OPD,
PDM surface OPD and sequence agree exactly, including a small command probe.
The CPU override exists only in memory; the saved GPU deployment is unchanged.
No GPU module or library was loaded. Configuration-only owner identities are
synthetic and do not establish live admission.

The installer generated files under
`/home/dgamroth/workspaces/codex/worktrees/classic-headless-offline-20261021/installed`.
No unit was linked, enabled, reloaded or started. The old service
`pipewireao-session@1581f3130b5c.service` remains inactive with MainPID 0.

## Native dependencies and limits

The selected prefix is
`/home/dgamroth/.local/opt/pipewireao-classic-headless-20261021`.
[Native identities](native-prefix.json) and [loader evidence](native-dependencies.log)
record the executable and libraries. Upstream WirePlumber revision
`bdc17eb2c419cbe41dbb248cf20cbe93370ee2f7` is used without either optional bug fix.
RTC modules remain in their own module directory. PipeWireAO library bytes are
unchanged from the previous Classic prefix.

This prefix inherits symlinks into `/opt/pipewireao` and the Julia artifact store,
and uses host libraries. It is not a self-contained immutable runtime closure;
recheck the selected dependencies before a live gate.

Pkg's automatic cache cleanup removed a cached development dependency during
resolution. [Restoration](development-cache-restoration.log) reinstated it and
verified loading JSON3 and RTC 0.2.0. Subsequent package commands disable automatic
cleanup. No scientific source or application asset was removed.

The [independent review](../../reviews/20261021-classic-headless-offline/REVIEW.md)
has no unresolved offline blocker. It includes fail-before/pass-after evidence
for output containment through directory symlinks.

Live application admission, restart/replacement, GUI controls, sustained cadence,
latency, GPU behavior and physical operation remain unqualified by these checks.
Artifact-management development stays paused.

## Reproduce

In the normal Classic checkout, use a fresh output directory outside the
application:

```sh
cd /home/dgamroth/workspaces/codex/pipewire/revolt-classic-rtc
env JULIA_DEPOT_PATH=/home/dgamroth/.local/share/classic-review-20261020/depot \
    JULIA_PKG_GC_AUTO=false JULIA_PKG_PRECOMPILE_AUTO=0 JULIA_PKG_OFFLINE=true \
    julia +1.13 --startup-file=no --project=. check-offline.jl \
    /home/dgamroth/.local/opt/pipewireao-classic-headless-20261021 \
    /absolute/fresh/output
```

The full RTC suite command was
`julia +1.13 --startup-file=no --project=. test/runtests.jl` in the RTC worktree.
The CPU instrument loader command was
`julia +1.13 --startup-file=no --project=. /absolute/registered/RTC/test/test_aos_owner_loading.jl cpu instrument`
in Classic's pinned environment. The replay script takes Classic's application
directory and an external JSON receipt path; see its argument validation.
