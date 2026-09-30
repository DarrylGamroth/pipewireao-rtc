# Classic row integration review

Date: 2026-09-30. Independent source and retained-evidence review. The reviewed
serial paths support the seven-frame, unsaturated functional result. No confirmed
unfixed processing defect was found in this increment. Scientific qualification,
nonzero live clipping feedback, latency, sustained capacity, and live callback
allocation remain separate gates. The existing 10⁻⁶ criterion is unchanged.

## Scope and provenance

This review applies to the explicit benchmark increment under the
[active authority map](../docs/README.md), [row design](CLASSIC_ROW_DESIGN.md),
[precision review](CLASSIC_PRECISION_REVIEW.md), and
[transport review](CLASSIC_TRANSPORT_REVIEW.md). It does not promote the archived
RTC architecture or establish physical operation.

| Component | Inspected source |
| --- | --- |
| PipeWire core | `pipewire-classic-row-buffers`, `a4de38e0d7257d98e5c03c51f248f84e6a822c26` |
| JFG | `JuliaFilterGraph-progressive-requal`, `8b608e6226db680ee5690a387f17d1473f5aeef4` |
| Rust scientific bundle and fixture | `calculon-algorithms-progressive-requal`, `54d8b1847d7913f532e1d48ceba2429eb2499055`, including `3a2b878ba91c86ab73628501471c38aac2cd437c` |
| RTC | `pipewireao-rtc-progressive-requal`, branch `copper-progressive-requal-20260929`, HEAD `e7e266af728bb201b1bc03e9d42fc3c8d87b0596`, with existing benchmark edits |

The RTC worktree already contained edits to the comparison/design, runner and
runner tests, plus the row evidence JSON and unrelated capacity/profile files.
The JFG worktree contained an untracked Python cache; Rust and core were clean
when inspected. This reviewer changed only this review document. No build, test
suite, live replay, commit, production edit, or hardware experiment was run.
Verification comprised source inspection, small Python reads of saved packet
and array artifacts, SHA-256 comparisons, and inspection of retained test logs.
The low latency hot path review skill supplied the ownership/allocation scope.

The original successful captures are:

- `~/.cache/rtc-classic-jfg-row-short-r1-20260930`.
- `~/.cache/rtc-classic-fgn-row-short-fixed-r1-20260930`.

Both contain 224 WFS datagrams and seven DM vectors. Independent decoding of the
raw TSVs found exactly `(frame 0, packet 1)` through `(frame 6, packet 32)` in
arrival order, nondecreasing timestamps, and DM IDs exactly `0..6`. Independent
Float64 subtraction of the saved Float32 vectors against the shared Rust oracle
found maxima of 2.682209014892578 × 10⁻⁷ µm for JFG and
1.1920928955078125 × 10⁻⁷ µm for FGN, with 1,939 finite values each and no values
at the ±0.8 µm limits. Reports preserve clean child exits, zero source rejection,
drops and starvation, and seven complete source frames. JFG attests 224 callbacks
and a healthy feedback bridge. These checks independently support the reported
short result; they do not derive successful frames from callback counts.

The parent subsequently supplied a release-core run. Inspection of
`~/.cache/rtc-classic-fgn-row-release-short-r1-20260930` confirms a passing
seven-command report, all 224 blocks, clean exits, and the same FGN numerical
maximum. `/tmp/classic-row-core-release-tests-20260930.log` reports all sixteen
ndarray tests passing. The completed JFG release replay at
`~/.cache/rtc-classic-jfg-row-release-short-r1-20260930` was subsequently inspected
independently: clean exits, 224 callbacks, healthy feedback, exact ordered WFS
packets and DM IDs `0..6`, and the same 2.682209014892578 × 10⁻⁷ µm maximum.
These staged release-prefix checks establish the short result on that deployment;
they do not establish installation into `/opt` or performance qualification.

## Reviewed scientific and protocol behavior

FGN has eight nodes: row calibration, fused SH sensing/reconstruction, and the
original six downstream controller/projection/limiting/feedback nodes. JFG has
nine: row calibration, SH measurement blocks, incremental reconstruction, and
the same six downstream functions. Inspection of the fixtures and parameter
loaders found the intended 352 × 352 detector, 11-row blocks, 188 subapertures of
22 × 22, 376 pair-interleaved slopes, 221 controlled coordinates, and 277 physical
commands. The internal JFG measurement/column/count schema strings match at both
ends. Rates are based on frame rate with the existing row declaration multiplier;
no second factor of 32 was introduced.

The FGN resolved configuration retains eleven F32 startup artifact paths, all
pointing to the same prepared fixture used by JFG. The U32 origin array is
compared with construction data, and the U8 mask is restricted to Boolean values
before construction. Fused sensing receives the former SH parameter ports under
`reconstruction:`. JFG's saved parameter hashes all match the current retained
fixture files, and its saved source graph hash matches the committed fixture.
The existing row-major conversion and the matrix shapes preserve the selected
calibrations. No new AO equation, coefficient, watermark, camera backpressure,
or HEART source change was found.

