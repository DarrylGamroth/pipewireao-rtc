# Optional WirePlumber user service

> Historical pre-RTC-ARCH-025 deployment instructions. The coordinator and
> companion observer launchers described below are retired. Their source and
> results remain available at baseline `e791361e`. Use the current repository
> README and `docs/WIREPLUMBER_SESSION_DESIGN.md` for WirePlumber-owned sessions.


Baseline: RTC `c49139f`, clean dedicated branch/worktree
`feat/wireplumber-user-service-20261007` / `/tmp/rtc-wireplumber-service-20261007`.
The selected slice is a companion observer for existing installed Copper HIL
CPU FGN/JFG packages with CUDA AOS. It does not move scientific supervision or
link ownership. Existing artifacts and native controls remain authoritative.

## Scoped coverage

| Contract | Allocation | Required checks | Disposition |
| --- | --- | --- | --- |
| RTC-ARCH-020 / RTC-DEV-023 | Copy companion executable, libraries, Lua and preparer into a fresh destination; generate a user unit with explicit installed package/prefix/runtime paths | Installed resource completeness, AO library selection, unit syntax, no dependency on repository/worktree at execution | Passed for this slice; no SDK export/registration or release recipe claim |
| RTC-DEV-021 / AAR-03 | Existing RTC notify unit owns required process cohort; companion uses BindsTo/After/PartOf, Restart=no | Exact active MainPID/native incarnation; fresh start/restart preparation; RTC cohort death stops observer; observer failure leaves RTC intact | Passed for the selected service transactions; isolated required-owner loss and independent scientific-owner units remain excluded |
| RTC-DEV-030 | ExecStartPre reads locator hints once, connects exact native supervisor and queries fresh Status | Wrong/stale owner rejection, changed unit/cohort rejection, native deadlines; saved state never establishes admission | Passed focused identity/rejection checks and both live executor bindings; no new control protocol |
| RTC-DEV-001 / RTC-DEV-006 | Companion has no source, link or science mutation authority | No GUI required, matched prefix after observer stop/death/restart, links retain identities/owners | Passed for metadata observation and 256-frame prefixes; no new pixel observer boundary |

The [dated qualification](../../docs/validation/wireplumber-user-service-20261007/README.md)
retains the final receipts, journals, source hashes, independent review and
limitations. These rows allocate only this increment; they do not close the
broader requirements or the architecture review's ownership-transfer gates.

The existing runtime supplies scientific format admission. The companion observes
the actual admitted contracts and selected topology, rather than independently
revalidating calibrations or authorizing ingress. Supported external roles are
`simulator` and optional `julia`; other profiles/layouts are rejected explicitly.
The companion is installed separately from the existing sealed SDK package:
it copies its own resources and invokes that package's already-installed SDK.
No SDK export/registration claim is made.

## Lifecycle

`BindsTo` starts the named RTC dependency when an operator starts the observer.
`After` waits for that existing notify service, whose READY follows source
release. Observer activation therefore does not establish held-startup discovery
or scientific readiness. `PartOf` propagates RTC stop/restart to its observer;
there is no reverse dependency and no automatic observer restart.

Every observer start prepares a new private RuntimeDirectory using an active
unit MainPID, exact native endpoint identity and fresh admitted Status. It checks
the selected descriptor in the owner's process arguments, expected endpoint
role PIDs, links/passive policy, and unchanged unit/cohort before atomically
publishing standard WirePlumber configuration. Failed preparation cannot reuse
an older executable configuration. A remaining post-preparation race gives a
stale exact-ID/serial snapshot; the observer has no mutation authority or
fallback name matching. `Type=simple` activity is not cohort readiness; only
the observer's `HIL_COHORT_READY` marker records completed discovery.

No new supervisor waits around WirePlumber: systemd runs the upstream executable
directly. The Julia adapter runs only in ExecStartPre. The unit clears inherited
remote/notify variables, chooses private AO libraries/modules and config/data
paths, and uses a non-RT CPU other than CPU0/1. RuntimeDirectory is removed on
stop. Neither installer nor unit changes desktop services or host-wide policy.

## Qualification scope

Cold tests cover generation, paths/resources and rejected topology/identity.
Private user-service checks cover each selected CPU executor with CUDA AOS,
observer discovery/start/stop/death/restart, native lifecycle, exact retained
baseline prefix, new cohort after RTC restart, and dependent cleanup. Evidence
must retain failures, command identities and actual unit states; process activity
does not replace native admission. Timing, full-sequence numerical equivalence,
multiple endpoints, link transfer and independent owner units remain separate.
