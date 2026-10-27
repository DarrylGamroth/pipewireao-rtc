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
complete cleanup, and removed unit files after native Quit. At 11:45:43 the
old systemd unit was inactive/dead with `Result=success`. The GUI status-row
notice fix is source commit `d24020a0ab52b728018c1e538ce384df23d59f28`, validated
with fixed workspace-position checks at widths 1000, 240 and 80, with no notice,
multiline notices, concurrent notices and clearing. Full text remains available
on hover; the installed GUI binary includes this change. This does not establish
the cause of an earlier ndarray Format rejection. The GUI repository retains the
user's unrelated dirty `docs/workstation-review.md`; it is outside this RTC
change.

## GUI parameter-update no-op, shape retention, and final managed cohort

A 1 nm defocus update through the GUI reproduced a no-op on managed session
`4fe8a61f-63a2-4d6c-a3cc-b49c625ad3a6`: `session.lua:50` attempted to call
missing `owner.node_params`, and RTC returned nil. RTC now uses the existing
`named_properties` query path (source `3add4f1`). The fix is released as RTC
0.2.22, source `fe989e6`, tree `ff26bd7751ddc89365cfbfabab226ab158ae769a`; LocalRegistry publication is recorded
at `4c1d0cb`. Eight native dispatch cases cover the action path, and all 12
focused tests pass. The same nil-action failure is reproduced before the fix.

GUI source commit `11c4f90` retains last-verified immutable instrument geometry
only when it belongs to the exact connected session identity. A failed request
still requires fresh status. Before the fix, the request failure reduced the
MCP observer set from 82 entries to 77. After the fix, the same failure retained
all 82 entries, including three images and pyramid flux. Source fail-before /
pass-after checks and an independent review passed. GUI verification reports
815 library, 200 bridge, 307 main, and 12 integration checks passing, with 31
ignored; Julia checks report 151 passing. The inspection view is at
`http://127.0.0.1:5719`. The retained-geometry screenshot is
`gui-shape-retention-pass.png` in the cache directory above.

The final RTC 0.2.22 CUDA session is Running at
`pipewireao-session@ba48b104e647.service`, session
`9daa80ef-2664-4f6f-8613-2b8e002d4b27` (invocation
`0372f99025a04732ada7e10983b04ab5`). Its read-only observer retained **956
exact raw/flux Header-sequence and PTS pairs, with 0 mismatches**. The GUI fix is
active on this cohort (invocation `0fd65f983486473283dc615d0e412a8a`). GUI
Defocus 1 nm was submitted and acknowledged; readback was RMS `3.954e-10 m`,
minimum `-1e-9 m`, maximum `5.957e-10 m`. Restore to zero was acknowledged.
Fourier X=1, Y=0, phase=0, amplitude=1 nm was submitted and the current offset
matched the owner; readback was RMS `7.828e-10 m`, with extrema ±`1.326e-9 m`.
Restore to zero was acknowledged. These are native simulated operator
observations, not hardware qualification.

The GUI's explicit Restore Reference → Held → Allow close → Close sequence
completed. The final snapshot records Closed, zero offset, all 82 connected
nodes and the retained readouts; see `gui-final-running-closed.json` and
`gui-final-running-closed.png`. The corresponding receipts are
`flux-shape-observation.json`, `gui-shape-fixed-completed.json`, and
`gui-fourier-fixed-completed.json` in the cache directory above.

Two unsuccessful shutdown/recovery exercises remain explicit. First, the
intermediate RTC 0.2.20 cohort (`pipewireao-session@0b3c12c43701.service`)
failed its normal managed shutdown: the RTC 0.2.22 native Quit helper refused
before sending because fresh-status verification failed, so there is no
shutdown-attempt receipt. An exact-incarnation `R.stop!` was then used; all old
owners/core were gone and cleanup completed, but the launch phase ended failed
with service result `exit-code`. The journal recorded “Session control
publication failed” at 12:16:04 and the old unit stopped at 12:16:49. The
shutdown receipt is `replaced-analysis-session-shutdown.json`; logs are
`gpi2-shape-retire-analysis-session.log` and
`gpi2-shape-stop-analysis-unit.log`. This differs from the earlier
`pipewireao-session@99eb9e383a6b.service`, whose native Quit at 11:45:43
completed with inactive/dead `Result=success` and complete cleanup. No cause is
assigned to the intermediate cohort's exit-code result.

Second, a headless recovery test failed after the release step because of
expected global-token contention while the GUI was polling. It was not a
passing test and was not retried; `recovery-shape-live.json` records only the
pre-release Holding state, and `gpi2-shape-recovery.log` retains the failure.
The source contract uses global monotonically increasing tokens and rejects
competing clients. The successful GUI recovery above is a separate observation
and is not represented as a passing headless test or a normal shutdown result.
