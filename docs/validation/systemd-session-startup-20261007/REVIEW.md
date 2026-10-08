# Independent startup and cleanup review

Date: 2026-10-08. Worktree: `/tmp/rtc-systemd-session-launch-20261007`.
Branch: `work/systemd-session-launch-20261007`.
Baseline: `6c16609b1ef75fbf0fc6248cc7f598dc622510a3` plus the primary agent's
uncommitted implementation. Initial changed files: systemd_owners.jl,
test_systemd_owners.jl, wireplumber_launch.jl; new systemd_units.jl and
SYSTEMD_SESSION_STARTUP.md. This review edits only this artifact.

Scope: generated service/target startup, retained identity, cancellation,
ingress-first cleanup, and fragment ownership/removal. No scientific code or
runtime protocol changes reviewed. No source edits, tests, process control, or
hardware checks performed by this reviewer.

Initial reviewed implementation file hashes:

- `deployment/julia/src/systemd_owners.jl`: `e0f4200dcd04fa8de605aac7958f620724f4270a1f2fa050b2f4b18b3a1fb675`
- `deployment/julia/src/systemd_units.jl`: `6aea3c0c4765a95a379c33436315f78992540ed83c0260f0f449e6d4c718f8f1`
- `deployment/julia/wireplumber_launch.jl`: `e7683a905c2aa920c47344f03697e2e7bf6e9cdf770f7789f8b611beb984a263`
- `docs/SYSTEMD_SESSION_STARTUP.md`: `9252ff1703f80f1ff5fa3787df0e9932d7a3d702f23d08314bb1d495852e7cd6`

## Conclusion

The refined startup sequence preserves the relevant ownership and ordering
boundaries by inspection. Core starts separately and the existing socket check
runs outside its service startup commands. HEART starts separately when its
actual PID is required in the source command. The cohort excludes both staged
roles; its target cannot implicitly restart them. Target success is followed by
individual owner identity verification, and native admission remains outside
systemd activation.

Cancellation now includes the target and all invocation member start jobs before
core/source revocation. There is no new PartOf/Requires/BindsTo stop propagation.
Core and source are stopped and their emptiness verified before consumer stop;
the target is stopped after service quiescence. The missing-ledger path cancels
member/target starts and limits teardown to ingress owners. No new ingress-ordering
regression was confirmed in the reviewed code.

The initial review identified one cleanup recovery defect, SSD-001. The follow-up
review below verifies its remediation. No unresolved blocking defect remains in
this bounded source review. Production acceptance also depends on the primary's
selected runtime checks; this review does not claim timing/hardware qualification.

## SSD-001 — Fragment deletion cannot recover after interruption or reload failure

- Classification: confirmed source behavior; medium severity; high confidence.
- Affected code: `deployment/julia/wireplumber_launch.jl`,
  `remove_fragments!`, reviewed lines 682–701.
- Evidence: validation requires every recorded fragment to exist. The subsequent
  loop deletes links and fragment files. Only after a successful daemon-reload
  does it set `unit_files_removed=true`. The outer cleanup catch saves the record
  on failure; it therefore preserves a false/absent completion flag if reload
  fails or times out after deletion. An interrupted deletion loop likewise leaves
  a partially deleted set and the original record.
- Derived failure: a later cleanup attempt encounters a missing fragment and
  fails its existence check before it can retry the reload or remove remaining
  fragments. Its own preceding successful deletion is indistinguishable from the
  condition it rejects. Ingress and consumers have already been stopped, so this
  is recovery/cleanup completion failure rather than evidence of unsafe frame
  processing.
- Minimal remediation: make cleanup converge when exact recorded paths/links are
  already absent, while continuing to reject changed existing files, unexpected
  links, foreign paths, live units or jobs, and foreign loaded definitions. Account
  for systemd retaining the known FragmentPath before reload even when that file
  has already been deleted. Retry reload before recording removal complete.
  Alternatively persist a deletion phase/progress that provides the same safe
  restart behavior.
- Required validation: force reload failure after deletion, retry cleanup and
  establish completion; also retry a partially deleted set and demonstrate that
  a replacement file/link still fences removal. Keep those experiments on private
  invocation units, outside the existing GUI/HIL session.
- Initial disposition: reported to primary for adjudication/remediation. The
  reviewer derived the failure from source sequencing. Final disposition: resolved
  by the reviewed remediation and the primary's retained fail-before/pass-after
  recovery test; see the follow-up verification below.

## Other examined concerns

