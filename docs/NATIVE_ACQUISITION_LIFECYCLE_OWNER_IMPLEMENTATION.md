# Native acquisition lifecycle owner integration

Date: 2026-10-06. This change integrates the selected scientific calibration,
HEART calibration and HEART correction HIL owners with the versioned private
PipeWire lifecycle endpoint. It does not change ordinary simulator startup,
calibration action JSON framing, science graphs or the vendor HEART process.

## Authority and operation boundaries

- Each selected owner creates the cold endpoint in Preparing before plant loading.
  It publishes Prepared after scientific preparation. Connect alone creates and
  starts the existing session and establishes its existing initial hold.
- `HILNativeAcquisitionLifecycle.Bridge` builds snapshots from the current
  session and action owner. `report_cursor` advances only after the saved JSON
  report has been written. It may lag the live acquisition cursor.
- Status reads fresh owner facts. Pause gates the next action or exchange;
  an already accepted action continues under its original finite request
  deadline. Resume starts admission. Correction Resume performs the existing
  startup RUN, zero adoption and CORRECT transition under the accepted ticket.
- Calibration Reset returns an explicit unsupported result and leaves the held
  probe alone. Correction Reset retains the existing two-window and native
  generation fences. Its public controller reset, subsequent hold and archive
  mutations share the accepted ticket's absolute deadline.
- Connect, Reset and Shutdown wait for a safe action boundary. A request staged
  during an action cannot destroy that action's session or accept Shutdown
  based on a pre-effect held flag. Status and Pause can be answered during an
  action. The idle service checks an atomic wake flag before scanning the
  native registry.
- Shutdown before any calibration action is permitted while the action owner
  is `initial` and unheld. Shutdown after an action requires actual Release
  with restoration confirmed. HEART's startup native hold remains separately
  recorded in the saved report; source Stopped says source resources closed and
  does not claim the vendor wrapper was restored. Correction Shutdown requires
  `owner.retained` after successful restore-run zero adoption, telemetry
  validation and archival. Retained restoration and source command ownership
  are separate facts: a Connected restored window can still have `held=true`
  until the source session closes.
- Correction reports retain a separate completed-record cursor. It advances
  after both the ordinary recorder and correction-truth record complete, and
  resets at the successful new-generation zero boundary. Resume and failure
  publication preserve that cursor while the live acquisition cursor can be
  newer. Failed report writes do not advance the published report cursor.
- An accepted Shutdown ticket is completed only after the session and action
  listener are closed. Stopped is synchronized with the private core under
  that ticket's remaining deadline. Failure or deadline expiry retains unknown
  outcome and does not retry the effect.

`CalibrationServer.OwnerServiceAbort` separates a lost lifecycle controller
from an actual calibration action failure. Its boundary hook runs only while
awaiting admission or input, and between completed actions. The nested action
hook latches transport failure and allows the accepted action to finish. The
server then unwinds its reader, socket and listener without calling `fault!` or
changing held/restored facts. Actual action failure, socket disconnect and
action inactivity continue through the existing action-fault path. The
action's next reader starts when the action is accepted, so a lifecycle Status
or Pause does not extend its input lifetime.

## Software evidence and remaining qualification

- `deployment/hil/test_owner_protocol.jl`: 103 assertions under the deployment
  Julia project, including native option rejection of marker and file-control
  flags and positive incarnation checks.
- `deployment/hil/test_native_acquisition_lifecycle.jl`: 12 private-core
  assertions. A Reset staged during an unsafe boundary remains deferred;
  an expired completion after a modeled successful Release leaves phase,
  held and restored facts unchanged. The idle wake check allocates zero Julia
  heap bytes after warmup.
- `deployment/hil/test_calibration_server.jl`: the synthetic action suite passed
  under a stub `CalibrationAcquisition` module, including 14 new boundary-abort
  assertions for preaccept cleanup, an accepted Hold followed by lifecycle
  loss, and a lost lifecycle completion after Release. This is a server
  protocol test, not a scientific or installed-owner qualification.
- Selected calibration capture and HEART owner option fixtures now supply
  explicit native control identity and an absolute private remote. A focused
  correction test checks held/restored independence before and after closure.

The worktree HIL project has no Manifest. Source option tests can use the
existing sealed CPU HIL environment without changing its dependencies.
Integration passed 2,178 deployment assertions across 78 test sets, the 103
protocol assertions and adjacent private-core endpoint and bridge tests.
The [independent owner review](NATIVE_ACQUISITION_LIFECYCLE_OWNER_REVIEW.md)
records the report-cursor correction's fail-before/pass-after evidence.
The primary integration worktree must still run selected installed
Classic/Copper owner cycles and scientific qualification before closing RTC #6.
The retained Unix action JSON service is issue #7; ordinary simulator marker
startup remains issue #9.
