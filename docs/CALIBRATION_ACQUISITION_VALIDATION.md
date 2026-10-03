# Operational calibration acquisition

## Scope

This records the Classic CPU increment of RTC-DEV-029 on 2026-10-02.
The requirement remains partial. Native FGN and external JFG execute the
maintained pixel calibration, complete-image Shack–Hartmann estimator and PDM
constraint algorithms. The ordinary correction graph is absent during initial
calibration. HEART source is unchanged.

The serialized Julia owner accepts the existing bounded completion protocol.
`rtc-calibrate` drives the Rust coordinator; Julia scientific helpers delegate
probe generation and interaction-matrix estimation to AdaptiveOpticsCalibration.
Neither implementation runs the scientific algorithms in socket callbacks.
One probe remains held across settling and measurement exposures. Each exposure
must deliver every required WFS output with its exact full identity and duration
before the owner acknowledges it. The coordinator-local domain `1` is an
explicit mapping of the full acquisition UUID; separate sessions have different
UUIDs even when their local receipts match.

Probe figures and constraint feedback use micrometre OPD. The normal AOS command
transport converts demanded figures to metre OPD once. Adoption evidence retains
the actual Float32 wire values. A publication acknowledgement is insufficient:
the owner drives pending native processing until actual command/WFS receipts,
under the original request deadline. Control-plane polling does not establish
adoption, settling or measurement success.

## Changes and fault behavior

- Generic prepared source/sink helpers belong to PipeWireAO.jl. They accept the
  fixed packed ndarray contract, including native output chunk stride zero,
  and retain one owned receive slot. They are ordinary Julia callbacks and make
  no hard real-time or zero-copy claim.
- The AOS transport adapter exposes an owner hook after an actual model step and
  before publication, so response collectors arm with the real exposure record.
  Disconnect or timeout prevents reuse of a failed instance.
- A complete associated finite batch with invalid WFS quality remains visible
  as `valid=false`. Rust rejects it and requests fresh reference restoration.
  Missing, mismatched or nonfinite transport evidence still faults the session.
- Restoration preflights all validation before effects and fences pending work.
  A post-effect failure retains the hold; an old probe cannot collect after a
  changed reference.
- Socket reply publication checks completed write length and the original
  deadline. A redundant terminal `flush` previously faulted after the client
  received release and closed; fail-before/pass-after evidence verifies its
  removal without suppressing genuine write/disconnect failures.
- Startup rejects a transport exposure duration that differs from the declared
  detector exposure before publishing readiness or opening endpoints. An actual
  mismatched startup was accepted before this guard and rejects after it;
  recorded 1.896 ms acquisitions already used matching durations.
- JFG graph owners stop before their peer source/sink endpoints are destroyed.
  The investigation harness also stops its separate client ThreadLoop before
  destroying native proxies. Both full-cycle runs finish with every process
  exiting successfully and calibration endpoints removed.

## Normal detector and selection

The initial on-sky selection contains 188 lenslets, including four inside the
simulated central obstruction. All-active captures retain their zero flux and
invalid flags; they fail scientific batch acceptance.

The simulated calibration condition uses zero uncompensated OPD, zero reference
command and an explicit R-band magnitude 0.5 source, instead of the science
source magnitude 2. Exposure, gain, detector noise, ADC and the deployed pixel
threshold 20 / flux threshold 1000 remain unchanged. This is a declared
calibration illumination, not an ideal optical truth calculation.

Sixteen dark exposures traverse raw transport and are averaged in ADC units.
Sixteen independent illuminated training exposures then use that background.
Before training, the eligibility rule requires intrinsic validity in every
sample and minimum flux at least twice the existing flux threshold, with no
target lenslet count. ADC upper-rail samples reject training.

The frozen selection contains 184 lenslets. Excluded zero-based ROI indices
85, 86, 101 and 102 are the central 2 × 2. Minimum selected training flux is
4929.25 ADC units; maximum ADC sample is 1682 of 4095, with no upper-rail samples.
References come from the deployed estimator. Independent detector seed 1
qualifies all selected positions. The same selection is installed as WFS
`active` and supplied to acquisition acceptance; all 188 flux/validity records
and all 376 slope positions remain available. Inactive slopes stay zero.

The exporter binds the acceptance mask to the selected WFS parameter file or
construction field. Standalone `--wfs-active` relies on the caller establishing
that same binding; it is not a live graph parameter readback.

## Export and launch

Start with a newly exported HIL package containing the maintained calibration
owner, current AOC and the selected simulator. Build both executables from the
same RTC source, then export the initial calibration topology:

