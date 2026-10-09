# Independent package boundary review

Astra first reviewed the proposed split against shared `4bc5c5d`, then reviewed
the implemented extraction against `3101c5a`. PKG-001 through PKG-006 were
originally migration risks demonstrated by existing coupling, explicitly not
confirmed defects in an implemented split. PKG-001 and PKG-006 subsequently
became confirmed extraction findings; PKG-007 through PKG-009 were added during
implementation review. The primary agent verified and remediated the confirmed
findings. The reviewer ran no services or tests; software execution and final
exit status are primary-agent evidence.

PKG-010 was found by the primary agent during final diff review and independently
checked against the guard, regression test and recorded fail-before result.

Priorities below preserve the original review. The original reports did not
assign a separate confidence rating. “Confirmed” denotes a defect established
from implementation source; “migration risk” denotes a conditional failure
identified during design review, not observed breakage.

| ID | Original priority / classification | Evidence and remediation | Disposition |
| --- | --- | --- | --- |
| PKG-001 | P1 / confirmed | Instrument completeness checks disappeared from shared installation; the campaign initially bypassed the new app preflight. REVOLT now validates its runtime and wrappers before install/start, and the campaign calls that preflight. | Closed in source and package checks. |
| PKG-002 | P1 / migration risk | Existing instrument wrappers selected `../julia` and modules under PipeWireAODeployment; moving modules without coordinated changes would break loading or sealed-wrapper comparison. Fresh SDKs have separate projects, relative app-to-common resolution before sealing, and instrument wrappers loading REVOLTRTC. | Addressed by implementation; export/relocation checks recorded. No implemented defect was reported under this ID. |
| PKG-003 | P1 / migration risk | The isolated export test defines a no-op staging method. Aliasing the shared staging generic would let that override alter shared behavior. The implementation instead uses an instrument-local forwarding function. | Risk avoided; binding identity tested. No shared-function pollution was observed. |
| PKG-004 | P1 / migration risk; boundary clarified | Existing profile validation names Classic/Copper and HEART roles, creating a risk of retaining instrument policy in common code. The implementation retains native v1 profile recognition and correlation as compatibility contracts; instrument geometry and site defaults belong to REVOLT. | Accepted boundary clarification; no confirmed relocation defect. Package identity/version rejection is separate evidence for PKG-001/008, not proof of policy extraction. |
| PKG-005 | P2 / migration risk | Existing resource fallback and hard-coded launcher paths coupled operational and instrument assets. Templates and the generic parameter-source launcher now resolve shared resources; cold bridges select declared SDK or loaded package sources. | Addressed by implementation; cold loading and relocation tested. No implemented defect was reported under this ID. |
| PKG-006 | P2 / confirmed | The design review identified both source inventories; implementation review confirmed that HEART transfer evidence omitted shared code. Campaign and transfer inventories now compose shared and instrument sources, with distinct prefixes for evidence copies. | Closed; source inventory checked. |
| PKG-007 | P1 / confirmed | Capture/replay initially bound only the old combined source root. Capture checks both roots and replay loads both projects. | Closed in final source review. |
| PKG-008 | P2 / confirmed | Isolated export namespaces cannot identify the installed app. Identity derives from the authoritative package_root function's owning module. | Closed; isolated export and tamper checks pass. |
| PKG-009 | P2 / confirmed | HEART/JFG integration tests remained in shared code while referencing removed modules/resources; the copied app package test was stale and excluded. Instrument tests now reside with their owner, and a rewritten app package/relocation test is included in its suite. | Closed in source; software checks recorded in receipt. |
| PKG-010 | P2 / confirmed; high confidence | Shared `ScienceExport.orchestration_sources` silently skipped a missing declared top-level runtime entry. The new `else` throws `ArgumentError`; the package regression test removes `wireplumber_cli.jl` only from a temporary exported SDK and requires rejection. | Closed. Source fix independently reviewed. Fail-before recorded: 112 assertions passed, one failed. Pass-after recorded: strict shared Pkg.test exited 0, with 1557 assertions across 41 testsets, including all 113 package-closure assertions. |

The preceding final seam pass found no remaining confirmed production defect;
the later PKG-010 source fix has observed pass-after evidence in
[shared-pkg-test-complete.log](shared-pkg-test-complete.log). A subsequent
strict Pkg run demonstrated that the export resolver inherited the test sandbox's
restricted load path and could not import Pkg. Its child-only environment now
uses `@:@stdlib`; the independent follow-up found no remaining defect in that fix.
Strict Pkg follow-ups also exposed undeclared direct test dependencies, including
PipeWireAO, PipeWireAODeployment and ThreadPinning for the cold bridge checks;
the test environments now declare these dependencies. These are subsequent
test-environment findings, not the original PKG-009 finding.

The original reviewed seam fingerprint was
`0fb9c6f21e6c97ef8430ac2f35bd09b0240311b47c91fabea22eb8bea66bb7b9`.
The subprocess fix supersedes the app ScienceExport component of that fingerprint;
reviewed file hash at that follow-up was
`1b644a7c4ffcf90329f062afaa9c039301b272e498fe24d4af01a3145af7bbab`.
Later docstrings do not change the reviewed runtime behavior.

PKG-010 fail-before evidence is
`~/.cache/rtc-julia-package-20261008/missing-entry-before.log`. Its test subprocess
returns nonzero if inventory generation silently accepts the missing entry;
only the expected `ArgumentError` satisfies the new assertion. No production
checkout file is removed by this test.
PKG-010 also supersedes the shared ScienceExport component of the original
fingerprint. Reviewed SHA-256 values are
`9775e16dad09130b2c5f5cd6487135ca1940a205aea6bd35138bed0bda81139d`
for shared `src/science_export.jl` and
`cca29801a6fb2fdc80e19e276f67e0b28d8f138af61613ecc776db18f94bb7db`
for shared `test/test_package.jl`.

This is source review and software qualification. Phase 5 live installed operation,
scientific acceptance and real-time resource qualification remain open.
