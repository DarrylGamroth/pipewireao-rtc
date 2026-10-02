# AOS/HIL deployment review

Initial review date: 2026-10-01; remediation verification: 2026-10-02.
This is independent review evidence for
RTC-ARCH-021 and RTC-DEV-024 through RTC-DEV-026, not an additional normative
contract or a timing/optical qualification. The primary agent adjudicates
findings and owns remediation and integration.

## Reviewed state

| Repository | Starting revision | Worktree and scope |
| --- | --- | --- |
| pipewireao-rtc | `1bc5eaa154cfb43f9df289da4ad0f6118b816a53` | `/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-aos-hil`, branch `work/aos-hil-deployment-20261001`; pre-existing modified deployment and active documentation, new exporter/owner/tests |
| AdaptiveOpticsSim | `d30db3f78d7fad77d0d5e9212b3eee1a34d86244` | `/home/dgamroth/workspaces/codex/rtc-hil-science/AdaptiveOpticsSim.jl`; clean at review start |
| AdaptiveOpticsSimPipeWireHIL | `e0f78f6d8c9e9937914d48b1e12b7df749626659` | sibling science worktree; pre-existing encoding, command validation, model-time and reset changes |
| REVOLTClassicSim | `e0fbdab9a5483d92fa6df5539019624d40b84f1e` | sibling science worktree; clean at inspection |
| REVOLTCopperSim | `cb840cd076ce20a4229bfe82dc1d390f7a1c4f55` | sibling science worktree; clean at inspection |

The reviewer changed only this document. Review covered the exporter, Python
supervisor/broker, Julia owner protocol and simulator, adapter exchange and
configuration, AOS HIL/model-time boundaries and backend selection, and the
maintained instrument graph declarations. Production sources were changing
under primary-agent ownership during this review; dispositions below identify
remediation observed afterward. No benchmark or live session was launched by
the reviewer, and the primary agent's private-core run was not modified.

## Conclusion and ownership

The architecture preserves the intended separation: the simulator owns model
time and scientific state, the adapter copies complete host buffers, existing
FGN/JFG owners execute the calibrated science, and the supervisor coordinates
admission and lifecycle. There is no new data scheduler. Initial review found
two confirmed correctness defects described below. Both corrections passed
independent source review and focused checks on 2026-10-02. Complete live
qualification remains open under HIL003. Subsequent diagnosis confirmed the
native return-capacity defect HIL004 and the independently corrected
ThreadLoop GC deadlock HIL005.

The critical path is:

1. A serialized simulator iteration steps one AOS frame at a fixed model-time
   boundary and synchronizes/stages its target output to a host array.
2. The owner converts the Float32 ADC product to UInt16 row-major transport
   storage before publishing the atomic ready sequence.
3. A PipeWire source callback copies one complete prepared buffer and supplies
   Header/acquisition metadata. The existing science chain produces a command.
4. The command callback checks the pending sequence, timing, length and every
   value before writing the host command buffer, converting µm OPD to m OPD.
5. The owner adopts the corresponding command into the exact AOS target,
   records the completed exchange, then schedules a future wall deadline.

AOS `_copy_hil_buffer!` executes copies and synchronization in its prepared
device context. Those operations remain outside transport callbacks. The new
transport copy code uses public `buffer_memory`/`bytes` views. One frame and one
command can be outstanding; the graph boundary rejects a second frame before
the corresponding command is adopted. Model sequencing does not skip when wall
periods are missed. Reset requires a quiescent exchange, resets the graph and
driver, and advances the acquisition generation.

The recorder is finite: Classic's maximum 256-frame raw buffer occupies
352 × 352 × 256 × 2 = 63,438,848 bytes, plus command/timing arrays. This is
bounded development recording, not a zero-allocation or deadline claim. The
owner uses sleeps and the adapter polls at millisecond scale; neither the
configured rate nor successful exchanges establish maximum throughput.

## Findings

### HIL001 — Rounded model periods rejected by startup validation

- Severity: medium, functional correctness. Confidence: high.
- Classification: confirmed defect; arithmetic reproduced without a live core.
- Affected code: `deployment/export_hil.py:plant_configuration`,
  `deployment/hil/owner_protocol.jl:rounded_period`, and
  `deployment/hil/simulator.jl:validate_graph_timing`.
- Evidence: the exporter writes `round(10⁹ / rate) / 10⁹` seconds and the driver
  uses that integral nanosecond period. The initial validator instead compared
  with `1 / rate` using relative tolerance `10⁻¹²`. At 30 Hz, the exported
  value is 0.033333333 seconds, while 1/30 is 0.033333333333…; relative error
  is approximately 10⁻⁸. A direct Python reproduction rejected 3, 30, 60 and
  144 Hz while accepting 10 and 500 Hz. All are allowed CLI values and satisfy
  the Classic exposure limit.
- Impact: many valid exported packages fail before preparation/admission.
  This is a clock-contract mismatch, not an optical or performance failure.
- Remediation: validate the atmosphere step against `options.period_ns / 1e9`,
  the model clock actually used, and retain a strict comparison.
- Required validation: export a non-divisor rate such as 30 Hz, show the old
  comparison rejects it, show the corrected validation accepts it, and reject
  an independently inconsistent atmosphere step. Check exporter/protocol
  rounding agreement for all allowed integer rates.
- Verification: an independent Python check called the current exporter for
  every integer rate from 1 through 500. All exported steps match the owner's
  integer period formula and the corrected tolerance; 476 fail the former
  unrounded comparison. Three focused Julia assertions verified that the
  former comparison rejects the 30 Hz value, the current
  `validate_graph_timing` accepts it, and an inconsistent 0.034-second step
  is rejected. No plant execution or private core was needed.
- Disposition: closed, independently verified on 2026-10-02. This closes the
  rounded-period defect only; it does not establish achievable wall cadence.

### HIL002 — Adapter errors can bypass deterministic resource teardown

- Severity: medium, failure recovery. Confidence: high.
- Classification: confirmed by source control flow; inherited adapter defect
  relevant to the new deployment error paths. No handle-leak measurement made.
- Affected code: adapter `src/exchange.jl:Base.close`, `stop!`, and
  `prepare_pipewire_hil`; public PipeWireAO `src/stream.jl:set_active!`.
- Evidence: `close(prepared)` initially calls `stop!(prepared)` before its
  `try/finally`. `stop!` calls `set_active!`, which first rethrows any stored
  callback error. An invalid command/frame callback therefore makes close
  exit before either stream, core, context, or loop is closed. Separately,
  preparation creates the loop, context, connection and streams before its
  cleanup `try`; a constructor failure leaves previously created objects
  without an explicit unwind path.
