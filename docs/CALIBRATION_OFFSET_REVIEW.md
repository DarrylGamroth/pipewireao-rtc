# Operational measured-offset export review

Independent source and bounded-test review, 2026-10-03. This is review
evidence, not a new normative contract. Authority remains
[RTC-ARCH-023](architecture.md#instrument-calibration-through-deployed-endpoints) and
[RTC-DEV-029](operations.md#rtc-dev-029--operational-interaction-calibration).

Reviewed worktree: `/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-calibration-quality`,
branch `work/classic-calibration-quality-20261003`, starting HEAD
`3624d258505003ab2776deac9c3232c759af9b64`. Reviewed uncommitted changes in
`deployment/export_hil.py` and `deployment/test_export_hil.py` only. Existing
campaign source/test changes and `docs/CALIBRATION_QUALITY_REVIEW.md` belonged
to other work and were preserved. The reviewer owns this document only.

Initial reviewed source SHA-256 (before OFFSET-R1 remediation):

- `deployment/export_hil.py`: `e451f14c3f4ec44a4c17554aa46d12d5fe173962e3f478d4775efdfeb8874956`.
- `deployment/test_export_hil.py`: `97ea4fcc781c1f481a4b7ea9842ae617300b1b00469ec20738eaf0f6870b0017`.

## OFFSET-R1 — Importer accepts recipes rejected by the campaign producer

- Severity: medium. Confidence: confirmed by source and isolated execution.
- Disposition: corrected; independently verified. Original evidence below is
  retained; the verification update records the final implementation.
- Locations: `deployment/export_hil.py`, `operational_calibration` recipe
  validation around lines 250–261; `deployment/test_export_hil.py`,
  `MeasuredFixture.__init__`; existing authority in
  `deployment/calibration_campaign.py:58`, `validate_recipe`, and line 293,
  `stage_base` ADC-rail consistency check.

Observed: the importer duplicates a subset of the maintained recipe checks:
version, zero reference, candidate mask, seeds and lamp magnitude. It omits
the complete field set, frame counts, settling rule, flux thresholds, ADC
rail, amplitude representation and deadlines. The new positive fixture has
only five recipe fields and cannot pass the existing producer validator.
Nevertheless, it is accepted as `operational-measured-offsets` for both FGN
and JFG.

Additional bounded experiments supplied all recipe fields using the existing
campaign test fixture, changed one field, and updated the nested recipe and
source/deployed provenance hashes consistently. No RTC process was launched.

| Input | Maintained producer contract | Observed importer result |
| --- | --- | --- |
| Missing required fields, unchanged new positive fixture | `validate_recipe` rejects incomplete recipe | Accepted for FGN and JFG |
| `training_frames = 1` | `validate_recipe` requires at least two | Accepted for FGN |
| `settling = {kind: sleep, seconds: 1}` | `validate_recipe` rejects unsupported settling | Accepted for FGN |
| `adc_upper_rail = 65535`, recorded detector `bits = 12` | `stage_base` requires rail `2**bits - 1`, hence 4095 | Accepted for FGN |

The first three producer rejections were executed directly. The ADC mismatch
was accepted by the importer; producer rejection follows directly from the
existing `stage_base` equality guard, which was inspected without launching
that stage. This is an import-contract/provenance defect. It does not establish
that any actual completed campaign or its measured arrays are incorrect.

Consequence: internally consistent hashes do not ensure that an imported
document could have been produced by the declared campaign protocol. A stale,
manually edited or incomplete recipe can receive operational provenance while
declaring unsupported acquisition or saturation semantics. The incomplete
positive fixture hides this divergence.

Smallest coherent remedy: invoke the maintained complete recipe validator at
the import boundary, then retain the additional zero-reference restriction.
Share or reuse the existing detector-bits/ADC-rail consistency rule. Avoid
adding another copied field-by-field validator. Make the exporter positive
fixture producer-valid; add focused rejection cases for missing fields,
invalid frame counts, unsupported settling, invalid thresholds/amplitudes and
detector/rail disagreement. Preserve rejection before output publication.

Minimal fail-before reproduction from the repository root:

```python
import sys, tempfile
from pathlib import Path
sys.path.insert(0, "deployment")
from test_export_hil import MeasuredFixture
from calibration_campaign import validate_recipe

for engine in ("fgn", "jfg"):
    with tempfile.TemporaryDirectory() as directory:
        fixture = MeasuredFixture(Path(directory), engine)
        try:
            validate_recipe(fixture.recipe)
        except ValueError as error:
            print(engine, "producer rejection:", error)
        print(engine, "import result:", fixture.preserve()["mode"])
```

Observed output for each engine: producer rejection
`unsupported or incomplete campaign recipe`, followed by import result
`operational-measured-offsets`. The remediation regression should construct
an explicit incomplete recipe; updating the positive fixture alone would
otherwise remove this reproducer without testing rejection.

## Boundary and implementation assessment

The importer checks measured payload extents, element representations,
finiteness, Boolean masks and result hashes before adoption. It checks
source/base/deployed graph and parameter identities; stage-result equality;
lifecycle completion; detector noise, seed and illumination snapshots;
estimator geometry, coordinate arrays and thresholds; and correlated zero
adopt/restore completions for the offset-acquisition stages. Exact stage
detector settings are compared with the target except the declared RNG seed.
Plant comparisons permit only the documented cadence, seed and magnitude
differences. These checks have distinct import-boundary purposes and are not
defects merely because they add substantial code.

The target adoption writes only background, reference slopes and active mask
payloads and the corresponding construction mask. Reconstructor and coordinate
maps remain the target package's artifacts. The return record explicitly
disclaims reconstructor acceptance and scientific correction. Acquisition
completion is not promoted to matrix acceptance.

Zero physical reference is checked against the recipe, interaction plan and
offset-stage command completions. The graph inspection rejects a system-flat
binding/node in the maintained Classic profile. This review covers that
maintained profile; it does not certify arbitrary custom graph topologies or
physical command origins.

The public export uses a sibling temporary directory, validates the completed
package, then renames it into the requested new output path. Failure removes
the temporary directory. Source campaign and base inputs are read, not adopted
in place. The helper's writes occur inside that staged package when called by
the public export. Default selection still calls the existing simulated
calibration helper and retains its historical-fixture label.

The concrete duplication finding is OFFSET-R1: a second partial recipe
validator has already diverged from its maintained owner. Source/deployed
identity checks and independent expected-value tests should not be removed
solely to reduce the diff size. No new framework or validator registry is
justified by this review.

## Verification and limits

- Executed `python3 -m unittest test_export_hil test_calibration_campaign`
  from `deployment/`: **32 test methods passed**, exit 0. Expected argparse
  output from the missing-argument test appeared during the run.
- Executed the incomplete-recipe reproduction for FGN and JFG and the three
  full-recipe mutation experiments above; each reproduced acceptance.
- Inspected the complete changed export path, surrounding producer/analysis
  code and the active architecture/operating requirements.
- Ran the code-quality skill's hotspot scan. Length/branch/name signals were
  treated as inspection prompts, not additional findings.
- No RTC launches, hardware actions, scientific acceptance, legal clearance,
  or production-code edits were performed. Reported real-campaign helper
  successes were not independently rerun here.
- Source compatibility and functional export checks do not establish
  uncertainty, matrix rank/conditioning, closed-loop correction or cadence.

No other confirmed defect was established in the initial bounded review.

## OFFSET-R1 verification update

**Corrected and independently verified, 2026-10-03.** The importer now calls
the maintained `calibration_campaign.validate_recipe` before examining or
adopting payloads. Its additional zero-command-origin restriction remains.
The former inline ADC-rail equality rule is now
`calibration_campaign.validate_detector_rail`; both `stage_base` and the
importer call it. The importer checks the target and each recorded source
detector. Source inspection confirms this extraction preserves the producer
rule and introduces no alternate recipe contract. The import is deferred
inside the helper because the existing campaign module imports the exporter
while loading; no import-time call or new dependency was introduced.

The positive fixture now contains the complete, normalized producer recipe.
The regression deliberately replaces that recipe and updates nested source
identities, so rejection tests the intended contract rather than stale hashes.
The prior minimal reproduction above is historical: running it with the new
positive fixture alone no longer constructs an invalid input. The maintained
regression constructs the missing-field case explicitly.

Independent execution passed four focused test methods, exit 0:

- `test_reuses_complete_producer_recipe_contract_before_adoption`: seven
  invalid-recipe cases for each of FGN and JFG, including all four reported
  cases; target file hashes remain unchanged after every rejection.
- `test_default_export_still_selects_historical_fixture`.
- `test_default_simulated_calibration_calls_existing_detector_script_and_labels_fixture`.
- `test_preserves_exact_bytes_maps_and_inputs_for_both_engines`.

Independent log:
`~/.cache/rtc-calibration-quality-offset-r1-independent.log`.
No RTC or Julia process was launched by these tests. The source still selects
the original simulated-calibration path when the option is absent. Adoption
still preserves exact measured offsets while retaining target reconstructor
and maps, and uses the existing staged publication boundary.

The following worker logs were independently inspected; their execution is
distinguished from the four methods independently rerun above:

| Cache log | Evidence | SHA-256 |
| --- | --- | --- |
| `rtc-calibration-quality-offset-r1-before.log` | Missing-field acceptance for both engines; invalid training count, settling and ADC rail acceptance for FGN | `5fa4c2c5cef29a6f1b018a6c794e6923b50f0737b4e747a7de37da76a0ff38eb` |
| `rtc-calibration-quality-offset-r1-after.log` | All four reported cases rejected for both engines, target untouched | `0509cfe12f256e28f996e3b6c7d662ccb8b487a9946e75d18900dbf536a86a9a` |
| `rtc-calibration-quality-offset-r1-tests.log` | 46 methods run, 45 passed and one installed-package matrix test skipped | `4b4bdf9180ee8a801470bd3e6f4adace09bffe1a2da97aa0aaa16de3468271e0` |
| `rtc-calibration-quality-offset-r1-real-fixtures.log` | FGN and JFG real-campaign helper checks passed with exact offsets and unchanged campaign hashes; no RTC or Julia launch reported | `95a54a52dc60a9c1dbf56a7c6148617a78eef612dad16f8c0bec5d05fe33954e` |

All four worker logs are under `~/.cache/`. Their real-campaign helper result
identities are respectively
`2db0ed749da8e1413b9435419f06abfec6cf033849493cc18f6848ac5d0984a2`
and `a957d6407625051e1321a0199edb6e41bc4ceb0cd58cfd7e4d44bea23e6c422e`.

Final independently inspected source SHA-256:

- `deployment/export_hil.py`: `e19da7e0e2e2309477ee9bb7245d5fcfee2b97830c57d4dad817cef5306e0d10`.
- `deployment/test_export_hil.py`: `b90096f54834abf12709c797ea4672381208475fd1acaba7fe980511f2973ef0`.
- `deployment/calibration_campaign.py`: `d9174ea14a5e007db58ceed0c0e0ed79a89a2d8a96a4e2567411e50f17460cc2`.

No remaining confirmed import-contract defect was found in this remediation.
OFFSET-R1 is closed. This disposition establishes the reviewed software
boundary; it does not accept a matrix, qualify correction or cadence, or
provide legal clearance.
