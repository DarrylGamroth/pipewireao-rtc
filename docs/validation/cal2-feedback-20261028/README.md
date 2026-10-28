# CAL2 external pupil and physical-offset validation — 2026-10-28

This record supports RTC 0.2.34 and RTC-DEV-037/038. The parent increment is
`fec49dd` / `565e744` on `cal2-external-pupil-gpu`, PR #19. Scientific acceptance,
software verification, private receiver integration and combined-loop
qualification are separate claims.

## Implemented boundaries

The version-4 external-pupil owner uses the existing native bootstrap and source
controls, with independent SCC/LLOWFS exposure streams and no simulated CAL2 DM.
CAL2 projects modes to 2,304 physical tweeter commands. GPI owns admission and
holds an absolute contribution per branch; one adopted snapshot supplies the
post-VDM physical offset and `r′ = r − CQu` reference compensation before final
conditioning. Calibration identity, command order, cohort, age and limits are
checked without introducing another authority or supervisor.

`InstrumentExport.prepare`, `compose`, `materialize_calibration` and
`prepare_feedback` retain the ordinary data-only application workflow. The
optical-calibration mode needs no dummy controller FITS. Materialization writes
`generated/calibration/rtc.yaml` and a path/hash receipt, preserves authored RTC
bytes, and controller mode selects that generated configuration. Feedback
preparation validates both accepted branches, executed frontend/settings,
selected RTC closure and all actual typed graph/physical factors before sealing.

## Software and integration evidence

Julia 1.13.3, no CUDA use. Source validation environments remain outside built
application runtime closures. Selected dependency releases are AOS 0.3.10,
HIL 0.2.10, Proper 0.4.1, FGA 0.8.11 and FGPW 0.1.15. Host expected-reference
qualification applies only to a CPU GPI detector producer; CAL2 propagation has
an independent CPU/AMDGPU selection.

| Selector | Observed result and scope |
| --- | --- |
| `test/runtests.jl` | 7,365 assertions pass; retained log `/tmp/cal2-rtc-core-followup.log` |
| Physical-offset core / native receiver | 79 core and 127 private-core assertions pass; no combined application claim |
| `test/calibration_optical.jl` | 90 CPU assertions pass: physical order/units, native pupil orientation, recipe admission, expected-response cold guards and executed settings |
| `test/calibration_optical_publication.jl` | 18 CPU assertions pass, including actual typed graph/FITS publication |
| `test/integration/test_managed_session_cal2.jl` | 23 cold assertions pass; no core, service or accelerator action |
| Source-only CAL2 build | Fresh ordinary optical-calibration build succeeds without controller FITS; default controller mode requires accepted selection |

The opt-in `managed_session_cal2.jl` derives contracts and roles from an accepted
sealed composed application. It checks native open properties, bounded complete
acquisitions, independent cadences, Pause/Reset/new acquisition generations and
exact owned cleanup. Physical, adopted-offset, reference-before/after and CAL2
modal vectors retain per-frame payloads. Its zero-reference oracle compares the
same receiving GPI physical-output frames; CAL2 exposure/input latency is a
separate quantity. The selector has not yet run against the normal combined
cohort, and exact-zero equality proves no nonzero `CQu` adoption.

## Accepted calibration and limits

The retained accepted bundle is `/tmp/cal2-native-calibration-20261028-r3`, identity
`sha256:a627376461693bfdd355babf7b7872283edeca2bf37debcc54366e212a320b5e`.
Its `calibration.yaml` SHA-256 is
`9faffb622e968bde0886d16d65564a1640a4e83343eec234fa8cda992b9d8833`.
Both indexed reports are accepted, deployable and non-diagnostic; application
acceptance remains false. Actual native `PupilOutput.pack!` fixes the GPI `[x,y]`
to transported `[quantity,y,x]` convention. Earlier uncorrected optical results
do not qualify this boundary.

At the unchanged 5% gates, optical held-out reconstruction errors are
1.543–3.254%; the Host expected-reference combined upper estimates are
0.990–1.059%, with h/h2 derivative upper estimate 0.4378%. The recipe uses 512
samples, 128 rounding samples, and independent training/validation seeds
200002/400002. The ideal independent Poisson/Gaussian model, qualified native
Host arithmetic/ADC envelope and empirical uncertainty estimates are explicit.
This accepts held physical-pose mean response, not individual noisy exposures,
finite PRNG-period or hardware-tail behavior, global stability or a noisy loop.
Previous held-frame reference failures remain rejected.

## Independent review dispositions

- C-R1: fixed. Composition protects the selected runtime Project/Manifest and
  validates the final registered runtime closure before publication.
- F-R1/F-R2/F-R3: fixed. Executed frontend projection/static bindings, every
  indexed branch and effective source/ADC settings are checked. Generated RTC
  path/hash and executed selection are bound; Host reference calibration cannot
  qualify an accelerator GPI producer.
- EXP-SW-01: fixed. Temporary frontend cleanup covers all work after creation.
- EXP-SW-02: fixed. Expected-response acquisition requires the exact executed
  photon-rate diagnostic, direct detector→ADC path and HIL frame alias, with no
  competing input/delayed producer. Rewire and runtime/calibration mismatch
  regressions pass. The accepted acquisition preceded this admission-only guard;
  the exact report-bound executed GPI graph passes it separately in
  `/tmp/cal2-chain-guard-smoke.log`. It does not change calibrated arrays.

Final source review found no remaining blocking parser, binding or cleanup
finding within this scope. Numerical uncertainty received a separate review.
Explicit wall pacing preserves the 2 kHz model timestep: CPU examples use 0.1 Hz
with longer branch silence limits; AMDGPU examples use 1 Hz. Neither setting
establishes a deadline. Normal combined lifecycle, nonzero physical/reference
adoption above Float32 quantization uncertainty, sustained simultaneous-loop
science and physical hardware qualification remain pending.
