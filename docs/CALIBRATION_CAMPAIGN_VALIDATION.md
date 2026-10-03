# Automatic Classic calibration campaign validation

Baseline RTC `dccb179`; isolated implementation branch
`work/calibration-campaign-20261002`. AOC reference statistics are commit
`3c11576`. This increment adds finite capture and fresh-stage orchestration,
not another RTC graph or scientific estimator. See [usage](CALIBRATION_CAMPAIGN_USAGE.md),
the [delivery plan](CALIBRATION_CAMPAIGN_PLAN.md), the
[independent review](CALIBRATION_CAMPAIGN_REVIEW.md) and
[evidence identities](CALIBRATION_CAMPAIGN_EVIDENCE.json).

## Implemented path

The public deployment launcher prepares four independent Classic CPU sessions:
dark → lamp training → frozen-reference qualification → zonal interaction.
Each uses the deployed FGN or JFG WFS and command-constraint graphs, normal
simulated noisy ADC samples, commanded/adopted probes and associated exposure
completion. No camera or DM hardware is controlled and HEART is unchanged.

The optional serialized `capture` request owns a finite local payload budget,
exact raw/slopes/flux/validity channel sizes and a bounded manifest published
last. It retains complete invalid WFS observations for dark statistics without
weakening interaction response validity. Borrowed packed arrays are written
before another exposure is armed. These are finite calibration captures,
not logging in an RTC frame callback or a zero-allocation acquisition claim.

The Python campaign validates identity, generation, settings, declared bounds,
byte counts, payload hashes and complete exposure association before numerical
use. AOC owns dark mean and unbiased variance, individual absolute centroid
reference means, eligibility diagnostics and the existing structured zonal
estimate. The recipe owns flux/ADC/residual acceptance. Each stage must restore
the declared reference, release ownership, pass public stop/quit and observe
successful cleanup before analysis or the next stage. Unknown outcomes are not
retried. Five measured candidate files are produced; active calibration is
never overwritten.

## Observed installed results

Cache root: `/home/dgamroth/.cache/rtc-calibration-campaign-20261002`.
Cases `fgn-3` and `jfg-1` use the same explicit recipe: 16 samples per dark,
training and qualification window; detector seeds 0,1,2,3 respectively;
lamp magnitude 0.5; 188 candidates; per-position flux minimum 2,000 ADC;
upper rail 4,095 ADC; held-out mean-centroid residual bound 0.1 pixel.
Interaction uses zero reference, ±0.02 µm OPD, two samples per signed probe
and one discarded settling exposure. These are characterization choices.

| Observation | FGN | JFG |
| --- | ---: | ---: |
| All four stages restore/release/shut down; launcher exits zero | Yes | Yes |
| Eligible positions, without forcing a count | 184 / 188 | 184 / 188 |
| Maximum selected held-out mean-reference residual | 0.0213247538 pixel | 0.0213247538 pixel |
| Signed zonal commands / interaction observations | 554 / 1,108 | 554 / 1,108 |
| Estimated physical-coordinate interaction shape | 376 × 277 | 376 × 277 |

**Exact final artifact equality is observed:** measured background, dark
variance, centroid references, active mask and interaction matrix are
byte-identical. The matrix SHA-256 is
`c6757f1396062bf1da0dde527851f29c1c9c7a5270e163d272315570f215ec52`.

**Exact qualification trajectory equality is not observed.** All dark and
training channel payloads match. Four of 16 held-out raw frames differ, with
1, 33, 2 and 451 changed UInt16 pixels. Slopes and flux differ in the same
frames; intrinsic validity matches. Thus these separate runs cannot establish
processing parity on those unequal inputs. The original paired comparison
retains `all_passed=false`. No algorithm or transport cause is inferred from
final artifact equality or a common seed alone.

The historical 1,663-exposure fixed-input equality result remains separate
evidence in [the prior validation](CALIBRATION_ACQUISITION_VALIDATION.md).
It does not erase the current held-out discrepancy.

## Software checks and original failures

- Python deployment suite: 141 tests, passed, two skipped; focused campaign
  suite rerun after strict version validation was added.
- Julia server/protocol fixtures: 401 assertions passed on the final typed
  capture implementation. Owner startup options: 25 assertions passed.
- AOC combined reference/spatial/sharpening suite: 1,958 assertions passed;
  its independent numerical review is in the AOC repository. Spatial and
  sharpening operations are not selected by this zonal campaign.
- Changed architecture and operations Mermaid documents render successfully.
- Independent review findings retain their fail-before/pass-after evidence,
  including unknown-outcome recovery, stale metadata, authoritative deadlines,
  Float32 probe contracts and stale launcher identity rejection.

The first export failed before launch because an undeclared `sha256` field
was supplied to an existing typed parameter. Export now updates only a hash
binding already present. The second attempt failed before launch because
`deploy.py` is not executable; the campaign invokes it through the Python
interpreter. Both failures remain in the original evidence.

Installed nominal runs precede the final records-map typing and preflight-only
guards. Exact source hashes distinguish installed observations from final
unit-test evidence. No exact-hash final-source nominal rerun is claimed here.

## Remaining acceptance

RTC-DEV-029 remains partial: precision, linearity, observability, 277-physical
to 221-controller coordinate composition, accepted reconstructor and simulated
correction, Copper, unchanged HEART calibration and GPU/cadence checks remain
open. The held-out input discrepancy must be characterized before reporting
exact campaign trajectory equivalence. No hardware, optimizer convergence,
hard real-time or rate qualification follows from these software results.