- Impact: failure of a callback does not satisfy the adapter's deterministic
  close contract. The supervisor's finite process termination limits the
  deployment impact, but does not make the reusable adapter cleanup correct.
- Remediation: ensure child-to-parent teardown executes even if deactivation
  fails, retain the first useful error, and unwind each successfully created
  object when preparation fails. Respect PipeWireAO's child ownership and loop
  locking rules; do not close parents while children remain open.
- Required validation: inject a stored callback error into started streams,
  call close, and verify all owned handles close and a second close is safe.
  Exercise a connection or second-stream construction failure and verify
  earlier objects are closed. These tests can use a private core or narrowly
  scoped lifecycle fault injection; no timing benchmark is needed.
- Verification: source construction now begins inside the cleanup `try` and
  tracks successfully created resources. Both construction failure and close
  use `_close_pipewire_resources!`, attempting command stream, frame stream,
  core and context in ownership order, then stopping/closing the loop.
  `_close_pipewire_hil!` catches deactivation errors before teardown and
  preserves them in the returned exception. Running-loop child destruction is
  locked; failed lock acquisition falls back to child cleanup only after a
  successful loop stop. The `closed` flag reflects actual handle state.
  Independent execution of `test/lifecycle.jl` passed all 33 assertions:
  15 for callback/child/lock errors and idempotent close, and 18 for the six
  partial-construction states. These use fake resources through the production
  cleanup functions; they are software control-flow evidence, not a native
  handle-leak measurement or a live callback-fault test. The original
  fail-before evidence is the source path documented above.
- Disposition: closed, independently verified on 2026-10-02 at the adapter
  control-flow level. Native integration cleanup remains part of HIL003.

### HIL003 — Deployment qualification is incomplete at this review cut

- Severity: acceptance gate, not a demonstrated production defect.
  Confidence: high about evidence available at this cut.
- Classification: observed acceptance gap. Historical live failures below were
  subsequently localized and corrected under HIL004, HIL005 and HIL009. The
  remaining acceptance issue is the exact replay discrepancy under HIL010.
- Evidence: the initial assignment reports 151 adapter pure checks, 69 owner
  pure checks plus Classic warm/reset preparation, 45 supervisor checks and
  four exporter checks. A later `python-tests.log` reports 67 tests passing
  with one skip. These are primary-agent evidence, not independently rerun
  here. The read-only log `live-classic-v2.log` ended with
  `source pause ACK timed out`; that does not by itself identify the original
  launch failure or a transport/science root cause.
  At the 2026-10-02 verification cut, the primary agent reports 184 adapter
  checks passing, including the 33 cleanup checks independently rerun here.
  Its latest live evidence still times out at sequence 3 after two successful
  commands. This is partial progress, not a completed finite batch or a
  qualification of any composition. The reviewer did not repeat or alter that
  live run. The later HIL004 investigation establishes the cause of the
  reproduced two-buffer starvation, separately from earlier launch failures.
- Later v2 evidence: independent revalidation of both retained batches in
  `evidence/final-v2-classic-fgn-cpu` passed, with 16 commands per batch,
  required controls, zero owner exits and only the deliberate core TERM.
  Classic JFG v2 also has two valid 16-command batches and successful control
  checks, but Julia exits 1 at teardown; its result correctly lacks `passed`.
  The retained log reports `retained ndarray buffer removed before processing
  completed` at 01:30:40.818928. It is not a qualified JFG deployment.
- Shutdown investigation: source establishes that broker quit pauses ingress,
  then accepts native RTC quit. Rust Stop/Unload stops graph execution, removes
  links, and releases owned sources/parameters. The Python supervisor waits
  for RTC exit before publishing external-owner quit markers. Thus JFG still
  exists when its linked buffers are removed. This ordering is observed in
  source. The later HIL009 diagnostic establishes that the removed loan was
  an unused prefetched output; its narrow correction and final JFG validation
  close this teardown issue.
- Required validation: complete all four installed CPU combinations, preserve
  science/calibration hashes, relocate an installed package, retain correlated
  finite frame/command artifacts and direct encoding/order/unit oracles, and
  demonstrate admission silence, pause/resume, stopped reset, finite completion,
  rejected control survival, dependency death, fresh restart, and foreground
  plus user-service cleanup. A pause should finish an outstanding adoption
  before its ACK. Include a source-ACK timeout/failure case and prove ingress
  revocation precedes consumer teardown.
- Disposition: partially demonstrated. All four final installed CPU profiles,
  declared GPU runs, science preservation, controls, nominal shutdown and the
  two user-service dependency-loss/restart cases have been independently
  reviewed below. The remaining gate is HIL010 localization and adjudication;
  the exact replay failure remains preserved.

### HIL004 — Reliable async output exhausts a negotiated two-buffer pool

- Severity: high, deployed functional progress. Confidence: high.
- Classification: confirmed native return-capacity/negotiation defect. This is
  a finite circular wait, not evidence of an unbounded buffer leak or a
  scientific algorithm failure.
- Affected code: native `src/pipewire/impl-port.c:tee_process_reliable`,
  `src/pipewire/impl-node.c:process_node`,
  `src/pipewire/buffers.c:pw_buffers_negotiate`, and the adapter's command
  buffer request. Native source inspected at
  `167968ecfba9649b563284b39655010789e0a46b`.
- Observed evidence: v9 FGN trace held frame 3 with input mask 3/output mask 2
  through thousands of retries after two completed commands. The v14 probe
  attached to the actual native FGN owner, RTC process 267347, and observed
  these exact states after reliable tee publications of buffers 0 then 1:

  `producer IO = (NEED_DATA, INVALID)`;
  `async cell A = (NEED_DATA, 1)`;
  `async cell B = (NEED_DATA, 0)`;
  negotiated command pool = 2.

  Adapter counters show both commands dequeued and queued back. Frame 3 was
  published but its command timed out. The debugger detached immediately after
  the snapshot. Initial daemon-process probes did not execute this mixer and
  therefore do not provide evidence against the RTC-process observation.
- Derived mechanism: the reliable tee exchanges a returned ID into producer IO
  only when producer IO already has `HAVE_DATA`. Both available IDs can remain
  in the two async cells, leaving no buffer for another publication. In
  addition, `process_node` skips output mixers unless the node reports
  `HAVE_DATA`. Repeated source triggers do not break this circular wait.
- Controlled comparison: cache-only v10b retained non-RT flags, FIFO/reliable
  settings and two source buffers, but requested three command buffers. The
  independently inspected reports show 16 frames/commands, stopped reset,
  another 16 frames/commands, no failure, and supervisor exit 0. Worker
  diagnostic counters identify exactly three reused command-buffer leases and
  two source leases. The worker executed these runs; the reviewer inspected
  the retained reports and `diagnostics/v10b-summary.json`. All commands were
  zero in this probe; it does not establish scientific convergence.
