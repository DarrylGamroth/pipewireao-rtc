# Classic completion independent engineering review

Review date: 2026-10-20. Current status: **selected source and bounded
software/simulation acceptance gates CCR-G01–G06 accepted; CCR-U06 live repair
accepted**. Parent-owned final cleanup and fresh retained user session were completed
afterward; see the primary-agent handoff addendum at the end.

Confirmed link-loss, raw-Props/readback, and idle RTC freshness defects found
through this review have verified remediations recorded below. No unresolved
confirmed production defect remains in the reviewed selected scope. The source
and initial open-gate sections retain their chronological meaning; final
adjudications below supersede their earlier pending statuses. Acceptance does not
claim a new public package release, clean-cache installation, physical hardware
qualification, scientific convergence, all-product numerical observer invariance,
or a 500 Hz wall-time/deadline guarantee.

## Scope and source identity

| Repository / worktree | Comparison | Branch / starting state |
| --- | --- | --- |
| `/home/dgamroth/workspaces/codex/pipewire/PipeWireAORTC-simulators-20261019` | `fb4efbe3b595dbc1509bad0c1eca56d2a473d56f` → `f6b1281022b8cc66115c156f3ba924fa7012dc3f` | `codex/simulator-releases-20261019`; parent-owned edits to deployment/roadmap documentation present |
| `/home/dgamroth/workspaces/codex/REVOLTClassicSim-managed-20261020` | `e6569a1` → `3a6f17047d0b6acc23b9e7036e6417e1ef337437` | Dedicated Classic worktree; clean on inspection |
| `/home/dgamroth/workspaces/codex/pipewire/pipewireao-gui-classic-20261020` | `566b521a49c5f12faddb4c48d884c7c67fa1d7a2` → `da2c4f1a828761ba5c51cb8b743f04ed1aabec6c` | `codex/classic-panels-20261020`; clean on inspection |

The selected application is CUDA Classic with a CPU JFG controller, released
AOS 0.2.1, HIL 0.2.2 and PipeWireAO 0.6.18. WirePlumber remains the session
authority; systemd remains the process-lifetime owner. No production files,
services, live controls, registry entries or running cohorts were changed by
this review.

During the review, the owner worker began adding `ext/aos/metadata.jl`,
`calibration_identity` parsing/reporting, and corresponding tests. That in-progress
diff received a preliminary read but is **not** part of the committed-source
acceptance recorded here. Its final commit and tests require a follow-up.

Reviewed authorities: repository AGENTS files; RTC task index and current
Classic acceptance table; registered migration ownership; RTC-DEV-014/025/026/027;
GUI development and component-panel contracts. The audit-code-slop review
catalog was used to check vocabulary, types, ownership, control flow and tests.
Its mechanical scan produced no independently actionable finding.

## Observed implementation and conclusions

### CCR-S01 — Lazy settings and prepared plant

- **Evidence:** RTC `src/owners/aos_owner.jl` configuration, settings and `_main`;
  `ext/PipeWireAORTCAOSExt.jl` `prepare_instrument_science`,
  `validate_configuration` and `Owner.prepare_science`; Classic
  `src/graphs.jl` strict NamedTuple overload and returned definition.
- **Observed:** v2 excludes graph/FITS declarations, requires explicit wire
  semantics, bounds recursive immutable settings, and loads the selected package
  only inside bootstrap ownership after the preceding cancellation checks.
  Instrument calls cross the existing lazy-load world-age boundary with
  `Base.invokelatest`.
- **Observed:** HIL validation verifies the actual graph/boundary port identities,
  dimensions and Float32 buffers. Classic's existing transport extension additionally
  verifies the actual PDM/detector bindings, permitted schema/encoding/scale
  combinations, atmosphere cadence and detector exposure. The RTC compares the
  resulting wire configuration with the explicit application declarations.
- **Derived:** the common warm/adopt/reset function operates on the same boundary
  subsequently passed to transport; no duplicate TOML optical graph or separate
  scientific execution owner is introduced by this patch.
- **Disposition:** no defect found; confidence high for the inspected preparation
  and load-order behavior. Managed science parity remains CCR-G02.

### CCR-S02 — Lifecycle, cancellation, cleanup and provenance

- **Evidence:** RTC `_main`, `Owner.run_owner`, `run_prepared!`,
  `prepare_source_control`, `save_report!`, `write_report`;
  `ext/aos/optical_observation.jl` cleanup.
- **Observed:** the new route delegates transport/lifecycle to the existing
  prepared owner. It retains source-first admission/control ordering, sequence
  updates after command adoption, stopped reset generation changes, saved-report
  ordering, bootstrap finishing/fault behavior and transport/observation cleanup.
  Cancellation is checked after the lazy import and after preparation/warm/reset.
- **Observed:** v2 reports retain legacy fields with null graph/hash, and add
  configuration path/hash and plant settings.
- **Disposition:** no introduced lifecycle defect found; confidence high for
  the source comparison. This does not establish actual service cancellation,
  owner-loss handling, bounded managed cleanup or immutable deployment provenance.

### CCR-S03 — GUI read-only exact-node projection

