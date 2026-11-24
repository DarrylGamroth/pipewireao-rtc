# Ordinary systemd services for session startup

Scope: one-shot launcher under RTC-ARCH-026. The headless RTC
owns admission, application links and source release; systemd owns processes.
FGN/JFG algorithms, AOS simulation and native controls are unchanged.

## Startup

The session service executes the native `pipewireao-rtc` application directly. Its finite
`ExecStartPre` helper renders the private configuration and ordinary owner
service files, then starts the private core. After confirming the core socket
and retaining its process identity, it starts the remaining held owners through
one systemd target. This replaces a separate `systemd-run` submission for each
owner. The target has `Wants` and `After`, with no stop propagation.

HEART profiles retain one necessary dependency: the source command contains the
actual HEART owner PID. Start and retain that owner before rendering the source
service. Record all intended unit names before the first start request. Neither
the core nor this staged HEART owner is pulled in by the target, so target start
cannot silently restart either after its identity was retained.

Target activation is not proof that every owner started. Check each loaded unit
definition and actual active PID, invocation, start time and cgroup. Then render
application configuration from those retained identities. Native warmup,
placement inspection and MediaSession admission precede release.

## First live correction

Graph owners connect without executing the offline synthetic qualification
frames. Ready confirms that the graph and required Links are present and held.
Start releases acquisition. A graph configured with correction priming starts
open and waits for an accepted live measurement from the declared camera for
each loop. The operator sends Close after the owner reports primed. An invalid
measurement clears priming for its camera, and Reset clears priming for all of
the owner's cameras.

Managed controller activation supports CPU graphs. Live priming uses
complete-frame CPU graphs and CPU compositions. The optical simulator can use
an accelerator and still supply live exposures to those CPU controllers.
Managed startup rejects captured CUDA and AMDGPU controller graphs before
graph preparation because capture executes a frame on synthetic input. The
direct GPU API remains available for offline qualification and replay.

Classic qualifies a fresh usable measurement according to its calibrated
Shack–Hartmann pipeline. The slopes and validity must belong to the same
acquisition. The slopes must be finite and at least one currently active
subaperture must pass the calibrated validity decision. Only that evidence
permits an operator's explicit Close request. The graph applies the existing
per-lenslet thresholds and retains the existing zero-fill behavior for
invalid slopes.

## Timing a Julia controller startup

Set `PIPEWIREAORTC_GRAPH_STARTUP_TIMING=1` in the session service environment
for the activation being measured. The launcher passes it to each Julia
graph owner. Read that owner's systemd journal for the invocation. Each record
names the graph, so controllers on the same instrument can be timed separately.

| Journal phase | Work measured |
| --- | --- |
| `load FilterGraphPipeWire` | Load the package that runs the scientific graph and connects it to PipeWire. |
| `prepare graph` | Build the declared algorithms, bind their calibrated parameters and prepare the execution graph. |
| `enter prepared graph` | Enter the Julia method specialized for that graph and its runtime options. First-use compilation before its first statement is inside this interval. |
| `configure graph node` | Determine the public ports, metadata, clocks and any correction, supervision or display observers from the declaration. |
| `construct graph node` | Construct the disconnected PipeWire filter, its buffers and callback state for this controller process. |
| `attach graph observers` | Check the correction observer and attach its timers to the owner's control loop, when configured. |
| `warm up graph` | Record that activation skips synthetic qualification. Installation runs the configured checks for supported complete-frame CPU graphs. |

Use wall time to locate a delay. The detailed phases also report CPU time
consumed by all threads in the graph process, Julia's compilation counter
and, on Linux, time the calling thread spent runnable while waiting for a CPU.
These counters overlap. A thread change makes the run-queue interval unavailable.
The graph owner's Prepared message precedes connecting the node and admitting
the session. Measure systemd Ready, the first live detector frame and the first
applied correction separately. The timing hooks run during owner startup.

## Cleanup

An explicit service stop first runs the installed `ExecStop` one-shot client.
It verifies the exact service invocation, main PID/start time, caller cgroup,
and native session UUID, then requests native Quit once. The session HSM
decides whether to accept the command. It coordinates source hold and
outstanding command adoption, graph stop, Link withdrawal and terminal owner
acknowledgements within its five-second effect deadline. ExecStop records
the attempt before submission, uses an eight-second request bound, and
waits for the same RTC process to exit within its 30-second helper budget.
That budget begins after package load. systemd's 300-second watchdog also
bounds compilation, I/O and client close.
A failed, missing or unknown acknowledgement is not retried.

Fresh invocation names are exclusive and services use `Restart=no`. On failure
or exit, cancel all cohort/member start jobs, revoke and prove the private core
and source empty, then stop consumers. Stop the target only after owner
quiescence. Remove only exact invocation-owned runtime unit links and files;
retain the launch ledger and fence cleanup on identity or ownership uncertainty.
An unreadable ledger permits ingress revocation but fences consumer/file removal.

The session HSM coordinates required owner shutdown. Optional analysis units
follow the session unit lifetime through `PartOf` and share invocation cleanup.

## Implementation and validation

1. Add literal argument/environment unit rendering; retire unused transient
   coordinator launch and cleanup functions.
2. Render/install exact invocation fragments, launch core then the owner target,
   and retain loaded definitions and actual owner identities.
3. Extend existing cleanup to cancel target and member jobs and remove owned
   fragments after proven quiescence.
4. Check unit escaping and discovery, actual systemd argument round trips,
   selected Copper FGN/JFG startup/native controls/teardown, and obtain an
   independent review of ordering and uncertainty handling.

These are deployment checks. They do not upgrade previous numerical, timing,
hardware, Classic, row-block or HEART qualification claims. Validation evidence
is recorded separately after execution.
