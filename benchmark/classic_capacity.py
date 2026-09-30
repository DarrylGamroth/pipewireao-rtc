#!/usr/bin/env python3
"""Classify repeated finite Classic windows without inferring an unbounded maximum.

A tested rate passes only with enough distinct windows satisfying exact delivery,
the selected numerical policy, normal child exits, recorded RTC thread placement,
source mean rate within the configured tolerance. A separate deadline contract
adds zero first-packet-to-DM period misses. Underdriven, overdriven, incomplete, and unobserved source loads do
not count as RTC failures. Original numerical failures remain visible separately.

The 1% default concerns mean source pacing, not jitter or per-arrival deadlines.
The first tested failing rate above the highest passing rate is only a bound for
these recorded finite-window contracts; it is not an asymptotic capacity claim.
"""
from __future__ import annotations

import argparse
from collections import defaultdict
from decimal import Decimal
import hashlib
import json
import math
from pathlib import Path
import re
import struct

from classic_placement import check_loop
from classic_wire import open_evidence

WFS = struct.Struct("<4B8HIQII")


def finite_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def gate(value, explanation):
    return {"passed": value, "explanation": explanation}


def option(command, name, default=None):
    if name not in command:
        return default
    index = command.index(name)
    if index + 1 >= len(command):
        raise ValueError(f"missing value after {name}")
    return command[index + 1]


