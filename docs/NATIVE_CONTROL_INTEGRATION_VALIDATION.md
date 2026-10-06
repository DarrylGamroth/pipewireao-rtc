# Native control integration checks

2026-10-06, RTC-ARCH-024 / RTC-DEV-030. Integration branch
`work/native-control-planes-20261005` combines the reviewed acquisition owners,
native calibration actions, optional observation boundary and public supervisor
codec. These checks do not establish installed qualification or issue closure.

## Combined source checks

| Check | Revision and result | Scope |
| --- | --- | --- |
| Deployment and observation | `c4c47ee`: 531 assertions in 14 test sets passed | Acquisition descriptors/callers, runner coordination, deployment installation and relocation, interruption, exact optional identities, retirement/cleanup and public loop selection |
| HIL options | `c4c47ee`: 108 assertions passed | Complete-frame options, typed source controls and native HEART controller identity |
| Finite and sustained accounting | `c4c47ee`: 132 assertions passed | Model/wall pacing, all-retained finite accounting, truth storage, ADC quantization and synthetic scheduler boundaries |
| Export assets and supervisor codec | `9055db3` plus the action-helper export change: 494 assertions in 27 test sets passed | Fresh calibration helpers, HEART export selection and exact typed supervisor codec/capacity checks |

The observation merge retains native HEART and acquisition coordination. Test
fixtures include both optional observation storage and native HEART storage;
neither resource replaces the other.

Calibration and HEART calibration exporters now copy
`hil/native_calibration_actions.jl` from the selected SDK, along with the current
lifecycle and action owners. An older HIL base cannot supply the action adapter
implicitly. The export regression compares its bytes with the current resource
and checks the HEART helper inventory. The isolated exporter fixture also binds
the actual native action client used by the campaign module.

## Evidence and limitations

Commands used Julia 1.12.7 on CPU 15 with `--startup-file=no` and
`--project=deployment/julia`. HIL suites run in fresh Main-scoped processes, as
required by their production-closure fixtures. Cold work shared that CPU with
independent reviews. No timing-isolation conclusion follows from durations.

Logs are retained under `~/.cache/rtc-live-controls-20261005`:

- `observation-native-integration-root-20261006.log`
- `observation-native-owner_protocol-root-main-20261006.log`
- `observation-native-sustained_run-root-main-20261006.log`
- `native-action-export-assets-root-final-20261006.log`

Rejected harness runs are preserved separately: isolated HIL modules did not
provide the Main bindings expected by the scheduler fixture, and the exporter
fixture initially lacked the new native action client binding. These failures
are distinct from scientific runtime failures. The latter fixture is corrected
and passes in the final export run. Julia emitted the existing loaded versus
precompiled Base64 version notice; all selected final checks exited successfully.

The [action endpoint review](NATIVE_CALIBRATION_ACTION_ENDPOINT_REVIEW.md)
records a confirmed foreign-controller retirement defect awaiting remediation.
The [supervisor review](NATIVE_SUPERVISOR_CODEC_REVIEW.md) leaves production
endpoint, caller and deadline integration open. The
[observation ledger](LIVE_OBSERVATION_VALIDATION.md) retains its controlled FFTW
wisdom qualification and unresolved default cold reproducibility, Julia reader
and selected GUI gates. Installed science, inclusive frame allocations,
cadence, latency, accelerator and physical-device validation remain separate.
