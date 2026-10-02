# HEART HIL deployment review

Independent review, 2026-10-02. This is review evidence, not an extension of the
active architecture or an assertion of physical qualification.

## Scope and reviewed revisions

The selected path is AOS → SPA Standard WFS sink → UDP → unchanged native
HEART → UDP → SPA Standard DM source → AOS. Acceptance is finite CPU
Classic/Copper exchange with owned lifecycle, exact payload order, explicit
units and placement. GPU, paced-readout performance, convergence and physical
actuation are outside this increment.

- RTC worktree: `/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-heart-hil`,
  branch `work/heart-hil-deployment-20261002`, baseline
  `7b5bc3c8bdbcc990b958769dfd59552c5f0858e6`.
- Plugin worktree: `/home/dgamroth/workspaces/codex/pipewire/pipewireao-spa-plugin-heart-dm-metadata`,
  branch `fix/dm-optional-metadata-20261002`, baseline
  `10388618bbf8493612cb1d852ccc0e018faa3c87`.
- Adapter worktree: `/home/dgamroth/workspaces/codex/AdaptiveOpticsSimPipeWireHIL-heart-stride`,
  branch `fix/frame-chunk-stride-20261002`, baseline
  `6adb85a9e96bed12a0f9084a0550e7d9f2230d71`.
- The RTC/plugin worktrees already contained the implementation under review. The reviewer
  changed only this artifact. The native HEART tree has unrelated untracked
  files; it was read without modification.
- Active authority: RTC-ARCH-022 and RTC-DEV-028, with RTC-DEV-025 through
  RTC-DEV-027 retained. Existing HIL scientific limitations remain applicable.
- Retained experiment root: `/home/dgamroth/.cache/rtc-heart-hil-20261002`.

No blocking review finding remains for the selected finite CPU deployment.
The stride and cleanup defects are corrected, the final exporter defaults are
reviewed, and the reviewer independently recomputed accepted Classic07 and
Copper03-paced wire evidence. Earlier failed batches remain failures. This
acceptance does not extend to other rates, packet intervals, physical units,
network generation isolation, GPUs or scientific convergence.

## Ownership and lifecycle analysis

The simulator owns optics, detector RNG, model time, frame publication and
command adoption. Only one frame and matching command may be in flight. Julia
work and host staging occur outside SPA callbacks. The private PipeWire core
owns the two bridge nodes. Rust owns exact links and serialized session control;
`external-rtc` admits no graphs, groups, observations or scientific updates.

The native wrapper owns one HEART child and its command client. It checks the
child's actual listening socket, then requires INIT, RUN, enable-flag and CORRECT
acknowledgements before readiness. Worker affinity and scheduler declarations
are checked after the correcting state is entered. The simulator remains held
until endpoint/link admission and session start have completed.

Pause completes an outstanding exchange before acknowledgement. Stopped reset
stops the simulator streams, restarts HEART, resets simulator state, then starts
held streams. The owner uses one absolute 12-second reset deadline; simulator
and supervisor limits are 14 and 16 seconds. Exhausted reset preparation faults
the owner and kills/reaps a partially started replacement. Native stdDM counters
restart from a fresh child, without a network generation identifier.

Shutdown waits for the simulator process to close before authorizing other
owners' graceful quit markers. If closure fails, private core/source revocation
precedes forced consumer cleanup. Native SHUTDOWN output (including an observed repeated held command) therefore
must not be adopted as a new simulator command. Generic supervisor tests cover
closure failure and marker rejection paths. No claim of hard real-time latency,
reserved physical cores or bounded disk growth follows from this control design;
logs are files and CPU affinity alone is not exclusive CPU reservation.

## Scientific and transport checks

Observed from source and offline artifact inspection:

- The simulator records UInt16 frames in row-major order. The WFS sink encodes
  raw pixels; the selected stdWfs raw tag is 1, not 0. Classic uses 352 × 352
  frames, Copper 64 × 64. Export binds the native detector ROI to both bridge
  offsets: Classic `(row=0, column=0)` and Copper `(844, 1044)`.
- `write_offset_fits` writes big-endian Float32 values, reverses array extents
  into FITS axes, and pads header/data to 2880-byte blocks. Classic05 installed
  background contains 123904 values, references 376 values; every decoded
  Float32 equals its original little-endian calibration payload.
