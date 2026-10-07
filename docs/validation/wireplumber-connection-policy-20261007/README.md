# Declared connections and required loss, 2026-10-07

Baseline RTC `e605831`, dedicated branch/worktree
`feat/wireplumber-connection-policy-20261007` /
`/tmp/rtc-wireplumber-policy-20261007`. Runner remediation is `0bcdf24`;
[checks.json](checks.json) records exact source hashes and receipt checks.
Upstream WirePlumber remains unchanged (`bdc17eb`, 0.5.18), built against AO at
`/tmp/wp-ao-pilot-20261006/build`. CPU0/1 are excluded; the development
coordinator/observer use CPU6 and scientific owners retain package placement.
HEART, desktop services and the existing GUI simulation were untouched.

## Changes and scope

- Required link loss was reproduced before correction: deleting link 28 in
  READY left the runner READY without a diagnostic. The periodic monitor now
  checks its captured link proxy/registry presence and state. Removal and
  terminal failure remain latched until reload; normal Paused links are usable.
- External node/port removal latches prevent a reused registry ID from concealing
  loss. Private-core replacement checks preserve replacement/unrelated owners
  during cleanup. Same-ID reuse has unit coverage; live replacements had
  different IDs. [Required-monitor evidence](required-monitor/README.txt)
  retains the fail-before/pass-after logs and command environment.
- WirePlumber checks the configuration's declared Format, passive links and
  exact owner clients, and continuously observes contracts without repair or
  source authority. Native Link Info properties and enum nick strings are used.
- All runtime/scientific ownership remains unchanged. The observer neither
  creates session links nor grants admission. This is not transfer qualification.

Installed test packages were refreshed at `/tmp/rtc-wp-policy-{fgn,jfg}-20261007`.
The sealed artifact map changes only `bin/pipewireao-rtc` and `provenance.json`;
the descriptor was recomputed. Every science, calibration, SDK and owner artifact
hash is unchanged from `/tmp/rtc-graph-updates-{fgn,jfg}-baseline-20261006`.
No interaction matrix was reacquired. The refresh command is preserved in
`scripts/prepare_wireplumber_policy_test.jl`.

## Live checks

Both selected paths use Copper complete-frame CPU reconstruction and CUDA AOS,
500 Hz model rate / 100 Hz wall pacing, 256 retained frames and 512 exchanges.
Fresh output directories isolate every check. Live native admission and role
identities precede injection; saved state is postmortem evidence only.

| Check | CPU FGN | CPU JFG | Acceptance / scope |
| --- | --- | --- | --- |
| Required input-link deletion | [Pass](fgn-linkloss/receipt.json) | [Pass](jfg-linkloss/receipt.json) | Healthy pre-injection observer, new loss marker, deployment exits nonzero, postmortem admission false, all owned groups/private core removed |
| Owned simulator SIGKILL | [Pass](fgn-ownerloss/receipt.json) | [Pass](jfg-ownerloss/receipt.json) | Independent PID/parent/start-time revalidation through pidfd; same required-failure and cleanup gates |
| Fresh admission after failures | [Pass](fgn-readmission/receipt.json) | [Pass](jfg-readmission/receipt.json) | New supervisor UUID/instance and runner instance; two complete 512-command runs, stop/reset/resume and optional observer death |
| Retained numerical regression | Pass | Pass | Detector and command prefixes match each engine's independently retained baseline exactly in both fresh runs; this is 256-frame prefix equivalence |
| Simulator measured tail | Pass | Pass | Last 256 exchanges of each run: 0 allocated Julia heap bytes, 0 GC pauses/time; excludes startup, retained prefix and final serialization |

Readmission UUIDs and instances are distinct from both failed sessions for each
engine; the saved receipts and checked hashes are in `checks.json`. All six
checks observe complete cleanup without coordinator fallback. Link injection
checks ID/serial immediately before public CLI destroy; the numeric destroy
operation itself is not atomic with a serial check. No allocator race was
observed. No Lua error handler appears in the successful policy logs.

Commands use the existing installed SDK, for example:

