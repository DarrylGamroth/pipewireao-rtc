# Independent implementation verification

Date: 2026-10-14. Reviewer: independent Astra architecture reviewer.
Status: focused implementation checks pass; the primary agent's completed checkout and registered 0.1.1 Pkg.test logs also pass. IV-08 records the stale manifest self-name repair; IV-09 and IV-10 close the registered-source test-permission defect and core release evidence gate. This verifies bounded increments, not completion of the registered small-application migration.

## Source and scope

- RTC worktree: `/home/dgamroth/workspaces/codex/pipewire/PipeWireAORTC-implementation-20261014`, branch `codex/pipewireaortc-implementation-20261014`, starting commit `8a175c2a3608f74e66571617906d0aa8f8e5f580`. Reviewed actual staged/unstaged package rename, source moves, wrapper changes, dependency changes and untracked artifact implementation/tests. The package organization was subsequently committed as `fdc3f24`; final verification also read the artifact integration, saved parameter configuration v2 and owner entry points on top of that commit. These additions and associated documentation/tests were still working changes during the initial review. IV-09 and IV-10 record the subsequent immutable 0.1.1 release at `db9ebe7a18b255b2337edae23995c24faf151400`.
- WirePlumber worktree: `/home/dgamroth/workspaces/codex/pipewire/wireplumber-session-rejection-20261014`, clean at `63f2df2ff88c07add386e28912e54bdeb345661b`; compared with `d20cd2037fda7b5932b0feb58b0af5aef5226a48`.
- Read repository instructions, the accepted architecture findings, migration contract, implementation, focused tests, policy harness and correction report. The earlier Julia package-design and code-quality review lenses remain applicable.
- Production source was not edited by this reviewer. Only this report was written. Focused tests used temporary files and in-process Lua policy fixtures; no live services, PipeWire core, scientific owner, GPU or hardware were started or stopped.

## Verification dispositions

The IV identifiers are stable verification records. A closed record documents an accepted gate; an open record states remaining work rather than implying a demonstrated production defect.

### IV-01 — Original wrong-arity root-cause claim withdrawn; narrower parameter fix verified

**Severity P1 for the narrower source behavior; confidence high; classification observed in isolated policy execution; disposition fixed at the isolated policy boundary.**

The original RAR-01 description omitted the existing inner `pcall(dispatch, ticket)` in `src/scripts/ao/session.lua`. That wrapper distinguishes pre-operation errors from operations whose effects have been issued. Before `begin`, errors receive a correlated negative completion; they do not reach the outer ingress fault handler. The protection exists at `d20cd203`, so wrong arity was not a valid fail-before example.

Independent replay used the new unchanged harness against three baseline files extracted from Git into a temporary directory: `session.lua`, `ao-control.lua`, `ao-session-control.lua`. Results:

| Source / case | Observed result |
| --- | --- |
| d20cd203 / wrong arity | Exit 0; 2 Ready/Running cases pass |
| d20cd203 / malformed operation-14 element-type field | Exit 1; lifecycle=5, source=1, graph=1, withdraw=1, publisher=1 |
| 63f2df2 / complete regression harness | Exit 0; 44 malformed/state cases pass, plus valid/duplicate requests and post-handoff/core/identity/expiry cases |

The narrower defect is real in this harness: an operation-14 request with an Int where the element-type String belongs reaches the owner after `effects_issued = true`; owner rejection then faults the session. The fix adds `validate_parameter` at `session.lua:423` and calls it before `begin` at `:534`. It validates String scalar types/UTF-8/NUL/length, F32_LE, an Id-array shape, positive dimensions and a multiplication-safe 512 MiB extent. These match the relevant Julia codec rules in RTC `src/native/native_runner_codec.jl:182–190,250–254,291–299,336–345`.

The production diff changes neither envelope/token admission nor duplicate replay, operation IDs, owner sequencing or post-effect fault behavior. It does not read files or interpret scientific values. The harness proves token consumption and correlated negative completion for malformed requests, unchanged epoch/no publisher/no hold/stop/withdraw, subsequent Status success, exact extent-boundary acceptance, and retained fault/cleanup ordering after accepted handoff.

