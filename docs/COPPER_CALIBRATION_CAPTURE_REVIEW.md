# Copper calibration capture review

## Scope and review baseline

Independent review of the bounded Copper capture increment in
`pipewireao-rtc-copper-calibration`, branch
`work/copper-calibration-capture-20261003`, starting from clean commit
`7fe0bcdc64ae53d7fa24eeb0116d206033b6ce8e`.

The parent owns requirements, production changes and installed runs. This
reviewer owns only this document. The initial pass was source/architecture
review; subsequent source checks and the final installed audit are recorded
below, with the completed bounded gate in CCR-8. Existing Classic capture and the six
interaction actions retain their contracts. HEART, hardware, accelerator,
controller-gain and detector changes are excluded.

Authorities are RTC-ARCH-023, RTC-DEV-029 and roadmap step 4: acquire the
deployed Copper four-pupil representation with its stateful normalization.
The baseline operations text permits capture only for Classic; the selected
extension must be reflected in the active requirements before completion is
claimed. Copper reference estimation/adoption and a generalized campaign are
outside this increment. A retained 3,600-value reference is evidence only;
there is no existing deployed reference-pixels node to adopt it.

## CCR-1 — Explicit profile and payload contracts

**Severity/confidence:** Required contract; high confidence.
**Disposition:** Verified by source review, software checks and the bounded
installed capture gate; see CCR-5 and CCR-8.

Use concrete profile dispatch for the capture store/payload descriptors and
owner behavior. Do not infer the expected profile from a manifest, byte count
or available response-array shape. Python validation must receive an explicit
expected profile and check both startup and manifest against it. The ordinary
owner must retain profile identity even when capture storage is absent, since
Copper `collect` also requires the settling rule in CCR-2.

| Copper payload | Shape | Encoding/layout | Bytes per exposure |
| --- | --- | --- | ---: |
| Raw detector | 64×64 | U16_LE, ROW_MAJOR | 8,192 |
| Reconstruction pixels | 4×900 | F32_LE, ROW_MAJOR | 14,400 |
| Mean pupil intensity | 1 | F32_LE | 4 |
| Total | | | 22,596 |

The pixel ordering is the existing public reconstruction-pixels port order.
Do not transpose, renormalize or subtract a newly estimated reference while
recording. Maintain Classic's existing payload names/layout/metadata. A
profile mismatch must reject before exposure acquisition or storage reservation.
Validate Copper's nullable Classic-only active-mask fields explicitly rather
than fabricating a Classic mask.

Required checks: valid profiles; wrong expected/startup/manifest profile;
exact per-profile field set, shape, type, byte count and hash; invalid Boolean
or nonfinite numeric payload; Classic compatibility; cumulative capacity and
metadata bounds. Unknown outputs must not silently select another profile.

## CCR-2 — Previous-frame normalization and minimum settling

**Severity/confidence:** Scientific association requirement; high confidence.
**Disposition:** Verified by source review and software checks; discarded
normalization exposure observed in both installed runs (CCR-8).

Observed source: the public FGA `pyramid_pupil_image.jl` computes the current
mean intensity, stages its reciprocal, and forms reconstruction pixels with
`workspace.reciprocal_previous_frame_mean[1]`. Therefore the first exposure
after startup or a changed probe can use normalization from a prior state.
At least one completed exposure must be discarded after every adoption before
Copper capture or collection. Positive model-time settling must actually
advance through one or more completed exposures; explicit discard must be at
least one. This is the selected software normalization contract, not a claim
about physical mirror settling.

Reject `immediate` for Copper's adopted-to-settled transition before setting an
effect flag, acquiring an exposure or changing the phase/cursor. The existing
adopted probe must remain truthful and usable for a correlated valid settling
request. Enforce the rule for collection without a capture store as well.
Restoration remains independently available under its existing rules; an
invalid collection request must not prevent a fresh reference restoration.

