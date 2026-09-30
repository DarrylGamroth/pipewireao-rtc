# Classic installed SPA sender

Status: the helper and private plugin candidates passed seven-frame exact-byte
source qualification and the all-five 63-frame receiver comparison at 100 Hz.
The installed FITS and ndarray plugins still need the owner fixes below;
longer source qualification remains pending. Private functional validation can resolve an
installation with its `spa_library_directory` set to
`/home/dgamroth/.cache/rtc-classic-spa-private-plugins-20260930`. That directory
contains frozen candidate FITS/ndarray DSOs and the unchanged installed HEART
plugin.

`run_classic_spa_sender.py` replaces only the replay sender in a Classic live
comparison. Its isolated source core loads installed factories from
`/opt/pipewireao`; receiver graphs, scientific packages, and HEART remain
unchanged. It uses this topology:

```text
api.fits.source (GRAY16_LE video, finite timerfd cadence)
  -> api.ndarray.video-view (row-major UInt16 ndarray)
  -> api.heart.std-wfs.sink (paced native-order stdWfs UDP)
  -> existing Classic RTC receiver on UDP 6000
```

The video view is required because FITS complete-frame ndarray output declares
column-major `[width, height]`, whereas the HEART sink requires row-major
`[height, width]`. FITS also offers packed `GRAY16_LE` video. The installed
video-view factory adapts that public format to the exact
`org.heart.std-wfs.raw-pixels/1` schema, preserves Header metadata, and forwards
shared buffer storage where negotiated. Its ordinary-buffer fallback copies
rows. It performs no calibration, pixel permutation, or scientific operation.
FITS conversion into the source buffer and the sink's owned copy for timed
packet transmission are existing transport requirements.

The sink configuration preserves UInt16 raw pixels, source 0, native byte order,
zero checksum, zero ROI offsets, 11 rows / 3,872 pixels per packet, and 32
packets per frame. The FITS Header sequence supplies frame IDs 0 through N−1.
The source publishes complete frames at `rate_hz`; the sink samples one realtime
wire timestamp per frame and emits packet 1 immediately, then uses its timerfd
at `readout_us / 32` intervals. The nominal first-to-terminal interval is
`readout_us × 31 / 32`, matching the original sender's packet schedule. Neither
transport component clips pixels or command values.

The source is an open-loop cadence: late processing can skip scheduled planes.
The helper rejects mismatched final packet counts; the UDP qualifier additionally
requires exact ordered frame IDs and bytes. Scheduler jitter and skipped frames
must be established by captured data, not by the declared rate alone. This is
source transport evidence, with no RTC numerical, capacity, deadline, or physical
operation claim.

## Integration API

After the existing receiver links, parameter preparation, and capture are ready:

```python
from run_classic_spa_sender import run_sender

report["spa_sender"] = run_sender(
    helper=helper,
    installation=installation,
    directory=directory / "spa-sender",
    cube=cube,
    frames=args.frames,
    rate_hz=args.rate_hz,
    readout_us=args.readout_us,
    rows_per_packet=args.rows_per_packet,
    source_cpus=args.source_cpus,
)
```

The helper blocks until the sink reports N complete transmitted frames and
32 × N datagrams, with zero rejected frames and send errors, then stops its
owned source daemon. Start the UDP receiver and capture before calling it.
The destination defaults to `127.0.0.1:6000`; optional `destination` and `port`
arguments can select another ordinary IPv4 receiver. `directory` must be new.
The helper returns the retained `report.json` content and raises on failure.

Disable PipeWire's parameter cache on the sink with the public
`node.cache-params=false` property: dynamic SPA counter values otherwise remain
at the cached initial snapshot after enumeration. This affects observation,
not transport. The helper includes this property in its generated configuration.

Callers using `run_classic_heart_live.py` can resolve the installation with
`helper.pipewire_installation(None, Path("/opt/pipewireao"))`; the FGN/JFG runner
already resolves it. Keep the existing receiver packet decoding, payload
comparison, source-counter checks, and numerical command qualification. Replace
only the wfsSimulator invocation; preserve the existing source CPU placement.
All five receiver paths can use the same helper.