- Contract issue: native ndarray endpoints advertise minimum two buffers and
  existing ASYNC negotiation enforces minimum two. Scheduling documentation
  describes an async minimum of two; no reliable-async minimum of three was
  found. The application must not silently absorb an undocumented native
  progress requirement.
- Adjudicated remediation: the primary agent selected native negotiation of an
  additional reliable reserve, preserving current ownership/return behavior.
  The internal `PW_BUFFERS_FLAG_RELIABLE` must follow output-port
  `reliable`, which selects the actual tee and respects per-port overrides.
  Propagate it in both link allocation and single-port mixer negotiation;
  retain existing sharing, allocator-owned memory and dynamic-data flags.
  Ordinary ASYNC minimum remains two; ASYNC plus reliable minimum becomes
  three; a direct negotiation with neither ASYNC nor another minimum retains
  one. The implemented correction and native tests are reviewed below;
  qualification with an isolated rebuilt prefix remains required.
- Scope constraint: three is sufficient for one async reliable edge (two IO
  slots plus one producer buffer), not a general fanout sufficiency proof.
  Multiple distinct mixes may retain more IDs, and adding a link can reuse an
  existing pool without renegotiation. A stronger global claim needs
  topology-aware reservation or explicit topology restrictions. Qualification
  here covers the single command edge.
- Synchronous-path caveat: `impl-link.c` currently sets ASYNC allocation flags
  unconditionally, even when effective IO is synchronous. Unconditionally
  adding reliable therefore raises that conservative allocation to three for
  reliable synchronous/row links as well. Do not claim unchanged effective
  synchronous link allocation. If avoiding that increase, the implementation
  must use effective async IO including the reliable-driver exception, and
  handle later links reusing a pool allocated earlier.
- Rejected shortcut: do not add an isolated idle branch to the tee and assume
  it will run; the scheduler may skip it. Do not harvest arbitrary NEED_DATA
  IDs without ownership proof: `schedule_mix_input` writes NEED_DATA before
  the consumer callback executes. A return-only redesign would need parity,
  application-release/Busy, exact-once, occupied-producer, fanout and row-borrow
  guarantees. Negotiation avoids changing these ownership rules.
- Required validation: a native fixture must reproduce the negotiated count
  and stalled two-slot state before remediation, cover flag combinations and
  allocator/shared-memory paths, and preserve the existing row-transport tests.
  The real adapter must retain its request for two while the corrected native
  prefix negotiates three and completes finite batches, pause/reset/restart,
  cleanup and exact data/sequence checks. Native tests alone do not qualify
  the four deployment compositions. A package/JLL rollout is a separate
  delivery obligation.
- Implementation verification (2026-10-02): the reviewed
  `pipewire-hil-async-return` diff adds bit 6 in `buffers.h`, raises the
  minimum only for ASYNC plus RELIABLE in `pw_buffers_negotiate`, and sets the
  new flag from output-port `reliable` at both allocation sites. This matches
  the field selecting `schedule_tee_node_reliable`, including port overrides.
  Existing flags are combined without replacing NO_MEM, SHARED or DYNAMIC;
  no ownership, scheduling, memory policy, public struct layout or function
  signature changes were found. `buffers.h` is installed: this is an internal
  negotiation flag in an installed header, not a new SPA/wire flag.
- Native regression verification: the fixture calls actual
  `pw_buffers_negotiate` through two fake SPA nodes. The retained fail-before
  log records request 2/flags 0x60 producing 2 instead of 3 and aborting.
  After correction, an independent CPU-6 execution of the built fixture passed
  all 256 cases: four ASYNC/RELIABLE modes × sixteen combinations of NO_MEM,
  SHARED, DYNAMIC and IN_PRIORITY × requests 2, 1, 3 and 8. It checks count,
  flags, allocated versus allocator-owned data pointers/sizes, dynamic flags
  and clearing. A direct synchronous negotiation retains minimum one,
  ordinary ASYNC retains two, and reliable ASYNC enforces three.
- Native test limits: this fixture does not execute either caller's flag
  selection, the stalled IO-cell state, or live progress. Both fake peers offer
  MemPtr and MemFd, so selection takes MemPtr; SHARED exercises mapped backing,
  but the MemFd-only selection branch is not tested. Requested 8 is below the
  context cap 16; no new hard-cap claim follows. The pre-existing SPA_MAX
  behavior that raises a requested/capped count to the minimum is retained.
  Row regression results and final-prefix runs remain to be reviewed.
- Final functional verification: all four final-v3 CPU compositions completed
  16 + reset + 16 exchanges, controls and clean owner shutdown on the corrected
  prefix with unchanged adapter buffer requests. Source/fixture evidence
  derives the reliable reserve of three from a request of two; no independent
  cold read of the live negotiated count was obtained. Do not present the
  derived count as a measured live pool count.
- Disposition: closed for the demonstrated single-edge progress failure,
  supported by original two-buffer IO-state evidence, negotiation fail/pass
  regression and final functional passes. General fanout progress and a
  direct live pool-count measurement remain outside this qualification.

The inspection used installed library
`/opt/pipewireao/lib/x86_64-linux-gnu/libpipewire-ao-0.3.so.0.1700.0`,
SHA-256 `2514f1f329d6eaf8209ee41f5e07b2d31ad2e312549434e6c0020863d1045fc9`,
Build ID `e51e1910d23e09e88556bd1aff007bbd87ffab10`. Its x86-64 instructions
confirmed the source branch and supplied exact field offsets because this
library has symbols but no debug types. The GDB probe is pinned to those
bytes. Offsets must not be reused on another build.

Evidence under `~/.cache/rtc-aos-hil-20261001/diagnostics/`:

| Artifact | SHA-256 |
| --- | --- |
| `tee-return-snapshot-v14-rtc.txt` | `225f69d42d30c8097a6c44178b7df6b57b77fbb26dd55e52a3bf1723ea608797` |
| `tee-return-snapshot.gdb` | `a6275ddfd133f0de59cc2088ce6ee902545d6703b5772f51e3720f2c9d15a0df` |

Breakpoints perturb timing. These are ownership/progress observations, not
latency measurements. The reviewer changed only this document and cache-only
diagnostic scripts; no production native source or installed binary.

Native remediation evidence under `~/.cache/rtc-aos-hil-20261001/diagnostics/`:

