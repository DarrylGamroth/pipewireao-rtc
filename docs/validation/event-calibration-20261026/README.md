# Shared event-driven calibration — 2026-10-26

Implementation: `674559f`, based on
`b4eab3ad25021dc98ae8c40c79f4926e0ad8ccbf`; branch `codex/event-calibration`.
The source worktree was clean before this isolated increment. The instrument
monorepo and installed sessions were not modified. Validation used Julia
1.13.2 and the existing local validation environment; no generated manifest
or source override is included in the change.

## Delivered behavior

- The shared interaction-acquisition procedure advances from correlated typed
  completion events, with explicit deadline, cancellation and recovery events.
- Existing native acquisition and CLI entry points use that procedure. Online
  consumers receive causally validated candidate response batches before the
  next probe. Consumer mutation cannot change retained result storage.
- Native discovery and requests wake from callbacks and deadline timers.
  Explicit external-supervision hooks retain periodic checks. The default
  calibration path does not sleep or periodically poll for a completion.
- Unknown outcomes stop submissions. Known failures request bounded restoration
  and release; partial candidate calculations do not activate a calibration.

The [acquisition guide](../../JULIA_CALIBRATION_ACQUISITION.md) owns API usage
and subsequent delivery gates. The [independent review](../../reviews/20261026-event-calibration/REVIEW.md)
found no remaining blocking defects and independently passed the 47 procedure
assertions.

## Verification

Commands run from the shared RTC package worktree with
`julia --startup-file=no --project=.`:

| Selector | Result |
| --- | --- |
| `test/test_calibration_acquisition.jl` | 234 assertions passed: original driver, CLI, bounds, identity/exposure, clipping, cancellation, timeout and recovery checks |
| `test/test_calibration_procedure.jl` | 47 passed: online signed-pair response calculation against an independent linear sensor, exact typed replay, correlation, cancellation, invalid evidence and consumer failure |
| `test/test_native_calibration_action_client.jl` | 47 passed |
| `test/test_native_control_client.jl` | 23 passed |
| `test/test_calibration_install.jl` | 11 passed; sealed entrypoint compatibility |
| `test/native_control_endpoint.jl` | 42 private-core assertions passed, plus its 23 control-client assertions; includes discovery/request without a supervision hook and notifications after client closure |
| `test/native_calibration_action_endpoint.jl` | 17 private-core assertions passed; action retirement preserves run identity |
| `test/native_control_endpoint_faults.jl` | 23 fault assertions passed, plus its 23 control-client assertions |
| `test/native_acquisition_lifecycle_client.jl` | 74 private-core assertions passed |
| `test/test_native_session_client.jl` | 18 passed |
| `test/test_native_acquisition_lifecycle_client.jl` | 89 passed |
| `test/test_native_calibration_action_codec.jl` | 195 passed |

Cold tests were run as scripts; grouped unit selectors were also run using
`include` in a fresh Julia process. Private-core selectors create and close
their own core and never connect to the desktop core. Their owner-side test
dispatchers still use the existing polling helpers; the new client proof
specifically omits its supervision hook for discovery and the first request.

An early acquisition regression failed the first Hold deadline because cold
dynamic action dispatch occurred inside its one-second endpoint budget. A
concrete-action function barrier now prepares that dispatch before starting
the exchange budget. The same original acquisition selector then passed all
234 assertions. No timeout was increased, deadline bypassed or expected
failure removed to obtain that result.

`git diff --check` passed. The changed acquisition-guide Mermaid diagram was
rendered with the installed Mermaid CLI Podman image and produced a nonempty
SVG; temporary rendering artifacts were removed. Added relative document links
and new section anchors passed local checks. A whole-document link scan also
found the pre-existing historical `../tests/calibration.rs` link in the roadmap;
it is unchanged by this increment.

## Qualification limits

This is software and private-core protocol evidence. It does not establish
actual Classic/Copper/GPI optical acquisition, physical device operation,
settling, multi-WFS completion, multi-corrector transactions, asynchronous
recording, resource isolation or real-time deadlines. No full package suite,
GPU campaign or physical experiment was run. Instrument campaign migration
and numerical-worker/recorder overload behavior remain explicit follow-on
gates rather than completed capabilities.
