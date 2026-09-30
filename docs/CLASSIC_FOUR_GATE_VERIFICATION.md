# Independent verification of the four Classic development gates

Date: 2026-09-30. This reviewer had no prior authorship of the implementation,
measurement harnesses, arithmetic models, or earlier reviews. The review used
the `review-low-latency-design` skill and examined current source and retained
evidence. It ran no build, test suite, controller, UDP sender, or deployment.
Small saved JSON/CSV reads and hashes supplied the independent artifact checks.

The selected scope is CPU execution of the unchanged Classic calibration and
scientific chain: 352 × 352 pixels, 188 active SH subapertures, 376 x/y slopes,
221 controlled coordinates, HEART's 277 padded reconstruction coordinates, and
277 physical command values. All four requested development gates have adequate
evidence at the explicitly stated boundaries below, including fresh installed
SPA qualification against all five receiver paths. No new confirmed source
defect was found. Two canonical Julia startup attempts exposed a local package
environment failure; its repair and successful fresh attempts are retained.
Application accuracy, whole-stack allocation freedom,
an indefinite maximum rate, and physical camera timing are not supported claims.

## Review baseline and evidence identity

The RTC worktree is
`/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-progressive-requal`, branch
`copper-progressive-requal-20260929`. Review began at `578a334` and inspected the
malformed-header guard subsequently committed at `0fda03c`. Pre-existing edits
to the capacity classifier/tests/document and three untracked Copper
profile/summary files were preserved. This review owns only this document.

The maintained authority map is [docs/README.md](README.md). Relevant evidence
is linked below; the following hashes identify the final capacity artifacts
examined rather than asserting source-to-binary attestation.

| Artifact | SHA-256 |
| --- | --- |
| `benchmark/classic_capacity.py` | `b055082fc83ad6d5185d164dade3407e9b2e5263df5d1cbc368d5e1d3f2cd3a3` |
| `~/.cache/rtc-classic-final-capacity-20260930/manifest.json` | `f15de0dd7843445f034d030ad568ca7a6cd90ebd3f6c1db27314023cf968c802` |
| Same directory, `capacity.json` | `f9ca2cca31737f16cce33b98d4451809d11d5098b52299a4cee7a68b74447601` |
| `~/.cache/classic-campaign-timestamp-audit-20260930.json` | `6dc4529ee841043c839c20d5d45df38a77c8cc1568f2ba7fda27aa633b6ead51` |
| `~/.cache/rtc-classic-spa-clean-five-paths63-20260930/manifest.json` | `9c33581c42a922046614e782db0148ae1ecc5e23c70951b2ab7b4077eac9662b` |
| `~/.cache/rtc-classic-spa-installed-five-paths63-20260930/manifest.json` | `f75abd47fa1362ef71936355053dc63b5a058a0d3c6bb77486047ae72f33cf4e` |
| `benchmark/data/classic_spa_installed_qualification_20260930.json` | `33b2371df4dc73cd51c14e7d45ef693564da63ad59a059c220e0e2d5af44daa6` |

The capacity JSON's embedded manifest and classifier hashes match the actual
files. There are **79 selected capacity windows**. The separate timestamp audit
covers 85 windows, including six preserved historical row-source windows. Every
selected directory appears in that audit. All 168 present WFS/DM streams passed
finite, nondecreasing timestamp checks; two absent streams belong to the
preserved HEART pre-ingress startup failure. No raw WFS archive was rescanned by
this reviewer.

## Gate decisions

| ID | Decision / confidence | Evidence and permitted claim |
| --- | --- | --- |
| FGV-01 | Accepted / high | Numerical development acceptance preserves strict failures and explicitly selects source arithmetic. HEART adds exact model replay; FGN/JFG wire checks use conservative rounding bounds. |
| FGV-02 | Accepted / high | Helper/layout characterization and successful frame/row live traces establish their stated numerical and measured allocation results. They do not establish a helper speedup or allocation freedom outside those intervals. |
| FGV-03 | Accepted / high within stated clock and finite-window assumptions | Repeated latency, separate delivery/deadline bounds, and actual completed SH/MVM work during the recorded readout observations are supported. |
| FGV-04 | Accepted / high | FITS → video-view → HEART stdWfs sink → UDP passed exact source qualification, all five clean-candidate receiver paths, and fresh qualification using installed plugins and canonical receiver roots. |

### FGV-01 — arithmetic acceptance

Source inspection of `classic_numerical_acceptance.py` confirms that the model
regenerates its controller state from zero and does not feed captured outputs
back into its own recurrence. HEART's model preserves the 16-lane/scalar-tail
CoG order, paired reconstruction, fused controller arithmetic, and the original
sparse extrapolation traversal reconstructed from selection indices. Fixture
checks constrain the active mask, calibration identity, coefficient values and
coordinate maps. The controller's contractive recurrence and operation-count
rounding budgets have a stated engineering basis; they are not selected from
the largest observed discrepancy.

