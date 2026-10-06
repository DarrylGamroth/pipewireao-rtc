# Installed Copper gate independent review — 2026-10-06

Disposition: accept the bounded detector/command trajectory, reset, observer
death/replacement, stalled observer, and simulator Julia heap allocation evidence.
CIG-001 is corrected and independently verified; truth remains not evaluated.
No source edits, builds, live tests, process changes, or science reruns were made
by this review. Review consisted of retained evidence, source inspection, archive
decoding/hashing, and read-only PID presence checks.

## Reviewed boundary

- Qualification helper worktree `/tmp/rtc-copper-main-observer`, clean at
  `f47b4aa` over `5bcbdd0` and deployment main `ef8ead2`.
- Installed packages `/tmp/copper-jfg-main-{noobs-v2,obs-v1,alloc-v1}-installed`;
  proofs identify SDK `1417b69656b94e146e600c7201bc4d3b34d2cea4`.
- Evidence `/tmp/gui-copper-main-{baseline,unattended,death,stall,alloc}-v1` and
  `/tmp/gui-copper-main-full-trajectory-comparison-v1.json`.
- GUI binary SHA-256 independently recomputed as
  `311308864f52b9ea36dfbc86b1c648d072677aada73a3cd45e7d05061c9563d9`.
  Reviewed the native GUI harness and production-panel test source; no binary
  rebuild was performed to independently reproduce the source-to-binary mapping.

## Accepted observations

1. All six full records across disabled observation, unattended observation, and
   observer death contain 256 detector frames and 256 commands, before and after
   reset. Independently decoded gzip payloads have correct lengths (8192 detector
   bytes and 1108 command bytes per sequence), complete sequences 1–256, and exact
   equality across all six records. The stall record also matches them exactly.
   Common detector hash is
   `b47321140763e9ba4c0eb6a7d56102aff54835a6ce2ba83418511b70270e71c0`;
   command hash is
   `349c6f6105a780236cd6bc402c8fc849293fdd300838e3f1d74706ed4f12e27f`.
2. Full-record runs show completed generation 1, paused/reset sequence 0 at
   generation 2, and completed generation 2. Native supervisor identity remains
   unchanged within each case. Baseline pause/hold/resume preserves sequence 130.
3. Observer PID 3968408 terminated by signal 9; replacement PID 3968431 differs.
   Science advances 29→37 after death and 44→50 across replacement release while
   owner identities and native incarnations remain unchanged. Both processes
   record actual 64×64 U16 native samples rendered by production ViewPanel,
   including reconnection and retained-copy checks. The replacement log has one
   passing test. The killed observer is correctly evidenced by terminal signal,
   not by its numeric exitcode field alone.
4. Stall harness source sends SIGSTOP to the owned observer after readiness,
   waits 0.5 seconds, samples native science, then sends SIGCONT. Recorded source
   sequence advances 29→34 in the same generation/incarnation. The source loop
   advances its cursor only after exchange adopts the matching command, so this
   establishes required science progress. The receipt does not separately save
   a `/proc` stopped-state snapshot. Render log passes and the final full record
   completes 256 exchanges with the same exact trajectory.
5. Allocation runs complete 512 exchanges each, retain prefix 16, and report
   496 measured exchanges with zero allocated Julia heap bytes, GC time, pauses,
   full sweeps, and allocation counts. Source brackets `Base.gc_num()` after
   completed sequence 16 and after sequence 512, before final serialization.
   Reset clears both counters. The first run includes pause/hold/resume at
   sequence 317. The counters cover Julia heap allocation throughout the
   simulator process; they do not measure the separate JFG process, arbitrary
   native allocations, or CUDA device allocation. No GC disabling workaround
   was found in the inspected installed Julia source. Full-record runs have
   zero measured post-prefix exchanges and provide no allocation evidence.
6. Rehashed all 513 protected files in each installed package against its proof
   and original package: no mismatches. Rehashed the 460 scientific artifacts
   referenced by each run receipt: no mismatches. All five receipts report clean
   systemd exit, removed unit, and confirmed cleanup. Every recorded deployment
   owner and child PID was absent at review time; no processes were changed.

## Finding CIG-001

Severity: medium. Confidence: high. Evidence classification: observed.

The comparator at `scripts/check_native_hil_gui.jl:753` pushes each sustained
`truth` object, compares equality, and reports `truth_equal=true` with scope
“trajectories and truth.” Every reviewed sustained report has
`truth.enabled=false` and `truth.samples=[]`. Equality of disabled empty records
does not establish observed optical-truth equality. Exact detector/command byte
equality remains valid.

Required remediation: retain historical receipts, explicitly report truth as
not evaluated, narrow the comparator scope and success claim to the evidence
actually present, and regenerate only the cold comparison. If a later task
requires truth qualification, it needs enabled, nonempty appropriately scoped
truth observations. Do not rerun science solely to preserve the old wording.

Disposition: corrected and independently verified in isolated GUI worktree
`/tmp/gui-copper-truth-scope`, commits `ebe4f40` and `59cb087` (clean worktree
at review). Only the comparator and its focused cold tests changed. Source now
requires a Boolean enabled flag consistently across all six reports and, when
enabled, a nonempty sample vector. Disabled truth reports `truth_evaluated=false`
and `truth_equal=null`; success depends on exact detector/command equality.
Enabled truth remains compared exactly and contributes to success.

Reviewed the focused regression changes and retained passing log
`/tmp/gui-truth-comparison-focused-cold-v2.log` (108/108); the reviewer did not
rerun those tests. They cover equal/different enabled truth, disabled truth
output, inconsistent enablement, and enabled empty/missing/wrong-type samples,
while retaining trajectory integrity rejection coverage. Read the regenerated
real comparison `/tmp/gui-copper-main-full-trajectory-comparison-v2.json`:
256 exchanges, six equal detector/command hashes unchanged from the initial
review, `success=true`, `truth_evaluated=false`, `truth_equal=null`, and scope
explicitly stating that disabled truth was not evaluated. The old v1 comparison
is historical evidence superseded by v2 for this claim. No science rerun was
needed or performed for this correction. No remaining CIG-001 blocker.

## Claim limits

Functional runs use wall pacing 10 Hz (trajectory cases) or 100 Hz (allocation),
with a 500 Hz model. This review establishes no rate, latency, hardware, visible
window GUI, full deployment allocation, or scientific inverse-equivalence claim.
The allocation run's exact retained prefix covers only 16 frames, not all 512.
The protected-file review supports preservation; it does not independently
validate the scientific correctness of the unchanged model or calibration.
