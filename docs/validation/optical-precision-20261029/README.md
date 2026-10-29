# Explicit optical arithmetic precision — 2026-10-29

The RTC 0.2.50 candidate is based on `e991fe5` (0.2.49); the matching AOS source is
`ddd9a52bc74daaa142813c96e1555caf24c84949`, based on published 0.3.15.
The AOS compatibility floor is 0.3.16, the first release with this authored
precision contract. Julia 1.13.3 is used. Source overrides are validation-only and are not published
application runtime closures.

The optional `proper_optical_train` catalog property admits only `Float32` and
`Float64` and is read-only through runtime settings. Omission does not inject a
precision setting. AOS owns the selected typed graph and binding consistency.
The RTC executor, detector models, exposure times, masks and controller settings
are unchanged. Catalog bytes are included in prescription identity; unchanged
omitted-setting AOS graph bytes do not imply unchanged RTC calibration identity.

| Selector | Result | Scope |
| --- | --- | --- |
| Core `test/runtests.jl` with explicit registered native prefix | 7,978 pass, exit 0 | Existing cold/core CI selector; no science or GPU packages loaded |
| `julia --project=. test/test_simulation_source.jl` | 90 pass | Cold authored settings; explicit/omitted/invalid precision and read-only admission; no science/GPU imports |
| `PIPEWIREAORTC_TEST_BACKEND=cpu julia --project=SCIENCE_ENV test/captured_optical_preparation.jl` | 260 pass | Real CPU graphs at both precisions, monochromatic/finite-band/chopped preparation, changed inputs and reset |
| `PIPEWIREAORTC_TEST_BACKEND=cuda julia --project=SCIENCE_ENV test/captured_optical_preparation.jl` | 268 pass | Actual captured CUDA graphs at both precisions; scalar indexing disabled |

The cold selector fails before the catalog change with an unknown precision
property. Logs are retained as `/tmp/cal2-rtc-precision-{fail-before,pass-after}.log`
and `/tmp/cal2-captured-precision-{cpu,cuda}.log`.

The scientific environment uses CUDA 6.4.2, Proper 0.4.1, HIL 0.2.11 and
KA 0.9.45. The CUDA device is an RTX 3080 shared with an independently running
GPI session. This is functional execution evidence, not exclusive-device timing
or deadline qualification. The seeded detector-noise reset regression remains
at default Float64 optics; deterministic response/chopping/reset checks exercise
both optical precisions.

A validation-only full CAL2 Float32 optical feed measures approximately 47–49
pupil updates/s including integration and host wire conversion, before the
upstream plant, transport and controllers. The requested whole-pipeline 50 Hz
objective remains open. Neither this timing nor passing replay qualifies the
old calibration for Float32. Fresh calibration/held-out reconstruction and
application integration are required; noisy-loop acceptance remains pending.

The full core log is `/tmp/cal2-rtc-precision-core.log`. Its `git cat-file`
missing-object diagnostic is expected from `test_configuration_store.jl`'s
explicitly removed loose-object rejection check; the corresponding test passes.
Independent source review of the catalog/test change and the release metadata/
compatibility floor found no blocking finding. The added catalog property is
optional and introduces no new runtime dependency or scientific executor.
