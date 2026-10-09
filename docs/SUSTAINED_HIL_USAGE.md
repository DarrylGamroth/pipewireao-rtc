# Bounded sustained HIL qualification

This records the earlier installed complete-frame scientific HIL owner under
RTC-DEV-025/026. The finite default is unchanged. HEART transport is excluded
from this extension; HEART remains unchanged.

The qualification coordinator below was retired with the earlier session
coordinator. Its command is historical and is not runnable from a fresh package.
The new session authority is WirePlumber. Current export/start/control commands
are in [the Julia guide](JULIA_DEPLOYMENT_USAGE.md). Requalification of sustained
measurement through that authority remains a separate gate; these recorded
results do not establish it.

## Export options

The current `REVOLTRTC.jl/bin/export_hil.jl` exporter retains these options:

| Option | Meaning |
| --- | --- |
| `--frames 256` | Retained contiguous ADC/command prefix and timing warmup; 1–256 |
| `--total-exchanges 8192` | Actual continuously adopted exchanges; prefix count through 65,536 |
| `--wall-rate unpaced` | Completion-driven exchange capacity; no wall schedule |
| `--wall-rate 100` | Explicit wall pacing in Hz, no faster than the declared model rate |
| `--rate-hz 500` | Model period, 2 ms; separate from achieved wall cadence |
| `--correction-diagnostics` | Prefix truth and bounded sparse late truth; exclude these runs from clean capacity measurements |

A distinct wall rate requires more exchanges than retained frames. The model
exposure must fit the model period. Changing wall pacing does not change model
chronology, detector exposure, matrices, gains or actuator coordinates. Choose
wall pacing from measurements of the exact installed plant/backend. Overruns
advance to a future wall deadline without skipping model exchanges or emitting
catch-up bursts.

Retain the usual export arguments for the accepted operational calibration,
AOS/plant, adapter and dependency sources. The installed package must resolve its
own dependencies before admission. Preparation and reset happen while held;
release follows inspected thread placement and RTC Running acknowledgement.
The normal foreground and systemd user-service paths use the same source owner.

## Historical run through the retired deployment coordinator

The earlier package contained the development qualification coordinator:

```bash
OPENBLAS_NUM_THREADS=1 JULIA_NUM_THREADS=1,0 taskset -c 2-15 \
  julia --startup-file=no --project=/path/to/package/julia \
  /path/to/package/julia/assets/deployment/qualify_sustained.jl \
  /path/to/package /tmp/fresh-rtc-runtime /path/to/fresh-evidence
```

Add `lifecycle` to perform two runs with midrun pause/resume, stopped reset,
restart and exact retained-payload/sparse-truth comparison. Use enough exchanges
that the first run remains active beyond the coordinator's first 12 periodic
samples. Timing with that intentional pause is not capacity evidence.

Add `reset` instead to perform two uninterrupted runs separated by a completed
stop, reset and restart. Each run must independently pass the same zero-allocation
gate, and retained pixels, commands and sparse truth must repeat exactly. Cold
reset and report work occurs between the measured intervals. This mode does not
qualify midrun pause/resume. The inclusive allocation gate remains active in
`lifecycle` mode; allocating interim control/report work is a failed gate.

The coordinator verifies actual total counts and prefix hashes, records effective
placement and library mappings, samples host memory, snapshots owned NVIDIA
memory at admission/completion/reset, and confirms public shutdown and tracked
owned-group cleanup. Paths must be fresh. A failed public shutdown remains a
failed qualification even if fallback cleanup eventually succeeds. Exceptional
cleanup first permits the supervisor's 300-second cleanup allowance, then allows
a separate 300 seconds after interruption before bounded forced termination.
Unconfirmed identities or surviving detached groups remain explicit failures.

Run live GPU cases serially. Stop competing qualification tests before cadence
measurement; record other host load. No CPU0/1 placement or host tuning is part
of this increment. The example CPU set applies to the coordinator; the installed
profile owns the narrower source/RTC/housekeeping placement.

## Reports and measurement scope

