# SIGTERM diagnostic

A preliminary candidate smoke with Julia 1.13.4 reached the settled fault
and completed its measured status and groups requests. While a status receipt
was pending, the driver sent SIGTERM. Julia printed
`[3860168] signal 15: Terminated`, and the driver failed its
`success(child)` check. The child was in `MediaSession.serve!` with its
own private core. The first harness did not capture the child exit fields.

The preliminary driver ran with `OPENBLAS_NUM_THREADS=1`, CPU 4,
`--threads=1 --gcthreads=1,0 --startup-file=no` and the candidate
project. The child ran on CPU 14 with the default Julia thread settings and
`-C native -J <Julia 1.13.4 sys.so> -g1 --startup-file=no`. The driver
issued 24 light requests and two bursts of 32 requests. This smoke is
excluded from the paired measurements.

A candidate repeat used the final benchmark harness, physical CPU 4 for
the driver and daemon, and CPU 14 for the child. Julia 1.13.4 ran on
`--threads=1,0 --gcthreads=1,0 --startup-file=no`. The child used the
launcher's `Base.exit_on_sigint(false)`. The client acknowledged the pending
status, Julia logged `[3889130] signal 15: Terminated`, and the child
reported exit code field 0 and terminating signal 15. The owner task's
Linux thread blocked SIGTERM in its `SigBlk` mask `0000000000004206`.
One helper's mask was `0000000000000000`. The capture provides process
termination evidence and shows where SIGTERM was unblocked.

Two baseline attempts using the benchmark harness ended before signal
delivery. The first 3.5 s warm-up expired in `CapturingOwners` under high
host load. A repeat extended the untimed warm-up to 15 s, reached
`CapturingSources`, and took the emergency disconnect during warm-up
cleanup. Both attempts are excluded from the signal evidence.

For the matched public launch, run the following Julia selector against each
project using the [paired-trial driver flags](METHOD.md). The selector uses
the existing public session process test and its ordinary interrupt point
after the status and groups acknowledgements. It stages the test launcher
in a temporary directory and uses the launcher's Julia version and flags.
The substitutions select just this test case, pin the child process to CPU 14,
send SIGTERM, and print the child exit fields.

```julia
path = joinpath(dirname(Base.active_project()), "test", "media_session_process.jl")
source = read(path, String)
fixture = repr(joinpath(dirname(path), "control_private_core.jl"))
changes = (
    "include(\"control_private_core.jl\")" => "include($fixture)",
    "termination in (:quit, :interrupt, :publisher_exit)" => "termination in (:interrupt,)",
    "Cmd([joinpath(rtc" => "Cmd([\"taskset\", \"-c\", \"14\", joinpath(rtc",
    "kill(child, Base.SIGINT)" => "kill(child, Base.SIGTERM)",
    "@test success(child)" =>
        "println(\"SIGTERM receipt: exitcode=\", child.exitcode, \" termsignal=\", child.termsignal)\n            @test success(child)",
)
for (before, after) in changes
    @assert occursin(before, source)
    global source = replace(source, before => after; count = 1)
end
include_string(Main, source, path)
```

Both public-launcher probes passed six assertions through the startup and
control requests. Each failed the successful-exit assertion after SIGTERM.

| Revision | Child exit code field | Child terminating signal |
| --- | ---: | ---: |
| Baseline | 0 | 15 |
| Candidate | 0 | 15 |

This outcome reproduces on the baseline. The paired latency trials use
SIGINT, which let all six session children exit successfully.