- Native `hrtConfigVerify.c` expects NCPA rows=188 and columns=2. The native FITS
  reader reads contiguous pixels; `hrtWfsProc.c` subtracts reference x,y fields
  per subaperture. This agrees with the exporter axes `NAXIS1=2`, `NAXIS2=188`
  and the simulation reference generator's pair-interleaved x,y convention.
- Native configuration drops recorded dark/sky/flat detector corrections and
  supplies the simulated background and Classic reference files. Empty native
  PDM flat/offset files follow the zero-figure plant. Matrices, thresholds,
  masks and native controller laws remain hybrid calibration.
- All 361 cells of the native 19 × 19 actuator map equal the maintained
  Classic/Copper model construction, with every command index 1…277 occurring
  once. Source row/pupil orientation remains an explicitly provisional model
  convention, not measured registration.
- The SPA stdDM decoder computes Float32(Float64(wire μm) × 10⁻⁶). HEART-mode
  AOS transport uses scale 1.0 on the resulting metres. The offline wire checker
  compares each retained command byte after that exact conversion, so successful
  capture comparison can establish all 277 array coordinates without permutation.
  It cannot establish physical OPD versus mechanical displacement.
- The plugin fix keeps data and Header mandatory while making Acquisition and
  HeartStdDm annotations optional. Optional acquisition metadata remains
  deliberately unqualified because stdDM lacks domain/generation identity.
  Header sequence continues to carry native idFrame. No new queue or numerical
  hot-path operation is introduced by this metadata fix.

## Findings and dispositions

### HEART-HIL-001 — rank-two source chunk stride

- Severity: high. Confidence: high; adapter remediation independently inspected.
- Classification: confirmed integration defect, reported by the primary agent
  with native WFS timeout and absence of captured WFS datagrams in Classic05.
- Evidence: the source adapter publishes a rank-two UInt16 frame chunk stride
  of 2 bytes while the WFS sink requires the negotiated row stride of 704 for
  a 352-column frame. Source/sink representation contracts disagree before
  native reconstruction. Classic05 does not establish finite exchange.
- Remediation: correct the source chunk stride at the adapter owner and retain
  the row-major payload and scientific models. Check all other callers of the
  affected adapter routine for the same convention.
- Required validation: fail-before/pass-after adapter coverage and installed
  Classic/Copper finite exchanges through both UDP legs, then regression of
  the existing scientific transport.
- Disposition: closed. Source remediation and installed verification accepted.
  Reviewed `AdaptiveOpticsSimPipeWireHIL-heart-stride/src/exchange.jl` and
  `test/transport.jl`. The stored `Int32` frame stride is computed before the
  callback using exactly the published ndarray format. It matches public native
  `src/pipewire/ndarray-filter.c` format sizing and FGN `storage_init`: element
  bytes × last extent for row-major, first extent for column-major. Validated
  formats have nonempty positive Int32 dimensions, permitted layouts and checked
  total byte size; stride overflow is rejected before callback execution.
  The frame payload copy and command acceptance are unchanged. Rank-one and
  rank-three tests avoid assuming that every ndarray is a rank-two image.

### HEART-HIL-002 — command physical convention is unqualified

- Severity: medium for any physical/scientific interpretation. Confidence: high.
- Classification: known limitation, not a newly demonstrated numerical defect.
- Evidence: export provenance explicitly labels the numerical OPD interpretation
  provisional; stdDM supplies dimensional conversion but no optical factor of
  two or measured influence calibration. The HSDM model also labels orientation
  and influence functions provisional.
- Remediation: retain the qualification boundary. A later physical/scientific
  claim requires authoritative mirror convention, sign, pupil registration and
  interaction calibration evidence.
- Required validation: separate physical/plant oracle; finite loopback payload
  comparison is insufficient.
- Disposition: accepted limitation for this non-actuating increment; no blocking
  convergence or hardware requirement added.

### HEART-HIL-003 — reset does not fence prior-generation network packets

- Severity: medium outside the private finite fixture. Confidence: high.
- Classification: known protocol limitation.
- Evidence: fresh native children restart local frame IDs; stdDM has no domain
  or generation field and the source does not invent one. Simulator stream
  reset is not a proof against arbitrarily delayed old datagrams.
