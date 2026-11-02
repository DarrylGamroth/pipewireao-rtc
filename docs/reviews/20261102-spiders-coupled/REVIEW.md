# SPIDERS coupled CPU recovery review — 2026-11-02

## Scope and baseline

Independent review of RTC-DEV-032–035; RTC-DEV-036 remains monitor-only and
unchanged. RTC baseline `778a7e2`, reviewed implementation `59976f9` plus
camera-pool integration `5b25ccd`. Graph baseline `f71a53c`, final validated and
reviewed implementation `4d43af1c9e702aa5ef43c6e34c74d98f4ae90871`. The graph
worktree was clean after that commit, with no source changes after validation.

The selected profile is complete-frame CPU composition with explicitly declared
controllers `correction` and `llowfs-correction`, participants `pair` and
`dm-command`, and one shared command/feedback path. Review covered exact owner,
token and componentwise generation fencing; stopped-camera recovery; SCC pair
priming and watermark preservation; complete history scope; shared flats and
offsets; independent first-close guards; readiness invalidation; reset, failure,
cancellation and absence of automatic replay. Single-controller compatibility
remains required. Physical devices, GPU recovery and deadline qualification are
outside scope.

## Findings and dispositions

| ID | Severity / confidence | Evidence and requirement impact | Disposition and verification |
| --- | --- | --- | --- |
| CR-01 | P2 / high, confirmed | `src/owners/correction_recovery.jl`, `cancel!`: cancellation omitted the new `PartiallyClosed` state. After the first subset closed, cancellation left the operation resumable and fresh evidence could still produce `CloseLoop` for the remaining controller. Violated RTC-DEV-035's cancellation latch. | Fixed: cancellation latches an active partial recovery when `recovery_generation > 0`, preserving initial mixed-controller qualification. Client regression failed before the fix and passes 5/5 afterward; it verifies no further native transactions and preservation of the already closed controller. Independently inspected and rerun. |
| CR-02 | P2 / high, confirmed | `src/owners/correction_recovery_controllers.jl`, post-release polling: all-open readback was accepted without matching the coordinator's exact controller-generation tuple. A foreign open write could advance a selected or unselected controller and the client could send CloseLoop before noticing a conflict. Violated RTC-DEV-035's contradiction fencing. | Fixed: post-release polling requires all-open values, coherent states and the exact requested/active tuple before authorizing close. Selected and unselected generation-change regression passes 8/8; neither case sends a close write. Independently inspected and rerun. |
| GR-01 | P2 / high, confirmed | Graph `julia/FilterGraphPipeWire/src/composition_recovery.jl`, `_validate_composition_close`: cold property staging called `_current_composition_close_fresh`, reading mutable controller/conditioner storage. Reserving the control slot does not exclude a camera callback already executing. This crossed the scientific-storage ownership boundary and could inspect inconsistent state. | Fixed and source-reviewed: staging uses one coherent atomic/seqlocked observation, exact control-snapshot identity and selected branch readiness; live scientific checks remain at serialized adoption. The discriminating regression publishes proof, perturbs live conditioner state, accepts staging from published evidence, then refuses adoption while retaining its guard; fresh camera evidence permits a new explicit request. It failed before at staging (4 passed, 1 error) and passes 5/5 after the fix, including the final optimized suite. This models an overlapping mutation; it is not a native concurrency trace. |

## Verification inspected

- Independent RTC focused run: 203 HSM, 123 singular-client and 57 plural-client
  assertions passed (383 total), including CR-01/02 regressions. Command:
  `julia --project=. -e 'include("test/test_correction_recovery.jl"); include("test/test_correction_recovery_client.jl"); include("test/test_correction_recovery_controllers.jl")'`.
- RTC full package run completed successfully; parent recorded 8,540 assertions
  across 371 top-level testsets. This reviewer inspected the completed log.
- The earlier four RTC export/load failures came from the temporary SDK lacking
  the validation dependency Manifest. The test helper now copies the selected
  validation closure for root and workspace-test layouts. Parent recorded
  407/407 checks in both root and external environments; production export is
  unchanged. The earlier untracked-source/Git-staging explanation was a rejected
  hypothesis: export copies the complete source directory.
- Graph FGA recovery log: 880 assertions passed, including nine SCC watermark
  and history checks and zero warmed recovery allocation.
- Actual SPIDERS scope admission was recorded for the two controllers and
  `(pair, dm-command)` participants. This establishes cold admission only.
- Final FGPW suite at normal optimization: 2,680/2,680 assertions across 126
  groups, independently counted from the completed stable log. All 124 coupled
  checks passed: admission 67, readiness/reset/allocation 23, freshness/failure
  22, GR-01 staging/adoption 5, and foreign scope 7. Package surface passed 23/23,
  including the ambiguity check. The maintained focused subset also passed
  57/57. The final diff whitespace check passed.
- Final warmed fixture checks report zero bytes for the native callback,
  property adoption and recovery adoption. An exact-state optimized profile
  independently reported zero callback and recovery-adoption bytes. Earlier
  allocation observations came from superseded source and are not evidence for
  the final gate; no specific cause is inferred from their difference.
- The actual SPIDERS private-core recovery selector is a separate application
  gate and was still running at this review decision. No installed application,
  physical-device, accelerator or deadline claim follows from these results.

## Review decision

CR-01, CR-02 and GR-01 are closed by source review and their focused regressions.
No additional confirmed source findings remain. Combined review is approved for
the selected complete-frame CPU recovery implementation and its software-test
scope. Instrument application promotion remains subject to its private-core gate.
Software tests do not establish physical-loop behavior, settling, latency, or
deadline performance. Cold compilation cost was observed during validation but
was not qualified or changed as part of this review.
