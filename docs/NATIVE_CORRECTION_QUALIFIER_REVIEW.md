# Native two-window correction qualifier review

2026-10-06. Independent bounded review of RTC installed-launcher seam
`6800199` and correction qualifier `9244441`. Source worktree
`pipewireao-rtc-native-controls` was clean at the latter revision. This document
is in the separate RTC review worktree, starting at `436d42d`. No production
edit, test rerun, build or SCI was performed.

**Disposition:** approve the frozen implementation for the planned installed
cases. No confirmed blocker was found. This is source/cold-evidence acceptance;
actual native correction and scientific acceptance remain pending.

## Reviewed authority and failure boundaries

- The launcher now selects the installed package's `julia/deploy_cli.jl` and
  project, with the current Julia executable. Strict package admission precedes
  launch and installed runtime hashes are recorded. The retained admission
  client, launcher PID, owned process identities and exact source/HEART native
  bindings remain required.
- Both instruments require the sealed 256-frame active contract, correction
  lifecycle, diagnostics, expected ingress and retained telemetry capacity.
  HEART generation/configuration/placement/health and child parent/group/session/
  start ticks are bound through fresh native snapshots and published reports.
- Window one is already auto-resumed by deployment admission. The qualifier
  neither sends duplicate Resume nor claims to have observed its initial hold:
  `initial_hold_observed=false` records this limitation. Fresh lifecycle/HEART
  state and the completed journal remain its authority.
- Each window waits for native restored, unheld, completed state and matching
  live/publication cursors before reading report files. The bounded journal
  prefix hash, 256 command sequence identities, full-width domain/generation and
  exposure-end model times bind the report to that native cursor. Historical
  report `acquisition_generation` is deliberately not substituted for the
  journal/native authority. Exact published report bytes are retained before
  Reset or shutdown updates the live path.
- Stopped Reset requires native held window two, sequence/model zero, unchanged
  domain, generation+1, a distinct owned child and disappearance of the old
  child. Its journal also requires the reset/held record and lifetime probe
  token preservation. Child health is re-established after that intentional
  generation transition, then public Start begins the second window.
- Successful exit requires both complete windows, exact frame/command hashes
  and truth equality across Reset, restoration/unheld state, final native
  shutdown, no owned groups/children, all client closes and both scientific
  replays. Exceptions keep failure set. Unknown effects never cause speculative
  restoration or release, and owned fallback cannot turn failure into success.

## Scientific and retained evidence checks

The qualifier invokes the existing installed `heart_correction_analysis.jl`
after native shutdown. Source inspection confirms that analyzer checks actual
payload lengths/hashes, retained ADC and DM records, native phase/archive
counts, ACK/configuration proof and startup/restoration zero figures before
the existing replay. The new coordinator retains exact reset equality and
requires both existing intervals **17–128** and **129–256** complete, with finite
residual-to-atmosphere variance ratios **0 ≤ ratio < 1**. No coefficient,
tolerance, vendor algorithm or scientific helper is changed by these commits.

The primary's final cold correction log independently totals **149/149 across
seven sets**, without failure markers. All seven file hashes in the producer's
correction receipt match current retained bytes. The installed-launcher and
native-authority fail-before/pass-after oracles were inspected: the latter
rejects a saved complete report when the native owner is Stopped, before reading
that report. These injected cold fixtures are not actual correction execution.

Exact source hashes, copied primary cold log and verification metadata are in
the [review receipt](validation/integrated-gates-review-20261006/correction-review/receipt.json).
No allocation, latency, cadence, hardware or newly completed scientific gate is
claimed by this review.
