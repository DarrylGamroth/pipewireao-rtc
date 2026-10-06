# Calibration completion evidence review — 2026-10-06

Reviewed `ec2fd26` and `ca85db3` in `/tmp/rtc-copper-main-observer`, clean at
`ca85db3`. Scope is limited to the optional Rust completion journal and Julia
qualification failure-report retention. No prior Copper qualification was
reopened. No source edits, builds, live tests, process changes, or science changes
were made by this reviewer. The ongoing Classic diagnostic belongs to the
primary agent and is outside this source review.

Disposition: the bounded diagnostic behavior is acceptable. CCE-001 is corrected
and independently verified in the follow-up below. No confirmed
operational correctness defect was found in acquisition/recovery forwarding or
failure-report retention.

## Accepted behavior

- `--evidence` is optional. Without it, the existing native endpoint acquisition,
  result emission, and exit status remain unchanged. Plan validation and fresh
  evidence-file creation/write precede native connection and ownership request.
  `create_new` preserves existing evidence destinations.
- The decorator forwards submit/receive/fault results. Returned decoded
  `CalibrationCompletion` fields are retained before coordinator validation,
  including invalid batches and stale adoption cursors. Submit run/serial/action
  entries allow correlation. The journal does not alter accepted evidence or
  add retries/recovery actions. There is no filesystem write in those three
  endpoint methods; JSON construction still adds control-path work.
- Overflow stops retention, preserves existing records and an error marker,
  and produces an error exit after acquisition/recovery finishes. Ordinary
  serialization, flush, and sync errors also fail the CLI. Coordinator result
  output remains available when journal finalization fails. `acquire_calibration`
  returns `Err` only before ownership, so its early `?` does not discard a
  post-hold recovery journal on that path.
- The Julia qualifier retains the owner report before native cleanup on primary
  failure. Copy errors are separate facts and do not replace the primary error
  or produce success. If the runtime report subsequently disappears, the saved
  report hash remains present. No science algorithm, model, calibration matrix,
  or HEART owner behavior is changed by these commits.
- Reviewed the focused Rust tests and saved 4/4 passing test log, Clippy log, and
  Julia retention regression source/log. No test was independently rerun.
  The Rust logs retain the pre-existing future-compatibility warning for
  `proc-macro-error2`; no new own-crate warning appears.

## CCE-001 — fixed JSON charge understates retained object memory

Severity: medium for an exact 64 MiB heap ceiling claim; low for the current small
diagnostic. Confidence: high. Evidence classification: source-derived, not a
measured peak-heap result. Affected source: `src/bin/rtc-calibrate.rs`,
`action_charge`, `completion_charge`, and `EvidenceJournal::record`.

A settle submission with a prior cursor retains four nonempty JSON objects:
outer submission, action, `after`, and `prior_received_cursor`. Its fixed charge
is 1024 bytes. Installed serde_json 1.0.151 uses BTreeMap for these objects; Cargo
lock lists no serde_json indexmap dependency. Installed Rust BTreeMap source has
11 key and value slots per leaf. On x86_64, a String is 24 bytes and Value is at
least 24 bytes because it includes String/Vec variants. Thus the four leaf arrays
alone require at least 4 × 11 × (24 + 24) = 2112 bytes, before node metadata,
strings, and the journal record vector. The current charge cannot be a
conservative bound on retained heap.

The old implementation still has a finite memory bound: retained record count
and all variable arrays are bounded. This finding does not imply unbounded
growth, a demonstrated allocation failure, or failure of the small live trial.

Proposed bounded correction: increase fixed per-record accounting to 8192 bytes
for the current schema and use saturating arithmetic consistently. The 64-byte
charge per numeric array value is reasonable for present representations. A
1024-byte per-exposure charge covers one retained six-field exposure object,
but `completion_json` first builds a temporary Vec<Value> which `json!` converts
again; use 2048 per exposure if accounting is also intended to cover construction
temporaries. Describe the ceiling as a 64 MiB accounting budget, not a measured
exact heap/RSS bound. Preserve a separately bounded serialized evidence-file
claim; do not infer allocation or latency qualification from these diagnostics.

Disposition: corrected and independently verified in the follow-up below. The
ongoing diagnostic uses the frozen journal version and a small action set far
below the budget; no live change was requested or made by this reviewer.

### CCE-001 correction verification

