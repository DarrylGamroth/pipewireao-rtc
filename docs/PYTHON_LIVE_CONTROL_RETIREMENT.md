# Python live-control CLI retirement

Historical status: scoped CLI retirement at RTC commit `eca7b0cff1edf3db6a39fb84714615bfa39d51e3`

This record describes the earlier CLI retirement, not the current checkout.
All Python files were removed on 2026-10-08; the old coordinator is also retired.
The [source before removal](https://github.com/DarrylGamroth/pipewireao-rtc/tree/6b893b7e98e474580f53ff913751963b62f8db2a/deployment)
preserves those implementations. Use the [current Julia guide](JULIA_DEPLOYMENT_USAGE.md)
for maintained tools. Statements and verification below refer to the recorded
revision.

The operational deployment and calibration CLI entrypoints use Julia. Direct
Python commands that started or controlled a live RTC stopped with a diagnostic
before creating runtime/output paths, opening sockets, or reading deployment
state. The Julia entrypoints named by each diagnostic were present at that
revision.

## Retired direct entrypoints

| Python entrypoint | Rejected direct command | Julia entrypoint at that revision |
| --- | --- | --- |
| `deployment/deploy.py` | `run`, `control` | `deployment/julia/deploy_cli.jl` |
| `deployment/check_profile.py` | live profile qualification | `deployment/julia/deploy_cli.jl` for deployment control; no Julia counterpart for this focused check |
| `deployment/check_properties.py` | live property/lifecycle qualification | `deployment/julia/deploy_cli.jl` for deployment control; no Julia counterpart for this focused check |
| `deployment/check_hil.py` | live HIL qualification | `deployment/julia/deploy_cli.jl` for deployment control; no Julia counterpart for this focused check |
| `deployment/check_heart_failure.py` | live HEART failure injection | `deployment/julia/deploy_cli.jl` for deployment control; no Julia counterpart for this focused check |
| `deployment/calibration_campaign.py` | live calibration campaign | `deployment/julia/src/calibration_campaign.jl` |
| `deployment/hil/heart_owner.py` | live HEART owner service | `deployment/julia/src/heart_owner.jl` |

For `deployment/deploy.py`, `preflight` and `install` remain available. Its
Python `Deployment.run`, public broker, control client and source coordination
methods remain importable for development fixtures and historical evidence
reproduction; they are not active CLI paths. The qualification functions,
calibration campaign client/workflow, and Python HEART owner classes also
remain importable for their existing unit fixtures. This retirement does not
claim those legacy implementations have been deleted or made safe as callable
Python APIs.

## Preserved data and tooling

No saved JSON, report, configuration, provenance, offline conversion, or
exporter behavior is retired here. Existing exporters can still construct
historical descriptors containing old control fields; the current production
Julia deployment profile rejects incompatible live owner descriptors. Tests
may continue to exercise their fixtures through imports.

The in-repository JSON socket helpers `Deployment.fixture_socket_control` and
`Deployment.fixture_serve_control`, `OwnerProtocol.control!`, and
`CalibrationServer.serve!` remain test-fixture support. Production Julia
supervisor control uses the native supervisor client/dispatcher. Production
calibration owners use `NativeCalibrationActions.serve!`; it has a `serve!`
name but uses the native endpoint rather than JSON sockets.

## Verification

`deployment/test_retired_live_cli.py` runs each retired command in a subprocess
with a socket-construction sentinel and disposable paths. It checks for the
diagnostic, confirms that paths and sockets remain untouched, verifies that
Python offline deploy commands are still present, and imports the fixture APIs.
It does not start a PipeWire daemon, run Julia or Rust, or exercise scientific
owners.
