# Classic mirror description review

Status: supplied-JSON source and mirror-description integration accepted.
No confirmed unresolved production defect remains in this review's scope.
The reviewer independently verified the final application receipts and both
simulator NodeInfo descriptions in the saved private-core dump. The primary
agent's broader WFS, GUI, and GPU-exclusion audit remains a separate gate.

## Authority and scope

The implementation agreement is `CONTRACT.md` in the task evidence directory
`worktrees/classic-mirror-description-20261022`. The final user direction selects
JSON.jl and an explicit JSON file supplied to the simulator. The earlier
ALPAOMirrors package design is superseded; there is no package to install or
register, no bundled simulator geometry, and no default asset path.

Starting revisions: ALPAO `c06c613`, ClassicSim `803dc0c`, RTC `b45f76d`, Classic
application `958f111`. Reviewed final native revision:
`faaad587d42257e128d6225b21ce9e5a1c8cb66f`. Reviewed scientific revision:
`248e588` (explicit file input). Final RTC revision is `0ed3da2`; final application
revision is `e5a64c5b05d597fcd403074ec73ada0b4ee2da65`. Source was inspected in
the dedicated `*-mirror-description` worktrees. The final application manifest
selects RTC 0.2.7 tree `0524ab42a862334c40a7fb42b82287ae0afd83f2` and
ClassicSim 0.2.6 tree `f7e26251c173d791a7bd986d4791d18ed3d1faf0`.

The scope includes source-grid command geometry, physical vector order,
instrument pupil registration, both Gaussian profiles, calibration propagation,
immutable cold preparation, metadata identity, native validation/NodeInfo byte
ownership, application-relative file resolution, and preservation of calibration
and presentation values. The reviewer edits only this report and has performed
no service, registration, GPU, ASDK, or hardware operation.

## Accepted design

- The sole canonical source file is ALPAO
  `data/mirror-descriptions/revolt-hsdm277.json`. Native installation and the
  sealed application carry copies of those bytes, not independent geometries.
- Native `device.mirror.description` uses existing factory/NodeInfo properties.
  Cold validation precedes backend creation; the sink owns exact bytes and
  exposes no runtime update parameter. Descriptor-absent behavior is retained.
- ClassicSim `read_mirror_description(path)` reads at most 1 MiB plus one
  rejection byte and returns owned immutable tuples. It checks the complete
  schema, duplicate keys, bounded integer positions, uniqueness, Unicode, and
  unknown fields. Each preparation reads once and retains its description.
- Pupil registration remains an instrument setting. The default pitch is
  0.125 in normalized pupil coordinates; source columns increase x and source
  rows decrease y. The default outer coordinate remains 1.125. No mechanical
  pitch, stroke bound, influence calibration, or hardware command-to-OPD fact is
  inferred from the device file.
- Both coordinate and grid profiles derive counts/geometry from that description
  and pitch/influence width from the selected registration. Source-grid
  Zernike/Fourier conventions remain independent. Float64 selected pitch is
  retained in scientific metadata even when Float32 coordinates round alike.
- The scientific identity contains content and registration, not installation
  paths. RTC resolves the configured relative file within the application and
  passes it to the scientific API. The existing operational instrument JSON
  shape and explicit command units remain intact.
- Simulator command-sink properties use public PipeWireAO property updates
  under the native thread-loop lock before admission. Applied-command properties
  use the existing HIL argument. No new message protocol or HIL package change
  is introduced.

## Findings and dispositions

### MD-R01 — malformed native Unicode accepted

Severity P2; confidence observed. The initial native string scanner accepted raw
`0xff` and an unpaired `x\\ud800` model string. An independent CPU-only validator
experiment returned success for both, allowing invalid exact bytes to propagate.
The final validator checks full-input UTF-8 and paired Unicode escapes. Repeating
the same experiment returned `-EINVAL` for both malformed inputs, while the
canonical file and a valid surrogate pair returned success. The final SDK-free
native suite includes these rejection paths. **Closed.**

### MD-R02 — finite selected pitch invalid in execution precision

Severity P2; confidence derived, then verified. Initial Float64-only validation
admitted finite pitches that became infinity/zero in Float32 or overflowed the
outer grid. Final validation checks positive finite Float32 pitch/influence width
and finite grid extent. The reviewer independently checked rejection of `1e300`,
`1e-300`, and `Float64(floatmax(Float32))/2` and preserved first default coordinate
`(-0.375f0, -1.125f0)`. The final file-input selector includes strict registration
tests across preparation and metadata paths. **Closed.**

### MD-R03 and MD-R04 — superseded package concerns

The interim package had an absolute development source path and a potential
data-only precompile-cache invalidation concern. Those were corrected in the
interim design, then the user removed package distribution altogether.
The final simulator reads its explicit input during cold preparation, so neither
package concern applies. **Retired with the superseded design.**