| Artifact | SHA-256 |
| --- | --- |
| `native-negotiate-fail-before.log` | `ffe9c1e77e6295a7b2e4f96e604196033883b58d3df56911cc343beb211c4cd8` |
| `native-negotiate-pass-after.log` | `7086811e16cd87bae70ef74985a8c516188c1f191611924e97a62c03a19db50e` |
| Native `src/pipewire/buffers.c` | `00ea7b71f3a71722e97de0ac1257e647b9037a8122c2db1dfb4ea7f2ba08aad6` |
| Native `src/pipewire/buffers.h` | `5fcc5d4081dbbb708df8fa7862afed9596e8ada78e98b4d4a688e7a2afd52cf6` |
| Native `src/pipewire/impl-link.c` | `676d8ae6bdd3a62dbe4b990b08ed31adb21cf34ef1599559b152d5f5357ef578` |
| Native `src/pipewire/impl-port.c` | `62f214b048b06080dc1e0555b4bfc54e77a56637a3d4206e34ba44aa737ff019` |
| Native `src/tests/test-buffers-negotiate.c` | `c47a33d936883e73270a4539b43ec339d3d3e4f59f0f3dd87a264d57ed2490d0` |

### HIL005 — Blocking ThreadLoop calls prevent callback garbage collection

- Severity: high, process progress and cleanup. Confidence: high.
- Classification: confirmed FFI/GC circular wait, separate from HIL004.
- Affected code: PipeWireAO `src/thread_loop.jl:with_thread_loop_lock`,
  `stop!` and `Base.close`. Reviewed remediation worktree:
  `/home/dgamroth/workspaces/codex/pipewire/PipeWireAO-thread-loop-gc-safe`,
  base `71d567f74d99a618a8225ef608afaa9588f9144f`. Its pending changes
  include the source fix, regression child/test integration, and version
  0.6.11 → 0.6.12; the reviewer did not edit them.
- Observed evidence: `diagnostics/gdb-v8b-connection.txt` records the adopted
  callback thread waiting in `jl_gc_wait_for_the_world` during compilation,
  while the Julia owner is blocked in `pw_thread_loop_lock`/
  `pthread_mutex_lock`. The regression summary records both original lock
  and stop cases timing out after 20 seconds, then both corrected cases exiting
  zero with `GC_CALLBACK_COMPLETE`.
- Derived mechanism: the native loop callback holds the loop mutex and
  requests collection. The owner blocks acquiring that mutex while remaining
  GC-unsafe, preventing the callback's collection from completing. Joining the
  callback thread has the equivalent circular wait.
- Remediation reviewed: the lock and a private `_stop_thread_loop` helper use
  static `@ccall gc_safe=true` with the same library, pointer and C return
  types as the existing bindings. Both explicit stop and running-loop close
  use that helper. This follows the package's existing MainLoop FFI pattern.
  Native stop signals and joins the other thread; it does not run the Julia
  callback on the waiting caller.
- Lifetime review: the lock path retains the loop for the subsequent callback
  and finally block, keeps `native_access_count` elevated throughout, and
  continues to reject close while a native access is active. Explicit stop
  returns the loop after joining. Close nulls the owned handle before joining;
  a later finalizer therefore cannot destroy that handle again. Child ownership,
  callback rooting, lock release, native destruction and public signatures are
  unchanged. The patch adds no guarantee for simultaneous lifecycle operations
  on the same loop; existing caller serialization remains necessary.
- Validation reviewed: `test/runtests.jl` includes `test/loop.jl`, which runs
  separate lock and stop child processes with 20-second deadlines and SIGKILL
  on timeout. The child warms the callback/GC code, uses atomics to establish
  callback entry, then collects on the foreign loop thread while the owner
  enters lock or join. A 100 ms delay encourages that interleaving; it is not
  a deterministic scheduler barrier. The observed fail-before result and GDB
  state establish that the regression reproduces the relevant mechanism on
  this host. `diagnostics/pwa-package-tests.log` reports four GC participation
  assertions passing and the complete package suite passing. These runs were
  performed by the primary agent; the reviewer independently inspected their
  source and retained evidence, without rerunning the suite.
- Disposition: closed by independent source/evidence review on 2026-10-02.
  Packaging and exact-prefix deployment qualification remain delivery work;
  this does not close HIL003 or HIL004.

Evidence and source hashes at this review cut:

| Artifact | SHA-256 |
| --- | --- |
| PWA `src/thread_loop.jl` | `9c05295700fd57e9e20c387cb55316ef34de9806df85329933d9cf5f6f0fd3c9` |
| PWA `test/thread_loop_gc_child.jl` | `32072a855b34b277b91bef39d02b11c8897cf4389e25474e73a5b2c7af6ae1ad` |
| PWA `test/loop.jl` | `be295b8d49550661b51deeb05b4e1801bd453fd45ea5095b1d3417420547ca9b` |
| `diagnostics/thread-loop-gc-regression.txt` | `ab9733ea233f98c498c80d19661ac6f67639088be6767803c2275039ebdd823e` |
| `diagnostics/pwa-package-tests.log` | `aec6755f48bffbda385d877c473fc0ae88669e7407d2562d432a490980986606` |

### HIL006 — Qualification can report success without completing its checks

- Severity: high, acceptance evidence integrity. Confidence: high.
- Classification: confirmed qualification-harness defect, not a demonstrated
  transport failure.
- Affected code: `deployment/check_hil.py:qualify`, initial reviewed hash
  `3cb2875c9bccbaf09165f9b76889923a21fb9aa1ed71591fd6b77ba4c6a5ad52`.
- Observed/derived evidence: after `runner.run()` returns, the harness checks
  only that every process has exited and no run directory remains, then sets
  `passed = True`. It never requires admission, either batch, or the planned
  quit. The deployment intentionally allows a clean early stop, so return
  alone is not completion evidence. An independent temporary fake Deployment
  whose run returns before admission reproduced:
  `{"passed": true, "checks": ["shutdown_clean"], "admitted": false}`.
  No live process or production source was changed by that reproduction.
- Related cleanup gap: `poll() is not None` accepts nonzero and signal exits.
  `wait_owned_process` deliberately escalates to TERM/KILL when grace expires
  and does not reject a nonzero return code. The harness could consequently
  call a killed or failed simulator's teardown clean. This follows from source;
  no live shutdown-fault injection was performed for this review.
- Proposed remediation: require the complete named evidence set and two
  validated finite batches before success. Assert final error state is clear.
  Record owner exit status and termination escalation; require graceful exit
  for simulator/Julia owner/RTC in nominal qualification, while accounting
  explicitly for the private core's intentional termination policy.
- Required validation: a clean early-return fake must fail; missing either
  batch must fail; a nonzero/forced nominal owner exit must fail; the complete
  expected path must pass. Keep actual live cleanup qualification separate.
