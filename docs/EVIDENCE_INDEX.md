# Delivery evidence catalog

| Engineering question | Verification record |
| --- | --- |
| Does native Quit return a pending capture loan while its provider stays up? | [Shared CPU Quit regression and Classic CUDA check](validation/shared-quit-20261126/README.md) |
| What passed on CPU with RTC 0.7.33, and where does CPU pacing matter? | [CAL2 restart, Classic controls, Copper feedback and GPI2 pacing](validation/cpu-qualification-20261126/README.md) |
| Does an installed RTC admit its declared Links, quit cleanly and release its retained graph? | [Classic CPU admission and service shutdown](reviews/20261125-installed-session/REVIEW.md) |
| Does CAL2 keep publishing through native Quit and RTC reattachment with the bundled queue? | [Installed CAL2 camera sequences, open-loop priming and buffer withdrawal](validation/cal2-bundled-queue-20261125/README.md) |
| How quickly can CAL2 attach to a publishing simulator and detach? | [Installed package cache](validation/native-admission-queries-20261124/README.md#installed-package-cache) and [direct attachment measurements](validation/cal2-installed-attach-20261124/README.md) |
| What was the latency from the first live LLOWFS input to output? | [First-frame and steady-state measurements](validation/cal2-open-frame-latency-20261124/README.md) |
| How was open-loop startup exercised across instruments? | [Classic, GPI2 and SPIDERS graph checks](validation/direct-session-launch-20261124/instruments.md) and [CAL2 live priming and first corrections](validation/open-loop-startup-20261123/README.md) |
| What happened on the first DM edit, first correction and GPI2 shutdown? | [Native NDArray integration](validation/rtc-ndarray-integration-20261123/README.md) |
| Where were the 500 µs deadlines missed on the GPI2 replay? | [Matched traced and untraced windows](validation/gpi2-traced-replay-20261122/README.md) |
| How did SCC mode count, camera dropout and mirror saturation affect SPIDERS? | [Fitted CUDA simulator results](#spiders-fitted-cuda-simulator--2026-11-1718) |

Use the dated directories in [validation](validation/) and [reviews](reviews/)
for other runs. Each report records its configuration and distinguishes software
tests, simulation and instrument measurements.

## Calibration and optical reference verification — 2026-11-21

RTC `e546dcc` corrected SHA-256 checks on nested FITS references and the
expectations for managed optical inputs. The core suite passed 10,580 checks
in that cohort. [Calibration usage](CALIBRATION_METHOD_USAGE.md) ·
[Bundle tests](../test/test_calibration_bundle.jl) ·
[Optical tests](../test/test_external_optical_instrument.jl)

## SPIDERS fitted CUDA simulator — 2026-11-17/18

These runs used the RTC 0.7.23 cohort. Individual reports identify the
patches and calibration used. Camera timing below is in model time.

- On two held-out trajectories, the 112-mode self-coherent camera (SCC)
  controller reduced mean unfringed dark-hole contrast by 14.05% and 13.55%
  relative to 64 modes. Adding 32 lab-derived modes raised contrast by 5.31%
  and 5.13% relative to 112. These comparisons used the fitted simulator
  with photon noise disabled. [64 vs. 112 modes](https://github.com/DarrylGamroth/pipewireao-rtc/blob/66158056901d5715db7c9ecf0537e7243f542bea/docs/validation/spiders-fringe-banks-20261117/README.md) ·
  [112 vs. 144 modes](https://github.com/DarrylGamroth/pipewireao-rtc/blob/66158056901d5715db7c9ecf0537e7243f542bea/docs/validation/spiders-lab-mode-bank-20261117/README.md)
- During a 1.5 s pause in SCC input, LLOWFS delivered all 150 expected
  updates. The first returning SCC exposure primed the chopped pair. The
  opposite phase yielded a new correction 30 ms later.
  [Dropout and native command receipts](https://github.com/DarrylGamroth/pipewireao-rtc/blob/66158056901d5715db7c9ecf0537e7243f542bea/docs/validation/spiders-multirate-20261118/README.md)
- Restoring the sensor reference after a one-update pulse left all 1,197
  subsequent mirror commands clipped. In the protective Reset trial,
  Release left both integrators open. After a fresh pair on the calibrated
  flat and sequenced reclosure, the final three model seconds reached mean
  contrast 1.12484 × 10⁻⁵ against 1.12586 × 10⁻⁵ in the uninterrupted run.
  A separate ordering left SCC guarded when LLOWFS moved the mirror first.
  [Recovery verification](https://github.com/DarrylGamroth/pipewireao-rtc/blob/66158056901d5715db7c9ecf0537e7243f542bea/docs/validation/spiders-multirate-20261118/protective/verification.log) ·
  [Guarded close](https://github.com/DarrylGamroth/pipewireao-rtc/blob/66158056901d5715db7c9ecf0537e7243f542bea/docs/validation/spiders-multirate-20261118/reclose-order/README.md)
- The registered MLLOWFS estimator reproduced all 14 lab coefficients on one
  archived crop. [Estimator comparison and scope](https://github.com/DarrylGamroth/pipewireao-rtc/blob/66158056901d5715db7c9ecf0537e7243f542bea/docs/validation/spiders-multirate-20261118/modal-sensing.md)

## Retrieve historical records

The [published catalog](https://github.com/DarrylGamroth/pipewireao-rtc/blob/5a1e471fc9c67cfaa2de153ffc480af1fdb7a7ea/docs/EVIDENCE_INDEX.md)
opens the documentation and its linked evidence together at the recorded revision.
It includes the retired WirePlumber prototype, earlier control migrations,
calibration campaigns and their reviews. The four November 9 GPI2 replay
reports also link to their original raw archives and keep their SHA-256 checksums.

From a clone with project history, read an old document or recover an archive
without changing the checkout. For example, from the repository root:

```sh
rev=5a1e471fc9c67cfaa2de153ffc480af1fdb7a7ea
git show "$rev:docs/WIREPLUMBER_SESSION_DESIGN.md"
run=docs/validation/gpi2-connected-20261109
git show "$rev:$run/evidence.tar.gz" > evidence.tar.gz
sha256sum -c "$run/evidence.tar.gz.sha256"
```

For the complete catalog immediately before this cleanup, use
`git show e69c39a:docs/EVIDENCE_INDEX.md`. To locate other versions of a file,
use `git log --all -- path/to/file`.
