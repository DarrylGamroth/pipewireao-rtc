"""Offline payload/sequence regression for the selected HEART bridge profile."""
import json
from pathlib import Path
import struct
import tempfile
import unittest

import check_heart_wire as wire


class WireTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        checks = {}
        self.lines = []
        for batch in (1, 2):
            pixels = struct.pack("<4H", batch, 2, 3, 4)
            microns = [batch * 0.125] * 277
            metres = b"".join(struct.pack("<f", value * 1e-6) for value in microns)
            directory = self.root / f"batch-{batch}"
            directory.mkdir()
            (directory / "frames").write_bytes(pixels)
            (directory / "commands").write_bytes(metres)
            checks[f"batch-{batch}"] = {"sequences": [1], "frame": {"file": "frames", "shape": [2, 2]},
                                        "command": {"file": "commands"}}
            for segment in (1, 2):
                packet = wire.WFS_HEADER.pack(0, 1, 16, 0, 4, 2, 2, 1, 0, 0,
                                              segment, 2, (segment - 1) * 2, batch, 1, 0)
                packet += pixels[(segment - 1) * 4:segment * 4]
                self.lines.append(f"{batch}.0\t6000\t{packet.hex()}")
            packet = bytearray(wire.DM_HEADER.pack(0, 0, 1, 1, 0, 277, batch, 1, 0))
            packet.extend(struct.pack("<277f", *microns))
            checksum = 0
            for (word,) in struct.iter_unpack("<I", packet):
                checksum ^= word
            struct.pack_into("<I", packet, 20, checksum)
            self.lines.append(f"{batch}.1\t6100\t{packet.hex()}")
        checks.update(reset_interval_realtime_ns=[1_500_000_000, 1_900_000_000],
                      shutdown_begin_realtime_ns=2_500_000_000, shutdown_end_realtime_ns=2_900_000_000)
        (self.root / "result.json").write_text(json.dumps({"passed": True, "checks": checks,
                                                         "deployment": str(self.root / "deployment.conf")}))
        (self.root / "provenance.json").write_text(json.dumps({"heart": {
            "packet_rows": 1, "detector_roi": {"row": 0, "column": 0}}}))
        self.packets = self.root / "packets.tsv"

    def write(self):
        self.packets.write_text("\n".join(self.lines) + "\n")

    def test_reset_ids_payload_order_and_exact_single_conversion(self):
        self.write()
        result = wire.validate(self.packets, self.root)
        self.assertTrue(result["passed"])
        self.assertEqual((result["wfs_frames"], result["dm_commands"]), (2, 2))

    def test_missing_fragment_and_extra_command_fail(self):
        original = list(self.lines)
        for lines in (original[1:], original + [original[-1]]):
            self.lines = lines
            self.write()
            with self.assertRaises(AssertionError):
                wire.validate(self.packets, self.root)

    def test_corrupt_wire_pixel_and_dm_checksum_fail(self):
        original = list(self.lines)
        for index in (0, 2):
            self.lines = list(original)
            fields = self.lines[index].split("\t")
            packet = bytearray.fromhex(fields[2])
            packet[-1] ^= 1
            fields[2] = packet.hex()
            self.lines[index] = "\t".join(fields)
            self.write()
            with self.assertRaises(AssertionError):
                wire.validate(self.packets, self.root)

    def test_detector_roi_header_mismatch_fails(self):
        fields = self.lines[0].split("\t")
        packet = bytearray.fromhex(fields[2])
        struct.pack_into("<H", packet, 14, 844)
        fields[2] = packet.hex()
        self.lines[0] = "\t".join(fields)
        self.write()
        with self.assertRaises(AssertionError):
            wire.validate(self.packets, self.root)

    def test_held_command_resend_requires_exact_payload_and_lifecycle_window(self):
        duplicate = self.lines[-1].split("\t")
        duplicate[0] = "2.6"
        self.lines.append("\t".join(duplicate))
        self.write()
        result = wire.validate(self.packets, self.root)
        self.assertEqual(len(result["out_of_exchange_commands"]), 1)
        self.assertTrue(result["out_of_exchange_commands"][0]["payload_equals_last_accepted"])
        # The same exact duplicate during normal running must be rejected.
        duplicate[0] = "2.2"
        self.lines[-1] = "\t".join(duplicate)
        self.write()
        with self.assertRaises(AssertionError):
            wire.validate(self.packets, self.root)

    def test_changed_resend_with_valid_checksum_is_rejected_in_shutdown_window(self):
        fields = self.lines[-1].split("\t")
        fields[0] = "2.6"
        packet = bytearray.fromhex(fields[2])
        struct.pack_into("<f", packet, wire.DM_HEADER.size, 0.5)
        struct.pack_into("<I", packet, 20, 0)
        checksum = 0
        for (word,) in struct.iter_unpack("<I", packet):
            checksum ^= word
        struct.pack_into("<I", packet, 20, checksum)
        fields[2] = packet.hex()
        self.lines.append("\t".join(fields))
        self.write()
        with self.assertRaisesRegex(AssertionError, "differs from the previously accepted"):
            wire.validate(self.packets, self.root)
