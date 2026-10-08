# Copper WFS source gate

Tool provenance: the Python scripts and retired Julia launcher referenced here
were removed from the current checkout on 2026-10-08. Commands describe the
[recorded source revision](https://github.com/DarrylGamroth/pipewireao-rtc/blob/6b893b7e98e474580f53ff913751963b62f8db2a/benchmark/COPPER_GATED_SOURCE.md);
these commands are not runnable in this checkout. Results and design claims
retain their original scope. See the [current benchmark index](README.md) for retained tooling.

The opt-in `--gated-source` baseline uses HEART's existing `wfsSimulator`
`-wfs 1 -sync 1` mode. HEART source and binaries are unchanged. This mode
replaces the simulator's internal frame timer with a separate native pacer;
its latency samples are therefore a distinct source-clock configuration from
the retained timer-driven Copper baseline.

The companion creates HEART's per-user ready and trigger POSIX semaphores
exclusively. The simulator posts ready after its pixel-sending threads and
input preparation exist, then blocks on the trigger semaphore. Before the
first trigger, the wrapper inspects every live thread of the wrapper, pacer,
and simulator and requires the exact declared CPU mask and FIFO priority. It
releases the pacer only after all three snapshots pass. The native pacer
posts one trigger per frame at absolute `CLOCK_MONOTONIC` deadlines:
`release + floor(frame × 10⁹ / 474)` nanoseconds, with frame numbering
starting at 1. It records target and post-return timestamps outside the
frame-processing graph. The trigger timestamp is a close upper bound on the
semaphore post, not the exact wake time of the pixel sender.

The wrapper writes one gate report and one raw trigger CSV per RTC run. The
orchestrator requires all three gate reports, their pre-release thread
snapshots, complete trigger counts, exact WFS/DM packet delivery, and command
vector parity before publishing latency phases. A failed thread inspection
does not release the sender. A 3-frame wrong-CPU check exited with zero UDP
packets, and neither owned semaphore remained. The successful isolated
3-frame replay produced frame IDs 0–2 with sequences 1 and 2 in order.

`qualified` in the gate report establishes source placement and a complete
nominal trigger sequence. Actual trigger lateness and spacing are recorded but
have no acceptance threshold. These runs do not claim a pacing deadline or
uncontended latency ranking. The existing timer-driven and gated source
results must be reported separately. The semaphore names are per user, so
concurrent gate runs fail closed; a `SIGKILL` can leave names behind, which
the pacer deliberately does not unlink on its next start.

The maintained command builds the native pacer from this repository and
retains the source, compiler invocation/version, binary hash, thread reports,
and trigger CSVs in the run output:

```sh
python3 benchmark/run_copper_baseline.py \
  --gated-source --mode row --repeats 1 --frames 1024 \
  --verify-placement --configure-all-loops \
  --strict-placement-profile benchmark/profiles/ryzen-6800h-copper.json \
  --output-dir /path/to/new/gated-row
```

Use `--mode fullframe` with a different output directory for complete-frame
ingress. All three RTCs receive the same FITS cube and nominal trigger
schedule in each mode. The existing packet qualifier still compares every
WFS payload with the FITS source and verifies every Standard-DM packet.

The current profile reserves CPUs 0 and 1, pins the daemon loop to CPU 2, the
JFG island loop to CPU 4, adapter loop to CPU 8, observer to CPU 14, and source
to CPU 12. The retained 2026-09-29 results below used the original CPU0 layout;
their packet and numerical results do not qualify this revised placement.

## Retained 1,024-frame comparison, 2026-09-29

The final row-block and complete-frame manifests are
`~/.cache/rtc-copper-gated-v4-row-1024-20260929/manifest.json` and
`~/.cache/rtc-copper-gated-v4-fullframe-1024-20260929/manifest.json`.
Both used the same 1,024-frame FITS cube, 474 Hz nominal trigger rate,
2,000 µs readout, clipping feedback, strict Ryzen thread profile, and final
wrapper and pacer hashes. HEART, FGN, and JFG each captured all 2,048 WFS
packets and emitted all 1,024 ordered Standard-DM commands in each mode.
The largest HEART↔JFG command-vector difference was 4.563 × 10⁻⁸ µm;
FGN↔JFG was 2.980 × 10⁻⁸ µm. Every source, pacer, and wrapper thread
inspected before release had the requested CPU 12 / FIFO20 placement. The
[packet-level record](data/copper_gated_phases_20260929.json) requalifies
the retained WFS and DM captures and hashes them.

| Ingress | RTC | First WFS packet → DM p50 | Terminal WFS packet → DM p50 | Terminal WFS packet → DM p99 | Maximum trigger lateness |
| --- | --- | ---: | ---: | ---: | ---: |
| Row blocks | HEART | 1,134 µs | 137 µs | 213 µs | 144 µs |
| Row blocks | FGN | 1,128 µs | 131 µs | 208 µs | 121 µs |
| Row blocks | JFG | 1,128 µs | 129 µs | 207 µs | 88 µs |
| Complete frame | HEART | 1,248 µs | 250 µs | 396 µs | 103 µs |
| Complete frame | FGN | 1,152 µs | 154 µs | 184 µs | 128 µs |
| Complete frame | JFG | 1,147 µs | 149 µs | 355 µs | 147 µs |

These are one qualified run per mode, not independent latency repetitions.
Six unrelated CPU-saturating Julia analysis processes were observed during
the series, and HEART→FGN→JFG run order was fixed. The shorter row-block
first-packet interval is consistent with work occurring during readout; it
does not isolate the responsible operation or establish an uncontended RTC
ranking. The gate timestamps its semaphore posts, not camera exposure or
physical DM actuation. The source clock also differs from the retained
timer-driven series.

An earlier complete-frame attempt failed before FGN pixel ingress while its
Standard-DM adapter waited for `PREPARED`; no FGN WFS packets were sent. Its
unqualified record remains at
`~/.cache/rtc-copper-gated-rational-fullframe-1024-20260929/manifest.json`.
The subsequent complete-frame replay and the final pair qualified. The
startup failure's cause has not been established.
