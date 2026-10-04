# Julia package remediation review

## Scope and baseline

Independent review of the agreed Julia package remediation across:

- JuliaFilterGraph worktree `/home/dgamroth/workspaces/codex/pipewire/JuliaFilterGraph-package-fixes`, baseline `eedcf55a089c4de0e58c9e80e4423f80cbab2dbb`;
- RTC worktree `/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-package-fixes`, baseline `bce24a8d953a694b4c98da3d9df1d116c2716fb6`.

Both worktrees contained the primary and remediation workers' in-progress changes at review start. The reviewer owns this document only and has made no production changes, commits, sibling changes or live RTC launches. The review follows the previously selected package structure rather than reopening it. Julia package quality/design skills and the RTC repository's active architecture/operations contracts govern the review. The existing migration evidence remains bound to its earlier sources.

**Final disposition: the selected Julia package remediation and named deployment conversion are independently verified. JPR-001 through JPR-007 are corrected; no required source or functional qualification defect remains open in this scope. Scientific, GPU, physical and performance acceptance remain outside this review.**

## Findings

| ID | Severity | Confidence | Evidence class | Disposition |
| --- | --- | --- | --- | --- |
| JPR-001 | Medium | High | Direct documentation/implementation contradiction | Corrected; final wording independently compared with implementation |
| JPR-002 | Low | High | Direct status-condition contradiction | Corrected; final wording independently compared with implementation |
| JPR-003 | Low | High | Direct numerical-failure-condition contradiction | Corrected; final wording independently compared with implementation |
| JPR-004 | Medium | High | Same service-template invariant fails before and passes after | Corrected; source and retained reproducer independently reviewed |
| JPR-005 | High | High | Copy-path condition admits recursively copied source subtree | Corrected; pre-mutation guard and retained portable checks reviewed |
| JPR-006 | Medium | High | Isolated package suite fails opening sibling test fixture | Corrected; isolated rerun passes |
| JPR-007 | High | High | Installed generated CLI rejects leading application flags | Corrected; same invariant and real installed cold exports verified |

### JPR-001 — Pyramid row documentation changes the publication cadence

Affected file: JFG `julia/FilterGraphAlgorithms/src/public_algorithm_docs.jl`, `PyramidRowReconstructorF32` docstring.

The initial new text says selected pupil pixels and mean intensity are published for each row block, while reconstruction completes with the image. Actual `_stage_pyramid_row_reconstruction!` in `algorithms/wavefront_sensor/pyramid_row_reconstruction.jl:354–363` calls `_publish_pyramid_pixel_row!` and copies the reconstructed result only when `result isa AlgorithmProcessResult && result.complete`. All three ports declare conditional publication. Row processing advances internal accumulation; it does not publish those full-image outputs at every row block.

This is a confirmed user-visible documentation defect with direct source evidence. It can mislead consumers about availability and acquisition cadence; no measured runtime failure is needed to establish the contradiction. Remediation must describe terminal publication for all three outputs without changing numerical or scheduling code. Verification must compare the corrected text with the terminal guard and existing conditional output contract; a `hasdoc` pass alone cannot establish correctness.

### JPR-002 — Incomplete-sample status is described as block-count failure

Affected file: the same new documentation file, `IncrementalDenseReconstructionIncompleteSample`.

The initial text says a sample ended before its configured measurement-block sequence was complete. Actual `incremental_dense_reconstruction.jl:293–296` first requires terminal sample metadata, then returns this status when `workspace.seen_count != length(workspace.seen)`: some required measurement columns were never accumulated. It is a coverage test, not a comparison with the configured number of blocks. Duplicate-column and out-of-range conditions have separate statuses.

Remediation must state that terminal input arrived before every required measurement column was covered. Preserve the enum and implementation. Verify the wording against the exact terminal/coverage condition and avoid asserting that a particular number of blocks alone ensures completion.

### JPR-003 — Numerical solve breakdown is documented as proven singularity

Affected file: the same new documentation file, `SccWeightedRegularizedReconstructionSingularSystem`.

The initial text says the weighted regularized system is singular at the attempted solve. The existing solver also returns this enum for nonfinite right-hand-side or residual norms and nonpositive/nonfinite conjugate-gradient scalar products; examples are `weighted_regularized_reconstruction.jl:306,314,338,345`. Those conditions can indicate numerical breakdown and do not establish mathematical singularity of the intended system.

Remediation must describe failure to continue the solve because of singular/degenerate or nonfinite numerical conditions. Keep the established enum name and values. Verification must inspect the return sites, including finite-data overflow paths; no solver or tolerance change is justified by this documentation correction.

### JPR-004 — Generated service uses the invoking installer’s template

