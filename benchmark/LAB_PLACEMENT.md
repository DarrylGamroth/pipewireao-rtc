# Laboratory placement launcher

`lab_placement.py` is a companion process-envelope tool for RTC-ARCH-019 and
RTC-DEV-019. The Copper baseline uses its `verify` interface when
`run_copper_baseline.py --verify-placement` is selected. Each runner checks
its live processes before ingress and after replay; the baseline requires
all declared role reports to be verified.

The target process owns its graph, buffers, workers, and scheduling. The
launcher only applies its initial process CPU and scheduler envelope, records
the effective Linux thread state, and controls when ingress can begin.

## Target hooks

Before any measured ingress, the target creates its internal threads, warms
them, writes `--ready-file`, then waits until `--gate-file` exists. The launcher
captures and verifies every thread's CPU affinity and scheduler policy before
creating that gate.

A qualified run also supplies `--qualified --finished-file PATH --release-file
PATH`. After measured ingress ends, the target writes the finished file and
keeps its threads alive without starting teardown. The launcher captures and
verifies the post-run thread map, then creates the release file. The target may
then stop and exit. A missing finish signal, changed placement, or failed
post-run inspection fails the run without creating the release file.

For example, a target needs this lifecycle:

```text
create and warm internal threads
write READY
wait for GATE
run measured ingress
write FINISHED
wait for RELEASE
tear down and exit
```

The default allowed policy for every thread is the launch policy. A mixed
PipeWireAO process can declare each permitted policy, such as
`--allowed-thread-policy other --allowed-thread-policy fifo:20`, and can require
an exact observed count with `--required-thread-policy fifo:20=1`. The launcher
records TIDs, Linux thread names, and observed state. A host-specific profile
may require an exact name together with policy and affinity. The name is a
placement check; the process implementation still defines what work the
named thread performs.

For a process that an existing runner already started, use `verify` instead of
`run`. It takes `--role`, `--pid`, `--cpus`, `--leader-policy`, optional thread
policy rules, and `--output`; it neither launches nor releases the process.
This supports a runner's own pre-ingress or post-replay boundary while the PID
is still alive.

## Strict Copper thread profile

`run_copper_baseline.py --verify-placement --strict-placement-profile
benchmark/profiles/ryzen-6800h-copper.json` passes the profile to each runner's
existing pre-ingress and post-replay `verify` call. The verifier checks each
role's exact process CPU envelope, leader policy, policy counts, placement
counts, and any declared exact thread names. A missing role or a mismatch
returns a failed report before the runner starts its pixel source. The profile
path and SHA-256 are recorded with the run. A new machine or CPU layout needs
its own reviewed profile; changing `--rtc-cpus` alone cannot silently relax
this one.

The Ryzen profile requires a named FIFO83 `rtc-data-loop` pinned to CPU 0 in
the FGN daemon, the named HEART stage workers on their declared cores, and
the JFG `data-loop.0` plus its pinned Julia and control threads. Earlier
broad-envelope replays observed no FIFO thread in the FGN daemon, so those
replays do not meet this profile. The profile also checks the observer and
adapter data-loop names, although their declared affinity masks remain broad.
Thread names establish which configured threads received a placement; they
do not by themselves trace individual algorithm calls. For this Copper
configuration, FGN invokes its Algorithm synchronously on the graph owner
loop, and the JFG PipeWire callback invokes `process!` directly. The selected
JFG configuration has zero progressive CPU workers; no separate Julia MVM
shard task is asserted by this profile.

The [named-thread evidence](data/copper_named_thread_evidence_20260929.json)
reapplies the stronger name, policy, and affinity checks to 128 retained
pre-ingress and post-replay records from eight earlier 1,024-frame RTC runs.
Those runs were gated by the preceding count-only profile; the offline check
does not change their original gate. Two subsequent 16-frame three-way runs,
one row-block and one complete-frame, used the new profile before ingress
and after replay. Both qualified exact WFS and DM delivery and numerical
command equivalence. Their manifests are
`~/.cache/rtc-copper-named-thread-final-row-16-20260929/manifest.json` and
`~/.cache/rtc-copper-named-thread-final-fullframe-16-20260929/manifest.json`.
The evidence record includes both live runs, for 160 checked placement
records in total. This closes the named-thread check for this host profile;
it does not establish an uncontended latency ranking or a general profile
for other machines.

With a strict profile, the Copper launcher also derives the JFG island's
explicit PipeWireAO client-loop CPU and FIFO priority from its named
`data-loop.0` rule. The island receives a private client configuration with
eventfd idle and `mem.mlock-all=false`; the JFG report records its path and
hash. Two gated 16-frame three-way replays verified the resulting CPU 0 /
FIFO83 loop before ingress and after replay. The
[client-loop record](data/copper_client_loop_evidence_20260929.json) retains
the manifests and thread evidence. Other clients still use the installed
generic client configuration in those island-only runs. The later opt-in
[all-loop Copper profile](profiles/ryzen-6800h-copper-all-loops.json) also
configures the FGN and JFG daemons, observers, and adapters explicitly; its
[evidence](data/copper_all_loop_evidence_20260929.json) includes two 16-frame
gated replays and pre/post named thread checks. Three 1,024-frame repetitions
per ingress mode also qualified with the local PipeWireAO.jl GC-safe binding;
the [phase record](data/copper_all_loop_local_binding_phases_20260929.json)
retains their packet-level timing and provenance. These runs still lack
controlled host isolation and do not close RTC-DEV-019.

The resulting JSON includes the requested envelope, command, host, each
pre-gate map, post-run map when the finish/release handshake is used, `VmLck`,
and `/proc/<pid>/smaps_rollup`. It is a laboratory record, not a deadline or
host-qualification claim.