Limit: the harness uses POD and owner fixtures and a seeded prepared policy state. It is not native POD serialization or the actual Julia parameter-owner execution. Full Meson, installed native-policy integration and live session qualification were not run. No claim that all remaining invalid scientific declarations are harmless is made; owner-local validation and accepted-effect semantics remain separate.

### IV-02 — Package identity, shared module identity and moved implementation verified

**Severity P2 review gate; confidence high; classification observed/source-derived; disposition accepted for the package-organization increment.**

`Project.toml:1–3` names PipeWireAORTC and preserves UUID `a3e2c7da-f73f-4284-8482-36ac422b34e6`. `src/PipeWireAORTC.jl` includes the moved configuration, deployment, native and owner implementation and then the former root configuration/launch/install/CLI modules. These use parent-module imports rather than new copies of the modules.

The four root `wireplumber_*.jl` files import the corresponding package bindings. The CLI alone keeps executable argument/exit dispatch. The wrapper identity checks prove these are the exact same module objects, including CLI references to configuration/launch/install. No coordinator or alternate authority was introduced.

A source comparison normalized only the package name and compared moved native/owner/deployment/configuration files with the baseline. All matched except the intended recursive `validate_runtime` source check. The former root module implementations differed only in parent imports, removal of source inclusion, documentation and moving executable dispatch into the root wrapper. Native codec behavior is therefore unchanged by the reviewed move; this is a source-diff conclusion, not a full native-protocol execution result.

Independent `test/test_package.jl` and `test/test_runtime_export.jl` execution passed **213 assertions**: module/wrapper identity 28; named package/export/relocation 125; rejected legacy SDK preservation 4; entry selection 31; shared helper identity 5; source closure 11; recursive required-entry validation 9. The checks compile/load a fresh copied export, move it, load it from the new location and re-export without changing sealed source bytes.

Compatibility boundary: `using PipeWireAODeployment` is not aliased to the new import name. Existing downstream source callers need migration, and old sealed SDKs retain their original launchers. These tests validate the renamed compatibility export path; they do not prove that the new installer can operate on arbitrary old SDKs or that a registered data-only application exists. `src/configuration/deployment_configuration.jl:396–438` still intentionally validates a copied SDK layout.

### IV-03 — Owned-memory FITS implementation passes focused conversion and lifetime gates

**Severity P1 artifact-contract gate; confidence high for tested behavior; classification observed/source-derived; disposition implementation and normal package import accepted; IV-04 records integration closure.**

The reviewed `src/artifacts.jl` returns `PreparedArtifact.data::Array{T,N}`, owned independently of the FITS handle. It reads a bounded original byte snapshot from a regular non-symlink file, rechecks opened identity and file metadata, and closes the descriptor in `finally` (`:71–103`). Decoding uses the in-memory FITS snapshot (`:185–227`), so subsequent pathname changes do not change the decoded source or its original hash.

Targets are limited to Float32/Float64/UInt8/UInt16/UInt32/Bool. Dimensions and byte products are checked before allocations; every multidimensional selection requires an explicit permutation. Conversion rejects nonfinite values, floating overflow and inexact integer/Bool values. FITSIO constructs ImageHDU using CFITSIO's equivalent image type; scaling is handled before conversion. The code records BSCALE, BZERO and BUNIT without claiming unit conversion or schema validation.

`pack` uses an owned transient byte vector and explicit little-endian shifts. Reversed logical iteration gives row-major wire order. It writes no raw artifact files. Original and prepared hashes describe preparation-time values; the documented mutable data array can later change without changing its provenance record. Callers must not treat that record as a fresh integrity assertion for a mutated array.

Independent execution of `test/test_artifacts.jl` passed **134 assertions**:

| Test set | Assertions | Relevant contract |
| --- | ---: | --- |
| Selection and owned arrays | 61 | Nonsquare axis mappings, explicit square axes, 3-D permutation, HDU selection/rejection, independent ownership, exact known bytes, source deletion after prepare |
| Cancellation and snapshot ownership | 17 | Same exception propagated before/mid/late preparation, no returned partial artifact, original/no-new-file checks, source replacement after snapshot |
| Conversion and metadata | 39 | Exact integer/Bool rules, nonfinite/overflow, negative zero, Float64 bytes, scaling and unit metadata, null/compressed/table rejection |
| Limits before image allocation | 17 | Invalid dimensions/types, missing/symlink/compressed input, input extent and large decoded-image header |