- **Evidence:** GUI `src/view_panel/node_properties.rs`, its tests,
  `src/operator_view/model.rs`, validation, view integration and header/navigation.
- **Observed:** binding requires one exact node name/media name match, current
  connected generation and serial. The first identity is pinned; disappearance,
  ambiguity or replacement invalidates that generation's panel. A new connection
  generation can bind afresh.
- **Observed:** values come from owned node-info or observed scalar Props.
  Duplicate property advertisements and cross-namespace ambiguity are unavailable.
  Defaults, pending requests and drafts are not substitutes. Oversized strings,
  control characters and non-finite floats are rejected. Snapshot fields are
  explicitly labelled last acknowledged values.
- **Observed:** the panel adds no sample subscription, native query, write intent,
  preview source or native lease ownership. Existing view variants retain their
  prior branches. The new panel uses the established layout and source selectors.
- **Disposition:** no defect found; confidence high for model/renderer behavior.
  Real source publication and complete profile rendering remain CCR-G04.

## Verification inspected or repeated

Independent checks:

| Check | Result / scope |
| --- | --- |
| `cargo test --lib node_properties` in GUI worktree, using its documented shared target/native library environment | 4 passed; `gui-focused.log`. Production renderer/model tests, not a native/live-session trial |
| `julia --project=. --startup-file=no -e 'include("test/test_aos_owner.jl")'` in RTC worktree | 150 passed; `owner-cold.log`. Working-tree smoke while metadata work was ongoing, not a final committed-head gate |
| `git diff --check` in RTC worktree | Passed at inspection |

The Julia smoke emitted a cache/precompilation version warning and completed
successfully. The GUI invocation emitted the five already recorded vendor
warnings; the focused package tests passed. No production fix was inferred from
those warnings.

Implementation-worker evidence was read and checked against the tests:

- `../owner/EVIDENCE.md` and logs: generic boundary counting/mismatch checks,
  actual Classic CPU/CUDA no-transport preparation, actual default-loader ordering,
  legacy preparation, zero-allocation idle and phase-timing checks.
- `../gui/validation.md`, `checks.json` and final logs: 460 library, 257 native
  binary and 11 integration tests; 15 opt-in live tests ignored; native build,
  WASM/browser compilation, Clippy and Julia fixture checks. The initial failed
  native environment runs remain recorded; the owner-environment run passed.

The cold/no-transport evidence verifies the described software slice. It does
not establish full managed delivery, deterministic closed-loop equivalence,
observation non-interference, sustained GPU cadence or hardware qualification.

## Initial acceptance obligations — historical snapshot

These are **verification obligations**, not confirmed source defects.

| ID | Severity / confidence | Evidence and affected contract | Required validation / disposition |
| --- | --- | --- | --- |
| CCR-G01 | Completion gate / high | The development environment still has explicit RTC/Classic path sources; no new sealed candidate evidence was available at this review | Review final committed package identities, registry-only closure, relocation/isolated instantiate and launch/stop instructions. Open |
| CCR-G02 | Completion gate / high | Current new evidence stops at prepared no-transport Classic; RTC-DEV-014/024 selected causality row remains planned | Validate every accepted frame/command identity and next-frame causality; direct replay at declared tolerances; explicit scalar/parameter adoption and restoration. Open |
| CCR-G03 | Completion gate / high | Old application receipts do not qualify changed plant/dependency closure; RTC-DEV-025 and fault rows remain planned | Held Ready, start/pause/resume/stopped reset/new generation, invalid-control survival, orderly Quit, owner-loss/fault/ingress hold and exact cleanup while preserving unrelated cohort. Open |
| CCR-G04 | Completion gate / high | GUI tests use synthetic snapshots; metadata implementation and RTC-owned profile are still being assembled | Review final source metadata/config tests; actual geometry, units and source bindings; live rendered profile including missing/lost-source behavior. Open |
| CCR-G05 | Completion gate / high | Independent source and CPU numerical audit completed; see `../science/CALIBRATION_REVIEW.md` | Satisfied for retained artifact identity, documented operational calibration transfer, current plant prescription and CPU estimator compatibility. Preserve the 16-frame noisy operational campaign provenance; no offset replacement is warranted. CUDA oracle/convergence claims remain separate |
| CCR-G06 | Completion gate / high | No final bounded-observer trajectory/cadence evidence was available | Compare deterministic accepted results with no/attached/slow/detached/reattached observers, and record backend/device/thread placement, wall cadence/missed periods, bounded storage and warmed allocations with proper scope. Open |

Final review should update these same IDs with exact evidence and dispositions.
No scientific gain, filter, threshold or calibration change is requested by
this source review.

## CCR-G05 follow-up — retained scientific calibration

The independent follow-up confirms exact `graph.conf` and 16-FITS preservation,
zero typed node-config differences between the old TOML and new builder under
released AOS 0.2.1, exact actuator-grid order, and exact current-estimator
replay of all 16 saved operational lamp frames. The background is exactly the
mean of 16 saved dark frames; the archived AOC incremental mean reproduces
the retained noisy reference slopes exactly.

