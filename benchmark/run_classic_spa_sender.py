#!/usr/bin/env python3
"""Finite Classic FITS -> installed SPA stdWfs replay, with optional UDP capture."""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import struct
import sys
import threading
import time

from fits_segment import write_fits_segment
from run_classic_live import WORKSPACE, load_script

WIDTH = HEIGHT = 352
ROWS = 11
PACKETS = HEIGHT // ROWS
HEADER = struct.Struct("<4B8HIQII")
REMOTE = "classic-spa-sender"
SOURCE = "classic-fits-source"
VIEW = "classic-fits-video-view"
SINK = "classic-heart-wfs-sink"


def primary_header(cube: Path) -> tuple[dict[str, str], int]:
    values = {}
    size = 0
    with cube.open("rb") as stream:
        while True:
            block = stream.read(2880)
            if len(block) != 2880:
                raise ValueError("incomplete FITS primary header")
            size += len(block)
            for offset in range(0, 2880, 80):
                card = block[offset:offset + 80].decode("ascii")
                if card[:8].strip() == "END":
                    return values, size
                if card[8:10] == "= ":
                    name = card[:8].strip()
                    if name in values:
                        raise ValueError(f"duplicate FITS card: {name}")
                    values[name] = card[10:].split("/", 1)[0].strip()


def validate_settings(cube: Path, frames: int, rate_hz: int, readout_us: int,
                      rows_per_packet: int = ROWS) -> int:
    values, _ = primary_header(cube)
    required = {"BITPIX": "16", "NAXIS": "3", "NAXIS1": str(WIDTH),
                "NAXIS2": str(HEIGHT), "BSCALE": "1", "BZERO": "32768"}
    if any(values.get(key) != value for key, value in required.items()):
        raise ValueError("sender requires the Classic 352x352 UInt16 FITS cube")
    available = int(values["NAXIS3"])
    if not 1 <= frames <= available:
        raise ValueError("requested frames exceed the FITS cube")
    if rows_per_packet != ROWS:
        raise ValueError("Classic replay requires 11 rows and 32 packets per frame")
    if rate_hz < 1 or readout_us < 1 or readout_us * rate_hz >= 950000:
        raise ValueError("readout must be positive and below 95% of frame period")
    return available


def sender_config(cube: Path, rate_hz: int, readout_us: int,
                  destination: str = "127.0.0.1", port: int = 6000) -> str:
    ipaddress.IPv4Address(destination)
    if not 1 <= port <= 65535:
        raise ValueError("UDP port must be in 1..65535")
    # JSON strings are also valid relaxed SPA-JSON strings.
    return f'''context.properties = {{
    core.daemon = true core.name = {REMOTE} library.use-fallback = false
    default.clock.min-quantum = 1 default.clock.quantum-floor = 1
}}
context.spa-libs = {{
    support.* = support/libspa-support
    api.fits.source = fits/libspa-fits
    api.ndarray.video-view = ndarray/libspa-ndarray
    api.heart.std-wfs.sink = heart/libspa-heart
}}
context.modules = [
    {{ name = libpipewire-module-scheduler-v1 }}
    {{ name = libpipewire-module-protocol-native }}
    {{ name = libpipewire-module-spa-node-factory }}
    {{ name = libpipewire-module-client-node }}
    {{ name = libpipewire-module-link-factory args = {{ allow.link.passive = true }} }}
    {{ name = libpipewire-module-metadata }}
    {{ name = libpipewire-module-access }}
]
context.objects = [
    {{ factory = spa-node-factory args = {{
        factory.name = support.node.driver node.name = Classic-SPA-Dummy-Driver
        node.group = classic-spa-dummy node.sync-group = sync.classic-spa-dummy
        priority.driver = 200000
    }} }}
    {{ factory = spa-node-factory args = {{
        factory.name = api.fits.source node.name = {SOURCE}
        node.virtual = true object.linger = true priority.driver = 300000
        api.fits.path = {json.dumps(str(cube))}
        api.fits.hdu = 1 api.fits.sample-rank = 2 api.fits.rate = {rate_hz}/1
        api.fits.schema = org.heart.std-wfs.raw-pixels/1
        api.fits.io-mode = file api.fits.prefault = false api.fits.loop = false
        api.fits.readiness = timerfd api.fits.output-mode = frame
    }} }}
    {{ factory = spa-node-factory args = {{
        factory.name = api.ndarray.video-view node.name = {VIEW}
        node.virtual = true object.linger = true
        api.ndarray.frame-size = 352x352 api.ndarray.frame-rate = {rate_hz}/1
        api.ndarray.schema = org.heart.std-wfs.raw-pixels/1
        api.ndarray.video-format = GRAY16_LE
    }} }}
    {{ factory = spa-node-factory args = {{
        factory.name = api.heart.std-wfs.sink node.name = {SINK}
        node.cache-params = false
        node.virtual = true object.linger = true
        api.heart.std-wfs.destination-address = {destination}
        api.heart.std-wfs.port = {port} api.heart.std-wfs.source = 0
        api.heart.std-wfs.pixel-type = raw
        api.heart.std-wfs.width = 352 api.heart.std-wfs.height = 352
        api.heart.std-wfs.frame-rate = {rate_hz}/1
        api.heart.std-wfs.network-byte-order = false
        api.heart.std-wfs.pixels-per-datagram = {ROWS * WIDTH}
        api.heart.std-wfs.rows-per-datagram = true
        api.heart.std-wfs.readout-time = {readout_us}
        api.heart.std-wfs.checksum = none
    }} }}
]
'''


