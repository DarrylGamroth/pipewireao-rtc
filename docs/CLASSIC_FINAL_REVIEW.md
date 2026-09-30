# Classic integration review

Date: 2026-09-30. This is a source and evidence-contract review, followed by
explicitly authorized harness fixes. It does not qualify pending capacity
runs, new production deployments, or physical application accuracy.

## Scope and revisions

| Repository | Reviewed range |
| --- | --- |
| JuliaFilterGraph-progressive-requal | `1d91a589709ec9d28a194593ca387fbfc7f41fb3` → `6f1da393f9bd7153ed95b8811ccf32ebce6342a6` |
| pipewireao-rtc-progressive-requal | `94fd0162a03b8ab6213f88bbe28c8d7e3c360eac` → `ddd526c9ee022f1e9fdbc2c206d9601458e70003` |

The RTC worktree advanced to `82c8066` during review; its separate plugin
selection change was preserved when applying the timestamp correction.
Unrelated profiles, the Copper capacity summarizer, another worker's row
admission evidence, and JFG's untracked Python cache were left untouched.
No main branch, installed binary, scientific algorithm or coefficient changed.

The review followed the `review-low-latency-hot-path` skill. Source inspection
covered JFG callback storage/counter changes, runner startup and teardown,
packet/clock correlation, both RTC live harnesses, SPA sender lifecycle,
placement, numerical-policy selection, campaign intervals, archive readers
and the finite-window capacity classifier. Existing numerical and capacity
helpers were authored earlier by this same review worker; their integration
inspection here is **not a second independent audit of their implementation**.
Earlier source/arithmetic analyses remain the detailed basis for those helpers.

## Disposition

Two confirmed harness defects were found and corrected after primary-agent
adjudication. A later combined-classifier execution exposed FR-03 below;
it was also corrected. None establishes corruption of existing saved results.

| ID | Severity / confidence | Finding | Disposition |
| --- | --- | --- | --- |
| FR-01 | P2 / high | Campaign intervals accepted backward or nonfinite packet times | Fixed in `6856d51`; saved earlier captures still require a timestamp audit |
| FR-02 | P2 / high | Sender cleanup exceptions skipped its report and could replace a primary replay exception | Fixed in `b892258`; mocked cleanup regressions pass |
| FR-03 | P2 / high | Truncated WFS headers escaped the evidence reader as `struct.error` and aborted combined classification | Fixed by explicit header-length validation; same 15-test suite fails before and passes after |

No additional confirmed source blocker was found within the reviewed scope.
The fixes require primary-agent integration review. Historical cached interval
summaries cannot acquire the new validation merely by updating the harness.
The primary agent owns their saved-data audit and final capacity disposition.

### FR-01 — reject invalid time ordering before deriving intervals

**Observed source:** At reviewed RTC revision `ddd526c`,
`benchmark/run_classic_campaign.py:intervals` checked packet identities and
counts, parsed `Decimal` timestamps, and rejected negative terminal-to-DM
intervals. It did not validate timestamp finiteness or ordering within either
stream. The inherited physical capture qualifier checked protocol/pixel
content but only summarized timestamps. `classic_capacity.py:load_run_evidence`
trusted a positive cached achieved rate as a complete validated source window;
its stricter packet fallback was bypassed in that case.

**Derived counterexample:** In each frame, first WFS at 1.000000 s, terminal
WFS at 0.999000 s and DM at 1.000100 s, with subsequent frames shifted by
10 ms, gives 100 Hz achieved rate, 100 µs first-to-DM, 1,100 µs terminal-to-DM
and −1,000 µs readout. Correct identities and positive terminal-to-DM did not
exclude this malformed clock sequence. With otherwise passing gates, both
capacity contracts could pass. This is a validation defect, not evidence that
this timestamp sequence occurred in a real capture.

**Correction:** Both WFS and DM timestamps must now be finite and
nondecreasing. Equal timestamps remain valid. Rejection occurs before writing
`latency-intervals.json`. The existing campaign exception path records an
analysis error and retains/archives the raw capture. No live processing or
classifier architecture changed. A monotonicity check still cannot rule out
every realtime clock-rate error or an undetected interior clock excursion.

**Verification:** The same 13-test focused campaign suite failed before the
guard with nine failing subcases and passed afterward on CPU 14 in 0.012 s.
Regressions cover backward intermediate/terminal WFS timestamps, backward DM
timestamps whose commands still follow their own terminal packets, all three
nonfinite values in both streams, and equal WFS timestamps. No live replay was
run. Existing results must be audited from retained packet timestamps; positive
summary minima alone do not establish global timestamp ordering.

### FR-02 — retain sender failure evidence through cleanup errors

**Observed source:** At `ddd526c`,
`benchmark/run_classic_spa_sender.py:run_sender` called `helper.stop` and
`shutil.rmtree` before writing its report in one unprotected `finally` block
(original lines 230–239). Either exception skipped `report.json`; when replay
had already raised, the cleanup exception replaced it. Outer harness logs
could still show failure, so this did not create a false passing run, but the
sender's accumulated provenance/counters and original error could be lost.