Affected file: RTC `deployment/julia/src/deploy.jl`, `install` (current template selection near line 1068).

The named-package conversion initially selected the template from the installer’s loaded resource root. Installing an incoming sealed SDK could therefore preserve its template bytes yet generate a unit from different bytes in the invoking SDK. This violates the incoming package’s ownership of service policy even when both SDKs have compatible package versions.

The retained `template-selection/rtc-template-selection-invariant.jl` uses an incoming-template marker and separately checks sealed-byte preservation and generated-unit selection. The same invariant reports one pass/one failure before and two passes after. The reviewer read the reproducer, both logs, and corrected selection of `installed_julia/assets/deployment/pipewireao-rtc@.service.in`. This closes the source-selection defect; actual service lifecycle qualification remains a separate gate.

### JPR-005 — Runtime copying admits a destination inside copied resources

Affected file: RTC `deployment/julia/src/science_export.jl`, `copy_deployment_runtime` (current lines 68–80).

The first overlap guard checked only the package source directory. A checkout destination such as `deployment/hil/nested-output/julia` or `deployment/templates/nested-output/julia` remained admissible although those resource trees are subsequently copied recursively. Copying into those trees can discover its own output and recurse until filesystem failure. The retained `resource-overlap-before.json` evaluates the old admission condition without mutating source resources; it is analytical path evidence, not a deliberately destructive copy experiment.

The correction checks the nearest existing destination ancestor, resolves real paths, and rejects both descendant and enclosing overlap against all three recursively copied roots before removal or copying. The reviewer inspected the predicate and tests for package, HIL and template roots, preservation of source inventory, and an unrelated allowed child of the checkout deployment directory. The retained full portable run passes 479 assertions. No recursive-copy failure was intentionally induced in a live source tree.

### JPR-006 — PipeWire package tests still read sibling package fixtures

Affected files: JFG `julia/FilterGraphPipeWire/test/runtests.jl`, `linked_row_graph.jl`, and `closed_loop_feedback.jl`.

The first independently staged package run reached a real missing-file error opening `../../JuliaFilterGraph/test/fixtures/closed-loop-correction.conf`; the retained `independent-package-tests.log` identifies the exact staged path and call chain. Three sibling configurations were then copied byte-for-byte into the PipeWire package’s own test fixtures, references made local, and canonical source/SHA records added. The reviewer independently matched these records to canonical bytes and read the successful `independent-pipewire-retest.log` completion. FGA and JFG had already passed the original isolated run. This is a package-test distribution correction, with no runtime algorithm change.

### JPR-007 — Generated installed CLI consumes application flags as Julia flags

Affected file: RTC `deployment/julia/src/deploy.jl`, generated `-e` entrypoint wrappers.

The primary’s actual cold installed export failed because generated `julia -e ... "$@"` commands lacked the `--` separator before application flags. The previous include-based command had a positional SDK argument that masked this requirement. The observed failure blocks installed cold export and therefore deployment closure. Remediation must separate Julia and application arguments, preserve the CLI exit status, and verify every generated wrapper with real leading flags. The final generator now executes `exit(PipeWireAODeployment.<owner>.main(ARGS))` with `--` before application arguments; all seven owner mains explicitly return zero on successful completion. The four campaign/method owners previously ended with `println` and now return zero without changing their operation. The reviewer inspected the generated installed wrapper, all seven return sites, and the same executable invariant: before, Julia consumed `--version` and returned its own success while rejecting `--base-package`; after, the application parser owns both arguments and all eight assertions pass. Portable checks execute all seven generated wrappers. Real installed Classic/Copper HIL and HEART exports also complete through the corrected wrappers. This closes JPR-007; final live lifecycle qualification remains separate.

## Design observations and qualification requirements

The candidate FGA 0.5.6 / JFG 0.2.4 / FGPW 0.1.2 identities and tightened local provider floors address the earlier mixed-provider ambiguity in principle. The reviewed metadata and resolved lock retain those identities consistently; the candidates have not been registered. The final JFG source is clean commit `f2f4cd4e269a63887c6d55f915d97d674fd18687`. External dependency versions are unchanged.

The new FGA documentation was read as scientific/API text, not just counted. The closed-loop recurrence, constraint-feedback sign and dimensionless gain declarations match the existing implementation. Detector calibration retains flat × (raw − background); weighted centroid documentation retains dimensionless weights and weighted-flux threshold semantics. Stateful declarations keep local adoption/commit semantics. The three specific contradictions above have been corrected and independently checked against the implementation.

