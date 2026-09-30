#!/usr/bin/env python3
"""Evaluate arithmetic conformance of saved Classic captures, never run qualification.

The historical 1e-6 gate is retained. Bounds follow operation counts and IEEE
binary32 rounding; none is fitted to the observed cross-implementation maximum.
See CLASSIC_NUMERICAL_ACCEPTANCE.md for the acceptance scope and derivation.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np

from analyze_classic_heart_boundaries import (Fma, analyze as analyze_heart,
                                             compare, read_array, read_fits)

U32 = 2.0 ** -24
U64 = 2.0 ** -53
TINY32 = 2.0 ** -149


def require_active_subapertures(fixture):
    """The reviewed Classic sensor model requires all 188 subapertures active."""
    path = Path(fixture) / "active-subapertures.u8"
    active = np.fromfile(path, dtype="u1")
    if active.shape != (188,) or not np.all(active == 1):
        raise ValueError("Classic arithmetic model requires 188 active subapertures with mask value one")
    return path


def gamma(operations: int, unit_roundoff: float = U32) -> float:
    if operations < 0 or operations * unit_roundoff >= 1:
        raise ValueError("invalid rounding operation count")
    return operations * unit_roundoff / (1 - operations * unit_roundoff)


def strict_gate(actual, expected):
    difference = np.abs(actual.astype(np.float64) - expected.astype(np.float64))
    scale = np.maximum(1, np.maximum(np.abs(actual), np.abs(expected)))
    bad = (difference > 1e-6) & (difference / scale > 1e-6)
    return {"passed": not bool(bad.any()), "failed_values": int(bad.sum()),
            "maximum_absolute_difference": float(difference.max())}


def within_bound(actual_error, bound):
    actual_error, bound = np.broadcast_arrays(actual_error, bound)
    if (not np.isfinite(actual_error).all() or not np.isfinite(bound).all()
            or np.any(actual_error < 0) or np.any(bound < 0)):
        raise ValueError("invalid error or bound")
    ratio = np.divide(actual_error, bound, out=np.zeros_like(actual_error), where=bound > 0)
    ratio[(bound == 0) & (actual_error > 0)] = np.inf
    return {"passed": bool(np.all(actual_error <= bound)),
            "failed_values": int(np.count_nonzero(actual_error > bound)),
            "maximum_error": float(actual_error.max()), "maximum_bound": float(bound.max()),
            "maximum_error_to_bound_ratio": float(ratio.max()) if np.isfinite(ratio).all() else None}


def dot_reference(matrix, inputs):
    """Binary64 reference, with explicit reference and binary32 reduction budgets.

    2*n bounds multiplication and addition paths for a sum using every term
    once, including tree, sequential, paired and FMA reductions. Float32 inputs
    multiply exactly in binary64. The reference sum's own error is included.
    """
    matrix, inputs = matrix.astype(np.float64), inputs.astype(np.float64)
    n = matrix.shape[1]
    result = inputs @ matrix.T
    magnitude = np.abs(inputs) @ np.abs(matrix).T
    # Inflate the computed nonnegative sum before applying either gamma.
    upper_magnitude = np.nextafter(magnitude / (1 - gamma(2 * n, U64)), np.inf)
    reference_error = gamma(2 * n, U64) * upper_magnitude
    rounding = gamma(2 * n) * upper_magnitude + 2 * n * TINY32
    return result, np.nextafter((rounding + reference_error) / (1 - gamma(8, U64)), np.inf)


def sensor_model(pixels, origins, coordinates, thresholds, references, heart):
    """Source-derived CoG arithmetic; HEART's four scalar tail pixels precede lane fold."""
    patches = np.stack([pixels[:, r:r + 22, c:c + 22].reshape(-1, 484)
                        for r, c in origins], axis=1)
    selected = np.where(patches >= thresholds[None, :, 0, None], patches, np.float32(0))
    shape = selected.shape[:2]
    moment = np.zeros((*shape, 2), np.float32)
    flux = np.zeros(shape, np.float32)
    if heart:
        lanes = np.zeros((*shape, 16, 2), np.float32)
        lane_flux = np.zeros((*shape, 16), np.float32)
        for pixel in range(480):
            lane = pixel % 16
            lanes[:, :, lane] += selected[:, :, pixel, None] * coordinates[pixel]
            lane_flux[:, :, lane] += selected[:, :, pixel]
        for pixel in range(480, 484):
            moment += selected[:, :, pixel, None] * coordinates[pixel]
            flux += selected[:, :, pixel]
        for lane in range(16):
            moment += lanes[:, :, lane]
            flux += lane_flux[:, :, lane]
        slopes = moment * (np.float32(1) / flux[:, :, None]) - references
    else:
        for pixel in range(484):
            moment += selected[:, :, pixel, None] * coordinates[pixel]
            flux += selected[:, :, pixel]
        slopes = moment / flux[:, :, None] - references
    if not np.all(flux >= thresholds[None, :, 1]):
        raise ValueError("inactive subapertures require a separate model")
    return slopes.reshape(-1, 376).copy(), flux


