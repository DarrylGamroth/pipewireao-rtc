# Independent controller loop-state review

Reviewed the working diff against `3e053b7f2e5c439b778dfd56113f1b5a2b02f679` in `/home/dgamroth/workspaces/codex/worktrees/jfg-loop-controls-20261026`, including the new `correction_loop_state.jl` test file. No production files were changed and no live actions were performed.

## Findings

No actionable findings.

## Assessment

- **Observed:** `ClosedLoopCorrectionPlan.closed` defaults to `true`. The existing closed recurrence, coefficient validation, output rejection, and first-output feedback rules are preserved. The open branch (`julia/FilterGraphAlgorithms/src/algorithms/control/closed_loop_correction.jl:258`) copies committed mathematical state and correction separately, without anti-windup, hidden-mode removal, or residual integration. Shape, alias, residual-finiteness, and required delayed-feedback validation precede it.
- **Observed:** Successful open frames establish output availability, including an initially open first frame. Subsequent frames therefore require feedback under the existing contract. Commit/discard/reset implementations are unchanged; closing resumes from the held preceding correction and current delayed feedback. Hidden-projection replacements and scalar-property replacements preserve `closed`.
- **Observed:** The leaky-integrator open branch (`src/algorithms/control/leaky_integrator.jl:123`, under the same package) holds its committed value while retaining input, alias, shape, and finite-output checks. Reset continues to restore its configured initial state. All closed arithmetic remains unchanged.
- **Observed:** Captured correction and leaky owners retain `closed` during preparation. Their open kernels hold history while validating inputs; correction skips projection enqueue and hidden expansion. `prepare_validation` preserves the flag when constructing a proof-specialized correction owner. Initial history, first-frame availability, failure priority, and reset handling remain consistent with the declared CPU Algorithms.
- **Observed:** Runtime `Bool` Property schemas add stable new IDs without changing existing IDs. Generic Property transactions and generation adoption remain the existing implementation; tests exercise strict Boolean typing, staged/adopted generations, cancellation, state retention, allocation-free adoption, and current-frame metadata on held outputs.
- **Observed:** `JuliaFilterGraph/src/properties.jl` still rejects runtime Property replacement on prepared captured/specialized owners. The documentation explicitly describes fixed capture preparation, holding rather than clearing correction, and continued downstream settling.
- **Scope clarification:** The coordinator confirmed that GPU capture support is required only for Algorithms that already supported capture. `ClosedLoopIntegratorF32` continues sharing the CPU correction plan/workspace; this change does not add a new GPU capture implementation for it.

## Validation evidence reviewed

- `fail-before.log`: the new loop-state test cannot prepare the previously absent `closed` Property.
- `cpu-final.log`: new correction hold/state tests **45/45**, leaky hold/state tests **14/14**, and existing controller, Property, failure, IEEE arithmetic, alias, allocation, and Float64 tests pass.
- `cuda-focused.log`: new open correction replay tests **26/26** and open leaky replay tests **12/12** pass, together with existing closed capture, hidden-mode, numerical-failure, and history tests.
- `graph-focused.log`: authored Boolean Properties, held output publication/metadata, state retention, ordinary Property transactions, and rejection of specialized-owner mutation pass.
- `pipewire-focused.log`: Boolean adoption **15/15**, existing Property/control handoff, generation, reset, and cross-thread snapshot tests pass.
- `rtc-loop-integration.log`: cross-codec RTC loop command integration **39/39** passes.
- Independently ran `git diff --check`: clean.

This review inspected source and the supplied local evidence; it did not rerun the software suites or add hardware validation. AMDGPU device execution was not demonstrated by the supplied logs; the shared GPU source was reviewed. No claim of physical plant freeze or hardware correctness follows from these software checks.
