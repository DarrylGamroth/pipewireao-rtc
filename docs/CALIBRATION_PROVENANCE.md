# Calibration source and dependency provenance

Reviewed 2026-10-03. RTC baseline `04f692c2178ed79726232d409ba40fddd21b672d`;
AOC baseline `3997efe82d0e762d605b1d734864b076f73669ed`. This record constrains
the next calibration increment. It is not a license grant or clearance of the
complete deployment dependency graph.

## Implementation rule

The selected work must not copy, translate, adapt or import GPL implementation
code into our packages. This includes tests, fixtures, generated tables and
examples. An unknown source license does not authorize reuse. Reading a method
description does not establish rights to its implementation.

Implement numerical operations from explicitly documented mathematical
contracts, with independently written tests. Use primary mathematical
references where available. Record the origin of instrument-specific formulas
and conventions rather than describing all equations as generic. Do not call
an implementation clean-room merely because it has different identifiers or
uses another language. The earlier reviewers had access to reference material.

Any proposed reuse of permissively licensed material needs the exact source
revision, applicable file license, required notices and an explicit record of
what was reused. No such source reuse is selected by this increment.

Dependencies require a separate inventory of wrappers and native libraries,
their resolved versions, selected providers, licenses and distributed artifacts.
A permissive wrapper license does not establish the native library's license.
Do not silently replace a numerical backend to avoid this review.

## External references