CPU simulation uses AOS stream execution. Accelerator simulation uses AOS
captured graph execution, prepared before source admission; capture failure
rejects preparation rather than silently selecting an allocating stream path.
The report identifies the execution policy. CUDA is the selected live target
in this increment; AMDGPU deployment support does not constitute measured HIP
qualification. Captured and stream arithmetic need not be bit-identical; the
qualification records their detector and OPD differences separately.

- `simulator-result.json`, version 1, describes only the retained contiguous
  prefix. Its ADC/command hashes and truth are suitable for the existing finite
  correction analyzer.
- `simulator-result.json.sustained.json`, version 2, reports actual total delivery,
  owner sequence, model/wall period, whole-run scheduler misses, warmup-excluded
  histograms, detector/command statistics, source-process GC counters and optional
  sparse truth. It is not a full-duration pixel recording or finite-analyzer input.
- The coordinator's `.lifecycle.json` binds descriptor/coordinator hashes,
  preserved reports, memory observations, controls and cleanup results.

Every exchange, including the unretained tail, validates sequence, model time,
source/command timing, finite bounded commands and the installed ADC range.
Timing bins are 10 µs wide through 1 s, with explicit overflow and exact observed
min/max. Source publication → adopted command reception excludes plant
simulation. Complete exchange duration includes plant work; source intervals
also expose observer/control/pacing costs. No distribution is a hard worst-case
bound. An unpaced model-period budget comparison is not a scheduler miss count
or maximum isolated RTC throughput.

Source GC measurements cover the simulator process after the retained prefix
and before final serialization. They include optics, transport and any interim
controls/diagnostics. They do not measure FGN/JFG graph callbacks. Host and GPU
boundary memory includes retained allocator/driver pools and does not establish
continuous memory peaks or zero allocation.

The normal warmed simulator frame loop must allocate zero Julia heap bytes.
This includes optics, transport, recording, metrics, pacing and enabled
per-frame diagnostics. Preparation, stopped reset and report serialization
are separate phases. Unchanged control files are consumed before their ACK;
quiet polling and active waits use prepared state, yielding with
`GC.safepoint()` rather than creating per-wait timers. Prefix OPD hashing
updates prepared SHA contexts; only the cold report writer creates digest
strings. Segment tests supplement whole-process measurements; zero graph or
metrics bytes alone do not qualify the simulator. Operator control processing
is reported separately and is not silently removed from process counters.

## Saved-frame graph checks

`hil/check_graph_replay.jl` runs the installed public ordinary JFG graph on a
completed saved ADC prefix, carries controller clipping feedback chronologically,
compares recorded commands, and separately measures warmed public `process!`
allocations. It exposes requested-minus-demanded and physical/controller feedback.
It validates bound package/calibration hashes and controller configuration first.
Copper inverses with different bytes require the explicit
`--allow-reconstructor-difference` characterization flag; the report records their
difference rather than asserting byte identity or introducing an acceptance
threshold.

For a deliberately clipped diagnostic cohort, `--clipping-feedback-control`
also replays the same saved pixels with controller feedback held at zero. The
flag requires nonzero normal feedback and a changed command trajectory, so
agreement of saturated outputs alone cannot pass this control. It records the
counterfactual separately; it does not simulate a new closed-loop plant outcome.

These are offline analyses: they operate on saved data, outside the live loop.
They complement live delivery and correction evidence. They do not qualify
foreign callbacks, pacing, transport delivery or unrecorded plant trajectories.

See the [plan](SUSTAINED_HIL_PLAN.md), [independent review](SUSTAINED_HIL_REVIEW.md)
and the [sealed evidence ledger](SUSTAINED_HIL_EVIDENCE.json) for completed
continuous, stopped-reset, paced, clipping and released-package observations.
Midrun control/report processing remains outside the qualified zero-allocation
guarantee; `lifecycle` mode keeps that failed gate visible.

The historical [finite calibration validation](CALIBRATION_COMPLETION_VALIDATION.md)
refers to older raw telemetry. Large historical `.tel` files now live in that
campaign's `historical-telemetry-archive-20261005/` as lossless zstd blobs.
Its `manifest.json` and `restore.py` reproduce the original relative paths and
verify contents; restore the required cohort before running its original
verifiers. Calibration arrays, reports and current sustained recordings were
not removed.
