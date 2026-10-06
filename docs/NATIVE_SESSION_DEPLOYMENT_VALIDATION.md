# Native session publication and operator selection

## Scope

Source-level functional qualification on 2026-10-06 for RTC issues #4, #8 and
#9. This increment publishes the existing supervisor identity; it adds no
scientific scheduler, frame processing or implicit owner launch. Installed
scientific and systemd service qualifications remain separate.

The launcher publishes one bounded native discovery record after creating its
supervisor endpoint and before preparing external scientific owners. UUID,
PID, incarnation, private remote and node name come from that endpoint. The
operator label comes from the deployment configuration and is not an identity.
Cleanup removes only this exact publication; a replacement survives. A failed
endpoint close does not bypass discovery or process cleanup.

The Julia CLI supports `sessions`, `select-session --session UUID`, and
`control --session UUID -- COMMAND`. Listing returns unverified hints.
Selection performs fresh read-only native Status and retains that exact client
for later explicit commands. Duplicate names do not select an owner. Unknown
outcomes have no retry, rebind, owner creation or JSON transport fallback.
Printed JSON remains optional local rendering.

## Confirmed locator path defect

**Observed:** the public supervisor locator is stored at
`RUNTIME/control.json`; scientific reports and the private core socket live at
`RUNTIME/INSTANCE/`. Calibration and HEART export consumers previously derived
the private directory using `dirname(control_locator)`, selecting the parent
instead. An earlier fixture placed both at the same directory and missed this
case.

The startup helper now reads a bounded immutable `Locator` once, checks its
PID against the spawned process where available, and connects that same copy.
Live native metadata and fresh Status remain the authority. The returned
`private_runtime` and `observation_remote` fields identify that bound private
child explicitly. Calibration actions and saved report reads use those fields;
they do not infer a socket or report path from the locator's parent. Replacing
the locator after copying cannot redirect the selected client.

**Fail-before/pass-after:** the retained discriminator reconstructs the old
`endpoint_binding` from RTC revision `1adc3aa`. Its new-layout assertion fails
against that implementation and passes against the corrected implementation.
This establishes the path defect; it does not claim that an installed
calibration campaign has already passed.

## Verification

Evidence is retained under `~/.cache/rtc-live-controls-20261005/`.

| Gate | Result | Evidence |
| --- | --- | --- |
| Discovery, lifecycle, CLI syntax, acquisition and interruption pure checks | 155 passed | `native-session-publication-pure-final-20261006.log` |
| Actual single-core publication and exact retained selection | 26 selection checks plus 15 coordinator/observation checks passed | `native-session-publication-core-20261006.log` |
| Independent cores, duplicate labels, running/stopped sessions and fresh Julia CLI | 21 checks passed, in addition to the single-core suite | `native-session-publication-multiple-20261006.log` |
| Immutable locator, malformed hints and campaign bindings | 101 checks passed | `native-locator-path-pure-final-20261006.log` |
| Actual native supervisor, copied-locator replacement and cleanup | 52 checks plus 15 prerequisite checks passed | `native-locator-public-core-20261006.log` |
| Old/new private-child discriminator | Old implementation failed 1 assertion; corrected implementation passed 1 | `native-locator-path-before-final-20261006.log`, `native-locator-path-after-20261006.log` |
| Actual launcher, publication, public controls and terminal cleanup | 54 passed | `native-deployment-locator-publication-20261006.log` |
| Deployment, acquisition and HEART export regression checks | 482 passed | `native-discovery-deploy-exports-20261006.log` |
| Actual GUI native session selection and read-only Status | 1 GUI test passed; enclosing two-core suite passed 23 checks plus 41 prerequisites | `native-session-gui-public-core-20261006.log` |

The final launcher fixture is
`native-runner-deployment-2054029031880091`. It uses runner SHA-256
`f4f8adf29a28aea11a915d929b671ac1bffec0fbc569d6d4e3766aa5a228f430`,
inherited CPUs 14/15 and explicit owner CPU 14. It submits **zero scientific
frames** and arms no ndarray sinks. The original earlier failed fixtures and
intermediate test setup mistakes remain retained.

## Independent read-only listing correction

The reviewer found that listing sessions used the publication directory helper,
which created missing directories. The reader now checks existing owned private
directories and returns an empty list when the registry is absent. It creates
no directories or lock files. The unchanged discriminator passed 5 assertions
and failed 3 before the correction, then passed all 8 afterward. The expanded
pure suite passed 104 assertions. Evidence is retained in
`native-session-publication-review-20261006/readonly-{before,after}.log` and
`native-session-read-only-root-20261006.log`.

## Remaining delivery gates

Independent review of publication and the locator correction, rendered GUI/picker and reconnect isolation, installed Classic/Copper FGN/JFG/unchanged HEART,
ordinary-owner bootstrap retirement and systemd qualification remain required.
Scientific equivalence, allocation, latency and physical hardware validation
are not implied by these functional tests.