The first run explicitly included `src/artifacts.jl` while integration was still landing. After integration, a separate fresh Julia process loaded `PipeWireAORTC.Artifacts` normally, asserted public/parent-module identity and passed the same 134 assertions. Thus the final result includes the normal package-import gate, not only an explicit-source test.

Cancellation is cooperative between bounded reads and conversion/packing chunks and around decode/hash operations. It is not a measured upper bound on CFITSIO read or SHA cancellation latency. Bounds are per source/decoded/target allocation, not aggregate memory bounds. Current preparation checks type/shape/conversion, not the scientific declaration's schema/expected units or executor adoption; those remain owner integration obligations.

### IV-04 — Artifacts package entry-point integration verified

**Severity P1 completion gate for the new public API; confidence high; classification observed; disposition normal-import gate closed.**

At the initial snapshot, `src/PipeWireAORTC.jl` did not include `artifacts.jl` or declare Artifacts public, and `test/runtests.jl` did not include the new test. The primary agent was notified; this was an active integration step, not an algorithmic defect.

The final entry point includes the implementation and declares Artifacts public; the test entry point includes `test_artifacts.jl`. A fresh normal `using PipeWireAORTC.Artifacts` plus `Base.ispublic` and parent-module identity checks passed, followed by all 134 artifact assertions. Root Project/Manifest resolves FITSIO 0.17.5. The final test Project also declares FITSIO directly with compat 0.17. The initial focused checks did not exercise full Pkg.test environment isolation; IV-08 records the later failure and verification of its repair.

### IV-05 — Remaining migration obligations are explicit and unclosed

**Severity P1 for the full requested application; confidence high; classification observed; disposition deferred to subsequent implementation gates, not a regression in this increment.**

AAR-01 copied-SDK elimination and the complete registered scientific application, AAR-03 configuration-driven scientific owners, the remaining AAR-04 scientific source inclusions, AAR-06 upstream introspection and AAR-07 additional acquisition identities remain open. IV-10 closes only the shared core package registration/test slice. Source-copy export/validation and raw-file runtime parameter readers remain. IV-06 verifies FITS startup preparation in the sparse parameter publisher; it does not establish JFG/FGN scientific owner startup or live adoption. No registered fresh-depot small Classic application, FGN memory-adoption parity, numerical equivalence or isolated live-session reliability result was produced by this review.

The migration document accurately retains those limits and the corrected RAR-01 cause. Hsm and Agent remain explicitly deferred. The existing immutable v1 records, WirePlumber authority, systemd supervision and scientific ownership remain controlling.

### IV-06 — Saved parameter configuration v2 prepares FITS before publication

**Severity P1 data/compatibility gate; confidence high for the bounded checks; classification observed/source-derived; disposition accepted for cold sparse-parameter preload.**

`src/owners/native_parameter_source.jl:165–228` explicitly distinguishes saved configuration versions 1 and 2. Version 1 retains absolute raw `initial_payload_path`; version 2 accepts `initial_artifact` and resolves its path against the saved configuration directory. Wrong-version fields are rejected. This is a new saved-file version, not a reinterpretation of the native v1 request. All source declarations, names/mapping uniqueness, dimensions, layout, aggregate packed extent and FITS selections are checked in the first pass; artifact reads start in the second pass at `:231–243`. Control/bootstrap endpoint-name collisions remain a separate check in `run_owner` at `:469`, before stream construction.

FITS preparation produces an owned Float32 array, then privately owned publication bytes: explicit row-major packing or a copy of the contiguous column-major bytes on the already-required little-endian host (`:235–240`). Both conversions occur before `prepared!`, Connect admission and stream construction (`:467–483`), outside callbacks and the PipeWire lock. The original/prepared provenance is retained with an additional hash and layout for the publication bytes (`:246–249`). No packed file is written. These hashes record the initial preload; subsequent native v1 raw-file updates can change `source.bytes` and do not refresh this initial provenance. The private Source field was subsequently named `initial_provenance` (`:135`) to state that lifetime explicitly; its initialization and behavior are unchanged.