**Correction:** Cleanup outcomes and errors are recorded separately for daemon
and runtime-directory cleanup. Cleanup failure forces `qualified = false`.
The report write is attempted after either step fails, and an active replay
exception is preserved. If report writing itself fails during replay failure,
stderr records the additional failure. Filesystem write failure cannot promise
a durable report. The existing transport helper continues to own process
stopping; this change adds no new stop framework or realtime behavior.

**Verification:** The initial focused invocation on CPU 14 passed all seven
sender tests in 0.014 s. A subsequently authorized same-suite comparison loaded
the unmodified module from `git show b892258^:benchmark/run_classic_spa_sender.py`
into the current test module's `SENDER` binding, without changing the worktree.
The old module failed in 0.021 s with four errors: three cleanup-failure cases
had no `report.json`, and normal cleanup lacked the new outcome field. The same
seven tests with the corrected module passed in 0.014 s. These mocked cases
cover normal cleanup, stop failure, runtime removal failure, and simultaneous
cleanup failures during an original replay exception. They inspect the
persisted report, failed qualification, cleanup states, and original exception
identity. No claim is made that a saved sender run encountered this failure.

The retained `run_sender_cleanup_tests.py` runner selects only the sender
module; both invocations use the same checked-in focused tests. Reproduce from
the RTC repository root, using `run_classic_spa_sender_before.py` for the
fail-before invocation and `benchmark/run_classic_spa_sender.py` for pass-after:

```sh
taskset -c 14 python3 -B \
  ~/.cache/classic-final-review-20260930/run_sender_cleanup_tests.py \
  ~/.cache/classic-final-review-20260930/run_classic_spa_sender_before.py
```

## Callback ownership, allocation and disabled tracing

The only production JFG change in the reviewed range adds two preallocated
allocation-counter vectors and two `Base.gc_total_bytes(stats)` stores to the
existing trace implementation in
`julia/FilterGraphPipeWire/src/graph_node.jl` (trace definition around line 349,
begin/end around lines 1901–1937).

| Execution boundary | Source conclusion |
| --- | --- |
| Tracing disabled (`nothing`) | Existing constant begin/end methods remain unchanged. New clock or GC reads are not introduced on that branch. This is source inspection, not a new machine-code or cycle measurement. |
| Trace enabled, GC counters disabled | Existing timestamps/header capture remain; new allocation counters are not read. Storage is allocated before publication. |
| Trace enabled with GC counters | Existing GC snapshots supply the added byte counters. Fixed vectors are written by the serialized callback; overflow increments `omitted` and does not grow storage. |
| Trace export | The runner closes the native node before reading/exporting trace storage, relying on the established native close/quiescence contract. CSV/report allocations occur after processing. |

The clock bracket surrounds `_process_graph_buffers!` and the success counter.
Property adoption precedes it; notification follows it; the native bridge and
initial Julia dispatch are outside it. Byte/GC snapshots lie inside the clock
bracket, so their interval is slightly narrower. Counters are process-global:
concurrent helpers and other Julia tasks contribute. Native allocations and
work between snapshots are not measured by these counters. Zero observed
deltas support the stated measured-body claim, not whole-stack allocation
freedom, a thread-exclusive attribution, or a worst-case timing guarantee.
The maintained callback documents state these boundaries appropriately.

The two ordinary-array science warmups and owner prewarm are distinct. For row
mode, owner prewarm lacks row metadata and returns the metadata-missing result
before sensing. The runner explicitly records this limitation. It therefore
does not establish that the first real borrowed-buffer science call is free of
all initial compilation or native dispatch cost. That is a remaining evidence
limit, not a demonstrated JIT cause of frame loss. The separate saved admission
trace identifies a retained terminal buffer at admission and must retain its
more specific measured attribution.

## Numerical and measurement acceptance

- The original strict comparison is still written separately. Selecting
  `source-arithmetic` can pass a run whose historical strict comparison failed;
  those strict failures remain failures under their original criterion.
- HEART acceptance requires both the source-derived rounding bounds and exact
  Float32 wire agreement with its independent recurrence model. FGN/JFG future
  wire acceptance establishes consistency within derived rounding bounds, not
  bitwise agreement with an independently executed model of every internal
  stage. The classifier explicitly labels the different strengths.
- The fixture enforces the all-active 188-subaperture assumption and hashes the
  active mask, original coefficients and calibration arrays. Clipping
  disagreements are checked separately by the harness. A broad interval's
  ambiguous clipping count does not become proof of internal state uniqueness.
- Arithmetic acceptance supplies no physical accuracy budget. HEART's broad
  `qualified` flag remains separate from `functional_wire_qualified`; hidden
  initial-state readback is still unavailable. The capacity classifier uses
  the declared functional gate without silently changing that distinction.
- First-WFS-to-DM and terminal-WFS-to-DM have separate recorded distributions.
  The one-period deadline includes every frame. The after-first-100 summary
  is a separate descriptive subset, never the deadline gate. Percentiles are
  omitted for fewer than 100 samples in campaign summaries.