Required checks: startup and repeated adoption; immediate rejection without
side effects; subsequent discard/model-time success; minimum-one exposure
identity; no-store Copper collect; Classic immediate semantics unchanged;
restoration after rejected settling and normal/failed acquisition disposition.

## CCR-3 — Bounded ownership, publication and quality

**Severity/confidence:** Required transport contract; high confidence.
**Disposition:** Verified by source review and software checks, with successful
bounded publication and lifecycle observed in both installed runs (CCR-8).

Capture only completed sink-owned arrays after all raw/WFS receipts match the
full acquisition identity and before the next exposure is armed. The serialized
owner writes these arrays outside callbacks. Retain finite invalid-quality
frames as evidence with their intrinsic validity; never relabel a captured
batch as accepted interaction responses. Nonfinite arrays or missing/corrupt
receipts remain failures, distinct from `valid=false`.

Preserve the existing absolute request deadline across acquisition, file writes
and atomic manifest publication. Reserve cumulative payload capacity before
acquisition, retain partial files without a successful manifest after failure,
and keep post-effect unknown outcomes in fault/hold. A timeout must not produce
a late successful manifest or permit reuse of a failed transport instance.
No new buffer loans, processing callbacks, unbounded bulk JSON or generic
scientific framework are required.

The existing conservative collection formula is
`512 + 16 × measurements + 180 × frames ≤ 65,536` bytes. With 3,600 Copper
measurements it admits 41 frames (65,492 bytes) and rejects 42 (65,672 bytes)
before acquisition. Capture instead uses bounded local files and the existing
small completion descriptor. The 4,096-frame and separate metadata bounds
remain enforced; they do not imply that 4,096 frames fit the JSON collect reply.

Required checks: exact N=41/N=42 collection admission, pre-effect capacity
rejection, write/timeout/disconnect failure, no false manifest success,
profile-specific finite/quality checks, consecutive exposure identities and
fresh-reference restoration/release.

## CCR-4 — Installed gate and scientific limits

**Severity/confidence:** Qualification boundary; high confidence.
**Disposition:** Observed bounded FGN/JFG capture gate passes; see CCR-8.
Scientific qualification limits below remain unchanged.

A bounded normal-noise/ADC FGN and JFG capture must bind the exact deployed
scientific nodes, startup parameters, absolute 277-command µm OPD probes,
adopted demanded figures, feedback, raw arrays and both Copper outputs.
Receipts must show the discarded normalization exposure and subsequent accepted
capture identities. Compare engines on actual shared recorded inputs or retain
input differences explicitly; equal seeds alone do not establish equal frames.
Verify restoration, release, public shutdown and owned-process cleanup.

Existing Copper HIL offset fixtures retain their declared historical status.
This increment can establish capture and collection transport, bounded storage
and metadata correctness. It cannot establish a Copper interaction matrix,
reference adoption, inverse rank, correction quality, physical operation or
wall cadence. Subsequent science must use public algorithm APIs and measured
samples, with its own declared acceptance checks.

## CCR-5 — Missing startup profile was accepted

**Severity/confidence:** Medium evidence-validation defect; confirmed.
**Affected code:** `calibration_campaign.py:verify_capture`.
**Disposition:** Closed after the same missing-field case was rejected on the repaired source.

The proposed validator uses `startup.get("profile", profile)`. This substitutes
the caller's expected profile when the startup record omits its profile,
contrary to the new RTC-DEV-029 requirement to check the declaration against
the startup snapshot. The reviewer reproduced acceptance by constructing the
Copper fixture, deleting `startup["profile"]`, and calling `verify_capture`
with `profile="copper"`; it returned the Copper manifest successfully.

Require an actual matching startup field and add a missing-profile rejection
case. This is malformed-evidence admission, not a demonstrated wrong profile
in the real owner: `calibration_report` always publishes its selected profile.
The explicit expected-profile argument and manifest/channel checks otherwise
prevent the manifest from selecting its own contract.

## Frozen Julia source and software verification

The reviewed source hashes are:

| File | SHA-256 |
| --- | --- |
| `calibration_server.jl` | `095c91ad77c20ed80b75c2882afff9b391c5aee7048fc399ea0f3742e4be4fc7` |
| `calibration_owner.jl` | `f9554d4ee617541f456bb803f513721a1d7369c1ab48efc320fd053097b8a32c` |
| `test_calibration_server.jl` | `e615a85b3aee201ea0f5ced9d2578b3430d4bdf79da11424f663dd6b4917f5f8` |
| `test_calibration_capture.jl` | `e304779ff2dbb3c644a32b04f569cffae83e647965ba23b7acddfdc7e3be85a9` |

Independent source inspection confirms CCR-1 through CCR-3 on the Julia side:
real `AcquisitionSession` profile dispatch is independent of optional storage;
known profile/count mismatches reject; each successful adoption records its
sequence; Copper immediate settling rejects without effects; both capture and
ordinary collect require a later completed exposure. Restoration does not use
the measurement-settling restriction. Classic immediate behavior is retained.
The generic legacy test-session fallback uses the explicitly selected store
layout, not incoming array dimensions, and cannot override a known real profile.

Capture writes the three correctly typed packed Copper vectors through the
existing completed-owner storage path. Length/stride/finite checks precede
each write, deadline/connection checks cover writes and publication, and a
partial write faults the held owner without a completion manifest. The sink
arrays are consumed before rearming the next exposure. No new scientific
calculation or callback work is introduced.

Durable logs under `~/.cache/rtc-calibration-quality-20261003/` report 524 server,
27 owner-option, 31 adjacent acquisition and 105 public-client assertions.
The same one-assertion Copper-store admission fixture fails on the original
Classic-only source and passes on the new source, giving 688 passing assertions
across the five successful processes. The reviewer inspected the frozen tests
and logs; these are software tests, not installed endpoint qualification.
The fail-before log includes package precompilation/version notices, which do
not explain its explicit `capture supports Classic only` rejection.

Python source review confirms an explicit per-profile descriptor, exact channel
set/shape/encoding/byte checks, profile-sized cumulative export bounds and
package-declared profile selection before launching `run_stage`. The parent
reports 167 Python tests (165 passed, two fixture skips), plus the focused
28-test run (27 passed, one fixture skip). CCR-5 remains the specific missing
startup-field gap requiring closure. No additional ownership, mathematical
ordering, bound or publication blocker was identified in this source pass.

The proposed installed gate remains four normal-noise lamp captures per engine,
zero 277-command reference, one discarded settling exposure and one discarded
restoration exposure, followed by release/public shutdown. Its 100 ms model
period and 2 ms exposure are separate quantities; this test makes no 2 ms
cadence claim and adopts no new Copper reference/background/interaction result.


### CCR-5 repair verification and source clearance

The parent preserved `python-missing-profile-fail-before.log`, changed the
check to `startup.get("profile") != profile`, and retained the same negative
case in the tests. The reviewer independently repeated the original fixture:
it now raises `ValueError: capture startup differs from declared profile`.
There is no fallback for an omitted profile. The focused Python result remains
27 passed and one fixture skip. Parent bounds/deprecation-check Julia reruns
also pass all 524 server and 27 owner-option assertions.

Final Python SHA-256 values:

| File | SHA-256 |
| --- | --- |
| `calibration_campaign.py` | `600f56d5786edf905fa88de775c899420d7db9ddb2a516d3efe854a63815afd4` |
| `export_calibration.py` | `918e5819c566d986b7f52df6cac8cdeac3b533723cc44cb047e73287fce51caa` |
| `test_calibration_campaign.py` | `688cf11c6094f9b0c87d836316b6a0ba9dadb96f92c16492277484b719f8a42d` |
| `test_export_calibration.py` | `d5af98e409e38a00169296267d957a1bea8eb3ebfd8b1ca55156b191a6a69ce0` |

No source-review blocker remains for the declared bounded installed smoke
checks. CCR-4 remains pending actual FGN/JFG receipts and shutdown evidence.
The unchanged Copper offset fixture remains explicitly historical.