Reviewed the uncommitted `src/bin/rtc-calibrate.rs` diff over `ca85db3`; source
SHA-256 at review was
`c80bf86ea8a3a83592a1c6caaf4ebe5908620a8c5575facbcc49f961ecc66d73`.
The only worktree change at review was this file. Fixed record charges are now
8192 bytes for actions, completions, receive errors/timeouts, faults, and final
coordinator records. Exposures charge 2048 bytes each, numeric arrays retain
64 bytes per value, and completion calculations retain saturating arithmetic.
The header calls the limit `max_charged_bytes`. The source explicitly identifies
the limit as a conservative budget, not measured RSS or an allocator-independent
heap limit. These changes resolve the identified understated fixed charge and
the associated resource-claim problem for the current bounded schema.

Inspected the new regression and saved
`/tmp/calibration-evidence-budget-tests-20261006.log`: 5/5 focused Rust tests pass,
including assertions for an 8192-byte nested-action charge and
8192 + 64 + 2048 response charge. These assertions validate accounting policy;
they do not measure peak heap or RSS. No reviewer builds/tests were run, and no
science rerun is needed solely for this accounting correction. CCE-001 is closed.

The separate frozen live diagnostic and any subsequent capture investigation
are outside this correction review. No physical root cause is inferred here.

## Evidence limits and optional concerns

“Full replies” should be called decoded `CalibrationCompletion` records. Native
endpoint decoding already maps protocol failures into `CalibrationFailure` and
does not expose raw POD/header/status bytes to this decorator. The journal is
not raw protocol capture and should not be presented as such.

The journal is flushed after acquisition; abrupt termination can leave only its
preflight header. This is consistent with the requested cold diagnostic and is
not crash-durable per-action logging. Added JSON construction can affect control
deadlines, so the enabled diagnostic provides no timing-equivalence, throughput,
rate, hardware, or scientific inverse-correctness evidence.

## Independent Classic lamp fixture preparation review

Observed by independent read-only comparison on 2026-10-06. Scope: preparation
validation only. No reviewer edits to packages, builds, tests, or live processes
were performed. This review makes no live Collect success or scientific
qualification claim; actual acquisition receipts and status are separate.

Reviewed source `/tmp/classic-fgn-main-nativecal-v4-installed`, fresh fixture
`/tmp/classic-fgn-cal-lamp-v3-installed`,
[`prepare_calibration_lamp_fixture.jl`](../../../scripts/prepare_calibration_lamp_fixture.jl),
and `/tmp/classic-fgn-cal-lamp-v3-coldproof.json`.

| Reviewed input | SHA-256 |
| --- | --- |
| Preparation helper | `12ad2dfc858b0de78cd8e41cc0ba6c6003b2b58ee602fb8f258c51c439d7ca87` |
| Coldproof receipt | `ff7fcb1b8ed815259682bdc10c92cc7058c909e40187d9f4a1eed13cab354133` |
| Source descriptor | `d6e6271cd84d2d253f59cf00bd08535c39a14577cf5f785d6daf794bd4271051` |
| Fresh descriptor | `8ada3e8d58fa864f72db94785d09d5dbb69718e35cdece51c1989aa260bb6d9d` |
| Source plant | `b85632f5efcaf9371006d79f10276aa99986be4e188b29ce9e2c7a46e56da943` |
| Fresh plant | `6df2ce6c542b3ba200363e02f9c1f53e340f0224ce55c7a8759d234321a5c882` |
| Recipe | `8cbed58035ac2d38efde1238442883f69e6d79e5a9eb283d24fb8464af5d6b8e` |

The recipe is the existing
`~/.cache/rtc-calibration-quality-20261003/method-smoke-reverse-v2/recipe.json`.
All hashes recorded by the coldproof match the actual helper, recipe, source
and fresh package bytes. The embedded provenance receipt agrees with every
coldproof field recorded before installation.

Both package inventories contain 582 files, with no additions or removals.
Exactly four files differ:

| File | Observed change |
| --- | --- |
| `hil/plant.toml` | Parsed TOML has one semantic difference: `shwfs.source_magnitude` changes from 2.0 to the recipe's 0.5. Detector RNG seed remains 0; all other model settings match. |
| `provenance.json` | Adds `calibration_illumination_fixture` and updates the plant artifact hash. All other original provenance fields match. |
| `deployment.conf` | Changes the package name and the plant/provenance artifact hashes. Owner declarations, arguments and all other descriptor values match. |
| `systemd/pipewireao-rtc@.service` | Changes only the `ExecStart` package destination. The installer-owned, unsealed unit was omitted from staging and regenerated for the fresh installed destination. |