These files come from the documented operational campaign at lamp magnitude
0.5, transferred explicitly to the magnitude-2 target. They are not the
historical 256-dark/noiseless defaults. The current magnitude-2 noiseless
flat gives 176 valid measurements out of 188 regions, 184 active, and maximum
valid residual 0.013388127 detector-coordinate units. Neither the comparison
with a different 256-frame dark estimate nor the nonzero noiseless-flat
residual establishes a calibration defect. Preserve the files and state their
actual provenance. Full commands, source versions, diagnostics, limitations,
failed exploratory checks and final passing evidence are in the science review.

## Fault-link-001 independent adjudication

Date: 2026-10-20. This follow-up supersedes any provisional interpretation that
absence of a held ACK alone proves an AOS/HIL defect. RTC-DEV-025 explicitly
requires pause ACK only after outstanding adoption and permits an unknown
source-control outcome to fault the session and revoke ingress before consumer
cleanup. Do not introduce abandoned-exchange success ACKs or new HIL APIs to
satisfy an overstrict test.

### CCR-F01 — Required owned-Link removal is missed by registry proxy comparison

- **Severity:** high; required-loss detection. **Confidence:** high, confirmed
  source mechanism plus fail-before test. **Disposition:** source fix independently verified at `ce2dc766`; managed replay pending.
- **Affected:** installed WirePlumber `lib/ao-connections.lua`, especially
  `connections.new` object-removed callback (105–120) and `connections.realize`
  captured creator proxy (507). Installed file SHA256
  `58d771b56a4fc52ff639abf984c78f36c2c4e3981fe4841e65ac0d5cea3a1ba7`
  exactly matches the current WirePlumber source file.
- **Observed source:** `lib/wp/link.c:235` creates factory links with
  `own-global=FALSE`. `lib/wp/private/registry.c:31–44` explicitly documents
  separate creator and registry proxies for the same global. The policy captures
  the creator proxy, then compares it by GObject equality to the ObjectManager
  registry proxy in object-removed. Those are different objects. The creator's
  `proxy_event_removed` (`lib/wp/proxy.c:297`) only traces; it does not emit the
  `pw-proxy-destroyed` signal subscribed by the policy. Registry removal destroys
  the registry proxy instead (`private/registry.c:507–529`).
- **Observed fail-before:** the existing whole cold `ao-connections.lua` fixture
  passes with the installed production module. A copy changing only the owned
  link removal case to use distinct creator/registry objects fails:
  `Link removal did not retain saved identity: nil`. The prior fixture aliases
  those objects and therefore does not exercise the actual ownership contract.
  Evidence: `owned-link-original-fixture.lua`, `owned-link-distinct-proxies.lua`,
  their logs, and `run_lua_fixture.py` (system liblua5.4; no new service or source
  edit). This is a policy/unit experiment, not a native live proxy experiment.
- **Corroborating managed observation:** the injected object was owned Link
  id143/serial144 (`simulator-wfs`→JFG raw input). Yet the first logged Fault at
  01:25:11.872351 names the removal of focal-image **port** id94/serial95 during
  simulator teardown. Hold then fails at 01:25:11.994487 with missing object
  serial. This agrees with missed direct Link loss followed by source timeout.
  Precise injection-to-fault elapsed time was not timestamped in the receipt;
  do not claim it from journal ordering alone.
- **Remediation:** preserve creator ownership/lifetime but correlate required
  Link disappearance with the registry incarnation using saved global ID and
  object serial, or retain the matching registry proxy once observed. Never
  correlate only by name, raw ID or creator pointer. Removal must still work
  when live properties/bound ID have already been invalidated; use retained
  identity. Preserve intentional withdrawal suppression, late creation fencing,
  no duplicate faults and no automatic readmission.
- **Validation:** same distinct-proxy case passes after fix; wrong/reused serial
  does not fault the old incarnation; actual owned native Link destruction faults
  on the injected link while endpoints remain present; loss during realization,
  late proxy activation and intentional withdrawal retain correct outcomes.
  Then rerun Classic fault case with corrected emergency-cleanup expectations.

### CCR-F02 — Fault harness incorrectly demands a held surviving source

- **Severity:** medium, acceptance-test false failure. **Confidence:** high.
  **Disposition:** confirmed test defect; no production HIL remediation warranted.
- **Affected:** RTC `test/integration/session_faults.jl:461–495`, including
  unconditional exact source decode/held ACK and surviving owner/node checks.
- **Observed:** link-removal can make the matching command impossible. Released
  HIL0.2.2 exchange returns only after command adoption and driver-cycle completion;
  it eventually throws on missing sequence1192. RTC consumes source requests only
  between exchanges. This preserves RTC-DEV-025 rather than falsely acknowledging
  an unadopted frame. The installed policy publishes Fault, tries source hold
  with a finite deadline, and on unknown hold disconnects the endpoint so systemd
  performs its established emergency cleanup. Source survival is not promised.
- **Observed:** this run's missing source triggered `only(empty)` while the
  harness tried to decode the removed node. It is secondary, not evidence of a
  false ACK, fabricated data, adopted cursor corruption or need for an abort API.