- Remediation: restrict claims to sequential private-loopback runs; a later
  network deployment needs a documented epoch/fencing mechanism and delayed
  packet tests.
- Required validation: ordinary reset/restart evidence for this increment;
  adversarial cross-generation tests before stronger isolation claims.
- Disposition: accepted and documented scope limitation.

### HEART-HIL-004 — wire checker omits explicit ROI assertions

- Severity: low. Confidence: high.
- Classification: evidence improvement, not an observed malformed live packet.
- Evidence: `check_heart_wire.py` unpacks columns, rows and row/column origins
  but does not compare them to the selected profile. Payload equality proves
  pixel bytes and order, but does not independently prove geometry fields.
- Remediation: compare each packet's geometry and ROI with the exported profile
  and add an offline wrong-ROI rejection case.
- Required validation: unchanged accepted captures and rejection of mutated ROI.
- Disposition: closed. The checker now compares width, packet rows, detector ROI
  and packet count with the exported provenance; the wrong-ROI mutation test
  passes by rejecting the altered packet.

### HEART-HIL-005 — diagnostic capture can bypass owned cleanup

- Severity: high for qualification-harness cleanup. Confidence: high.
- Classification: confirmed source defect in a subsequent review update.
- Evidence: the new `check_hil.py` stop wrapper copies native logs/status before
  calling `original_stop()`. A copy error exits that wrapper without stopping
  processes. `Deployment.run` catches the stop error and removes its runtime
  in a finally block; it does not invoke stop a second time. Disk-full or a
  file race can therefore leave owned children alive while losing their markers.
- Remediation: always invoke `original_stop()` in a finally block around evidence
  capture. Preserve capture failure diagnostics without bypassing cleanup.
- Required validation: inject a copy exception and demonstrate original stop
  runs exactly once; normal evidence capture must still pass.
- Disposition: closed. The final wrapper calls `original_stop()` first and
  copies flushed diagnostics in its finally block before runtime deletion.
  An injected `OSError("disk full")` confirms the original stop is called
  exactly once while the copy error remains visible.

### HEART-HIL-006 — shutdown output retains the last native frame ID

- Severity: medium for evidence classification. Confidence: high for observation;
  the exact native shutdown propagation is derived from the logs and source.
- Classification: confirmed wire-checker assumption error; no demonstrated
  extra simulator adoption.
- Evidence: Classic06 completes two 16-frame batches with all owner exits zero.
  Its capture contains accepted DM IDs 1…16, an extra 16, IDs 1…16, another extra
  16. Each extra has a new native timestamp and the last accepted payload,
  including all 277 nonzero coordinates. `check_heart_wire.py` originally
  recognized only frame-zero shutdown packets and therefore rejects this capture.
  Native `heart-1.log` records SHUTDOWN, WFS peer disconnect at
  13:13:19.272686, an invalid partial frame and a forced downstream trigger;
  the first extra packet arrives at 13:13:19.273030. The stdDM stop callback
  itself closes its socket; it does not generate a zero command.
- Remediation: distinguish expected frame/command exchanges from output emitted
  while the streams are held/closed using explicit lifecycle evidence. Preserve
  unexpected active-exchange duplicate rejection. Describe shutdown output
  generically; zero/flat is not the only observed payload.
- Required validation: exact 32 accepted frame/command matches, explicit
  accounting for the two additional packets, and negative tests for duplicates
  during an outstanding exchange or altered extra payloads.
- Disposition: closed. Corrected checker and new capture evidence independently
  verified for Classic07 and Copper03-paced. Complete WFS reception establishes one pending frame. Accepted DM
  must match it; repeats without a pending frame require a recorded reset or
  shutdown realtime interval and equality with the previous converted command.
  Ordinary duplicates still fail. The reviewer reran all 12 wire/report tests
  successfully after this change. The subsequently added changed-payload test
  preserves the checksum but rejects the altered command inside the valid window.

### HEART-HIL-007 — child-death harness bypasses supervisor detection

- Severity: low. Confidence: high.
- Classification: validation gap, not an observed supervisor defect.
- Evidence: after confirming the killed child's owner exits nonzero, the initial
  `check_heart_failure.py` raises its own `DeploymentError`. This exercises
  wrapper monitoring and cleanup but bypasses the supervisor's dependency check.
