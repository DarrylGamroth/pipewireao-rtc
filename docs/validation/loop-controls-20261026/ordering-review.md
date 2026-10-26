# Independent dependency-ordering review

Reviewed commit `859677b770e141c42c937d211cc9295cc1160d7d` against `dc2b867b` in `/home/dgamroth/workspaces/codex/worktrees/aos-graph-ordering-20261026`.

## Findings

No actionable findings. No production files were changed during this review.

## Assessment

- **Observed:** `src/algorithm_graphs/preparation.jl:518` computes a cold Kahn topological order from direct links only. Each iteration scans declaration ordinals from the beginning, so newly released earlier nodes take precedence over later ready nodes. Processed nodes use a negative predecessor count and cannot be selected twice. Self-links and longer cycles leave no zero-count candidate and raise `AlgorithmGraphError` with delayed-link guidance.
- **Observed:** Direct endpoint, direction, format, and buffer validation still precede ordering (`preparation.jl:1121`). Reordered exact node preparation selects output owners by node name (`preparation.jl:1153`); graph inputs, named outputs, direct bindings, parameters, and delayed storage retain their existing identity-based construction.
- **Derived:** Context alignment is preserved. Stream and captured policies repeat the same context for every node (`preparation.jl:825`). Grouped admission still requires names in declaration order and direct edges strictly between earlier and later groups (`preparation.jl:912`); therefore every admitted grouped graph already has forward declaration dependencies and its stable topological order is the declaration order. No context permutation is needed.
- **Observed:** Scheduling and temporary adjacency storage are confined to preparation. Executable owners remain concrete tuples/NamedTuples. Enqueue, completion, reset, and delayed publication implementations were not changed; captured execution consumes the reordered tuple during preparation as well.
- **Observed:** Tests cover scrambled chains with a native stateful response node, disconnected/ready-node ordering, binding identity, reset identity, warmed zero allocation and inference, self/direct cycles, delayed feedback and async publication, fail-stop/reset, graph-file identities, and unchanged grouped admission constraints (`test/testsets/algorithm_graphs.jl:435`). Documentation describes the implemented ready-node selection rule and grouped exception consistently.

## Verification evidence

- Reviewed `fail-before.log`: the scrambled dependency-chain test fails under the old earlier-node restriction.
- Reviewed `final-validation.log`: focused algorithm-graph and second-order-response suites pass, including the added behavioral tests and existing grouped, ownership, failure, and boundary tests. This review did not rerun those suites.
- Ran `/home/dgamroth/.cache/aos-ordering-20261026/review-ordering-check.jl`: **1,074/1,074 assertions passed** on Julia 1.13.2. It evaluates the exact ordering helper source in an isolated module with simple endpoint stubs and compares every three-node directed graph (512 edge sets), plus duplicate-edge variants, against independently enumerated topological permutations. Cyclic cases must throw; acyclic cases must equal the lexicographically earliest valid declaration order.

## Limits

The supplied focused test evidence is host software validation. This review did not execute CUDA/AMDGPU stream or native capture tests, measure device behavior, run the complete package suite, or touch live services. Accelerator scheduling preservation above is a source-level conclusion. An initial package-loading attempt for the bounded extra check waited during dependency startup and was stopped; the isolated helper check completed without loading package dependencies.