def sink_counters(text: str) -> dict:
    values = [int(value) for value in re.findall(r"\bLong\s+(-?\d+)", text)]
    if len(values) != 4:
        raise ValueError("sink Props must contain four ordered Long counters")
    return dict(zip(("frames_sent", "frames_rejected", "datagrams_sent", "send_errors"), values))


def run_sender(*, helper, installation, directory: Path, cube: Path, frames: int,
               rate_hz: int = 10, readout_us: int = 2000,
               rows_per_packet: int = ROWS, source_cpus: str | None = None,
               destination: str = "127.0.0.1", port: int = 6000) -> dict:
    """Block until finite replay completes; raises on sink count/error failure.

    Caller starts its receiver/capture before this call. This owns an isolated
    source daemon; no receiver or scientific graph is created or modified.
    ``directory`` must be new and survives as provenance and diagnostic output.
    """
    cube = cube.resolve()
    available = validate_settings(cube, frames, rate_hz, readout_us, rows_per_packet)
    directory = directory.resolve()
    if directory.exists():
        raise ValueError(f"sender output already exists: {directory}")
    directory.mkdir(parents=True)
    replay_cube = cube
    if frames != available:
        replay_cube = directory / "input.fits"
        write_fits_segment(cube, replay_cube, 0, frames)
    config_dir = directory / "config"
    config_dir.mkdir()
    shutil.copy2(installation.client_conf, config_dir / "client.conf")
    config = config_dir / "sender.conf"
    config.write_text(sender_config(replay_cube, rate_hz, readout_us, destination, port))
    runtime = Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")) / f"cs-{os.getpid()}"
    runtime.mkdir()
    env = os.environ.copy()
    env.update({"XDG_RUNTIME_DIR": str(runtime), "PIPEWIREAO_RUNTIME_DIR": str(runtime),
                "PIPEWIREAO_CONFIG_DIR": str(config_dir),
                "PIPEWIREAO_MODULE_DIR": str(installation.module_directory),
                "PIPEWIREAO_SPA_PLUGIN_DIR": str(installation.spa_library_directory),
                "PIPEWIRE_REMOTE": REMOTE, "PIPEWIREAO_DEBUG": "0",
                "LD_LIBRARY_PATH": str(installation.library_directory) + ":" + env.get("LD_LIBRARY_PATH", "")})
    plugins = [installation.spa_library_directory / relative for relative in
               ("fits/libspa-fits.so", "ndarray/libspa-ndarray.so", "heart/libspa-heart.so")]
    report = {"transport": "FITS -> SPA video-view -> SPA HEART stdWfs sink -> UDP",
              "frames": frames, "rate_hz": rate_hz, "readout_us": readout_us,
              "rows_per_packet": ROWS, "packets_per_frame": PACKETS,
              "cube": str(cube), "replay_cube": str(replay_cube),
              "source_cpus": source_cpus, "qualified": False, "errors": [],
              "sha256": {str(path): helper.sha256_file(path) for path in [cube, replay_cube, config, *plugins]},
              "scope": "finite source transport; no RTC numerical or capacity claim"}
    daemon = stream = None
    try:
        argv = helper.placed([str(installation.daemon), "-c", config.name], source_cpus)
        report["source_command"] = argv
        daemon, stream = helper.start(argv, env, directory / "daemon.log", cwd=installation.working_directory)
        def ready():
            if daemon.poll() is not None:
                raise RuntimeError(f"source daemon exited: {daemon.returncode}")
            return (runtime / REMOTE).exists()
        helper.wait_for("sender private socket", ready)
        # Build downstream first; creating the source link admits the first frame.
        for output, input_ in ((f"{VIEW}:output_1", f"{SINK}:frame"),
                               (f"{SOURCE}:output", f"{VIEW}:input_1")):
            helper.command([str(installation.tool("pwao-link")), "-r", REMOTE,
                            "-w", "-L", output, input_], env)
        snapshot = helper.command([str(installation.tool("pwao-dump")), "-r", REMOTE], env)
        (directory / "graph.json").write_text(snapshot)
        nodes = json.loads(snapshot)
        ids = {node.get("info", {}).get("props", {}).get("node.name"): node["id"] for node in nodes}
        sink_id = ids[SINK]
        deadline = time.monotonic() + frames / rate_hz + 10
        while True:
            if daemon.poll() is not None:
                raise RuntimeError(f"source daemon exited: {daemon.returncode}")
            props = helper.command([str(installation.tool("pwao-cli")), "-r", REMOTE,
                                    "enum-params", str(sink_id), "Props"], env)
            counters = sink_counters(props)
            if counters["frames_rejected"] or counters["send_errors"]:
                raise RuntimeError(f"sender rejected input or failed UDP transmission: {counters}")
            if counters["frames_sent"] >= frames:
                break
            if time.monotonic() >= deadline:
                raise RuntimeError(f"sender timed out: {counters}")
            time.sleep(0.02)
        (directory / "sink-props.txt").write_text(props)
        report["sink_counters"] = counters
        if counters != {"frames_sent": frames, "frames_rejected": 0,
                        "datagrams_sent": frames * PACKETS, "send_errors": 0}:
            raise RuntimeError(f"sender counters differ from finite replay: {counters}")
        report["qualified"] = True
    except Exception as error:
        report["errors"].append(str(error))
        raise
    finally:
        primary_error = sys.exception()
        report["cleanup"] = {"daemon": "not_started", "runtime": "pending"}
        if daemon is not None:
            try:
                if daemon.poll() is None:
                    daemon.send_signal(signal.SIGTERM)
                helper.stop(daemon, stream)
                report["cleanup"]["daemon"] = "stopped"
            except Exception as error:
                report["cleanup"]["daemon"] = "failed"
                report["qualified"] = False
                report["errors"].append(f"sender daemon cleanup failed: {error}")
            finally:
                report["process_returncode"] = daemon.returncode
                if daemon.returncode != 0:
                    report["qualified"] = False
                    report["errors"].append(f"sender daemon return code: {daemon.returncode}")
        try:
            shutil.rmtree(runtime)
            report["cleanup"]["runtime"] = "removed"
        except Exception as error:
            report["cleanup"]["runtime"] = "failed"
            report["qualified"] = False
            report["errors"].append(f"sender runtime cleanup failed: {error}")
        try:
            (directory / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        except Exception as error:
            if primary_error is None:
                raise
            print(f"sender report failed after replay failure: {error}", file=sys.stderr)
    if not report["qualified"]:
        raise RuntimeError("sender cleanup failed; see report.json")
    return report


def qualify_packets(cube: Path, records: list[tuple[float, bytes]], frames: int,
                    rate_hz: int, readout_us: int) -> dict:
    """Check exact native-order Classic wire payloads and retain observed pacing."""
    import numpy as np
    _, offset = primary_header(cube)
    with cube.open("rb") as stream:
        stream.seek(offset)
        signed = np.frombuffer(stream.read(frames * WIDTH * HEIGHT * 2), dtype=">i2")
    expected = (signed.astype(np.int32) + 32768).astype("<u2").tobytes()
    errors = []
    if len(records) != frames * PACKETS:
        errors.append(f"expected {frames * PACKETS} packets, received {len(records)}")
    by_frame = {}
    for index, (received_at, packet) in enumerate(records):
        if len(packet) != HEADER.size + ROWS * WIDTH * 2:
            errors.append(f"packet {index}: invalid length")
            continue
        fields = HEADER.unpack_from(packet)
        source, pixel_type, bits, network, size, pixels, columns, rows, roi_x, roi_y, seq, count, raster, stamp, frame, checksum = fields
        expected_frame, expected_seq = divmod(index, PACKETS)
        expected_seq += 1
        if (source, pixel_type, bits, network, size, pixels, columns, rows,
                roi_x, roi_y, seq, count, raster, frame, checksum) != (
                0, 1, 16, 0, ROWS * WIDTH * 2, ROWS * WIDTH, WIDTH, ROWS,
                0, 0, expected_seq, PACKETS, (expected_seq - 1) * ROWS * WIDTH,
                expected_frame, 0):
            errors.append(f"packet {index}: wire header or order mismatch")
        start = (frame * WIDTH * HEIGHT + raster) * 2
        if packet[HEADER.size:] != expected[start:start + ROWS * WIDTH * 2]:
            errors.append(f"packet {index}: pixel payload differs from FITS")
        by_frame.setdefault(frame, []).append((received_at, stamp))
    starts, wire_starts, spans, gaps = [], [], [], []
    for frame, packets in by_frame.items():
        if len(packets) != PACKETS:
            errors.append(f"frame {frame}: incomplete")
        if len({stamp for _, stamp in packets}) != 1:
            errors.append(f"frame {frame}: inconsistent wire timestamps")
        starts.append(packets[0][0])
        wire_starts.append(packets[0][1])
        spans.append((packets[-1][0] - packets[0][0]) * 1e6)
        gaps.extend((b[0] - a[0]) * 1e6 for a, b in zip(packets, packets[1:]))
    return {"qualified": not errors, "errors": errors, "packet_count": len(records),
            "frame_ids": list(by_frame), "nominal_packet_interval_us": readout_us / PACKETS,
            "nominal_first_to_terminal_us": readout_us * (PACKETS - 1) / PACKETS,
            "observed_first_to_terminal_us": spans, "observed_packet_gaps_us": gaps,
            "nominal_frame_interval_us": 1e6 / rate_hz,
            "observed_frame_intervals_us": [(b - a) * 1e6 for a, b in zip(starts, starts[1:])],
            "wire_frame_intervals_us": [(b - a) / 1000 for a, b in zip(wire_starts, wire_starts[1:])],
            "pacing_note": "receive timestamps characterize scheduler and UDP jitter; no percentile or deadline claim"}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cube", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--frames", type=int, default=7)
    parser.add_argument("--rate-hz", type=int, default=10)
    parser.add_argument("--readout-us", type=int, default=2000)
    parser.add_argument("--source-cpus")
    parser.add_argument("--port", type=int, default=6000)
    parser.add_argument("--pipewire-prefix", type=Path, default=Path("/opt/pipewireao"))
    parser.add_argument("--fgn-root", type=Path, default=WORKSPACE / "calculon-algorithms-progressive-requal")
    parser.add_argument("--qualify-udp", action="store_true", help="bind local receiver before replay; requires exclusive port")
    args = parser.parse_args(argv)
    sys.path.insert(0, str(args.fgn_root / "scripts"))
    helper = load_script("classic_spa_transport", args.fgn_root / "scripts/run_fgn_copper_fullframe_live.py")
    installation = helper.pipewire_installation(None, args.pipewire_prefix)
    records = []
    receiver = None
    thread = None
    stopping = threading.Event()
    if args.qualify_udp:
        receiver = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        receiver.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4194304)
        receiver.bind(("127.0.0.1", args.port))
        receiver.settimeout(0.1)
        def capture():
            while not stopping.is_set():
                try:
                    packet, _ = receiver.recvfrom(65535)
                    records.append((time.time(), packet))
                except socket.timeout:
                    pass
        thread = threading.Thread(target=capture)
        thread.start()
    failure = None
    try:
        report = run_sender(helper=helper, installation=installation,
                            directory=args.output, cube=args.cube, frames=args.frames,
                            rate_hz=args.rate_hz, readout_us=args.readout_us,
                            source_cpus=args.source_cpus, port=args.port)
    except Exception as error:
        failure = error
        report = None
    finally:
        if thread:
            stopping.set()
            thread.join()
            receiver.close()
    if args.qualify_udp:
        summary = qualify_packets(args.cube, records, args.frames, args.rate_hz, args.readout_us)
        (args.output / "wfs-packets.tsv").write_text("".join(
            f"{stamp:.9f}\t{len(packet) + 8}\t{packet.hex()}\n" for stamp, packet in records))
        (args.output / "udp-summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        if failure is not None:
            raise failure
        if not summary["qualified"]:
            raise RuntimeError("UDP qualification failed; see udp-summary.json")
        report["udp_qualification"] = summary
        (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    if failure is not None:
        raise failure
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
