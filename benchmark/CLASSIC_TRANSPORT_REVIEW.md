# Classic live transport review

Date: 2026-09-30. Independent bounded review of the Classic complete-frame
FGN/JFG harness and ordinary progressive HEART harness. This is characterization
under [the active authority map](../docs/README.md) and
[the agreed comparison scope](CLASSIC_MATCHED_REVIEW.md).

## Scope and evidence

Reviewed RTC files: `benchmark/run_classic_live.py`,
`benchmark/prepare_classic_heart_config.py`, and
`benchmark/run_classic_heart_live.py`. Reviewed JFG files:
`benchmark/run_classic_pipewire_node.jl`, `benchmark/run_classic_array_replay.jl`,
and `scripts/test_classic_pipewire_startup.jl`, at commit
`c1cd735bc153890a2603b4195ca32abdb8ad29c6` in
`/home/dgamroth/workspaces/codex/pipewire/JuliaFilterGraph-progressive-requal`.
The shared helpers, capture qualifier, DM decoder, unit adapter, and feedback
owner were inspected for the relevant contracts.

Final reviewed RTC source SHA-256 values:

```text
run_classic_heart_live.py   2b62434ea259d6889a8a0dcdd07a7f8c2d2233297c11fa23b93f98940db253d3
run_classic_live.py         1d128322d54361310a2bc358ddf4ecaef73b78287710bff15107c6721f5ed972
prepare_classic_heart_config.py
                           65a2143308195f4a809e99047af22dd85c069dcf335fa15044aac8902d55f72b
```

RTC review worktree:
`/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-progressive-requal`,
branch `copper-progressive-requal-20260929`, base
`5f7e37e9dd5995d613da6858e096acb5162346f9`. Existing benchmark edits and untracked
reports were present. This review changes only this new document.

Saved evidence directories under `/home/dgamroth/.cache`:

- `rtc-classic-fgn-fullframe-short-r3-20260930`
- `rtc-classic-jfg-fullframe-short-20260930`

Both captures contain 224 WFS packets, seven 277-element DM commands, frame IDs
0 through 6, zero payload mismatches against the FITS cube, and zero recorded
process-exit errors. Source diagnostics report seven complete frames and no
rejections, drops, or starvations. Maximum command differences from the direct
seven-frame reference are 2.9802322387695312 × 10⁻⁸ µm for FGN and
1.7881393432617188 × 10⁻⁷ µm for JFG. These are within the existing native-unit
10⁻⁶ criterion. Failed earlier startup and packet-size attempts remain separate
evidence and are not converted into successes by these runs.

## Findings

### CT-01 — HEART cleanup must account for abnormal child exits

Severity: medium. Confidence: high from source. Classification: confirmed
failure-accounting defect in the initially reviewed implementation.

The initial `run_classic_heart_live.py` cleanup recorded child return codes but
did not turn nonzero codes into errors. `helper.stop` can terminate or kill a
child that fails to stop normally. A complete valid capture plus acknowledged
SHUTDOWN could therefore be labeled `functional_wire_qualified=true` despite
abnormal process termination. The full `qualified` field remains false because
effective HEART flags have not been read back, but that does not repair the
functional-result failure accounting.

Required remediation: record abnormal child termination as a qualification
error while preserving capture analysis and all other cleanup. A focused mock
with valid capture and abnormal RTC or capture-process exit is sufficient to
demonstrate fail-before/pass-after behavior; no new live benchmark is needed
for this reporting path. This finding was sent to the HEART implementation
agent during review. The final implementation records nonzero returns as
`abnormal_exit`, adds a qualification error, and retains post-cleanup capture
analysis. Independent rerun of all nine focused Python mock tests passed,
including `test_abnormal_rtc_exit_cannot_qualify_complete_capture` (a matching
capture with RTC return code −9). Disposition: fixed and independently verified
by source inspection and the focused mock test; no live rerun was required.

### CT-02 — Common harness cleanup can stop before reporting or cleaning remaining children

Severity: medium. Confidence: high from source. Classification: confirmed
failure-path robustness defect in the initially reviewed implementation.

`run_classic_live.py` initially touched each stop marker and called each
`helper.stop` directly in its `finally` block. Any exception in these operations
skips the remaining cleanup and the final `report.json` write. Thus a cleanup
failure can obscure the primary failure and leave another child running.
The two successful captures do not exercise this path.

