# Registered GPI2 refresh — 2026-10-26

Scope: refresh the registered CUDA simulator, ordinary CPU JFG controller and
GUI. This is simulated application validation, not hardware, timing or global
stability qualification. Host placement and 10 Hz simulation pacing are retained.

## Registered packages and calibration

- AdaptiveOpticsSim 0.3.0, AdaptiveOpticsCalibration 0.17.1,
  AdaptiveOpticsSimPipeWireHIL 0.2.5, PipeWireAORTC 0.2.10,
  FilterGraphAlgorithms 0.8.1, JuliaFilterGraph 0.4.2,
  FilterGraphPipeWire 0.1.7, FilterGraphIsland 0.1.3,
  PipeWireAO 0.6.19, PipeWireAO_jll 1.7.1, CUDA 6.4.2.
- All runtime packages resolve to registry trees; no development path or Git
  source override is present. The retained Manifest records exact dependencies.
- Fresh deterministic CUDA calibration measured 1,509 modes, retaining rank
  1,445. All 33 startup FITS bindings passed typed preparation. The staged
  calibration receipt SHA-256 is
  `9a4f3dcf7df4bd91a125d61bcc4896707c00ca7f537fd913a0258101b2cc308f`.
- Four finite, 48-step array-loop cases pass (tip/tilt, focus, astigmatism,
  mixed disturbance); residual ratios range from 0.00530 to 0.00738. These
  deterministic checks do not describe live atmospheric performance.
- The approved provisional 250 Hz / 0.7 stage response, 25 Hz split and
  ±3.4 µm OPD woofer limits are included; gains were not retuned.
- AOS 0.3.0 was registered before the subsequent dependency-ordering merge on
  AOS main. Its presence does not establish deployment of that later merge;
  the compiled GPI graph already places the response before its consumer.

## UInt16 transport regression

The previous live deployment used the private HIL build
`0.2.2+gpi2validate.20261025.f5fa45c2`. Its UInt16 and tip/tilt support was
missing from the canonical registered release. Updating packages exposed that
release gap; comparing the previous immutable package source confirms it.
Existing Float32-to-UInt16 wire encoding tests did not cover the native boundary.
The new actual AOS UInt16 boundary
fails before HIL 0.2.4, reproducing the reported admission error; native UInt16
ExchangeState construction also fails before the fix.

HIL commit `4b951914385b302fb49f04e0b17b57871bca622b` admits dense UInt16
frames, copies native codes without requantization, and retains Float32 commands
and Float32 encoding behavior. A rectangular 2×3 native exchange checks exact
codes including 0, 32767, 32768 and 65535, row-major order, two same-sequence
command adoptions and retirement. Calibration covers both frame types.
All 2,759 checks pass against registered AOS 0.3.0 / PipeWireAO 0.6.19.
The primary agent independently inspected the production diff, regression and
passing logs before integration. RTC response/loop controls pass 47 assertions;
camera/command/session contracts pass another 53.

## Schema and tip/tilt integration

The subsequent startup passed UInt16 admission but rejected the existing
tip/tilt coefficient schema at the optional Applied publisher. HIL commit
`d552e96f31828c9ccab79088ed62069ecf08e14d` restores support using the existing
catalogued `pipewireao/tip-tilt-opd-coefficients-m-f32/1` quantity unchanged.
Physical-DM Applied streams retain
`pipewireao/applied-dm-command-opd-um-f32/1`. There is no new URI or relabeling of
stage coefficients as actuator values. All selected output contracts validate
before native connection. The complete suite passes 2,792 assertions, including
mixed native-prepared DM/stage schemas, units, complete-set adoption and exact
stage values (including negative zero).

The shared JFG schema generator verifies the RTC YAML, GUI Rust and HIL Julia
projections. Active Classic/GPI authoring and production code contain no legacy
scientific IDs; historical receipts and opaque external-schema test examples
are retained. The cold application audit checks 18 scientific identifiers
against the shared catalog and compares every selected Applied publisher's
schema/shape with the RTC port declaration. Only Project.toml, Manifest.toml
and the deployment seal change in the final dependency-only refresh; all
scientific files remain byte-for-byte identical to the validated application.

## Deployment records

GPI2 is Running in `pipewireao-session@c568c1605bc8.service`, invocation
`4b8e8ffc7f764821bc13f6b78cd8f300`, RTC PID 608809 and CUDA simulator PID
608672. Native Start completed. The prepared detector shape is 242×240 UInt16;
commands cover woofer (97), tweeter (2,304) and tip/tilt (2).

Open and Close each returned `active_adoption_observed=true`, with matching
requested/active property generations and false/true Boolean readbacks.
The final native Status is Running and correction is left closed.
Fourteen live streams pass read-only observation, including detector, commands,
Applied values, roles, constraints and offsets. Twelve acquisition-bearing
products share generation/sequence; the Applied streams retain their declared
Header-only semantics. Same-sequence DM Applied scaling is bit-exact, and all
owned observers retire (zero remaining nodes). In this short sample woofer
clipping is zero at ±3.4 µm OPD; tweeter clipping persists, averaging 33.49 of
2,304 coordinates/frame at ±1 µm OPD. This is not long-window performance evidence.

GUI PID 616481 runs in `pipewireao-gpi2-refresh-gui-20261026.service`, using
the listening `wayland-A8gwBRWoCk` proxy and the new exact PipeWire remote.
Software-rendering overrides are absent. Its native clients and fourteen ndarray
consumers are present in the new private core. The final native Format/EnumFormat
inspection verifies 28 exact catalogued scientific schema identifiers, all with
the `pipewireao/` prefix. This is process/connection verification, not a claimed
visual screenshot review.

Workstation records are retained under
`~/.cache/pipewireao/gpi2-refresh-20261026` and
`~/.local/state/pipewireao/gpi2-refresh-live-20261026`.
The first service bootstrap lacked the new RTC package in its default depot;
its dependency set was instantiated before relaunch. Failed attempts are
retained separately. The UInt16 startup failure retired its entire exact cohort
with `cleanup_complete=true`.

The previous GPI2 Quit outcome remained unknown after its absolute request
deadline; supervised cleanup confirmed all old owner and manager PIDs absent.
This refresh does not claim to fix that native Quit failure.

GUI source `699d00dad16384ef8aaa7f555a39ebb9dde50396` was built with the
locked dependencies. Binary SHA-256:
`f73adeb0b7d932ddcd98d29ac70ed54868193f943691005ff814325129a43a13`.
Saved GUI layout is preserved. Existing unrelated source edits are untouched.