- **Remediation:** qualify two explicit outcomes: acknowledged held source with
  exact adopted cursor and ordinary ordered withdrawal; or unconfirmed hold with
  retained Fault and exact emergency teardown. Do not accept mere node absence
  as cleanup proof. Require preserved first fault, bounded effect outcome, source
  ingress revocation before consumer teardown, unchanged unrelated cohort and
  fresh incarnation/readmission. In a deliberately missing-command case, require
  the latter outcome rather than successful pause.
- **Validation:** deterministic helper coverage for both outcomes, missing-source
  observation without a misleading collection exception, and actual managed
  link/owner loss followed by exact cleanup and fresh admission.

### CCR-F03 — Cleanup observer samples completion before manager quiescence

- **Severity:** medium, acceptance-test race. **Confidence:** high.
  **Disposition:** confirmed test defect; completion evidence must be awaited.
- **Affected:** `test/integration/session_faults.jl:182–222`.
- **Observed source:** observer waits only for `cleanup_complete` in the receipt,
  then samples unit/cgroup/process checks once. ExecStopPost writes the receipt
  before its own process exits, so that receipt cannot prove manager unit/cgroup
  quiescence. `W.stop!` first requires a currently active incarnation; calling it
  after policy-triggered deactivation can fail without submitting a stop, which
  is recorded here as `WirePlumber session unit is not active with the installed
  policy`.
- **Observed evidence:** retained receipt has cleanup_complete=true and no cleanup
  errors; all four owners and owner cgroups are gone, manager main process gone,
  but unit_quiescent and manager_cgroup_empty are false in the immediate sample.
  Subsequent read-only systemctl inspection gives MainPID=0, ActiveState=inactive,
  SubState=dead and empty ControlGroup. This supports transient ExecStopPost
  sampling, not a surviving owner leak.
- **Remediation:** poll the conjunction of receipt + exact retained unit incarnation
  disposition + no jobs + all original process identities absent + all original
  cgroups empty, under one deadline. Reconcile an already-stopping exact invocation
  without issuing another effect or pretending a stop was submitted. Do not weaken
  all-checks-required or use a single empty registry listing as completion.
- **Validation:** delayed manager teardown after receipt writes must initially
  remain pending and eventually pass; a nonempty retained cgroup must timeout;
  a replaced invocation must fail rather than being stopped or accepted.

### Fault causality and remaining evidence limits

The retained journals show source teardown before consumer process exits:
source timeout is printed at 01:25:13.963519 after endpoint teardown began;
source process exits 01:25:14.436067; parameter/JFG processes exit
01:25:20.216545/01:25:20.292486; core is explicitly stopped
01:25:39.061533 and session stop completes 01:25:40.070614. The final receipt
records exact owner identities and no cleanup errors. The source stop preceded
consumer exits, consistent with ingress revocation, but the existing run does
not independently timestamp every native frame publication/adoption or each
consumer shutdown request. Do not present it as complete ordering/timing proof.

The policy's hold uncertainty occurred about 122 ms after its first Fault, not
at the end of the full five-second hold budget: the source objects were already
closing. No successful held ACK should be invented for that interval. The last
owner-committed cursor must remain the last adopted command, not the already
stepped but unmatched exposure1192. Current report code updates state.sequence
only after exchange success. The retained final source report was independently
read and copied to `fault-final-source-report.json`: generation1, sequence1191,
running=false, completed=false, and explicit missing-command1192 failure. Thus
the actual report retains the last committed cursor truthfully. This run did
not reach fresh readmission.

Evidence files: `fault-session-journal.log`, `fault-source-journal.log`,
`fault-cohort-journal.log`, `fault-current-unit.log`, `fault-policy-hashes.json`,
and original `../fault-link-001/qualification.json` and cleanup snapshots.
No production code, services or user runtime was changed by this adjudication.


## CCR-F01 remediation verification — ce2dc766

Reviewed clean WirePlumber worktree
`/home/dgamroth/workspaces/codex/pipewire/wireplumber-classic-20261020`, commit
`ce2dc76618e7e82d9389b52e2b9cf7628c9e1bb9`, parent `d20cd203`.
Only production `ao-connections.lua` and its cold fixture changed.

**Observed:** the registry addition stores immutable global-ID/serial identity;
removal locates the retained registry object by GObject equality, reads the saved
identity before clearing it, and compares both fields against the admitted
cohort. Diagnostics retain the creator's captured endpoint identity separately.
Neither creator ownership nor session policy authority changes. Terminal cohort
and intentional withdrawal continue suppressing required-loss callbacks; pending
activation completes through the existing cleanup fence.

Independent tests (system liblua5.4, no live process mutations):

- The exact independent distinct-proxy test that failed before now passes.
- The complete final `tests/wplua/scripts/ao-connections.lua` passes, including
  before/after registry-add ordering, invalidated properties, fresh equal wrappers,
  duplicates, unrelated IDs/serials, and pending intentional withdrawal.
- Additional `owned-link-fixed-reuse-order.lua` passes actual chronological
  old-removal → replacement-add → late-old-removal → replacement-removal. It
  requires one fault for the old required incarnation, retains the replacement
  through a stale callback, and refuses to inherit the old obligation by ID.
- `git diff HEAD^ HEAD --check` passes.

