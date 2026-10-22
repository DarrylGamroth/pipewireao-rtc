# Live residual wavefront diagnostics

This bundle preserves the 2026-10-22 CPU validation for Classic residual
wavefront products. Offline, package, optical, prefix, and managed replay checks
are recorded separately. The managed reset-oracle pass is finite simulation
evidence. The live CPU RTC and existing GUI have been updated; hardware
qualification remains outside this change.

The product is a generic rank-two residual pupil OPD image in nanometres. It
removes piston and retains tip/tilt; samples outside the pupil are NaN. The GUI's
existing ndarray panel can display the image and finite-sample RMS under the
Simulator group, without GUI source changes or instrument-specific handlers.
The focal and wavefront images carry their common originating snapshot identity
and WFS PTS, but delivery is independently lossy. Match sequence and generation
before comparing different products; their latest displayed frames need not align.

The final reset-oracle managed run passed 716/716 checks. It captured two
consecutive CPU generations, each with 32 detector/controller frames and 31
residual-wavefront observations. In both generations, pupil masks and shared
acquisition identity/PTS matched, detector differences were empty, and exact
detector/controller replay passed. Maximum wavefront pixel error was
1.52582 × 10⁻⁵ nm against a 1 × 10⁻⁴ nm tolerance. The reset-oracle GPU audit
lists no GPU mappings for the captured processes. See `managed/reset-oracle/`.

Earlier attempts remain clearly labeled under `managed/failed-managed-spa/`
and `managed/failed-managed-verified/`: the former recorded 326 passes, 31
failures and one error; the latter recorded 714 passes and two failures. The
initial managed harness parse failure and the later core-start failure are also
preserved. These are failed attempts, not evidence of successful validation, and
their individual logs do not establish a general cause for the final pass.
Prefix validation passed 8/8 checks in `logs/prefix-tests-verified.log`.

The refreshed offline preparation passed 71 checks and reports no simulator
start, service activation, GPU libraries, or GPU modules. Package test and
metadata evidence is in `logs/package-tests-final.log` and
`logs/package-metadata-final.log`. These software results do not establish live
hardware behavior. The 2,416-assertion full package test preceded the explicit
source-keyword correction; the corrected registered 0.2.3 package separately
passed 60 optical checks and 190 source/metadata checks. The managed gate uses
that corrected immutable package.

## Live CPU deployment

The application main commit is `4c8cf50b55cd97b96f423254988867c91caf93a8`.
PipeWireAORTC 0.2.3 is pinned to immutable tree
`07c4146c0e62d318b369d2fc55fbdbfc022e310c` in the existing private review
registry only. No GitHub or public registry release was made. The integration
receipt records matching installed production hashes, sealed application hashes,
and unchanged scientific inputs, including calibration identity
`sha256:1837924beaf3a198726c096cfc3922d30529935be3f73974a1979169cb2962e4`.
The application keeps its saved CUDA default; this live copy explicitly selects CPU.

`live/live-wavefront-check.json` records 16 increasing generation-one samples,
sequences 507–522, with the actual transmitting pupil mask, near-zero pupil
piston and finite RMS of 42.056–48.119 nm. This short sample is not a long-run
correction-performance claim. The generic GUI has an actual PipeWire link from
the wavefront queue and remains running. Its profile places the ordinary ndarray
image and whole-image RMS under **Simulator → Residual wavefront · nm OPD**.
No rendered screenshot was captured. No GUI source change or Rust build was needed.

`live/live-gpu-audit.json` records no GPU compute-library mappings or GPU device
handles in any owned core, RTC, controller, parameter, simulator or GUI process.
The GUI uses software rendering. `live/previous-session-final.json` records
complete cleanup of the replaced CPU session. The new RTC was Running during
verification and is intentionally left running with the GUI. The shared diagnostic
contains no instrument-name rendering branch; other applications enable the same
source/queue/view declaration as appropriate to their pupil dimensions.

Only selected small logs and JSON receipts are included. The bundle excludes
installed application trees, `.bin` frame/command arrays, and the raw managed
candidate subtrees. `SHA256SUMS` hashes the curated bundle; raw bounded captures
remain outside Git under the dated task directory. The scripts record the paths
used during validation; the task worktrees are removed after merging to main.
