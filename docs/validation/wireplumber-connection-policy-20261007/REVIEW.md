# Connection-policy review and adjudication

Baseline RTC `e605831`; remediation worktree
`/tmp/rtc-wireplumber-policy-20261007`. Astra independently reviewed the lifecycle
and policy boundary, then Rust remediation and the development loss harness.
The primary agent checked the findings against source and live results. This
record distinguishes confirmed defects from migration prerequisites and test
limitations; it is not hardware or timing qualification.

| ID | Severity / confidence | Evidence and analysis | Disposition / validation |
| --- | --- | --- | --- |
| WPA-01 | High / high | **Observed:** deleting a required link in READY left the baseline monitor in READY without a diagnostic. Recorded link state was not consumed by periodic monitoring. | Fixed in `src/live.rs`: check captured proxy/registry presence and usable state; latch terminal failure. Same private-core test passes in READY/RUNNING; normal Stop/Start still works. |
| WPA-02 | High / high | **Observed:** external contracts used reusable IDs. **Derived:** removal followed by reuse before polling could conceal loss. | Registry removal latches invalidate the captured node/port incarnation. Replacement tests fault and preserve replacement/unrelated owners during cleanup. Exact same-ID semantics have unit evidence only; live allocator replacements had different IDs. |
| WPA-03 | High / high for transfer | **Observed:** optional WirePlumber unit starts after admitted RTC READY/source release. It cannot realize links required for that admission without a startup-boundary change. | Retain RTC ownership. A pre-admission realization contract remains necessary before transfer; current observer readiness is not admission authority. |
| WPA-04 | High / high for transfer | **Observed:** RTC retains non-lingering creator proxies and ordered cleanup. **Derived:** moving creation without realization-scoped withdrawal can reconstruct stale work during unload/retry. | Retain one RTC link owner. Transfer requires finite cancellation/withdrawal and delayed-callback rejection; these are not implemented by this observer. |
| WPA-05 | Medium / high | **Observed:** current owner roles are simulator and optional Julia; session objects are required. General mixed-rate, multiple-output AOS execution is not qualified. | Cold declarations cover multiple sources/sinks sharing one owner. Preserve selected Copper scope and separate optional observation boundary; no new provider/configuration grammar. |
| WPA-06 | High / high | **Observed source:** Lua registers no `WpLink:get_state()`; Link exposes a GObject state property. | Use `object["state"]`; later actual type-boundary failure is WPA-09. |
| WPA-07 | High / medium initial hypothesis | Review initially reported a loop-local declaration used afterward; source was being changed concurrently. | Current lookup precedes the loop. Rechecked by reviewer and 26/9 cold assertions; no historical live-failure claim for this finding. |
| WPA-08 | High / high | **Observed live:** passive links failed discovery because registry `global-properties` omit `link.passive`. `WpPipewireObject` properties expose native Link Info. | Use `object.properties`. Preserve `policy-info-before/`; subsequent native discovery passes. Cold test keeps the registry subset distinct from Info properties. |
| WPA-09 | High / high | **Observed live:** numeric comparisons fail on GEnum strings in timer and state signal. Upstream `wplua/value.c` pushes enum nick strings. | Check `error`/`unlinked` nick strings. Preserve `policy-state-before/`. Same cold callback test fails against that saved script and passes corrected source; native coexistence also passes. |
| WPL-01 | High / high | **Observed contract:** fallback helper rejects `initial_wait=0`; that test failure would skip cleanup and receipt writing. | Positive grace, guarded fallback and receipt write in an inner finally. Source re-reviewed; no claim that an actual deployment was leaked. |
| WPL-02 | Medium / high | **Derived test ambiguity:** any earlier loss marker could satisfy an injected-loss gate. | Require observer health/no prior marker or Lua error before injection; record log offset and require a new marker afterward. |
| WPL-03 | Medium / high | **Derived process risk:** numeric kill after PID/start-time validation leaves a reuse race. No occurrence observed. | Development-only pidfd helper opens before revalidation and signals the bound process. Cold test rejects wrong parent/start time and terminates only its own child. No production Python dependency added. |

The last independent source review found no blocker in the corrected Rust,
Lua or loss-harness mechanisms. Live results and remaining limits are recorded
in [the qualification](README.md). Source review does not close link transfer,
general multiple-endpoint simulation or deadline/resource qualification.

The final independent review checked all six receipt hashes, current source
hashes, successful WirePlumber logs, cleanup observations and readmission
summaries. It accepted the scoped merge without blockers, preserving the fault
diagnostics and the unproved transfer/graceful-shutdown gates.
