# Copper WirePlumber/HIL coexistence

Experiment series: 2026-10-06. RTC base `37dfc3a`, initially clean; branch
`feat/wireplumber-compatibility-pilot-20261006`, worktree
`/tmp/rtc-wireplumber-pilot-20261006`. This extends the
[isolated compatibility fixture](../wireplumber-compatibility-20261006/README.md).
WirePlumber `bdc17eb` (0.5.18), PipeWireAO `29da2d6` and installed SDK 0.6.17
are unchanged. The private WirePlumber build uses AO dependency aliases;
it is neither a global installation nor a release recipe.

## Scope and ownership

The installed Copper packages run CUDA AOS with CPU FGN or CPU JFG. Artifacts,
algorithms, scientific settings and placement are reused from the
[baseline/update checks](../live-artifact-updates-20261006/README.md).
Package descriptor hashes match those baselines. Model exposure/period is 2 ms;
wall pacing is 100 Hz with 512 closed-loop exchanges and a retained 256-frame
prefix. These are functional checks, not independent offered-load measurements.

The runtime owns scientific admission, source hold/release and every link.
WirePlumber observes the selected ports and links by ID and serial. Its profile
loads only Lua scripting and this development observer. It creates no links,
launches no scientific owners and does not authorize acquisition. A port/link-only
ObjectManager avoids node parameter activation; port parameters are still read.
No GUI is attached. Controls use the existing native SDK; JSON is saved
configuration/evidence only. Desktop audio and the separate GUI/HIL session
were untouched. CPU0/1 were excluded; the coordinator/observer use CPU6 and the
owners retain their admitted deployment placement recorded in the receipts.

## Observed results

| Check | CPU FGN + CUDA AOS | CPU JFG + CUDA AOS |
| --- | --- | --- |
| Source held throughout discovery | Ready, paused, sequence 0 | Ready, paused, sequence 0 |
| Exact topology/role owners | Six ports, three declared RTC-owned links | Six ports, three declared RTC-owned links |
| Native incompatible-format rejection | 30 checks | 28 checks |
| Run 1 / run 2 completion | 512 / 512 frames and commands | 512 / 512 frames and commands |
| Native stop/reset/start and midrun stop/resume | Pass; fresh reset generation and cleared sequence/report cursor | Pass; fresh reset generation and cleared sequence/report cursor |
| WirePlumber SIGKILL while held | Sequence 136 | Sequence 135 |
| Links after WirePlumber death | Same IDs, serials, formats and client owners | Same IDs, serials, formats and client owners |
| Retained frames/commands against reset and own earlier baseline | Exact 256-exchange SHA-256 equality | Exact 256-exchange SHA-256 equality |
| Simulator heap/GC in each measured tail | 256 exchanges, 0 B, zero GC pauses/time | 256 exchanges, 0 B, zero GC pauses/time |
| Owned shutdown/cleanup | Confirmed, no fallback | Confirmed, no fallback |

Prefix equality covers 120 FGN and 121 JFG exchanges after WirePlumber death.
It does not establish equality of all 512 payloads. Truth diagnostics were
disabled; equal empty truth records supply no optical-truth evidence. Allocation
counters cover the simulator process after the retained prefix, including optics,
transport, recording, diagnostics and controls, excluding final report
serialization. They do not measure FGN/JFG allocation here. Pause/death/resume
occur before this measured tail and their allocation costs are not qualified.

Commands are `[277]`, F32_LE, ROW_MAJOR, micrometre OPD; pixels are `[64, 64]`,
U16_LE, ROW_MAJOR. The third link carries a `[253, 3600]` reconstructor parameter.
Data links advertise 500/1 independently of wall pacing. JFG's parameter link
omits rate, giving four negative checks on each of its two parameter ports;
all other ports have five. The observer does not invent a missing rate.

[FGN](fgn-receipt.json) and [JFG](jfg-receipt.json) receipts retain exact object
and owner identities, source/binary hashes, placement, controls, summaries,
prefix hashes and cleanup. Small deployment/WirePlumber logs are retained here.
Raw ADC/command recordings and large registry snapshots remain in the receipts'
temporary paths and are not duplicated in Git.

## Probe corrections and independent review

Initial failures were harness/API issues, not demonstrated defects in scientific
processing or pixel transport. The [failure ledger](investigative-failures.json)
preserves reasons, source hashes, receipt identities and successful owned cleanup.

- Registry inspection needed a scoped AO `LD_LIBRARY_PATH`.
- `WpSpaJson:parse(1)` leaves nested arrays as strings; recursive `parse()` fixed
  cohort arguments and the next run discovered the selected objects.
- Sparse EnumFormat offers can omit parameter rates; this post-admission
  observer validates the actual negotiated Format.
- Lua POD parsing omits String, Array and Fraction values inside single-choice
  wrappers, confirmed by dumps and upstream `api/pod.c`. Existing native
  `pod:filter()` validates original PODs. Required-field guards remain because
  filtering treats absent fields as unconstrained. No decoder is introduced.
- The generic `rate` short name selects audio's integer property. The public
  NDArray key `id-01000004` supplies the Fraction type through WirePlumber's
  existing numeric-key support.

Every final port accepts its negotiated contract and rejects changed schema,
first shape dimension, element type, layout, and rate when present. This proves
these contracts and selected mismatches, not general Choice decoding. A small
native-filter fixture established these checks before repeating HIL. Final Lua
syntax validation and nine focused Julia topology/owner tests pass.

A separate read-only agent verified source, final receipts, raw retained hashes,
declared endpoints/passive policy and role PIDs. No blocking defect remains for
this bounded claim. Review findings are disposed as follows:

| ID | Finding | Disposition |
| --- | --- | --- |
| WPH-001 | Equality could miss operation after observer death | Kill before 256; verify retained baseline/reset hashes; retain full-sequence/truth limits |
| WPH-002 | Pin topology and exact role owners | Declared directed endpoints/passive policy and owner PIDs checked; negative tests pass |
| WPH-003 | Discovery could miss later observer failure | Check process health and loss/Lua-error markers until planned kill |
| WPH-004 | Validate rate and complex Choice values natively | Required-field guard, native filtering, deliberate mismatches and public Fraction key |
| WPH-005 | Bind evidence to experiment extent | Sealed 256/512/100-Hz provenance and completed extents checked; shared ports deduplicated |

Logs retain the optional SPA D-Bus warning and FGN preparation's existing Julia
precompilation/version warnings. No startup-time or warning-repair claim follows.
Scientific packages and upstream WirePlumber were not edited.

## Remaining gates

This pilot preserves the accepted runtime-owned-link fallback. Link transfer is
not implemented. Keep runner link admission and cleanup until connection policy,
pending withdrawal, fresh owner replacement, runtime/required-AOS loss and
admission/failure parity are qualified. WirePlumber replacement, multiple WFS/DM
endpoints and mixed-rate shared-plant operation are not covered here.

Systemd process ownership is a separate migration; these runs use the existing
supervisor. Build/release selection, service dependencies, held admission and
required-owner failure gates must pass before removing that supervision. No new
latency, maximum-rate, progressive, physical-device or scientific-equivalence
claim follows from this experiment.
