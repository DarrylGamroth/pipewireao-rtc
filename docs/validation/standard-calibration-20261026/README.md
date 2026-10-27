# Standard calibration bundles — 2026-10-26

This RTC source change unifies calibration entry points across the GPI pyramid
and Classic Shack–Hartmann procedures. `calibrate_system` generates a
version-1 bundle from a built application, `validate_system` validates the
bundle against its declared application, and `stage_calibration` imports a
verified bundle into a fresh source copy. Bundle integrity covers the result,
context, concrete graph, typed FITS artifacts, and optional retained history.

Modal-only APIs and CLIs and the active Classic TOML result loaders are removed.
Frozen calibration records remain historical inputs and are not rewritten.
Imported bundles preserve their historical source identities and support
startup/integrity checks; this migration does not rebind them for the new
validation/staging sequence. RTC 0.2.17 packages these interfaces for registered
application environments. Source overrides remain validation-only.

## Source and environment

Implementation used dedicated `codex/standard-calibration` worktrees from RTC
`6c9c21e` and instruments `02a50bf`. Implementation checkpoints are RTC
`bdb81f2` and instruments `559bb9d`. The original instrument checkout remained
clean. Julia 1.13.2 CPU checks used a separate source-validation environment
with this RTC source and registered AOS 0.3.2, HIL 0.2.5, AOC 0.17.1, FGA 0.8.1,
FGI 0.1.3, FGPW 0.1.9, JFG 0.4.2 and PipeWireAO 0.6.19. Built applications used
a separate registered-only manifest (RTC 0.2.13); a source-override manifest was
correctly rejected by the ordinary export contract. No manifests are committed.

The final staging interface is
`stage_calibration(source, application, bundle, fresh_destination)`. Source is
authored data; application is its verified build. Two retained failed rebuilds
showed why a built tree cannot be restored by deleting generated files: it
contains both compiled YAML and rendered native session/host templates. The
final interface copies authored source and verifies its recipe, retained graph
template and localized optical prescription against the calibrated build.

## Completed software checks

- Shared bundle integrity/publication: 68 assertions; modal temporal/FITS I/O:
  284; modal completion: 63. All 415 passed. The reviewer independently repeated
  the 68 cold bundle assertions.
- Selected imported bundles: 106 assertions passed, including historical hashes,
  template resolution, exact parameter aliases, explicit physical-sized neutral
  offsets and no scientific/accelerator packages loaded by the cold reader.
- GPI feedback/publication: 230; shape controls: 36; CPU/CUDA/AMDGPU profile
  authoring: 49; formatting fixtures: 50. All passed. Formatting check passed.
- Instrument calibration/API selector: all 161 assertions passed, including
  stale/aliased templates, unsupported recipe fields and built-as-source staging
  rejection without output creation.
- Independent source review found no remaining blocker; see the
  [adjudicated findings](../../reviews/20261026-standard-calibration/REVIEW.md).

Primary and reviewer independently compared all 52 original coefficient FITS,
the retained source-completion FITS, three historical receipts and the original
GPI graph against the instrument base: all original bytes remain unchanged.
Three added Float32 zero-offset vectors make graph defaults explicit (Classic
277, GPI woofer 97, GPI tweeter 2304). Strict typed startup covers Classic's
19 parameters / 23 artifacts and GPI's 33 parameters / 32 artifacts.

## Finite CPU workflows

Classic's common acquisition completed 212 coordinates with retained rank 208.
Common validation ran 512 frames at pupil resolution 480, atmosphere seed 1 and
r₀ = 0.15 m. Mean residual after discarding 128 frames was 50.51794 nm; no actuator
or central samples clipped. This is a finite simulation observation, not a
hardware or stability qualification. Authored-source staging passed all 19 typed
bindings, and the staged source rebuilt with the registered manifest. The
rebuilt recipe and retained-template contract matched the input.

GPI completed all 1,509 coordinates, with 11,104 measurements and retained rank
1,445. The common validator passed tip/tilt, focus, astigmatism and mixed
48-step correction cases. Final four-input authored-source staging passed all
33 typed bindings, and its registered rebuild passed the recipe/template check.