Required remediation: catch and record individual marker/child cleanup errors,
continue cleaning the remaining children, force `qualified=false`, and write the
report after cleanup. Keep the original execution error visible. A mock that
fails the first child stop and verifies the second stop plus retained report is
the appropriate bounded validation. Early environment/configuration failures
before the current reporting block are an additional report-coverage gap.

**Remediation verification:** the new `cleanup_replay` catches each marker,
child-stop, fallback-kill and log-close exception separately. It continues
through remaining children, records return codes, and clears qualification if
any errors exist. The caller then reaches its existing report write without a
cleanup exception replacing the primary execution error. Independent rerun of
the twelve common-runner Python tests passed, including both new cleanup tests.
The failure test injects a marker failure and a child-stop failure together,
checks that the remaining child is stopped and the failed child receives the
fallback kill/wait, and checks retained errors and failed qualification. The
success test checks preservation of a successful result. The tests target the
helper; continuation to the report write was checked by source inspection.
Disposition: CT-02 fixed for the reviewed cleanup failure paths. The separate
early-preflight report-coverage limitation remains; this bounded fix does not
claim that every possible filesystem failure can produce a report.

### CT-03 — Packet qualification does not establish arrival order or a pacing budget

Severity: low for the current short captures; medium for a future stronger
delivery claim. Confidence: high. Classification: validation gap, not observed
packet corruption or reordering.

The inherited `qualify_copper_aos_capture.py` groups by frame ID and sorts by
packet sequence before checking coverage and pixel payloads. This proves packet
identity and content but does not itself reject reordered arrival. It records
measured source periods/readout intervals without an allowed timing-deviation
budget. Requested `-period` and `-readout` arguments are consequently not proof
of a deadline or source-jitter guarantee.

Independent read-only inspection of the saved raw TSVs confirmed the exact
arrival sequence `(frame 0, packet 1)` through `(frame 6, packet 32)` for both
runs, with nondecreasing capture timestamps. No hidden reordering was observed.
All sender payloads match their FITS pixels, including the signed-FITS-to-U16
offset. Thirty-two packets of eleven rows use 7,744 pixel bytes per packet,
within the sender's 8,024-byte payload limit.

Required validation before stronger future claims: preserve and check original
arrival order where order is a requirement, and declare the permitted pacing
deviation before treating source timing as a gate. Do not invent a new timing
budget from these seven-frame observations. The current harness explicitly
limits its claim to a short transport/numerical gate.

### CT-04 — Seven live frames do not exercise nonzero clipping feedback

Severity: medium for full-chain equivalence claims. Confidence: high.
Classification: disclosed validation boundary.

Both captures contain zero commands at the clipping limits. They establish
initial-state and short-trajectory behavior but cannot distinguish correct
nonzero feedback carry from several defective feedback implementations. The
1,031-frame array checks and [precision review](CLASSIC_PRECISION_REVIEW.md) are
separate evidence; they do not establish live transport under saturation.

Source inspection supports the intended live semantics: JFG warms the direct
graph before publication and resets it; `prewarm_owner` preserves the first
native Start's settling behavior; the graph owner resets its feedback slot;
and `_finish_feedback_candidate!` copies feedback only after successful terminal
output handling. Feedback ports are hidden from public transport and require
no extra consumer. The FGN module uses its existing host feedback property.

Required validation for the later saturated live gate: use the unchanged corpus
in the declared continued sequence, preserve controller state, and observe
nonzero feedback before making a live anti-windup-equivalence claim. Keep the
existing 10⁻⁶ mismatch visible rather than changing scientific coefficients.

### CT-05 — HEART rejected the generated alias syntax before ingress

Severity: high, blocks HEART startup. Confidence: high. Classification:
confirmed configuration-serialization incompatibility, separate from numerical
or transport behavior.

The subsequently retained attempt
`/home/dgamroth/.cache/rtc-classic-heart-progressive-short-20260930` failed before
INIT or sender launch. `scao.log` reports `daoConfig_getAlias` rejecting the
alias dictionary because keywords or `&` are missing, followed by a syntax
error at line 3 (`examplePath`). Its report records RTC exit code 156 and both
qualification fields false; the only preceding command was input validation.
The ordinary mapping emitted by generic YAML serialization was therefore not
accepted by HEART's existing alias parser. No HEART command/packet-equivalence
claim can be drawn from this attempt.

