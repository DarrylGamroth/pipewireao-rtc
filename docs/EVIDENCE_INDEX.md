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
| How did SPIDERS recover from SCC dropout and shared mirror saturation? | [112-mode multirate private-core HIL](validation/spiders-multirate-20261118/README.md) and [MLLOWFS lab estimator parity](validation/spiders-multirate-20261118/modal-sensing.md) |
| Did a wider SCC mode bank improve the SPIDERS dark hole? | [64 and 112 modes](validation/spiders-fringe-banks-20261117/README.md) and [112 and 144 lab-derived modes](validation/spiders-lab-mode-bank-20261117/README.md) |

Use the dated directories in [validation](validation/) and [reviews](reviews/)
for other runs. Each report records its configuration and distinguishes software
tests, simulation and instrument measurements.

## Calibration and optical reference verification — 2026-11-21

RTC `e546dcc` corrected SHA-256 checks on nested FITS references and the
expectations for managed optical inputs. The core suite passed 10,580 checks
in that cohort. [Calibration usage](CALIBRATION_METHOD_USAGE.md) ·
[Bundle tests](../test/test_calibration_bundle.jl) ·
[Optical tests](../test/test_external_optical_instrument.jl)

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
