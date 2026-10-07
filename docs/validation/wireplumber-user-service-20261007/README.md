# Optional WirePlumber user-service qualification

Date: 2026-10-07, America/Vancouver. RTC base `c49139f`; dedicated branch
`feat/wireplumber-user-service-20261007`. This increment adds an optional observer
beside the existing installed RTC user service. The SDK supervisor retains the
private core, required scientific owners, admission, native controls and every
link. Upstream WirePlumber and all scientific packages are unchanged.

## Selected configuration

- Existing installed Copper packages from the [live-update baseline](../live-artifact-updates-20261006/README.md):
  CPU FGN or CPU JFG, CUDA AOS, SDK 0.6.17, Julia 1.12.7.
- PipeWireAO `/opt/pipewireao`, source `29da2d6`; upstream WirePlumber 0.5.18,
  source `bdc17eb`, built through the already-qualified private AO selection.
- Non-actuating complete-frame exchange: 100 Hz wall pacing, 2 ms model period,
  512 exchanges per RTC incarnation, first 256 retained. Truth diagnostics off.
- Observer/preparer and development coordinator on CPU6, non-RT. The unchanged
  RTC packages admit their recorded thread placement; CPU0/1 remain excluded.
  No desktop services, host scheduling or power policy were changed.

The installer copies the qualified executable, libraries, modules, Lua scripts,
preparer and upstream license notices to a fresh companion prefix. Runtime
library selection resolves the companion and `/opt/pipewireao`, without needing
its build or repository worktree. A separate fresh installation check confirmed
resource completeness and preserved the WirePlumber and bundled Lua notices.
This is a private companion installation, not an SDK release/registration or a
WirePlumber release recipe.

## Observed results

Final results are in the executor receipts below. Each selected executor runs
two RTC incarnations through the same gates:

1. Start the existing RTC user unit; query fresh native admission and its exact
   active MainPID. Stop/reset acquisition, then start the observer.
2. Observe six ports and three RTC-owned links by exact ID/serial and negotiated
   NDArray contracts. Reset with the observer present; the source stays paused
   at sequence zero and the observer identity stays unchanged.
3. Begin acquisition and pause before the retained prefix completes. Stop/start
   the observer, then SIGKILL it. Verify `Restart=no`, remove its RuntimeDirectory,
   restart it explicitly, and check unchanged RTC cohort, source cursor and link
   identities/owners. Resume and finish 512 detector frames and 512 DM commands.
4. Request an actual RTC restart while the observer is active. `PartOf` restarts
   WirePlumber automatically after the new RTC is admitted. The qualifier does
   **not** manually start or repair the observer in this second incarnation.
   Require new RTC PID, native UUID and observer PID, and removal of the old
   confirmed process groups. Repeat the complete exchange and observer gates.
5. SIGKILL the entire final RTC service cohort. `BindsTo` stops the observer;
   both RuntimeDirectories and service cgroups are empty. Remove only the
   qualifier's unchanged instance unit files and clear their failed states.

Each retained detector/DM prefix matches its corresponding independent baseline
and the other RTC incarnation exactly. Each simulator's final 256 exchanges
report **0 Julia heap bytes, 0 GC pauses and 0 GC time**. This measured scope
includes simulator optics, transport, recording and diagnostics; final report
serialization is excluded. Observer lifecycle checks happen in the retained
prefix, so these counters do not measure those control operations or all RTC
processes.

| Gate | CPU FGN | CPU JFG |
| --- | --- | --- |
| Two complete incarnations | PASS: 512 frames/commands each; [receipt](fgn-receipt.json) | PASS: 512 frames/commands each; [receipt](jfg-receipt.json) |
| Automatic observer restart after actual RTC restart | Second `observer_start.start_requested = false` | Second `observer_start.start_requested = false` |
| Exact baseline/reset prefixes | Both frame/command SHA-256 checks | Both frame/command SHA-256 checks |
| Measured simulator tail | 256 exchanges per incarnation, 0 B / GC0 | 256 exchanges per incarnation, 0 B / GC0 |
| Final cohort exit and owned cleanup | Receipt and [RTC journal](fgn-rtc.log) | Receipt and [RTC journal](jfg-rtc.log) |

