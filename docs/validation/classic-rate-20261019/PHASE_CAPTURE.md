# Classic rate phase capture

This note defines the bounded phase capture used to compare repeated Classic
rate trials with the optional GUI closed and open. It is an investigation aid;
captured software timings do not qualify physical camera timing or a physical
adaptive optics loop.

## Enablement and bounds

Capture is off by default. The owner accepts these capture arguments:

```text
--phase-timing-directory ABSOLUTE_PATH
--phase-timing-frames COUNT
--phase-timing-warmup COUNT
```

The warmup option is optional and defaults to 512 frames. The capture capacity
must be in 1–65,536 rows, and warmup must be in 0–65,536 frames. The owner
preallocates and touches the fixed row storage before the timed loop. One serialized
simulator owner thread records the rows while the owner remains active and holds
the simulator lifecycle. It performs no report-file I/O while recording. A
stop, finite-run completion, generation reset, or owner termination writes
`phase-timing-GENERATION.json` using a
same-directory temporary file and atomic rename; an existing regular report
for the same generation is refreshed atomically. Directory and symlink
conflicts are preserved and reported as errors.

The report is version 1 JSON. It includes the owner PID, bootstrap instance,
generation, wall period, pacing mode, warmup count, capacity, saved record
count, whether capacity was filled, the ordered column names, and row arrays.
`period_ns = 0` means unpaced operation and is recorded as `pacing = "unpaced"`.
Positive periods are recorded as `pacing = "periodic"`.

## Row contract

Every row contains 17 unsigned 64-bit integers in this order:

| Column | Meaning |
| --- | --- |
| `generation` | Owner/source generation for the exchange. |
| `sequence` | Completed frame and command exchange sequence. |
| `deadline_ns` | Wall-clock deadline assigned to the exchange. |
| `started_ns` | Exchange start timestamp. |
| `ready_ns` | Timestamp when the exchange is ready to step. |
| `step_started_ns` | Start of the AOS graph step. |
| `step_finished_ns` | Completion of the AOS graph step. |
| `staged_ns` | Frame staging timestamp. |
| `published_ns` | Frame source publication timestamp. |
| `received_ns` | Matching correction command receive timestamp. |
| `adoption_started_ns` | Start of command adoption into the AOS boundary. |
| `finished_ns` | Completion timestamp for the exchange. |
| `optical_finished_ns` | Timestamp immediately after the optional optical observation sampling call returns. This is not completion of its asynchronous image worker. |
| `next_deadline_ns` | Deadline selected for the next exchange. |
| `missed_periods` | Skipped future release slots after `deadline_ns + period_ns`; this is not the number of late starts. Zero in unpaced mode. |
| `process_gc_time_ns` | Cumulative Julia process GC time sampled after this exchange. |
| `process_allocated_bytes` | Cumulative Julia process allocation counter sampled after this exchange. |

Timestamp columns use the process monotonic nanosecond clock. They are elapsed
time markers, not UTC wall time or model time. The two process counters are
cumulative observations of the whole simulator process, including optional
worker activity; they are not per-frame costs or allocation claims for the
instrumented exchange.

The owner excludes the configured initial warmup frames. It records a row only
after a successful exchange returns with matching frame and command sequence.
A failed exchange does not produce a partial row. If capture capacity is
reached, later exchanges continue without adding rows. Repeated saves without
new rows are no-ops. A stop after a partial capture can save, resume the same
generation, append rows, and atomically refresh the same report.

## Controlled closed/open trial plan

Use the same machine, owner configuration, graph and controller configuration
for every trial. Keep frame rate, wall rate, GUI view, display scaling, and
other active applications fixed except for the GUI state under comparison.
Keep the simulator process held between captures and its placement unchanged
throughout the experiment. Start capture after the same warmup count, collect the same number of
rows, and save only after stopping the trial. Run several alternating trials
in a closed, open, open, closed order to expose drift and repeatability. Record
the report path, GUI state, run order, software revisions, and any dropped or
failed exchange evidence alongside each comparison.

Compare matching phase intervals derived from the timestamp columns, then
compare missed-period counts and the cumulative process counters as context.
Report per-trial distributions and tails as well as medians; do not infer a
cause from one run or from cumulative allocation/GC counters alone. The capture
does not itself prove that GUI connection state caused a timing change. GPU
kernel-level breakdown, driver scheduling, display-server load, physical
camera timing, and target-host qualification remain outside this report.
