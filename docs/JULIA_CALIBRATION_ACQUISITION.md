# Julia interaction acquisition

The shared `CalibrationAcquisition` driver acquires prepared probe responses
through `pipewireao.rtc.calibration-actions/1`. AOC constructs probes and estimates
interaction matrices; instrument recipes select illumination, coordinates,
units, amplitudes and scientific acceptance. The driver contains no instrument
names, optical algorithms, graph scheduling or session lifecycle policy.

## Entry points

A fresh calibration export provides `bin/rtc-calibrate` as a thin Julia
entrypoint. The exporter includes and seals the operational package; an external
Rust calibrator is no longer an export input. The native binding flags, saved
v1 plan and stdout result shape are retained:

```sh
PACKAGE/bin/rtc-calibrate \
  --remote /absolute/path/to/private-core \
  --node declared-calibration-owner.actions \
  --owner-pid OWNER_PID --owner-instance OWNER_INSTANCE \
  --plan /absolute/path/to/prepared-plan.json
```

Binding values are hints until the native client proves the current owner and
controller. Start/admit the selected session through the existing systemd and
WirePlumber tools first. This command does not start a session or grant physical
actuation authority. Existing sealed exports keep their original executable;
create a fresh export to select the Julia driver.

The reusable Julia API uses the same driver:

```julia
using PipeWireAODeployment
const Acquisition = PipeWireAODeployment.CalibrationAcquisition
const Native = PipeWireAODeployment.NativeCalibrationActionClient

plan = Acquisition.read_plan(plan_path)
binding = Native.Binding(remote, action_node, owner_pid, owner_instance)
result = Acquisition.acquire(binding, plan)
report = Acquisition.document(result)
```

`Plan(run, reference, probes, measurements, frames_per_probe, settling,
timeouts)` also accepts prepared host arrays. Figures are owned Float32
snapshots in their declared order; host array index labels are not wire
coordinates. `Timeouts` contains positive Int64 nanosecond budgets for ownership,
adoption, settling, collection and restoration. Settling uses the existing
`Immediate`, `DiscardExposures` or `ModelTime` native types. Package loading and
acquisition do not require AOC, AOS, JFG or an accelerator dependency in this
operational environment.

## Completion and recovery

The finite workflow is Hold, then Adopt → Settle → Collect for each probe,
followed by Restore → Release. Native correlation proves run/serial, controller,
operation and terminal outcome; submission alone proves none of those effects.
The driver validates adopted figures, clipping, epoch continuity, settling
boundaries and exact consecutive contributing exposure IDs/model times.
Only a complete, restored and released run publishes response batches.

`acquire!` accepts an already proved fresh native connection. It accepts
`cancelled=()->false`, `check=()->nothing` and an optional completion observer.
Cancellation is checked at completed action boundaries. An in-flight action
resolves within its finite deadline; cancellation never cuts restoration/release
in half. Recovery uses its own restoration/ownership budgets. An external
supervision exception while waiting or an unknown transport outcome stops
submissions; there is no automatic retry, reconnect or rebind. A fault report
cannot authorize resume. `acquire` closes its own controller on every exit;
`acquire!` leaves ordinary connection cleanup with its caller.

A successful CLI run exits 0. A completed aborted/fault acquisition exits 1 and
prints its v1 result. Input, binding or diagnostic-output failure exits 2.
Scientific acceptance remains the instrument/AOC consumer's responsibility.

## Bounds and diagnostics

Plans are limited to 16 MiB, 16,384 probes, 4,096 commands/frames and the existing
native request/reply capacities. Unknown or duplicate saved-plan fields reject
before Hold. Projected retained figures/responses are limited to 512 MiB,
including a conservative per-probe metadata charge. This payload bound is not
an allocator-independent Julia heap/RSS limit. Acquisition and serialization
are cold control work; the driver imposes no new allocation in frame callbacks.

Optional `--evidence NEW_PATH` creates an exclusive file before connecting and
retains a completion journal until the workflow returns. It performs no file
writes from the completion observer while ownership is held. The charged
journal budget is 64 MiB; exhausting it does not interrupt safe recovery, and
finalization reports the diagnostic failure. Journal **version 2** records typed
completed actions and the final acquisition outcome. It does not claim that an
unconfirmed request was accepted and is not byte-compatible with the temporary
Rust journal. Saved plans, reports and this journal use JSON; live controls use
native SPA PODs throughout.

See [software/native verification and limitations](validation/julia-acquisition-20261008/README.md).