- Remediation verification: required evidence now includes both batches, quiet
  admission, all planned controls, mid-batch hold/resume, and acknowledged final
  native quit. Every nominal non-core owner must return zero. Independent
  execution of the early-return regression now rejects the original false-pass
  case; all five harness tests pass. Classic FGN v1 evidence contains both
  16-command batches, a held sequence 2, all exit codes zero and final
  stopped/error-null state.
- Further verification: the qualification harness now wraps `os.killpg`,
  recording each attempted signal and owned process role before forwarding it,
  and restores the original function in `finally`. Any non-core or unknown
  role signal rejects qualification, even with a zero exit status. This is
  cold test instrumentation; the production lifecycle is unchanged. Independent
  review found it covers the supervisor's existing TERM/KILL escalation sites.
  All five harness tests passed again. Classic FGN v2 retained evidence shows
  only a core TERM, simulator/RTC exits zero, both required batches and no
  final error. The contemporaneous Classic JFG v2 evidence has Julia exit 1
  and no passed flag, demonstrating that unsuccessful teardown is rejected.
- Disposition: closed, independently verified against harness hash
  `64a91c3e2b868933d9536aa7b99f2d9ae1b97595447f19b26cdc8bce109e9273`.
  Live composition acceptance remains separate under HIL003.

### HIL007 — Retained reports refer to deleted runtime payloads

- Severity: medium, reproducibility of qualification evidence. Confidence: high.
- Classification: confirmed by source path construction and cleanup.
- Affected code: `deployment/check_hil.py:qualify_batch` and report descriptors
  emitted by `deployment/hil/simulator.jl:write_report`.
- Evidence: each batch copies the report and two binaries into the evidence
  directory, but leaves the report's frame/command `file` values pointing to
  absolute paths beneath `runner.runtime`. Deployment cleanup then removes
  that runtime. The harness validator opens exactly those descriptor paths;
  copied reports therefore cannot be revalidated after cleanup. The files and
  hashes are retained, so this is a broken evidence reference, not data loss.
- Proposed remediation: rebase retained descriptors to the durable files, or
  define report-relative payload paths and resolve them against the report
  directory. Preserve original runtime paths separately if needed for
  provenance; update both per-batch and aggregate retained reports.
- Required validation: copy a report/binaries, remove the original runtime,
  then validate both retained batches from their evidence location. For
  relocation claims, move the evidence directory and repeat.
- Remediation verification: copied descriptors now point to durable evidence
  files, retaining original paths as `runtime_file`. Both per-batch and
  aggregate Classic FGN v1 reports independently passed `validate_report`
  after confirming the original runtime payloads no longer exist.
- Disposition: closed for durability after runtime cleanup. The evidence paths
  remain absolute; moving an evidence directory is not supported by this fix
  and no evidence-directory relocation claim is made.

Qualification harness coverage at this cut: its broker client executes on a
worker thread while the supervisor handles the actual socket on its owning
thread, and a check guard prevents recursive qualification during nested
control calls. This preserves serialized source request/ACK ownership in the
planned path. It validates sequences, model timestamps, hashes, finite command
limits and timestamp correlation. It does not independently establish encoding
correctness, numerical plant/RTC agreement, negotiated pool counts, or the
loaded prefix identity. The revised harness now requires a stop after at least one command and before
finite completion, verifies a stable paused sequence during a hold, and
resumes through the public broker. Classic FGN v1 demonstrates that path.
It does not deliberately time the pause request to an outstanding exchange;
that stronger interleaving still relies on the serialized owner contract.
Remaining coverage limits belong to HIL003 rather than additional defects.

### HIL008 — HIL core retains obsolete recorded-device data loops

- Severity: medium, deployment admission/placement. Confidence: high.
- Classification: confirmed installed composition defect.
- Affected code: `deployment/export_hil.py` core transformation and the
  inherited `core.conf.in`. The maintained recorded core defines RTC/source/sink
  loops on CPUs 2/12/8. HIL replaces the recorded devices and declares core
  placement [2, 14], but initially copied all three loop definitions.
- Observed evidence: retained `evidence/final-classic-jfg-cpu/result.json`
  failed before admission with `thread 290305 (source-loop) affinity [12]
  exceeds deployment envelope [2, 14]`. It contains no passed qualification
  or batch checks. This is placement rejection, not a science/GPU failure.
- Remediation reviewed: `hil_core` deep-copies the decoded standard SPA
  configuration, validates the maintained three loop names, and retains only
  `rtc-data-loop`. The exporter decodes through the existing public SPA JSON
  tool and writes the HIL package's core before recomputing artifact hashes.
  The recorded base and scientific/calibration files are untouched.
- Independent verification: all six exporter tests and five harness tests
  passed. Actual installed recorded core files for Classic/Copper × FGN/JFG
  were decoded and transformed; each equals its original with only source/sink
  loop entries removed, and every input object remained unchanged. RTC loop
  properties, modules, objects and other context properties are preserved.
- Required live validation: re-export/reinstall the affected compositions,
  verify actual threads stay within declared placement, then complete all
  required controls and finite batches. A prior Classic FGN v1 pass does not
  qualify the changed v2 exports.
- Disposition: closed. All four final-v3 CPU results passed admission and
  two finite batches; independent checks confirmed every recorded thread mask
  fits its declared role envelope and excludes CPUs 0/1. Final lifecycle
  acceptance remains tracked separately under HIL003.

Reviewed hashes for HIL006–HIL008 corrections:

| Source | SHA-256 |
| --- | --- |
| `deployment/check_hil.py` | `6ac2bb01c7eb5d57427c7640c01315ac03561a643c231b4c3e52b51c6a6e8509` |
| `deployment/export_hil.py` | `cff50c9ed1d0a0a50b1730599bf2590693bc656ba34f289aa0e8ac73ea88aaf3` |
| `deployment/test_check_hil.py` | `a5ec966e0fc3b513f9144149789bdf954956c83ff9b850b9c5eca4caaa4808e5` |
| `deployment/test_export_hil.py` | `f861b4fe7cf9d7792730295cf171c656cf639501e4b4e1b0d2a08c8fb8968bb3` |

### HIL009 — Stopped idle output prefetch removal falsely fails JFG teardown

- Severity: medium, nominal shutdown correctness. Confidence: high.
- Classification: confirmed native lifecycle defect, distinct from pool
  starvation HIL004 and from a lost scientific input or partial result.
- Affected code: native `ndarray-filter.c:process`,
  `invalidate_retained_buffer_on_data_loop` and `filter_remove_buffer`.
