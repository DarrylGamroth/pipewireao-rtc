# GPI2 optional pupil-flux and operator validation — 2026-10-27

This record covers the registered analysis and GUI integration, read-only live
observations, an optional-analysis fault-isolation run, a private-model clipping
measurement, and scoped protective recovery on both pre-replacement and managed
replacement sessions. The managed replacement is Running and validated, and the
older session has since been retired successfully through native Quit.
Machine-side receipts
referenced below are in `/home/dgamroth/.cache/pipewireao/gpi2-operator-20261027/`.

## Registered package closure

The fresh registered analysis environment resolves these package versions and
Julia package tree hashes:

| Package | Version | Tree hash |
| --- | --- | --- |
| FilterGraphAlgorithms | 0.8.3 | `14a81c98ef95a41a14a6b035b6e357787493de66` |
| FilterGraphPipeWire | 0.1.10 | `9a09801926d61ed4b7016718164ef153cfc25efc` |
| PipeWireAORTC | 0.2.20 | `63c76c3a5f46d588c3a9eb00a03fe7cd6a51770c` |

These are the `git-tree-sha1` values in the resolved registered manifest at
`/home/dgamroth/.cache/pipewireao/gpi2-operator-20261027/registered-analysis-environment/Manifest.toml`.
The FGA 0.8.3 schema publishes the four-channel pupil-flux shape and channel
metadata; FGPW 0.1.10 accepts and emits those channels; RTC 0.2.20 permits a
single-input optional analysis graph while retaining synchronized matching for
multi-input analysis graphs.

## Healthy exact-pair observations

A read-only observer sampled the earlier GPI2 session for about 21.7 seconds. It
compared each optional flux vector against independently summed raw detector
regions for the same source Header sequence and PTS. **954 retained pairs
matched exactly; 0 mismatches.** The earlier session evidence is retained to
show that the path worked before the replacement as well. The raw source was
UInt16, shape 242 × 240; flux was Float64, shape 4, in ADC counts; the declared source rate was
2,000 Hz. The observer's drive interval was 20 ms and its bounded capacity-one
queues dropped older observations, so this establishes the exact association
and calculation for retained pairs, not source throughput, end-to-end latency,
or deadline performance. The detector and four 60 × 60 pupil regions came from
the instrument geometry declaration.

Evidence: `flux-healthy-observation.json` in the cache directory above. The
observation records zero mismatches and includes retained per-sequence source
sums and flux values.

The managed replacement session was then sampled for about 21.3 seconds. Its
observer retained **905 exact raw/flux Header-sequence and PTS pairs, with 0
mismatches**. The new RTC systemd unit is
`pipewireao-session@0b3c12c43701.service` (invocation
`2c823dd47e674c69b7e64df49376bd4b`); it is Running. The managed analysis process
(PID 2049730, invocation `97a200ad515e471a8ba4a4085e1d6410`) reported READY with
2 links. The replacement recovery observation also passed, reaching Closed after
Held. The status-row GUI fix was relaunched with the installed replacement
configuration (invocation `a0f5bfca6a2e469880e6aac489cffdeb`) and is active
on the replacement session (PID 2052016).

Evidence: `flux-managed-observation.json` and `recovery-complete-live.json` in
the cache directory above. The managed observer is also read-only, uses 20 ms
drive intervals and bounded capacity-one queues, and does not establish source
throughput, end-to-end latency, or deadline performance.

## Optional-analysis fault isolation

In a separate 40-second read-only observation, the optional pupil-flux service
was sent STOP, CONT, and KILL. During STOP, flux sequence 148740 held while raw
and control continued advancing. CONT resumed flux publication. After KILL,
flux remained at sequence 149728, while raw advanced from sequence 149729 to
151508 and control from 149729 to 151507. Across the run, **626 retained raw /
flux pairs matched exactly; 0 mismatches**. This demonstrates observed control
and raw-stream progress through the injected optional-process stall and failure;
it does not prove recovery of the killed analysis process or a bound on response
time.

Evidence: `flux-isolation-observation.json` contains the 41 per-second observer
snapshots and pair comparisons; `flux-isolation-signals.tsv` records STOP,
CONT, and KILL against the optional service PID. Both are in the cache directory
above. Receipt timestamps are observer CLOCK_MONOTONIC times, not source
latency measurements.

## Private-model clipping measurement

The 1,024-frame noisy CUDA run did not complete its test harness: its saved
status is an error, so it is not used as validation. A separate 1,024-frame
CUDA plant / host-controller-output capture passed and records same-step
requested-minus-demanded mirror feedback in metres OPD. Over that capture, tweeter feedback was
nonzero in 1,017 frames (maximum 85 actuators in one frame; peak absolute
feedback 0.232 µm); woofer feedback was zero in all frames. Peak absolute
commands were 1.000 µm for the tweeter, 1.819 µm for the woofer, and 0.500 µm
for tip/tilt. The private model's trailing mean residual ratio was 0.0714.

This is a numerical result for the provisional private-array GPI model and its
configured simulation limits. It is not native RTC evidence, measured hardware
behavior, a clipping-rate qualification, or a deadline result. In particular,
a command peak alone does not identify clipping; the feedback measurement is
the clipping evidence. The supplied report identifies 64 electrons/ADU and
1,024 ADU bias as provisional values, not measured GPI calibration.

Evidence: `clipping-owner-bindings-1024.yaml` contains the passing capture and
per-frame command/feedback measurements. `clipping-1024.yaml` preserves the
separate errored CUDA attempt. Both are in the cache directory above.

## Protective recovery on both live sessions

On the earlier GPI2 live RTC, a scoped recovery observation recorded the
controller Held and the subsequent state Closed, with recovery application
reported successful. The earlier unit was
`pipewireao-session@99eb9e383a6b.service`. A second passing observation on the
managed replacement reached Closed after Held. Both are native simulated
evidence; there is no physical settling qualification.

Evidence: `recovery-live.json` and `recovery-complete-live.json` in the cache
directory above. `previous-session-shutdown.json` records the old unit
`pipewireao-session@99eb9e383a6b.service` stopped, successful service result,
complete cleanup, and removed unit files after native Quit. The GUI status-row
notice fix is source commit `d24020a0ab52b728018c1e538ce384df23d59f28`, validated
with fixed workspace-position checks at widths 1000, 240 and 80, with no notice,
multiline notices, concurrent notices and clearing. Full text remains available
on hover; the installed GUI binary includes this change. This does not establish
the cause of an earlier ndarray Format rejection. The GUI repository retains the
user's unrelated dirty `docs/workstation-review.md`; it is outside this RTC
change.
