# REVOLT Classic development callback performance

Date: 2026-09-29. Status: measured development result, not a real-time qualification.

## Question and boundary

The experiment compares one complete-frame, nine-node Calculon FGN graph
callback with the maintained direct typed Calculon replay on the same pinned
REVOLT Classic profile and detector inputs. The detector is 352 × 352 U16,
with 188 Shack–Hartmann subapertures and 277 demanded PDM values. Both paths
run one worker lane. Timing covers `spa_fgn_graph_process` or one direct
scientific replay call. Graph construction, fixture copying, parameter
publication, feedback carry, PipeWire scheduling, camera transport, and DM
transport are outside the timed interval. The replay is completion paced;
the capacity figure below is a serialized service estimate, not throughput
under fixed-rate arrivals.

Before timing, each graph process checked seven pinned frames against the
direct implementation at five boundaries: calibrated pixels (bitwise equal),
slopes, reconstructed DM error, unconstrained VDM command, and demanded PDM
command (F32 absolute/scaled-relative tolerance 10⁻⁶). Another 1,024 frames
matched delayed feedback and demanded commands. All five paired runs passed.

## Result

Five alternating-order pairs used 2,000 warmups and 5,000 samples per path
on logical CPU 14 of the Ryzen 7 6800H. The CPU 14/15 physical-core pair
had no observed CPU-saturating competing task; other cores carried background
load. The host used its `powersave` governor and no real-time priority.
Per-frame distributions and the environment manifest are in
[`data/classic-20260929`](data/classic-20260929/manifest.json).

| Metric | Nine-node FGN graph | Direct Calculon replay |
| --- | ---: | ---: |
| Median of five p50 values | 154.219 µs | 140.944 µs |
| p50 range across runs | 153.838–154.590 µs | 140.754–141.785 µs |
| Median of five p90 values | 158.717 µs | 146.495 µs |
| Median of five p99 values | 196.629 µs | 233.026 µs |
| Serialized service estimate, median | 6,391/s | 6,948/s |
| Whole-process user CPU, median | 1.324 s | 1.016 s |
| Whole-process system CPU, median | 0.012 s | 0.008 s |
| Whole-process involuntary switches, median | 7 | 7 |
| Whole-process major faults | 0 | 0 |

The paired graph/direct p50 ratios ranged from 1.0895 to 1.0978; the median
ratio was 1.0940. The qualification script's 10% within-path p50 dispersion
gate passed. The graph costs about 13.3 µs more at this callback boundary on
this host. The p99 ordering reverses across some runs and does not establish
a tail-latency advantage for either path. Whole-process CPU and scheduler
counters include setup, numerical checks, and teardown, so they are not
per-callback accounting. An initial CPU 8 run had 20–32% p50 dispersion while
another process saturated its SMT sibling, CPU 9; its raw data remains in the
local experiment cache and was excluded from the stable comparison, not from
the investigation.

`perf record -g --call-graph dwarf -F 997` on CPU 14 sampled 50,000 warmed
graph callbacks without lost samples. About 71.8% of exclusive sampled cycles
fell in image-view Shack–Hartmann centroid processing, 10.2% in pixel
calibration, and 3.9% in the AVX2 dense operation. The direct replay likewise
spent 70.2% in centroid processing, 10.5% in its `process_frame` symbol,
5.6% in AVX2 dot product, and 4.3% in region extraction. These samples show
scientific image work dominates both paths. They do not isolate the 13.3 µs
gap to graph dispatch: the graph processes borrowed image views while the
direct replay materializes a region-major slab.

Two separate heaptrack runs per path used identical 2,000-frame warmup and
either 1 or 5,001 measured frames. The graph reported 1,315 versus 1,316
process allocations; the direct replay reported 735 in both runs. Thus no
allocation count grew with the 5,000 added callbacks. This differential
check includes setup and CSV output and is not a full live-PipeWire
allocation proof.

The 154 µs graph callback is practical for continued development of this
10 Hz simulated Classic profile. No result here establishes camera-to-DM
latency, detector-readout overlap, a sustainable offered frame rate, or a
correction-critical deadline. The existing live Classic harness measures a
different completion-paced end-to-end boundary; keep those results separate.

## Warmup-instrumented replication

A second five-pair run on 2026-09-29 used the same CPU, profile, 2,000 warmups,
5,000 measured calls, and alternating order. The graph and direct replay now
measure warmup wall and process-CPU time around their warmup loops, separately
from the steady-state callback samples. The new source revisions are PipeWire
`1045d32`, plugins `e4c2319`, and Calculon `f2ca4ac`. The complete second
manifest and ten raw distributions are in
[`data/classic-warmup-20260929`](data/classic-warmup-20260929/manifest.json).

| Median across five runs | Nine-node FGN graph | Direct Calculon replay |
| --- | ---: | ---: |
| Warmup wall time, 2,000 frames | 325.554 ms | 291.030 ms |
| Warmup process CPU time, 2,000 frames | 325.540 ms | 290.982 ms |
| Steady p50, 5,000 frames | 155.993 µs | 144.070 µs |
| Steady p50 range | 155.461–156.434 µs | 143.729–145.342 µs |
| Steady p99 median | 189.235 µs | 163.636 µs |
| Serialized service estimate, median | 6,367/s | 6,895/s |

The paired p50 ratio median was 1.0816, ranging from 1.0742 to 1.0858;
both within-path p50 spreads passed the 10% gate. The two experiments agree
that the graph callback costs about 8–10% more than direct replay at this
boundary. Warmup time includes frame preparation and feedback carry; the
steady samples time only the processing call. Neither measures first use or
package/load startup. The clock calls added around warmup do not occur in
the timed per-frame processing loop.

## Reproduction

The measured revisions were Calculon `36d9eca` plus the qualification-driver
diff subsequently committed as `2665b7a`, plugins `d376a43`, and PipeWire
`7de647d`. The manifest records the base revision and diff hash, host topology,
compiler versions, commands, counters, and all ten raw 5,000-sample CSV
filenames. The plugins checkout contained unrelated untracked PDFs; its
tracked source was clean. The qualification script is at
`calculon-algorithms/scripts/qualify_fgn_revolt_classic.py` in the sibling
repository. From that repository, with the sibling checkouts at the revisions
above:

```sh
python3 scripts/qualify_fgn_revolt_classic.py \
  --artifact-root /home/dgamroth/workspaces/codex/heart/revolt-rtc \
  --fgn-root /home/dgamroth/workspaces/codex/pipewire/pipewire \
  --fgn-build /home/dgamroth/workspaces/codex/pipewire/pipewire/build \
  --pipewire-pkgconfig-build /home/dgamroth/workspaces/codex/pipewire/pipewire/build \
  --plugins-root /home/dgamroth/workspaces/codex/pipewire/plugins \
  --profile /home/dgamroth/workspaces/codex/pipewire/plugins/profiles/revolt-classic.toml \
  --output /tmp/classic-development-performance \
  --samples 5000 --warmup 2000 --repetitions 5 --cpu 14
```

The source artifact path, selected host ABI (7), resolved graph, and fixture
files must be present. The script validates the source profile before
collecting samples and writes each run's distribution and environment into
its output directory. Repeating on a different host requires reporting a new
result; the figures above are not a target threshold.