def source_pacing_from_packets(directory, frames):
    """Recover achieved WFS rate even when missing DM packets prevent latency analysis."""
    directory = Path(directory)
    path = directory / "wfs-packets.tsv"
    first = []
    previous = None
    count = 0
    with open_evidence(path, "rt") as source:
        for ordinal, line in enumerate(source):
            timestamp, _, packet = line.rstrip("\n").split("\t")
            header = bytes.fromhex(packet[:WFS.size * 2])
            if len(header) != WFS.size:
                raise ValueError(f"truncated WFS header at packet {ordinal + 1}: "
                                 f"{len(header)} bytes, expected {WFS.size}")
            decoded = WFS.unpack(header)
            expected = (ordinal // 32, ordinal % 32 + 1, 32)
            if (decoded[-2], decoded[10], decoded[11]) != expected:
                raise ValueError("WFS frame/packet order differs from complete Classic ingress")
            now = Decimal(timestamp)
            if not now.is_finite() or (previous is not None and now < previous):
                raise ValueError("WFS packet times are nonfinite or move backward")
            if ordinal % 32 == 0:
                first.append(now)
            previous = now
            count += 1
    if frames < 2 or count != frames * 32 or len(first) != frames or first[-1] <= first[0]:
        raise ValueError("incomplete or zero-duration WFS window")
    return {"achieved_source_rate_hz": float(Decimal(frames - 1) / (first[-1] - first[0])),
            "complete_source_window": True, "source": str(path)}


def load_run_evidence(run, requested):
    """Read existing artifacts only. Missing evidence stays explicit, never a pass."""
    directory = Path(run["directory"])
    evidence = {"sha256": {}, "read_errors": {}}
    for filename, key in (("numerical-summary.json", "numerical"),
                          ("arithmetic-acceptance.json", "arithmetic"),
                          ("physical-summary.json", "physical"),
                          ("placement-before.json", "placement_before"),
                          ("placement-after.json", "placement_after")):
        path = directory / filename
        if not path.is_file():
            continue
        try:
            content = path.read_bytes()
            evidence[key] = json.loads(content)
            evidence["sha256"][str(path)] = hashlib.sha256(content).hexdigest()
        except (OSError, ValueError) as error:
            evidence["read_errors"][filename] = str(error)
    report = run.get("report", {})
    if run.get("path") == "heart":
        path = directory / "runtime/config/host.cpu"
        # Prefer the exact copied configuration recorded by the runner.
        recorded = report.get("environment", {}).get("HRT_CPU_MACHINE_FILE")
        if recorded:
            path = Path(recorded)
        if path.is_file():
            content = path.read_bytes()
            evidence["heart_cpu_map"] = content.decode()
            evidence["sha256"][str(path)] = hashlib.sha256(content).hexdigest()
    rate = run.get("latency", {}).get("achieved_source_rate_hz")
    if finite_number(rate) and rate > 0:
        evidence["source_pacing"] = {"achieved_source_rate_hz": rate,
                                     "complete_source_window": True,
                                     "source": "campaign validated WFS/DM packet intervals"}
    else:
        try:
            frames = report.get("frames", requested.get("frames", 0))
            evidence["source_pacing"] = source_pacing_from_packets(directory, frames)
        except (OSError, ValueError, TypeError) as error:
            evidence["read_errors"]["source_pacing"] = str(error)
    return evidence


def numerical_gates(run, evidence):
    report = run.get("report", {})
    numerical = evidence.get("numerical", report.get("numerical", {}))
    historical = {"passed": numerical.get("qualified"),
                  "failed_values": numerical.get("failed_values"),
                  "maximum_absolute_error_um": numerical.get("max_absolute_error_um")}
    policy = option(run.get("command", []), "--numerical-acceptance", "strict")
    if policy == "strict":
        passed = historical["passed"]
        strength = "strict reference comparison"
    elif policy == "source-arithmetic":
        arithmetic = evidence.get("arithmetic", report.get("arithmetic_acceptance", {}))
        passed = arithmetic.get("arithmetic_consistency_passed")
        strength = "rounding-bound consistency"
        if run.get("path") == "heart":
            exact = arithmetic.get("exact_model_passed")
            passed = False if passed is False or exact is False else (True if passed is True and exact is True else None)
            strength = "exact HEART source model and rounding bounds"
    else:
        passed, strength = None, "unrecognized numerical policy"
    clips = numerical.get("clipping_decision_mismatches")
    if clips is None:
        passed = None if passed is not False else False
    elif clips != 0:
        passed = False
    feedback = report.get("final_constraint_feedback")
    if isinstance(feedback, dict) and feedback.get("qualified") is False:
        passed = False
    return ({"passed": passed, "policy": policy, "strength": strength,
             "clipping_classification_disagreements": clips,
             "application_accuracy": "not assessed"}, historical)


def placement_gate(run, evidence):
    report = run.get("report", {})
    expectations = []
    if run.get("path") == "heart":
        text = evidence.get("heart_cpu_map")
        if not text:
            return gate(None, "the copied HEART worker CPU map is unavailable")
        for name, cpu in re.findall(r"(?m)^([A-Za-z0-9.]+\.w)\s*=\s*\{\s*(\d+)\s*\}", text):
            expectations.append(("heart", name, int(cpu), 15))
    else:
        request = report.get("placement_request", {})
        for role, key, name in (("daemon", "daemon_loop_cpu", "rtc-data-loop"),
                                ("adapter", "adapter_loop_cpu", "data-loop.0"),
                                ("node", "node_loop_cpu", "data-loop.0")):
            cpu = request.get(key)
            if cpu is not None:
                expectations.append((role, name, cpu, request.get("fifo_priority")))
    if not expectations:
        return gate(None, "no explicit measured RTC loop placement contract")
    for phase in ("placement_before", "placement_after"):
        snapshots = evidence.get(phase)
        if not isinstance(snapshots, dict):
            return gate(None, f"{phase} snapshot is unavailable")
        for role, name, cpu, priority in expectations:
            snapshot = snapshots.get(role)
            if not isinstance(snapshot, dict) or snapshot.get("available") is not True:
                return gate(None, f"{phase}: {role} process observation unavailable")
            try:
                check_loop(snapshot, name, cpu, priority)
            except (KeyError, TypeError, RuntimeError) as error:
                return gate(False, f"{phase}: {error}")
    return gate(True, "requested RTC loop names, affinity, and FIFO priority match before and after; source/helper placement beyond those checks is not attested")


def normal_exit_gate(run):
    report = run.get("report", {})
    returns = report.get("process_returncodes")
    if returns is None:
        processes = [item for item in report.get("commands", []) if item.get("kind") == "process"]
        returns = [item.get("returncode") for item in processes]
    if not returns or any(code is None for code in returns):
        return gate(None, "complete child-process exit evidence is unavailable")
    return {"passed": all(code == 0 for code in returns), "child_returncodes": returns,
            "launcher_returncode": run.get("returncode"),
            "explanation": "child exits are checked separately because a numerical or delivery gate can make the launcher exit nonzero"}


def classify_window(run, requested, evidence, pacing_tolerance=0.01):
    if not finite_number(pacing_tolerance) or not 0 <= pacing_tolerance < 1:
        raise ValueError("pacing tolerance must be a fraction in [0, 1)")
    target = run.get("rate_hz")
    if not finite_number(target) or target <= 0:
        raise ValueError("requested rate must be positive and finite")
    report = run.get("report", {})
    frames = report.get("frames", requested.get("frames"))
    source = evidence.get("source_pacing", {})
    achieved = source.get("achieved_source_rate_hz")
    if source.get("complete_source_window") is not True or not finite_number(achieved) or achieved <= 0:
        pacing_status, pacing_passed = "unmeasured_or_incomplete", None
        deviation = None
    else:
        deviation = achieved / target - 1
        if achieved < target * (1 - pacing_tolerance):
            pacing_status, pacing_passed = "underdriven", False
        elif achieved > target * (1 + pacing_tolerance):
            pacing_status, pacing_passed = "overdriven", False
        else:
            pacing_status, pacing_passed = "within_average_tolerance", True
    pacing = {"passed": pacing_passed, "status": pacing_status, "requested_rate_hz": target,
              "achieved_source_rate_hz": achieved, "relative_average_deviation": deviation,
              "tolerance_fraction": pacing_tolerance, "source": source.get("source")}
    science, historical = numerical_gates(run, evidence)
    exits, placement = normal_exit_gate(run), placement_gate(run, evidence)
    exact = run.get("exact_wire_delivery")
    physical = evidence.get("physical", report.get("physical", {})).get("qualified")
    if physical is not None and exact is not None and physical != exact:
        exact_gate = gate(None, "campaign and physical artifact disagree")
    else:
        exact_gate = gate(physical if physical is not None else exact,
                          "ordered WFS/DM delivery and packet validation from the campaign")
    latency = run.get("latency", {})
    first = latency.get("all", {}).get("first_to_dm_us", {})
    misses = latency.get("deadline_exceeded_count")
    maximum = first.get("max")
    deadline = 1e6 / target
    complete_latency = (isinstance(frames, int) and frames > 1 and first.get("count") == frames
                        and isinstance(misses, int) and not isinstance(misses, bool) and 0 <= misses <= frames
                        and finite_number(maximum) and maximum >= 0)
    if complete_latency and ((misses == 0) != (maximum <= deadline)):
        complete_latency = False
    deadline_gate = {"passed": misses == 0 if complete_latency else None,
                     "first_to_dm_deadline_us": deadline, "misses": misses,
                     "maximum_first_to_dm_us": maximum, "frames_observed": first.get("count"),
                     "explanation": "all frames, including first use; first WFS packet to DM must not exceed one requested frame period"}
    operational = report.get("functional_wire_qualified") if run.get("path") == "heart" else report.get("qualified")
    gates = {"exact_wire_delivery": exact_gate, "science_acceptance": science,
             "normal_child_exit": exits, "rtc_placement": placement, "source_pacing": pacing,
             "first_to_dm_deadline": deadline_gate,
             "runner_functional_gate": gate(operational, "selected runner functional result; HEART's separate initial-state/full qualification remains unchanged")}
    prerequisites = (pacing_passed, exits["passed"], placement["passed"])
    def contract_status(required):
        if any(value is not True for value in prerequisites):
            return "excluded"
        if any(gates[key]["passed"] is False for key in required):
            return "failed"
        if all(gates[key]["passed"] is True for key in (*required, "runner_functional_gate")) and run.get("returncode") == 0:
            return "passed"
        return "unassessed"
    delivery_status = contract_status(("exact_wire_delivery", "science_acceptance"))
    status = contract_status(("exact_wire_delivery", "science_acceptance", "first_to_dm_deadline"))
    reasons = [name for name, item in gates.items() if item["passed"] is not True]
    if run.get("returncode") != 0:
        reasons.append("launcher_nonzero_exit")
    return {"directory": run.get("directory"), "repeat": run.get("repeat"), "frames": frames,
            "rate_hz": target, "readout_us": run.get("readout_us"), "status": status,
            "delivery_status": delivery_status, "deadline_status": status,
            "gates": gates, "reasons": reasons, "historical_1e_minus_6": historical,
            "artifact_sha256": evidence.get("sha256", {}), "evidence_read_errors": evidence.get("read_errors", {})}


def classify_manifest(manifest, evidence_by_directory, pacing_tolerance=0.01, minimum_windows=3):
    if not isinstance(minimum_windows, int) or isinstance(minimum_windows, bool) or minimum_windows < 2:
        raise ValueError("repeated-window classification requires at least two windows")
    requested = manifest.get("requested", {})
    series = defaultdict(lambda: defaultdict(list))
    for run in manifest.get("runs", []):
        path, directory = run.get("path"), run.get("directory")
        if not path or not directory:
            raise ValueError("every run needs a path and evidence directory")
        evidence = evidence_by_directory.get(directory, {})
        window = classify_window(run, requested, evidence, pacing_tolerance)
        # Reject accidental merging of different experiment configurations at one rate.
        report = run.get("report", {})
        window["conditions"] = {"frames": window["frames"], "readout_us": run.get("readout_us"),
                                "workers": report.get("row_workers", requested.get("workers", 0)),
                                "matrix_layout": report.get("matrix_layout", requested.get("layout", "shared")),
                                "placement_request": report.get("placement_request", report.get("placement")),
                                "numerical_policy": window["gates"]["science_acceptance"]["policy"]}
        series[path][window["rate_hz"]].append(window)
    output = []
    for path, rates in sorted(series.items()):
        classified_rates = []
        for rate, windows in sorted(rates.items()):
            distinct = {(item["directory"], item["repeat"]) for item in windows}
            duplicate = len(distinct) != len(windows) or len({item["directory"] for item in windows}) != len(windows) or len({item["repeat"] for item in windows}) != len(windows)
            conditions = {json.dumps(item["conditions"], sort_keys=True) for item in windows}
            contracts = {}
            for contract in ("delivery", "deadline"):
                key = contract + "_status"
                eligible = [item for item in windows if item[key] in ("passed", "failed")]
                if duplicate or len(conditions) != 1:
                    status = "incomparable_windows"
                elif len(eligible) < minimum_windows:
                    status = "insufficient_windows"
                elif any(item[key] == "failed" for item in eligible):
                    status = "failed"
                else:
                    status = "passed"
                contracts[contract] = {"status": status, "eligible_windows": len(eligible),
                                       "excluded_windows": sum(item[key] == "excluded" for item in windows),
                                       "unassessed_windows": sum(item[key] == "unassessed" for item in windows)}
            classified_rates.append({"rate_hz": rate, "status": contracts["deadline"]["status"],
                                     **contracts["deadline"], "contracts": contracts,
                                     "required_windows": minimum_windows,
                                     "duplicate_windows": duplicate, "windows": windows})
        bounds = {}
        for contract in ("delivery", "deadline"):
            passing = [item["rate_hz"] for item in classified_rates if item["contracts"][contract]["status"] == "passed"]
            failing = [item["rate_hz"] for item in classified_rates if item["contracts"][contract]["status"] == "failed"]
            highest = max(passing) if passing else None
            above = [rate for rate in failing if highest is None or rate > highest]
            bounds[contract] = {"highest_tested_passing_rate_hz": highest,
                               "first_tested_failure_upper_bound_hz": min(above) if above else None,
                               "lower_rate_failures_hz": [rate for rate in failing if highest is not None and rate < highest]}
        output.append({"path": path, "contracts": bounds,
                       "highest_tested_exact_delivery_rate_hz": bounds["delivery"]["highest_tested_passing_rate_hz"],
                       "highest_tested_deadline_clean_rate_hz": bounds["deadline"]["highest_tested_passing_rate_hz"],
                       "rates": classified_rates})
    return {"schema_version": 1, "scope": "finite recorded windows only; no unbounded maximum, physical-loop, or application-accuracy claim",
            "criteria": {"minimum_distinct_windows": minimum_windows,
                         "average_source_pacing_tolerance_fraction": pacing_tolerance,
                         "deadline": "first WFS packet to DM <= one requested frame period, for every recorded frame",
                         "failure_bound": "separate contracts: delivery/science failures; delivery/science/deadline failures; first higher tested rate with enough eligible windows",
                         "delivery": "exact wire plus selected science acceptance; lateness alone does not fail delivery",
                         "source_load": "underdrive, overdrive, and unknown pacing are excluded rather than counted as RTC failures",
                         "repetitions": "directories and repeat ordinals must be distinct; this does not establish statistical independence"},
            "series": output,
            "limitations": ["average pacing tolerance does not bound source jitter",
                            "a passing finite window does not establish loss-free indefinite operation",
                            "readout may change with requested rate; retain per-window conditions",
                            "infrastructure, child-exit, or placement failures do not establish an RTC capacity upper bound",
                            "original numerical failures remain separate from the selected arithmetic policy"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--pacing-tolerance", type=float, default=0.01,
                        help="fractional average source-rate tolerance; default 0.01 = 1%%")
    parser.add_argument("--minimum-windows", type=int, default=3)
    args = parser.parse_args()
    content = args.manifest.read_bytes()
    manifest = json.loads(content)
    evidence = {run["directory"]: load_run_evidence(run, manifest.get("requested", {}))
                for run in manifest.get("runs", [])}
    result = classify_manifest(manifest, evidence, args.pacing_tolerance, args.minimum_windows)
    result["manifest"] = str(args.manifest.resolve())
    result["manifest_sha256"] = hashlib.sha256(content).hexdigest()
    result["classifier_sha256"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    text = json.dumps(result, indent=2, allow_nan=False) + "\n"
    if args.output:
        args.output.write_text(text)
    else:
        print(text, end="")


if __name__ == "__main__":
    main()
