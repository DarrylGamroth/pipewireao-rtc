#!/usr/bin/env python3
"""Analyze the bounded 28-frame Classic HEART diagnostic capture offline.

This reads existing artifacts; it does not run a scientific graph or change its
acceptance criterion. libm fmaf supplies a single-rounding Float32 model, not
evidence about the instructions used by the captured HEART executable.
"""

from __future__ import annotations

import argparse
import ctypes
import ctypes.util
import hashlib
import json
from pathlib import Path
import re

import numpy as np


FRAMES = 28
BLOCK = 2880
BUFFERS = ("cbHoGrad0", "cbHoVect0", "cbDmErr0", "cbClUnclipped0", "cbDmCmd0")


def read_fits(path: Path, shape: tuple[int, ...]) -> tuple[np.ndarray, dict]:
    """Read one unscaled Float32 primary image of an explicitly expected shape."""
    content = path.read_bytes()
    if len(content) < BLOCK or len(content) % BLOCK:
        raise ValueError(f"{path}: truncated or unpadded FITS")
    cards = {}
    end = None
    for offset in range(0, min(len(content), 32 * BLOCK), 80):
        card = content[offset:offset + 80].decode("ascii")
        name = card[:8].strip()
        if name == "END":
            end = offset
            break
        if card[8:10] == "= ":
            if name in cards:
                raise ValueError(f"{path}: duplicate {name} card")
            cards[name] = card[10:].split("/", 1)[0].strip().strip("'").strip()
    if end is None:
        raise ValueError(f"{path}: no FITS END card")
    dimensions = tuple(int(cards[f"NAXIS{i}"]) for i in range(len(shape), 0, -1))
    if (cards.get("SIMPLE") != "T" or int(cards["BITPIX"]) != -32
            or int(cards["NAXIS"]) != len(shape) or dimensions != shape
            or float(cards.get("BSCALE", "1")) != 1
            or float(cards.get("BZERO", "0")) != 0):
        raise ValueError(f"{path}: unexpected FITS type, shape, or scaling")
    header_size = ((end + 80 + BLOCK - 1) // BLOCK) * BLOCK
    count = int(np.prod(shape))
    payload_size = count * 4
    if len(content) != header_size + ((payload_size + BLOCK - 1) // BLOCK) * BLOCK:
        raise ValueError(f"{path}: unexpected FITS payload extent")
    values = np.frombuffer(content, dtype=">f4", offset=header_size,
                           count=count).reshape(shape).astype(np.float32)
    if not np.isfinite(values).all():
        raise ValueError(f"{path}: nonfinite FITS values")
    return values, {"shape": list(shape), "cards": cards,
                    "sha256": hashlib.sha256(content).hexdigest(), "finite": True}


def read_array(path: Path, shape: tuple[int, ...]) -> np.ndarray:
    values = np.fromfile(path, dtype="<f4")
    if values.size != int(np.prod(shape)) or not np.isfinite(values).all():
        raise ValueError(f"{path}: unexpected array size or nonfinite values")
    return values.reshape(shape)


def compare(actual: np.ndarray, expected: np.ndarray) -> dict:
    if actual.shape != expected.shape:
        raise ValueError("comparison shapes differ")
    return {
        "values": actual.size,
        "unequal_bits": int(np.count_nonzero(actual.view(np.uint32)
                                             != expected.view(np.uint32))),
        "max_absolute_difference": float(np.max(np.abs(
            actual.astype(np.float64) - expected.astype(np.float64)))),
    }


class Fma:
    """Use the host libm's fmaf, retaining the library for the callable's lifetime."""

    def __init__(self):
        self.library = ctypes.CDLL(ctypes.util.find_library("m") or "libm.so.6")
        self.function = self.library.fmaf
        self.function.argtypes = [ctypes.c_float] * 3
        self.function.restype = ctypes.c_float

    def __call__(self, a, b, c) -> np.ndarray:
        aa, bb, cc = np.broadcast_arrays(a, b, c)
        return np.fromiter(
            (self.function(float(x), float(y), float(z))
             for x, y, z in zip(aa.flat, bb.flat, cc.flat)),
            dtype=np.float32, count=aa.size,
        ).reshape(aa.shape)


def read_sparse(path: Path) -> tuple[np.ndarray, list[tuple[int, int, np.float32]]]:
    """Preserve coefficient order from the original 277×277 calibration."""
    matrix = np.zeros((277, 277), dtype=np.float32)
    entries = []
    header = False
    seen = set()
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("Sparse:"):
            if header or not re.match(r"Sparse: rows=277 cols=277 nnz=12597\b", line):
                raise ValueError("unexpected sparse header")
            header = True
            continue
        row, col, value = line.split()
        row, col, value = int(row), int(col), np.float32(value)
        if (not header or not 0 <= row < 277 or not 0 <= col < 277
                or (row, col) in seen or not np.isfinite(value)):
            raise ValueError("invalid sparse coefficient")
        if entries and row < entries[-1][0]:
            raise ValueError("sparse rows are not ordered")
        seen.add((row, col))
        entries.append((row, col, value))
        matrix[row, col] = value
    if len(entries) != 12597:
        raise ValueError("unexpected sparse coefficient count")
    return matrix, entries


def project(values: np.ndarray, entries) -> np.ndarray:
    output = np.zeros((FRAMES, 277), dtype=np.float32)
    for row, col, coefficient in entries:
        output[:, row] += coefficient * values[:, col]
    return output


def controller(errors, indices, pole, lo, hi, fma, fused) -> np.ndarray:
    state = np.zeros(277, dtype=np.float32)
    output = np.empty_like(errors)
    for frame, error in enumerate(errors):
        state = fma(pole, state, error) if fused else pole * state + error
        output[frame] = state
        feedback = np.zeros_like(state)
        feedback[indices] = state[indices] - np.clip(state[indices], lo, hi)
        state = fma(-pole, feedback, state) if fused else state - pole * feedback
    return output


def analyze(capture: Path, fixture: Path, corpus: Path, extrapolation: Path) -> dict:
    run = json.loads((capture / "report.json").read_text())
    if run["frames"] != FRAMES:
        raise ValueError("this analysis requires the bounded 28-frame capture")
    arrays, metadata = {}, {}
    recorded_hashes = {item["buffer"]: item["sha256"] for item in run["boundary_dumps"]}
    for name in BUFFERS:
        shape = (FRAMES, 188, 4) if name == "cbHoGrad0" else (FRAMES, 277, 1)
        values, metadata[name] = read_fits(capture / f"{name}.fits", shape)
        if metadata[name]["sha256"] != recorded_hashes[name]:
            raise ValueError(f"{name}: hash differs from capture report")
        arrays[name] = values if name == "cbHoGrad0" else values[:, :, 0].copy()
    selection = read_array(fixture / "full-to-active-vdm.f32le", (221, 277))
    indices = selection.argmax(axis=1)
    if (np.count_nonzero(selection) != 221 or len(set(indices)) != 221
            or not np.all(selection[np.arange(221), indices] == 1)):
        raise ValueError("unexpected controlled-coordinate selection")
    uncontrolled = np.setdiff1d(np.arange(277), indices)
    matrix, entries = read_sparse(extrapolation)
    compact = read_array(fixture / "active-to-full-vdm.f32le", (277, 221))
    if (not np.array_equal(matrix[:, indices], compact)
            or np.any(matrix[:, uncontrolled])
            or not np.array_equal(compact[indices], np.eye(221, dtype=np.float32))):
        raise ValueError("original and compact extrapolation identities do not hold")
    g, pole, antiwindup, lo, hi = read_array(fixture / "scalars.f32le", (5,))
    if not np.array_equal([g, pole, antiwindup, lo, hi],
                          np.array([-.3, .99, .99, -.8, .8], dtype=np.float32)):
        raise ValueError("unexpected controller coefficients")
    grad = arrays["cbHoGrad0"]
    if not np.all(grad[:, :, 0] == 1):
        raise ValueError("capture contains inactive subapertures; masking needs review")
    slopes = grad[:, :, 1:3].reshape(FRAMES, 376).copy()
    recon = arrays["cbHoVect0"]
    errors = arrays["cbDmErr0"]
    observed = arrays["cbClUnclipped0"]
    commands = arrays["cbDmCmd0"]
    wire = read_array(capture / "dm-wire-um.f32", (FRAMES, 277))
    rust_q = read_array(corpus / "demanded_pdm_command.f32le", (FRAMES, 277))
    rust_u = read_array(corpus / "vdm_command.f32le", (FRAMES, 221))
    fma = Fma()
    reconstructed = np.zeros((FRAMES, 221), dtype=np.float32)
    ordinary_reconstructed = np.zeros_like(reconstructed)
    c = read_array(fixture / "reconstructor.f32le", (221, 376))
    for col in range(0, 376, 2):
        x, y = slopes[:, col, None], slopes[:, col + 1, None]
        y_product = y * c[:, col + 1]
        reconstructed += fma(x, c[:, col], y_product)
        ordinary_reconstructed += x * c[:, col] + y_product
    reconstructed_padded = np.zeros_like(recon)
    reconstructed_padded[:, indices] = reconstructed
    predicted = controller(errors, indices, pole, lo, hi, fma, True)
    ordinary = controller(errors, indices, pole, lo, hi, fma, False)
    independent = controller(g * reconstructed_padded, indices, pole, lo, hi, fma, True)
    physical = np.clip(project(independent, entries), lo, hi)
    reference_frames = np.arange(FRAMES) % 7
    differences = np.abs(wire.astype(np.float64) - rust_q.astype(np.float64))
    scales = np.maximum(np.maximum(np.abs(wire), np.abs(rust_q)), 1)
    failures = (differences > 1e-6) & (differences / scales > 1e-6)
    heart_exact_projection = observed[:, indices].astype(np.float64) @ compact.T.astype(np.float64)
    rust_exact_projection = rust_u.astype(np.float64) @ compact.T.astype(np.float64)
    failed_values = []
    for frame, coordinate in zip(*np.where(failures)):
        failed_values.append({
            "frame_index": int(frame), "physical_coordinate": int(coordinate),
            "heart": float(wire[frame, coordinate]), "rust": float(rust_q[frame, coordinate]),
            "difference": float(wire[frame, coordinate] - rust_q[frame, coordinate]),
            "controlled": bool(coordinate in indices),
            "projected_controller_difference_float64": float(
                heart_exact_projection[frame, coordinate] - rust_exact_projection[frame, coordinate]),
            "heart_projection_rounding_vs_float64": float(
                wire[frame, coordinate] - heart_exact_projection[frame, coordinate]),
            "rust_projection_rounding_vs_float64": float(
                rust_q[frame, coordinate] - rust_exact_projection[frame, coordinate]),
        })
    return {
        "scope": "offline numerical evidence; does not qualify a failed run or identify machine instructions",
        "paths": {"capture": str(capture), "fixture": str(fixture),
                  "corpus": str(corpus), "extrapolation": str(extrapolation)},
        "run_qualified": run["qualified"], "run_errors": run["errors"],
        "nonzero_process_returns": [item for item in run["commands"] if item.get("returncode") != 0],
        "boundary_dump_returns": [item["returncode"] for item in run["commands"]
                                  if "DUMP_BUFFER" in item["argv"]],
        "fits": metadata,
        "extrapolation_sha256": hashlib.sha256(extrapolation.read_bytes()).hexdigest(),
        "original_sparse_matches_compact": True,
        "command_buffer_vs_wire": compare(commands, wire),
        "gradient_state_counts": {"active": int(np.count_nonzero(grad[:, :, 0] == 1))},
        "gradient_vs_rust": compare(slopes, read_array(fixture / "slopes.f32le", (7, 376))[reference_frames]),
        "gradient_periodic": compare(slopes, slopes[reference_frames]),
        "reconstruction_vs_rust": compare(recon[:, indices].copy(), read_array(
            fixture / "dm_error.f32le", (7, 221))[reference_frames]),
        "reconstruction_periodic": compare(recon, recon[reference_frames]),
        "ordinary_pair_reconstruction": compare(ordinary_reconstructed, recon[:, indices].copy()),
        "fmaf_pair_reconstruction": compare(reconstructed, recon[:, indices].copy()),
        "gain_multiplication": compare(g * recon, errors),
        "ordinary_controller": compare(ordinary, observed),
        "fmaf_controller": compare(predicted, observed),
        "fmaf_controller_from_captured_gradients": compare(independent, observed),
        "sequential_projection_of_captured_controller": compare(np.clip(
            project(observed, entries), lo, hi), commands),
        "complete_model_from_captured_gradients": compare(physical, wire),
        "controlled_clamp": compare(np.clip(observed[:, indices], lo, hi), commands[:, indices].copy()),
        "uncontrolled_nonzero_values": {name: int(np.count_nonzero(arrays[name][:, uncontrolled]))
                                        for name in ("cbHoVect0", "cbDmErr0", "cbClUnclipped0")},
        "wire_gate": {"qualified": not bool(failures.any()), "failed_values": failed_values,
                      "max_absolute_error_um": float(differences.max()),
                      "criterion": "abs <= 1e-6 OR abs/max(abs(actual),abs(expected),1) <= 1e-6; native microns"},
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("capture", "fixture", "corpus", "extrapolation"):
        parser.add_argument(f"--{name}", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    result = analyze(args.capture, args.fixture, args.corpus, args.extrapolation)
    text = json.dumps(result, indent=2, allow_nan=False) + "\n"
    if args.output:
        args.output.write_text(text)
    else:
        print(text, end="")


if __name__ == "__main__":
    main()