**Remediation verification:** `serialize_config` now emits an explicit anchor
for each ALIASES entry, preserves source anchor names, writes arrays and records
using brackets/braces, and uses double-quoted strings and decimal numbers.
Unsupported scalar forms are rejected. Independent source inspection confirmed
the alias requirement in `daoConfig_getAlias`, array recognition in
`daoConfig_getArrayDict`, object-ID creation at `{` in `daoConfig_readFileYaml`,
and the double-quote/minus-sign token rules in `daoStr_separateTokensYaml`.
These sources are in the `daoinsw-heart-comparison` utility library. The limited
serializer follows this parser's supported syntax rather than assuming generic
YAML is sufficient.

All eighteen focused configuration tests passed independently, including tests
that reject the former safe-dump aliases/records and accept the new serializer.
Those tests explicitly describe their source-derived syntax checks as distinct
from native parser execution. Separately, the parent's retained r2 attempt
advanced through parsing to WFS allocation; its r3 attempt ran the scientific
chain and passed the packet/numerical subchecks. These are observed native
evidence that the initial parser failure is fixed for the pinned configuration.
Independent decoding of the retained r1/r2/r3 YAML found exactly equal values,
and all fourteen calibration-manifest entries were unchanged. Disposition:
CT-05 fixed and independently reviewed. The subsequent memory and telemetry
failures below are separate conditions.

### CT-06 — Huge-page allocation failed; the existing process option permits replay

Severity: medium, startup environment. Confidence: high. Classification:
observed allocation failure and disclosed execution-mode choice.

The retained `rtc-classic-heart-progressive-short-r2-20260930` attempt reached
SHWFS allocation, where `hrtMemory.c` reported that huge-page `mmap` could not
allocate memory. RTC exit code was 254 and qualification remained false.
The runner then selected the existing `HRT_MEMORY_HUGEPAGES=0` option for r3.
`heart-copper-comparison/source/util/src/hrtMemory.c:1342` reads that variable
and disables huge pages for the exact value `0`; the variable name is defined
in its existing header. The runner sets this process environment and records it
in the report. It performs no host memory-policy or reserved-pool adjustment.

Disposition: r2 remains a failed attempt. The existing ordinary-page option
allowed r3 to reach replay; retain that option in provenance and any later
performance comparison. This review establishes neither huge-page performance
nor equivalence between memory-placement policies.

### CT-07 — HEART r3 passed wire subchecks but failed telemetry shutdown

Severity: medium, lifecycle qualification. Confidence: high for the observed
failure; root-cause remediation remains with the implementation agent.

The retained `rtc-classic-heart-progressive-short-r3-20260930` attempt captured
224 WFS packets and seven DM commands. Both physical and numerical subchecks
passed; maximum command difference was 4.172325134277344 × 10⁻⁷ µm with zero
clipping-decision disagreements. RTC nevertheless exited with code 155.
The log records an output telemetry bind failure at `127.0.0.1:1` and subsequent
`hrtTelemetry_close_streamList` errors because final chunks had no file
descriptor. Shutdown also emitted incomplete-input diagnostics, kept outside
the replay capture. This evidence establishes a lifecycle failure; it does not
by itself identify every underlying telemetry setup/cleanup defect.

The runner correctly keeps both overall qualification fields false despite
successful packet/numerical subchecks, preserving the abnormal exit in errors.
Disposition: preserve r3 as a failed lifecycle attempt with useful wire evidence.
The configuration agent is investigating disabling unneeded existing telemetry
streams through configuration. No HEART source change or ignored exit status
is authorized by this review. Effective flag/zero-state readback remains a
separate qualification limitation even after a clean shutdown is obtained.

**Configuration remediation review:** the r4 overlay omits only the CB
`TELEMETRY_FILE_STREAMS` and `TELEMETRY_SOCKET_STREAMS` selections and supplies
the existing SRT→HRT and HRT→SRT secondary-stream base addresses at localhost
ports 6200 and 6300. In `hrtTemplate.c:895,996`, absent tag lists produce zero
selected file/GUI streams. `hrtConfig.c:705–720` recognizes the two base-address
keys; these port values are already used by the maintained Copper configuration.
Automatically registered secondary streams still exist; the report explicitly
does not claim that every telemetry path is disabled.

