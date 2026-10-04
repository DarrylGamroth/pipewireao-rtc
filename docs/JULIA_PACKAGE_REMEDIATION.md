# Julia deployment package remediation

Baseline: `bce24a8d953a694b4c98da3d9df1d116c2716fb6`, branch
`work/deployment-package-20261003`, initially clean task worktree
`pipewireao-rtc-package-fixes`. Prior migration results remain historical;
this record qualifies the package conversion separately.

## Deployment structure

`PipeWireAODeployment` v0.1.0 has a stable UUID, standard `src/` module entry,
ordinary `using` loading, a test workspace and a committed application lock.
The outer CLI paths remain compatible. Exported SDKs carry source, project/lock,
CLI, test-workspace closure, CPU-layout assets and embedded deployment resources.
Operational resource paths and source identities are resolved from the loaded
package at call time, so precompilation does not retain a checkout path.

Deployment continues to supervise the existing FGN/JFG and unchanged native
HEART owners. Algorithms, calibration math, gains, scientific acceptance, CPU
placement policy and scheduler settings are preserved. User systemd units use
the same sealed launcher as foreground deployment; installation generates a
unit without enabling or starting it. Operational commands remain Julia.

## Corrections established during qualification

- The previous `Parameter` outer constructor overwrote Julia's generated method;
  named loading exposed a precompilation failure. An explicit inner constructor
  preserves conversion behavior and tuple-shaped input.
- Installation used the caller's service template despite preserving the
  incoming SDK's sealed template. The same marker invariant failed before and
  passed after selecting the SDK's embedded template. Incomplete SDK resources
  now reject admission before copying.
- A copy-destination guard admitted nesting under recursively copied HIL and
  template sources. Nonmutating path checks established that admission defect;
  the guard now protects every copied source tree before filesystem mutation.
  Unrelated output directories remain supported.
- Generated `julia -e` CLIs lost a positional argument that had separated Julia
  flags from application flags. An installed export failed with Julia's
  `unknown option --base-package`. Generated CLIs now delimit arguments with
  `--` and propagate their owner's exit status. Explicit CLI success returns
  preserve output while supporting that exit contract.

Legacy include-loaded sealed SDKs are preserved and require their original
launcher or a fresh export. They are rejected by the named-package installer;
installation does not rewrite sealed source to silently change formats.

## Verification and limitations

Julia 1.12.7 qualification passed on the selected CPU deployment:

| Check | Result |
| --- | --- |
| Fresh precompilation and portable package tests | 511 assertions passed (343 original, 168 new) |
| Executable CLI invariant | Failed against preserved SDK, passed against fresh wrappers |
| Installed operational source closure | All 47 hashes match reviewed source |
| Installed CPU exports under restricted PATH | Classic/Copper × FGN/unchanged HEART; four passed, no Python execution in retained export traces |
| HEART foreground and systemd user lifecycle | Four routes; each two exact 16-frame/command batches, stop/reset/restart, clean owned-process and runtime removal |
| Systemd ownership | Admitted Julia MainPID matched; exit 0, result success, inactive/dead and MainPID 0 |
| Finite Copper calibration endpoints | FGN/JFG eight-frame dark captures; release/restoration/shutdown confirmed, launcher exit 0, sealed package identity preserved |

The finite endpoint checks intentionally reuse the previously sealed scientific
bases. They qualify the new installed supervisor and acquisition boundary;
they do not constitute a new interaction-matrix campaign. The unchanged HEART
executable is native, without a runtime build container. All checks preserve
unowned GUI sessions and host policies; configured CPU envelopes exclude CPUs
0 and 1. Unique test services were linked solely for these checks, not enabled
for automatic startup.

Evidence cache: `~/.cache/rtc-package-remediation-20261003`. The committed
[evidence ledger](JULIA_PACKAGE_REMEDIATION_EVIDENCE.json) binds exact sources,
reports, producer harnesses and logs, including retained failure evidence.
[Independent review](JULIA_PACKAGE_REMEDIATION_REVIEW.md) records findings and
verification. Usage is in [the deployment guide](JULIA_DEPLOYMENT_USAGE.md).

Startup logs retain optional DBUS/mixer/format warnings and Julia precompilation
messages about already loaded versions. Exact delivery and lifecycle gates
passed, but these results do not establish quiet caches or startup latency.
Finite re-export also reports absent Git metadata in the installed SDK; source
and artifact identity is established by sealed file hashes rather than an
inferred Git revision.

CPU software, installed exchange and lifecycle checks are distinct from
interaction-matrix precision, scientific correction acceptance, physical
instrument operation and GPU cadence. This packaging increment does not close
those scientific or accelerator gates. It does not publish registry releases.
