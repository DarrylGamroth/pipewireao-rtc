# MediaSession cooperative idle benchmark

The trial exercises the real `MediaSession.serve!` loop with the locked
PipeWireAO Julia binding and its native daemon. Each arm starts fresh Julia
processes and a test-owned daemon on a private Unix socket. The fixture omits
the declared source intentionally. All measured status and groups requests
run in settled `Fault`, with zero groups and no running graph, while the
native control endpoint remains live.

## Run

From the candidate worktree, set `baseline` to a checkout of
`9eaf00978e89544270670e54651ecdcf8b4002b3`. Instantiate both locked projects
before measurement. The recorded host used Julia 1.13.4, OpenBLAS with one
thread, the client and daemon on CPU 4, and the session on CPU 14. Select two
different physical cores when reproducing on another host. The recorded host
was Debian 13 with Linux 6.12.117+deb13-amd64, one AMD Ryzen 7 6800H socket,
eight physical cores, two SMT threads per core, and one NUMA node. Both pinned
CPUs used the Linux `powersave` governor. The daemon, Julia client and their
helper threads inherited CPU 4. The session's threads inherited CPU 14.

```sh
candidate=$PWD
baseline=/path/to/baseline
evidence="$candidate/docs/validation/session-agent-idle-20261122"
scratch=$(mktemp -d)

cmp "$baseline/Manifest.toml" "$candidate/Manifest.toml"

run_arm() {
    project=$1
    label=$2
    env OPENBLAS_NUM_THREADS=1 taskset -c 4 julia --threads=1,0 --gcthreads=1,0 \
        --startup-file=no --project="$project" "$evidence/benchmark.jl" \
        "$label" 14 "$scratch/$label.tsv" 512
    gzip -n "$scratch/$label.tsv"
}

run_arm "$baseline" baseline-1
run_arm "$candidate" candidate-1
run_arm "$candidate" candidate-2
run_arm "$baseline" baseline-2
run_arm "$baseline" baseline-3
run_arm "$candidate" candidate-3
```

Each child enables the public launcher's SIGINT handling. The measured
session is the second session in its process. The first
runs the same real missing-source startup expiration and the normal cleanup
sequence. The client warms both request paths with a 30 s deadline per
request. The measurement uses a 2 s deadline. An initial baseline smoke hit
the 2 s deadline during cold groups warm-up, before the idle and request
measurements. The aborted arm is excluded. One arm
uses one client and one outstanding control request at a time.

## Measurements

- **Startup expiry.** The second session receives a real producer-monotonic
  startup budget of 3.5 s and waits for the missing source with no connected
  benchmark client. An Hsm transition hook records the owner's cached
  duty-cycle sample and the wall timestamp at transition completion from
  `CapturingSources` to `HoldingFaultSources`. It records `HeldFault`
  separately, after compensation. The reported differences from the original
  startup deadline describe the session owner. The settlement delta includes
  compensation, and the cached sample describes the owner's expiry turn.
- **Warm idle.** The client stays connected and issues zero requests over 5 s.
  Differenced Linux per-thread `schedstat` records provide scheduler CPU
  runtime and timeslices. Per-thread `status` records provide voluntary and
  involuntary context switches. Sum the threads for session process CPU.
  Context-switch and timeslice rates are scheduling observations.
- **Light traffic.** Schedule 512 alternating status and groups requests
  at 10 ms intervals. Retain every target timestamp, invocation timestamp,
  acknowledgement timestamp and reply token. A delayed invocation still
  counts toward its original target. The benchmark validates typed, correlated
  observed replies and the expected fixture state.
- **Bursts.** Send 32 bursts of 32 alternating requests. Each burst starts
  after a 20 ms quiet gap following the previous one. The first request of the
  first burst starts immediately. Requests within a burst run back-to-back
  at concurrency one, so offered rate depends on completion. The per-request
  interval includes client encoding, native submission, session processing,
  native reply delivery and typed return to the client. It starts at
  invocation in either workload. For light traffic, target to invocation
  also quantifies lateness introduced by the generator and previous calls.
- **Shutdown.** Send SIGINT while a status operation has a pending native
  submission. Record whether the client gets the reply before retirement
  and require a successful process exit. The elapsed interval includes the
  parent observing the child exit and its polling resolution.

## Raw records

The six gzip-compressed, tab-separated traces have the same row schema.
Rows with a shared first field appear in every trial.

| First field | Remaining fields |
| --- | --- |
| `trial` | Label, Julia version, kernel family, architecture, default Julia threads, GC threads, client PID, session CPU, start ns |
| `meta` | Key and value |
| `expiry` | Original startup deadline, owner cached sample, fault transition complete, settled fault transition complete (all ns), overdue phase |
| `idle` | Client monotonic observation duration ns, session thread count |
| `idle_thread` | Owner or helper marker, Linux thread ID, CPU runtime ns, timeslices, voluntary switches, involuntary switches |
| `request` | Phase, command, burst index, position, target ns, invocation ns, acknowledgement ns, reply token |
| `shutdown` | Signal sent ns, child exit observed ns, request disposition, exit code, terminating signal |

These trials cover package control traffic and software cleanup on one shared
Linux host. They use processor affinity without CPU isolation. They contain
no optical workloads, data-plane latency, hardware timing or target-host
qualification. Each arm supplies three startup and shutdown observations,
so those rows support a range of observed times.