## CCR-6 — Refreshed Copper package admission

**Severity/confidence:** Dependency/provenance gate; observed artifact identities.
**Disposition:** Artifact and import checks pass; bounded installed FGN/JFG
capture subsequently passed (CCR-8).

The original Copper HIL bases predate the operational calibration helper and
adapter API. The first preparation attempt rejected that missing capability
before RTC launch. The retained original script/log and fresh replacement
outputs distinguish this from an acquisition failure.

Policy `copper-capture-policy.json`, SHA-256
`f0403102d7041563b25264ec6d64a8f8c03327cedc1ba50e64a41b514d66cbb4`,
binds both refreshed and installed descriptors, seven control-source hashes,
the detector configuration and the four-frame/discard-one/zero-reference plan.
The reviewer verified all policy identities and artifact inventories of the
original bases, qualified dependency sources, refreshed bases and new capture
packages. The final installed inventories contain 377 FGN and 504 JFG files
(881 total).

Original versus refreshed Copper graph trees, all calibration arrays,
`plant.toml` and the complete `REVOLTCopperSim` package are byte-identical.
Five shared packages—AOS, its HIL adapter, PipeWireAO, FGA and AOC—are explicitly
refreshed from the engine-matched qualified Classic snapshot; their source
and Project files match that declared source exactly. This is a new package
combination, not proof that every old/new shared model implementation is
scientifically equivalent. Historical Copper offsets retain their fixture
status.

The unchanged detector has 64×64 samples, 14-bit ADC, gain 1, enabled photon
and readout noise, seed 0 and a 2 ms exposure. The model period remains 100 ms.
The installed capture budget is 90,384 bytes for four Copper exposures. No
constructor, map, background, threshold or optical setting was tuned during
this refresh.

Two pure Julia checks on CPU 5 exited 0 under the actual installed HIL Project:
first loading AOS, its adapter, CopperSim and PipeWireAO; then including the
installed calibration owner and checking that the public preparation,
adoption, exposure-step and wire-readback functions have methods, with Copper
command count 277. Both engines' HIL Project/Manifest and owner/acquisition/
server files are byte-identical. These checks did not prepare a live endpoint
or generate an exposure. Package precompilation/version notices appeared;
the successful process outputs are retained in reviewer tool history, not a
separate durable log.

The artifact/import gate permits the bounded smoke run. It does not substitute
for actual endpoint preparation, parameter adoption, first-frame normalization,
raw/WFS receipt association, restoration or shutdown evidence.


## CCR-7 — Packaged runner rejected an admitted external observer

**Severity/confidence:** Startup blocker; observed and independently discriminated.
**Disposition:** Closed for the rebuilt FGN package; original failure preserved.

The first installed FGN attempt prepared and connected its source at sequence 0,
then rejected `links[1]` with the old generic forbidden-link diagnostic. No
capture was admitted. That link joins external `simulator-wfs:output_1` to
external `calibration-raw:input_1` in complete-frame execution. Both endpoints
have U16_LE `[64,64]`, the same raw-detector schema and rate `10/1`. It satisfies
`config.rs`'s existing complete-frame external-observer exception; no new graph
admission exception or scientific topology change is needed.

The failed runner SHA-256 is
`762bc218700a016ffbb82391254df606e5146fe4e76ec75844231638953ef20f`.
It lacks the current direct-link diagnostic string present in the independently
qualified Classic runner and rebuilt main runner. Root rebuilt commit
`7fe0bcdc64ae53d7fa24eeb0116d206033b6ce8e`; the new runner is
`96c115595811665061232c641e901be1856d7fb6577d4e9351372508439879d2`
and coordinator is
`701443e1cd85912f12fcff6a3009c32019b054dd50f48cd261b472c3eacf6011`.
The reported ten external-configuration regressions pass. Binary string
inspection alone does not identify the old binary's exact source commit.