The first source object remains unconnected with sequence zero. Existing connection logic still assigns initial preload sequence one (`:434–438`); the live raw-file request path and its sequence/acknowledgement handling were not changed by this diff. A saved FITS preload therefore does not imply a controller ticket, new protocol operation or scientific adoption acknowledgement.

Independent final `test/test_parameter_fits.jl` execution passed **33 assertions**, including nonsquare axes and exact row/column bytes, provenance/publication hashes, no new payload files, cancellation propagation, invalid version/selection rejection, idle declarations and legacy raw bytes. The initial 32-assertion test checked only `ArgumentError` for a later invalid declaration, which could also arise when opening an earlier missing FITS file. An additional reviewer probe checked the actual diagnostic `parameter source supports only F32_LE` and confirmed the intended ordering. The primary agent then strengthened the checked-in test to require that diagnostic; the final 33-assertion rerun passed. This validation gap is closed without a production change.

Cancellation checks surround declaration preparation and propagate through Artifacts; no partial source list is returned. Column-major copy and publication hashing have checks around the stage, not an interruptible inner loop. No cancellation latency, total peak memory, native publication or JFG/FGN adoption claim follows from these checks. Required subsequent validation remains isolated native startup/publication and owner adoption; scientific schema and expected-unit checks remain owner obligations.

### IV-07 — Shared owner entry points preserve endpoint and cleanup contracts

**Severity P1 ownership/cleanup gate; confidence high for source and fixture behavior; classification observed/source-derived; disposition accepted for the reusable entry-point increment.**

`src/owners/native_parameter_source.jl:620–651` moves the existing argument validation into private `_owner_options` and exposes `main`. Required arguments, absolute paths, endpoint-name syntax/distinctness and positive Int64 instances are retained. `assets/deployment/hil/parameter_source.jl:1–5` now dispatches to this package method; it does not define another runtime or module copy.

`src/owners/native_owner_bootstrap_runtime.jl:537–558` constructs the existing bootstrap Runtime before calling the cold owner body, then supplies the same runtime and a cooperative preparation check. The owner body remains on the caller thread. The helper invokes `finish!` and then `close` even after the body fails, retaining body/finish/close exceptions in order. Accepted cancellation suppresses an InterruptException but preserves cleanup failures; an interrupt without cancellation remains an error. Existing `fault!` only records the main error under the runtime lock (`:303–307`); existing `finish!` clears hooks, marks completion and waits for the monitor (`:309–319`). No additional lifecycle coordinator, supervisor or admission authority was introduced.

Independent `test/test_owner_entrypoints.jl` execution passed **49 assertions**: argument preservation/rejection 24; injected-runtime options and deterministic cleanup 16; cancellation/error preservation 9. The runtime fixture verifies helper control flow and exception identities. It does not create a native bootstrap endpoint or prove monitor shutdown under a live core failure. The public normal-import path, source-order construction-before-body and unchanged existing runtime ownership were also inspected. Live bootstrap/FITS cancellation and native shutdown remain subsequent integration gates.

### IV-08 — Stale manifest package identity blocked isolated test loading; repaired

**Severity P1 package-delivery gate; confidence high; classification observed metadata and execution evidence; disposition fixed, isolated test gate closed.**

The renamed package initially retained `[[deps.PipeWireAODeployment]]` for its own UUID in Manifest.toml, even though root and test Project files named PipeWireAORTC. The earlier main-project import and focused tests did not detect this mismatch. The primary agent subsequently reported that full Pkg.test failed isolated loading. The worker's `/tmp/pipewireaortc-manifest-fail-before-20261014.log` is a fresh metadata-only import replay, not the original full-test transcript.