If fewer than all available cube frames are requested, the helper uses the
existing `write_fits_segment` transport utility to write only that prefix. A
complete corpus run uses the original FITS file directly. No repeated scientific
simulation or reference computation occurs in the sender.

## Standalone source qualification

Run only while no RTC is using the receiver port or measuring performance:

```sh
python3 benchmark/run_classic_spa_sender.py \
  --cube /home/dgamroth/workspaces/codex/heart/revolt-rtc/sim_wfs_data/classic_wfs.fits \
  --output /home/dgamroth/.cache/rtc-classic-spa-sender-seven \
  --frames 7 --rate-hz 10 --readout-us 2000 --qualify-udp
```

The optional receiver binds exclusively before source startup. It retains
`wfs-packets.tsv` using the existing capture-table columns, validates exact
FITS pixel bytes and every fixed header field, frame ordering and completeness,
and one consistent wire timestamp per frame. `udp-summary.json` retains each
observed packet gap, first-to-terminal interval, and frame interval alongside
the nominal timings. Receive timestamps include receiver scheduling and UDP
jitter; they provide characterization, not a precise camera timing claim.
`report.json` records the source command, CPU envelope request, installed plugin
hashes, FITS hash, generated configuration hash, final sink counters, and daemon
return code. `graph.json`, `sink-props.txt`, and `daemon.log` retain the negotiated
topology and observations. Failed source runs also retain captures when available.

Focused regressions:

```sh
python3 -m unittest discover -s benchmark -p test_run_classic_spa_sender.py
```

The tests cover exact generated transport settings, input admission, dynamic
counter parsing, and rejection of corrupted, missing, and reordered packets.

## Observed startup issue

`SPA-SENDER-001` — confirmed startup failure, high confidence. The seven-frame
source runs at 10 Hz with 2,000 µs readout captured zero UDP packets. Diagnostic
startup at `/home/dgamroth/.cache/rtc-classic-spa-sender7-debug-20260930` shows
`classic-fits-video-view` receiving `Start` while its FITS input link is still
negotiating, and returning −EIO (`daemon.log`, line 1545). Negotiation later
completes and all nodes report running, but the view receives no successful
restart and the sink remains at zero counters. This is distinct from the
parameter-cache observation issue described above.

Derived mechanism: the generic SPA wrapper clears `NEED_CONFIGURE` when both
port formats exist. That notification triggers graph recalculation during
format negotiation, before the final input buffer and IO assignment. Its Start
readiness check also requires buffers and IO. The already prepared downstream
link makes the view runnable during that intermediate state.

A passive FITS-to-view input link followed by the active view-to-sink link was
tried at `/home/dgamroth/.cache/rtc-classic-spa-sender7-r6-20260930`; final link
creation failed immediately (exit 255), also with zero packets. That candidate
has no successful evidence. Required validation after remediation is the same
exact-byte, ordered-frame, complete-packet source capture, followed by the
shared sender comparison against all five unchanged receiver paths.

The separate generic wrapper candidate now retains `NEED_CONFIGURE` until each
required or configured port has format, buffers, and `SPA_IO_Buffers`; buffer
and IO lifecycle changes publish the updated flags after releasing the callback
gate. The existing connected C video-view test fails before this change and
passes after it. Only its ndarray DSO was installed for investigation; FITS and
HEART DSOs remain unchanged. A later seven-frame source trial still emitted
zero packets, with successful Start calls and running links. Thus the readiness
defect does not account for the whole transport failure.

At `/home/dgamroth/.cache/rtc-classic-spa-sender7-reliable-profile-20260930`, a
functional trial with `node.reliable=true` on the three transport nodes and the
profiler module loaded after protocol-native bound the profiler successfully,
but its JSON output was empty over approximately 10.7 seconds. No graph cycles
were recorded and no UDP packets arrived. Earlier profiler trials loaded the
module before protocol-native and could not bind; those empty outputs provide
no execution evidence. Exact timer/process observation is still required to
distinguish the remaining mechanisms. These diagnostic runs are not timing
qualification.

