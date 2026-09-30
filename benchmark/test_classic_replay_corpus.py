"""Focused tests for the bounded Classic replay corpus."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest

import numpy as np


SPEC = importlib.util.spec_from_file_location(
    "classic_replay_corpus", Path(__file__).with_name("classic_replay_corpus.py"))
assert SPEC and SPEC.loader
CORPUS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CORPUS)


def card(name: str, value: int | str) -> bytes:
    return f"{name:<8}= {str(value):>20}".encode("ascii").ljust(80)


class CorpusTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.fixture = self.root / "fixture"
        self.fixture.mkdir()
        self.source = self.root / "source.fits"
        self.output = self.root / "corpus"
        self.pixels = np.arange(352 * 352 * 7, dtype=np.uint32).astype("<u2")
        self.pixels.tofile(self.fixture / "raw-frames.u16le")
        self._write_fits()
        (self.fixture / "prepared-profile.toml").write_text(
            "[detector]\nframe_count = 7\nwidth = 352\nheight = 352\n"
            "[deformable_mirror]\ncontrolled_vdm_size = 221\n"
            "full_vdm_size = 277\npdm_size = 277\n"
            "[clwc]\nloop_gain = -0.3\npole = 0.99\nanti_windup_gain = 0.99\n"
            "[pdm_limits]\nlower = [" + ", ".join(["-0.8"] * 277) + "]\n"
            "upper = [" + ", ".join(["0.8"] * 277) + "]\n",
            encoding="utf-8")
        (self.fixture / "scalars.f32le").write_bytes(
            struct.pack("<5f", -0.3, 0.99, 0.99, -0.8, 0.8))
        for initial, continued, width, *_ in CORPUS.ORACLES:
            values = (np.linspace(-0.1, 0.1, 7 * width, dtype="<f4")
                      if initial == "demanded_pdm_command.f32le"
                      else np.arange(7 * width, dtype="<f4"))
            values.tofile(self.fixture / initial)
            (np.arange(1024 * width, dtype="<f4") + 10000).tofile(self.fixture / continued)
        feedback = np.arange(1024 * 221, dtype="<f4") + 20000
        feedback.tofile(self.fixture / CORPUS.FEEDBACK)

    def _write_fits(self, *, bzero: int = 32768, truncate: bool = False,
                    extra: bytes = b"") -> None:
        cards = [card("SIMPLE", "T"), card("BITPIX", 16), card("NAXIS", 3),
                 card("NAXIS1", 352), card("NAXIS2", 352), card("NAXIS3", 7),
                 card("BSCALE", 1), card("BZERO", bzero), card("CHECKSUM", "'stale'")]
        # An END card in the second header block exercises full-block parsing.
        header = b"".join(cards) + b" " * (CORPUS.BLOCK - len(cards) * 80)
        header += b"HISTORY fixture".ljust(80) + b"END".ljust(80)
        header = header.ljust(2 * CORPUS.BLOCK, b" ")
        signed = (self.pixels.astype(np.int32) - 32768).astype(">i2").tobytes()
        body = signed + b"\0" * (-len(signed) % CORPUS.BLOCK)
        self.source.write_bytes(header + (body[:-1] if truncate else body) + extra)

    def test_repeats_pixels_and_captured_state_order(self) -> None:
        manifest = CORPUS.create_corpus(self.source, self.fixture, self.output)
        self.assertEqual(manifest["frames"], 28)
        self.assertEqual(manifest["cube"]["shape"], [28, 352, 352])
        header, cards, raw = CORPUS.read_cube(self.output / "input.fits", 28)
        self.assertEqual(CORPUS._card_number(cards, b"NAXIS3"), 28)
        self.assertEqual(CORPUS._card_number(cards, b"BZERO"), 32768)
        self.assertEqual(CORPUS._card_number(cards, b"BSCALE"), 1)
        self.assertEqual(raw, CORPUS.read_cube(self.source)[2] * 4)
        self.assertNotIn(b"CHECKSUM=", header)
        for initial, continued, width, *_ in CORPUS.ORACLES:
            actual = (self.output / initial).read_bytes()
            expected = (self.fixture / initial).read_bytes() + \
                (self.fixture / continued).read_bytes()[:21 * width * 4]
            self.assertEqual(actual, expected)
        feedback = (self.output / "controller-constraint-feedback.f32le").read_bytes()
        self.assertEqual(feedback[:7 * 221 * 4], bytes(7 * 221 * 4))
        self.assertEqual(feedback[7 * 221 * 4:],
                         (self.fixture / CORPUS.FEEDBACK).read_bytes()[:21 * 221 * 4])
        self.assertEqual(CORPUS.validate_replay_corpus(
            self.output, self.fixture, self.output / "input.fits", 28), manifest)

    def test_one_repetition_has_initial_reference_only(self) -> None:
        result = CORPUS.create_corpus(self.source, self.fixture, self.output, 1)
        self.assertEqual(result["frames"], 7)
        self.assertEqual((self.output / "demanded_pdm_command.f32le").read_bytes(),
                         (self.fixture / "demanded_pdm_command.f32le").read_bytes())
        self.assertEqual(result["nonzero_controller_feedback_frames"], 0)

    def test_rejects_malformed_fits_and_pixel_mismatch(self) -> None:
        for change in ("bad_scaling", "truncated", "extra_hdu", "wrong_pixel"):
            with self.subTest(change=change):
                if change == "bad_scaling":
                    self._write_fits(bzero=0)
                elif change == "truncated":
                    self._write_fits(truncate=True)
                elif change == "extra_hdu":
                    self._write_fits(extra=bytes(CORPUS.BLOCK))
                else:
                    self._write_fits()
                    raw = bytearray((self.fixture / "raw-frames.u16le").read_bytes())
                    raw[0] ^= 1
                    (self.fixture / "raw-frames.u16le").write_bytes(raw)
                with self.assertRaises(ValueError):
                    CORPUS.create_corpus(self.source, self.fixture, self.output)
                self.assertFalse(self.output.exists())

    def test_largest_corpus_retains_captured_reference_limit(self) -> None:
        manifest = CORPUS.create_corpus(self.source, self.fixture, self.output, CORPUS.MAX_REPETITIONS)
        self.assertEqual(manifest['frames'], 1029)
        self.assertEqual((self.output / 'demanded_pdm_command.f32le').stat().st_size, 1029 * 277 * 4)
        self.assertEqual(CORPUS.validate_replay_corpus(self.output, self.fixture, self.output / 'input.fits', 1029), manifest)

    def test_rejects_bad_repetitions_and_reference_extent_or_finiteness(self) -> None:
        for value in (0, CORPUS.MAX_REPETITIONS + 1, 1.5, True):
            with self.subTest(value=value), self.assertRaises(ValueError):
                CORPUS.create_corpus(self.source, self.fixture, self.output, value)
        reference = self.fixture / "feedback-vdm-command.f32le"
        reference.write_bytes(reference.read_bytes()[:-4])
        with self.assertRaisesRegex(ValueError, "extent"):
            CORPUS.create_corpus(self.source, self.fixture, self.output)
        np.full((1024, 221), np.nan, dtype="<f4").tofile(reference)
        with self.assertRaisesRegex(ValueError, "nonfinite"):
            CORPUS.create_corpus(self.source, self.fixture, self.output)

    def test_rejects_unproven_zero_initial_feedback_and_changed_scalars(self) -> None:
        initial = self.fixture / "demanded_pdm_command.f32le"
        values = np.fromfile(initial, dtype="<f4")
        values[0] = np.float32(0.8)
        values.tofile(initial)
        with self.assertRaisesRegex(ValueError, "zero initial feedback is unproven"):
            CORPUS.create_corpus(self.source, self.fixture, self.output)
        values[0] = 0
        values.tofile(initial)
        (self.fixture / "scalars.f32le").write_bytes(
            struct.pack("<5f", -0.3, 0.98, 0.99, -0.8, 0.8))
        with self.assertRaisesRegex(ValueError, "scalars differ"):
            CORPUS.create_corpus(self.source, self.fixture, self.output)

    def test_validator_rejects_self_consistent_manifest_tampering(self) -> None:
        CORPUS.create_corpus(self.source, self.fixture, self.output)
        command = self.output / "demanded_pdm_command.f32le"
        changed = bytearray(command.read_bytes())
        changed[-1] ^= 1
        command.write_bytes(changed)
        manifest_path = self.output / "manifest.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["oracles"][command.name]["sha256"] = CORPUS.sha256(changed)
        manifest_path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, "manifest differs"):
            CORPUS.validate_replay_corpus(self.output, self.fixture,
                                          self.output / "input.fits", 28)

    def test_validator_rejects_changed_cube_fixture_or_frame_count(self) -> None:
        CORPUS.create_corpus(self.source, self.fixture, self.output)
        with self.assertRaisesRegex(ValueError, "frame count"):
            CORPUS.validate_replay_corpus(self.output, self.fixture,
                                          self.output / "input.fits", 21)
        cube = self.output / "input.fits"
        original_cube = cube.read_bytes()
        cube.write_bytes(original_cube[:-1])
        with self.assertRaisesRegex(ValueError, "product differs"):
            CORPUS.validate_replay_corpus(self.output, self.fixture, cube, 28)
        cube.write_bytes(original_cube)
        original = bytearray((self.fixture / "raw-frames.u16le").read_bytes())
        original[4] ^= 1
        (self.fixture / "raw-frames.u16le").write_bytes(original)
        with self.assertRaisesRegex(ValueError, "FITS pixels differ"):
            CORPUS.validate_replay_corpus(self.output, self.fixture, cube, 28)


if __name__ == "__main__":
    unittest.main()