Independent comparison of retained r3/r4 decoded YAML found exactly those four
changed keys. Scientific CB `CAPACITY` and all fourteen calibration-manifest
entries are unchanged. Deletions and added addresses are included in the
preparation report. R4 started and shut down with RTC exit zero, but the new
readback gate stopped it before ingress (CT-08). Therefore clean startup/abort
is observed; clean lifecycle after an actual seven-frame replay still needs
the parent's next native attempt. Disposition: bounded source-supported
configuration remedy reviewed; full replay validation remains pending.

**Final native evidence:** the completed parent r5 attempt,
`rtc-classic-heart-progressive-short-r5-20260930`, ran the seven-frame replay
and both RTC/capture processes exited zero, with no report errors. Thus the
bounded optional-telemetry remedy now has clean post-replay lifecycle evidence.
CT-07 is resolved for this short configuration; r3 remains a retained failure.
This does not qualify longer secondary-stream update windows.

### CT-08 — GMS blockState is not a current correction-mode attestation

Severity: high, prevents valid replay admission. Confidence: high from source
and native r4 evidence. Classification: confirmed harness state assumption.

The new readback path runs unchanged `hrtGmsPrint` before ingress and after
replay, reads CLWFC/TFC sections, checks section type and owner, rejects missing
or duplicate scalar fields, and checks every requested flag plus the two
initialized-disabled flags. Failed commands or reads are retained and fail the
run. Readback and internal initial-state verification remain separate report
fields; successful flag reads cannot silently set the internal-zero-state field.
Raw snapshot logs and the hrtGmsPrint binary hash are retained; snapshot-log
hashes are not yet added to the final artifact hash loop in this revision.

However, the first version requires each block snapshot to say `CORRECTING (4)`.
In the completed `rtc-classic-heart-progressive-short-r4-20260930` attempt,
CORRECT was acknowledged successfully but both snapshots said `RUNNING (3)`.
All requested/initialized flag values matched. The gate stopped before sender
launch and retained a failed report; RTC cleanup exited zero.

The source explains why this check is unsuitable. `hrtBlock_cmdHandler`
(`hrtBlock.c:1469`) calls `hrtBlock_processStateTrans` before dispatching the
command handler (`:1495`). The transition routine publishes
`gmsSection_p->blockState = block_p->state` (`:1325`). Only afterward does
`hrtBlock_cmdhandle_correcting` set the internal `base_p->state` to CORRECTING
(`:2795`), without republishing that GMS field. Thus this GMS value can represent
the previous state even when the correction command succeeded. This is not
evidence that a sample would execute with the wrong controller equation.

Required remediation: identify and check the existing command-level mode/loop
state authority, retaining owner/type/flag checks. Do not merely allow RUNNING
as proof of correction. Add a regression representing the actual native
snapshot and the chosen authoritative mode fields. Keep all initial-state
limitations explicit. The independent rerun of all 34 current configuration and
runner tests passed, but their original mock CORRECTING value failed to model
this native behavior; passing those mocks does not close CT-08. Disposition:
confirmed and sent to the configuration agent for bounded remediation.

**Remediation verification:** `parse_gms_mode` now requires exactly the
`gms.cmdHandler[0]` section of type CMDHANDLER, with single scalar values
`overallMode = 4` and `overallModeStr = CORRECTING`. This has a direct source
basis: `hrtTemplateCmds.c:1597–1603` publishes those fields after successful
command fanout. The CLWFC/TFC owner/type/flag checks remain strict, while their
blockState is retained as observational metadata. The runner requires two
successful command-mode snapshots and four successful flag snapshots across
pre-ingress and post-replay before setting `effective_flags_verified`.

All 35 focused configuration/runner tests passed independently, including the
new exact mode-identity/value regression and existing pre/post failure cleanup
coverage. The completed parent r5 report attests both mode snapshots and all
four flag snapshots. Both blockState fields remain RUNNING, demonstrating why
the corrected authority choice matters. Independent read-only checks also
confirmed exact order of all 224 WFS packets and seven finite command vectors;
the maximum command error remains 4.172325134277344 × 10⁻⁷ µm. RTC and capture
exited zero. `functional_wire_qualified=true`, `effective_flags_verified=true`,
and `effective_initial_state_verified=false`; full `qualified` therefore remains
false. Disposition: CT-08 fixed and independently verified with source, focused
tests, and completed native r5 evidence. Internal zero-state evidence was not
inferred from mode/flag success.