The worker's replacement-add-before-old-removal fixture is a defensive stale
callback test, not proof of permissible registry event ordering. Source review
of `registry_global_remove` → `wp_global_rm_flag` →
`wp_registry_notify_rm_object` → `wp_object_manager_rm_object` shows synchronous
`g_signal_emit` delivery of object-removed before slot invalidation and the next
registry event. Consequently a native reused ID cannot silently overwrite the
old saved incarnation before its required removal notification. The additional
independent chronological test verifies the relevant policy behavior.

Disposition: **CCR-F01 source remediation accepted, high confidence**. No new
confirmed defect found. Evidence/source hashes and exact commands are retained
in `owned-link-fix-verification.json`; investigate scripts remain outside the
production worktree. The actual managed Classic run must still establish direct
Fault for the injected Link before secondary source teardown, the valid unknown-
hold emergency outcome, exact bounded cleanup, and fresh readmission. This source
verification alone does not close that managed acceptance gate.


## GUI Props integration review — 2026-10-20

### CCR-U04 — Actual source snapshots require indexed, read-only Props projection

- **Severity:** completion-blocking integration defect. **Confidence:** high.
- **Observed:** `managed-session-003/graph-ready.json` contains an empty
  `PropInfo` array and four indexed `Props` records for run, reset, acknowledged
  source snapshot and rejection. The earlier GUI adapter ignored Props without
  advertised controls, and its worker retained only the last record. Static AOS
  NodeInfo facts rendered, but the ten requested snapshot rows were unavailable.
- **Remediation reviewed:** GUI commit `8d4a1f2` retains complete indexed Props
  enumerations and projects bounded named scalars into `NodeSnapshot.props_params`,
  separately from editable PropInfo controls. No synthetic control advertisement,
  source query, write protocol, HIL change, or scientific parameter change.
- **Verified source properties:** connection generation, node ID and object serial
  bind the publication; parameter/error revision changes invalidate pending passes.
  The complete pass replaces old records, including absent/empty records. Scalar
  projection rejects malformed, duplicate, nonfinite and oversized values. Named
  raw values cannot create editable controls; numeric advertised controls retain
  their existing typed observation path. NodeInfo/raw-name conflicts stay unavailable.
- **Evidence:** `gui-egui/props-fail-before-executed.log` executes the actual
  four-record/empty-PropInfo fixture against the prior projection and fails;
  `props-all-tests.log` and `props-regressions-final.log` pass the corrected
  projection, disappearance, identity, bounded parser and numeric-control cases.
- **Disposition:** projection design accepted; final exact-head checks and actual
  connected GUI acknowledged-snapshot display remain required.

### CCR-U05 — Post-write enumeration bypasses the new batch owner

- **Severity:** medium, editable-control observation regression. **Confidence:**
  high for the source defect; overlapping-callback symptom is derived, not a
  measured live failure.
- **Affected revision:** `8d4a1f2` through `2e21521`;
  `src/pipewire_worker/registry.rs::set_property`.
- **Observed source:** normal polling owns a complete Props enumeration and its
  core barrier, but post-write refresh still calls `enum_params` directly. The new
  callback accepts every non-subscription Props response into the current pending
  pass. Consequently an unowned reply is discarded without a pending pass or can
  overlap a later pass; repeated indices invalidate it, and disjoint stale records
  are not intrinsically distinguishable. The worker independently confirmed the
  missed second enumeration issuer.
- **Native sequencing:** local primary source `protocol-native.c::node_marshal_enum_params`
  replaces caller sequence with `SPA_RESULT_RETURN_ASYNC(msg->seq)`.
  `impl-node.c::emit_params/node_subscribe_params` uses literal 1 for unsolicited
  subscription enumeration. Thus excluding literal 1 is correct; comparing the
  reply to caller constant 2 would not repair the problem. Rust `enum_params`
  currently discards its native return value.
- **Remediation:** route post-write readback through the same polling owner: clear
  the requested Props bit, invalidate any pending pass while retaining its barrier,
  and issue a fresh complete pass only after that barrier drains. Keep committed
  values/revision unchanged on submission, because submission is not adoption.
- **Validation requested:** pending and no-pending refresh cases; wrong/old barrier
  cannot publish, committed observations survive submission, and the next complete
  pass replaces all records. No service or production SDK changes by this reviewer.
- **Disposition:** worker repair in progress; final reviewed head recorded below.

### Final GUI Props adjudication

Reviewed clean GUI head **`abd50eaf701d9e0ffef0ceb97f3fd582dbfdae40`**,
including the post-write repair, and `git diff 301c7f6..abd50ea --check`. Only
`poll_node_properties` now issues explicit enumerations in `registry.rs`. A pass
invalidated during a write keeps its original barrier; the next pass cannot start
until that barrier consumes it. Thus late rows from that old pass cannot enter a
new pending pass. Subscription responses use literal sequence 1 and remain excluded.
Node removal drops its listener/batch owner; connection generation, object serial,
revision and error checks additionally guard publication. No confirmed stale-node
or stale-enumeration publication defect remains in the reviewed path.

