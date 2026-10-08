# Separate systemd owner services: evidence

Status: **selected installed parity gates passed**, 2026-10-07. Scientific
scope is Copper complete-frame CPU FGN/JFG with CUDA AOS, non-actuating.
Implementation is `c088103`, based on clean `dde0bf4` in
`work/systemd-owners-20261007`. See the [design](../../SYSTEMD_OWNER_DESIGN.md),
[independent review](REVIEW.md) and [sealed evidence](evidence.json).

## Ownership and changes

systemd user services own process creation, lifetime, cgroups and reaping.
WirePlumber owns the three declared external links. The headless RTC retains
native readiness, preparation, source hold/release, reset and admission
revocation. GUI/CLI controls and scientific algorithms remain unchanged.
The default direct backend remains supported for foreground operation and
profiles not qualified by this transfer.

Failure checks exposed and corrected exact cleanup-hook validation, consumer
teardown before confirmed ingress revocation, stale-incarnation discovery on
restart, failed-report overwrite by duplicate exit cleanup, and Julia's default
temporary-directory deletion of retained diagnostics. Original failed gates
remain recorded; no fault-time source acknowledgement is inferred from cleanup.

## Installed matrix

| Check | CPU FGN | CPU JFG |
| --- | --- | --- |
| Required core loss | [Final pass](final-installed/fgn-core/receipt.json), failed/unadmitted report, diagnostic directory survives exit | [Final pass](final-installed/jfg-core/receipt.json), same |
| Required simulator loss | [Pass](initial-installed/fgn-simulator/receipt.json) | [Pass](initial-installed/jfg-simulator/receipt.json) |
| Required WirePlumber loss | [Pass](initial-installed/fgn-manager/receipt.json) | [Pass](initial-installed/jfg-manager/receipt.json) |
| Required RTC runner loss | [Pass](initial-installed/fgn-rtc/receipt.json) | [Pass](initial-installed/jfg-rtc/receipt.json) |
| Required Julia graph-owner loss | No separate Julia graph owner | [Pass](initial-installed/jfg-julia/receipt.json) |
| Abrupt coordinator loss | [Pass](initial-installed/fgn-coordinator/receipt.json) | [Pass](initial-installed/jfg-coordinator/receipt.json) |
| Fresh whole-session restart | [Final pass](final-installed/fgn-restart/receipt.json): two incarnations, four runs, 2,048 commands | [Final pass](final-installed/jfg-restart/receipt.json): same |

Each final incarnation exercises held source discovery, native stop/reset/start,
exact native owner PID binding to systemd MainPID, actual warmed thread
placement, negotiated WirePlumber-owned links, repeated complete runs and clean
shutdown. Restart changes both coordinator InvocationID and deployment UUID.
Every final run delivers all 512 frames and commands. Its retained 256-frame ADC
and command prefixes equal its own accepted foreground baseline byte for byte.
Across four runs per engine, all 1,024 post-prefix measured simulator exchanges
report zero heap bytes, allocation counters, GC pauses/time and full sweeps.
These are per-engine comparisons, not a new bitwise FGN/JFG equivalence claim.

The independent initial fault audit confirms closure of all 50 recorded owner
units across 11 distinct fault cases, no queued starts and CPU0/1 exclusion in
267 warmed thread records. Final receipts additionally retain each owner's
observed terminal unit state and recursive cgroup-empty check. Two initial
coordinator SIGKILL reports remain stale running/admitted artifacts: cleanup is
established by live manager/cgroup evidence, never those files. Earlier JFG
restart also passed [2,048 commands](initial-installed/jfg-restart/receipt.json).

## Source and dependency identities

The [FGN](final-installed/fgn-package/systemd-refresh.json) and
[JFG](final-installed/jfg-package/systemd-refresh.json) packages refresh only
the orchestration SDK. Their sealed non-SDK files are unchanged from
`/tmp/rtc-wp-realization-fgn-20261007-retry4` and
`/tmp/rtc-wp-realization-jfg-20261007-attempt1`; all 68/67 provenance SHA-256
leaves respectively match those bases. The selected plant, simulator source,
graphs, calibration arrays, native runner and WirePlumber binaries retain their
accepted identities. Both installed `deploy.jl` and `systemd_owners.jl` match
committed source bytes. Full descriptors, provenance, SDK file hashes, per-case
receipts and journals are archived; bulk frame/command binaries are omitted.
Baseline prefix hashes are sealed in `evidence.json`.

The required WirePlumber POD-filter capacity fix remains isolated at `4c2648fa`;
its library is frozen in these packages. No upstream repository is pushed.
User manager is systemd 257.13, with RT-priority/memlock limits 95/4 GiB.
`CPUAffinity` and actual per-thread placement are checked; this host does not
provide an enforced delegated cpuset via `AllowedCPUs`. Whole-process FIFO is
not enabled. Qualification allows 900 seconds for cold startup; generated units
retain their 600-second default. No startup-time performance claim follows.
Existing GUI service `pipewireao-gui-hil-demo-hIo0tX.service` remained active at
MainPID 1632744; desktop and HEART processes were untouched.

Initial receipts predate the additive final-unit and retention assertions.
Their `coordinator_sha256` field hashes the on-disk qualification script at case
creation. Final receipts use a module-load `qualification_source_sha256`; the
production SDK stayed frozen within each series. Initial fault evidence is
reused for unaffected process/ingress clauses after the one-line runtime
retention correction; both final core-loss checks exercise that correction.

## Software verification and reproduction

[Focused tests](focused-tests-final.log) pass **215/215** assertions, including
CLI/template/SDK copy, exact identity, unknown revocation, terminal report and
actual subprocess-exit retention. [Private unit probes](unit-probe.md) and
[adversarial probes](https://github.com/DarrylGamroth/pipewireao-rtc/blob/6b893b7e98e474580f53ff913751963b62f8db2a/docs/validation/systemd-owners-20261007/investigate.jl) exercise descendant closure, abrupt
coordinator death, queued-start cancellation, an accepted launch with an unknown
client result, and rejection of observed replacement incarnations. The review
retains SOR-06–09 fail-before/pass-after evidence and unsupported authority
boundaries. Arbitrary same-user unit-name replacement is not an atomic safety
fence; automatic independent owner restart is disabled.

Use the committed Julia qualification entrypoint with fresh output paths:

```bash
julia --startup-file=no --project=deployment/julia \
  deployment/qualify_systemd_owners.jl \
  INSTALLED_PACKAGE FRESH_RUNTIME FRESH_EVIDENCE BASELINE_RUN restart
```

Other selected cases are `core`, `simulator`, `manager`, `rtc`, `julia` (JFG only),
`coordinator` and `clean`. The entrypoint pins its own threads to CPU6, creates
only private unique units, and removes its unit files after preserving evidence.

## Main integration

Clean canonical main fast-forwarded to `a010975`. Its focused SDK regression
passes [215/215 assertions](merged-main-focused.log);
[the integration record](main-integration.json) binds that check to the unchanged
qualified implementation. No additional scientific or timing claim follows.

## Limits and reuse

These checks qualify the selected process-supervision/link-owner composition
and native lifecycle. Heap/GC evidence is for the simulator's inclusive tails;
whole RTC process allocation, deadline/tail latency, maximum offered rate,
Classic/row profiles, general multiple-endpoint AOS and physical actuation are
separate. Abrupt cleanup does not establish graceful source pause or scientific
completion of in-flight work. Existing scientific, calibration and foreground
passes retain their original scopes; this transfer does not reacquire or
relabel them. Direct-mode and graph-internal link code still have supported
callers and are retained.
