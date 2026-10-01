#!/usr/bin/env python3
"""Summarize qualified windows from a Classic platform campaign manifest."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import sys


def _number(value, context):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValueError(f"{context} must be a finite number")
    return value


def _idle_delta(before, after):
    result = {"status": "available", "units": {"usage": "count", "time": "microseconds"},
              "cpus": {}}
    if not isinstance(before, dict) or not isinstance(after, dict) or \
            not isinstance(before.get("cpus"), dict) or not isinstance(after.get("cpus"), dict) or \
            not before["cpus"] or not after["cpus"]:
        return {**result, "status": "missing_snapshot"}
    before_cpus = before.get("cpus", {}) if isinstance(before, dict) else {}
    after_cpus = after.get("cpus", {}) if isinstance(after, dict) else {}
    for cpu in sorted(set(before_cpus) | set(after_cpus), key=str):
        cpu_result = {"states": {}}
        old_states = before_cpus.get(cpu, {}).get("idle", {})
        new_states = after_cpus.get(cpu, {}).get("idle", {})
        for state in sorted(set(old_states) | set(new_states)):
            if state not in old_states or state not in new_states:
                cpu_result["states"][state] = {"status": "invalid_state", "flags": ["missing_snapshot_state"]}
                result["status"] = "partial"
                continue
            delta = {}
            invalid = []
            old_name, new_name = old_states[state].get("name"), new_states[state].get("name")
            if old_name != new_name:
                invalid.append("state_name_changed")
            for counter in ("usage", "time"):
                try:
                    old_value = int(old_states[state][counter])
                    new_value = int(new_states[state][counter])
                except (KeyError, TypeError, ValueError):
                    invalid.append(f"missing_or_invalid_{counter}")
                    continue
                difference = new_value - old_value
                if old_value < 0 or new_value < 0:
                    invalid.append(f"negative_{counter}")
                elif difference < 0:
                    invalid.append(f"decreasing_{counter}")
                else:
                    delta[counter] = difference
            if invalid:
                cpu_result["states"][state] = {"status": "invalid_counter", "flags": invalid}
                result["status"] = "partial"
            else:
                cpu_result["states"][state] = {"status": "ok", **delta}
        result["cpus"][str(cpu)] = cpu_result
    return result


def _range(values):
    return {"min": min(values), "max": max(values), "windows": len(values)}


def _percentile_ranges(runs):
    windows = {}
    for window in ("all", "after_first_100"):
        metrics = {}
        window_counts = []
        for metric in ("terminal_to_dm_us", "first_to_dm_us"):
            values = {"p50": [], "p99": []}
            counts = []
            for run in runs:
                latency = run["latency"]
                window_stats = latency.get(window)
                stats = window_stats.get(metric) if isinstance(window_stats, dict) else None
                if window == "after_first_100" and stats is None:
                    all_stats = latency.get("all", {}).get(metric)
                    if isinstance(all_stats, dict) and all_stats.get("count", 0) <= 100:
                        continue
                    raise ValueError(f"qualified run lacks {window}.{metric} despite remaining samples")
                if not isinstance(stats, dict):
                    raise ValueError(f"qualified run lacks {window}.{metric}")
                count = stats.get("count")
                if isinstance(count, bool) or not isinstance(count, int) or count <= 0:
                    raise ValueError(f"{window}.{metric} needs a positive sample count")
                if window == "after_first_100":
                    all_count = latency["all"][metric]["count"]
                    if count != max(all_count - 100, 0):
                        raise ValueError(f"{window}.{metric} count does not match the all-frame extent")
                counts.append(count)
                if "p50" not in stats:
                    raise ValueError(f"{window}.{metric} lacks p50")
                values["p50"].append(_number(stats["p50"], f"{window}.{metric}.p50"))
                if "p99" in stats:
                    if count < 100:
                        raise ValueError(f"{window}.{metric} claims p99 with fewer than 100 samples")
                    values["p99"].append(_number(stats["p99"], f"{window}.{metric}.p99"))
            if counts:
                window_counts.append(counts)
            metrics[metric] = {percentile: (_range(samples) if samples else None)
                               for percentile, samples in values.items()}
        if window_counts and any(counts != window_counts[0] for counts in window_counts[1:]):
            raise ValueError(f"inconsistent first/terminal sample counts in {window}")
        windows[window] = metrics
    return windows


def summarize_manifest(manifest, manifest_path):
    if not isinstance(manifest, dict) or not isinstance(manifest.get("runs"), list):
        raise ValueError("manifest must contain a runs array")
    groups = {}
    for run in manifest["runs"]:
        if not isinstance(run, dict):
            raise ValueError("each run must be an object")
        try:
            key = (run["path"], int(run["rate_hz"]), run["mode"])
        except (KeyError, TypeError, ValueError) as error:
            raise ValueError("each run needs path, integer rate_hz, and mode") from error
        groups.setdefault(key, []).append(run)

    summarized = []
    for (path, rate, mode), runs in sorted(groups.items()):
        diagnostics = {run.get("diagnostic") for run in runs}
        if len(diagnostics) != 1 or not isinstance(next(iter(diagnostics)), bool):
            raise ValueError(f"inconsistent diagnostic flag in {path}/{rate}/{mode}")
        for run in runs:
            if not isinstance(run.get("comparison_qualified"), bool):
                raise ValueError("each run needs a boolean comparison_qualified flag")
            if not isinstance(run.get("errors"), list):
                raise ValueError("each run needs an errors array")
            if run["comparison_qualified"] and run["errors"]:
                raise ValueError("comparison_qualified run has nonempty errors")
        eligible = [run for run in runs
                    if run["comparison_qualified"] is True and not run["errors"]]
        for run in eligible:
            if not isinstance(run.get("latency"), dict):
                raise ValueError("comparison-qualified run lacks latency data")
            for flag in ("exact_wire_delivery", "science_passed"):
                if run.get(flag) is not True:
                    raise ValueError(f"comparison-qualified run failed {flag}")
            for flag in ("source_pacing_passed", "functional_passed", "normal_child_exit"):
                if run.get(flag) is not True:
                    raise ValueError(f"comparison-qualified run failed {flag}")
            if run.get("returncode") != 0:
                raise ValueError("comparison-qualified run needs returncode zero")
            latency = run["latency"]
            deadline = latency.get("deadline_exceeded_count")
            if isinstance(deadline, bool) or not isinstance(deadline, int) or deadline < 0:
                raise ValueError("qualified run needs a nonnegative deadline_exceeded_count")
        gates = {}
        for flag in ("exact_wire_delivery", "science_passed"):
            gates[flag] = {
                "passed": sum(run.get(flag) is True for run in runs),
                "failed": sum(run.get(flag) is False for run in runs),
                "unknown": sum(flag not in run or run.get(flag) is None for run in runs),
            }
        deadlines = {"windows": len(eligible), "frames": 0, "exceeded": 0}
        rates = []
        run_summaries = []
        for run in runs:
            sample = {"repeat": run.get("repeat"),
                      "comparison_qualified": run["comparison_qualified"],
                      "errors": run["errors"],
                      "exact_wire_delivery": run.get("exact_wire_delivery"),
                      "science_passed": run.get("science_passed")}
            if run in eligible:
                latency = run["latency"]
                first = latency.get("all", {}).get("first_to_dm_us", {})
                frames = first.get("count")
                if isinstance(frames, bool) or not isinstance(frames, int) or frames < 1:
                    raise ValueError("qualified run needs all-frame first_to_dm_us count")
                terminal = latency.get("all", {}).get("terminal_to_dm_us", {}).get("count")
                if terminal != frames:
                    raise ValueError("qualified run has inconsistent all-frame first/terminal counts")
                deadlines["frames"] += frames
                deadlines["exceeded"] += latency["deadline_exceeded_count"]
                achieved = latency.get("achieved_source_rate_hz")
                if achieved is not None:
                    rates.append(_number(achieved, "achieved_source_rate_hz"))
                sample["latency"] = latency
            if "before_ingress" in run or "after_capture" in run:
                if "before_ingress" not in run or "after_capture" not in run:
                    sample["idle_delta"] = {"status": "missing_snapshot", "cpus": {}}
                else:
                    sample["idle_delta"] = _idle_delta(run["before_ingress"], run["after_capture"])
            sample["command"] = run.get("command")
            sample["perf_command"] = run.get("perf_command")
            run_summaries.append(sample)
        summarized.append({
            "path": path, "rate_hz": rate, "mode": mode,
            "diagnostic": next(iter(diagnostics)),
            "counts": {"cases": len(runs), "passed": len(eligible),
                       "failed": len(runs) - len(eligible)},
            "percentile_ranges_across_per_window_values": _percentile_ranges(eligible),
            "achieved_source_rate_hz": _range(rates) if rates else None,
            "all_frame_deadline_counts": deadlines,
            "gate_assertions": gates,
            "runs": run_summaries,
        })

    manifest_path = Path(manifest_path).resolve()
    digest = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
    return {
        "schema": "classic-platform-summary/1",
        "input_manifest": {"path": str(manifest_path), "sha256": digest},
        "root_manifest_reference": {"path": str(manifest_path), "sha256": digest,
                                    "source_revisions": manifest.get("source_revisions"),
                                    "harness_revision": manifest.get("harness_revision"),
                                    "harness_sha256": manifest.get("harness_sha256"),
                                    "requested": manifest.get("requested")},
        "aggregation_policy": "eligible windows require comparison_qualified=true and errors=[]; ranges summarize per-window percentiles; no pooled percentiles",
        "groups": summarized,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    manifest = json.loads(args.manifest.read_text())
    result = summarize_manifest(manifest, args.manifest)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"output": str(args.output), "groups": len(result["groups"]),
                      "input_manifest_sha256": result["input_manifest"]["sha256"]}, sort_keys=True))


if __name__ == "__main__":
    main()
