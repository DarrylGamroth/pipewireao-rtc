# Classic finite-window capacity classifier

`classic_capacity.py` reads an existing campaign manifest and saved artifacts.
It does not run a controller. The output keeps two contracts separate:

| Contract | Required in each eligible window |
| --- | --- |
| Delivery | Exact ordered WFS/DM delivery, selected numerical policy, normal child exits, requested RTC loop placement, achieved average source rate within tolerance |
| Deadline | All delivery requirements, plus every first-WFS-packet→DM interval ≤ one requested frame period |

Default average pacing tolerance is ±1%, configurable with
`--pacing-tolerance`. This concerns the measured mean of first-packet frame
periods; it does not constrain jitter. Missing, underdriven or overdriven source
windows are **excluded**, not RTC failures. Infrastructure exit or placement
failures are also excluded, with their own failed gate visible. When DM is
missing, the helper can recover achieved source rate from complete ordered WFS
packet timestamps, including campaign-compressed archives.

Default repetition count is three (`--minimum-windows`, minimum two).
Directories and repetition ordinals must differ. Frame count, readout, layout,
worker count, placement request and numerical policy must agree within each
path/rate. These checks establish distinct recorded windows, not statistical
independence. A rate needs enough eligible windows and no eligible failure to
pass. Additional excluded windows remain visible.

For each contract the report exposes the highest tested passing rate and the
first higher tested failing rate. A failing rate has enough eligible windows
and at least one failure of that contract. The latter is only a bound on this
finite experimental acceptance rule. Lower-rate failures, changed readout and
nonmonotonic outcomes remain visible. No indefinite loss-free or unbounded
maximum-rate claim follows. A late loss-free window can pass delivery and fail
deadline; its lateness does not become a delivery-capacity failure.

## Numerical and operational evidence

The selected policy is read from each saved command. `strict` retains the
original 10⁻⁶ µm gate. `source-arithmetic` requires the arithmetic bound check;
HEART additionally requires its exact source-arithmetic wire model. Clipping
classifications must agree. Original strict failed-value counts remain visible
under `historical_1e_minus_6`, even when source arithmetic passes. Application
physical accuracy remains unassessed.

Child return codes, launcher return code, exact wire evidence, selected
arithmetic acceptance, original strict comparison, before/after RTC placement,
achieved pacing and all-frame deadline misses appear separately. A nonzero
launcher exit due to a measured delivery failure cannot conceal that failure
if load, placement and normal child exits are otherwise established. Unknown
or contradictory evidence cannot produce a pass. Placement coverage is the
recorded RTC loops; it does not attest every helper/source thread.

## Reproduction and baseline observation

```sh
taskset -c 14 python3 benchmark/classic_capacity.py \
  /home/dgamroth/.cache/rtc-classic-baseline3x1029-20260930/manifest.json \
  --output /home/dgamroth/.cache/rtc-classic-baseline3x1029-20260930/capacity.json

taskset -c 14 python3 -m unittest discover -s benchmark -p test_classic_capacity.py
```

The completed 2026-09-30 baseline contains three passing 1029-frame 100 Hz
windows for FGN frame, FGN row, JFG frame and JFG row under both contracts.
HEART has two passing windows and an excluded pre-ingress TCP port-guard failure;
it therefore has insufficient eligible repetitions. No tested failure upper
bound is established. This preserves the original failed HEART attempt.
The JSON records manifest, classifier and input artifact SHA-256 hashes.
Thirteen synthetic tests cover repetition, missing evidence, pacing boundaries,
underdrive, independent delivery/deadline outcomes, failure bounds, numerical
policy, HEART exact-model enforcement, child exits, placement, missing DM, and
complete/corrupt/incomplete Zstandard evidence. The shared `classic_wire` reader
retains plain, XZ and gzip compatibility and checks Zstandard decoder exit status.

## Current characterization (2026-09-30)

The original baseline above describes the first manifest. A successful separate
HEART replacement now supplies the third eligible window; its original startup
failure remains recorded. Final campaigns and classification are complete. The retained evidence
establishes finite delivery/deadline bounds, with exclusions preserved.

### Source correction and historical evidence

The original 32-buffer source delayed its first notification while draining
queued UDP packets. A failed 250 Hz Julia diagnostic establishes the admission
and notification mechanism. [The admission record](CLASSIC_ROW_ADMISSION.md)
preserves that failure and the successful 64-buffer rerun. HEART SPA commits
`9f3c321` and `10388618` notify after first publication and prefer bounded
buffer headroom, preserving the prior minimum. The HEART RTC and wfsSimulator
are unchanged.