- Remediation: invoke `runner.check_processes()` after the observed owner exit
  and require its actual required-owner failure to propagate; fail if it does
  not detect the dependency loss.
- Required validation: retained installed failure evidence must identify the
  supervisor's real required-owner-death diagnostic and complete cleanup.
- Disposition: source correction accepted. The harness now invokes
  `runner.check_processes()` and fails if dependency death is not detected.
  Installed `evidence/heart-child-death.json` passes: the actual error is
  `required heart exited with status 1`, the source is held at sequence zero,
  admission remains false, all owned processes are reaped and runtime is removed.
  Simulator SIGTERM and RTC SIGKILL are the recorded fault cleanup fallback;
  they are not represented as graceful normal shutdown.

## Independent verification performed

Command, from `deployment/`:

```sh
python3 -m unittest test_export_heart_hil test_check_heart_wire test_check_hil test_deploy test_heart_owner.ProtocolTests
```

Observed: 71 tests pass. ProcessTests were intentionally excluded because they
bind TCP 5001 and a live HIL investigation was active. These tests cover exact
FITS encoding, wire corruption/sequence rejection, owner protocol/placement,
source reset deadlines and shutdown ordering. The native wrapper process tests
and plugin sanitizer results reported by the primary agent are separate
verification evidence, not reruns performed by this reviewer.

After HEART-HIL-004/005 remediation, the reviewer reran `python3 -m unittest
test_check_hil test_check_heart_wire`: 11 tests passed, including wrong-ROI
rejection and diagnostic-copy-failure cleanup.

Additional offline checks: exact Float32 comparison of installed Classic05
background/reference FITS, all-cell actuator map comparison with the model,
native reference-reader source inspection, and plugin `git diff --check`.
The exporter adapter override was also inspected: it requires a byte-identical
`Project.toml`, snapshots package sources in the installed environment, records
revision/source identity and refreshes package artifact hashes. It changes the
transport adapter source while retaining the frozen dependency declarations.

No live HEART command, physical device, GPU or performance test was run by this
reviewer. Final production source was reconciled after the profile readout-default change.
Canonical relocation checks planned by the primary agent are additional delivery
checks; the acceptance here identifies the retained packages below.

## Installed evidence independently rechecked

The reviewer revalidated all 349 installed Classic06/07 package artifact hashes
and all 342 Copper03-paced hashes. Both retained batch reports per profile pass
`validate_report`: 16 ADC frames and 16 matched commands each, sequence 1…16,
finite bounded values, correct model timestamps and exact binary hashes. Each
native generation records 27 threads with CPUs 0/1 excluded. New native PIDs
and generation 1→2 accompany reset. Normal-run core, HEART owner, simulator and
Rust runner all exit zero; only the private core receives the expected supervisor
termination signal.

| Retained run | Finite exchange | Maximum absolute command (μm) | Nonzero components per batch | Wire capture |
| --- | --- | --- | --- | --- |
| Classic06 | 2 × 16 pass | 0.079423636 | 4432 | historical: checker exposed last-ID shutdown repeats |
| Classic07 | 2 × 16 pass | 0.079423636 | 4432 | independently recomputed: 32 frames, 32 commands, two held repeats |
| Copper03-paced | 2 × 16 pass | 0.0028858127 | 4155 | independently recomputed: 32 frames, 32 commands, two held repeats |

Copper's captured detector shape is 64 × 64 and ROI is `(844, 1044)`. All
frame bytes and all 277 command coordinates match the simulator artifacts,
with exactly one Float32 micrometre-to-metre conversion. Both extra held
commands fall inside recorded reset/shutdown windows and equal the previously
accepted command. Flushed native logs retain shutdown peer-disconnect,
incomplete-frame and downstream-invalid diagnostics. Those diagnostics occur
with shutdown and are not suppressed or described as successful WFS frames.

The selected Copper package requires 2000 μs packet readout pacing for the
observed finite exchange. Copper02 with zero pacing transmitted its two WFS
packets but timed out without an accepted command; Copper03 changes only that
readout setting and passes. This is an observed compatibility discriminator,
not proof of the internal cause or a qualified pacing/rate envelope. Do not
promote a suspected first-chunk race to a confirmed root cause. The unchanged
native HEART implementation remains outside this remediation.