To remove ambiguity about that replay, the primary agent created a clean detached worktree at `fdc3f24471488cad3dc0c5667631aca6782691b4`: `/home/dgamroth/workspaces/codex/pipewire/PipeWireAORTC-rename-reproduction-20261014`. This reviewer independently ran the same `julia --startup-file=no --project=test -e 'using PipeWireAORTC'` command there and in the corrected implementation worktree. The baseline exits 1 with `ArgumentError: Package PipeWireAORTC [a3e2c7da-f73f-4284-8482-36ac422b34e6] is required but does not seem to be installed`; the corrected worktree exits 0. The primary agent also preserved these results in `/home/dgamroth/.cache/pipewireaortc-registration-20261014/rename-before.log` and `rename-after.log`. The metadata and matching fail-before/pass-after command establish the package-isolation defect; this is not a FITS conversion or protocol defect.

The repair used Pkg in an anonymous temporary project to remove the stale self entry, followed by resolution in the real workspace with the test self dependency restored. This reviewer read the migration script and independently parsed the preserved pre-repair `/tmp/jl_7IhREl/Manifest.before.toml` and final manifest: **all 59 complete nonself dependency records are identical**; the complete self record is also identical except that its table name is now PipeWireAORTC. The top-level project hash changed with the final workspace metadata. No dependency version, source revision, tree hash or transitive dependency was silently changed by this repair. The earlier FITSIO dependency additions are a separate intentional change relative to `fdc3f24`.

Final `Manifest.toml:188–192` has the canonical self name, unchanged UUID/version and path `.`. `test/Project.toml:2–5,12–19` declares FITSIO and PipeWireAORTC directly, points the latter to `..` and retains matching compatibility bounds. `test/test_package.jl:8–11` now asserts that exactly one manifest record has this UUID and that its name is PipeWireAORTC. Independent execution of the updated package test passed **158 assertions** (29 identity/metadata, 125 export/relocation, 4 legacy rejection).

The primary agent's completed `/tmp/pipewireaortc-pkg-test-20261014.log` was independently inspected: isolated environment setup names PipeWireAORTC correctly, all **53 testsets / 1,848 assertions** pass, and Pkg reports `PipeWireAORTC tests passed`. This includes the updated initial-provenance field and all three new test files. This reviewer did not duplicate the full Pkg.test process. The fail-before evidence and pass-after full test execution close this package-isolation gate; they do not establish a fresh-depot registered installation, native live session behavior or scientific owner parity.

### IV-09 — Registered-source tamper fixture assumed writable copies; test-only repair verified

**Severity P2 test-portability defect; confidence high; classification observed/source-derived; disposition fixed; focused regression and registered 0.1.1 full-suite gates closed (IV-10).**

After core commit `385cb64`, the primary agent installed immutable registered 0.1.0 in a fresh depot and ran its package tests. The archived `docs/validation/registered-core-20261014/registered-0.1.0-Pkg.test.log:236–238` identifies the failure: the existing deliberate-tamper fixture attempted to write the temporary copied `Project.toml` and received Permission denied. The test had assumed copied package sources were writable; Pkg-installed source files are read-only and the existing export preserves their permissions. The registered suite reached and passed module identity and export/relocation checks before this test error. A successful checkout suite in IV-08 therefore did not establish registered-source test portability.

The reviewed patch changes `test/test_package.jl:117–127` only: it first sets the temporary copied Project file to mode 0444 and checks that no write bit remains, derives the version substitution from `Base.pkgversion(P)`, asserts that bytes actually change, then grants owner-write on that temporary file before intentionally corrupting it. The unchanged rejection assertion still requires the SDK validator to reject the altered package. Production export/permission behavior, the installed source tree and native/scientific code are unchanged. Forcing read-only mode makes the same condition occur in ordinary checkout tests as well as registered installations; using the actual package version preserves the tamper operation after a version bump.

The worker's `/tmp/pipewireaortc-readonly-fail-before-20261014.log` demonstrates the same Permission denied with the read-only fixture and without its permission repair. `/tmp/pipewireaortc-readonly-pass-after-20261014.log` passes after the repair. This reviewer inspected both logs and independently reran the final package test: **160 assertions pass** (29 module/metadata, 125 export/relocation, 6 legacy rejection/read-only tamper checks).

Root `Project.toml:3` and the manifest self record at `Manifest.toml:192` advance from 0.1.0 to 0.1.1. An independent parsed comparison against `385cb64` confirms the **entire Manifest differs only in that self version**; all 59 nonself dependency records and all other metadata remain identical. At this focused verification stage, publishing a new immutable 0.1.1 tree and checking its registered full suite remained pending. IV-10 records their subsequent completion; the already registered 0.1.0 tree was retained. Other migration obligations in IV-05, including the small scientific application and Hsm/Agent deferral, are unchanged.

