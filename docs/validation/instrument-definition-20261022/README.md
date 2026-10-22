# Classic shared instrument definition — CPU software validation

Date: 2026-10-22. This gate concerns scientific metadata, RTC publication and
GUI resolution. It does not qualify hardware, calibrated mirror registration,
physical stroke, wall cadence or latency. The provisional Gaussian mirror,
calibration files, gains, command units and shape-control conventions are
unchanged.

## Ownership and closure

`REVOLTClassicSim.instrument_definition()` supplies ordered source-grid DM
geometry, distinct optical pupil coordinates, shape coordinates and SHWFS
regions. The application generator adds selected calibration identity, actual
controller bounds and wire interfaces. The sealed `instrument.json` is published
as read-only properties on the existing verified native RTC session endpoint.
The GUI resolves instrument references only after fresh session verification;
missing, malformed or replaced metadata disables the affected products and
controls. Hydrated scientific metadata is never saved in workspace state.

The selected startup calibration identity does not establish adoption of later
live artifact changes. This increment validates the existing one-DM/one-WFS
AOS transport. Future multi-channel instruments require explicit transport
mapping; the GUI component resolver contains no instrument-name handlers.

| Component | Immutable local closure |
| --- | --- |
| REVOLTClassicSim | 0.2.5, commit `803dc0cf6e66f6705e842bbd86f0e35ceb46fef5`, tree `febea5d48262a760cb9a34199e10ca7eb874987c` |
| PipeWireAORTC | 0.2.6, commit `20b4106`, tree `d1f2707feedcff7395b344b4afdaf196950a5c4f` |
| GUI | `feba24997ad85429b4f933fc20bc8e6818171274` |
| AOS / shared HIL adapter | unchanged 0.2.2 / 0.2.2 |
| JFG / FilterGraphPipeWire | unchanged 0.4.1 / 0.1.6 |
| Julia | 1.13.2, one-thread CPU software checks |

The two Julia versions are registered in the existing private review registry,
using immutable local bare mirrors. Only those two manifest entries changed;
there are no path or repository overrides. Registry update reports its existing
missing-origin warning; package resolution succeeds from the local mirrors.
The matching native prefix remains
`~/.local/opt/pipewireao-classic-headless-20261021`; no native module change is
required for standard NodeInfo property publication.

## Completed software checks

| Check | Result |
| --- | --- |
| Scientific geometry / definition | 265 assertions passed, including exact historical source-grid values and both profiles' cold graph declarations |
| Full RTC Julia suite | 2,622 assertions in 88 test sets passed |
| Final metadata selector | 103 assertions passed after same-loaded-byte sealing refinement |
| Application instrument / calibrated FITS geometry | 17 assertions passed |
| GUI complete shared library | 581 passed, one existing opt-in test ignored |
| GUI exact native session metadata | 3 new instrument and 34 native-session tests passed |
| GUI RTC adapter/session selector | 31 passed, five existing opt-in tests ignored |
| WASM shared library, native Glow build, formatting | Passed |
| Exact application JSON/TOML cross-language check | 10 views, 277 actuators, 188 subapertures; units, limiter, shape coordinates and no scientific persistence checked |

The exact definition is 34,605 UTF-8 bytes, SHA-256
`dddf56a551d87f24faecbb3980d6be88abceeb3842552dca4665c82ef9ccc1bb`.
The GUI Glow executable SHA-256 is
`d8dae6b82f830ce3547d7f2001354ed2f37ddefe805c8297e670403e3c7054fc`.
The application view file decreases from 51,013 to 10,472 bytes.

The first full RTC attempt loaded the preceding validator while the new tests
were being completed and failed a newly introduced rejection case. It is not a
final-source result. The repeated full run and final focused run above pass.
The full suite prints an expected failed Git-object lookup from its negative
configuration-store checks. GUI builds retain existing vendored Smithay and
atomic deprecation warnings.

Host preparation logs and scripts are retained under
`~/workspaces/codex/worktrees/classic-instrument-definition-20261022`.
The [independent review](../../reviews/20261022-instrument-definition/REVIEW.md)
records three corrected configuration defects and the boundary analysis.
## Installed offline and live closure

The final application commit is `958f11199e05a84e1dbd39bb8367f924781eb25c`.
Pinned offline preparation passes **79 assertions** and the unchanged actuator
completion/HEART checks pass **60 assertions**. All 50 sealed assets match.
The generated public endpoint contains the exact instrument bytes and hash.

The old CPU session `0506e9722c2a` and its GUI were stopped through retained
identities. Its final receipt records `cleanup_complete=true` and service result
`success`. New session `ea307b4d06d7`, invocation
`01fb75c8945144c1b83cf73702cb37b8`, is Running with UUID
`dcd70071-374e-429d-b80f-0dfc9e0851b4`. Its installed application is under
`~/.local/state/pipewireao/classic-cpu-instrument-live-20261022`.
Classic remains on CPU, model rate 500 Hz and wall pacing 10 Hz. The GUI uses
Mesa software rendering through the existing forwarded display.

The [live receipt](live-instrument-check.json) checks exact published bytes and
hash against the sealed file, endpoint PID/profile/UUID against the retained RTC,
and 31 matching WFS acquisition identities/PTS with a bitwise-exact independent
summary oracle. The summary and slopes GUI subscriptions are active. The
[GPU audit](live-gpu-audit.json) records no GPU runtime mappings or device handles
for the seven owned roles, including the optional analysis process and GUI.

A separate [read-only production-adapter probe](live-instrument-probe.log)
fresh-selects that exact session and receives an accepted Status. It obtains the
definition through the same verified native adapter as the GUI and resolves
10 views, the 277-command DM and 188-subaperture SHWFS. The shape binding is
available with nine Zernike modes and 112 Fourier frequencies. The probe sends
no lifecycle, scalar, artifact or parameter changes and takes no frame streams.
This validates installed delivery and resolver availability; it does not claim
a manual rendered-window inspection or a live command-application test.

The implementation commits are merged to each normal checkout's local `main`;
the four temporary implementation worktrees and merged branches are removed.
The pre-existing GUI workstation-review edit is preserved byte-for-byte.
No GitHub publication or new native library build was required for this gate.