The runners and classifier require HEART's exact-model flag as well as its
arithmetic consistency flag. FGN/JFG wire acceptance has the deliberately weaker
rounding-bound meaning. Cross-implementation clipping disagreements remain a
separate rejection condition. `historical_1e_minus_6` and the strict numerical
artifact remain visible when selected arithmetic acceptance passes. For example,
the accepted 1,029-frame windows retain 17,149 strict failed values for HEART,
502 for FGN row, 340 for JFG frame and 888 for JFG row; FGN frame has zero.

[The numerical record](../benchmark/CLASSIC_NUMERICAL_ACCEPTANCE.md) distinguishes
the exact 285,033-value HEART wire result from broader FGN/JFG bounds. Its
conservative physical-command radius reaches about 0.00797 µm for 1,029 frames;
this is not an application tolerance. Broad bounds can conceal small defects.
The stronger saved intermediate and recurrence checks, exact helper oracle
results, command limits, and clipping checks provide additional evidence without
turning FGN/JFG wire consistency into a bitwise independent oracle.

### FGV-02 — helpers, layout and allocation

The ordinary-array experiment covers three 1,029-frame repetitions of all six
worker/layout combinations. It reports exact outputs against the reset serial
oracle. The source keeps matrix preparation outside frame processing, partitions
output rows, and joins helpers before terminal publication. Sharding retains
the original matrix and adds 332,384 coefficient bytes; a matrix fitting within
nominal L2 capacity does not establish cache residency. The recorded p50
differences around 1.5% provide no convincing helper or layout speedup.

The original broader counter intervals with approximately 462 kB of first-use
allocation remain reported. The saved allocation profile attributes them to
measurement-wrapper compilation. The later function-barrier validation records
zero inner and outer counters for all six cases. Its timings do not replace the
original three-repetition measurements.

For the four successful live cases, this reviewer checked every input hash in
JFG's `benchmark/results/classic-live-callback-allocation63-2026-09-30.json`
against the saved files. The same check also covers the separately preserved
failed helper capture. Direct CSV inspection confirmed 63 complete-frame
intervals and 2,016 intervals in each row case, with zero allocated-byte,
pause and GC-time deltas. Source inspection of `GraphCallbackTrace` and
`_process_graph_callback!` confirms fixed storage, explicit overflow counts,
and the unchanged `nothing` branch when tracing is disabled.

The interval brackets borrowed-buffer graph execution and the success counter.
Property adoption, initial dispatch/native bridge, notification, transport and
startup lie outside it. GC snapshots are process-wide and can include helper
activity occurring during the bracket. They do not cover helper work between
brackets or native allocation. Live helper evidence covers one/two helpers with
sharded layout; shared-helper coverage is ordinary-array characterization.

Detailed records are in the sibling JFG repository's
`docs/classic-cpu-helper-characterization.md`,
`docs/classic-live-callback-evidence-20260930.md`, and
`docs/classic-callback-trace.md`.

### FGV-03 — latency, completed science and capacity

All five paths have three exact 1,029-frame windows at 250 Hz with every
first-WFS-packet→DM interval within 4 ms. The classifier includes first use in
the deadline test, checks the achieved mean source rate within ±1%, requires
normal child exits and before/after RTC placement, and preserves first-packet
and terminal-packet latency distributions separately. Its after-first-100
statistics do not determine acceptance.

The updated [Classic comparison](../benchmark/CLASSIC.md) and
[capacity record](../benchmark/CLASSIC_CAPACITY.md) were checked against the
final manifest. All rounded common-250-Hz p50/p99 ranges match the fifteen
saved per-window summaries; every one uses 2,000 µs requested readout.

| Path | Highest tested delivery pass | First higher eligible delivery failure | Highest tested deadline pass | First higher eligible deadline failure |
| --- | ---: | ---: | ---: | ---: |
| HEART | 250 Hz | 750 Hz | 250 Hz | 750 Hz |
| FGN frame | 1,250 Hz | 1,500 Hz | 250 Hz | 1,000 Hz |
| JFG frame | 1,250 Hz | 1,500 Hz | 250 Hz | 1,000 Hz |
| FGN row | 500 Hz | 750 Hz | 250 Hz | 500 Hz |
| JFG row | 250 Hz | 500 Hz | 250 Hz | 500 Hz |