All 580 descriptor-sealed artifacts match their actual bytes in each package.
All 578 protected files in the receipt match both source and fresh package
bytes, including scientific sources, calibration arrays, binaries and owner
sources. No accidental scientific or owner file differences were found.

The helper retains explicit source and destination hashes and verifies the
source package after preparation. Its receipt states that the fixture has no
qualification claim. Retaining detector seed 0 isolates the illumination
change; this does not reproduce the original recipe's seed82 acquisition or
the separate seed98 HEART transfer. No blocking preparation findings remain.

## Independent Classic lamp Collect and Capture evidence review

Disposition: accept the bounded installed functional Collect and Capture
results. No blocking evidence or claim findings remain. This review inspected
retained reports, decoded payloads, hashes, and process absence; it did not run
builds, tests, acquisition, or process-control operations. Only this review
document was changed. The preparation review above supplies the independently
checked fixture boundary.

### Collect

Reviewed [the Collect receipt](classic-lamp-collect-v1.json) against actual files
in `/tmp/rtc-main-nativecal-classic-lamp-collect-v1`. Recomputed every receipt
file hash, installed runtime hash, native runner/calibrator hash, descriptor
hash, and plan hash, plus the referenced recipe and coldproof hashes. All match.
The standalone calibrator result and completed owner report exactly match the
copies in `qualification.json`.

All four returned batches exactly match their decoded completion-journal
records. Each contains 376 finite values and 16 consecutive exposures, at
sequences 2–17, 19–34, 36–51, and 53–68, with domain 1 and generation 1. Exposure
starts advance by 2,000,000 ns and durations are 1,896,000 ns. These are model
timestamps, not achieved wall cadence. Submitted and adopted figures match
the plan after its declared Float32 conversion; the restored figure matches
the reference and none of these replies reports clipping.

The owner report records 69 total exposures, zero quality-invalid exposures,
zero ADC upper-rail frames/pixels, and maximum ADC 1691 of 4095. Restoration,
release, unsupported Reset rejection with unchanged cursor/facts, shutdown,
and tracked cleanup are confirmed. All recorded child PIDs and launcher PID
were absent at review; the private runtime instance was removed.

The journal has 32 records and occupies 54,972 bytes. Its `max_bytes` header
and executable hash correctly identify the frozen `ca85db3` implementation,
before the `8167bbe` accounting correction. This observation is not a heap
measurement and does not retroactively attribute corrected accounting to the
frozen binary.

### Capture

Reviewed [the Capture receipt](classic-lamp-capture-v1.json) against actual files
in `/tmp/rtc-main-nativecal-classic-lamp-capture-v1`. All receipt file hashes,
installed runtime hashes, native runner hash, and descriptor hash match. The
retained manifest and completed owner report exactly match the qualifier's
copies. The manifest hash matches the native completion; its 2743 metadata
bytes and 500504 payload bytes agree with the retained files.

Decoded both retained frames at sequences 2 and 3. Each contains a 352×352 U16
detector image, 188 Float32 flux values, 188×2 finite Float32 slopes, and 188
validity bytes. Each validity array exactly equals the owner report's active
mask: 184 true and four false, with the expected active-mask hash. Selected
flux minima independently recompute to 4918.5 and 4986.0625; maxima are
12992.8125 and 13099.6875. The sealed threshold artifact hash matches provenance;
its per-subaperture flux threshold is 1000, giving observed minimum ratios
4.9185 and 4.9860625. These ratios describe only these retained frames.

The two raw images have maxima 1655 and 1637 and no pixels at the 4095 upper
rail. The complete owner run, including settling and restoration, records four
exposures, zero invalid exposures or upper-rail events, and maximum ADC 1659.
Restoration, release, unsupported Reset rejection with unchanged cursor/facts,
native shutdown, and tracked cleanup all agree with the receipt. Launcher and
child PIDs were absent and the private instance was removed. The parent runtime
directory retains exactly `control.json`, `deployment.lock`, and `state.json`,
as explicitly recorded; removal of that parent directory is not claimed.

### Claim boundary

These observations support the declared illumination diagnosis and functional
native calibration acquisition for this fixture. They do not establish an
interaction matrix, inverse correctness, scientific or three-way numerical
equivalence, original recipe/HEART seed reproduction, allocation behavior,
maximum rate, latency, hardware validation, or a unique physical mechanism.
The earlier failed dim-fixture Collect remains valid historical evidence.
