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
Pupil registration is a separate instrument setting; default pitch remains0.125.

Candidate revisions: native ALPAO `faaad587d42257e128d6225b21ce9e5a1c8cb66f`,
REVOLTClassicSim `248e588cee4182b218f7a41bb78cf56c870c2899` (0.2.6), and
PipeWireAORTC0.2.7. AOS0.2.2 and HIL0.2.2 remain unchanged. Julia1.13.2,
JSON1.12.2; one Julia/BLAS thread for numerical checks.

Observed local results:

- Native SDK-free mock tests:3/3; fresh staged installation preserves exact JSON
  bytes. Metadata ownership, schema/count validation and Unicode rejection covered.
- Classic cold scientific selector:602/602; full CPU suite:876/876. Includes exact
  historic277-command mapping/default coordinate fingerprints, selected pitch,
  both Gaussian profiles, production/calibration frames, replay and AOC contracts.
  Synthetic smaller descriptions test propagation only, not another instrument.
- RTC complete maintained suite:2,645/2,645. Includes exact64-bit integer IDs,
  decimal-token distinction, malformed/trailing JSON rejection, saved settings,
  required file input without a fabricated default, contained application-relative
  paths and ordinary endpoint metadata. An expected corrupt-Git-object rejection
  prints `git cat-file` failure; the suite exits0.
- Application metadata authoring checks:25/25. Calibration completion and final
  registered/offline/live deployment checks remain pending at this source freeze.

Original logs and preparation context are retained outside the package at
`/home/dgamroth/workspaces/codex/worktrees/classic-mirror-description-20261022/`.
Key receipts: `alpao-receipts/native-file-only-testlog.txt`,
`classic-file-description-cold.log`, `classic-file-description-cpu.log`,
`rtc-suite-final.log`, `rtc-file-input-final.log` and
`app-file-input-authoring.log`. The authoring calibration check lacked an
application-only dependency; no calibration result is claimed from that attempt.

The live CPU update and final registration receipts will be appended after the
candidate is installed. The [independent review](../../reviews/20261022-mirror-description/REVIEW.md)
records confirmed findings and their disposition.