**CCR-U05 remediation accepted. CCR-U04 source remediation accepted.** The
post-write regression covers both pending and no-pending states, preserving old
committed observations until real readback and replacing disappeared record indices.
The correction in `056b02a`/`2e21521` only removes the false diagnostic that a
non-driving observer cannot request processing; it retains trigger failure handling
and does not add observer authority.

Independent focused execution: **11/11 pass** using the worker-built exact-head
native test executable, SHA-256
`17c4895b040904892f953cd456f10b58d2c197662b5d662cb4a82f0298904ae4`.
Command and output: `gui-props-final-independent.json` and
`gui-props-final-independent.log` in this review directory. No concurrent Cargo
build was started by the reviewer. Earlier `gui-props-independent.*` is explicitly
intermediate evidence with the same production repair but pre-commit test-module
placement; it is not used for the exact-head claim. Worker full-suite evidence
reports 461 library + 241 native + 11 integration tests, 15 intentionally ignored;
final all-target inspection Clippy passes.

The actual connected GUI acknowledgement/panel check remains a separate application
verification owned by the parent agent. These source and headless checks do not
claim that live check or close the finite-science/observer/resource gates.


## Finite science, observation and resource adjudication — 2026-10-20

Reviewed RTC test commit **`965aef03a1f282fbd368a8263c3e392b049a3edc`**,
`test/integration/classic_finite_replay.jl`, its observation helper, and retained
`finite-replay/run-012` evidence (**1318/1318 assertions passed**, 16 accepted
exchanges in each of four modes). Independent verification is retained in
`finite-and-resource-independent.json`. It rehashes source, native binaries,
all application inputs and payloads; checks exact payload extents; compares
all mode payloads and direct-replay bytes; and independently checks Float32
micrometre-to-metre command scaling. All checks pass.

### CCR-G02 — Selected finite scientific transport gate accepted

The detector and demanded command captures are native callback copies on explicit
reliable recorder branches. The assertions require all sequences 1:16, matching
frame/command Acquisition identity and exposure, one accepted command per frame,
monotonic publication/completion chronology, exact ADC row-major staging and exact
Float32 command adoption. These recorder branches are validation instrumentation,
not optional drop-oldest observers. They are held constant across scenarios.

A separately prepared ordinary CPU JFG graph consumes the recorded ADC frames.
It receives the same sealed graph and FITS inputs, warms, resets, starts feedback
at zero, and copies the newly computed controller feedback only after processing
each frame. That agrees with the installed FilterGraphPipeWire feedback bridge,
which copies scratch into its slot after terminal publication. It does not feed
recorded commands back into the replay oracle. Every replayed adopted command is
bitwise equal to the actual transport-adopted command. This is an independent
execution-path/transport comparison of the same algorithm, not an independent
physical or mathematical validation of that algorithm.

Between scenarios, `reset_hil_boundary!` resets graph state and initial command;
each scenario constructs a fresh HIL transport/model-time owner and fresh native
JFG graph. Exact reset trajectories are observed rather than assumed: 1,228,128
detector components and 4,155 command components differ from their first-frame
values, while the complete four scenario payloads remain identical. No missing
reseed or feedback off-by-one defect was found. The earlier 44-assertion ADC test
provides the explicit command-perturbation/next-frame check; managed-session-003
provides live scalar/parameter adoption and restoration. Together these close the
selected bounded transport gate without claiming an independent GPU optics oracle
or scientific convergence.

### CCR-G06 — Selected observer invariance and resources accepted

All seven public JFG outputs and the detector output drain through exact selected
application capacity-one copy/drop-oldest queue declarations. The optional consumer
comparison selects **detector and demanded command**: none; normal (1:16); slow
(1,16); and link detach/reattach (1:6,12:16). Each scenario preserves every accepted
detector, demanded and adopted payload exactly. Slow/churn consumers demonstrably
skip observations while all 16 scientific exchanges complete. Fresh scenario
teardown is checked. The source waits for validation recording/selected requested
observations between exchanges, so this is functional invariance evidence, not a
wall-time throughput test.

The independent installed-session `review-session-001/observation-lifecycle.json`
adds actual eight-stream normal/slow/full-client detach/reattach progress, finite
values and identities. It does not assert every-frame numerical equality for all
eight products. The combined bounded claim is sufficient for the selected
completion row when stated explicitly; it does not qualify queue-disabled
comparisons, arbitrary observer implementations, all-product numeric invariance,
or an unlimited-duration campaign.

`review-session-001/resource-summary.json` agrees with the independently rehashed
phase capture: 32,768 contiguous generation-1 rows, sequences 513:33,280 after
512 warmup frames; fixed row payload 4,456,448 bytes; 429.023 Hz over the retained
76.376-second adjacent-row interval; 5,421 skipped future release slots. Process
allocation rises 5,242,720 bytes over 32,767 adjacent exchanges (**160 bytes per
interval**); process GC time delta is zero. These are whole-simulator-process
cumulative counters, not graph-callback allocations, and do not imply zero
allocation. The receipt records RTX 3080 identity and the separate launch resource
snapshot records actual thread/CPU placement. Concurrent local builds/GUI/observer
work make this a functional characterization, with no deadline/tail SLO, 500 Hz,
convergence or physical-device claim.