def rn_error(result):
    # From |fl(x)-x| <= u |x| + half-min-subnormal, expressed using fl(x).
    return (U32 * np.abs(result.astype(np.float64)) + TINY32) / (1 - U32)


def controller_model(residual, scalars, heart=False):
    g, p, a, lo, hi = scalars
    if not (0 <= a <= 1 and 0 <= p < 1):
        raise ValueError("contractive controller bounds require 0 <= a <= 1, 0 <= p < 1")
    fma = Fma() if heart else None
    u = np.zeros(residual.shape[1], np.float32)
    feedback = np.zeros_like(u)
    state = u.copy()
    previous_state_error = np.zeros_like(u, dtype=np.float64)
    predicted, feedbacks, local_errors = [], [], []
    for r in residual:
        weighted = g * r
        if heart:
            out = fma(p, state, weighted)
            local = float(p) * previous_state_error + rn_error(weighted) + rn_error(out)
        else:
            antiwindup = a * feedback
            corrected = u - antiwindup
            decayed = p * corrected
            out = decayed + weighted
            local = (float(p) * (float(a) * rn_error(feedback) + rn_error(antiwindup)
                                + rn_error(corrected)) + rn_error(decayed)
                     + rn_error(weighted) + rn_error(out))
        u = out
        feedback = u - np.clip(u, lo, hi)
        if heart:
            state = fma(-a, feedback, u)
            previous_state_error = float(a) * rn_error(feedback) + rn_error(state)
        predicted.append(u.copy())
        feedbacks.append(feedback.copy())
        local_errors.append(np.nextafter(local / (1 - gamma(16, U64)), np.inf))
    return np.array(predicted), np.array(feedbacks), np.array(local_errors)


def propagated_controller_bound(residual_a, residual_b, local_a, local_b, scalars):
    g, p = map(float, scalars[:2])
    bound = np.zeros(residual_a.shape[1], np.float64)
    output = []
    for ra, rb, ea, eb in zip(residual_a, residual_b, local_a, local_b):
        # Exact input differences: subtraction of two finite binary32 numbers in binary64.
        forcing = abs(g) * np.abs(ra.astype(np.float64) - rb.astype(np.float64))
        bound = np.nextafter((p * bound + forcing + ea + eb) / (1 - gamma(8, U64)), np.inf)
        output.append(bound.copy())
    return np.array(output)


