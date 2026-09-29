#!/usr/bin/env python3
"""Validate and summarize paired latest/hold timing records."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
from pathlib import Path


BENCH_SLOW_SAMPLES = 2500
WARM_SLOW_SAMPLES = 500
HOLD_CYCLES = 10
FIELDS = ("path", "identity", "callback_count", "callback_ns", "queue_ns", "receipt_ns")


def percentile(values: list[int], fraction: float) -> int:
    ordered = sorted(values)
    return ordered[max(0, math.ceil(fraction * len(ordered)) - 1)]


def summary(values: list[int]) -> dict[str, int]:
    if not values or any(value < 0 for value in values):
        raise ValueError("latency distribution is empty or contains a negative interval")
    return {
        "count": len(values),
        "min": min(values),
        "p50": percentile(values, 0.50),
        "p90": percentile(values, 0.90),
        "p99": percentile(values, 0.99),
        "max": max(values),
    }


def intervals(values: list[int]) -> list[int]:
    return [later - earlier for earlier, later in zip(values, values[1:])]


def load_records(path: Path) -> dict[str, list[dict[str, int]]]:
    groups: dict[str, list[dict[str, int]]] = {"slow": [], "primary": [], "overhead": []}
    with path.open(newline="") as stream:
        reader = csv.DictReader(stream)
        if tuple(reader.fieldnames or ()) != FIELDS:
            raise ValueError(f"{path}: unexpected CSV header")
        for line, row in enumerate(reader, 2):
            kind = row.pop("path")
            if kind not in groups or set(row) != set(FIELDS[1:]):
                raise ValueError(f"{path}:{line}: unexpected record")
            try:
                record = {key: int(value) for key, value in row.items()}
            except (TypeError, ValueError) as error:
                raise ValueError(f"{path}:{line}: invalid integer") from error
            if any(value < 0 for value in record.values()):
                raise ValueError(f"{path}:{line}: negative timestamp or identity")
            groups[kind].append(record)
    return groups


def validate_and_summarize(path: Path) -> dict:
    groups = load_records(path)
    slow = groups["slow"]
    primary = groups["primary"]
    overhead = groups["overhead"]
    if len(slow) != BENCH_SLOW_SAMPLES or len(primary) != BENCH_SLOW_SAMPLES * HOLD_CYCLES:
        raise ValueError(f"{path}: missing or extra slow/primary records")
    if len(overhead) != 1000:
        raise ValueError(f"{path}: expected 1000 clock-overhead records")
    if slow[0]["identity"] != 15:
        raise ValueError(f"{path}: benchmark slow identities must start at 15")
    for kind, records, expected_step in (("slow", slow, HOLD_CYCLES),
                                          ("primary", primary, 1)):
        first_identity = records[0]["identity"]
        first_cycle = records[0]["callback_count"]
        for offset, record in enumerate(records):
            if record["identity"] != first_identity + offset:
                raise ValueError(f"{path}: noncontiguous {kind} identity at {offset}")
            if record["callback_count"] != first_cycle + offset * expected_step:
                raise ValueError(f"{path}: noncontiguous {kind} callback count at {offset}")
            if not (0 < record["callback_ns"] <= record["queue_ns"]
                    <= record["receipt_ns"]):
                raise ValueError(f"{path}: invalid {kind} timestamp order at {offset}")
        if any(delta <= 0 for delta in intervals([r["callback_ns"] for r in records])):
            raise ValueError(f"{path}: nonmonotonic {kind} callbacks")
    for record in overhead:
        if (record["identity"] != 0 or record["callback_count"] != 0
                or record["callback_ns"] != 0
                or not 0 < record["queue_ns"] <= record["receipt_ns"]):
            raise ValueError(f"{path}: invalid clock-overhead record")

    def phase(records: list[dict[str, int]], warm: int) -> dict:
        selected = records[warm:]
        callback = [r["callback_ns"] for r in selected]
        queue = [r["queue_ns"] for r in selected]
        return {
            "identity_first": selected[0]["identity"],
            "identity_last": selected[-1]["identity"],
            "queue_to_receipt_ns": summary([r["receipt_ns"] - r["queue_ns"] for r in selected]),
            "callback_to_queue_ns": summary([r["queue_ns"] - r["callback_ns"] for r in selected]),
            "callback_interval_ns": summary(intervals(callback)),
            "offer_interval_ns": summary(intervals(queue)),
            "achieved_callback_hz": (len(callback) - 1) * 1e9 / (callback[-1] - callback[0]),
            "achieved_offer_hz": (len(queue) - 1) * 1e9 / (queue[-1] - queue[0]),
        }

    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    return {
        "file": str(path.resolve()),
        "sha256": digest,
        "load": "single PipeWire Dummy Driver; driver-paced 1000 Hz primary and every-tenth-cycle slow offer",
        "clock": "CLOCK_MONOTONIC_RAW",
        "warmup_slow_identities": WARM_SLOW_SAMPLES,
        "warmup_primary_identities": WARM_SLOW_SAMPLES * HOLD_CYCLES,
        "slow": phase(slow, WARM_SLOW_SAMPLES),
        "primary": phase(primary, WARM_SLOW_SAMPLES * HOLD_CYCLES),
        "clock_two_reads_ns": summary([r["receipt_ns"] - r["queue_ns"] for r in overhead]),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("csv", nargs="+", type=Path, help="native or Julia fixture CSV")
    parser.add_argument("--output", type=Path, help="write report JSON to this path")
    args = parser.parse_args()
    report = {"runs": [validate_and_summarize(path) for path in args.csv]}
    rendered = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.write_text(rendered)
    else:
        print(rendered, end="")


if __name__ == "__main__":
    main()
