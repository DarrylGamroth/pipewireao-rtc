# RTC-owned local management — 2026-11-03

The later [installed rollout](../management-rollout-20261104/README.md) records
commits/merges and deployment. The source-validation baseline below describes
the earlier stage, when operator services remained unchanged.

## Source and scope

RTC baseline `ccaa1d51717d747e4494d33b3b5766ddab1991cc`, branch
`improvements/management-endpoint-20261103`, dedicated `pipewireao-rtc-management`
worktree; initial source tree clean. GUI baseline
`91e578dcb279453655c75ed1f9971477adad2d93`, branch
`improvements/helper-memory-20261103`; its pending memory mitigation, reports,
plan and untracked user SPIDERS test were preserved. No commits, merges or
publication are included. The operator's installed RTC, scientific inputs and
web service remain unchanged.

The [endpoint contract](../../MANAGEMENT_ENDPOINT.md) defines this delivery.
Native `pipewireao-management` exposes a private per-user Unix socket, bounded
admission and one shared cached Julia worker. `ManagementCLI` reuses the existing
store/simulator modules. GUI native clients use correlated one-shot IPC and
SCM_RIGHTS inputs; helper process startup, command/root overrides and fallback
are removed. Both desktop and browser bridge reuse that client.

Native live controls, journaling, scientific validation/adoption and independent
systemd rebuild jobs retain their original authorities. Rebuild jobs use the
accepted management request ID so their existing job record can be found even
when the transport completion is lost. Direct legacy Julia tooling retains its
UUID job IDs and stdio interfaces. Browser admission and its connection-owned
recovery restrictions are unchanged; arbitrary network receipt lookup is not
added.

## Environment and reproducible commands

Julia 1.13.3, native SDK 4.0.0 and WirePlumber 0.5.18. Resolving the source
workspace revealed a stale tracked manifest (PWA 0.8/native 3 and RTC 0.4.4 despite
Project.toml selecting PWA 0.9/RTC 0.5). Public Pkg resolution regenerated only
the required cohort entries. OffsetArrays remains at the baseline 1.17.0; no
installed application manifest was edited.

With the matching native pkg-config/library environment, build and test the
standalone companion:

```sh
meson setup /tmp/rtc-management-build native -Dtests=true -Dwp_source_dir=/path/to/wireplumber
meson compile -C /tmp/rtc-management-build pipewireao-management management-activate
PIPEWIREAO_MANAGEMENT_BINARY=/tmp/rtc-management-build/pipewireao-management \
  julia --startup-file=no --project=. test/management_endpoint.jl
julia --startup-file=no -O0 --project=. -e 'using PipeWireAO; ENV["PIPEWIREAO_PREFIX"]=String(PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir); include("test/runtests.jl")'
```

The dedicated systemd test installs only uniquely named runtime-linked validation
units and removes them afterwards:

```sh
PIPEWIREAO_MANAGEMENT_BINARY=/tmp/rtc-management-build/pipewireao-management \
PIPEWIREAO_MANAGEMENT_NATIVE_PREFIX=/path/to/native-sdk \
  julia --startup-file=no --project=. test/management_systemd.jl
```

Set `PIPEWIREAO_MANAGEMENT_OBSERVE_UNITS` to comma-separated existing unit names
to assert their PIDs/invocations/states remain unchanged. The executed test
observed the current RTC session, core, Julia-owner and web units. It did not
stop or rebuild them.

From the GUI checkout, explicitly run the production-client/owner integration:

```sh
PIPEWIREAO_MANAGEMENT_BINARY=/tmp/rtc-management-build/pipewireao-management \
PIPEWIREAO_MANAGEMENT_PROJECT=/path/to/pipewireao-rtc \
  cargo test -p pipewireao-gui-native --test management_endpoint -- --ignored --nocapture
```

This test constructs two real Rust clients, checks that client construction starts
no Julia workload, registers a FITS input after its pathname is unlinked,
materializes its values, queries durable receipts and restarts the owner while
retaining its prepared payload. The normal Rust suite leaves this external-owner
integration ignored; no test requires the operator's session.

## Verification and review

- Native companion built without warnings; 150 actual IPC assertions passed.
  Coverage includes two clients/domains sharing one cached process, correlated
  responses, FD retention after client unlink/close, malformed/oversized input
  and output, bounded slow I/O, Busy, 16-handler saturation, idle reclamation,
  256-record capacity, duplicates, dropped acknowledgements, interrupted records,
  root exclusivity, worker timeouts, process-group cleanup and socket activation.
- Eleven Rust transport tests passed, including exact framing limits, same-UID
  private endpoint validation, pre-admission Busy, reply identities, receipt
  bounds, FD-only registration, no retry, client exit and the 64-worker client
  capacity held through detached bounded requests.
- Real Rust → native companion → Julia store integration passed. Two clients
  shared one owner process; the prepared bytes remained exact after client exit,
  idle worker retirement and native owner restart.