| GPI disturbance | Final RMS / uncorrected RMS | Final RMS (nm) |
| --- | ---: | ---: |
| Tip/tilt | 0.007311 | 0.17393 |
| Focus | 0.005302 | 0.15040 |
| Astigmatism | 0.005858 | 0.14484 |
| Mixed | 0.007369 | 0.14192 |

These are finite deterministic simulation cases, not measured instrument errors.
Acquisition/validation and final staging/rebuild used separate processes against
the same hash-bound bundle. The earlier combined driver was stopped after its
validation receipt completed, because its already-loaded three-input staging
implementation had been superseded; no success is claimed for that old stage.

The [portable verification driver](verify-pipeline.jl) records the final
build → acquire → validate → stage → rebuild sequence. Run it
from a source-validation environment with `OPENBLAS_NUM_THREADS=1`, passing the
instrument repository, instrument name, fresh output root and registered-only
manifest. It does not open a PipeWire core or installed service.

## Existing failures and limits

The graph-reference selector fails identically in the unmodified instrument
checkout and this worktree: 9 passes, one stale concrete-graph fixture comparison
failure and one altered-dimension shape-binding error. It is not a passing gate.
The old exact Float32 completion comparison differed by at most 4.656613 × 10⁻¹⁰;
the migrated test uses an absolute `eps(Float32)` bound while retaining rank,
affine reproduction and limit checks. No numerical procedure was changed to
match a frozen coefficient file.

Imported root bundles are packaging adoptions, not new acquisitions. Their
historical source identities remain unchanged and cannot be silently rebound
for replay/staging against a different build. Fresh bundles exercise the common
workflow. Copper and SPIDERS remain outside this data/tool migration. The new API
is included in RTC 0.2.17 for ordinary pinned environments. These sensor procedures
currently execute simulation-local acquisition; native event-driven hardware
campaigns remain a separate integration. Physical-device calibration, GPU
numerical equivalence, sustained cadence and deadline qualification were not
performed. Existing running services were not contacted or modified.


## TOML cleanup follow-up

Remaining Copper/SPIDERS scenario authoring in the instrument repository moved
to YAML without changing parsed values. The obsolete package-backed GPI scenario
and private-core branches were removed. Scenario checks passed 22 assertions;
formatter checks passed 50; a minimal YAML-only environment instantiated and
loaded both files. Julia package/artifact metadata, Taplo configuration, frozen
records and the external SPIDERS physical15 TOML/FITS contract remain intact.

The optional RTC owner-loading regression now uses a YAML graph (28 CPU
assertions passed). Finite replay now writes `result.yaml`; managed replay binds
`calibration/result.yaml`. Both scripts pass syntax checks, the YAML report
writer passes round-trip verification and the selected receipt hash matches a
previously rebuilt Classic application's declared calibration identity. The
full opt-in replay campaigns were not rerun for this format-only change.
Archived oracle/qualification scripts and dated evidence were not rewritten.

## Integration with RTC main

The merge of calibration source `9cf5dd9` into main `3163805` was clean and
preserves main's Hsm correction-timer implementation and 0.2.14 package metadata.
The combined source passed the full Julia 1.13.2 package workspace: 4,835
assertions across 178 testsets, using one Julia thread and the installed native
SDK prefix. The optional scientific calibration selectors passed 415 assertions;
the correction-timer private-core selector passed 56; native control and
calibration-action endpoint selectors passed 65 and 17, respectively.

The first full-suite invocation omitted `PIPEWIREAO_PREFIX` and stopped in the
schema selector; the configured rerun passed. An initial optional timer invocation
used a bare module without its normal `include` binding; running the maintained
script directly passed. The full workspace emits a Git missing-object diagnostic
while testing rejection of deliberately deleted catalog content. No test failure
remains. Project/Manifest files were unchanged by validation. No installed
services or physical devices were contacted. This merge does not publish a new
registered release or qualify hardware, GPU equivalence or deadlines.