HEART 500 Hz has only two eligible windows; both deliver exactly and miss
deadlines. Its third incomplete observation is excluded, so 500 Hz establishes
neither a three-window pass nor an eligible three-window failure bound.
FGN/JFG frame delivery passes at 1,250 Hz although every frame misses that
rate's period deadline. FGN row 500 Hz misses one deadline in each repetition.
JFG row 500 Hz loses delivery in one of three eligible windows. These outcomes
are consistent with the two separate contracts.

This reviewer inspected the retained physical summaries for failed windows.
All eligible high-rate failures have complete 32,928-packet WFS captures, zero
pixel mismatches, and reported DM count/order failures. The incomplete HEART
captures are excluded. Normal exits and load eligibility were checked in the
classifier output, rather than inferred from launcher failures. The first
higher failure is a bound on this finite acceptance rule, not proof of a
monotonic or indefinite saturation threshold. Requested readout decreases above
250 Hz, so the table describes the recorded rate/readout schedule.

The row source correction has a source-level basis: `9f3c321` notifies after
the first successful publication instead of draining later row packets;
`10388618` prefers two bounded row frames while preserving the old minimum.
The frame branch already stopped on successful publication, and its buffer
preference remains eight. The final series excludes old-source row windows.
The failed 32-buffer evidence and successful corrected diagnostic remain in
[the admission record](../benchmark/CLASSIC_ROW_ADMISSION.md). This establishes
the investigated mechanism without assigning every later high-rate loss to it.

Completed-work claims are stronger than counts of callbacks or input-ready
events. The reviewed JFG split path computes each ready SH prefix, publishes
its x/y columns, and synchronously accumulates every column into all 221 output
coordinates before returning with workers zero. The analogous FGN fused path
has synchronous prefix accumulation. Thus accepted complete callback evidence
supports cumulative lower bounds, not sums that double-count prior prefixes.
The corrected JFG 250 Hz diagnostic derives positive work in all 63 frames:
SH min/median/max 4/166/184; MVM columns 8/332/368. An additional 10 µs clock
margin preserves these summary values but changes four individual bounds.

[The row-work record](../benchmark/CLASSIC_ROW_WORK.md) correctly conditions
these deductions on the realtime/monotonic endpoint envelope. That envelope
does not measure unseen interior clock excursions. FGN's earlier diagnostic
has positive lower bounds in 58/63 frames. The
[HEART direct trace](../benchmark/CLASSIC_HEART_READOUT.md) observes SH work in
63/63 frames and derives prior completed MVM pairs in 62/63; frame zero has no
positive MVM bound. HEART uses one monotonic clock, but its terminal event is
the handler's receive observation. These records demonstrate actual partial
science before their recorded terminal observations, with the stated limits;
they do not measure physical sensor or exact NIC arrival time.

### FGV-04 — clean SPA sender

`run_classic_spa_sender.py` configures public FITS `GRAY16_LE` output, the
row-major ndarray video view, and the existing HEART sink. The sink preserves
raw UInt16 pixels, native byte order, 11 rows per packet and 32 packets per
frame. The helper requires exact finite counters and normal cleanup. The
receiver's independent packet and numerical qualification supplies the
end-to-end checks that sender counters alone cannot establish.

The clean pair has FITS SHA-256
`947ba07a07f5da0e8c60b408455933689e3cc7a7cc1ca8dbf8c358c9ac3f8a41`
and ndarray SHA-256
`153839f352590a992655f327ef892c1dff3595ab9fbe80f183ed2aeb7ec6458c`.
The clean SDK branch exposes the two baseline ndarray factories. This avoids
using the earlier three-factory investigation binary as evidence for the clean
backport. The saved seven-frame source check has 224 exact packets. Its five
63-frame receiver windows each have 2,016 WFS packets, 63 DM commands, exact
ordered source frames, zero pixel mismatches, selected arithmetic acceptance
and normal process exits. HEART's source model has zero unequal command bits;
its separate broad qualification remains false under its documented limitations.

The reviewed sender chain uses the unchanged HEART sink implementation, and
the receiving HEART RTC executable remains unchanged. These functional runs do
not substitute for the wfsSimulator capacity campaigns.

The fresh installed campaign has now passed all five paths using `--sender spa`
without a private sender-directory override. Its canonical receiver roots are
FGN `54d8b1847d7913f532e1d48ceba2429eb2499055` and JFG
`6f1da393f9bd7153ed95b8811ccf32ebce6342a6`. The installed FITS and clean ndarray
hashes match the pair above. The installed HEART SPA hash is
`efaf3a810284a6a39b9c84fb433cf9669a638da14b41cd528b8a18cc593ce7d6`, containing
the reviewed row-source corrections. This reviewer independently hashed all
three actual `/opt` DSOs and checked the deployment-record hash.