- Observed evidence: a separate Classic JFG diagnostic completed 16 commands,
  stopped reset and another 16 commands. Exact-release GDB snapshots identify
  the removed lease as output `demanded` index 0. Every data input is NULL and
  unavailable; the output view flags are zero; processing is unprepared,
  actual run state STOPPED, native state PAUSED, requested state UNKNOWN,
  destroying false and error zero. Synchronized invalidation clears the
  output pointer and returns `was_prepared = false`; the subsequent
  unconditional EPIPE causes Julia exit 1.
- Derived mechanism: `process` prefetches available output buffers before
  deciding all inputs are ready. An extra idle cycle can therefore leave a
  blank output cached without calling the scientific callback. Stop invokes
  deactivate and leaves that cache intact. Removing the link during normal
  native shutdown invalidates that idle cache correctly, but then wrongly
  diagnoses unfinished processing.
- Contract review: public ndarray callbacks borrow pointers only through each
  callback return. FIFO inputs nevertheless remain helper-owned until
  presentation or termination; an output explicitly marked OUTPUT_UNAVAILABLE
  is retained and presented again on a later callback. Pausing does not erase
  these obligations. Therefore neither all-unprepared removal nor every
  stopped output removal is justified by the observed idle-prefetch case.
- Proposed bounded correction: retain synchronized pointer invalidation.
  Exempt only an unprepared, stopped output prefetch that is not explicitly
  retained with OUTPUT_UNAVAILABLE. Capture the relevant output-view flag
  under the data-loop synchronization. Preserve EPIPE for removed data inputs,
  prepared processing, and intentionally retained unavailable outputs.
  Leave public borrowing, run-control and supervisor teardown ordering intact.
- Required validation: show the stopped idle-prefetch fixture fails before and
  passes after; continue rejecting prepared input/output removal, stopped
  retained input removal, and stopped OUTPUT_UNAVAILABLE removal. Verify the
  replacement-pool/resume path cannot reuse stale memory, and repeat the
  previously failing installed JFG shutdown with all owner exit codes zero and
  no owner signals. Run the adjacent admission, feedback, row/lifetime tests.
- Implementation verification: the two-file correction on
  `fix/ndarray-idle-output-removal-20261002` implements the adjudicated guard.
  It snapshots STOPPED on the serialized main-loop callback and snapshots
  OUTPUT_UNAVAILABLE under the existing data-loop synchronization before
  invalidating the pointer. The synchronized atomic exchange supplies
  `was_prepared`. Only STOPPED + unprepared + OUTPUT + not-unavailable returns
  without EPIPE. No extra all-inputs-NULL condition is required: releasing this
  blank output cache neither discards nor modifies a retained input; removal
  of such an input still fails. No borrowing, scheduling or teardown-order
  change was found.
- Regression verification: the exact final test against baseline source
  reaches the stopped-prefetch case and aborts on its expected-zero error
  assertion. After correction, the admission fixture checks that case plus
  stopped retained input, stopped OUTPUT_UNAVAILABLE output, prepared
  RUNNING/STOPPED output, and unprepared RUNNING/UNKNOWN output removals.
  Independent debug and release fixture executions passed. The debug binary
  initially could not load support.system without the build-specific
  `PIPEWIREAO_SPA_PLUGIN_DIR`; it passed with that existing test environment
  restored. Retained logs show all seven selected admission/publication,
  ndarray, buffer negotiation, return and row-lifetime tests passing in both
  debug and release. A later fixture extension then replaces both buffers,
  resumes through the production prepare/process functions and proves that
  the callback uses the replacement output, never the removed buffer; only
  replacement leases are returned and caches clear. Independent source review
  and release-fixture execution passed. This is a software fixture, not a
  new live replacement-pool test.
- Live verification: final-v3 Classic JFG and Copper JFG each completed two
  16-command batches, all required controls and zero owner exits with only
  deliberate private-core TERM. The reviewer independently validated retained
  and aggregate reports, payload hashes, sequences, timestamps, placement and
  exit/signal records. The retained Classic JFG runtime-library observation
  matches installed release SHA-256
  `02220ec0d27016c5eed5947eeeafb87b4b9844686a797a2aebefda75a132d1d7`.
- Disposition: closed for the demonstrated stopped-prefetch defect, with
  fail-before native/JFG evidence and pass-after regression/JFG evidence.
  No production remediation edited by the reviewer.

| HIL009 reviewed source | SHA-256 |
| --- | --- |
| Native `src/pipewire/ndarray-filter.c` | `ef582f277f8e769e28e18428d623c290cb542ccdf64bb2b49a7207a842fb9546` |
| Native `src/tests/test-ndarray-filter-admission.c` | `94c2672b7508a5287a1d72aff9e92f818e7548de092f241423f76a7cb13315e1` |

HIL009 evidence under `~/.cache/rtc-aos-hil-20261001/diagnostics/`:

| Artifact | SHA-256 |
| --- | --- |
| `paused-removal-observation.json` | `22c1f374806b468bb425e1eab810e7f52b22147e7ed5578862ff8419594db97a` |
| `retained-removal-cold-live.txt` | `7bcb1301db20a294eac5affced82077c224c2e03853b778cac1ec4ae01b49fb4` |

The snapshot used release library SHA-256
`7ac46b9847fdef6710e7e5ce8ec5b3b32673c3df9a7fef85c16864d1f1d6b825`
at native revision `5017892d44c6f724e1f18d68cd2aad762914c93b`. It is a
lifecycle/ownership observation, not a latency measurement. Worker diagnostic
text proposing all-unprepared removal is an unadjudicated proposal, not the
independent contract conclusion above.

### HIL010 — Classic JFG exact plant replay differs by one ADC code

- Severity: acceptance nonconformance; impact on the encoding/model boundary
  remains unresolved. Confidence: high in the observed difference, no
  established root cause.
- Classification: confirmed failed exact-replay check, not yet an established
  transport, quantization, RNG, FFT or scientific algorithm defect.
- Evidence: final-v3 Classic JFG records sequence 13, row 209, column 144 as
  216; direct public plant replay with the retained installed environment,
  model clock, warm/reset sequence and recorded commands produces 217.
  Replays on CPUs 6 and 12 agree. Both retained live batches repeat the
  difference. Independent comparison of the complete raw files confirmed
  one mismatch out of 1,982,464 UInt16 samples, with maximum difference one.
  All Classic commands are zero. A direct pre-integer detector observation of
  217.1523895 does not establish the corresponding live value.
- Comparison evidence: Copper JFG replay uses its own recorded nonzero commands
  and matches all 65,536 pixels exactly. The reviewer independently compared
  those raw files and reviewed the replay program's step-before-adopt order,
  exact hash/config checks and unchanged exact mismatch criterion.