## RTC 0.2.17 release preparation

The release starts from combined main `c712328`, including the separately
released 0.2.16 correction-metadata admission fix. Only package metadata and
release documentation changed during preparation. Julia 1.13.2 passed the full
workspace with 4,836 assertions across 178 testsets using the configured native
SDK and one Julia thread. A fresh Julia 1.12.7 environment passed all 115 bundle
and completion-driven procedure assertions across six testsets without warnings.
`Pkg.resolve()` changed only the package's own Manifest version to 0.2.17;
dependency versions and compatibility bounds remain unchanged.

## Registered RTC 0.2.17 validation

[Release v0.2.17](https://github.com/DarrylGamroth/pipewireao-rtc/releases/tag/v0.2.17)
tags commit `124d964fd7a325cee3b1e96b651a17688b622128`. Private registry commit
`1846af1` registers tree `e2acf924a4dc58dbada284b315b0e725803297c6`, matching
the tag. A fresh registered-only environment installed that exact tree without
path or repository overrides, using the instrument cohort documented above.
LocalRegistry generated the registry change; its worktree limitation required
an isolated ordinary clone rather than a linked worktree.

On Julia 1.13.3 the installed package passed the full `Pkg.test("PipeWireAORTC";
allow_reresolve=false, julia_args=["--threads=1"])` workspace: 4,836 assertions
across 178 testsets. The installed bundle, modal-I/O and completion selectors
passed another 415 assertions; the instrument calibration selector passed 161.
These checks use the configured native SDK and never contact installed RTCs.

Earlier registered runs were interrupted when the host's Julia 1.13.2
installation was removed during execution: the package selector lost its
standard-library directory, a calibration selector could not load `libdSFMT`,
and a staged rebuild could no longer identify bundled LibCURL. Those runs are
not passing evidence. The replacement environment and checks use Julia 1.13.3.
Development, validation and release tooling now require Julia 1.13 or newer in
repository guidance. This does not alter historical evidence or live services.

## RTC 0.2.18 integration — 2026-10-27

The integrated source includes the preserved channel/unit work and per-mirror
pupil/clear-aperture metadata. Calibration selection now keeps prior records in
Git, rejects archive manifests, and selects `calibration/context.yaml` directly.
The modal writer stores one typed FITS pupil-mask reference instead of a second
Boolean array. Context resolution checks a bounded snapshot's hash, type, shape,
axes, Boolean values, row-major order and aggregate memory budget without loading
an accelerator. Island 0.1.4 and HIL 0.2.6 publish the corresponding source channels;
the RTC compatibility floors require those registered releases.

Julia 1.13.3 passed 56 cold context assertions. Independent verification passed
another 56 context assertions and 11 writer/bundle/relocation/tamper checks.
The maintained scientific staging selector passed 11 assertions against the
previous exact Classic acquisition: no archive directory or manifest, no duplicate
RTC context, matching selected parameter hashes, and unchanged source bytes.
The same archive assertions failed on registered RTC 0.2.17 before the change.

Two older optional selectors retain baseline limitations. The session selector's
no-GPUCompiler assertion fails because registered AOS 0.3.2 imports
KernelAbstractions 0.10.3, which depends on GPUCompiler; this reproduces in the
untouched RTC 0.2.17 environment. Neither CUDA nor AMDGPU loads. The older optical
selector assumes `plant.package`, while Classic now declares `plant.definition`;
that assertion is unchanged from 0.2.17. These are not passing evidence. The cold
context checks and the instrument-specific finite replay are separate gates.
No installed RTC, desktop core, accelerator or physical device was contacted.

The configured full root workspace completed on Julia 1.13.3 with **5,016/5,016
assertions across 186 testsets**. Named-analysis checks passed 114/114. The full
suite requires `PIPEWIREAO_PREFIX=/opt/pipewireao`; an initial run without that
setting stopped in the schema selector and is not passing evidence. The known
Git missing-object diagnostic comes from intentional catalog-corruption testing.
No unexpected warning or failure remains in the configured core run.
