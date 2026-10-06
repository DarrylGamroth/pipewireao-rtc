# Integrated native GUI and calibration gate review

2026-10-06. Bounded independent review of GUI `ed2de43` + `cc51286`
in `pipewireao-gui-native-hil` and RTC `456a772` in
`pipewireao-rtc-native-controls`. Both reviewed trees were clean. This artifact
lives in the separate RTC review worktree, starting at `830ff95`. No production
edit, test rerun, build, SCI or canonical GUI documentation change was made.

**Disposition:** approve these frozen implementations for the already planned
installed qualification. No confirmed production blocker was found. One cold
test-count correction below is required in the documentation. This approval
does not establish that the pending installed or scientific gates have passed.

## Source review

- **Ownership and native identity:** retained supervisor admission remains bound
  to the harness-owned launcher/MainPID, UUID, incarnation and public native
  discovery. The prior service invocation exit receipt and cleanup reducer
  remain intact. New observer signals target only the newly owned process;
  replacement requires another PID and the same native source global/serial.
  Native progress and discarded-buffer growth are required after observer exit.
  Readiness/release files synchronize that test executable only.
- **Duplicate installed owners:** the peer must be separately sealed,
  non-actuating, without external owners, and publish the same label. The
  coordinator stops only its peer through the retained native client. The
  ignored Rust hook selects the two exact UUID records, checks distinct
  PID/remotes, verifies fresh global/serial/token and expected lifecycle/Status,
  and renders both UUIDs with production picker/panel code. It submits only
  Status and asserts no passive controls. An exact completion marker and facts
  file prevent a missing ignored test from passing. Native peer shutdown and
  owned fallback retain failure semantics.
- **Complete trajectories and reset:** preparation requires a full recording.
  `compare-trajectories` requires the three distinct scenarios and all six
  records, consecutive reset generations, native-complete summaries and exact
  detector/command payload hashes plus truth equality. It rejects prefix or
  tampered evidence. The old two-cohort comparison is explicitly narrower.
- **CPU RTC / CUDA AOS:** the source argv and provenance must both select CUDA.
  Processing implementation bytes must match the campaign's explicit,
  separately qualified CPU reference; FGN requires its native bundle/factory,
  while JFG requires the ordinary service-graph owner and rejects either GPU
  capture flag spelling. The trusted reference's prior CPU qualification is an
  input assumption, not newly proved by reading an arbitrary directory. The
  reviewed gate records that scope and does not infer CPU execution from an
  engine name alone.
- **Six calibration fixtures:** Classic/Copper × FGN/JFG/HEART derive native
  instrument, source binding, stage, illumination, payload bound and backend
  from strict sealed declarations. Figure/WFS extents, finite Float32 values,
  finite timeouts and two-frame Capture capacity are checked before launch.
  Capture now forwards the selected profile/stage to the maintained verifier.
  HEART additionally binds fresh wrapper/child generation, configuration,
  ingress, placement and diagnostics to native snapshots; checks child parent,
  group/session/start ticks; retains count/size/hash-bound native evidence; and
  requires that child to disappear during owned shutdown. The prior unsupported
  Reset invariance, restoration/release, publication cursor and cleanup failure
  gates remain. No unknown effect triggers speculative Release. Small action
  qualification remains separate from full transfer/inverse/correction science.

## Evidence and one correction

**GATES-R001 — overstated GUI cold assertion count.** Severity low; confidence
high; observed evidence inconsistency. `docs/NATIVE_HIL_GUI_GATES.md` reports
89/89. Both its referenced `/tmp/gui-native-gates-cold-third.log` and the primary's
`/tmp/gui-native-gates-root-cold-20261006.log` actually total **83/83 in nine
sets** (26+12+6+6+4+6+7+4+12). Correct the documentation/report count to 83;
no implementation or test change is required. Disposition: reported to primary.

The calibration root log totals **175/175 in nine sets**. Neither cold log has
test failure markers. Retained Rust software evidence reports **119 passed,
15 ignored**; its ignored-test list contains the new exact hook, while the old
binary discriminator executes zero tests. Clippy retains the documented
`proc-macro-error2 2.0.1` future-compatibility warning. The stable executable
independently hashes to
`13ef605bcf1e6d614702190911e35d3c44bb8f02aeced5abe300b06cd3dc1ac0`.

Exact source/evidence hashes and copied root cold logs are in the
[review receipt](validation/integrated-gates-review-20261006/receipt.json).
Actual installed duplicate selection, observer death/replacement and six full
trajectory/reset records remain execution gates. Generic Collect/Capture must
still run on the selected installed fixtures. Offscreen rendering is not native
window validation. These increments make no allocation, timing, hardware or
full-transfer acceptance claim.
