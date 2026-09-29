"""Focused tests for extracting a frame range from a FITS cube."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("fits_segment.py")
SPEC = importlib.util.spec_from_file_location("fits_segment", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
SEGMENT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SEGMENT)


def _card(name: str, value: str) -> bytes:
    return f"{name:<8}= {value:>20}".ljust(80).encode("ascii")


def _fits_cube(width: int = 2, height: int = 2, frames: int = 3) -> tuple[bytes, bytes]:
    cards = [
        _card("SIMPLE", "T"),
        _card("BITPIX", "16"),
        _card("NAXIS", "3"),
        _card("NAXIS1", str(width)),
        _card("NAXIS2", str(height)),
        _card("NAXIS3", str(frames)),
        _card("OBJECT", "'synthetic cube'"),
        _card("CHECKSUM", "'old-checksum'"),
        _card("DATASUM", "'old-datasum'"),
        b"END".ljust(80),
    ]
    header = b"".join(cards).ljust(2880)
    payload = bytes(range(width * height * frames * 2))
    padded = payload + b"\0" * (-len(payload) % 2880)
    return header + padded, payload


class FitsSegmentTests(unittest.TestCase):
    def test_writes_selected_frames_and_updates_header(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source.fits"
            destination = root / "segment.fits"
            content, payload = _fits_cube()
            source.write_bytes(content)

            SEGMENT.write_fits_segment(source, destination, start=1, count=2)

            result = destination.read_bytes()
            cards = [result[index:index + 80] for index in range(0, 2880, 80)]
            self.assertTrue(any(b"'synthetic cube'" in card for card in cards))
            self.assertTrue(any(card.startswith(b"NAXIS3  =                    2") for card in cards))
            self.assertTrue(any(card.startswith(b"HISTORY Benchmark segment") for card in cards))
            self.assertTrue(any(card.startswith(b"HISTORY Segment frames") for card in cards))
            self.assertFalse(any(card.startswith((b"CHECKSUM", b"DATASUM ")) for card in cards))
            selected = payload[8:24]
            self.assertEqual(result[2880:2880 + len(selected)], selected)
            self.assertEqual(len(result), 5760)
            self.assertEqual(result[2880 + len(selected):], b"\0" * (2880 - len(selected)))
            with self.assertRaises(FileExistsError):
                SEGMENT.write_fits_segment(source, destination, start=0, count=1)

    def test_rejects_invalid_segment_and_extra_hdu(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source.fits"
            content, _ = _fits_cube()
            source.write_bytes(content)
            with self.assertRaisesRegex(ValueError, "outside"):
                SEGMENT.write_fits_segment(source, root / "bad.fits", start=2, count=2)
            with self.assertRaisesRegex(ValueError, "start"):
                SEGMENT.write_fits_segment(source, root / "bad-start.fits", start=-1, count=1)
            source.write_bytes(content + b"\0" * 2880)
            with self.assertRaisesRegex(ValueError, "another HDU"):
                SEGMENT.write_fits_segment(source, root / "extra.fits", start=0, count=1)


if __name__ == "__main__":
    unittest.main()