The RTC package now has a stable named identity, standard `src` and `test` directories, an explicit test workspace and ordinary package-loading entrypoints. The root/resource lookup is dynamic through `pkgdir`, rather than a source path captured during precompilation. Inspection of the moved implementation diff shows path/loading/source-inventory changes, installer compatibility admission and the Parameter constructor correction. No change to the scientific algorithms or to native frame execution is intended.

`CalibrationCampaign.orchestration_sources` recurses into package source/resources and hashes the executed outer Julia wrappers. `source_relative_path` preserves distinct package/resource paths for frozen method evidence. The SDK copier includes the named package and test workspace needed by normal Pkg operations; HIL execution retains its separate dependency environment. Cold preparation, recursive seals, precompiled relocation, foreground/service control and real finite acquisition checks are verified below. The finite acquisition scope uses the existing sealed scientific bases rather than repeating an interaction-matrix campaign.

The new installer explicitly rejects a legacy include-loaded SDK before copying it, preserving its original sealed launcher. This is a deliberate compatibility boundary to document, not permission to rewrite historical sealed packages in place. New packages and newly generated service units must retain the established main-process readiness, SIGINT cleanup and source identity contracts.


## Independently checked corrections and resource snapshots

The reviewer re-read all three corrected docstrings against their implementation sites. Pyramid row documentation now distinguishes per-block accumulation from complete-image publication of all three outputs. The incremental status now identifies missing required measurement-column coverage at terminal input. The SCC status now explicitly includes an invalid/below-minimum preconditioner diagonal, nonpositive/nonfinite CG inner products and nonfinite right-hand-side/residual norms, without claiming mathematical singularity. JPR-001 through JPR-003 are corrected; no algorithm implementation changed for these fixes.

A static independent byte/hash comparison matched all 67 records in the four new JFG package test snapshot manifests to the canonical repository files. Copied example scripts resolve their accompanying configuration files locally. The external schema/inventory and launcher-integration tests are removed from default package entrypoints and retained in `scripts/package_tests/runtests.jl`; canonical schemas/examples remain repository authorities. The retained isolated runs load each provider from a separately staged package directory with no repository fixtures/examples. FGA and JFG pass in `independent-package-tests.log`; the FGPW correction passes in `independent-pipewire-retest.log`. The separate repository integration log passes 439 assertions, including canonical snapshot consistency and the retained schema/inventory/launcher tests. These are CPU software tests; they do not qualify GPU or live PipeWire execution.

The reviewer compared the parsed JFG deployment Manifest against the baseline: only the three local package entries change versions (FGA 0.5.6, JFG 0.2.4 and FGPW 0.1.2). All external dependency entries are unchanged. Candidate identities are not a claim of registry publication.

## Bounded verification of package boundaries and deployment guards

JFG and FGPW library Projects no longer declare sibling path sources. Their test Projects retain only the standard self-parent package source; the explicit `scripts/package_tests` consumer selects all three provider paths. This supports independently distributed packages while keeping monorepo development reproducible. The reviewer read the resulting Projects and independently staged consumer paths rather than treating an in-tree suite as standalone evidence.

The retained RTC `source-inventory-resource-overlap-fixed.json` contained 47 operational source/resource records at the overlap-fix checkpoint; every recorded SHA matched the worktree when independently checked. This checkpoint precedes JPR-007’s wrapper correction and must not be used as the final revised SDK identity. Its 479-assertion portable log includes the named-package relocation and complete test-workspace checks. The YAML duplicate-key diagnostic is emitted by the deliberate malformed-input test; the suite passes.

Evidence directories are `/home/dgamroth/.cache/julia-package-audit-20261003` and `/home/dgamroth/.cache/rtc-package-remediation-20261003`. The subsequent sections record final frozen source identities, installed cold exports, finite acquisition execution and foreground/systemd lifecycle verification. Earlier checkpoints remain historical.

## Final CLI and cold-export checkpoint

The final `rtc-package-tests-cli-flags-fixed.log` passes 511 portable assertions (343 existing plus 168 added), including package precompilation, relocation, service policy, source overlap and generated CLI argument checks. The reviewer read the executable invariant and raw before/after JSON/logs, rather than relying only on the summary.

The final operational inventory (`rtc-package-source-inventory.json`, SHA-256 `c1495e6be66739de90636ed5f8549319619494bb620f26b3787910052cdde336`) has 47 entries. Independent hashing matched every entry both to the current checkout and to `installed-runtime-v2`, resolving installed resources under `julia/assets/deployment`.

For all four records in `cold-exports-v2/report.json`, the reviewer independently checked descriptor SHA, every sealed artifact SHA and actual `execve` trace paths. Classic FGN HIL has 449 artifacts, Classic HEART 470, Copper FGN HIL 443 and Copper HEART 463; all match. The traces contain respectively 28, 6, 27 and 6 executed paths and no Python executable. These cold preparation results are complemented by the independently verified session and calibration-endpoint checks below.