- Generated-unit activation/cgroup test passed ten assertions. It used an
  executable prefix and worker filename containing `$`, killed only the uniquely
  named test service, verified worker/descendant removal and survival of a separately owned test job,
  and recovered Unknown
  on the next socket activation without re-executing the request. Existing RTC
  and web unit identities were unchanged; all validation links/units were removed.
- GUI workspace tests passed (1,496 successful result cases; opt-in tests remain
  ignored). The unrelated pre-existing SPIDERS test remains skipped. Formatting,
  WASM/browser compilation, dependency checks and warnings-denied Clippy passed;
  desktop Clippy excludes that untracked test using the existing focused targets.
- The 151 GUI Julia development-fixture assertions passed.
- The RTC core suite passed on the final regenerated manifest, reporting 8,985
  passing assertions across 376 summary rows. Its missing-Git-object diagnostic
  is the expected rejection case. The new dispatcher/installation/rebuild-ID
  checks contribute 41 assertions; no native session is needed for them.

Independent Sol review assessed native durable ordering, FD/resource ownership,
process cleanup, root/path restrictions, response bounds and Julia installation.
The following findings were adjudicated and remediated:

| ID | Finding and evidence | Disposition |
| --- | --- | --- |
| ME01 | One-pass stale-temp cleanup could collide with an accepted record's rewrite; broad `.tmp` matching also deleted an unrelated owner file. Pre-fix regression observed the unrelated-file loss. | Two-pass cleanup handles only exact nonce temp names before record recovery; interrupted/foreign-file cases pass. |
| ME02 | systemd executable words do not expand `$` like later argv. Doubling `$` in the executable path selected the wrong file. | Separate executable/argument escaping; generated-unit test actually launches from a `$` prefix and reads a `$` worker path. |
| ME03 | Linux parent-death signals follow the creating thread. Forking the cache from a short-lived handler killed it after its first reply; the cache regression failed. | A persistent bounded spawner thread owns fork lifetime; cached sharing, hard kill and systemd whole-cgroup cleanup pass. |
| ME04 | A 1 MiB receipt-query limit could not recover valid retained configuration responses. | Receipt wrapper gets its own bounded 16 MiB + 4 KiB limit; original simulator/configuration limits remain unchanged. Large recovery and exact Rust limits pass. |
| ME05 | A rebuild could persist its independent job before loss of the RPC completion, leaving no recoverable RPC→job mapping. | Owner injects the accepted ID; the existing durable job uses that ID. Focused owner tests recover by original ID without relaunch. |

The first native IPC run also caught an incorrect direct-bind socket mode; the
companion now explicitly sets 0600. The initial real-client test fixture used a
non-private temporary parent and was corrected to the contract's 0700. A staged
systemd fixture initially lacked SDK libraries; its private test prefix now
points at the selected SDK's libraries. These were investigated rather than
masked by wider permissions or disabled checks.

## Memory observations and qualification limits

Two explicit real-client passes sampled about 1.4–1.5 MiB native-owner PSS before
use, 490–575 MiB for the owner plus its one shared warmed Julia worker, and
1.5–1.6 MiB after idle retirement (rounded). These are discrete local observations, not transient
peaks, allocation profiles, latency percentiles or worst-case memory bounds.
The GUI runtime has no Julia installation requirement. Owner-side description
and preparation can still load Julia and scientific environments on demand.
Independent accepted deployment jobs retain their existing lifecycle/resource
rules; one cached management worker is not a global bound on scientific jobs.

Foreign-UID connection rejection is implemented but was not exercised under
another UID. No physical device, scientific replacement execution, frame-rate,
real-time, cross-host or Internet qualification follows from these tests.
No new cross-browser receipt recovery workflow or mutation authorization is
claimed. Production owner/client package publication and deployment remain
separate from this source/test-owned installed acceptance.

## Retention and completion

Final checks found no test-owned service or runtime unit links and no process
mapping either build tree. Cargo metadata resolved the repository-local
`pipewireao-gui/target/rtc-management`; `cargo clean` removed 16,114 files
(18.2 GiB reported), increasing free filesystem space from about 95 to 111 GiB.
The temporary native build, raw logs and copied baseline manifest were removed
after this summary. The source worktree remains because it contains the
uncommitted RTC delivery; pre-existing worktrees and source changes are preserved.

Changed-file documentation checking resolved 715 local file links/anchors. A
pre-existing historical roadmap link to retired `../tests/calibration.rs` remains
unchanged; it is not a new delivery link. Whitespace checks pass in both trees.
The previously rendered GUI architecture diagram is unchanged. The new endpoint
contract and evidence are indexed in the RTC task index, current roadmap and
evidence catalog.

The running deployment has not been replaced. Rollout must install the matching
native companion and tooling project, select existing store/job roots, activate
its owner socket, and update the GUI/bridge cohort. Runtime GUI command/root
fallback is deliberately unavailable in the migrated code. Source publication,
commits/merges and operator rollout are not included in this implementation turn.
