# Ordinary systemd services for session startup

Under RTC-ARCH-026 the headless RTC owns admission, application Links and
source release. Systemd owns process lifetime.

## Startup

Installation validates the deployment, topology, Julia environment and selected
executable. It writes `systemd/session-activation.json` and binds its SHA-256
digest into the generated session unit. The document records the installed
paths, validated profile and file identities, including the calibration and
application manifests. Reinstall after changing these inputs.

Systemd starts the installed MediaSession as its main process. The process
checks the document digest, installed file identities, its exact command
line and systemd invocation. It uses the new invocation to bind the private
socket, owner identities and control endpoints. Existing deployments continue
to run the service template shipped with their pinned RTC. If a profile
declares a session-only environment setting that differs from the manager
environment, the RTC applies it after starting the owners and re-executes the
pinned command under the same PID. This preserves settings that Julia reads
at process entry and keeps them private to the session.

For a managed source, MediaSession starts the private core, confirms its
socket and retains its identity. It starts the remaining held owners through
one systemd target. HEART profiles require the actual HEART owner PID in the
source command, so MediaSession starts and retains that owner first. The
target has `Wants` and `After` with no stop propagation. For independent
providers MediaSession attaches to the declared running services. It checks
each unit, PID, invocation, start time and cgroup before generating the
session configuration with those identities.

The installed RTC service uses `Type=notify`. Its main process owns admission
for every instrument. Once the required PipeWire Links have negotiated and the
graphs have acknowledged Hold, MediaSession opens a separate native connection
to its own public control endpoint. It matches the session UUID, node, PID,
control instance and PipeWire object incarnation to the prepared invocation.
A fresh Status request from that connection checks the held graph. Each managed
source must acknowledge that it is held. An independent provider keeps
publishing while its RTC graph is held.

MediaSession verifies the current systemd invocation, process arguments, owner
identities and CPU placement before it publishes the discovery record and
signals Ready to systemd. A missing Link, placement mismatch, expired deadline
or lost owner prevents successful startup. The installed service has no
post-start admission process. Direct private-core sessions may still use the
native inspection and admission commands.

## Keep controller graph services running across an RTC restart

Set the three [independent core and source bindings](HIL_CONFIGURATION.md#attach-an-rtc-to-an-already-publishing-source) in the installer environment
and pass `--persistent-graph-owners` when installing the RTC. The installer
writes a service named `pipewireao-graph-<application>-<role>.service` for each
selected graph alongside the session template. Link the generated graph unit
files into the same user manager as the session. With `app` set to the absolute
installation path, run the following before starting the RTC.

```sh
systemctl --user link "$app"/systemd/pipewireao-graph-*.service
systemctl --user daemon-reload
```

Start the independent core and publishing source. Starting the RTC pulls in any
stopped graph units. You can also start those units ahead of the RTC to load
their calibration before the first session. Every RTC activation checks the
loaded unit and process identity, installed inputs, actual placement and fresh
native endpoints. A changed installation requires a matching graph service
deployment and fresh admission.

Stopping the RTC or sending it native Quit withdraws that session's Links and
releases its graph attachments. The graph services stay active and prepare
fresh held attachments with correction open. To take the entire instrument
offline, stop the RTC first, then stop the graph units explicitly and stop the
independent source and core under their respective service owners.

This option currently supports ordinary complete-frame CPU graph services with
session run control. Graphs with correction require live priming. Composition,
row-block processing, accelerator capture, an offset receiver and recovery
owners require their existing deployment mode. The [bootstrap contract](OWNER_BOOTSTRAP_DESIGN.md#graph-service-lifetime-across-rtc-sessions)
defines the observable behaviour for another implementation.

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

The session HSM coordinates required owner shutdown. Invocation cleanup revokes
the required core and sources before stopping optional analysis. An optional
observer can finish shutdown independently of the native Quit acknowledgement.

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
