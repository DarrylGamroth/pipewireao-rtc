# JFG exported control environment SDK compatibility

## Confirmed defect

**JFG-SDK-001 — stale exact SDK compatibility survives staging.** At RTC revision
`908f75e`, `HILExport.julia_owner_environment` replaces the owner environment's
PipeWireAO source with `../../hil/packages/PipeWireAO`, but preserves its original
compatibility entry. An exact `=0.6.13` requirement therefore survives staging SDK
0.6.16, even though that selected source cannot satisfy the old requirement.
Both production HIL export and deployment calibration export call this helper.
This finding is independent of the scientific JFG graph and algorithm files.

The independent fixture starts with exactly that old pin and a staged SDK
Project declaring PipeWireAO's canonical name/UUID and version 0.6.16. The original
helper leaves `=0.6.13`, failing the exact-version assertion. The same fixture
passes after the correction, with `=0.6.16`. Original before/after output and the
fixture are retained under
[validation/jfg-staged-sdk-20261006](validation/jfg-staged-sdk-20261006).

The historical cached `classic-jfg-native-v10/jfg/deployment/Project.toml` also
retains `=0.6.13` while its staged SDK Project declares 0.6.15. That cache is
corroborating metadata, not fresh runtime qualification or authority. Root's
manual cache refresh for the current scientific run does not correct the
production export helper.

## Correction

The helper validates the Project at the fixed staged SDK path before writing the
owner Project: canonical PipeWireAO name, UUID, and a parseable declared Julia
version are required. It verifies the related owner dependency UUID, installs
that dependency if absent, and writes an exact compatibility requirement for
this staged version. It does not select a new SDK, replace scientific packages,
or modify unrelated dependency, compatibility, source, or metadata entries.
The existing ThreadPinning bootstrap dependency update remains in effect.

The existing override rule is preserved: an owner with no PipeWireAO source
mapping can be staged normally; an existing mapping is accepted only with
`refresh=true` and only when it is exactly
`{path = "../../hil/packages/PipeWireAO"}`. An arbitrary path, URL, extra fields,
or even an alternate spelling of the path remains inadmissible. Invalid staged
identity/version or owner PipeWireAO UUID rejects before writing the owner
Project. Refresh can update the exact pin when the SDK already staged at that
same path changes version.

Production HIL export stages packages before calling this helper. Deployment
calibration export copies the base `hil` tree before its refresh call, retaining
the staged SDK at the validated path. No caller or scientific file was changed.

## Verification and limits

All checks ran on CPU11, Julia 1.12, offline, with no native build, install,
scientific cohort, or GPU execution:

- Identical standalone discriminator: one expected assertion failure before;
  pass after, reporting exported compatibility `=0.6.16`.
- Portable exporter suite: **319/319** checks pass, including **41/41** new
  staged SDK contract checks. Coverage includes preservation of unrelated
  entries, the old exact pin, same-path refresh and version change, missing SDK
  Project, wrong/missing name or UUID, invalid/missing/non-string version,
  arbitrary source overrides in both refresh modes, and wrong owner dependency
  identity. Rejections preserve owner Project bytes.
- The prior bootstrap environment fixture now stages a valid SDK Project and
  checks the resulting exact SDK compatibility.
- `git diff --check` passes. The portable fixtures intentionally use non-Git
  package directories; their existing Git-provenance probes emit two benign
  `not a git repository` messages, without test failures.

Reproduction from the RTC checkout:

```sh
taskset -c 11 env JULIA_PKG_OFFLINE=true julia --startup-file=no \
  --project=deployment/julia \
  docs/validation/jfg-staged-sdk-20261006/discriminator.jl
taskset -c 11 env JULIA_PKG_OFFLINE=true julia --startup-file=no \
  --project=deployment/julia deployment/julia/test/test_exports.jl
```

These checks establish metadata correction and exporter regression behavior.
They do not claim a fresh complete production package resolution, relocated
installed JFG run, scientific acceptance, or performance qualification. Root
owns the independent review and fresh installed export/run gates.