- Requirement assessment: RTC-DEV-024 requires maintained science/provenance,
  installed independence and correct encoding/order/units; it does not
  separately require cross-process bitwise model reproducibility. Its stated
  direct-oracle verification remains partial while this mismatch could still
  originate at the source/encoding boundary. Functional transport/control
  success is established separately. Do not describe all RTC-DEV-024 acceptance
  as passed merely because only one code differs.
- Discriminating evidence: capture the actual live public pre-conversion
  product and HIL boundary value at the affected sequence/pixel, with recorded
  configuration/environment and exact output bytes. If live model data itself
  differs and encoding is exact, the functional encoding clause can be
  separated from an explicitly open plant-reproduction nonconformance.
  If conversion/order is wrong, fix that demonstrated boundary defect.
- Diagnostic observation: the isolated cache clone in
  `evidence/diagnostic-classic-jfg-adc` passed 16 + reset + 16 with all four
  processes exiting zero and only the private core receiving TERM. Both raw
  frame files now have SHA-256
  `e5edc87c7fb901c60191cfbe6503be17087cf096c52998e21e366fede53c7813`,
  identical to the direct replay. At the affected sequence/pixel both batches
  record public pre-integer ADC 217.1523895263672, detector UInt16 217,
  graph Float32 ADC 217 and recorder UInt16 217. The reviewer validated both
  reports with the original validator and checked the instrumentation diff:
  targeted reads after completed exchange into bounded preallocated arrays,
  plan descriptions before connect, report serialization after the batch.
  No science formula or production simulator change was introduced. The
  instrumented run is not cadence evidence.
- Diagnostic provenance: aggregate result SHA-256
  `3ae1413904fdc64118880bd1fb1ef2522198d33f0b386d686354f1dd7ab156b2`;
  batch-report hashes
  `dc6e128cac03c8d49582ba485336dc0b436e688b50ce21934e527ed639bdfe51`
  and `4b0bd5343b54fe4be2eb42e4f77d1564e22e3a3bf6657bc5bcd22747b8b9a792`.
  This successful run does not reproduce or localize the original 216 sample.
  Different live/direct FFT plan descriptions with matching images do not
  establish an FFT cause.
- Next discriminating measurement: when 216 recurs, retain the same targeted
  public pre-integer, detector, HIL boundary and recorder values plus model
  target, RNG/reset state or reproducible state fingerprints, FFT plan
  descriptions, environment/configuration hashes and raw bytes. Compare with
  the retained failing and matching cases before changing implementation.
- Disposition: open. Primary adjudication accepts merge of the demonstrated
  functional non-actuating implementation while RTC-DEV-024/HIL003 remain
  partial. The original failed exact replay, exit status, artifacts and hashes
  remain retained; this diagnostic is not a pass-after for the discrepancy.
  No tolerance, model coefficient or scientific code change is authorized by
  this finding.

## Final installed evidence review (2026-10-02)

The reviewer independently revalidated both saved per-batch reports and their
aggregate descriptors for all four final-v3 CPU compositions. Each contains
16 frames and matching commands, then stopped reset and another 16. Required
control evidence includes quiet sequence-zero admission, a stable mid-batch
pause, resume, rejection survival, stopped reset and final quit. Every
non-core owner exited zero without supervisor TERM/KILL; only the private core
received its intentional TERM. All recorded thread masks fit declared role
envelopes and exclude CPUs 0/1. These runs establish functional exchange and
foreground lifecycle, not deadline compliance.

| Retained evidence directory | Completed exchanges | Result |
| --- | --- | --- |
| `final-v3-classic-fgn-cpu` | 16 + 16 | pass; commands zero |
| `final-v3-classic-jfg-cpu` | 16 + 16 | pass; commands zero |
| `final-v3-copper-fgn-cpu` | 16 + 16 | pass; nonzero commands |
| `final-v3-copper-jfg-cpu` | 16 + 16 | pass; nonzero commands |
| `final-copper-fgn-cuda` | 16 + 16 | pass; selected CUDA target |
| `final-copper-fgn-cuda100` | 16 + 16 | pass; selected CUDA target |
| `final-copper-fgn-amdgpu-v3` | 16 + 16 | pass; selected AMDGPU target |

GPU evidence was independently revalidated, including payloads and actual
thread placement. AMDGPU v3 declares
`HSA_OVERRIDE_CPU_AFFINITY_DEBUG=0` in the installed owner environment.
The earlier run with broadened ROCr helper affinity failed admission and is
not counted. CUDA100 retains a 10 ms model step and sequential model time;
its second batch observed 44.63698 publications/s and 19 missed wall periods.
The first batch includes an intentional pause and startup effects. Neither
batch is a sustained-rate benchmark or evidence of 100 Hz wall operation.
The optional GPU runs preceded the second, idle-output-removal native fix;
their functional result is not an exact-second-prefix GPU rerun.

Independent byte/provenance checks covered all 1,140 declared artifacts across
the four installed CPU packages. The listed preserved science sets contained
15 Classic FGN, 143 Classic JFG, 11 Copper FGN and 137 Copper JFG files,
including calibration payloads, graph declarations and owner code. All match
both the retained preservation audit and their recorded-profile originals.
Every existing original provenance field except the intentionally changed
`runtime_requires` also matches. An initial audit listed two absent provenance
keys as preserved; the primary corrected that evidence to require actual key
presence. The independent check did not rely on absent-key equality.

All installed HIL and JFG Manifest path dependencies checked are relative and
resolve within their package: four for each FGN profile and eight across each
JFG profile's two environments. Execution after export/install demonstrates
those installed paths; moving a retained evidence directory remains outside
the absolute-descriptor format.

The Copper direct CPU replay program was independently source-reviewed and
its result/program/graph/provenance hashes checked. It compares each direct
frame before adopting that frame's recorded plant-unit command, reproducing
warm/reset ordering and the declared model clock. It records exact agreement
for 65,536 UInt16 row-major pixels across 16 frames and 4,432 nonzero command
components, maximum 0.26691416 µm OPD, none at the limiter. This is
plant/recorded-command causality and encoding evidence. It does not reconstruct
the RTC controller independently or observe wire-unit commands, so it cannot
by itself establish calibration equivalence, transport scaling, convergence,
or physical correctness. Nonzero scale/order validation remains provided by
adapter boundary tests.

An independent run of the current supervisor, exporter and evidence test
modules passed 58 tests. Source review confirms software fault coverage for
source ACK deadlines, identity/shape rejection, stale ACKs, owner death,
unknown native mutation outcomes without retry, and forced ingress revocation
before consumer cleanup. These tests mock the relevant failure boundaries;
they are distinct from the live user-service fault/restart evidence reviewed
in the following section. Classic JFG exact-environment replay retains the
one-code discrepancy documented under HIL010. Its mechanism is unresolved;
no established RNG, numerical or transport cause or cross-engine plant
equivalence is claimed.