Final normal row campaigns select the frozen release HEART SPA DSO explicitly:
SHA256 `efaf3a810284a6a39b9c84fb433cf9669a638da14b41cd528b8a18cc593ce7d6`.
Its normal and diagnostic O3 builds pass all five native transport tests.
Old-source row windows remain historical evidence and will not be mixed with
corrected-source windows in the final rate classifier.

### Retained campaigns

Artifacts live under `/home/dgamroth/.cache/`; every campaign keeps exact
commands, placement, source revisions, counters, failures and compressed wire
captures. Current sequence is recorded by
`run-classic-completion-campaigns-20260930.commands.json`.

| Campaign directory | Purpose | Status |
| --- | --- | --- |
| rtc-classic-baseline-combined1029-20260930 | Original 100 Hz baseline, all five paths | Complete; three successful windows each and one retained HEART startup failure |
| rtc-classic-capacity-frame1029-20260930 | HEART and frame graphs, 1,000/1,500 Hz | Complete; graph frame delivery passes at 1,000 Hz, deadline misses remain; higher-rate losses retained |
| rtc-classic-row-fixed-coarse63-20260930 | Corrected source, row graphs, 100/250/500/1,000/2,000 Hz | Complete; single short search windows, not repeated capacity evidence |
| rtc-classic-row-fixed-baseline1029-20260930 | Corrected source row baseline at 100 Hz | Complete |
| rtc-classic-row-fixed-capacity1029-20260930 | Corrected source rows, 500/750/1,000 Hz | Complete |
| rtc-classic-frame-refine1029-20260930 | Frame graphs at 1,250 Hz | Complete |
| rtc-classic-heart-refine1029-20260930 | Unchanged HEART at 500/750 Hz | Complete |
| rtc-classic-common250-1029-20260930 | All five paths at 250 Hz | Complete; three exact, deadline-clean windows each |

The final selection includes 79 windows. It excludes the six historical
old-source row windows from the final capacity comparison without deleting them.
All 85 retained windows were audited for finite, nondecreasing timestamps:
168 present WFS/DM streams pass; two absent streams belong to the preserved
pre-ingress HEART failure. Timestamp validity does not establish complete packet
payloads: incomplete captured WFS headers remain exclusions.

| Path | Exact-delivery passing/failing bound, Hz | Deadline passing/failing bound, Hz |
| --- | --- | --- |
| HEART | 250 / 750 | 250 / 750 |
| FGN frame | 1,250 / 1,500 | 250 / 1,000 |
| JFG frame | 1,250 / 1,500 | 250 / 1,000 |
| FGN row | 500 / 750 | 250 / 500 |
| JFG row | 250 / 500 | 250 / 500 |

Bounds require three eligible windows at each assessed rate. HEART 500 Hz has
two eligible passing windows and one incomplete-capture exclusion, so its
classification is insufficient; HEART 1,500 Hz is also insufficient. Original
startup/capture failures are visible in the classifier output. Full-frame
1,000 and 1,250 Hz pass delivery but fail deadline; Rust rows at 500 Hz pass
delivery but each window has an initial period miss. Julia rows at 500 Hz fail
delivery because one of three windows loses a command.

Final artifacts:

- [Full classifier output](data/classic_capacity_final_20260930.json), including
  per-window gates, exclusions and original numerical criteria; failed-run
  identities remain in the indexed physical summaries and capture archives.
- [Timestamp audit](data/classic_timestamp_audit_20260930.json).
- [Common 250 Hz baseline](data/classic_common250_20260930.json): all five paths,
  three windows each, zero missing commands and zero 4 ms period misses.
- [Corrected-source 100 Hz row baseline](data/classic_row_baseline_fixed_20260930.json).
- Cache source: `/home/dgamroth/.cache/rtc-classic-final-capacity-20260930/`.

Reproduction uses the final `manifest.json` with the classifier command above.
The capture reader now reports truncated WFS headers as unavailable pacing
rather than aborting the complete analysis. Its discriminating regression fails
before and passes after; the final 155-test Classic suite passes. Three harness
findings and their evidence are recorded in
[the integration review](../docs/CLASSIC_FINAL_REVIEW.md). An independent final
four-gate review is recorded in
[the verification report](../docs/CLASSIC_FOUR_GATE_VERIFICATION.md).