The two omitted setter calls are independently justified: CLWC's
`enableR0L0` setter can restart unavailable modal-statistics work even for zero
(`hrtClwcBlock.c:4824`), while TFC rejects any `enableHoPsd` setter request when
PSD is not configured (`hrtTfcBlock.c:3679`). Their initializers set both flags
to zero, and the new snapshot expectations still require zero. Removing those
invalid commands therefore does not remove their validation obligations.

## Other reviewed behavior

- The common runner creates the graph and unit adapter, establishes the links,
  waits for the adapter's PREPARED marker and the JFG owner's PREPARED marker,
  and starts capture before releasing the WFS sender. FGN parameter artifacts
  are loaded during module construction. U32 origins come from construction
  data checked against the exported binary; the active mask is constructed
  from validated U8 Boolean values. All eleven applicable F32 arrays remain
  startup artifacts. No parameter is silently omitted.
- JFG preparation tests cover normal startup, an existing stop marker, connect
  failure, and run failure using a mock node. The final report preserves the
  primary connect/run error and closes the owner. The saved live node report
  predates the final added `status` field: it attests PREPARED, seven callbacks,
  no bridge failure, and observed stop, but does not validate every final
  reporting path. This review did not run Julia tests or a fresh live replay.
- The unit adapter multiplies native microns by Float32 10⁻⁶ exactly once before
  the Standard-DM sink. The decoder compares the recovered wire values in
  microns, validates checksums/finiteness, and preserves command order.
  The common qualification subsequently checks exact adapter sequence coverage,
  child statuses, and receiver diagnostics.
- The HEART overlay preserves the padded 277-coordinate representation, uses
  the existing calibration filenames, loads the nonzero reconstruction matrix,
  selects gain −0.3 and pole 0.99, clears flat/offset/slew paths, and disables the
  selected optional terms through configuration and requested runtime flags.
  Source/calibration/output hashes and explicit overrides are retained.
- HEART remains ordinary progressive stdWfs: the runner sets
  `HRT_DEFER_WFS_INGRESS=0`, starts a fresh RTC, requires INIT/RUN/CORRECT command
  acknowledgements, and captures before source release. It stops capture before
  SHUTDOWN so shutdown commands are not replay samples. Requested flag ACKs are
  explicitly distinct from effective flag/zero-state readback. The later GMS
  path adds direct flag readback and the verified CT-08 command-mode check.
  Full matched qualification separately requires internal zero-state evidence.
  Functional wire success alone must not be described as completed HEART
  scientific qualification.

No scientific implementation or HEART source change was proposed. No build,
live replay, CPU-intensive benchmark, or hardware validation was performed in
this review. Verification comprised source inspection, inexpensive reads of
the retained packet/command evidence, and nine focused Python mock tests via
`python3 -m unittest discover -s benchmark -p test_run_classic_heart_live.py -v`.
The CT-02 follow-up also independently ran all twelve tests in
`test_run_classic_live.py`; all passed.
The serializer follow-up independently ran all eighteen tests in
`test_prepare_classic_heart_config.py`; all passed. It inspected the parent's
retained r1/r2/r3 logs/configurations/capture summaries without executing HEART.
The telemetry/GMS follow-up ran all 34 current configuration/runner tests;
all passed, and the completed parent r4 failure was independently inspected.
The command-mode correction increased that suite to 35 tests; all passed
independently, and the completed parent r5 report and packet/command artifacts
were inspected without running another live replay.

## Final disposition

CT-01 and CT-02 are fixed and independently verified. CT-03 and CT-04 are
validation boundaries for future claims; they do not invalidate the observed
seven-frame captures. The review supports the narrowly stated successful
FGN/JFG short-capture result. CT-05 is fixed, with native parsing/replay evidence
and unchanged decoded configuration values. CT-06 records the failed huge-page
attempt and supported process-level opt-out. CT-07 keeps the HEART r3 lifecycle
failure separate from its successful packet/numerical subchecks; its bounded
configuration remedy is now verified through a clean r5 replay lifecycle.
CT-08 is fixed with source-backed command-mode attestation and passing native
pre/post reads. R5 establishes the short HEART functional wire result and mode/
flag verification. Internal zero-state readback remains unverified, and full
matched qualification remains false. The seven-frame result does not qualify
live saturation feedback, row-block execution, capacity, or tail latency.