### IV-10 — Registered core release evidence verified; scientific migration remains open

**Severity P1 core-delivery gate; confidence high for inspected evidence; classification observed metadata/logs; disposition core registration and registered test gate closed.**

This final pass inspected evidence only; it ran no new tests and changed no production source or registry. The primary agent executed the registered 0.1.1 full suite. This reviewer independently counted **53 passing testsets / 1,850 assertions** in `docs/validation/registered-core-20261014/registered-0.1.1-Pkg.test.log` and confirmed its final `PipeWireAORTC tests passed` marker. The registration receipt records exit 0. The log identifies the installed package under the isolated depot's `packages/PipeWireAORTC/1VAn8` directory; direct filesystem inspection confirmed its Project file has version 0.1.1 and mode 0444. The permission condition behind IV-09 was therefore present in the registered test source.

Independent Git/tree and registry reads match the receipt: release commit `db9ebe7a18b255b2337edae23995c24faf151400` has tree `8f609ff2ca5940e2516a9ed7d6dcee4ff0878741`; the installed LocalRegistry is clean at `28d363f8d14b495c89947b76ff13afc925948afe`, and `P/PipeWireAORTC/Versions.toml` maps 0.1.1 to exactly that tree while retaining the separate 0.1.0 entry. The archived `application.Project.toml` has no `[sources]` overrides, and the parsed `application.Manifest.toml` has no path dependencies and records the same 0.1.1 UUID/tree. These are a core verification environment, not a scientific deployment.

The receipt accurately distinguishes an initially empty-depot 0.1.0 installation from the subsequent 0.1.1 update using cached dependencies. The initial install's transient unavailable registry-branch message remains visible in `fresh-install.log` and is explained in the validation README; it is not counted as a successful fetch. The 0.1.1 suite log also contains a precompilation notice about already-loaded dependency versions, followed by successful isolated Pkg test execution. No clean-warning-free or from-empty-depot 0.1.1 claim is made.

The receipt records published review branches, unchanged remote default branches and unchanged original service PIDs/invocation IDs. Those operational checks were performed by the primary agent; this evidence-only pass did not repeat remote or service inspection. Review-branch availability is distinct from promotion to the registry's remote default branch. Scientific dependency releases, package-owned scientific entry points, graph introspection, configuration/FITS-driven simulation, the small relocated Classic application, live lifecycle/science qualification and resource/hardware validation remain open. Hsm and Agent remain deferred. IV-10 closes the core package delivery slice and the IV-09 registered rerun, without closing those application gates.

## Reproduction and limits

Commands run by this reviewer:

```sh
# WirePlumber: pure in-process policy harness
python3 tests/ao/run-policy.py

# RTC: package/module identity, compatibility export and relocation
julia --startup-file=no --project=. -e 'using PipeWireAORTC; include("test/test_package.jl"); include("test/test_runtime_export.jl")'

# RTC: final normal-import artifact gate
julia --startup-file=no --project=. -e 'using PipeWireAORTC; using PipeWireAORTC.Artifacts; @assert Base.ispublic(PipeWireAORTC, :Artifacts); @assert parentmodule(Artifacts) === PipeWireAORTC; include("test/test_artifacts.jl")'

# RTC: saved parameter FITS preload and shared owner entry points
julia --startup-file=no --project=. -e 'using PipeWireAORTC; include("test/test_parameter_fits.jl"); include("test/test_owner_entrypoints.jl")'
```

Baseline replay used the same policy harness with `AO_POLICY_SOURCE` set to the temporary git-extracted baseline and `AO_POLICY_CASE` selecting `wrong arity` or `parameter element type field`. Source comparison and `git diff --check` completed without unexpected differences/whitespace failures. The updated package test was independently rerun for IV-08; the primary agent's full Pkg.test execution was verified from its completed log. No live lifecycle, GPU, performance or hardware checks were run by this reviewer. Tests establish the boundaries above, not timing or full application qualification.