Focused cold checks pass **33/33 service boundary assertions** and **9/9 topology
assertions**. They reject unsupported roles/profiles, wrong descriptor/locator
owners, changed MainPID/cohort/native UUID, changed link identities/contracts,
and stale executable configuration after failed preparation. Generated user
units pass `systemd-analyze --user verify`.
The [independent final review](REVIEW.md) found no blocker within this scope.

## Reproduction and retained evidence

Install the companion as described in [the service README](../../../deployment/wireplumber/README.md#optional-user-service).
The development qualifier requires fresh evidence, unique private instance names
and an independently qualified baseline receipt:

```sh
taskset -c 6 env JULIA_PKG_OFFLINE=true OPENBLAS_NUM_THREADS=1 \
  JULIA_NUM_THREADS=1,0 julia --startup-file=no --compiled-modules=existing \
  --project=/path/to/installed-package/julia \
  deployment/qualify_wireplumber_service.jl \
  /path/to/installed-package /path/to/installed-companion /tmp/fresh-evidence \
  wp-fgn-unique docs/validation/live-artifact-updates-20261006/fgn-baseline-receipt.json
```

Use `wp-jfg-unique` and the corresponding JFG package/baseline for JFG. Cold checks:

```sh
julia --startup-file=no --compiled-modules=existing \
  --project=/path/to/installed-package/julia \
  deployment/wireplumber/test_service.jl \
  --deployment /path/to/installed-package/deployment.conf
julia --startup-file=no --compiled-modules=existing \
  --project=/path/to/installed-package/julia deployment/test_qualify_wireplumber_hil.jl
```

The receipts retain exact native identities, placement, controls, source
summaries, prefix hashes, unit states and cleanup outcomes. Journals, companion
installation records, generated observer units and installed library selection
are retained beside them. Raw prefix payloads were independently hashed in the
original `/tmp/rtc-wp-service-*-evidence-*-20261007/run-*` directories; they are
not duplicated into Git. Saved reports do not establish live readiness.

[Source hashes](source-sha256.json) identify the operational helpers and final
qualifier. The [JFG tested coordinator](jfg-tested-coordinator.jl) has its exact
receipt hash. The only difference from the final FGN coordinator is the added
pre-launch refusal of already-loaded unit names; it does not change lifecycle
checks. Both copied installations use the same current operational source.
Earlier FGN smoke trials passed but did not independently distinguish automatic
restart from a manual observer start. Only the final receipt is used for that
claim. No failed scientific or delivery gate was waived.

## Limits and remaining gates

- This observes one Copper exchange with `simulator` and optional `julia` roles.
  Other deployment profiles and general multiple-source/sink AOS sessions are
  rejected or remain unqualified.
- RTC READY follows source release. `After` provides post-admission service
  ordering; held discovery here occurs after explicit native stop/reset and
  does not demonstrate observation before initial source release.
- `Type=simple` active state does not prove observer readiness. Its current
  invocation's `HIL_COHORT_READY` journal marker records completed discovery.
  Loss is reported without reconnecting by name or authorizing science.
- The unexpected-exit gate kills the whole RTC cohort. It does not newly qualify
  isolated AOS/JFG owner loss or independent scientific-owner user units.
- Exact equivalence is limited to retained 256-frame prefixes; full 512-exchange
  numerical equivalence is not claimed. Detector ADC rails and other scientific
  fixture properties retain their original baseline scope.
- These are functional lifecycle/allocation checks with deliberate pauses and
  cold preparation. Recorded timing counters are not a latency, startup-time,
  deadline, maximum-rate, GPU-allocation or physical-loop qualification.
  Existing SDK cold preparation still emits package precompile/version notices
  and the optional D-Bus support warning; these are preserved in the journals
  and precede the admitted exchanges.
- Connection policy, link ownership transfer, release integration and separate
  owner units retain the [architecture review gates](../../APPLICATION_ARCHITECTURE_REVIEW.md).
