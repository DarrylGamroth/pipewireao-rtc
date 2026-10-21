# Classic headless offline refresh review — 2026-10-21

Independent bounded review of RTC package commit
`fa8e4d5dcdb370f9acf3a9c28bc898e071ed919e` (registered source tree
`77e169a9512fa557ff3ee1e4871537fc5468d0ef`) and Classic application commit
`caaf9f4`, based on `841a6e665c5dc0d3d31eac3ba4e42b25cba5e713`.
Reviewed in the `pipewireao-rtc-classic-headless` and
`revolt-classic-rtc-headless` worktrees on `codex/classic-headless-offline`.
Both worktrees started clean; Classic's intended refresh was reviewed while
being prepared and again after its seal and commit. This review changes only
this record. No unresolved blocker remains within the offline scope.

## Finding

### CHO-01 — Lexical output containment allowed an application symlink alias

- Severity: P2. Confidence: high. Observed draft diagnostic defect.
- Affected code: Classic `check-offline.jl`, original output-path check; repaired
  by `external_output` at lines 6–20 in the reviewed application commit.
- Evidence: a fresh output below an external directory symlink targeting the
  application passed the original lexical `relpath` rule. Subsequent diagnostic
  writes could therefore create an evidence directory inside the application,
  contrary to its documented output boundary.
- Remediation: resolve the existing output ancestor and append the missing
  components before checking containment; reject existing outputs and dangling
  symlink ancestors before writing.
- Required validation and disposition: **resolved and independently verified**.
  A temporary alias to the real application reproduced acceptance by the old
  lexical condition. The repaired helper rejects that same path with
  `ArgumentError`, creates no application output, and accepts a fresh nested
  external destination without creating it. The final full diagnostic passes.

## Independently checked

- All 37 sealed artifact SHA-256 values match their current files. All 32
  original scientific/configuration assets outside the four intentionally
  refreshed metadata/environment files are byte-identical to the base commit,
  including calibration results, FITS artifacts, graphs, simulation settings,
  session/core/client templates and operator views.
- Classic's manifest changes only its `PipeWireAORTC` dependency entry. AOS
  0.2.2, HIL 0.2.2, Classic 0.2.4, calibration 0.17.0, JFG and transport package
  versions and source trees are preserved. The package environment contains no
  checkout or repository overrides. The private registry and bare mirror agree
  with the registered RTC 0.2.0 tree above.
- Descriptor changes replace `session-manager` with the exact native
  `pipewireao-rtc -c @RUNTIME@/rtc/rtc.conf` contract and rename the old
  `wireplumber` client/placement role to `session`. Placement values, scientific
  owner arguments and environment values are preserved.
- The diagnostic exercises actual package seal validation, required native
  asset checks, template rendering, parameter-owner configuration generation
  and native SPA-JSON parsing. Its owner records are explicitly synthetic. The
  selected helpers do not launch scientific owners or activate services.
- RTC, libwireplumber and PipeWireAO binary hashes match `native-prefix.json`.
  Loader evidence selects the combined prefix. The libwireplumber pkg-config
  prefix is relative; its rebase does not change runtime bytes.
- README and provenance preserve prior daemon-based live evidence as historical,
  separate future live instructions from offline checks, and retain the GPU
  configuration without claiming GPU execution. The GUI command explicitly
  requires the canonical checkout to contain this candidate before use.

## Evidence checked, without repeating expensive gates

The primary agent's receipts under
`/home/dgamroth/workspaces/codex/worktrees/classic-headless-offline-20261021`
agree with their scripts and logs:

- `rtc-tests.log`: 77 test sets, 2,409/2,409 assertions.
- `configuration/offline-check.json` and `app-check.log`: 64/64 checks, 37
  artifacts, GPU modules/libraries unloaded, no simulator or services started.
- `cpu-science.jl`, `cpu-science-final.log` and `cpu-science.json`: 30/30 checks
  for three deterministic 480-pupil CPU frames through RTC preparation versus
  a separately prepared direct plant, including a small command probe, exact
  detector/OPD equality and no GPU modules/libraries loaded.
- `owner-loading-cpu.log`: registered RTC 0.2.0 CPU instrument loader,
  33/33 checks.
- `install-check.json` and generated unit: public installer writes a fresh
  application, launcher and unit selecting the combined-prefix executable.
  No unit is linked, enabled or started. The primary agent reports 9/9 checks
  and successful `systemd-analyze --user verify`; its verification log is empty.

## Limits

This is offline software/configuration review and finite CPU replay evidence.
It does not qualify live admission, cold replacement, native module loading as
a complete scientific session, sustained cadence, latency, GPU behavior,
measured-mirror behavior or physical operation. The combined native prefix
inherits symlinks into the Julia artifact store and `/opt/pipewireao`, and also
uses host libraries. It is a selected local prefix, not a self-contained immutable
runtime closure; those dependencies must be rechecked before a future live gate.
No simulator service, GPU workload or production installation was started or
modified by this review.