### User-service and required-owner fault evidence

Independent review of `user-v3-copper-fgn-cpu` and
`user-v3-copper-jfg-cpu` validated both retained and aggregate 16 + reset + 16
reports. The user-unit harness waits for systemd start completion and verifies
an active unit with an admitted Running supervisor, consistent with Type=notify
readiness. Normal quit reaches inactive/dead, Result=success, ExecMainStatus=0.

Each unit then starts a fresh runtime instance and simulator PID. The harness
sends that required simulator TERM and records failed/exit-code/ExecMainStatus=1.
Its fault journal is filtered by the captured systemd invocation ID. In both
runs the matching RTC PID reports the simulator-command external node
disappeared, then the supervisor reports required RTC exit 1. This is a valid
dependency-loss observation even when native graph detection wins the race
against direct simulator-process polling.

The retained fault checks assert every owned PID is gone and no run directory
survives. Independent `/proc` checks confirmed all recorded owners and both
supervisors from nominal/fault invocations are absent. A read-only systemd
query confirmed both units now inactive/dead with MainPID=0 after test cleanup.
The injected termination journal includes Julia finalizer/context warnings;
they belong to the forced dependency-loss path and are not nominal teardown
success evidence.

These results close the user-service, fresh-instance restart and injected
required-owner-loss evidence gaps. They do not constitute an additional live
ACK-delay injection or prove shutdown under every fault interleaving. ACK
deadline and ingress-revocation ordering have separate focused software tests.
HIL003 now waits on the exact-environment direct replay investigation, not on
service qualification.

## Final claim and provenance review

The current validation prose and evidence JSON retain the failed exact Classic
JFG replay and mark RTC-DEV-024 partial pending localization. They distinguish
functional transport from calibration, convergence and hard real time; GPU
runs on native revision `5017892d4` are not represented as reruns on the later
CPU/user-unit native revision `7e17c0fa2`. Independent recursive checks of 30
current referenced records, graph files, raw replay files and RTC source
hashes found no missing file or hash mismatch. Evidence paths are local
retained artifacts; the JSON does not make them externally portable.

The row-major encoding, command order and micrometre-to-metre boundary are
separable from cross-process bitwise plant reproducibility. If live public
pre-encoding products reproduce the recorded code exactly and differ from
the standalone plant upstream, the functional boundary clause can be closed
while HIL010 remains an explicit model-reproduction nonconformance. Until
that distinction is measured, a source/encoding defect has not been excluded.
No numerical tolerance or weakened replay assertion is accepted here.

## Remediation verification record

The independent focused Julia command used Julia 1.12.7, one Julia worker,
CPU 6, and the existing owner environment:

```text
taskset -c 6 julia --startup-file=no --threads=1,0 \
  --project=/home/dgamroth/.cache/rtc-aos-hil-20261001/owner -
```

The stdin script loaded the current `deployment/hil/simulator.jl`, ran the
three timing assertions described under HIL001 in a temporary directory, and
included the adapter's `test/lifecycle.jl`. Result: 3 + 15 + 18 assertions
passed. The separate Python sweep used the actual `plant_configuration`
exporter and checked all 500 rates. No live core, accelerator, or benchmark was
started. Only this review document was edited by the reviewer.

| Reviewed source | SHA-256 at verification |
| --- | --- |
| RTC `deployment/hil/simulator.jl` | `2a3f37f27cf3fd0c14e825508807fb5dee2b323c3669440ca867bedade3ab1f4` |
| Adapter `src/exchange.jl` | `0f52e59550b18dd3ba2016f527bf770cc5c4d1efc6d815aa8ff0023bfad8993c` |
| Adapter `test/lifecycle.jl` | `a084cf7fe86b0d3d5532a0e1cc1e49b47e830b382a4958fc2720c4122679a49a` |

## Checked boundaries and limits

- **Installed sources:** the final installed environments have four relative
  path dependencies for each FGN profile and eight across each JFG profile's
  two environments. They resolve within the installed package, including the
  snapshotted PipeWireAO owner dependency. The exporter hashes package sources
  and resolved Manifests; execution after export/install verifies the installed
  paths. Julia and the selected PipeWireAO native prefix remain explicit runtime
  dependencies.
- **Maintained science:** `hil_session` replaces the first device source/sink,
  adjusts their link/port names and group membership, and leaves the science
  declarations/calibration payloads intact. Rate fields change explicitly.
  Final artifact hashes have been independently checked above. Scientific
  output equivalence is a separate claim; the Classic JFG replay discrepancy
  remains under investigation.
- **Units/order:** `COMMAND_TO_METRES = 1.0f-6`; each of the 277 command values
  keeps its index. Complete finite-value/conversion validation precedes any
  host command mutation. Frame traversal reverses Julia's index-product order
  to provide row-major bytes; the recorder uses the corresponding row/column
  traversal. UInt16 conversion uses nearest, ties to even. No gain, controller
  coefficient, reconstructor, clipping-feedback or HEART change was found in
  the reviewed integration code.
- **Scientific claims:** grid-Gaussian HSDM277 influence models remain
  provisional. Finite bounded commands and command clipping are functional
  observations; neither establishes convergence, correct calibration for this
  plant, residual wavefront error, or physical-loop safety.
- **Backend viability:** CUDA device ordinal 0 and AMDGPU device identifier 1
  match the AOS extension APIs inspected. Availability is checked explicitly,
  backend packages enter only selected exported environments, and no CPU
  fallback branch was found. AOS target preparation and host staging use the
  public boundary. Later installed Copper FGN runs demonstrate selected CUDA
  and AMDGPU execution as recorded above; they do not qualify every
  instrument/engine/backend combination or establish a maximum rate.
- **Control/recovery:** the public broker serializes requests, validates request
  bounds and identity, forwards scientific operations to the private Rust
  executor, and coordinates pause before stop and graph start before resume.
  Positive monotonic owner IDs, matching ACKs and current-instance directories
  protect normal control exchange. Completed finite sources reject further
  start until reset. Transport timeout/disconnect is reported as an unknown
  mutation outcome without replay. Unconfirmed source control invokes owned
  source/core termination before graceful consumer cleanup.
- **Placement:** exported source placement uses CPUs 6/14, core placement
  CPUs 2/14, and existing science placement is retained. Maintained envelopes
  exclude CPUs 0/1. Thread/resource admission remains the supervisor's job;
  requested affinity alone is not measured effective placement.

The review has not established an additional scheduler, hidden accelerator
fallback, or scientific convergence defect. Unmeasured backend combinations
and the Classic JFG reproducibility difference remain unqualified rather than
being promoted to established root causes.
