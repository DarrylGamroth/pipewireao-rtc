# Classic supplied mirror description — 2026-10-22

Scope: software validation of shared intrinsic DM geometry, explicit file input,
selected instrument pupil registration and ordinary PipeWire NodeInfo metadata.
No physical mirror, metrology, hardware unit conversion or timing qualification.
All numerical validation uses the CPU; the GPU remains available.

Final design uses one canonical device JSON in the ALPAO adapter repository at
`data/mirror-descriptions/revolt-hsdm277.json`, copied as a sealed application
asset. SHA-256: `38cddc34342e08ee66546600daf1dee8599f7054e12f74f631fa649ccd004326`.
The proposed ALPAOMirrors package was removed before registration. Classic reads
an explicitly supplied JSON filename using JSON.jl and retains immutable data.
Pupil registration is a separate instrument setting; default pitch remains 0.125.

Candidate revisions: native ALPAO `faaad587d42257e128d6225b21ce9e5a1c8cb66f`,
REVOLTClassicSim `248e588cee4182b218f7a41bb78cf56c870c2899` (0.2.6), and
PipeWireAORTC 0.2.7. AOS 0.2.2 and HIL 0.2.2 remain unchanged. Julia 1.13.2,
JSON 1.12.2; one Julia/BLAS thread for numerical checks.

Observed local results:

- Native SDK-free mock tests: 3/3; fresh staged installation preserves exact JSON
  bytes. Metadata ownership, schema/count validation and Unicode rejection covered.
- Classic cold scientific selector: 602/602; full CPU suite: 876/876. Includes exact
  historic 277-command mapping/default coordinate fingerprints, selected pitch,
  both Gaussian profiles, production/calibration frames, replay and AOC contracts.
  Synthetic smaller descriptions test propagation only, not another instrument.
- RTC complete maintained suite:2,645/2,645. Includes exact 64-bit integer IDs,
  decimal-token distinction, malformed/trailing JSON rejection, saved settings,
  required file input without a fabricated default, contained application-relative
  paths and ordinary endpoint metadata. An expected corrupt-Git-object rejection
  prints `git cat-file` failure; the suite exits 0.
- Final file-input/metadata and actual CPU prepare/warm/reset selector: 194/194
  at source `0ed3da2` (the full RTC suite above preceded this last focused change).
- Registered application metadata: 25/25; unchanged calibration completion:
  60/60; final installed offline preparation: 80/80. Manifest contains no path or
  repository overrides, JSON3, StructTypes or ALPAOMirrors. Local registry pins
  ClassicSim 0.2.6 tree `f7e26251c173d791a7bd986d4791d18ed3d1faf0` and RTC 0.2.7
  tree `0524ab42a862334c40a7fb42b82287ae0afd83f2`; app revision `e5a64c5`.
  All 26 baseline numerical/calibration/layout assets remain byte-identical.

Original logs and preparation context are retained outside the package at
`/home/dgamroth/workspaces/codex/worktrees/classic-mirror-description-20261022/`.
Key receipts: `alpao-receipts/native-file-only-testlog.txt`,
`classic-file-description-cold.log`, `classic-file-description-cpu.log`,
`rtc-suite-final.log`, `rtc-file-input-final.log` and
`app-file-input-authoring.log`. The authoring calibration check lacked an
application-only dependency; no calibration result is claimed from that attempt.

## Live CPU deployment

The new session `091368df-84d2-4e44-9095-32580dba35cd` is Running under
`pipewireao-session@71b93c8eed89.service`, invocation
`d2fa50c0f07740428be9c27d0d0e4152`. Model cadence is 500 Hz with explicitly slow
10 Hz wall pacing, using the CPU. This is functional validation, not a sustained
rate or latency claim. The previous session/GUI were stopped by retained identity;
cleanup completed with systemd result `success` and no forced termination.

- [Mirror NodeInfo receipt](live-mirror-check.json): command sink id121/serial122
  and applied-command source id117/serial118 publish all 2,541 canonical bytes,
  independently checked against the actual private-core dump.
- [WFS receipt](live-wfs-check.json): 31 matched acquisition/PTS cohorts agree
  bit-for-bit with an independent eight-field summary calculation. The visible
  summary and slopes GUI subscriptions are active. Detector/flux/validity panes
  were hidden in the preserved workspace, so those GUI subscriptions are absent.
  An initial all-panes-visible check rejected that layout assumption; the final
  check explicitly requires the visible summary, without changing GUI state.
- [Instrument endpoint/GUI receipt](live-instrument-check.json): exact published
  instrument bytes and SHA; a fresh production GUI adapter resolved 277 DM
  commands, nine Zernike modes, 112 Fourier frequencies and 188 SHWFS regions.
  The GUI binary remains `feba249`, using software Mesa rendering.
- [GPU exclusion receipt](live-gpu-audit.json): all seven owned roles have no GPU
  device handles or runtime mappings. Unrelated user processes were untouched.
- Generic simulator-settings describe: 5/5, including the required read-only
  mirror filename retained as `mirror-description.json`, not an installation path.

Live files and actual graph dump remain at
`/home/dgamroth/.local/state/pipewireao/classic-cpu-mirror-live-20261022/`.
Additional retained receipts: `register-local.log`, `app-pin-versions.log`,
`app-registered-tests.log`, `app-offline-final.log`, `launch-live.log`,
`live-mirror-check.log`, `check-live-visible.log`, `gui-instrument-probe.log`,
`live-settings-check.log` and `old-stop.json` in the external evidence directory.
The first direct native dump omitted the SDK plugin path and failed to create
its support loop; final checks use the retained `with-cpu-sdk.sh` environment.

The [independent review](../../reviews/20261022-mirror-description/REVIEW.md)
accepts the final source and exact live mirror publication. Physical ASDK mirror
qualification, camera control parity, measured influence functions, and further
multi-mirror transport remain outside this increment.