The recurrence remains:

```text
sₙ = uₙ₋₁ − 0.99 fₙ₋₁
uₙ = 0.99 sₙ − 0.3 rₙ
```

The graph source retains all controller-to-VDM, VDM-to-PDM, command limiting,
PDM-to-VDM feedback, and VDM-to-controller feedback stages. Hidden-mode gain is
zero. Different fused/split sensing and reconstruction reduction orders remain
part of the comparison; equal type names do not establish bitwise equality.

The native metadata adapter converts Header sequence and zero-based row offset
to `RowBlockInfo`. Complete reconstruction preserves the sequence and terminal
input timestamp, emits offset zero and terminal true, and propagates accumulated
discontinuity. JFG uses the same Header fields, including MARKER, DISCONT and
CORRUPTED. Nonterminal/deferred results suppress the graph's external outputs;
CLWC is reached only after reconstruction completion. The command adapter is the
single public command consumer and performs the existing micron-to-metre wire
conversion exactly once.

The new JFG lifecycle test is more discriminating than a callback-count check:
it inspects every nonterminal output's availability and contents, committed CLWC
state, feedback retention, terminal numerics, exact short sensing slopes,
missing/reordered/corrupted blocks, supersession, reset, and discontinuity
recovery. A synthetic nonzero retained feedback slot makes unintended carry on
deferred calls observable. That injection tests retention, not live saturation.
The test also checks that row views retain their source-frame parent. Its zero
allocation assertion is confined to the warmed direct replay call. The reported
1,621 assertions were supplied by the parent; this review inspected their source
rather than rerunning Julia.

## Ownership and publication

| Resource | Writer and readers | Lifetime and publication boundary |
| --- | --- | --- |
| Array replay raw rows | Prepared fixture arrays; serialized graph reader | Precreated views retain parent matrices; source frames are not mutated during replay |
| Native raw row | Existing SPA/PipeWire producer and the current graph callback | Borrowed only for the synchronous callback; JFG validates extent, capacity and alignment before projection |
| Calibrated pixels needed across blocks | Scientific SH workspace | Incoming calibrated rows are copied into the existing owned detector workspace before the raw borrow ends |
| JFG measurements/reconstruction | Serial graph in this gate | Zero helper workers; no new cross-thread scientific publication protocol is exercised |
| JFG feedback | Serialized graph owner | Private slot enters the next admitted frame; scratch is copied only after terminal availability and output metadata/finalization succeed |
| FGN feedback | Native graph callback | Private output chunk must be absent or exactly full; absent leaves retained input unchanged, complete payload is copied after graph success |
| Public DM command | Graph output, then one unit adapter | Existing native publication/queue mechanism; seven externally captured IDs prove the short terminal outputs |
| Native pool | Existing bounded filter allocation | Max 64; source requires 32 for the selected geometry; default 4 and minimum 2 are preserved |

Source anchors include JFG `graph_node.jl` `_borrow_buffer`, `_buffer_metadata`,
`_process_feedback_buffers!`, and `_finish_feedback_candidate!`; graph
`_process_candidate_admitted!`; SH measurement processing; Rust
`row_block_info`/`row_block_process_result`; and native
`commit_feedback_bridges`. Reset clears graph and feedback state. The live JFG
case retains its CPU owner until the PipeWire node has stopped and then closes
it. Existing helper publication is outside the serial result: helper layouts,
thread placement, acquire/release behavior under helper load, and cancellation
require their own evidence before performance approval.

Node workspaces can commit before later nodes finish. This review therefore does
not reinterpret “successful frame” as a transaction that rolls back every node
after arbitrary downstream failure. The bridge fails closed on terminal errors;
the demonstrated missing/reordered/corrupted cases are rejected upstream of CLWC.

## Findings and dispositions

### CR-01 — Pending calibration discontinuity was consumed one row late

Severity: high for the original first-frame loss. Confidence: high.
Classification: confirmed defect, fixed in the reviewed source.

Both Rust calibration wrappers formerly used
`sample.is_discontinuous() || workspace.take_discontinuity()`. A marked first
block short-circuited the state-consuming call. Row two then carried the pending
discontinuity and caused reconstruction to abandon frame zero. The retained
native attempts at both 2 ms and 20 ms readout received 224 blocks but emitted
only DM IDs `1..6`; changing pacing did not cure the loss.

Commit `3a2b878` consumes the pending flag before the Boolean combination in both
row and region calibration. Four focused reset/adoption regression logs fail on
the second block before the fix; the complete two-file post-fix run passes twenty
tests. The logged pre-fix cases used sequence 41, while the final committed cases
use sequence zero: this is a harmless fixture difference for the Boolean state
mechanism, but the artifacts should not be described as byte-identical tests.
The fixed live FGN replay at the original 2 ms pacing delivers all seven IDs.