The selected successful directories are `heart`, `fgn-frame`, `fgn-row`,
`jfg-frame-r2`, and `jfg-row-r2` under
`~/.cache/rtc-classic-spa-installed-five-paths63-20260930`. This reviewer read
each report, physical summary, arithmetic acceptance and sender report. Every
path has 2,016 exact WFS packets, IDs 0–62, 63 ordered DM commands, zero pixel
mismatches and selected arithmetic acceptance. HEART commands retain its
established IDs 1–63; graph commands use 0–62. All sender counters are 63 frames,
2,016 datagrams, zero rejected frames and zero send errors. All recorded child
exits are zero. HEART's exact model passes; JFG final feedback has 74 expected
nonzero values and errors at most 1.19 × 10⁻⁷ µm (frame) and
2.38 × 10⁻⁷ µm (row). FGN's absent separate feedback field and HEART's broad
legacy qualification limits remain unchanged. The manifest retains both failed
initial Julia attempts with `selected = false`.

The frozen [installed evidence index](../benchmark/data/classic_spa_installed_qualification_20260930.json)
adds artifact hashes, cleanup observations and post-run installed core hashes.
This reviewer checked its manifest hash, unchanged selected results, all selected
report/physical-summary/archive-index hashes, both retained failure reports and
node logs, and the three installed core files: 29 comparisons, all matching.
Archive indexes agree with their saved records; raw archives were not reread.
The cleanup observation records no remaining UDP 6000 listener. The final
provenance explicitly distinguishes the source checkout revision from the
installed normal core's binary hashes; it does not assert that the current
diagnostic source HEAD built that installed core. These additions do not change
any qualification result or expand the functional claim.

## Remaining claim limits and dispositions

| ID | Severity / confidence | Evidence and disposition |
| --- | --- | --- |
| FGV-L01 | Scope limit / high | Application command accuracy is unassessed. Preserve the original numerical failures; do not rename arithmetic consistency as unconditional scientific equivalence. No additional physical gate is imposed on this development task. |
| FGV-L02 | Scope limit / high | Zero allocation applies to the measured Julia intervals and ordinary-array probes. Retain excluded lifecycle/transport boundaries and the original wrapper allocation failures. |
| FGV-L03 | Scope limit / high | The work-before-terminal deductions depend on graph/configuration provenance and the documented clock model. Retain per-frame zeros and sensitivity changes. |
| FGV-L04 | Scope limit / high | Capacity is a finite repeated-window bracket with changing readout and recorded CPU placement. No statistical independence, OS isolation, indefinite rate, or physical-loop claim follows. |
| FGV-P01 | Closed / high | Fresh installed source/receiver reports, canonical roots, exact `/opt` hashes and normal exits now establish the installed functional claim. |
| FGV-D01 | P2 / high, corrected environment failure | Both first canonical JFG attempts failed before ingress on the missing declared `FilterGraphPipeWire` dependency. The local environment was repaired; fresh frame/row attempts pass. Initial failures remain preserved. |

FGV-D01 is observed in the installed campaign's original `jfg-frame/node.log`
and `jfg-row/node.log`: dependency UUID `0366a544-13dd-48a3-a3d6-bd2ba4547294`
cannot be loaded at `run_classic_pipewire_node.jl:26`. Both reports show exit
before `CONNECT_ACCEPTED`, with child statuses `[0, 1]`. The local
`benchmark/Manifest.toml` is ignored by Git. This is a deployment-environment
failure, not evidence of incorrect arithmetic, transport frame loss, or a
capacity bound. The retained `provisioning.json` and `cold-imports.json` in
`~/.cache/rtc-classic-installed-julia-environment-20260930` record successful
resolve/instantiate and cold import, both exit zero. The tracked Project hash
remains `08fe340cf14d6fab257ac113be622476cf51ecfec286d02f5827178f6f89630e`.
This reviewer checked the saved before/after Manifest bytes against their
recorded hashes: `59405813bba4cbf0ef457bb9af7c30d22d9ce839110d5192be253e1656e5dcb3`
and `b7930647838bbe502c001aa0fb9dea28b69c48c888ed29df2c861cda477af0d4`.
The same canonical runners then passed the fresh frame/row qualifications above.
No scientific or production source change was required.

Previously found FR-01/FR-02 and the malformed-header issue are preserved in
[the integration review](CLASSIC_FINAL_REVIEW.md). The current classifier
checks header length before unpacking and records failed evidence reads; its
capacity artifact now completes. The timestamp audit supplies the necessary
saved-data follow-up for FR-01. The retained primary-agent log
`~/.cache/classic-final-units-20260930.log` records 155 tests passing in 2.658 s;
this reviewer inspected that result and did not rerun the suite. This review found no basis for changing
scientific gains, calibrations, precision, or the unchanged HEART RTC.
