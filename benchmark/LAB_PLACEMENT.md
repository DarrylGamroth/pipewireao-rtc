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
records TIDs and observed state but does not assign names or roles to threads.

For a process that an existing runner already started, use `verify` instead of
`run`. It takes `--role`, `--pid`, `--cpus`, `--leader-policy`, optional thread
policy rules, and `--output`; it neither launches nor releases the process.
This supports a runner's own pre-ingress or post-replay boundary while the PID
is still alive.

The resulting JSON includes the requested envelope, command, host, each
pre-gate map, post-run map when the finish/release handshake is used, `VmLck`,
and `/proc/<pid>/smaps_rollup`. It is a laboratory record, not a deadline or
host-qualification claim.
