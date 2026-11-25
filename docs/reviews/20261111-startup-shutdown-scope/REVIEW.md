# RTC startup, optional analysis, and shutdown scope review

Reviewed RTC main at `91a36d2` on 2026-11-11. This is a source review.
The timings below come from the existing private-core runs.

[RTC-ARCH-026](../../architecture.md) assigns admission, application Links,
and session lifecycle to MediaSession. systemd owns process lifetime.
AdaptiveOpticsSimPipeWireHIL owns simulated execution, and
FilterGraphPipeWire owns graph execution. [RTC-DEV-019 through RTC-DEV-023
and RTC-DEV-030](../../operations.md) specify placement, admission, bounded
controls, deployment and native replies.

## Findings

### SCOPE-01 — Move optical startup image policy to HIL

**Confirmed ownership mismatch.** [OpticalStartup](../../../src/deployment/optical_startup.jl)
recognizes the HIL launcher by its command line, reads HIL's backend and
configuration version, generates a workload package, and rewrites the
launch command and depot environment to load that image before RTC. This
is an entire RTC module implementing a HIL optimization. Its current
selector covers CPU optical configurations 4 and 6. Classic and GPI2 use
lockstep configuration 3, so this path does not address their cold startup.

Move workload selection, construction, and early image loading together
to HIL. RTC installation can invoke the package's supported preparation
entry point for the declared HIL owner and launch its public entry point.
Retire the RTC module once HIL exposes both pieces and the matching
release is installed. Preserve the verified Project and Manifest, early
image import order, explicit prefix, and startup without an image.
Validate fresh install, relocation, and private-core CAL2 and SPIDERS
startup and Quit against the [existing CPU evidence](../../validation/optical-startup-20261111/README.md).

### SCOPE-02 — Consolidate optional analysis service ownership

**Confirmed duplicate lifecycle.** [SessionRuntime.start!](../../../src/deployment/session_runtime.jl)
starts optional analysis after admission. Direct systemd start omits this
step. [Analysis](../../../src/analysis/Analysis.jl) creates its own lock,
unit fragments, and `analysis.json` receipt. The
[invocation cleanup](../../../src/deployment/session_launch.jl) excludes
these roles from its required-owner sweep and calls a separate analysis
cleanup path. The [Classic browser run](../../validation/live-flux-labels-20261111/README.md)
reached Ready before the test launched optional analysis. An initial
analysis launch expired and left an incomplete receipt and directory.

Use the existing deployment unit machinery and one invocation record for
both kinds of service. Keep optional launch after Ready, with optional
failure isolated from admission and required owners. A single deployment
entry point should start the requested services regardless of which client
initiated the deployment. Once registration and cleanup share the same
invocation boundary, retire Analysis's deployment lock, separate receipt
and cleanup sweep together. Keep exact fragment, job and process identity
checks through the stop/start race. Validate direct systemd and wrapper
launch, optional success and timeout, Quit during optional startup, and
failed-start cleanup on a private core.

### SCOPE-03 — Reuse the graph application for optional analysis execution

**Partial transfer.** The [analysis extension](../../../ext/analysis.jl)
already delegates graph preparation to `prepare_service_graph`. It still
constructs the PipeWire Node and manages connection, run and teardown.
FilterGraphPipeWire 0.5.5 has a standalone application with a prepared
service run path. Use that application where its public contract covers
the same work. The RTC extension also verifies endpoint incarnation and
manages analysis Links and observation queues. Establish how those are
declared and withdrawn before deleting the extension's connection path.
The graph process can own execution while the session retains policy over
its application Links. Keep channel units and scientific declarations
with their existing owners. Validate Classic and GPI2 analysis streams,
including client detach, owner exit, and removal of only analysis-owned
resources. The source comparison establishes a runner overlap. It does
not establish that the full extension can be removed today.

### SCOPE-04 — Send Quit without a separate science Status round trip

**Confirmed extra dependency.** [ExecStop](../../../src/deployment/session_cli.jl)
authenticates the exact process and session, then requires a successful
fresh Ready or Running Status before submitting Quit. The
[session HSM](../../../src/media_session/machine.jl) sends a source query
for admitted Status. It already decides whether a Quit can start and
rejects a second Quit during shutdown. Configuration cancellation has
its own admission-controller removal event.

Remove the pre-Quit Status request and its validator once the stop path
can verify endpoint identity without that request. Keep the exact
invocation and UUID fences, finite deadline, one-shot submission,
correlated Offline receipt, and emergency cleanup when the outcome is
unknown. Test with a delayed Status and responsive Quit, a stalled Quit,
and Quit during configuration or fault. Confirm the same request cannot
be replayed and that graph retirement precedes Link withdrawal. The
extra round trip can block submission by construction. This review did
not reproduce a specific incident with that cause.

### SCOPE-05 — Retire the parallel host shutdown path

**Confirmed overlap with live callers.** [SessionRuntime.shutdown!](../../../src/deployment/session_runtime.jl)
submits native Quit directly, persists a separate attempt record, and
reconciles cleanup. The same module's `stop!` uses systemd, whose ExecStop
also submits Quit and writes its own receipt. Classic and managed
integration selectors exercise the direct helper. Native Quit remains a
published operation for GUI and other direct protocol clients.

Use the existing systemd stop path for host-managed shutdown and exercise
native Quit separately as a protocol operation. Migrate deployed helper
callers and reconcile their evidence before retiring the parallel helper
and its attempt record. Keep ExecStopPost for partial launches, dead main
processes, and orphan jobs. Failed-start compensation also covers failures
before an invocation record exists, so it cannot be removed with the
parallel Quit helper. Verify both native and systemd Quit, unknown-outcome
reconciliation, and partial startup cleanup against the exact invocation.

## Keep a warm session for iteration

For GUI and repeated control tests, reuse one admitted private-core
deployment. Close and reopen the GUI or attach with
[SessionRuntime.attach](../../../src/deployment/session_runtime.jl).
Send `session-stop` to hold sources and stop graphs while keeping the
processes and Links. Send `session-start` to resume. Verify the needed
initial state when a test depends on it. Use a supported Reset or a fresh
run when retained state would change the test.

The [live GUI evidence](../../validation/live-flux-labels-20261111/README.md)
records 504.81 s to Classic Ready and 375.93 s for corrected GPI2. Reusing
the session avoids that launch for each UI check. Cold admission, changed
simulation or calibration inputs, startup cancellation and clean Quit
still require a fresh run.

Managed Quit retires the simulator with the rest of the invocation.
Keeping a simulator across RTC process replacement would require a
separately owned private core and an external-source profile that admits
the running provider through its declared endpoints. The
[standalone HIL configuration](../../HIL_CONFIGURATION.md) supplies the
simulator side of that setup. No managed-source takeover was verified in
this review.