```sh
taskset -c 2-15 env JULIA_PKG_OFFLINE=true OPENBLAS_NUM_THREADS=1 \
  JULIA_NUM_THREADS=1,0 julia --startup-file=no --compiled-modules=existing \
  --project=/tmp/rtc-wp-policy-fgn-20261007/julia \
  deployment/qualify_wireplumber_loss.jl \
  /tmp/rtc-wp-policy-fgn-20261007 \
  /tmp/rtc-wp-policy-fgn-linkloss-runtime-20261007 \
  /tmp/rtc-wp-policy-fgn-linkloss-20261007 \
  /home/dgamroth/workspaces/codex/pipewire/wireplumber \
  /tmp/wp-ao-pilot-20261006/build required-link
```

Repeat with fresh directories and `simulator-owner`. Fresh readmission uses
`deployment/qualify_wireplumber_hil.jl` with the same five path arguments and no
case argument. JFG substitutes its corresponding package/runtime/evidence paths.
Retained logs are normalized copies with trailing whitespace removed; original
run outputs remain in the named temporary evidence directories.

## Cold checks and preserved failures

Julia checks pass 26 declared-session, 9 existing-topology and 33 service
assertions, using the installed SDK project and `--compiled-modules=existing`.
Multiple sources/sinks sharing one owner, contract/owner mismatches, missing and
duplicate nodes and optional observation independence have cold coverage.
This does not qualify a general multiple-output or mixed-rate AOS runtime.

Lua callback plumbing checks pass with separate registry/Info properties and
native enum string representations. Running the same test against
`policy-state-before/hil-observer.lua` fails at the string/number comparison.
Native SPA Format filtering is tested live, not supplied by those cold stubs.
The Python pidfd test rejects incorrect parent/start time and signals only its
owned child. Production deployment/control adds no Python dependency.

```sh
julia --startup-file=no --compiled-modules=existing --project=PACKAGE/julia \
  deployment/wireplumber/test_session.jl
julia --startup-file=no --compiled-modules=existing --project=PACKAGE/julia \
  deployment/test_qualify_wireplumber_hil.jl
julia --startup-file=no --compiled-modules=existing --project=PACKAGE/julia \
  deployment/wireplumber/test_service.jl --deployment PACKAGE/deployment.conf
/tmp/wp-ao-pilot-20261006/build/subprojects/lua-5.5.0/lua \
  deployment/wireplumber/test_observer.lua
python3 scripts/test_signal_test_owner.py
```

The initial [passive-property failure](policy-info-before/receipt.json) and
[enum-type failure](policy-state-before/receipt.json) remain preserved with
their exact investigative scripts/logs. Both deployments cleaned up; neither
failed gate was counted as accepted. Rust workspace tests, formatting, Clippy
and release build pass on the corrected source. The existing
`proc-macro-error2 v2.0.1` future-compatibility warning remains recorded.
The [independent review/adjudication](REVIEW.md) documents findings and scope.

## Remaining gates

**Step 4 is not proved:** optional post-admission observation supplies no
pre-admission realization/withdrawal contract. RTC link creation, ordered
negotiation and cleanup remain necessary. Broad deletion or reorganization of
that code is deferred until a chosen transfer passes its architecture gates.
The accepted architecture permits retaining RTC ownership when transfer adds
more coordination than it removes; this increment follows that boundary.

Loss checks prove eventual ingress revocation through observed source/core
termination, not a fresh native pause acknowledgement or measured revocation
latency. Interrupted exchanges do not complete. Link-loss teardown reports a
simulator exchange timeout, SIGTERM during report serialization and finalizer
context warnings; JFG also reports the disconnected core. FGN owner-loss retains
source-proxy cleanup errors in its saved report. All groups are gone, but
**graceful fault teardown is not qualified** and these diagnostics are preserved.

Normal readmission runs pass the lifecycle and measured-tail gates. Existing
cold precompilation/version warnings remain outside the scientific allocation
window. No target frame rate, p99 improvement, full-sequence scientific
equivalence, general multiple-endpoint AOS coherence, physical actuation or
independent-owner unit/release qualification follows from these functional tests.