### GUI and fault evidence update

`gui-live/props-live-comparison.json` binds GUI `abd50ea` and executable SHA
`ec665ea33022a1d16f47219d6bf8464403511bd88b6b263ab620bab2776c1250`.
All **21** rendered fields match the actual NodeInfo/four-Props/empty-PropInfo
source. Independently viewed `classic-metadata-props-fixed.png` shows the values,
exact source serial and last-acknowledged-snapshot wording;
`classic-shwfs-props-fixed.png` shows Running, real detector/SHWFS overlays and DM
geometry. **CCR-U04 actual projection validation is accepted.** Final GUI
detach/reconnect/source-loss and retained fresh-cohort work is still owned by the
parent and is not silently claimed by this review.

Both fault-link-002 and fault-controller-001 qualification receipts are now
complete, with policy-shutdown outcomes and complete initial/fresh cleanup.
These are valid unknown-hold/emergency-cleanup paths, not fabricated held ACKs.
The earlier CCR-F01 managed-remediation gate is therefore accepted for the direct
link-loss path as well as its independent source tests.


## Idle RTC connection loss review — 2026-10-20

### CCR-U06 — Idle native RTC connection loss leaves cached RUNNING authoritative

- **Severity:** high operator-state/freshness defect. **Confidence:** high.
- **Observed live evidence:** `gui-live/classic-source-lost-001/02-widget_tree.json`
  retains `RTC · RUNNING` after parent-owned exact cohort shutdown, while the
  separate observation connection shows disconnected and all 21 source properties
  correctly show unavailable. The parent observed this for over 30 seconds.
- **Observed source:** `rtc_adapter.rs` waits for explicit requests and immediately
  continues on its 20 ms idle receive timeout. Its native RTC main loop therefore
  does not dispatch existing exact-owner/proxy removal, registry retirement or core
  error callbacks while idle. `Client::iterate` runs only during connection and
  requests. The GUI RTC model has only request-correlated terminal events and no
  idle-loss event. Cached status is not invalidated until another command.
- **Required remediation:** bounded read-only pumping/health checking of the retained
  RTC connection while idle; exact generation-bound loss publication and cache/
  freshness revocation. No inferred Stopped state, no coupling to independent
  observation disconnection, and no automatic Status/control/query request.
- **Concurrency obligations:** retain matched completion-before-retirement behavior;
  preserve reply-before-loss delivery through the bounded event channel; keep
  retirement cancellation bounded; ignore obsolete generation loss. Selection may
  finish just before loss and before the first explicit request, so generation must
  be established for the worker at creation rather than inferred from a request.
- **Disposition:** remediation and focused validation in progress; exact-head final
  adjudication follows below.

### CCR-U06 final source and software adjudication

**Reviewed production head:** GUI `97e29996c256b5ab021f8f1c9032383b5cb6fdba`,
clean when inspected. Independent source review accepts the correction. The native
client performs one nonblocking iteration during the existing 20 ms idle receive
interval, then reads existing owner/controller/proxy/core health callbacks. A
scheduler delay alone cannot expire an idle deadline: this path uses zero timeout.
No owner command, Status refresh, observation-client inference, new worker, or
native protocol is added. The ordinary request completion-before-retirement path
is preserved.

The adapter receives the next model generation at creation, before selection and
before any request. Loss revokes submission admission before it waits behind an
already queued reply; the capacity-one channel retains that reply and then the
terminal loss. Receiver destruction cancels the retry within the existing polling
interval, preserving the two-worker bound. Model handling precedes request-ID
matching, ignores old-generation loss, clears cached lifecycle/freshness, preserves
an already completed outcome, and conservatively makes a pending mutation unknown.
It does not synthesize Stopped. The independent observation disconnect regression
preserves a still-valid RTC Running observation.

**Fail-before evidence:** `gui-egui/rtc-idle-fail-before-qualified.log` selects
exactly the idle-no-request regression with only the old timeout/continue branch
restored; it fails the bounded two-second wait. The earlier unqualified selector
ran zero tests and is not validation evidence. Restoring the correction passes all
five adapter tests in `rtc-idle-pass-after.log`.

**Independent pass-after:** `review/gui-rtc-idle-final-independent.json` and `.log`
record direct execution of exact-head, SHA256-verified test artifacts: **18** RTC
model/panel tests, **5** adapter tests, and **1** separate observation-disconnect
regression, **24 passed**. Library executable SHA256
`829c4213b65915771a324bf459359a948534728d082f54e85c528dad75d0e9a0`;
native test executable SHA256
`6ac20174626366cd8eb863dc21b5e52403fa8bdaae0f55ab0468288a1e26ec6d`.
No Cargo rebuild or service mutation was performed by this independent reviewer.
The worker's exact-head product suite separately records 465 library, 244 native,
and 11 integration passes, with 15 live tests ignored; Clippy and WASM checks pass.
An additional all-target test invocation exposed an example-only missing test-root
module; its separate test-harness repair is being handled by the worker and is not
misrepresented as a passing all-target gate here.

**Disposition:** production source and software regression validation accepted;
actual new-binary native core-loss observation remains the parent's final system
validation gate. No numerical, GPU timing, hardware, or unbounded-latency claim is
made by these GUI tests.