Fresh evidence is under
`~/.cache/rtc-copper-calibration-capture-20261003-v3/`; policy SHA-256 is
`54d6ace77d23faa3265678a956f75b43c996de03606594576fd119244dbc8c29`.
The reviewer rehashed all 377 FGN and 504 JFG package artifacts and both bound
descriptors. Relative to the failed packages, only the two binaries and their
provenance hashes changed. Session bytes, scientific graphs, model, arrays,
Julia sources and manifests are identical. The rebuilt FGN package passes
admission and the bounded capture workflow, providing behavioral pass-after
evidence for this packaging failure. The old failed package and log remain
immutable.

### Completed FGN capture audit

The reviewer independently checked all manifest and payload hashes, request/
reply version/run/serial correlation, startup-to-manifest full UUID mapping,
generation 1 and four ordered sequences 2–5. Sequence 1 was discarded after
adoption; captured starts are 100, 200, 300 and 400 ms with 2 ms exposure duration.
All four frames retain raw `[64,64]` U16_LE, reconstruction pixels `[4,900]`
F32_LE and intensity `[1]` F32_LE, totaling 90,384 bytes. Pixels are finite;
mean intensities range from 26.973915100097656 to 27.235300064086914. Raw ADC
samples range from 0 to 60, below the configured upper rail. These values
characterize this small corpus and do not establish detector performance.

The adopted and restored figures are exactly 277 zeros with `clipped=false`.
Restoration advances to fresh source sequence 6, release replies successfully,
and public shutdown reports stopped with launcher exit 0. The reviewer found
all four recorded launcher/child PIDs absent and the runtime instance removed.
Individual child exit codes are not recorded by this stage result and are not
inferred from launcher success. JFG and paired-output review remain separate
pending gates. No new reference, interaction matrix, correction or rate is
qualified by this FGN capture result.


## CCR-8 — Paired installed Copper capture completion

**Severity/confidence:** Functional qualification gate; observed actual receipts.
**Disposition:** CCR-4 and CCR-6 live capture gates pass for the declared bounded
CPU corpus. CCR-7 is closed by the unchanged-session rebuilt-runner result.
No additional blocker was found within this increment.

The completed stage-result SHA-256 values are:

| Engine | Stage-result SHA-256 |
| --- | --- |
| FGN | `7b0265b5b9319bd8018df5cae6205b3f34a2f477c3d1e6ae573e29b93d79d7ef` |
| JFG | `05a3fbf38a362de3cf2b5ed74da0ef88b25a11e763643614ef09c5f1ff642011` |

The reviewer separately repeated the manifest, payload, profile, detector,
settings-hash, request/reply correlation and lifecycle checks for both engines.
Each run records its own complete UUID domain, generation 1 and ordered capture
sequences 2–5 following discarded sequence 1. Each records fresh restoration
sequence 6, successful release, stopped state and launcher exit 0. All recorded
FGN launcher/child PIDs (four) and JFG launcher/child PIDs (six) were absent at
review, and both runtime instances were removed. This confirms owned cleanup;
it does not manufacture unrecorded individual child exit statuses.

An independent byte comparison of every payload reproduced the parent's paired
report: four actual 64×64 raw ADC frames (16,384 UInt16 values), four `[4,900]`
reconstruction arrays (14,400 Float32 values) and four Float32 intensity values
are byte-identical between engines. Thus the observed output agreement has
verified equal detector inputs, rather than an assumption based on equal seeds.
The four sequential captures are a small finite corpus; statistical independence
is not established. The paired report SHA-256 is
`f08f0628545d39c2bc53a3ec251ba69a0ef87f537e864d63345bc88106e10f1b`.

Measured acquisition phases are 14.365443834 s for FGN and 13.814967123 s for
JFG; these include the ordinary bounded protocol workflow and are not exposure
cadence or real-time performance qualification. The new dependency combination
is qualified here only for normal-noise, zero-command, bounded Copper capture
and its restoration/release lifecycle. Historical offset fixtures retain that
status. Measured reference/background adoption, interaction calibration,
reconstruction, correction and hardware behavior remain outside this result.