## Installed HEART lifecycle verification

The reviewer independently checked all four final `cold-exports-v2/live-*/result.json` records against the installed deployment descriptor and every sealed artifact, actual retained simulator reports, frame/command payload SHA values, launcher/deployment-module/harness hashes, and current process/runtime absence. Each route completes two batches of 16 frames and 16 commands, with sequences 1–16, no source failure, stop/reset/restart, and native HEART generations 1→2. Captured PID/start-time identities, including both native generations, are absent; owned instance and runtime directories are absent.

| Route | Result SHA-256 |
| --- | --- |
| Classic foreground | `c19efddd7029b70b31ef2a5aef5f6c6e5fc1bba8f42eb06852e8d56c42c25c8b` |
| Classic systemd | `51d75ae1f189775160526dbb94538bb5078fd6b1eea51ef2eaac84b6852ffc37` |
| Copper foreground | `3e2331d66597ff03b97f47c97a2dcc67f068faf4a61c2a23629612b64b7d6785` |
| Copper systemd | `8281033307dbb781bc94be2c8c0963856e7db041e10fff7c36eb7ff39748cce2` |

Both systemd routes identify the ready Julia supervisor as `ExecMainPID`, then finish inactive/dead with `Result=success`, `ExecMainStatus=0` and `MainPID=0`. Their invocation error-priority journal files are empty. The actual units retain `Type=notify`, `NotifyAccess=main`, `KillSignal=SIGINT` and the 300-second cleanup allowance. Foreground final records are stopped and unadmitted; actual execution traces contain no Python. Systemd uses the same sealed launcher under restricted PATH; it was not traced by replacing its main process.

Logs retain DBUS-library and mixer warnings at startup and a format-unset warning at teardown. They also retain Julia precompilation diagnostics about already-loaded versions differing from newly generated caches. The observed batch, state-transition and cleanup checks pass despite these messages; this review makes no claim of quiet caches, bounded cold compilation latency or absence of all warnings. The selected simulator/adapter tuple and scientific limits of the earlier migration remain in force. Finite FGN/JFG calibration endpoint and final evidence-ledger verification is recorded below.

## Final finite acquisition and closure

The reviewer independently inspected both records in `finite-stages/qualification.json` and their identical `stage-result.json` copies. Each selected Copper FGN/JFG dark stage captures eight exposures and 180,768 payload bytes through the final installed SDK. Each has six requests with matching version/run/serial and the expected hold→adopt→settle→capture→restore→release completions. Restoration, release and shutdown are confirmed; launcher exit is zero; final state is stopped and unadmitted with no error.

Independent validation checked the capture manifest size/SHA, all 24 payload files per engine, exact raw/pixels/intensity type/shape/layout/size, settings and acquisition-domain association, consecutive sequences after settling, exposure chronology and the final completion cursor. Capture manifest SHA-256 values are:

- FGN: `da2b224f93aa2e0c7ae2282bccd36df2e3661b276e723c7b26eff3f6d6a07e34`.
- JFG: `0e3f6fadc010dc22d9acf13a2ec807e9986d7fa74d6778038a0ee76f1ea6f129`.

All 438 FGN and 565 JFG sealed package artifact hashes match after acquisition. The producer harness explicitly compares complete package identity before and after each stage and completes both checks. The reviewer independently verified absence of every PID recorded at readiness (four FGN processes and six JFG processes) and both owned instance directories before the primary’s final cleanup of empty runtime roots and linked test units. The foreground/systemd process-identity checks above additionally use saved process start times.

The final evidence ledger’s 47 operational source hashes matched the reviewed worktree, and all 87 directly bound evidence files matched their recorded SHA values, including export/foreground traces, service journals, raw batches, regression reproducers/results/logs and historical source-inventory checkpoints. The independently checked ledger SHA-256 is `240e350c55fd8a91940e478b1619c1f365e31159b47fb1190183f2ab6aa573a5`. Final package source identity is the inventory SHA recorded above and the complete per-file table in [the evidence ledger](JULIA_PACKAGE_REMEDIATION_EVIDENCE.json). No prior migration result has been relabeled as a run of this package conversion.

The resulting evidence supports the chosen standard package layout, standalone CPU package tests, corrected public documentation, relocatable installed deployment resources, foreground/systemd ownership and the finite operational acquisition boundary. It does not establish a newly measured interaction matrix, scientific correction quality, hardware performance, GPU cadence, latency tails, all dependency-version combinations or registry publication. The retained warnings and selected dependency-tuple limitations remain explicit. No additional required remediation is identified in the reviewed scope.