```bash
cargo build --release --locked --features live \
  --bin pipewireao-rtc --bin rtc-calibrate
python3 deployment/export_calibration.py \
  --base-package /absolute/export/classic-hil \
  --output /absolute/export/classic-calibration \
  --pipewire-prefix /opt/pipewireao --deployment \
  --rtc-binary target/release/pipewireao-rtc \
  --calibration-binary target/release/rtc-calibrate
python3 deployment/deploy.py install \
  --package /absolute/export/classic-calibration \
  --destination /absolute/install/classic-calibration
```

The normal deployment launcher performs placement, preparation, exact linking
and admission. After admission, run the packaged `bin/rtc-calibrate` with
`--endpoint` pointing at `calibration.sock` in the instance directory recorded
by the launcher's `state.json`, and `--plan` pointing at the explicit AOC-prepared
plan. Initial client connection has a 30 s deadline starting after graph admission.
The listener is published before admission while the owner services paused
launcher control. Graph preparation retains the launcher's finite startup
bounds; request, response and exposure deadlines are unchanged. `CalibrationClient`
prepares zonal plans, validates complete results and estimates matrices; no
result is automatically activated. A changed mask, background or reference
requires a new explicit package with updated provenance and hashes.

Native graph paths use the existing `${PIPEWIREAO_RTC_GRAPH_*}` references,
bound by the descriptor to rendered runtime files. The launcher selects the
native Julia artifact override for the same prefix as its daemon and Rust
runner. Actual library maps remain the deployment verification evidence.

## Private-core full-cycle result

Both paths use 277 physical actuators, ±0.02 µm OPD zonal probes, two measured
exposures per sign and one discarded exposure after adoption/restoration.
Acquisition runs without a wall-cadence claim: the model period is 100 ms and
the detector exposure is 1.896 ms. Every request retains its original 20 s
timeout. No controller gain or clipping coefficient is changed.

| Check | FGN | JFG |
| --- | --- | --- |
| Probe batches / accepted exposures | 554 / 1108 | 554 / 1108 |
| Associated finite valid values | 208,304 | 208,304 |
| Fresh restoration sequence | 1663 | 1663 |
| Restoration and release | Confirmed | Confirmed |
| Owner, graph and helper shutdown | Successful | Successful |
| CLI elapsed, functional characterization | 43.11 s | 42.86 s |

All response Float32 values are bit-identical between these private-core runs.
The physical interaction matrices have shape 376 × 277, measurement by
physical actuator, and all 104,152 entries match exactly. Excluded rows remain
zero. This establishes response and matrix agreement for the recorded procedure; it does
not establish independent noisy calibration repeatability or scientific rank.

Recorded response SHA-256:
`ab308df92d0cbdf063a1aa5e57662930b369757f3b19bdca1182184690ae7432`.
The interaction matrix SHA-256 is
`b5115a793d5d8475b8da7c7d73f4b5b2a22ba4a1fd6b4396bdbc9f9e5040e89b`.
The current AOC 0.17 public estimator reproduces both matrices bit for bit.
The canonical local AOC checkout was stale at 0.1; verification uses an isolated
checkout of owned GitHub main `875a7c2`. Current FGA correctly excludes the
incompatible 0.1 interface. No FGA compatibility bounds were weakened. The
client requires `StructuredValid` before accepting the numerical product;
overflow cannot pass merely because the previous result storage remains finite.

Invalid all-active quality and a clipped 0.9 µm request each produce an aborted
result with no accepted responses and confirmed fresh restoration/release.
The actual positive selected two-probe gate and both full cycles produce
complete results. None replaces an ordinary active reconstructor.

## Precision experiment

Flat samples give trace of sample measurement covariance ≈0.13258 pixel².
Under stationary independent noise, initial two-frame averages and 0.02 µm
probes predict noise-column RMS 9.10 pixel/µm, versus observed column RMS 10.43.
The energy comparison is a noise hypothesis, not an observability decision.

A separate actual acquisition tests physical actuator 139 at normalized pupil
(0, 0), and actuator 143 at (0.5, 0), using 0.02, 0.04 and 0.08 µm probes,
16 exposures per sign and two independent repeats. Four zero figures provide
null controls. All 448 accepted exposures and restoration sequence 477 succeed.
The six estimated patterns represent two actuators at three amplitudes.

| Probe amplitude, µm OPD | Clear-pupil repeat noise RMS, pixel/µm | Repeatable signal energy, pixel²/µm² |
| --- | ---: | ---: |
| 0.02 | 3.409 | 32.94 |
| 0.04 | 1.746 | 30.78 |
| 0.08 | 0.851 | 32.69 |

