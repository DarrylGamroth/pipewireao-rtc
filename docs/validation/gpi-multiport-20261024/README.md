# GPI optical model and multi-command HIL — 2026-10-24

The GPI 2.0 optical model is now data-only in the instrument monorepo. Its three
named inputs are woofer (97 commands), tweeter (2,304) and tip/tilt (two OPD-ramp
coefficients). There is no concatenated command vector or partition graph node.
The existing AOS HIL boundary and PipeWire adapter accept a fixed named command
set; their scalar single-command API remains available for Classic.

One frame remains in flight. Each native callback validates and copies only its
own prepared command port. One receipt timeout covers the entire command set.
The owner waits for every port's matching sequence, checks completed native
cycles and stream health, then invokes one AOS adoption. All finite-value and
shape checks finish before any graph command is copied. A copy failure stops the
boundary; malformed reset also remains failed. This is a software lockstep
contract, not physical simultaneous actuation or an atomic hardware update.

## Source identity

| Repository | Reviewed source |
| --- | --- |
| AdaptiveOpticsSim | `7b60046c5850e6303d5550590a43cafc3d7576b7` (base `f8fd20de`) |
| AdaptiveOpticsSimPipeWireHIL | `7f30109a26a80e45315b6a2059242bf44bef1bcc` (base `ac16cf0`) |
| JuliaFilterGraph | `b77dcee` (base `1c3cddf`) |
| PipeWireAORTC | `45400b5` plus pyramid declaration/pupil binding commits, merged with Classic acceptance at `a040fd3` |
| Instrument monorepo | `bc2c088e3b3f501fdf6a30cf95250df019e3c133` (base `1ad250e`) |
| Legacy numerical reference | GPI2Sim `a12a6d5`, unchanged |

The schema catalog owns normalized pupil ramps, annular support, tip/tilt OPD
coefficients and both EM-output/input-equivalent electron quantities. RTC schema
projection is generated and passes the generator consistency check. The unused
combined-command schema was reverted when three distinct ports were selected.

## Verification

- AOS: 40 CPU algorithm-graph testsets; 236 focused boundary assertions,
  including warmed three-port step/adoption allocation guards. See
  [aos-tests.log](aos-tests.log). The original Symbol-only boundary fails the
  same multi-command selector before preparation.
- HIL: 1,908 transport/native/calibration assertions and an empty method
  ambiguity check, followed by boundary-name/alias and explicit multi-command
  calibration rejection checks. See [hil-tests.log](hil-tests.log).
- Native partial sets: 231 private-core assertions. Two ports remained ready
  over at least three additional native cycles with exactly one publication
  each. Releasing the final port completed adoption; withholding it produced
  the command-set timeout. A genuine duplicate payload rejected. Both failures
  preserved every graph command and blocked further frame execution/reset;
  deterministic close removed all streams. See
  [native-partial-tests.log](native-partial-tests.log).
- Shared RTC: detector layout 49, pupil bindings 68 and named authoring 22
  assertions, plus existing declaration/component/export selectors. The
  detector adapter supports rectangular placement, optional affine clipping,
  strict types/shapes and warmed allocation checks; it has no GPI-specific
  renderer or accelerator-capture claim.
- GPI CPU optical selector passed 39 assertions; see [gpi-tests.log](gpi-tests.log). It covers three-port shapes/causality, each corrector,
  additive OPD units, photon/electron bookkeeping, padding and seeded reset.
  The optional legacy comparison passed 16 assertions: exact mirror/ramp/pupil,
  photon-rate and EM-output arrays for the selected probe; the final normalized
  frame differed by at most 4.77×10⁻⁷ electrons due to reciprocal multiplication
  rather than gain division. See [parity.json](parity.json).
- Classic's actual declarative calibration plant passed eight CPU checks with
  its existing single Array command, 277 commands and 352×352 frame, including
  two exchanges and reset; see [classic-tests.log](classic-tests.log). The live Classic CUDA RTC was not changed/restarted.

### Independent review

| Finding | Assessment and disposition |
| --- | --- |
| HIL-MP-001 | **Confirmed, fixed:** resizing exposed host Arrays could allow prefix-only adoption or a malformed healthy reset. The same reproducer now rejects before any graph mutation; single-command and calibration boundaries use the same shape guards. |
| HIL-MP-002 | **Hypothesis, not reproduced:** an already-ready sink might receive an empty process callback during later cycles. The delayed/missing-port native tests did not reproduce this on the tested SDK. Only discriminating tests were added; no speculative production callback change was made. |

Independent final review checked AOS `7b60046c` and HIL `7f30109`; no confirmed
unresolved finding remains in this boundary/transport scope.

## Reproduction and limits

Scientific validation used Julia 1.13.2, CPU affinity 14–15, empty
`CUDA_VISIBLE_DEVICES`/`ROCR_VISIBLE_DEVICES`, and the installed PipeWireAO SDK
wrapper at
`/home/dgamroth/.local/state/pipewireao/classic-cuda-20261023/with-sdk.sh`.
The frozen science dependency set was copied into validation-only environments;
only AOS/HIL/RTC source paths and explicit test imports were changed. No package
resolution changed the live application. Raw logs/environments remain at
`/home/dgamroth/.local/state/pipewireao/classic-acceptance-20261024/gpi-multiport/`,
`/home/dgamroth/.local/state/pipewireao/hil-multiport-20261024/` and
`/tmp/aos-multiport-hil-validation-20261024/`.

Run the AOS `algorithm-graphs` CPU selector, HIL `test/runtests.jl` with its
private-core prerequisites, RTC `test/test_hil_declaration.jl`, and instrument
`test/gpi2.jl` in the coordinated source environments. The optional instrument
`test/gpi2_legacy_comparison.jl` additionally needs the unchanged reference
package; GPI runtime metadata has no dependency on it. Formatting uses the
repository's JSON.jl/Taplo/yamlfmt tool, with the scientific environment exposing
JSON.jl explicitly.

The stronger native multi-command test uses acquisition v2. Per-port v3 identity
rejection is covered by metadata tests and existing scalar native v3 tests;
native multi-command v3 remains unqualified. Multi-command held-probe calibration
is explicitly rejected until AOS defines that calibration contract. GPU/capture,
physical hardware, deadlines and 2 kHz wall-clock operation are not qualified.
The GPI pupil/maps/Gaussian influences and camera statistics remain provisional.
A complete GPI RTC controller/calibration profile, publication of all correctors,
and generic tip/tilt stage presentation remain subsequent work.
