# Managed instrument HIL migration

The instrument profiles select the process and its ports in YAML. The optional
`PipeWireAORTCExt` in AdaptiveOpticsSimPipeWireHIL binds the process to the
existing OwnerBootstrap and SourceControl protocols. RTC exports the cold
configuration and retains session admission, required endpoint checks and
link ownership. HIL owns the simulation task, model cursor, graph and data
streams. Device drivers and graph hosts publish their own Nodes and Ports.

| Boundary | Contract |
| --- | --- |
| Bootstrap | HIL starts the shared bootstrap monitor before importing science. RTC selects its exact PID, node and instance. The source warms held and acknowledges Connect after activating and verifying its data endpoints. |
| Source control | One bounded mailbox stages native Props. The source task commits control between scientific duties and acknowledges its actual cursor. Lockstep Pause waits for every matching command. Reset while held advances generation. |
| Simulation | HIL reuses the public frame exchange and optical execution. The pupil source uses the physical-offset transport and the same scientific pupil packet contract used by calibration. |
| Configuration | The HIL process consumes the existing sealed authored simulation selection. The independent manifest loader and execution entry point also run in a project without RTC. |

Classic and GPI2 retain the camera and applied-command contracts, including
the named DM command cohort in GPI2. CAL2 retains the external-pupil port.
SPIDERS retains its clocked source and independent detector exposures.
The GPI2 pupil-only composition retains its physical-offset input and
scientific pupil output. The host YAML declares optional accelerator
dependencies explicitly.

## Verification cohort

Julia 1.13.3, PipeWireAO 0.9.2, PipeWireAO_jll 4.0.2+0,
FilterGraphAlgorithms 0.12.0, FilterGraphs 0.10.0, FilterGraphPipeWire 0.5.2,
AdaptiveOpticsCalibration 0.17.3 and AOS 0.3.22 at `c058f32f`.
RTC 0.7.2 and HIL 0.5.1 were loaded from their migration worktrees.
The instrument repository started from `c8e805e`. The fitted SPIDERS build
used the existing generated fitted optical assets from that checkout.

| Repository | Verified changes |
| --- | --- |
| PipeWireAORTC | `dc149c9` exposes cold preparation and external process placement. `b20c38f` shares HIL pupil packet packing with calibration. |
| AdaptiveOpticsSimPipeWireHIL | `d6b0213` and `07f51b6` host managed sources. `56b75ba` prepares inactive transport before Connect. `75a062b` starts bootstrap before loading HIL. |
| Instrument profiles | `e4b79c2` migrates the profile declarations and dependency cohort. `ac8ec0c` selects the shared cold bootstrap launcher and adds the private-core selector. |

The private-core selectors launch the built profile's HIL command with the
configured leader CPU, bind its exact bootstrap identity and exercise its source
endpoint. The test selects a source environment in place of the deployed
project so it can use the candidate revisions. Classic uses the final cold
launcher. The other profile runs use the same managed HIL handler through its
loaded-package entry point. The lockstep
checks use ordinary PipeWire frame and command peers to verify exact exchange
and held reset. The pupil fixture uses a synthetic one-mode P/Q receiver for
transport validation. CPU/private-core results apply to the software path
and the selected profiles.

From the instrument repository, select the candidate source project with
`--project` and export a named profile and host combination. The following
commands build and check Classic.

```sh
julia --project=SOURCE_ENV tools/build.jl revolt-classic BUILT_APPLICATION \
  revolt-classic/profiles/simulator/profile.yaml \
  --host revolt-classic/profiles/simulator/host.cpu.example.yaml
julia --project=SOURCE_ENV test/managed_hil_private_core.jl BUILT_APPLICATION
```

| Check | Result |
| --- | --- |
| Cold instrument export | Seven application definitions exported. Classic, GPI2, GPI2 pupil source, CAL2 and the three SPIDERS optical variants. |
| Classic and GPI2 lockstep | 12 and 14 checks. Camera frame, exact command cohort, Pause after adoption, held Reset and Quit. |
| GPI2 pupil source | 10 checks. Synthetic one-mode receiver, scientific pupil publication, Pause, Reset and Quit. |
| CAL2 external pupil | Five checks on the full profile, covering bootstrap, held Reset and Quit. The smaller HIL selector also verified actual delivery at two independent exposure durations. |
| SPIDERS clocked source | Nine checks per nominal, Proper and fitted variant. A linked detector peer received the profile's data and cursor before Pause, Reset and Quit. |
| HIL and RTC focused checks | 18 managed external-pupil checks through the cold entry point, 33 standalone private-core checks without RTC, 46 phase timing checks, 31 placement checks and 15 calibration preparation checks. |
| Formatting | Changed authoring YAML and TOML passed. Repository-wide lint still reports formatting in pre-existing generated calibration records and archived benchmark inputs. |

The initial full CAL2 trial reached Prepared and expired during Connect.
That implementation compiled live transport methods inside the Connect
window. Commit `56b75ba` moved that work into Preparing with the streams
inactive. The same CAL2 profile passed with its existing bootstrap deadline.
The managed entry-point check observes Preparing before the scientific
preparation completes. The application declarations use that shared cold
entry point. The first Classic test omitted the service's CPU affinity and could
schedule the source on the diagnostics CPU. The selector now applies the exported
leader CPU to match the service placement. Classic then passed all 12 checks
with its freshly exported command. The selector also waits for both Ports to
appear in the peer registry before linking. SPIDERS Proper passed with that
registry wait.
