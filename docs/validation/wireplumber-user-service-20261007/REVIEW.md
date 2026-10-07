# Independent service review and disposition

Date: 2026-10-07. Read-only reviewer: `/root/wp_service_review`, Sol, high
reasoning effort. Primary agent retained architecture, integration and final
verification responsibility. Review covered the changed operational source and
qualifier; the reviewer did not launch or modify operational processes.

## Findings addressed during development

These were qualification/cleanup gaps in the development harness, rather than
confirmed scientific or transport defects. All had high confidence from source
inspection; no failed scientific acceptance was waived.

| ID | Severity | Evidence / affected code | Remediation and validation | Disposition |
| --- | --- | --- | --- | --- |
| WPS-01 | Major qualification gap | `qualify_wireplumber_service.jl` originally compared restart prefixes only with each other | Require an independent descriptor-matched baseline receipt and its prefix hashes; final FGN/JFG payload files and baseline payload files independently rehashed | Addressed |
| WPS-02 | Major qualification gap | A manual observer start in the second cycle could repair failed PartOf propagation | Actual RTC restart with observer active; cycle 2 calls `observe(...; start=false)` and records that no start was requested | Addressed in final strict receipts; earlier FGN smoke runs excluded from this claim |
| WPS-03 | Moderate qualification gap | Reset initially happened only before observer attachment | Reset again with observer present; assert generation advance, paused sequence zero and unchanged observer PID | Addressed in both cycles/executors |
| WPS-04 | Moderate qualification gap | Service identity checks lacked discriminating cold rejection tests | Test wrong locator/descriptor owner, changed MainPID/cohort/UUID and removal of old executable config after preparation rejection | Addressed; 33 cold service assertions pass |
| WPS-05 | Moderate evidence gap | Final journal collection could throw before preserving the primary receipt | Capture journal errors in the receipt, mark failure and always write the primary result | Addressed by source review; normal final journal capture succeeds |
| WPS-06 | Moderate cleanup gap | Partial user-unit installation could leave a file outside tracked cleanup | Track each successfully written file immediately; compare exact contents before removing only owned files | Addressed by source review; final owned-unit cleanup succeeds |

Additional design concerns were adjudicated in the
[service design](../../../deployment/wireplumber/SERVICE_DESIGN.md): exact
MainPID/native identity, bounded subprocesses, supported role restrictions,
post-release ordering, observed negotiated formats rather than independent
scientific admission, separate companion installation, private library selection
and removal of stale executable configuration.

## Final verification

The independent reviewer checked current production source, copied installation
resources, final receipts, both retained payloads in each incarnation, baseline
receipts and the baseline payloads. The reviewer observed:

- FGN and JFG each complete two 512-frame/command incarnations.
- Every retained detector/DM payload SHA-256 agrees with its report, receipt and
  independent baseline. Reset prefixes agree within each executor.
- Cycle 2 records `start_requested=false`, with fresh RTC/observer identities.
- Each 256-exchange simulator tail records 0 heap bytes and 0 GC pauses.
- Owned cleanup succeeds and the final receipts have no failure fields.
- Installed service/session/Lua/template resources equal current source bytes.
- FGN's coordinator hash matches current source. JFG's hash matches the
  [retained tested snapshot](jfg-tested-coordinator.jl); the only later difference
  is refusal of already-loaded user-unit names before starting the fixture.

**Disposition:** no confirmed source or qualification blocker remains for this
optional Copper observer scope. The primary agent also recomputed the final
payload, baseline-receipt and coordinator hashes and checked inactive unit state.

This review does not establish latency, deadlines, isolated scientific-owner
failure, general multiple-endpoint admission or link/process ownership transfer.
Those boundaries remain explicit in the [qualification](README.md#limits-and-remaining-gates).