def evaluate(evidence: Path, heart_capture: Path, corpus: Path, extrapolation: Path):
    fixture, jfg = evidence / "fixture", evidence / "jfg-array-compact"
    used = {require_active_subapertures(fixture)}
    def read(directory, name, shape):
        path = directory / name
        used.add(path)
        return read_array(path, shape)
    c = read(fixture, "reconstructor.f32le", (221, 376))
    e = read(fixture, "active-to-full-vdm.f32le", (277, 221))
    t = read(fixture, "full-to-active-vdm.f32le", (221, 277))
    indices = t.argmax(axis=1)
    if (np.count_nonzero(t) != 221 or len(set(indices)) != 221
            or not np.all(t[np.arange(221), indices] == 1)
            or not np.array_equal(e[indices], np.eye(221, dtype=np.float32))):
        raise ValueError("controlled selection/extrapolation identity failed")
    for name, n in (("controller-to-vdm", 221), ("vdm-to-controller", 221),
                    ("vdm-to-pdm", 277), ("pdm-to-vdm", 277)):
        if not np.array_equal(read(fixture, name + ".f32le", (n, n)), np.eye(n)):
            raise ValueError(f"{name} must be identity")
    scalars = read(fixture, "scalars.f32le", (5,))
    if not np.array_equal(scalars, np.array([-.3, .99, .99, -.8, .8], np.float32)):
        raise ValueError("unexpected Classic coefficients")
    lo, hi = scalars[3:]
    slopes = read(fixture, "slopes.f32le", (7, 376))
    pixels = read(fixture, "calibrated_pixels.f32le", (7, 352, 352))
    raw_path = fixture / "raw-frames.u16le"
    used.add(raw_path)
    raw = np.fromfile(raw_path, dtype="<u2").reshape(7, 352, 352)
    background = read(fixture, "background.f32le", (352, 352))
    origins_path = fixture / "subaperture-origins.u32le"
    used.add(origins_path)
    origins = np.fromfile(origins_path, dtype="<u4").reshape(188, 2)
    if np.any(origins > 330):
        raise ValueError("invalid subaperture origins")
    coordinates = read(fixture, "shack-hartmann-coordinates.f32le", (484, 2))
    thresholds = read(fixture, "thresholds.f32le", (188, 2))
    references = read(fixture, "reference-slopes.f32le", (188, 2))
    sensor_rust, _ = sensor_model(pixels, origins, coordinates, thresholds, references, False)
    sensor_heart, flux_heart = sensor_model(pixels, origins, coordinates, thresholds, references, True)
    gradient_path = heart_capture / "cbHoGrad0.fits"
    used.add(gradient_path)
    gradients, _ = read_fits(gradient_path, (28, 188, 4))
    heart = analyze_heart(heart_capture, fixture, corpus, extrapolation)
    for path in heart_capture.iterdir():
        if path.name in ("report.json", "dm-wire-um.f32") or path.suffix == ".fits":
            used.add(path)
    used.add(extrapolation)
    used.add(corpus / "demanded_pdm_command.f32le")
    used.add(corpus / "vdm_command.f32le")
    exact = {
        "calibrated_pixels_from_raw_minus_background": compare(raw.astype(np.float32) - background, pixels),
        "rust_gradients_from_shared_pixels": compare(sensor_rust, slopes),
        "heart_gradients_from_shared_pixels": compare(sensor_heart[np.arange(28) % 7], gradients[:, :, 1:3].reshape(28, 376).copy()),
        "heart_flux_from_shared_pixels": compare(flux_heart[np.arange(28) % 7], gradients[:, :, 3].copy()),
    }
    count = 1031
    residuals = {
        "rust": read(fixture, "dm_error.f32le", (7, 221))[np.arange(count) % 7],
        "jfg": read(jfg, "dm_error.f32le", (count, 221)),
        "heart": read_fits(heart_capture / "cbHoVect0.fits", (28, 277, 1))[0][:, indices, 0].copy(),
    }
    u = {
        "rust": np.concatenate([read(fixture, "vdm_command.f32le", (7, 221)),
                                 read(fixture, "feedback-vdm-command.f32le", (1024, 221))]),
        "jfg": read(jfg, "vdm_command.f32le", (count, 221)),
        "heart": read_fits(heart_capture / "cbClUnclipped0.fits", (28, 277, 1))[0][:, indices, 0].copy(),
    }
    q = {
        "rust": np.concatenate([read(fixture, "demanded_pdm_command.f32le", (7, 277)),
                                 read(fixture, "feedback-demanded-pdm-command.f32le", (1024, 277))]),
        "jfg": read(jfg, "demanded_pdm_command.f32le", (count, 277)),
        "heart": read(heart_capture, "dm-wire-um.f32", (28, 277)),
    }
    feedbacks = {
        "rust": np.concatenate([np.zeros((7, 221), np.float32), read(fixture, "feedback-controller-constraint-feedback.f32le", (1024, 221))]),
        "jfg": read(jfg, "controller_constraint_feedback.f32le", (count, 221)),
    }
    exact["jfg_slopes_match_rust"] = compare(read(jfg, "slopes.f32le", (7, 376)), slopes)
    checks, locals_, projection_bounds = {}, {}, {}
    for name in residuals:
        n = len(residuals[name])
        inputs = sensor_heart[np.arange(n) % 7] if name == "heart" else slopes[np.arange(n) % 7]
        reference, budget = dot_reference(c, inputs)
        checks[name + "_reconstruction_rounding"] = within_bound(np.abs(residuals[name].astype(np.float64) - reference), budget)
        predicted, feedback, local = controller_model(residuals[name], scalars, heart=name == "heart")
        exact[name + "_controller"] = compare(predicted, u[name])
        exact[name + "_controlled_clamp"] = compare(np.clip(u[name], lo, hi), q[name][:, indices].copy())
        if name in feedbacks:
            exact[name + "_feedback"] = compare(feedback, feedbacks[name])
        locals_[name] = local
        reference_q, budget_q = dot_reference(e, u[name])
        projection_bounds[name] = budget_q
        checks[name + "_projection_rounding"] = within_bound(np.abs(q[name].astype(np.float64) - np.clip(reference_q, lo, hi)), budget_q)
    for name in ("fmaf_pair_reconstruction", "gain_multiplication", "fmaf_controller",
                 "complete_model_from_captured_gradients", "command_buffer_vs_wire"):
        exact["heart_" + name] = heart[name]
    historical, propagation, clipping = {}, {}, {}
    for left, right, n in (("jfg", "rust", count), ("heart", "rust", 28)):
        key = left + "_vs_" + right
        classification = lambda values: np.where(values == lo, -1, np.where(values == hi, 1, 0))
        clipping[key] = int(np.count_nonzero(classification(q[left][:n]) != classification(q[right][:n])))
        historical[key] = {"controller": strict_gate(u[left][:n], u[right][:n]),
                           "physical_command": strict_gate(q[left][:n], q[right][:n])}
        bound = propagated_controller_bound(residuals[left][:n], residuals[right][:n],
                                             locals_[left][:n], locals_[right][:n], scalars)
        propagation[key + "_controller"] = within_bound(np.abs(u[left][:n].astype(np.float64) - u[right][:n].astype(np.float64)), bound)
        physical_bound = bound @ np.abs(e.astype(np.float64)).T + projection_bounds[left][:n] + projection_bounds[right][:n]
        # Account conservatively for binary64 evaluation of this nonnegative expression.
        physical_bound = np.nextafter(physical_bound / (1 - gamma(2 * 221 + 4, U64)), np.inf)
        propagation[key + "_physical_command"] = within_bound(np.abs(q[left][:n].astype(np.float64) - q[right][:n].astype(np.float64)), physical_bound)
    passed = all(value == 0 for value in clipping.values()) and all(x["unequal_bits"] == 0 for x in exact.values()) and all(x["passed"] for x in [*checks.values(), *propagation.values()])
    hashes = {str(path.resolve()): hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(used)}
    return {"schema_version": 1, "scope": "saved-array arithmetic conformance; no physical accuracy or run qualification",
            "arithmetic_conformance_passed": passed, "application_accuracy": "not assessed: no application error budget supplied",
            "heart_original_run_qualified": heart["run_qualified"], "historical_1e_minus_6": historical,
            "exact_models": exact, "clipping_classification_disagreements": clipping, "rounding_bounds": checks, "propagation_bounds": propagation,
            "input_sha256": hashes,
            "analyzer_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            "heart_analyzer_sha256": hashlib.sha256(Path(__file__).with_name("analyze_classic_heart_boundaries.py").read_bytes()).hexdigest()}


def heart_wire_model(fixture, frames):
    """Source-derived HEART model, repeated original images and zero initial state.

    The reviewed original sparse matrix visits coefficients in increasing
    physical-column order. The saved compact columns preserve those same
    coefficients; sorted selection indices recover that traversal.
    """
    fixture = Path(fixture)
    require_active_subapertures(fixture)
    read = lambda name, shape: read_array(fixture / name, shape)
    pixels = read("calibrated_pixels.f32le", (7, 352, 352))
    origins = np.fromfile(fixture / "subaperture-origins.u32le", dtype="<u4").reshape(188, 2)
    slopes, _ = sensor_model(pixels, origins,
                             read("shack-hartmann-coordinates.f32le", (484, 2)),
                             read("thresholds.f32le", (188, 2)),
                             read("reference-slopes.f32le", (188, 2)), True)
    c = read("reconstructor.f32le", (221, 376))
    e = read("active-to-full-vdm.f32le", (277, 221))
    indices = read("full-to-active-vdm.f32le", (221, 277)).argmax(axis=1)
    scalars = read("scalars.f32le", (5,))
    fma = Fma()
    reconstructed = np.zeros((7, 221), np.float32)
    for column in range(0, 376, 2):
        reconstructed += fma(slopes[:, column, None], c[:, column],
                             slopes[:, column + 1, None] * c[:, column + 1])
    control, _, _ = controller_model(reconstructed[np.arange(frames) % 7], scalars, heart=True)
    physical = np.zeros((frames, 277), np.float32)
    for column in np.argsort(indices):
        rows = np.flatnonzero(e[:, column])
        physical[:, rows] += control[:, column, None] * e[rows, column]
    return np.clip(physical, scalars[3], scalars[4])


def acceptance_for_wire(fixture, expected, actual, frames, role, mode):
    """Bound future wire captures against a common equation reference.

    This accepts arrays of shape (frames, 277), or little-endian Float32 paths.
    The original seven source images repeat from frame zero with zero controller
    state and the unchanged fixture. role/mode identify evidence; they never
    select an empirical tolerance. This is arithmetic consistency only, with
    no assertion that wire data identifies internal feedback or reduction order.
    """
    fixture = Path(fixture)
    require_active_subapertures(fixture)
    if frames < 1:
        raise ValueError("frames must be positive")
    def read(name, shape):
        return read_array(fixture / name, shape)
    def wire(values):
        if isinstance(values, (str, Path)):
            return read_array(Path(values), (frames, 277))
        values = np.asarray(values)
        if values.shape != (frames, 277) or not np.isfinite(values).all():
            raise ValueError("wire commands must be finite with shape (frames, 277)")
        return values.astype(np.float64)
    expected, actual = wire(expected), wire(actual)
    pixels = read("calibrated_pixels.f32le", (7, 352, 352))
    raw = np.fromfile(fixture / "raw-frames.u16le", dtype="<u2").reshape(7, 352, 352)
    if not np.array_equal(raw.astype(np.float32) - read("background.f32le", (352, 352)), pixels):
        raise ValueError("fixture pixel calibration identity failed")
    origins = np.fromfile(fixture / "subaperture-origins.u32le", dtype="<u4").reshape(188, 2)
    if np.any(origins > 330):
        raise ValueError("invalid subaperture origins")
    coords = read("shack-hartmann-coordinates.f32le", (484, 2)).astype(float)
    thresholds = read("thresholds.f32le", (188, 2)).astype(float)
    refs = read("reference-slopes.f32le", (188, 2)).astype(float)
    c = read("reconstructor.f32le", (221, 376)).astype(float)
    e = read("active-to-full-vdm.f32le", (277, 221)).astype(float)
    t = read("full-to-active-vdm.f32le", (221, 277))
    indices = t.argmax(axis=1)
    if (np.count_nonzero(t) != 221 or len(set(indices)) != 221
            or not np.all(t[np.arange(221), indices] == 1)
            or not np.array_equal(e[indices], np.eye(221))):
        raise ValueError("controlled-coordinate mapping identity failed")
    for name, width in (("controller-to-vdm", 221), ("vdm-to-controller", 221),
                         ("vdm-to-pdm", 277), ("pdm-to-vdm", 277)):
        if not np.array_equal(read(name + ".f32le", (width, width)), np.eye(width)):
            raise ValueError("wire bounds require identity " + name)
    scalars = read("scalars.f32le", (5,))
    if not np.array_equal(scalars, np.array([-.3, .99, .99, -.8, .8], np.float32)):
        raise ValueError("wire bounds require unchanged Classic coefficients")
    g, p, a, lo, hi = scalars.astype(float)
    patches = np.stack([pixels[:, r:r+22, col:col+22].reshape(7, 484)
                        for r, col in origins], axis=1).astype(float)
    selected = np.where(patches >= thresholds[None, :, 0, None], patches, 0)
    flux = selected.sum(axis=2)
    flux_error = (gamma(484) + gamma(968, U64)) * np.abs(selected).sum(axis=2)
    flux_error = np.nextafter(flux_error / (1 - gamma(1000, U64)), np.inf)
    if np.any(flux - flux_error <= np.maximum(0, thresholds[None, :, 1])):
        raise ValueError("flux-threshold decision is ambiguous under arithmetic bounds")
    products = selected[:, :, :, None] * coords
    moment = products.sum(axis=2)
    moment_error = (gamma(968) + gamma(968, U64)) * np.abs(products).sum(axis=2)
    centroid = moment / flux[:, :, None]
    quotient_error = (moment_error + np.abs(centroid) * flux_error[:, :, None]) / (flux - flux_error)[:, :, None]
    slope_error = quotient_error + (gamma(3) + gamma(6, U64)) * (np.abs(centroid) + quotient_error + np.abs(refs))
    slope_error = np.nextafter(slope_error / (1 - gamma(1100, U64)), np.inf).reshape(7, 376)
    slopes = (centroid - refs).reshape(7, 376)
    residual = slopes @ c.T
    residual_magnitude = (np.abs(slopes) + slope_error) @ np.abs(c).T
    residual_error = slope_error @ np.abs(c).T + (gamma(752) + gamma(752, U64)) * residual_magnitude
    residual_error = np.nextafter(residual_error / (1 - gamma(800, U64)), np.inf)
    u = np.zeros(221)
    budget = np.zeros(221)
    physical, physical_budget, ambiguous = [], [], 0
    for frame in range(frames):
        r, br = residual[frame % 7], residual_error[frame % 7]
        magnitude = np.abs(u) + budget
        feedback_magnitude = np.maximum(magnitude - min(abs(lo), abs(hi)), 0)
        # At most eight roundings on any expanded controller contribution,
        # covering scalar, FMA, and separate subtraction organizations.
        local = (gamma(8) + gamma(8, U64)) * (p * (magnitude + a * feedback_magnitude) + abs(g) * (np.abs(r) + br))
        budget = np.nextafter((p * budget + abs(g) * br + local) / (1 - gamma(32, U64)), np.inf)
        u = p * (u - a * (u - np.clip(u, lo, hi))) + g * r
        projected = e @ u
        bp = np.abs(e) @ budget + (gamma(442) + gamma(442, U64)) * (np.abs(e) @ (np.abs(u) + budget))
        bp = np.nextafter(bp / (1 - gamma(500, U64)), np.inf)
        ambiguous += int(np.count_nonzero(((projected - bp <= lo) & (projected + bp >= lo))
                                         | ((projected - bp <= hi) & (projected + bp >= hi))))
        physical.append(np.clip(projected, lo, hi))
        physical_budget.append(bp)
    physical, physical_budget = np.array(physical), np.array(physical_budget)
    checks = {"actual_vs_equation_reference": within_bound(np.abs(actual - physical), physical_budget),
              "expected_vs_equation_reference": within_bound(np.abs(expected - physical), physical_budget),
              "cross_implementation": within_bound(np.abs(actual.astype(float) - expected.astype(float)), 2 * physical_budget)}
    in_range = bool(np.all((actual >= lo) & (actual <= hi)) and np.all((expected >= lo) & (expected <= hi)))
    classify = lambda q: np.where(q == lo, -1, np.where(q == hi, 1, 0))
    exact_model = None
    exact_model_passed = None
    if str(role).lower() == "heart":
        predicted = heart_wire_model(fixture, frames)
        captured_f32 = actual.astype(np.float32)
        exact_model = compare(predicted, captured_f32)
        exact_model_passed = exact_model["unequal_bits"] == 0 and np.array_equal(actual, captured_f32)
    return {"scope": "wire arithmetic consistency; HEART additionally has an exact source model; no physical-accuracy qualification",
            "exact_model": exact_model, "exact_model_passed": exact_model_passed,
            "role": role, "mode": mode, "frames": frames,
            "actual_commands_f32le_sha256": hashlib.sha256(np.asarray(actual, dtype="<f4").tobytes()).hexdigest(),
            "expected_commands_f32le_sha256": hashlib.sha256(np.asarray(expected, dtype="<f4").tobytes()).hexdigest(),
            "arithmetic_consistency_passed": in_range and all(item["passed"] for item in checks.values()),
            "historical_1e_minus_6": strict_gate(actual, expected), "checks": checks,
            "within_command_limits": in_range,
            "minimum_flux_threshold_margin": float(np.min(flux - flux_error - thresholds[None, :, 1])),
            "minimum_pixel_threshold_distance": float(np.min(np.abs(patches - thresholds[None, :, 0, None]))),
            "clipping_decisions_ambiguous_under_bound": ambiguous,
            "observed_clipping_classification_disagreements": int(np.count_nonzero(classify(actual) != classify(expected))),
            "application_accuracy": "not assessed: no application error budget supplied",
            "analyzer_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            "fixture_sha256": {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                               for path in sorted(fixture.iterdir())
                               if path.name in {"active-subapertures.u8", "calibrated_pixels.f32le", "raw-frames.u16le", "background.f32le",
                                                "subaperture-origins.u32le", "shack-hartmann-coordinates.f32le",
                                                "thresholds.f32le", "reference-slopes.f32le", "reconstructor.f32le",
                                                "active-to-full-vdm.f32le", "full-to-active-vdm.f32le",
                                                "controller-to-vdm.f32le", "vdm-to-controller.f32le",
                                                "vdm-to-pdm.f32le", "pdm-to-vdm.f32le", "scalars.f32le"}}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--heart-capture", type=Path, required=True)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--extrapolation", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    report = evaluate(args.evidence, args.heart_capture, args.corpus, args.extrapolation)
    content = json.dumps(report, indent=2, allow_nan=False) + "\n"
    if args.output:
        args.output.write_text(content)
    else:
        print(content, end="")
    raise SystemExit(0 if report["arithmetic_conformance_passed"] else 1)


if __name__ == "__main__":
    main()
