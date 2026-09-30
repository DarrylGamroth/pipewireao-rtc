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
Twelve synthetic tests cover repetition, missing evidence, pacing boundaries,
underdrive, independent delivery/deadline outcomes, failure bounds, numerical
policy, HEART exact-model enforcement, child exits, placement and missing DM.