The final independent offline Python selection passes 76 tests, including valid-checksum
altered held-command rejection inside a valid shutdown interval. The source
snapshot of the earlier Copper01 export predates the stride repair and is not
the accepted installed Copper03-paced package. Failed earlier exports/runs remain
retained rather than being relabelled as passing evidence.

## Final review freeze

The final exporter default chooses 0 μs for Classic and 2000 μs for Copper,
permits an explicit override, and rejects nonpositive/noninteger rates,
noninteger/negative readout and readout occupying at least 95% of a period.
This selects the demonstrated Copper fixture without asserting a minimum safe
delay. The implementation and boundary tests were inspected and included in
the final 76-test independent rerun.

Primary-run logs were separately read: Python reports 117 tests with one skip
(the environment-gated export prerequisite test); Julia owner protocol has
77 passes and simulator checks 23 passes. Rust workspace log reports no failed
tests and retains an explicitly ignored private-core fixture. These are distinct
from the installed live runs reviewed above. The primary reports 232 focused
adapter tests, eight fail-before stride failures and eight zero-allocation copy
cases. Plugin normal/sanitizer runs are reported as six passing tests each.
The reviewer independently inspected their source changes and the installed
integration evidence; it did not rerun those Julia/plugin suites.

Merged transport fixes: plugin `9aeea5334d03874dcfffc6bc29c8187f2774705a` and
adapter `277d822`. The RTC changes remain in their dedicated worktree at this
review freeze. Source hashes below identify the reviewed production/evidence
logic independently of a later RTC commit or documentation edit.

| Reviewed RTC path | SHA-256 |
| --- | --- |
| `src/config.rs` | `83fe7bb3903fb8076545ee3a41e3644780b8cf1b38b939da82c25cbc98075552` |
| `src/config/decode.rs` | `1b7826ab5f54f70e4f20eb87cf9c68244bf75e84e339f08f82f67f9ddcfcd265` |
| `deployment/export_heart_hil.py` | `f90bf49860cd41ff42868d536d8bab0cea3b7702d7609b76619a9a7d4b4624a3` |
| `deployment/deploy.py` | `681e623b75bd7f9197ae223c55813f226abf3fc17ba4fa126dae5ae61fec6f53` |
| `deployment/hil/heart_owner.py` | `ff01b178568131c857cff6a0a30b65fa70bee30d9bedee6b6fc5ce6c71de9370` |
| `deployment/hil/simulator.jl` | `ed553e7abc220793b63637c7131785274d8fbdab204f840c9e6d2615f4455ac1` |
| `deployment/hil/owner_protocol.jl` | `77e9e934099486b6a2b6bf09af21752cf63e9976a73fea986685c1d6caf56d06` |
| `deployment/check_hil.py` | `6088e187ff118651c15b840ffc13c5d19ae9b9f1516cf7acc22b0a3b8cef8d4c` |
| `deployment/check_heart_wire.py` | `cd6007d84aec30a28949a763b6506ebaa4af0c954e1de9ac41835f84f3fdf5be` |
| `deployment/check_heart_failure.py` | `58a431e58176390b31745a9e502c23de4604e559d0f72dd2fa43f29058b3995f` |

Review verdict: accepted for finite non-actuating CPU Classic/Copper exchange
at the recorded profile settings, with HEART-HIL-002/003 retained as explicit
limitations. Copper zero-readout cause is unresolved and does not authorize
native algorithm/timing changes. No required physical or convergence evidence
is claimed by this review.

## Canonical installation verification

Final evidence-only pass, 2026-10-02. No implementation changed during this
pass. The ten production/evidence source hashes in the preceding freeze still
match the worktree. Exact merged transport revisions are plugin
`9aeea5334d03874dcfffc6bc29c8187f2774705a` and adapter
`277d822979f7709abb55769c76291937868f3e0b`.

The reviewer read the final validation document, evidence JSON, roadmap closure
and index; checked their local links; and independently recomputed the canonical
package and packet evidence:

| Canonical installed profile | Manifest artifacts verified | Retained result | Recomputed wire acceptance |
| --- | --- | --- | --- |
| `~/.config/pipewireao-rtc/revolt-classic-heart-hil-cpu` | 349 | `evidence/classic-final/result.json` | 32 WFS frames, 32 DM commands, two separately accounted held repeats |
| `~/.config/pipewireao-rtc/revolt-copper-heart-hil-cpu` | 342 | `evidence/copper-final/result.json` | 32 WFS frames, 32 DM commands, two separately accounted held repeats |

Evidence paths above are relative to the retained experiment root. All 33
path/SHA-256 entries in `HEART_HIL_EVIDENCE.json` matched their files. The checked
JSON SHA-256 was
`102f9521ce52208e38cc74478bd8d0bd6e203ed49c7c3d087d5ee62ae609bda3`.
Its copied batch fields, native generation/placement summaries, six worker
observations, wire results and exit codes agree with the underlying reports.
Every generation has 27 native threads within its declared CPU envelope;
required workers have exact declared affinity, FIFO policy and priority.
Reset changes native PID and generation. All normal-run owners exit zero.
The injected child-death and existing FGN regression summaries also agree with
their retained source evidence.

The final canonical packet checks verify ROI, every ADC payload byte and all
277 command coordinates after exactly one Float32 unit conversion. Classic
uses 0 μs readout, Copper 2000 μs. Maximum commands remain 0.079423636 μm and
0.0028858127 μm respectively. Both runs retain the stopped lifecycle intervals
used to account for native held-command repeats. This provides canonical
relocation evidence in addition to the earlier development-package checks.

Final primary logs confirm Python 117 tests with one intentional skip, no
failing default Rust workspace tests, and successful Clippy completion. Clippy
retains a dependency future-incompatibility warning for `proc-macro-error2`
2.0.1; this is not a failed check or an implementation-specific diagnostic.
Formatting success is reported by the primary; it was not independently rerun
in this evidence-only pass.

The final documents correctly retain provisional physical OPD/displacement,
missing UDP generation fencing, unresolved HIL010/convergence and Copper's
unknown zero-readout failure mechanism. The user-reported DU860, 10 MHz,
14-bit, 0.45 μs vertical shift, preamp 4.6× and EM gain 2 settings are explicitly
tentative and unapplied. The installed Copper plant still has EM gain 1,
excess-noise factor 1 and zero clock-induced charge; this pass does not validate
camera readback or physical detector calibration.

Final canonical verdict: no blocking discrepancy found. The final documentation
and evidence support the finite, non-actuating CPU claim at the recorded profile
settings and preserve the required scientific, hardware and timing limitations.

## User-service verification addendum

Evidence-only follow-up at RTC implementation commit `5b50414`, with the ten
reviewed production hashes unchanged. The reviewer checked `systemd_checks` in
the evidence summary against `evidence/classic-systemd` and
`evidence/copper-systemd-02`: both result/journal hashes match, both retained
16-command batches pass the report and binary-payload checks, stop/reset/restart
acknowledgements are successful, native PID/generation changes on reset, and
all 27 native threads satisfy the declared placement in each generation.
The initial report descriptors pointed at removed runtime paths. The primary
normalized both service results and retained batch reports to the retained
payload paths, preserving each original as `runtime_file`. The reviewer then
reran report validation directly on all four normalized batches and rechecked
the updated summary hashes; payload bytes and their expected hashes are unchanged.

Both services end with `Result=success`, `ExecMainStatus=0`,
`ActiveState=inactive` and `SubState=dead`. Journals confirm start/stop completion.
They also retain PipeWire admission `can't setup mixer` and teardown
`error unset format: Device or resource busy` warnings; successful lifecycle
and complete reports do not imply those warnings were absent. Their internal
cause was not investigated in this bounded evidence pass.

The earlier `evidence/copper-systemd` driver failure remains `passed=false`,
with its matching hash and explicit duplicate-start classification. Its service
still exits successfully. The corrected smoke driver observes automatic
admission before the first batch. Documentation correctly assigns these new
runs to service lifecycle/report evidence; exact UDP wire equality comes from
the separately reviewed canonical foreground captures. No service packet
capture, detector-setting change or broader timing qualification is claimed.
No blocking evidence discrepancy was found.
