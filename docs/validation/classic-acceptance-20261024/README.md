# Classic acceptance — 2026-10-24

This record closes the three Classic acceptance gates in the roadmap for the
selected local CPU deployment. It curates bounded receipts and test summaries;
the source receipts, full journals, CSV samples, application tree and GUI build
logs remain at `/home/dgamroth/.local/state/pipewireao/classic-acceptance-20261024/`.

## Outcomes

- **GUI observation:** the production native adapter, client model and view panel
  passed the hidden-SHWFS/X–Y-history/reconnect scenario. With WFS visible, the
  observation accumulated 32 trajectory points and saw 30 WFS groups. After
  hiding WFS, it saw no further WFS groups or full WFS frames while the trajectory
  continued from 33 to 64 points. Closing and reopening the observer reconnected
  at generation 2 and accumulated 32 new points. This was voluntary observer
  detach/reopen; it did not inject remote failure or exercise RTC commands. The
  canonical GUI change is `c7ee423ee2502909bfabc6afb23a9fbc8504ef46`.
  Formatting, Cargo tests, WASM check and Julia script tests passed. Clippy passed
  with the documented baseline exclusions; unfiltered Clippy still reports four
  unchanged `chunks_exact_to_as_chunks` findings.
- **Paired wavefront RMS:** a sustained 120 s observation at a 5 ms drive interval
  captured 2,312 distinct owner-published `F32_LE` frames at the declared
  `pipewireao/pupil-opd-rms-nm-f32/1` schema (20 Hz stream). The qualification
  summary contains 2,313 paired callback samples; this one-sample difference is
  the observer snapshot versus retained callback-pair count at teardown. Mean
  pupil OPD RMS changed from 281.686 nm to 51.575 nm, an 81.69% reduction. The
  simulation modeled 80.66 s while wall time was 128.94 s; cold startup dominated
  elapsed time. These results use a seeded simulated atmosphere and provisional
  Gaussian DM calibration. They are a software simulation result, not physical
  calibration, hardware, cadence or latency qualification. The captured sample
  CSV is intentionally not copied here.
- **Ready/Quit and shutdown:** the installed CPU native runtime accepted native
  Quit and completed owned shutdown/cleanup in 29.94 s; the focused test passed
  11/11 assertions. The original native Quit timeout did not recur in this run.
  Earlier failed evidence remains historical and is not reclassified.
- **Required-link loss:** the focused actual link-removal gate passed 146/146
  assertions. Ready and Running were observed before fault; the RTC reported
  Fault after link removal. Emergency/systemd cleanup completed, followed by a
  fresh session reaching Ready and Running and completing cleanup.
- **Controller loss:** the focused actual controller-exit gate passed 40/40
  assertions. Ready and Running were observed before fault; the RTC reported
  Fault and `policy-shutdown` followed. The evidence explicitly records an
  uncertain source-hold operation (`Node operation expired; submitted outcome
  unknown`), so no successful Hold is claimed. Systemd emergency cleanup
  completed, and a fresh session reached Ready and Running and completed cleanup.
  The receipt's `source_command_timeouts` list is empty for this case; this does
  not establish absence of timeouts in other cases or universally.

## Source and deployment identity

The GUI receipt records baseline `96b94cd` and canonical GUI source commit
`c7ee423ee2502909bfabc6afb23a9fbc8504ef46`. The acceptance application was
prepared as `/home/dgamroth/.local/state/pipewireao/classic-acceptance-20261024/cpu-application`.
The fault receipts identify PipeWireAORTC `0.2.9+telemetry.20261024.final`,
PipeWireAO SDK `0.6.19+deploy.20261023.93539f3b`, runtime source SHA-256
`46575531701277c10acf91386bdccab5b1df8710f01073a4748fa2675b986418`, and
sealed deployment SHA-256
`a8c41894656aacb8f643dc75d5faa5940a69134341d93ac76bcb7e20b94d6ba4`.
Shutdown additionally records manifest SHA-256
`dadb2440daf70f0f2ed28597b2505bbc7cdf57c9cc1c47312435e52ab7b95193`; exact
native and policy file hashes are in [shutdown.json](shutdown.json). Link and
controller receipts record the installed policy hashes. The fault qualification
test-content SHA-256 is
`be57020d2726ba4b3b16d227242378b7a4fe903d666ce8bb4987b62a0450d2a7`; the
shutdown test-content SHA-256 is
`1ec97946c94c28282cca7da582df49fd0f134b2bd0258ba405905af52db908e1`.
The fault selectors are in `test/integration/session_faults.jl` (`--case
link-removal` and `--case controller-exit --controller-role julia-command`);
the Ready/Quit selector is in `test/integration/classic_shutdown.jl`. The RMS
capture program was `/home/dgamroth/.local/state/pipewireao/classic-acceptance-20261024/observe-rms.jl`,
which included `test/integration/classic_observation.jl` from the RTC source
checkout. The GUI gate command and its source/dependency checks are recorded
verbatim in [gui-validation.json](gui-validation.json).

SHA-256 hashes of the original receipts/logs are recorded below so the curated
copies can be traced to the original evidence:

| Original receipt or log | SHA-256 |
| --- | --- |
| `gui/acceptance.json` | `c8649d217f1573082d46199789ec5456af9b2053aadb1ec71a15972df9d6093f` |
| `gui/validation.json` | `a35cb44b849779563fa2003ac9d21c76fb6efba6de20f97f31d645128900c919` |
| `rms.json` | `7d443e4462d48c5b0d0aa6efd3fe943572aa90b8af045aba6f90d4520aec45a4` |
| `rms.log` | `7c557e0873e49835f1de7ac31d96fb12569cdf3e37d8467babbf9675ac7c2067` |
| `shutdown/qualification.json` | `171e0d3d8f34720357f09ba0dfdd4ce13f1dc4a9e12b7bc47067aeeff091ed5c` |
| `shutdown.log` | `f35f3fef810312410e1efcf74cae581ede01492a95bd984c80825c844942bb98` |
| `link-loss/qualification.json` | `50106229c209bf886d4a2e572e48b3333a77920ca4cd10d67241a5e01793c66d` |
| `link-loss.log` | `caeea50ad5600972c55bfffb2f1c7bb22d93c1a40df8446155128d0d83cc2eae` |
| `controller-loss/qualification.json` | `d2e03e31b33595e05345b7a928d0cdc3635bb13c6721556a37aee50c22b5a605` |
| `controller-loss.log` | `1803fd8c40dd838aa00ea09576db9a94d4ff7fb1e9a5661948cffc521655d` |

Gate summaries are preserved in [shutdown.log](shutdown.log),
[link-loss.log](link-loss.log) and [controller-loss.log](controller-loss.log).
The unfiltered GUI checks and their commands are recorded in
[gui-validation.json](gui-validation.json). Machine-readable curated receipts
are [gui.json](gui.json), [rms.json](rms.json), [shutdown.json](shutdown.json),
[link-loss.json](link-loss.json) and [controller-loss.json](controller-loss.json).

The original running CUDA RTC and GUI were left unchanged; the CPU application
and fault sessions were separate. No external service or hardware action was
performed. These gates do not qualify GPU execution, physical hardware,
real-time cadence, worst-case latency or arbitrary deployments.