### MD-R05 — publication closure arity

Severity P1 for the selected descriptor path; confidence derived from the public
API. The initial simulator update used a zero-argument closure, whereas
`with_thread_loop_lock` invokes `f(loop)`, producing MethodError before admission.
The final source uses `do _`. Source correction and actual command-sink and
applied-command NodeInfo publication are verified by the final live receipt and
independent comparison of the saved graph dump with the canonical file.
**Closed, including integration evidence.**

An interim RTC test construction accidentally retained a scientific-only field in
strict operational JSON; it was corrected. Whole-document JSON rejection was
added during review. The JSON.jl migration now uses the existing bounded Common
parser, preserving decimal/integer distinctions and exact 64-bit identities.

The file input is independent of optional RTC instrument publication. The
primary agent removed an accidental coupling. The reviewer inspected the final
unconditional grid/layout/count validation and retained exact layout equality
when instrument metadata is selected. The final focused recheck includes actual
CPU scientific preparation without instrument publication and passes. **Closed.**

The old API calls in `test/aos_classic_preparation.jl` belong to an explicitly
historical graph-file oracle, not the new scientific package. The primary agent
confirmed this boundary; its oracle API is intentionally retained.

## Evidence inspected

Evidence files are in the task directory named above; final integration receipts
are owned by the primary agent.

| Evidence | Observed scope |
| --- | --- |
| `alpao-receipts/native-file-only-testlog.txt` | SDK-free native tests 3/3; final canonical path; unknown/malformed input rejection; caller input destroyed before exact-byte NodeInfo comparison |
| `alpao-receipts/native-file-only-install.log` and `file-only-asset-check.log` | Fresh staged installation and exact asset equality; removed Julia tree |
| `classic-file-description-cold.log` | 602/602; schema/immutable-file input, frozen geometry, selected registration, synthetic grid/count propagation, both profiles/calibration declarations |
| `classic-file-description-cpu.log` | CPU graph/profile, calibration, deterministic replay, science-analysis, and AOC checks; 876 passing assertions in the inspected completed output |
| `rtc-file-input-final.log` | 194 passing assertions covering metadata, selected science, file relocation, required file without invented default, and settings-management boundaries |
| `rtc-instrument-file-final2.log` | Final correction: 129 metadata assertions plus 32 generic warm/reset and 33 actual Classic CPU preparation assertions; no transport |
| `rtc-suite-final.log` | 2645 passing assertions at `34d054d`; the subsequent no-instrument correction is covered by the final 194-assertion selector above |
| `app-registered-tests.log` | Final registered environment: 25 instrument/description assertions and 60 calibration assertions pass |
| `app-offline-final.log` and `offline-final/offline-check.json` | 80 offline application checks pass with RTC 0.2.7; no services activated or simulator started by this offline check |
| `live-mirror-check.log` and runtime `live-mirror-check.json` | Both live CPU simulator nodes publish `device.mirror.description` exactly |

The reviewer independently compared all 26 baseline numerical/calibration/layout
assets in the application: `artifacts/*`, `calibration-result.toml`,
`parameters.conf`, `graph.conf`, and `operator-views.toml` are byte-identical to
`958f111`. The supplied JSON exactly matches the canonical source. Its SHA-256 is
`38cddc34342e08ee66546600daf1dee8599f7054e12f74f631fa649ccd004326`.
Operational `instrument.json` changes only its scientific identity and three
provenance/command-order text fields; geometry, limits, units, and display values
are unchanged.

Historical package-only test counts and cache experiments are retained in the
evidence directory for provenance, not used to accept the final design.
The first application authoring check passed metadata tests but could not load
FilterGraphIsland in that temporary environment. The final registered-environment
application checks supersede that incomplete check and pass calibration.

Final runtime receipts are in
`/home/dgamroth/.local/state/pipewireao/classic-cpu-mirror-live-20261022`.
The reviewer parsed `mirror-nodeinfo-graph.json` independently, selected each
node by its exact name, and compared the UTF-8 property bytes directly with the
native canonical file. Both descriptions contain exactly 2541 bytes with the
SHA-256 above. `simulator-command` is global id 121, serial 122;
`simulator-applied-command` is global id 117, serial 118. These identifiers also
match `live-mirror-check.json`. The receipt names CPU runtime
`d2fa50c0f07740428be9c27d0d0e4152` and private core `rtc-d2fa50c0f077`.
This independently closes the mirror metadata publication gate without making
a physical-device or broader runtime-performance claim.

Software simulation, native mock, parsing, and source inspection do not establish
physical ALPAO qualification, hardware calibration, real-time deadlines, or GPU
behavior. Those are outside this review's claim.