## Confirmed graph IO interoperability issue

`SPA-SENDER-002` — confirmed local graph interoperability failure, high
confidence. The ordinary SPA contract permits `ENOENT` for unsupported IO.
However, the current host sets local activation `active_driver_id` only after
successful synchronous node IO setup. FITS and the generic video-view wrapper
rejected graph Position. The driver then skipped activation reset for their
unacknowledged driver IDs. This prevented graph processing despite successful
Start calls and active links.

The bounded trace at
`/home/dgamroth/.cache/rtc-classic-spa-sender7-node-trace-r2-20260930` records seven
FITS ready cycles and zero process activations for source, view, and sink.
Syscall observation proves the source timer fires and reads seven FITS planes.
Thus timer inactivity was excluded. Trace instrumentation was applied only to
the private daemon, with binary/source hashes retained in its provenance file.

The owner fixes acknowledge and advertise valid Position IO. The generic
wrapper delegates only nodes that consume Position; other nodes do not retain
the pointer. FITS acknowledges setup/clear without retaining or consuming
Position. Both reject undersized non-null areas with `ENOSPC`; Clock remains
unsupported, and no clock population, cadence, science, HEART, or core changes
were made. The generic readiness candidate also publishes changed readiness
after a failed format callback restores a format but leaves its pool removed.

Using the same seven-frame cube, configuration, installed core, and 100 Hz
settings, the installed plugins captured zero packets at
`/home/dgamroth/.cache/rtc-classic-spa-position-before-seven-20260930`. The private
owner candidates captured exactly 224 packets and ordered frame IDs 0–6 at
`/home/dgamroth/.cache/rtc-classic-spa-position-seven-20260930`. Every fixed header
and UInt16 pixel byte matched; sink errors were zero and daemon exit was zero.
Wire frame intervals were 9.71–10.23 ms. Packet receive gaps and spans remain
characterization observations, including receiver batching; no pacing deadline
or hardware timing limit was qualified.

The reviewed private FITS DSO SHA-256 is
`947ba07a07f5da0e8c60b408455933689e3cc7a7cc1ca8dbf8c358c9ac3f8a41`;
ndarray is `6bdca173a4a4d3dc5ba4e053ce2a42072380e4dcc6bdebf5884f3b254e04045f`.
The unchanged HEART DSO is
`db021461bfb05d41939e0db54e56620c3d7ae38e626763aee59110becd65f784`.
Owner regression evidence includes 20 wrapper and 12 ndarray Rust tests,
connected C readiness coverage, FITS source/factory/cube tests, and failure
before / success after for Position setup and failed-format readiness.

## All-five receiver comparison

The 63-frame source-arithmetic corpus was replayed at 100 Hz with 2,000 µs
readout through the immutable private sender DSOs into every existing Classic
receiver. The primary agent integrated `--sender spa` and
`--sender-spa-directory` into the two live runners. Exact commands, runner
hashes, reports, physical summaries, and compressed raw capture hashes are in
`/home/dgamroth/.cache/rtc-classic-spa-five-paths63-20260930/manifest.json`.

| Receiver | WFS packets | DM commands | Selected arithmetic policy | Process exits |
| --- | ---: | ---: | --- | --- |
| HEART | 2,016 | 63 | pass, including exact source-model bits | normal |
| FGN frame | 2,016 | 63 | pass | normal |
| JFG frame | 2,016 | 63 | pass | normal |
| FGN row | 2,016 | 63 | pass | normal |
| JFG row | 2,016 | 63 | pass | normal |