Noise falls approximately inversely with probe amplitude while the clear-pupil
response remains repeatable. Null average noise norms 0.0933 and 0.0965 pixels
agree with the flat prediction 0.0910. The obscured actuator has a weaker
repeatable response; Gaussian tails mean it is not assumed exactly null.
Only two repeats were taken. There is no averaging-count sweep, uncertainty
based linearity acceptance, physical rank or corrected-loop qualification.

## Evidence and remaining gates

The CPU Classic HIL and calibration deployment exports include current AOC
0.17, the prepared transport helpers, owner/server/client sources and the release
`rtc-calibrate` command. The maintained deployment profile decoder accepts the
package, and every declared artifact hash matches. Historical offsets in that base export
remain hybrid diagnostic evidence, distinct from the operational captures above.

An installed test identified a stale RTC runner inherited from the older base
package: it rejected the Classic BOOL8 validity port before readiness. Current
RTC source already supports this port. Deployment export now requires explicit
`--rtc-binary` and `--calibration-binary`, copies both selected executables and
records their hashes. Graph-assets-only exports retain their existing behavior.

Subsequent installed attempts identified an unexpanded graph path, the runner's
former rejection of the external raw detector observer, and an unconditional
subscription to optional property metadata. Graph paths now use existing
environment bindings. The runner admits explicit complete-frame external
observer links with its ordinary compatibility checks. Run-control discovery
first observes public NodeInfo capabilities and subscribes to optional
`PropInfo` only when readable; required `Props`, run/reset status checks and
core-error handling remain strict. Failed packages and clean shutdown evidence
are retained separately from the successful private-core calibrations.

The current Classic FGN package now passes the actual public install/run/control
path. Its all-active negative test returns `InvalidEvidence`, no responses and
confirmed fresh restoration/release. The selected positive package completes all
554 batches and 1108 accepted exposures, restores at sequence 1663 and produces
exactly the same complete Rust result as both private-core FGN/JFG runs. Both
launchers stop and quit successfully; every owned process and runtime instance
is removed. The positive package validates 371 declared artifact hashes.
Retained process maps confirm that core, simulator and RTC all load the fixed
native library from `/opt/pipewireao`. Recorded data loops use FIFO priority 83
on CPU 2; leaders use CPU 14 and simulation uses CPU 6. CPUs 0/1 are excluded.
The first installed JFG attempt failed before readiness: its client-connection
timer expired while cold graph owners were still preparing. The server now
waits for initial admission before starting the same finite accept budget.
Three regression paths failed before this change and pass after it, including
post-admission timeout and quit while paused; no probe or exposure ran in the
failed installed package. A subsequent pre-admission placement check caught
an exporter omission: split Julia owners inherited their declared CPU layout
without the original `--pin-cpus` option. Export now preserves that explicit
option for both owners; the declared placement check remains unchanged.

With both fixes, installed JFG passes readiness/placement and completes 554
valid batches with 1108 associated exposures and confirmed restoration. Its
exact-result assertion fails: 380 of 208,304 slope values differ from installed
FGN, with maximum absolute difference 0.0177964 pixels. Non-value response
metadata matches. The qualifier asserted before terminal-report capture and
manual stop, so automatic cleanup with launcher exit zero is established, not
the planned normal terminal workflow. Common scientific sources, HIL manifests
and shared parameter bytes match. Same detector seed alone does not establish
identical ADC frames; raw-input capture/replay is the pending discriminator.
No algorithm or noise root cause is claimed.

A short installed FGN diagnostic retains each raw UInt16 detector frame and
its individual slope, flux and validity outputs. The first four actuator
push/pull pairs preserve the full plan's order, settling and averaging rules:
eight accepted batches, sixteen accepted exposure IDs and twenty-five total
exposures including restoration. Its batch values match the full FGN run.
Receipt identities, durations, payload extents and hashes are independently
checked; normal release, stop and quit complete with observed child exits zero.
Recording occurs after completion and before another exposure can be armed,
outside callbacks. Its elapsed time is not a performance measurement.

Two short JFG attempts fail link admission during format negotiation before
any exposure. Public snapshots
show matching format declarations and the graph output Format, while the
collector input Format remains empty. They do not show buffer allocation.
The creator's last `Init` state and an observer's `Negotiating` state follow
native notification behavior; they do not establish a lost callback.

A targeted run with existing native debug topics and unchanged budgets passes
the short JFG workflow, including the terminal report and normal stop/quit.
Parent wait records show all five child exits zero. All twenty-five raw frames
and corresponding individual slope, flux and validity payloads are bit-identical
to FGN. Separate full acquisition UUIDs remain distinct; matching local sequences
are not claimed as a shared domain. This verifies processing parity for the
same inputs in the short sequence, including the exposure positions of the
earlier full-run first difference. It cannot identify the earlier run's cause.