- `ExecStart=:` disables environment expansion, while argument rendering escapes
  percent specifiers and C-style characters. Environment identity fields are
  stripped as before. The primary reported an actual argument/environment
  round-trip check; that evidence is distinct from renderer string assertions.
- Target Wants semantics permit a failed member alongside an active target.
  `start_services!` reconciles every member and checks active retained identity;
  it does not accept the target state as readiness.
- A later failure while rendering HEART-dependent members retains the complete
  intended role set and previously launched process identities for cleanup.
- Exact unit names remain exclusive within a fresh invocation. Name-based systemd
  actions are not atomic compare-and-stop operations; observed identity mismatch
  still fences cleanup. Hostile/manual concurrent unit replacement remains outside
  the established workflow rather than becoming a new guarantee of this patch.
- Effective FragmentPath, absence of drop-ins, private file content hashes and
  selected resource properties are checked. The code does not separately compare
  the parsed ExecStart property; broad descriptions should not claim it does.
- Removal of old coordinator/transient routines was checked against the displayed
  diff; the maintained launcher continues using the retained Service identity and
  stop primitives.

## Evidence inspected

The reviewer read the source diff, generated-unit renderer, current startup design,
RTC-ARCH-025 ownership sections, and the tail of
`/tmp/rtc-systemd-startup-julia-tests-20261007.log`, which contains passing Julia
test summaries. The primary reports SDK exit 0 and a 16-assertion real-systemd
probe, including preservation of the initial WorkingDirectory failure receipt.
Those checks were not rerun here. Copper FGN/JFG checks were still running when
this review was requested. No physical, latency, or real-time qualification is
implied.


## Follow-up verification — SSD-001 resolved

The primary moved the ordinary unit lifecycle helpers into
`deployment/julia/src/systemd_unit_files.jl`, included by SystemdOwners.
WirePlumberLaunch retains launch policy and calls those helpers. The renderer
remains in systemd_units.jl. This extraction does not introduce another session
admission or scientific authority.

Source inspection confirms the following remediation in remove_fragments!:

- The complete set is validated before deletion, preserving exact invocation
  name/path, content-hash, link-target, drop-in, and quiescence checks.
- `unit_file_removal_started=true` is atomically saved before the first removal
  (`systemd_unit_files.jl:141`).
- A previously recorded removal phase permits an absent exact fragment path;
  an existing changed file or symlink still fails validation (`:127`).
- A cached known FragmentPath is accepted for that absent path during recovery
  (`:133`), allowing recovery before systemd has reloaded.
- Removal skips already absent files, reload runs again, and removal completion
  is set only after successful reload (`:143`). A process interruption before the
  final outer ledger save therefore replays the safe removal/reload phase.

The source and phase ordering address the confirmed failure, including interruption
within the deletion loop. The staged core/HEART startup, cohort membership,
per-member reconciliation, missing-ledger cancellation and ingress-first stop
ordering remain as reviewed. The start_services! extraction correctly qualifies
`SystemdOwners.record(service)` to avoid its local record argument shadowing the
function.

The reviewer read these completed logs without rerunning their experiments:

- `/tmp/rtc-systemd-removal-recovery-20261007-final.log`: 11/11 assertions pass for
  the primary's SSD-001 reload-failure/recovery experiment. The primary reports
  it uses the actual pre-fix installed launcher for failure evidence, verifies
  successful new retry, and verifies replacement-file rejection.
- `/tmp/rtc-systemd-unit-probe-20261007-final2.log`: 16/16 assertions pass; both
  successful-member and failed-member cases report cleanup complete.

No unresolved blocking source finding remains within this review's deployment
scope. Final SDK rerun and Copper FGN/JFG receipts remain the primary's integration
responsibility. HEART profile runtime qualification, timing and hardware claims
are not established here. Existing name-exclusivity assumptions remain unchanged.

Final reviewed source hashes:

- `deployment/julia/src/systemd_owners.jl`: `d2530600c6a9e0403195c3639e8ec4ae1cbe12ae46c29ff01c6b2384cf281adb`
- `deployment/julia/src/systemd_units.jl`: `6aea3c0c4765a95a379c33436315f78992540ed83c0260f0f449e6d4c718f8f1`
- `deployment/julia/src/systemd_unit_files.jl`: `c78dc29c9d9869b3e79cc8cdba2f9e045849f89007b1298bb46fcf8bf8d62e11`
- `deployment/julia/wireplumber_launch.jl`: `cb0e7c4452f7ebffe91780023eec5768e2dac3ab19ce91756d2e0bbd3589fdf9`
