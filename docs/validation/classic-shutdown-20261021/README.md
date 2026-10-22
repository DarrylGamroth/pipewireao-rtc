# Classic CPU shutdown and recovery — 2026-10-21

Classic's shutdown investigation found a native RTC link-observer lifetime
defect. A listener was removed when its PipeWire proxy was destroyed, then
removed again when the retained WirePlumber Link was finalized. SPA unlinking
leaves its old list pointers intact, so the second removal wrote into freed
memory. Resetting the removed hook fixes this without changing shutdown order,
the five-second operation bound, scientific owners, or upstream WirePlumber.

## Verification

| Check | Result |
| --- | --- |
| Focused native lifetime regression before correction | AddressSanitizer detects the invalid write after native remove-id and final Link release |
| Same regression after correction | Pass; observer rebind and finalization also pass |
| Native RTC suites, memory-checking build | 10/10 pass, zero skips |
| Native RTC suites, ordinary build | 10/10 pass, zero skips |
| Classic CPU Ready → Quit | 11/11; accepted native Quit, exact process/cgroup cleanup |
| Managed 256-exchange CPU loop, Stop and Quit | 2,859/2,859; exact detector/controller replay and complete cleanup |
| Required-link removal and fresh admission | 134/134; stopped source acknowledgement, complete cleanup and fresh Running session |
| Controller exit and fresh admission | 40/40; expected policy shutdown, complete cleanup and fresh Running session |
| Canonical deployment and stopped state | 11/11; installed module matches tested correction, native Quit accepted and all sessions stopped |

The managed replay uses the same 480-sample pupil, five atmospheric layers,
352 × 352 noisy detector, 277-actuator provisional Gaussian mirror and unchanged
calibration as the preceding CPU qualification. Its 500 Hz model advances at
1 Hz wall pacing for observation. Every payload hash matches the preceding
256-frame capture. Mean piston-removed pupil OPD RMS over frames 129–256 remains
51.0336 nm versus 281.0461 nm for the matched zero-command trajectory. No change
to the scientific model or matrices was needed.

The selected registered environment remains RTC 0.2.1, AOS/HIL 0.2.2 and Classic
0.2.4 on Julia 1.13.2. The corrected native module is built from this RTC task's
source against unchanged upstream libwireplumber 0.5.18 and PipeWireAO. Its two
independent optional upstream fixes remain disabled. The normal Julia manifest,
scientific application and CUDA default remain unchanged; validation selects
separately sealed CPU copies with empty CUDA/ROCm visibility. Live process-map
checks and the managed numerical replay's package/library checks exclude GPU
use by this campaign.

## Evidence and limits

The original [CCPU-04](../../reviews/20261021-classic-cpu-loop/REVIEW.md#ccpu-04--initial-run-native-quit-expired-initiating-mechanism-unresolved)
record proves a five-second expiry, but lacks the phase/memory trace needed to
identify its initiating cause. This investigation first reproduced a separate
native crash with temporary Lua tracing, then with the original uninstrumented
policy and a debugger. The memory-checking build localized the earlier invalid
write to the RTC observer. A focused native test reproduced it independently
of the simulator or Lua garbage-collection timing and passes after correction.

The corrected Ready → Quit and full-loop shutdown checks have not repeated the
original timeout. These results do not retrospectively prove that the observer
bug caused that particular historical expiry. No deadline was extended, unknown
operation retried, stopped-source acknowledgement fabricated, or failed record
converted to success. Fault injection may require emergency cleanup when an
outstanding command is lost; that expected fault outcome is distinct from a
healthy native Quit timeout. Failed-cohort service errors remain in the receipt;
fresh healthy cohorts must stop successfully.

Native Quit acknowledgement and complete systemd process cleanup are distinct.
The Ready test's `shutdown_and_cleanup_seconds` includes both and is not a
measurement of the five-second native effect itself. Functional tests and
sanitizer checks do not establish hardware behavior, sustained rate, tail
latency, long-run stability or memory safety for every possible execution.
ASan leak checking is disabled; the checks target invalid memory access.

The [independent review](../../reviews/20261021-classic-shutdown/REVIEW.md)
records source analysis, fail-before/pass-after evidence and limitations.
The [evidence index](EVIDENCE-INDEX.txt) maps retained artifacts; `SHA256SUMS`
identifies the curated source records. Original installed trees, binaries,
captured arrays and debug files remain outside Git at
`/home/dgamroth/workspaces/codex/worktrees/classic-shutdown-20261021/`.
The prefix retains the previously documented SDK symlinks and host dependency
limitations; it is not a hermetic release closure.

## Reproduction

The opt-in [Ready-to-Quit test](../../../test/integration/classic_shutdown.jl)
accepts `CPU_APPLICATION FRESH_STAGE NATIVE_PREFIX`. It admits only a new
non-actuating CPU session with GPU visibility cleared for every owner. It sends
one native Quit, preserves errors, reconciles exact owned cleanup and retains
the manager/owner journals. It writes success only after its outer testset passes.

Use the canonical Classic registered project and its pinned depot, select the
prefix's client config/module/SPA/library paths, and disable automatic package
GC/precompilation. [Prepared fault commands](FAULT-SESSION-COMMANDS.txt) use the
existing fault harness; each case and its recovery use fresh stages. Run cases
serially. The [integration guide](../../../test/integration/README.md) documents
the managed replay and fault interfaces.

Only the corrected RTC endpoint module was installed into the normal local
prefix. The original host, upstream library and Lua policy remain unchanged;
the prior module is backed up outside Git. Deployment hashes are retained in
`canonical-module-deployment.sha256`. The final canonical Ready → Quit check
passes all 11 assertions and leaves no active session units.

Artifact management stays paused. All campaign sessions are stopped. The next
selected instrument is GPI 2.0, using CPU checks while the GPU remains available
for other work.