The native trace locates a 455.5 ms gap inside the collector's first capability
callback; subsequent Format handling takes about 7 ms. The complete link takes
about 476 ms against its unchanged 500 ms deadline. A fresh Julia 1.12.7 process
with the exact ThreadLoop, collector type and UInt32/Pod signature measures
473.74 ms for its first handler call, including 473.73 ms compilation; its
second call takes 4.98 µs with no compilation. The ignored parameter workload
changes neither endpoint state nor callback error. This directly demonstrates
the compilation cost; no GC or scheduler root cause is inferred.

PipeWireAO.jl now compiles that exact handler during endpoint construction,
before `connect!`, inside existing cleanup handling. It does not execute the
format handler, mutate native parameters or change the public API. This setup
cost can block the owner's ThreadLoop during preparation; it is not a guarantee
for adding endpoints to an already active real-time session. The focused helper
and private-core checks pass 151 and 133 assertions. A fresh native short run
passes the normal public workflow: the collector capability gap falls to
29.79 ms and link admission to 47.95 ms, against the same 500 ms deadline.
The first offline handler call now takes 5.45 µs with zero compilation.
All twenty-five ADC and individual WFS payloads still match FGN, and all five
child exits are zero. The remaining native gap is not individually attributed.
Logging and synchronous recording affect timing; these are startup and
functional checks, not camera-to-DM latency measurements. No science change,
timeout extension or buffer-lifetime change is made.

Both current full installed runs then pass with native debug logging disabled.
Each retains all 1663 raw frames and individual WFS outputs, accepts 554 batches
with 1108 measurement exposure IDs, restores at sequence 1663 and completes the
normal released-owner report and public stop/quit workflow. Parent wait records
show all three FGN and all five JFG child exits zero, with no owned process or
runtime instance remaining. Every raw ADC, slope, flux and validity payload
matches between runs, as do all 208,304 accepted response values and their
associated local receipt metadata. Complete acquisition UUIDs are distinct.
Both complete Rust results have the original `ab308df…7432` hash above.
The packaged AOC 0.17 public estimator produces bit-identical 376 × 277
Float32 interaction matrices, 416608 bytes each, with the original
`b5115a79…e89b` hash above. Inactive rows remain zero.
This closes the current installed functional and identical-input agreement
gate. It does not identify the earlier run's unrecorded input or explain its
380 differing values, and it does not establish calibration repeatability
under independent noise. Synchronous recording makes elapsed times diagnostic.
The FGN package retains the earlier listener-startup server variant; JFG uses
the admission-aware fix. This declared setup difference does not change the
scientific owner, acquisition or graph parameters. Entire source packages
are not claimed identical. The current common server implementation has the
separate 241-assertion regression check and installed JFG workflow evidence.

This establishes installed FGN functional acquisition; it does not establish paced
readout performance or acceptance of a reconstructor.

Software checks: 133 live-feature Rust workspace tests pass with three ignored;
formatting and all-target Clippy pass. Python deployment checks discover 132
tests with two unselected generator matrices skipped. Current AOC client checks
pass 24 assertions, the bounded server 241, acquisition validation 31, generic
transport helper 151, and the HIL adapter suite 1210. Independent reviews cover
ownership, restoration, processing parity and the noise calculation. These are
software and simulated endpoint checks, not physical-instrument validation.

Machine-readable source/record identities are in
[the acquisition evidence summary](CALIBRATION_ACQUISITION_EVIDENCE.json).
Raw captures, complete responses, commands and independent reviews are retained
under `~/.cache/rtc-event-calibration-20261002/`.

Still required: explanation of the earlier installed discrepancy; automatic
dark/flat/reference campaign; precision and observability policy; explicit
composition with the 221-coordinate VDM/controller maps; selected AOC
reconstructor and closed-loop correction; Copper and unchanged HEART endpoints;
accelerator and cadence validation. Trimming 277 physical columns to 221 is
invalid. Inactive measurement rows must be selected before a covariance solve,
then embedded as zero reconstructor columns. Sixteen flat exposures also limit
the centered empirical covariance rank to at most 15, even after selecting the
368 eligible measurement positions. A covariance-aware reconstructor needs an
accepted noise model/regularization or sufficient independent data; removing
zero rows alone does not make the full covariance positive definite.

The native client must load the fixed library at the selected prefix. Merely
selecting `/opt/pipewireao` for the daemon does not override a released JLL
client. These checks use an explicit artifact override plus library path; a
published artifact-only deployment remains a separate release gate.
