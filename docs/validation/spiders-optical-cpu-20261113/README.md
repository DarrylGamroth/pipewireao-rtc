# SPIDERS fitted-dual offline CPU calibration

The shared instrument optical launcher from instrument revision `ff07f84`
used the same fitted-dual export for both the upstream and optical inputs.
It used Julia 1.13.3, registered PipeWireAORTC 0.7.19,
AdaptiveOpticsCalibration 0.17.4, AdaptiveOpticsSim 0.3.22,
AdaptiveOpticsSimPipeWireHIL 0.5.1, FilterGraphs 0.10.2,
FilterGraphAlgorithms 0.12.2, FilterGraphPipeWire 0.5.3 and PipeWireAO 0.9.2.
The export used a locally staged compiled optical model. The temporary launcher
added observation and publication logs without changing the recipe or numerical
criteria.

| Input | SHA-256 |
| --- | --- |
| `deployment.conf` | `3d7ab4a02ec87152bb0609f686c8a654a7e9322a6ee30fe573d33da0018d1c50` |
| `calibration/optical-dual.yaml` | `43af780666237c432a8aa801f3d4c25ae8ef557a63bb628d4fbc3220fc2da478` |
| `calibration/materialize-dual.yaml` | `05429f3c498fa0e51e1afe86c04b470f2e418d10516ae65027887a536007c793` |

## Runtime observations

The [first attempt](../rtc-0719-20261112/README.md#spiders-fitted-dual-attempt)
ended with exit status 143. The origin of SIGTERM remains unconfirmed.
The retry ran in a transient user unit with a three-hour limit. In an early
sample, 96.06% of the sampled CPU cycles were in LLVM. A native stack showed
LLVM's consecutive-store merge inside Julia JIT code generation. Later samples
showed single-precision FFTW execution in the external-pupil exposure step
during both the first interaction pass and the refit with LLOWFS nulling.
Those samples identify two sources of runtime without attributing the first
attempt's termination to either.

A separate diagnostic at Julia `-O0` reached observations earlier, but took
41.6–41.9 s for its first two observations versus roughly 23–29 s for warmed
observations at the default setting. The runs overlapped, and the diagnostic
was stopped after the comparison. It did not produce a bundle. Neither run
opened a PipeWire core or tested an instrument.

## Acceptance and publication

The default run finished successfully in 46 min 42 s. The 89 logged
observations took 22.7–28.9 s each and accounted for 36 min 18 s in total.
Peak memory was 4.3 GiB according to the user service.

| Branch | Owned modes | Reported rank | Full/half derivative error | Recovery error |
| --- | ---: | ---: | ---: | ---: |
| LLOWFS | 2 | 2 | 0.0212251 | 9.66 × 10⁻⁸ |
| SCC | 8 | 10 | 0.00006046 | 4.42 × 10⁻⁷ |

The SCC fit includes all ten columns and publishes estimates for the eight SCC
modes. Both branches passed the existing 5% numerical criteria. The initial
projection before LLOWFS nulling failed its diagnostic held-out check. The
refitted projection passed all three held-out mixtures with a maximum relative
reconstruction error of 2.277% and a maximum corrected-to-uncorrected pupil
RMS ratio of 0.02725.

Publication loaded the exact typed FITS bindings into both branch graph
configurations before making the index visible. A separate read through the
registered RTC bundle reader validated both reports, contexts, graph hashes
and all 60 artifact entries. The index, report hashes and five shared
projection hashes matched the published files. Both reports were marked
accepted and deployable. This is simulation-local calibration evidence with
the upstream fast loop held.

| Product | SHA-256 |
| --- | --- |
| `calibration.yaml` | `90eb5d995e186df6f4a6385c682296813bdca9b551d55c1278ebcf744f7349fd` |
| `llowfs/result.yaml` | `ec1a7491ff1401bd4a666750612e0a9a093963fe5180011484b19423309448fa` |
| `scc/result.yaml` | `cef1ec45c3bb872c0dd9422ee590b3453ec422a722bf64b2e5f2aa7d92fb9e87` |
