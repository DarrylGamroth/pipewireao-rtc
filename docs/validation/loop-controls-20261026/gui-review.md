# Independent GUI correction-loop review

Reviewed the working diff against `30a2133b750a80fe5cde73c5bed52659bcf49b8f` in `/home/dgamroth/workspaces/codex/worktrees/gui-loop-controls-20261026`. Review was read-only apart from this report. No services were contacted or changed and no test/build suite was rerun.

## Findings

No actionable source findings.

**Browser validation disposition:** Resolved. Inspected the final DPR2 receipt: `browser-review-dpr2.exit` is `0`; its log reports **28 checks** and **no browser errors**. The coordinator reports that the initial failure was missing Playwright in the system Python environment, followed by the successful cached-environment rerun. No source change or review rerun was needed.

## Assessment

- **Observed:** `SessionBinding.correction_loops` is optional with an empty default (`src/operator_view/model.rs:94`). Each binding explicitly identifies its ID, title, graph, and qualified Property. Validation bounds the collection and strings, requires a declared graph and qualified nonempty Property parts, and rejects duplicate IDs/targets (`src/operator_view/validation.rs:406`). Configuration cannot contain a saved loop state. No instrument or node-name inference was added.
- **Observed:** The RTC panel derives Open/Closed solely from an exact observed Boolean under a fresh, connected, matching session (`src/view_panel/rtc.rs:350`). It emits an explicit desired Boolean together with the binding, connection generation, and session identity. Rendering or clicking does not replace the observed value. Pending, stale, unknown, mismatched, and non-Boolean states cannot enable loop mutations.
- **Observed:** Dispatch rechecks the current complete binding declaration, graph membership, existing verified native-session fence, generation/session identity, Boolean observation, no pending RTC request, and no staged update batch (`src/main/rtc_session.rs:308`). It then constructs only the existing `PropertiesSet` command. Opening/closing adds no acquisition, reset, startup, or independent transport operation.
- **Observed:** Existing mutation submission and request admission remain responsible for pending state and dispatch. Accepted `PropertiesSet` responses invalidate cached Properties and queue their readback; requested values do not become observations. Unknown outcomes retain shared history and clear connection/observation authority, without automatic retry. These interfaces were inspected in `src/main/rtc_session.rs:82`, `src/main/rtc_session.rs:565`, and `src/rtc/model.rs`.
- **Observed:** Documentation agrees with explicit declaration, owner-authoritative readback, continued processing, retained controller state, and unchanged generic Boolean editing. Startup and generic command implementations were not modified.

## Verification evidence

- `native-tests.log`: **639 library**, **284 native application**, and **12 import tests** pass; **1 library / 15 application tests are ignored**. Added tests cover optional/invalid/duplicate configuration, exact Boolean observation, fenced click intents, no optimistic state, pending/unknown behavior, current-declaration/session/generation checks, and the existing native command/model integration. Earlier `focused.log` compile errors are superseded by this successful full native run.
- `wasm.log`: browser-target check finishes successfully.
- Both `browser-review-dpr1` and `browser-review-dpr2` logs and exit markers report **28 checks**, no browser errors, and exit **0**.
- Strict Clippy exits **101** for six `chunks_exact_to_as_chunks` errors in unchanged deformable-mirror source files. `clippy-baseline-allowed.log` finishes successfully and its exit file is **0**. This is an existing lint-class limitation, not a new loop-control finding.
- Independently ran `git diff --check`: clean.

The new controls' behavior is covered by native egui interaction/model tests. The browser artifacts primarily exercise existing rendering fixtures; they do not demonstrate a live correction-loop command or physical plant behavior. No live or hardware correctness is claimed.
