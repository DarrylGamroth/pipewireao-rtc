# Independent root-layout review

Astra reviewed staged/unstaged changes against `4bc5c5d`; the primary agent
verified and addressed the findings. No live services ran during review.

| ID | Severity / confidence | Evidence | Disposition |
| --- | --- | --- | --- |
| ROOT-001 | P1 / confirmed | Three cold HIL bridges resolved nonexistent `assets/deployment/julia/src`; standalone include failed before startup. | Corrected explicit SDK and package-resource paths; standalone include passes and six loading assertions pass. Related native-test helper includes use the loaded package root. |
| ROOT-002 | P2 / confirmed | Maintained command guides referred to removed `deployment/julia` and `deployment/*.jl` paths. | Current guides and quickstart use the root project and moved resource entrypoints. Historical URLs and recorded evidence remain. |

Review found no additional defect in runtime inventories, resource/evidence
mapping, installed SDK wrappers or the explicit package-bound launcher path.
SDK-relative `../julia` remains intentional because exported SDK layout is retained.
The inherited `prepare_fault_teardown_test.jl` references retired APIs; it is not
qualified or repaired by this relocation and must be removed from maintained
paths in the remaining cleanup.

The phase-4 seam review additionally identifies PKG-001 through PKG-006: separate
owned inventories, instrument wrappers/projects, isolation of staging test
substitution, native-profile versus instrument validation, resource resolution,
and composed provenance. Those requirements are recorded in
[package boundaries](../../RTC_PACKAGE_BOUNDARIES.md#extraction-contracts).
They remain migration risks for the independent instrument split.