All captures had zero WFS pixel mismatches, ordered complete WFS IDs 0–62,
and no repeated/decreasing DM IDs. Sender counters were exactly 63 frames and
2,016 datagrams with zero rejection/send errors. The FGN/JFG receiver counters
reported 63 frames, zero rejection/drop/starvation, and 2,016 blocks for row
mode. JFG retained final constraint feedback passed, with maximum errors
1.19 × 10⁻⁷ µm (frame) and 2.38 × 10⁻⁷ µm (row). FGN does not expose that
final-feedback field in these reports. HEART's final clipped-actuator count
was 76, equal to its expected count, and all effective flag readbacks passed.

HEART's broad `report.qualified` remains false: its historical 10⁻⁶ comparison
has 22 failures with maximum 1.31 × 10⁻⁶ µm, and internal zero-state readback is
unavailable. Its selected source-arithmetic bound checks and exact HEART
source model passed, with zero unequal command bits. No science or HEART
change was made to alter these criteria. The first HEART attempt failed before
ingress because the new runner branch referenced an undefined local `cube`;
the primary agent corrected it to `args.cube`, added a harness regression, and
the fresh `heart-r2` result is retained alongside the failed attempt.

This sequence ran alongside functional diagnostics and proves transport and
selected numerical consistency. It does not qualify latency or capacity.

## Clean committed-baseline sender qualification

The generic SDK fixes were narrowly backported onto committed core baseline
`ac82518` without investigative snapshot `a498b10`, latest-hold, leases,
observer, acquisition metadata or latency implementation. The clean branch is
`codex/classic-spa-readiness-clean`, production code/test commit `fefc8f3`.
Its release DSO passed 14 wrapper tests, 5 ndarray tests, the full C regression,
exports, a discriminating video-view readiness comparison, and a reentrant
snapshot negative control. Runtime enumeration returns exactly the baseline
`api.ndarray.frame-assembly` and `api.ndarray.video-view` factories.

A separate frozen private directory
`/home/dgamroth/.cache/rtc-classic-spa-private-clean-plugins-20260930` contains:

- ndarray SHA-256 `153839f352590a992655f327ef892c1dff3595ab9fbe80f183ed2aeb7ec6458c`;
- FITS SHA-256 `947ba07a07f5da0e8c60b408455933689e3cc7a7cc1ca8dbf8c358c9ac3f8a41`;
- symlinks to unchanged installed unrelated plugins, including HEART.

The actual clean pair passed its own seven-frame connected source check:
exactly 224 datagrams, complete IDs 0–6, every header/pixel byte matching, no
sink rejection/send error, and normal exit. It then passed the same five
receiving paths sequentially using the 63-frame corpus, 100 Hz and 2,000 µs
readout. Every path delivered exactly 2,016 WFS packets and 63 DM commands,
ordered complete WFS IDs 0–62, zero payload mismatch, and no repeated/decreasing
DM IDs. Selected source-arithmetic checks and all process exits passed.

Sender and FGN/JFG receiver counters matched the preceding comparison; JFG
final-feedback errors were again 1.19 × 10⁻⁷ µm (frame) and 2.38 × 10⁻⁷ µm
(row), with 74 expected nonzero values. HEART's exact source model had zero
unequal command bits, and final clips were 76/76. Its existing broad legacy
qualification/readback limitations and FGN's unavailable separate feedback
field remain documented. The current JFG harness uses four process roles;
all four returned zero, while HEART/FGN returned three zero process statuses.

Fresh exact commands, harness revision `ebe583f`, script/plugin hashes, reports,
validation and Zstandard capture archive hashes are at
`/home/dgamroth/.cache/rtc-classic-spa-clean-five-paths63-20260930/manifest.json`;
the seven-frame source result is at
`/home/dgamroth/.cache/rtc-classic-spa-clean-source7-20260930`.
Historical failed attempts and the earlier three-factory binary remain
preserved separately. The clean pair, rather than the earlier binary's result,
now establishes the clean backport's functional transport gate. No latency,
capacity, hardware, deployment, main update or push is claimed. Existing local
SDK changes and deployed factory-set intent remain unchanged.