## Final selected-gate adjudication — 2026-10-20

The independent final receipt is
`review/final-live-relocation-independent.json`. Current application identity is
`c52ceb58407e77a352eb8ac14b702f967642bbab`; Classic candidate `cb0298e`, RTC runtime
candidate `b2c64dc`, RTC finite-test commit `965aef03`, selected native link-loss
fix `ce2dc766`, and GUI production fix `97e2999`. Runtime package candidates are
immutable private review candidates, not new public releases.

| Gate | Final disposition and bounded evidence |
| --- | --- |
| CCR-G01 | **Accepted.** Final c52 relocation/seal/instantiate receipt has no Project sources or Manifest path/repository overrides. Independently rehashed all 30 source and relocated files against the receipt; 27 runtime/scientific files match finite run 012, and only README/operator views/seal change. Private registry and shared package/artifact/precompile caches are explicit. This is fresh relocation with cached instantiation, not clean-cache or historical cache-content qualification. |
| CCR-G02 | **Accepted.** Actual CUDA ADC transport 44/44 plus managed scalar/parameter adoption/restoration and 1,318/1,318 finite replay assertions. Every accepted detector/demanded/adopted result for 16 exchanges per mode is exact; direct fresh CPU JFG replay is independent of the recorded demanded-command oracle. The earlier detailed replay review defines reset, causality and numerical scope. |
| CCR-G03 | **Accepted.** Managed lifecycle 68/68, link-loss 41/41 and controller-exit 40/40 establish selected lifecycle/fault/cleanup/fresh-admission paths. Unknown-hold emergency cleanup follows existing policy; no invented held ACK or new abandonment API. Final user handoff cohort is an operational follow-up, not substituted for these completed qualification runs. |
| CCR-G04 | **Accepted.** Actual scientific views, 21 exact NodeInfo/Props facts with empty PropInfo, ten Status fields/eleven Settings facts, missing/lost-source handling, and independent native RTC loss are demonstrated. Props source/readback and idle generation/queue corrections have independent review and tests. |
| CCR-G05 | **Accepted.** Retained 16 FITS/graph identities, actual 16-frame operational calibration lineage, current plant prescription and CPU JFG geometry/units/threshold/mask compatibility are documented in the scientific audit. Hybrid reconstructor and calibration transfer remain explicit; no tuning or independent physical validation is claimed. |
| CCR-G06 | **Accepted for selected bounded claim.** Finite no/normal/slow/churn observation preserves exact detector/demanded/adopted results with all app queues present. Installed eight-stream progress complements two-product numerical comparison. The 32,768-row resource receipt reports 429.023 Hz, 5,421 skipped slots, 160 whole-process allocated bytes per adjacent exchange and zero process GC-time delta; no zero-allocation callback or 500 Hz claim. |

### CCR-U06 live remediation accepted

`gui-live/rtc-idle-loss-live.json` binds production GUI `97e2999` and inspection
binary SHA256 `61942cb383c8031c30417ca0c82a2b29ecac235bf5425eab55a39c7d2cd6051c`.
The parent's explicit orderly cohort shutdown removes the actual native RTC
endpoint; the retained read-only MCP wait and widget trees observe **RTC ·
disconnected**, disabled Start/Stop/Reset/Refresh controls, and session **Not
observed**, with no fabricated Stopped lifecycle. Independent parsing of
`grouped-source-loss-001/05-widget_tree.json` verifies those facts. The screenshot
`classic-source-lost-rtc-controls-fixed.png` was independently viewed and agrees.
Crucially, the separate PipeWire observation connection still shows **connected ·
26 nodes** in that capture. This distinguishes native RTC health invalidation
from an observer-disconnect shortcut. The previously retained stale RUNNING
capture is the actual-system fail-before evidence. **CCR-U06 is closed with
source, regression, concurrency and actual-system pass-after evidence.** This
capture is not a measured worst-case dispatch-latency bound.

Remaining handoff at this timestamp: parent awaits the exact final shutdown
receipt for review-session-002, then retains a fresh review-session-003 for the
user. The worker is separately repairing an example-only test-root omission;
that does not alter the reviewed production implementation. No service action
was performed by this independent reviewer.


## Primary-agent operational handoff

The parent verified review-session-002's retained cleanup_complete ledger with
no cleanup errors. Fresh review-session-003 was admitted held Ready, explicitly
selected after refreshing the GUI discovery list, started through the GUI and
confirmed Running by a separate native Status. Unit
`pipewireao-session@e3ea2343257c.service`, invocation
`c8febbbffefb408a9c97ad59b71168ae`, session
`5ee74331-974c-4546-91fb-6c06eae3e5d9` is retained for review. The grouped Status
and Settings and actual SHWFS/DM views render with production GUI `97e2999`.
`../final-handoff.json` binds exact identities, status, screenshots and original
unrelated-cohort preservation. The separate test-only example correction at GUI
`b0fa8b3` passes all-target inspection verification: 874 tests, 30 explicit live
tests ignored. Parent facts in this addendum are operational evidence, not a new
independent source review or a broader performance/scientific qualification.
