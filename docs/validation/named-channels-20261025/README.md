# Named RMS channels — 2026-10-25

The optional atmospheric RMS source now declares the existing two-value packet
as immutable named channel metadata. Channel 0 identifies uncorrected
atmosphere RMS, channel 1 identifies corrected pupil RMS, and both declare
`nm OPD`. The numerical product, schema, shape, sample timing, and callback
behavior are unchanged. Configurations without an atmospheric snapshot still
omit the RMS source.

## Software validation

The optical observation selector ran against the CPU Classic application
configuration. Its temporary environment copied the HIL environment's locked
manifest, redirected the RTC entry to this worktree, and added the Classic
simulation package from the matching CPU application manifest. No package
resolution or upgrade was run. Julia used the installed package cache.

Command:

```sh
julia --project=/home/dgamroth/.local/state/pipewireao/named-channels-20261025/rtc \
  test/aos_optical_observation.jl \
  /home/dgamroth/.local/state/pipewireao/named-channels-20261025/rtc/simulation.conf
```

Result: 16 piston-removed pupil presentation assertions and 88 shared optical
observation CPU product assertions passed. This includes the channel count,
zero-based indices, names, titles, units, and no-RMS-source behavior. The test
also confirmed that GPU packages and GPU libraries were not loaded. Full output
is recorded outside the repository at
`/home/dgamroth/.local/state/pipewireao/named-channels-20261025/rtc/optical.log`.

The first attempts exposed two setup mismatches: the HIL environment did not
include the instrument package required by the selector, and an older Classic
configuration used `wall_rate` instead of this RTC branch's `pacing_rate_hz`.
The final run used the matching application environment inputs with the
configuration field adapted in the temporary state directory. No repository
configuration or unrelated worktree changes were modified for validation.

## Private CPU and GUI integration

The isolated CPU Classic application reached Ready and Running through the
existing RTC lifecycle, with 156 other dependency identities and 71 application
files preserved. HIL receives a metadata-only overlay on the exact admitted
transport tree; RTC receives only the RMS declaration change. The immutable
registered snapshots have no path/repository Manifest overrides. See
[admission](admission.json) and [GPU inspection](gpu-audit.json).

The [separate GUI export](gui-export.json) resolves authoring references through
existing owner APIs without changing the active application. Its parsed result
differs from the previous GUI in only the three named-binding migrations. Live
browser checks pass for actual RMS source catalog/sample agreement, source field
titles/units, RMS and WFS hide/restore, reconnect, named flux, real WFS tooltip,
DM products and configuration faults. A native adapter/renderer scenario also
passes three 32-summary phases, including WFS hidden while X/Y continues and
adapter reconnect. Detailed GUI receipts reside in the peer GUI repository's
`docs/validation/named-channels-20261025/` record.

The broader HIL calibration deadline timeout reproduced on both unchanged
baseline and patched source with identical controlled inputs; its cause remains
unresolved. That result is distinct from the passing changed-surface checks and
is not claimed as a clean full HIL suite.

All source changes remain in dedicated worktrees. No main-checkout copy-back,
merge, production browser replacement, scientific equivalence, physical-device
or timing qualification is claimed.

The temporary cohort was stopped after acceptance. [Cleanup](cleanup.json)
confirms all private processes/socket disappeared and the existing home services
remain Running. The single shutdown reproduced the known unknown native Quit
deadline outcome in [issue #12](https://github.com/DarrylGamroth/pipewireao-rtc/issues/12).
Ownership cleanup is complete, while the retained service phase is failed; this
is not a successful shutdown gate. No retry, rebind or lifecycle fix was made.
