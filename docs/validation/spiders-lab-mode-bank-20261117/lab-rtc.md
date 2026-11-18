# How the fitted RTC compares with the SPIDERS lab RTC

Both designs form a rolling fringed-minus-unfringed SCC image, apply a calibrated inverse and drive a deformable mirror from camera feedback. The loop architectures differ at four points.

| Stage | SPIDERS lab checkout and FITS archive | Fitted RTC used here |
| --- | --- | --- |
| SCC input | The CRED2 frame sorter identifies the brighter even/odd parity as fringed, checks frame continuity and publishes the latest difference on Aeron stream 5003. The SCC service subscribes to that stream. The archived main-camera mask selects 22,080 pixels on a 416 × 380 crop. | The simulator provides tagged chopping phase and acquisition identity. The graph pairs consecutive opposite phases from the same source. It selects 12,703 pixels from the 221 × 221 fitted iFTS-port image. |
| Calibration and command basis | The main-camera service applies an image-to-actuator inverse and emits 468 actuator estimates. The archived 650 Fourier probes describe calibration inputs. The separate iFTS generator filters the probe images at DFT radii 29–60, applies spot masks and uses Tikhonov damping at the 70th singular value. The CRED2 generator in the checkout uses different radii and the 100th singular value. | The fitted camera uses the iFTS annulus scaled for detector sampling. The inverse is trained on filtered model probes and acts on raw chopped pixels with a zero reference. The comparison keeps the band alone and sets damping from the smallest retained singular value of each bank. Our wider bank measures 144 SCC coordinates. |
| Low-order sensing | The Goldeye LOWFS service normalizes by frame flux, subtracts a reference image and applies a pixel-to-mode inverse. The archived calibration uses 388 pixels and 14 modes. The checkout also computes centroid tip/tilt, but its assignments into the outgoing modal vector are commented out. | LLOWFS measures the centroid of the reflected image, subtracts its flat centroid and corrects two coordinates, tip and tilt. The SCC command calibration nulls these two measured coordinates. |
| Integration and mirror output | SCC and LOWFS emit actuator estimates to one Aeron IntegratorService. Each accepted estimate updates a shared modal history using per-mode gains and a leak. The DM mixer adds the configured best flat, clips the result and can send it to the physical ALPAO BAX307. | Two integrators keep separate SCC and LLOWFS histories. Their projected commands sum before the shared physical-command limiter. The initial and restarted demands are zero. The standalone HIL simulator applies the BAX307 response using the same raw measured influence file as the lab, resampled for the fitted pupil. |

The **650 lab probes** and **144 active SCC coordinates** count different things. These runs compare two camera-driven controllers fitted to the same simulator. They do not measure how they rank against a particular night or bench configuration. The modeled camera has 10 ms exposures with photon noise disabled and no wall-clock pacing. The lab launcher's late-data cutoffs are 500 μs for LOWFS and 5 ms for SCC; those settings give neither a measured cadence nor end-to-end latency. The archive contains gain and flat files, but no physical closed-loop receipt was found that ties a particular gain, flat, inverse or frame rate to a measured lab contrast.

## Independent rates on one mirror

The lab design allows LLOWFS to correct the shared mirror more frequently
than SCC. A fresh low-order estimate updates the integrator as soon as it
arrives. This timing requirement also applies to the fitted RTC. Its graph
uses independent inputs, updates the branch with fresh evidence, holds the
other branch's previous correction and publishes the combined demand.
The standalone HIL source applies the latest demand on its next optical
step. If LLOWFS is the only camera with a staged frame, HIL still triggers
the elected PipeWire driver. An earlier private-core regression exercised
that case with SCC silent.

Both camera ports in this particular experiment declare 100 Hz in model
time. After SCC is primed, its rolling F−U pair can update on each
successive opposite-phase exposure. A 50 Hz chop cycle therefore does
not imply a 50 Hz SCC update rate. These trials measure steady-window
contrast at the declared rates. They do not exercise unequal-rate timing.

A dedicated low-order DM or fast steering mirror is a possible instrument
upgrade. The measured configuration uses one BAX307. A two-device profile
would need an independently calibrated low-order actuator mapping and a
second command endpoint; an FSM would receive tip/tilt, while a dedicated
DM could support additional calibrated low-order modes.

The independent-input configuration is in FilterGraphPipeWire 0.5.6
(`src/composition.jl`, around line 116). The per-arrival update and held
corrections are in FilterGraphs 0.10.3 (`src/composition.jl`, around
lines 314–406). AdaptiveOpticsSimPipeWireHIL 0.5.9 triggers staged outputs
in `src/array_streams.jl` around line 329. The instrument repository
at `58ecd8ac842a789c8df06586a2875273b0b80042` records the earlier independent
arrival test in `test/spiders_dual_transport.jl` around line 375 and its
verification in `spiders/ANALYSIS_PLAN.md` around line 2633.

## Checking the comparison

The line references below identify local files in the lab working copy. The manifests identify the versions of the source and FITS files used for this review. Check them with `sha256sum -c` from `~/spiders-working` and `/mnt/datadrive/DATA`, respectively. [Service files](lab-services.sha256) · [Lab assets](lab-files.sha256)

- Frame classification and the live SCC input are in `choppedframesortservice/src/ChoppedFrameSortService.jl` around lines 161–243, `sccservice/start.sh` line 7 and `sccservice/src/state-machine.jl` around line 207.
- The CRED2 and iFTS recipe parameters are in `sccservice/scripts/generate-scc-im.jl` around lines 195–299 and `sccservice/scripts/generate-scc-im-ifts.jl` around lines 168–273. The saved main-camera product dimensions differ from the CRED2 script's configured dimensions; the exact archived CRED2 generation settings are unresolved. The earlier [lab replay](../spiders-fringe-20261117/README.md) checks the iFTS filtering against stored images.
- The low-order measurement and actuator projection are in `lowfsservice/src/state-machine.jl` around lines 233–320. Control routing and the shared update are in `integratorservice/start.sh` lines 10–24 and `integratorservice/src/state-machine.jl` around line 237. The best flat and clipping are applied in `dmmixerservice/src/state-machine.jl` around line 314.