Disposition: resolved for the demonstrated mechanism. No calibration arithmetic
or controller coefficient changed. No speculative pacing remedy is needed.

### CR-02 — Original native reports have incomplete configuration provenance

Severity: medium for reproducible qualification; does not refute the observed
short wire result. Confidence: high. Classification: evidence gap.

The original FGN report hashes the profile and binaries but omits the resolved
graph, daemon configuration, and individual calibration arrays. Its graph and
configuration files remain saved, and their paths identify the shared fixture;
this is useful recoverable evidence, not contemporaneous array attestation.
The original JFG report additionally hashes its graph and arrays. Its native
build report records pre-commit core HEAD `d130d3a` alongside the actual binary
hashes. The fixed FGN run uses an installed staging prefix with binary hashes
and no source/build revision fields. The two original runs therefore are not a
single release-build performance comparison.

The parent added prospective `parameter_sha256`, `resolved_graph_sha256`, and
`daemon_configuration_sha256` fields. Source inspection confirms these are
computed before daemon launch, after FGN graph installation. This closes the
specific omission for future reports without rewriting old reports. Source to
binary/build-mode linkage remains a release manifest/evidence responsibility.

Disposition: bounded harness remediation reviewed; preserve the original
provenance limitation. Label any later hashes of old retained files retrospective.
For release/performance claims, retain exact source revisions, build options and
binary hashes with each replay and document matched placement/core budgets.

### CR-03 — Short row success does not close clipping or long precision gates

Severity: medium for broader scientific-equivalence claims. Confidence: high.
Classification: known validation boundary, not a new processing defect.

Both live row captures have zero clipping. The JFG short array comparison also
has zero clipping feedback. Source inspection supports one terminal feedback
carry, and the injected nonzero slot tests retention, but neither proves live
nonzero anti-windup feedback under the selected wire topology. The existing
1,031-frame full-frame precision record still has 333 failing controller values
across 280 frames and a 1.2516975402832031 × 10⁻⁶ µm maximum. Its independent
recurrence replay supports the controller equation while leaving the precise
reconstruction reduction mechanism unresolved. It does not qualify the row
trajectory.

Disposition: open gate, correctly disclosed. Cheapest discriminating next work
is a continued row array replay with the existing oracle, saved residuals,
controller state and computed feedback, followed by live nonzero-clipping replay
with preserved state. Retain the original criterion and every failing value;
do not change coefficients or infer row acceptance from full-frame tests.

### CR-04 — Direct array allocation evidence excludes the live row callback

Severity: medium for an eventual zero-allocation or latency claim. Confidence:
high. Classification: disclosed measurement boundary.

`process_frame!` measures 32 direct graph calls, metadata construction,
availability checks and one terminal feedback copy using prepared Julia views.
The live boundary uses `RowMajorBorrowedArray` and the feedback owner. The
existing Start warmup has absent metadata and stops at the row calibration's
metadata-missing result before sensing. Two explicit array warmups do not prove
that every live specialization is warmed. The saved JFG node report explicitly
states this limitation and reports 4,670,464 allocated bytes across connection,
run and close, with zero observed collections. Those bytes cannot be attributed
to steady callback work from this diagnostic alone.

Disposition: no zero-allocation live claim approved. A focused allocation probe
on the actual warmed row-major borrowed-buffer callback, with valid row metadata
and terminal feedback, is the cheapest discriminating measurement. Separate
startup/JIT and steady callback scopes. Compiler, Julia/project/sysimage, BLAS,
thread/GC configuration, placement and latency distributions are incomplete for
full performance approval; the serial functional gate needs no invented budget.

### CR-05 — Completed buffer remediation remained listed as a future fix

Severity: low. Confidence: high. Classification: confirmed documentation defect,
remediated during review.

The initially inspected `CLASSIC.md` remaining-gates item still described a
16-buffer consumer maximum and proposed correction despite its completed row
section. The parent replaced that item with the remaining release/helper/allocation
qualification work. This review independently inspected the correction.

The connected regression genuinely negotiates and counts 32 source buffers,
then exercises conditional output retention. Its preserved fail-before log
shows incompatible 32 versus max-16 ranges under the same daemon policy; the
pass-after log includes ordinary and FIFO small-pool regressions. Native
`filter.c` retains its explicit `n_buffers > 64` rejection. The new test does not
itself constitute an exercised 65-buffer negative case or a sustained 32-block
loss/recovery test; the short native replay covers the selected source geometry.

Disposition: documentation resolved; test evidence accepted for bounded
negotiation and the short transport gate. Do not describe source inspection of
the >64 guard as a newly executed negative test.

## Final disposition

The serial row changes and CR-01 remedy are supported for the retained short
functional gate. Original failures remain visible in
[the row evidence](data/classic_row_development_20260930.json). CR-02's prospective
hashing remedy is source-reviewed; old runs retain their historical provenance
limits. CR-03 and CR-04 remain explicit qualification boundaries. CR-05 is fixed.
No additional production change is recommended on a hypothesis from this review.