- Delivery capacity and deadline-clean capacity are separate contracts. A late
  loss-free window does not fail delivery. Unknown, incomplete, underdriven or
  overdriven load, abnormal exits and unverified placement are excluded from
  RTC capacity upper bounds. The default ±1% criterion concerns average source
  pacing, not jitter. Repetition checks establish distinct windows, not
  statistical independence or indefinite loss-free operation.
- Callback/PCAP correlation uses endpoint clock envelopes and explicit
  assumptions about the interior offset. The 10 µs sensitivity check tests a
  wider model; it does not measure or prove a clock-error bound. Row-work
  inference applies to the actual synchronous FGN fused graph and JFG split
  graph with zero helpers; helper callback counts alone do not establish MVM
  column completion.

The original failed strict comparisons, failed HEART shutdown/port-guard
attempts, failed capture-startup attempt and frame-admission failure remain
documented alongside successful replacements. Trace runs remain separate from
uninstrumented capacity measurements. Archive readers check decoder status;
the report does not treat missing or corrupt compressed evidence as a pass.
Pending new-source capacity outcomes were not adjudicated by this review.

## Verification record

This pass ran no Julia/C builds, live workloads, UDP traffic or capacity tests.
Only the explicitly authorized focused Python suites above were executed.
Earlier live/build results were inspected as existing evidence, not rerun.
The remediation diffs were inspected and `git diff --check` passed.

Logs are retained under `~/.cache/classic-final-review-20260930/`:

| File | SHA-256 |
| --- | --- |
| `classic-final-review-campaign-before.log` | `ac793daccb337066950b2a90d77ecbf365d925aa2f010a470af12e4c142d5408` |
| `classic-final-review-campaign-after.log` | `8e6ee86a19f09028b0eb7e7edea126c74fdebb386dee5cf606adff182dac161c` |
| `spa-sender-cleanup-after.log` | `cedb82dc56386349028ceffb44102c4710aeaac8c7851a279af282486d8d23a8` |
| `spa-sender-cleanup-same-suite-before.log` | `a56e479d55d7335f163af0df8f24b18cb3870c5f5b3526db6aee5728d8c07d84` |
| `spa-sender-cleanup-same-suite-after.log` | `ce260cec0813a18bf562d84755786f5ba666fa2a8effe40c3f0b1f468aa22832` |
| `run_sender_cleanup_tests.py` | `07f86b35c1b53966ebe123206d5d9fa46fc1778128a47aa40f17d651e169acec` |
| `run_classic_spa_sender_before.py` | `e14238ffb0340c9a7a6d974d2a71b0dea0845e74278079c6643d5f565b20feae` |

## Follow-up FR-03 — malformed retained evidence must not abort classification

**Observed:** After the initial integration review, the primary agent's final
combined classification aborted on an old failed capture. The retained traceback
in `~/.cache/classic-final-analysis-step2-20260930.log` ends at
`source_pacing_from_packets` with `struct.error: unpack requires a buffer of
40 bytes`. Its SHA-256 is
`99b45ec5ff8c816a2276c92c8641f5def5faa37480b86590d687b822f1b109f7`.
The earlier review did not detect this exceptional input path.

**Confirmed source cause:** `classic_capacity.py` decoded the available
hexadecimal header bytes and passed them directly to `WFS.unpack`.
`load_run_evidence` catches expected input exceptions, including `ValueError`,
but `struct.error` is a different exception. A truncated or empty packet header
therefore aborted the complete manifest analysis instead of recording that
window's unavailable source pacing. This did not turn failed delivery into a
pass; it prevented classification from completing.

**Correction:** Validate that the decoded header has exactly `WFS.size`
(40) bytes before unpacking. A short header raises `ValueError` identifying
the truncated WFS header, packet ordinal, actual size and required size.
The existing reader records it in `read_errors.source_pacing`. With no valid
source-rate evidence, that window is excluded from both capacity contracts;
its original delivery failure and launcher status remain visible. No generic
exception catch or acceptance-criteria relaxation was added.

**Same-suite verification:** On CPU 14, the focused capacity suite ran 15 tests
before and after this fix. Before: six errors in 0.014 s, all the expected
uncaught `struct.error` cases. After: all 15 passed in 0.013 s. Regressions use
0-, 1- and 39-byte headers, both directly and through `load_run_evidence` plus
`classify_window`; they check recorded read errors, unknown source pacing,
excluded delivery/deadline status and preserved failed wire delivery. The
existing corrupt-Zstandard rejection test still emits its expected decoder
diagnostic and passes.

Logs under `~/.cache/classic-final-review-20260930/`:

| File | SHA-256 |
| --- | --- |
| `capacity-truncated-header-before.log` | `58a91ba9b8d76ab1bb0a50f56eb4d9fe8d3c73e11bd2d0e7183f39d0c4c2980a` |
| `capacity-truncated-header-after.log` | `814560f8f533e023c197108bb9f1a5c68542cd64a843acd4f8f53345dedcd934` |

No build, live replay, UDP traffic or saved-capture modification was performed.
The primary agent owns the subsequent complete classifier rerun. It separately
reported that its timestamp audit covered 85 windows and passed; that audit
was not independently rerun here and does not imply that every retained
capture has complete or valid WFS packet content.
