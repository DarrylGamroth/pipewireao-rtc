# SPIDERS 64-mode calibration at the dark-hole operating point

The instrument source is `4df5804`. The static operating point is the
468-element BAX307 command from the earlier fitted-dual experiment
(`edbc795`). [The FITS vector](system-flat.fits) has SHA-256
`820afdc413a46a51ff2ba8bd9120d3deaaa6a8f1b8118355d7d5321376e82eeb`.

## RTC recovery control

FilterGraphPipeWire publishes the graph recovery status as PipeWire node
properties. A protective request opens the scoped loops and restores the
configured command reference. The owner confirms the command and reports
the recovery generation. A matching release clears closure inhibition.
A guarded first close also requires fresh evidence for the requested loop.
Version 1 names one controller. Version 2 names a set of controllers and
publishes individual readiness, sequence and monotonic observation times
alongside the shared command evidence. RTC admits controls against the
published descriptor and the graph owner checks the evidence at adoption.

RTC `7222557` accepts both versions. The focused session controls suite
passed, including admission with two controllers, denial of an SCC close
when only the other controller is ready, stale evidence rejection and
unsupported version rejection.

## Recalibration

The shared calibration tool in instrument commit `a4587c8` loads the
native-command FITS vector named in [the recipe](optical-dark-hole.yaml).
It adds the bias before evaluating the measured DM surface, including for
the chopped SCC reference and LLOWFS centroid reference. The complete
physical demand is checked against the existing ±0.5 limits. The fitted
SCC region, model, 64 probe directions, two LLOWFS tip/tilt directions
and branch measurement ownership are retained. The full and half poke
amplitudes are 5 and 2.5 nm RMS OPD.

Calibration ran in Julia 1.13.3 with CUDA.jl 6.5.1 on an RTX 3080.
The SCC response retained rank 66 with condition number 26.14. The SCC
integrator owns 64 coefficients. The LLOWFS derivative disagreement was
0.02833 and the SCC disagreement was 0.0002384. The maximum held-out error
was 0.02091 against the existing limit of 0.05. The largest tested physical
command was 0.04581 in native units. [Numerical receipt](biased-calibration.json)

The materializer accepted both branch bundles. The test export binds the
measured reconstructor and reference files. The shared command graph applies
the same FITS vector with the existing `pdm-system-flat-f32` algorithm
before the command limiter.

## Private-core contrast

The fitted-dual CPU application used RTC 0.7.23 with the session code from
`7222557` loaded through a validation depot. The separate HIL process
used the existing fitted optical model and measured BAX307 DM. The candidate
application selected calibration
`sha256:d7b6598d3732b42b3543db0283f9145876202fc2c809add2a14ed855766ed1ca`.
The original zero-bias and eight-mode instrument selections are outside
this candidate export.

The RTC reached Running with both loops open. The first epoch establishes
the biased open-loop reference. The native Restart completed Hold, Reset,
and Start on the same private core for a second acquisition generation.
The subsequent SCC Close returned active adoption with matching requested
and active generations. LLOWFS stayed open. The first three SCC exposures
matched exactly between epochs and the physical command then changed as
SCC feedback took effect. The open epoch had zero deviation from the applied
system flat. The closed epoch's largest observed correction was 0.001168
native units, and every observed demand was within the ±0.5 limit.

The observer averaged camera electrons over the frozen 12,703-pixel mask
and matched model sequence, timestamp and optical phase. It excluded the
first four startup exposures from both windows. The same simulated flux,
exposure and camera response make the paired mean ratio a relative contrast
measurement.

| SCC phase | Paired exposures | Biased open mean (electrons/pixel) | SCC closed mean (electrons/pixel) | Closed relative to open |
| --- | ---: | ---: | ---: | ---: |
| Fringed | 8 | 5.421369 × 10⁻⁴ | 5.443451 × 10⁻⁴ | +0.41% |
| Unfringed | 8 | 2.016379 × 10⁻⁴ | 2.004390 × 10⁻⁴ | −0.59% |

The unfringed mean decreased for each matched exposure. The measured feedback
benefit is small relative to the static bias and applies to this deterministic
trajectory. The unit acknowledged native Quit, all owners and the RTC exited
with systemd `Result=success`, and the private socket was removed.

[Frames](exposures.csv) · [Restart](restart.json) · [Close](close.json) ·
[Command deviation](demand.json)

```sh
julia --startup-file=no compare.jl exposures.csv
```

The follow-up RTC commit `eed2aa0` covers grouped v2 closure in the focused
control tests. The live gate here closes SCC alone. The broader RTC suite
reaches the calibration-materialization selector and reports 12 malformed
nested-path/hash assertions. The same 12 fail in that selector against
unmodified RTC 0.7.23.
