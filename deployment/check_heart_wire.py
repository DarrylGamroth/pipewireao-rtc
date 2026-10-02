#!/usr/bin/env python3
"""Compare captured local HEART HIL UDP payloads with retained plant exchanges.

Input TSV columns are frame.time_epoch, udp.dstport, udp.payload from tshark.
This checks the selected native-order raw-pixel and single-packet DM profiles;
it does not establish physical mirror units or a network generation fence.
"""
from __future__ import annotations

import argparse
from decimal import Decimal
import hashlib
import json
from pathlib import Path
import struct

WFS_HEADER = struct.Struct("<4B8HIQII")
DM_HEADER = struct.Struct("<4BHHQII")


def validate(packets: Path, evidence: Path) -> dict:
    result = json.loads((evidence / "result.json").read_text())
    assert result["passed"], "finite deployment check must pass first"
    reports = [result["checks"][f"batch-{index}"] for index in (1, 2)]
    provenance = json.loads((Path(result["deployment"]).parent / "provenance.json").read_text())
    roi = provenance["heart"]["detector_roi"]
    packet_rows = provenance["heart"]["packet_rows"]
    height, width = reports[0]["frame"]["shape"]
    frames = []
    commands = []
    out_of_exchange_commands = []
    intervals = [result["checks"]["reset_interval_realtime_ns"], [
        result["checks"]["shutdown_begin_realtime_ns"], result["checks"]["shutdown_end_realtime_ns"]]]
    active = None
    awaiting_command = None
    for line in packets.read_text().splitlines():
        timestamp, port, encoded = line.split("\t")
        payload = bytes.fromhex(encoded.replace(":", ""))
        if port == "6000":
            (source, kind, bits, network, length, pixels, columns, rows,
             col_origin, row_origin, sequence, count, position, clock, frame,
             checksum) = WFS_HEADER.unpack_from(payload)
            assert (source, kind, bits, network) == (0, 1, 16, 0)
            assert (columns, rows, col_origin, row_origin) == (width, packet_rows, roi["column"], roi["row"])
            assert count == (height + packet_rows - 1) // packet_rows
            assert len(payload) == WFS_HEADER.size + length == WFS_HEADER.size + pixels * 2
            if sequence == 1:
                assert active is None and position == 0
                active = {"id": frame, "count": count, "clock": clock,
                          "payload": bytearray(), "next": 1}
            assert active is not None
            assert (frame, count, clock, sequence, position) == (
                active["id"], active["count"], active["clock"],
                active["next"], len(active["payload"]) // 2)
            active["payload"].extend(payload[WFS_HEADER.size:])
            active["next"] += 1
            if sequence == count:
                assert awaiting_command is None, "another frame arrived before its command"
                frames.append((frame, bytes(active["payload"])))
                awaiting_command = frame
                active = None
        elif port == "6100":
            target, network, sequence, count, offset, actuators, clock, frame, checksum = DM_HEADER.unpack_from(payload)
            assert (target, network, sequence, count, offset, actuators) == (0, 0, 1, 1, 0, 277)
            assert len(payload) == DM_HEADER.size + 277 * 4
            xor = 0
            for (word,) in struct.iter_unpack("<I", payload):
                xor ^= word
            assert xor == 0, "invalid DM wire checksum"
            values = [value for (value,) in struct.iter_unpack("<f", payload[DM_HEADER.size:])]
            # Match the SPA codec: multiply in Float64 and round once to Float32.
            metres = b"".join(struct.pack("<f", value * 1e-6) for value in values)
            if awaiting_command is None:
                capture_ns = int(Decimal(timestamp) * 1_000_000_000)
                assert any(start <= capture_ns <= end for start, end in intervals), \
                    "unsolicited command outside stopped reset/shutdown"
                assert commands and (frame, metres) == commands[-1], \
                    "out-of-exchange command differs from the previously accepted command"
                out_of_exchange_commands.append({"capture_realtime_ns": capture_ns, "id": frame,
                                                   "payload_equals_last_accepted": True})
            else:
                assert frame == awaiting_command, "command does not match outstanding wire frame"
                commands.append((frame, metres))
                awaiting_command = None
        else:
            raise AssertionError(f"unexpected UDP destination {port}")
    assert active is None, "incomplete WFS frame"
    assert awaiting_command is None, "missing command for final wire frame"
    expected_ids = []
    expected_frames = bytearray()
    expected_commands = bytearray()
    for index, report in enumerate(reports, 1):
        expected_ids.extend(report["sequences"])
        batch = evidence / f"batch-{index}"
        expected_frames.extend((batch / Path(report["frame"]["file"]).name).read_bytes())
        expected_commands.extend((batch / Path(report["command"]["file"]).name).read_bytes())
    assert [frame for frame, _ in frames] == expected_ids, "WFS IDs differ from retained plant exchanges"
    assert [frame for frame, _ in commands] == expected_ids, "DM IDs differ from retained plant exchanges"
    assert b"".join(payload for _, payload in frames) == expected_frames, "wire pixels differ from AOS ADC output"
    assert b"".join(payload for _, payload in commands) == expected_commands, "wire commands differ from plant input after one unit conversion"
    return {"passed": True, "wfs_frames": len(frames), "dm_commands": len(commands),
            "wire_micrometre_to_plant_metre_conversion": "exact Float32 match",
            "actuator_order": "all 277 coordinates match without permutation",
            "detector_shape": [height, width], "detector_roi": roi,
            "out_of_exchange_commands": out_of_exchange_commands,
            "packet_fields_sha256": hashlib.sha256(packets.read_bytes()).hexdigest(),
            "physical_opd_displacement_convention": "unqualified",
            "network_generation_fence": "not provided by stdDM"}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--packets", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.write_text(json.dumps(validate(args.packets, args.evidence), indent=2) + "\n")
