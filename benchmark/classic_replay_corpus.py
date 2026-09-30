#!/usr/bin/env python3
"""Make a bounded, state-continuous Classic FITS replay and captured oracles.

The seven source frames repeat in their original order. The first seven oracle
frames are the direct exporter capture; later frames are the prefix of its
1,024-frame continued feedback capture (no controller reset at frame eight).
No control or calibration values are recalculated here.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import struct
import tomllib

import numpy as np


BLOCK = 2880
CARD = 80
WIDTH = HEIGHT = 352
SOURCE_FRAMES = 7
MAX_REPETITIONS = 4  # The current clipping corpus is at most 28 frames.
CONTINUED_FRAMES = 1024
ORACLES = (
    ("demanded_pdm_command.f32le", "feedback-demanded-pdm-command.f32le", 277,
     "physical PDM command", "µm"),
    ("vdm_command.f32le", "feedback-vdm-command.f32le", 221,
     "prelimit controlled VDM command", "µm"),
)
FEEDBACK = "feedback-controller-constraint-feedback.f32le"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _card_number(cards: list[bytes], name: bytes) -> int:
    matches = [card for card in cards if card[:8].strip() == name]
    if len(matches) != 1 or matches[0][8:10] != b"= ":
        raise ValueError(f"expected one {name.decode()} FITS card")
    try:
        return int(matches[0][10:].split(b"/", 1)[0].strip())
    except ValueError as error:
        raise ValueError(f"invalid {name.decode()} FITS card") from error


def read_cube(path: Path, frames: int = SOURCE_FRAMES) -> tuple[bytearray, list[bytes], bytes]:
    """Accept exactly one standard primary UInt16 image with valid extent."""
    content = path.read_bytes()
    if len(content) < BLOCK or len(content) % BLOCK:
        raise ValueError("truncated or unpadded FITS cube")
    end = None
    for offset in range(0, min(len(content), 32 * BLOCK), CARD):
        if offset % BLOCK == 0 and len(content) - offset < BLOCK:
            break
        card = content[offset:offset + CARD]
        if card[:8] == b"END     ":
            end = offset
            break
    if end is None:
        raise ValueError("FITS primary header has no END card")
    header_size = ((end + CARD + BLOCK - 1) // BLOCK) * BLOCK
    header = bytearray(content[:header_size])
    cards = [bytes(header[i:i + CARD]) for i in range(0, end, CARD)]
    if not cards or cards[0][:8] != b"SIMPLE  " or cards[0][10:30].strip() != b"T":
        raise ValueError("expected a simple primary FITS image")
    if tuple(_card_number(cards, name) for name in
             (b"BITPIX", b"NAXIS", b"NAXIS1", b"NAXIS2", b"NAXIS3",
              b"BSCALE", b"BZERO")) != (16, 3, WIDTH, HEIGHT, frames, 1, 32768):
        raise ValueError("expected 352×352 UInt16 Classic frames, BSCALE=1, BZERO=32768")
    payload_size = WIDTH * HEIGHT * frames * 2
    if len(content) != header_size + ((payload_size + BLOCK - 1) // BLOCK) * BLOCK:
        raise ValueError("FITS payload extent differs from one padded primary image")
    payload = content[header_size:header_size + payload_size]
    return header, cards, payload


def _validated_fixture(fixture: Path, payload: bytes) -> dict:
    profile_bytes = (fixture / "prepared-profile.toml").read_bytes()
    profile = tomllib.loads(profile_bytes.decode("utf-8"))
    detector = profile.get("detector", {})
    if (detector.get("frame_count") != SOURCE_FRAMES or
            detector.get("width") != WIDTH or
            detector.get("height") != HEIGHT or
            tuple(profile.get("deformable_mirror", {}).get(k) for k in
                  ("controlled_vdm_size", "full_vdm_size", "pdm_size")) != (221, 277, 277)):
        raise ValueError("prepared fixture has different Classic geometry")
    control = profile.get("clwc", {})
    if tuple(control.get(k) for k in ("loop_gain", "pole", "anti_windup_gain")) != (-0.3, 0.99, 0.99):
        raise ValueError("prepared fixture has different controller coefficients")
    limits = profile.get("pdm_limits", {})
    if limits.get("lower") != [-0.8] * 277 or limits.get("upper") != [0.8] * 277:
        raise ValueError("prepared fixture has different PDM limits")
    scalar_path = fixture / "scalars.f32le"
    scalars = scalar_path.read_bytes()
    if scalars != struct.pack("<5f", -0.3, 0.99, 0.99, -0.8, 0.8):
        raise ValueError("exported controller and limit scalars differ from selected Classic values")
    raw_path = fixture / "raw-frames.u16le"
    raw = raw_path.read_bytes()
    if len(raw) != len(payload):
        raise ValueError("raw fixture has wrong pixel extent")
    decoded = (np.frombuffer(payload, dtype=">i2").astype(np.int32) + 32768).astype("<u2")
    if decoded.tobytes() != raw:
        raise ValueError("FITS pixels differ from raw-frames.u16le")
    return {"prepared-profile.toml": sha256(profile_bytes), raw_path.name: sha256(raw),
            scalar_path.name: sha256(scalars)}


def _read_floats(path: Path, frames: int, width: int) -> bytes:
    data = path.read_bytes()
    if len(data) != frames * width * 4:
        raise ValueError(f"wrong Float32 frame extent: {path}")
    if not all(math.isfinite(value) for (value,) in struct.iter_unpack("<f", data)):
        raise ValueError(f"nonfinite Float32 oracle: {path}")
    return data


def _build_corpus(source: Path, fixture: Path, repetitions: int) -> tuple[dict, dict[str, bytes]]:
    if type(repetitions) is not int or not 1 <= repetitions <= MAX_REPETITIONS:
        raise ValueError(f"repetitions must be an integer in 1..{MAX_REPETITIONS}")
    header, cards, payload = read_cube(source)
    source_hashes = {"original_cube": sha256(source.read_bytes())}
    source_hashes.update(_validated_fixture(fixture, payload))
    frames = SOURCE_FRAMES * repetitions
    continued = frames - SOURCE_FRAMES
    products: dict[str, bytes] = {}
    oracle_info: dict[str, dict] = {}
    for initial_name, continued_name, width, label, unit in ORACLES:
        initial = _read_floats(fixture / initial_name, SOURCE_FRAMES, width)
        extension = _read_floats(fixture / continued_name, CONTINUED_FRAMES, width)
        source_hashes[initial_name] = sha256(initial)
        source_hashes[continued_name] = sha256(extension)
        products[initial_name] = initial + extension[:continued * width * 4]
        oracle_info[initial_name] = {"shape": [frames, width], "dtype": "Float32 little endian",
                                     "quantity": label, "unit": unit,
                                     "sha256": sha256(products[initial_name])}
    initial_commands = np.frombuffer(
        products["demanded_pdm_command.f32le"][:SOURCE_FRAMES * 277 * 4], dtype="<f4")
    if np.any(np.abs(initial_commands) >= np.float32(0.8)):
        raise ValueError("initial seven commands touch a limit; zero initial feedback is unproven")
    feedback = _read_floats(fixture / FEEDBACK, CONTINUED_FRAMES, 221)
    source_hashes[FEEDBACK] = sha256(feedback)
    feedback_name = "controller-constraint-feedback.f32le"
    products[feedback_name] = bytes(SOURCE_FRAMES * 221 * 4) + feedback[:continued * 221 * 4]
    oracle_info[feedback_name] = {"shape": [frames, 221], "dtype": "Float32 little endian",
                                  "quantity": "controller constraint feedback", "unit": "µm",
                                  "sha256": sha256(products[feedback_name]),
                                  "initial_seven": "zero as independently confirmed in CLASSIC_PRECISION_REVIEW.md"}
    # Change only the frame count and stale checksum metadata; preserve the
    # source image encoding, scaling cards, and pixel bytes verbatim.
    for index, card in enumerate(cards):
        offset = index * CARD
        if card[:8] == b"NAXIS3  ":
            header[offset:offset + CARD] = f"NAXIS3  = {frames:20d}".encode("ascii").ljust(CARD)
        elif card[:8].strip() in (b"CHECKSUM", b"DATASUM"):
            header[offset:offset + CARD] = b" " * CARD
    image = payload * repetitions
    cube = bytes(header) + image + b"\0" * (-len(image) % BLOCK)
    cube_name = "input.fits"
    products[cube_name] = cube
    command_values = np.frombuffer(products["demanded_pdm_command.f32le"], dtype="<f4")
    feedback_values = np.frombuffer(products[feedback_name], dtype="<f4")
    manifest = {
        "kind": "bounded Classic repeated-frame clipping corpus",
        "source_frames": SOURCE_FRAMES, "repetitions": repetitions, "frames": frames,
        "original_cube_path": str(source.resolve()),
        "cube": {"file": cube_name, "shape": [frames, HEIGHT, WIDTH],
                 "dtype": "UInt16 via FITS BITPIX=16, BSCALE=1, BZERO=32768",
                 "sha256": sha256(cube)},
        "source_sha256": source_hashes, "oracles": oracle_info,
        "order": "source frames 1..7 repeat; oracle frames 1..7 are initial capture, frames 8..N are the continued capture prefix, without state reset",
        "continued_capture_available_frames": CONTINUED_FRAMES,
        "clipped_physical_values": int(np.count_nonzero(np.abs(command_values) == np.float32(0.8))),
        "nonzero_controller_feedback_frames": int(np.count_nonzero(np.any(feedback_values.reshape(frames, 221) != 0, axis=1))),
        "comparison_criterion": "10⁻⁶ µm absolute or scaled relative (scale floor 1); this corpus does not change the existing gate",
        "qualification": "captured Rust reference trajectory; no live receiver or physical-loop qualification",
    }
    return manifest, products


def create_corpus(source: Path, fixture: Path, output: Path,
                  repetitions: int = MAX_REPETITIONS) -> dict:
    """Create the corpus in a new directory after validating every input."""
    if output.exists() or output.is_symlink():
        raise ValueError(f"output already exists: {output}")
    if source.resolve() == output.resolve() or fixture.resolve() == output.resolve():
        raise ValueError("output must be separate from inputs")
    manifest, products = _build_corpus(source, fixture, repetitions)
    output.mkdir(parents=True)
    for name, data in products.items():
        (output / name).write_bytes(data)
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
                                          encoding="utf-8")
    return manifest


def validate_replay_corpus(directory: Path, fixture: Path, cube: Path, frames: int) -> dict:
    """Rebuild and byte-check a corpus against its original cube and fixture.

    This deliberately does not trust hashes or dimensions supplied by the
    manifest. The original cube must remain available at its recorded path.
    """
    if type(frames) is not int or frames < SOURCE_FRAMES or frames % SOURCE_FRAMES:
        raise ValueError("corpus frame count must be a positive multiple of seven")
    if cube.resolve() != (directory / "input.fits").resolve():
        raise ValueError("cube must be the corpus input.fits")
    recorded = json.loads((directory / "manifest.json").read_text(encoding="utf-8"))
    if recorded.get("frames") != frames or recorded.get("repetitions") != frames // SOURCE_FRAMES:
        raise ValueError("corpus frame count differs from manifest")
    source = Path(recorded["original_cube_path"])
    expected, products = _build_corpus(source, fixture, frames // SOURCE_FRAMES)
    if recorded != expected:
        raise ValueError("corpus manifest differs from verified source and fixture")
    for name, data in products.items():
        if (directory / name).read_bytes() != data:
            raise ValueError(f"corpus product differs from verified source and fixture: {name}")
    return recorded


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cube", type=Path, required=True, help="original seven-frame Classic FITS cube")
    parser.add_argument("--fixture", type=Path, required=True, help="prepared Classic fixture directory")
    parser.add_argument("--output", type=Path, required=True, help="new corpus directory")
    parser.add_argument("--repetitions", type=int, default=MAX_REPETITIONS)
    args = parser.parse_args()
    result = create_corpus(args.cube, args.fixture, args.output, args.repetitions)
    print(json.dumps({"cube": result["cube"], "frames": result["frames"]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