| Reference | Observed license / identity | Selected treatment |
| --- | --- | --- |
| pyRTC | [GPL version 3 text](https://raw.githubusercontent.com/jacotay7/pyRTC/1c0a55e81433eb7499808cac9c2641d8d6b4cfd7/LICENSE), revision `1c0a55e81433eb7499808cac9c2641d8d6b4cfd7` | Method inventory only; no implementation, translated code or fixtures imported |
| MagAO-X | [GPL version 3 text](https://raw.githubusercontent.com/magao-x/MagAOX/66a6087f7c4dbb7197468c43c9259d3e8b0350d3/LICENSE), revision `66a6087f7c4dbb7197468c43c9259d3e8b0350d3` | Method descriptions only; no implementation, translated code or fixtures imported |
| SPECULA | [MIT license](https://raw.githubusercontent.com/ArcetriAdaptiveOptics/SPECULA/e52b12cd6751568e6daad559c85c28f981ee58c2/LICENSE), revision `e52b12cd6751568e6daad559c85c28f981ee58c2` | Reference inventory; no copied implementation selected |
| Local SPIDERS sharpening script | SHA-256 `fe2dc48de82539bfbd0c4a6a67ee5032e3c2374de00d7d364ce13663ea8361c5`; source license and public revision not established | No source reuse authorized; AOC's recorded numerical-contract reimplementation needs its provenance retained |

Licenses above were checked against the cited primary files. Their presence
does not establish that every file in a repository has the same license.

## Recent AOC addition audit

Scope: `875a7c2..3997efe`, specifically ReferenceFrames (`3c11576`), spatial
sinusoidal probes (`d2c27a8`), focal-plane sharpening (`ecd4fab`), their tests
and integration documentation. The audit does not cover every historical AOC
algorithm or every RTC dependency.

Observed from the current source and Git diff:

- `Project.toml` is unchanged across this range: no dependency was added.
- The added modules do not import pyRTC, MagAO-X, SPECULA or SPIDERS.
- The mathematical contracts cover Welford moments, explicit spatial sine/cosine
  sampling, weighted core intensity, SPSA and Adam. Their ordinary-array
  reference tests and numerical review are recorded in AOC's
  [method review](https://github.com/DarrylGamroth/AdaptiveOpticsCalibration.jl/blob/3997efe82d0e762d605b1d734864b076f73669ed/docs/CALIBRATION_METHODS_REVIEW.md).
- The focal design states that the implementation and tests were independently
  written from its numerical contract; it preserves the SPIDERS source hash
  and the source-specific metric conventions.

No copied GPL implementation was identified in this bounded audit. Absence of
imports or matching text alone cannot establish independent authorship. The
audit has not reconstructed drafting history or cleared historical migrations.

## Findings and disposition

| ID | Evidence / confidence | Required disposition | State |
| --- | --- | --- | --- |
| CP-001 | AOC `3997efe` has no top-level license file; confirmed repository metadata | Owner selects a license for code they have rights to license. Preserve third-party terms; do not assume ownership of historical imports. | Owner preference requested; unresolved |
| CP-002 | AOC already directly depends on FFTW. Its existing optical-gain CPU implementation calls FFTW plans. [FFTW's own FAQ](https://www.fftw.org/faq/section1.html) identifies its GPL licensing. | Inventory resolved native provider and packaging obligations before asserting permissive distribution of a deployment. This is inherited, not introduced by the recent additions. | Selected provider established below; distribution assessment unresolved |
| CP-003 | SPIDERS script provenance has a hash but no established source license; confirmed documentation gap | Do not copy or translate the script. Retain source-specific mathematical attribution and the independent implementation evidence; obtain rights information before any future source reuse. | Source reuse excluded; provenance uncertainty remains |
| CP-004 | Recent source/doc audit supports the reported independent implementation but cannot recover drafting history | Independent bounded review before further scientific integration; distinguish evidence from a legal clearance. | Independent source review complete; historical authorship limits remain |

These findings do not demonstrate a GPL violation. They prevent a blanket
claim that the package or distributed RTC stack is free of GPL obligations.
The [quality plan](ANALYSIS_PLAN.md) keeps license/provenance checks separate
from numerical and simulation acceptance.

## Observed FFTW provider

The cached installed Classic owner environment at
`~/.cache/rtc-event-calibration-20261002/owner-installed-recording-fgn-full/base/hil/Manifest.toml`
resolves FFTW.jl 1.10.0 (tree
`97f08406df914023af55ade2f843c39e99c5d969`) and FFTW_jll 3.3.12+0
(tree `6866aec60ef98e3164cd8d6855225684207e9dff`). Runtime inspection selected
`fftw`, not MKL. The selected native artifact is
`fddee2a92d37e18a0b5265dce2aab7af84fd9242`, with
`share/licenses/FFTW/COPYING` and `COPYRIGHT`. Its COPYING contains the GPL
version 2 text; FFTW.jl's own README describes the native library as GPLv2 or
higher. Both Julia wrappers have MIT notices; FFTW_jll explicitly excludes the
wrapped binary from its wrapper license.

FFTW was added to AOC in `20cd9a9` for CPU optical-gain sensing. Current
`src/optical_gains/gain_sensing.jl` creates forward/inverse plans. The recent
reference, sinusoidal and focal modules do not call FFTW, but they share a
package with this direct dependency. Not calling the optical-gain method does
not establish the deployment's distribution obligations. MKL's presence in a
Manifest does not establish that it is the selected provider or settle its own
terms.

This observation applies to the identified cached environment. The source AOC
checkout's existing Manifest is not synchronized with its current Project;
do not use that stale Manifest to make runtime dependency claims. No provider,
dependency or package license was changed by this audit.

## Independent source review

An independent Astra review examined `875a7c2..3997efe` without fetching
external implementation bodies, editing source or running tests. It found no
confirmed copied/translated GPL material. The 19-file diff adds no dependency,
external fixture file, binary asset, vendored source or download. The current
code/tests are consistent with the documented AOC numerical contracts.

| Review ID | Severity / confidence | Disposition |
| --- | --- | --- |
| LIC-AOC-01 | Medium / high for the SPIDERS documentation gap | CP-003 retained open. A recorded independent-implementation claim is not independently reconstructable authorship history. Do not reuse source without established permission. |
| LIC-AOC-02 | Medium / high; pre-existing missing outbound license | CP-001 retained open. An author entry in Project.toml does not establish package terms; adding a license must not purport to relicense unknown third-party material. |

No full source-similarity comparison against GPL bodies was performed. No
historical migration audit or full-stack distribution clearance is claimed.

## Repeated-response diagnostics

The next independently written AOC diagnostic increment is
`3997efe..f79104d`. It adds repeated-response mean, sample variance, conditional
mean standard error and a low-rank covariance factor, with no dependency,
external fixture, vendored implementation or license change. Its equations
and numerical contracts are documented in AOC's
`docs/DESIGN_RESPONSE_MOMENTS.md`. Independent numerical review reproduced and
verified correction of a Float64 large-offset variance error before merge;
that software defect and correction are unrelated to source licensing.

The diagnostic has not been derived from pyRTC, MagAO-X or SPIDERS code.
Existing CP-001/CP-003 and inherited FFTW packaging questions remain open.
Numerical test success is not legal clearance or a new outbound license grant.
