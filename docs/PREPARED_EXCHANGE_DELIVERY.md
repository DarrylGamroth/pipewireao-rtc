# Prepared exchange delivery

## Accepted release pair

The prepared ndarray API is published in PipeWireAO 0.6.13, with the native
buffer-return correction in PipeWireAO_jll 1.7.0+19. Both releases and registry
entries are in DarrylGamroth's repositories. Native PipeWire and Yggdrasil
upstream repositories were not pushed; HEART was not changed.

The generic loan-exhaustion timeout tracked separately under CCR-006 came from
an old native client. Returning a borrowed buffer reinserted it without clearing
its native dequeued flag. The next dequeue rejected that same buffer and lost
available capacity. Native commit `42fdf86f4e66b15e7cc1d22404294f2234dfcb85`
already fixed ownership, input Busy accounting and insertion-error rollback;
the old JLL recipe did not include it.

The controlled test changed only the actual client library: the old JLL client
fails after 7 assertions at source completion; the fixed `/opt` client passes
133/133 twice. Julia's exchange algorithm and the oracle remain unchanged.
The freshly built JLL also passes three 133/133 runs with one/two Julia threads,
actual Julia and private-daemon mappings, exact receipts and warmed successful
source callback allocation of zero bytes. Native regression passes 1/1 and the
ordinary Julia package suite passes 1,506 assertions, including the 0.6.13
release candidate. These are functional checks, not RTC latency measurements.

A first registry-only check found a separate delivery gap: registered
PipeWireAO 0.6.12 predates the prepared API and fails before exchange with
missing `NdArraySource`. The already committed API was therefore released as
0.6.13. The HIL environment now requires at least that version. Earlier locked
manifests still need an explicit update and Julia restart.

```julia
using Pkg
Pkg.update(["PipeWireAO", "PipeWireAO_jll"])
```

Native product preferences may supply the fixed native revision independently
of a JLL wrapper version. A test daemon prefix by itself does not select the
client loaded by Julia. Product paths, modules and plugins must be consistent.
The source fix has no new ABI requirement and this delivery does not add an
executor, change a scientist's algorithm, or alter completion/failure semantics.

## Provenance and validation

- Native revision: `42fdf86f4e66b15e7cc1d22404294f2234dfcb85`.
- Own recipe: `33032e430`, replacing `d130d3afa` with the native fix.
- JLL source: `3d91d4cf5ec19336d418727acc7ee0c59670352f`, package tree
  `6847e65abbe43442d82db075c13433bf63845b4f`.
- PipeWireAO 0.6.13: `d6d2672d84a52228a75a32d0a6f00595deae37d7`, package tree
  `2216e057b6ef890b979735e67cc7914224099acb`.
- Own registry: `b4dbe50` (API registration), following `3bcdd21` (JLL).
- Raw evidence: `/home/dgamroth/.cache/pipewireao-exchange-completion-20261004`.

All five Linux targets were rebuilt with audits enabled. Ten release assets
(binary/log pairs) were downloaded again and match their built SHA-256 values.
The host selected AVX2 tree is `02332925c3953742006b7b962621affb654fc265`.
ISA warnings were independently adjudicated with exact encoding comparisons
and existing CPU-feature dispatch; they do not establish a native ISA defect.
Runtime validation of ARM or AVX-512 remains outside this host evidence.

[PipeWireAO validation](https://github.com/DarrylGamroth/PipeWireAO.jl/blob/main/docs/EXCHANGE_COMPLETION_VALIDATION.md)
and its [independent review](https://github.com/DarrylGamroth/PipeWireAO.jl/blob/main/docs/EXCHANGE_COMPLETION_REVIEW.md)
retain failed controls, native ownership analysis, package identities and
qualification limits. No frozen scientific artifact or earlier failed report
is rewritten by this follow-up. Selected calibration/correction acceptance
retains its original source/package identities. Ordinary native Copper
streaming CCR-017, physical endpoints, electronics and wall-clock cadence
remain separate work.

Final fresh `Pkg.add("PipeWireAO")` selects registered API 0.6.13 and JLL
1.7.0+19 without development paths or preferences. Saved resolution:
`published-resolution-v2.toml`. Both unchanged oracle runs pass 133/133:
`published-0.6.13-one-thread-1` (CPU 11) and
`published-0.6.13-two-thread-2` (CPUs 11,12). Each records actual new-artifact
client/plugin/core mappings and leaves no private daemon alive. Four focused
HIL release-bound assertions reject version 0.6.12, accept 0.6.13 and verify
both prepared endpoint exports from the published source.

This closes the selected host packaged exchange gate. Continuous HIL or
scientific correction is not rerun by this transport delivery check.

RTC package/export closure tests pass 174/174 (`rtc-package-export-tests.log`).
Five changed documents have no missing local file links and pass whitespace
checks; the roadmap Mermaid diagram renders successfully in the existing
Mermaid container. These checks do not launch a scientific RTC pipeline.
