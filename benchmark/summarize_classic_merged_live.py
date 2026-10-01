#!/usr/bin/env python3
"""Summarize repeated merged Classic platform campaigns without hiding failures."""
from __future__ import annotations

import argparse
from collections import defaultdict
import copy
import hashlib
import json
import math
from pathlib import Path
import sys

import classic_capacity


PATH_EXECUTION = {
    "heart": "unchanged progressive HEART stdWfs path",
    "fgn-frame": "Rust FGN complete-frame assembly and graph",
    "jfg-frame": "Julia JFG complete-frame assembly and graph",
    "fgn-row": "Rust FGN row-block publication and progressive graph",
    "jfg-row": "Julia JFG row-block publication and progressive graph",
}
REPORT_ARTIFACT_KEYS = {
    "report": "report.json",
    "physical": "physical-summary.json",
    "arithmetic": "arithmetic-acceptance.json",
}


def read_manifests(paths: list[Path], readout_fraction=None):
    if readout_fraction is not None and (not math.isfinite(readout_fraction) or not 0 < readout_fraction < .95):
        raise ValueError("readout fraction must be finite and between zero and .95")
    manifests = []
    seen_directories: dict[str, str] = {}
    ordinal_by_path_rate: defaultdict[tuple[str, int], int] = defaultdict(int)
    normalized_runs = []
    evidence_by_directory = {}

    for path in paths:
        path = path.resolve(strict=True)
        content = path.read_bytes()
        manifest = json.loads(content)
        if not isinstance(manifest, dict) or not isinstance(manifest.get("runs"), list):
            raise ValueError(f"{path}: expected an object with a runs array")
        requested = manifest.get("requested")
        if not isinstance(requested, dict):
            raise ValueError(f"{path}: requested campaign settings are missing")
        if requested.get("diagnostic") is not False:
            raise ValueError(f"{path}: instrumented/unknown diagnostic mode cannot be merged")
        modes = requested.get("modes")
        if modes != ["latency0"]:
            raise ValueError(f"{path}: only a latency0-only campaign is supported; got {modes!r}")

        manifest_ref = {
            "path": str(path),
            "sha256": hashlib.sha256(content).hexdigest(),
            "source_revisions": manifest.get("source_revisions"),
            "harness_revision": manifest.get("harness_revision"),
            "harness_sha256": manifest.get("harness_sha256"),
            "requested": requested,
        }
        manifests.append(manifest_ref)

        for source_run in manifest["runs"]:
            if not isinstance(source_run, dict):
                raise ValueError(f"{path}: each run must be an object")
            if source_run.get("diagnostic") is not False:
                raise ValueError(f"{path}: instrumented/unknown run cannot be merged")
            if source_run.get("mode") != "latency0":
                raise ValueError(f"{path}: off/nonzero/unknown QoS mode cannot be merged")
            qos = source_run.get("cpu_latency_request")
            if isinstance(qos, dict) and qos.get("requested_us") not in (None, 0):
                raise ValueError(f"{path}: nonzero CPU-latency QoS cannot be merged")

            directory = source_run.get("directory")
            if not isinstance(directory, str) or not directory:
                raise ValueError(f"{path}: run lacks a directory")
            canonical_directory = str(Path(directory).resolve())
            previous = seen_directories.get(canonical_directory)
            if previous is not None:
                raise ValueError(f"duplicate run directory {canonical_directory!r} in {previous} and {path}")
            seen_directories[canonical_directory] = str(path)

            path_name = source_run.get("path")
            rate = source_run.get("rate_hz")
            if path_name not in PATH_EXECUTION:
                raise ValueError(f"{path}: unsupported Classic path {path_name!r}")
            if not isinstance(rate, int) or isinstance(rate, bool) or rate <= 0:
                raise ValueError(f"{path}: run has invalid rate_hz {rate!r}")

            normalized = copy.deepcopy(source_run)
            for target, source in REPORT_ARTIFACT_KEYS.items():
                if target not in normalized and source in normalized:
                    normalized[target] = copy.deepcopy(normalized[source])
            original_repeat = source_run.get("repeat")
            key = (path_name, rate)
            ordinal_by_path_rate[key] += 1
            normalized["source_repeat"] = original_repeat
            normalized["source_manifest"] = str(path)
            normalized["source_manifest_sha256"] = manifest_ref["sha256"]
            normalized["repeat"] = ordinal_by_path_rate[key]
            normalized["directory"] = canonical_directory
            report = normalized.get("report", {})
            hashes = report.get("sha256", {})
            normalized["comparison_identity"] = {
                "source_revisions": manifest.get("source_revisions"),
                "harness_sha256": manifest.get("harness_sha256"),
                "input_and_binary_sha256": {
                    name: value for name, value in hashes.items()
                    if not Path(name).resolve().is_relative_to(Path(canonical_directory))
                },
                "parameter_sha256": report.get("parameter_sha256"),
                "numerical_policy": classic_capacity.option(normalized.get("command", []),
                                                           "--numerical-acceptance", "strict"),
                "runtime": report.get("pipewire_provenance"),
                "placement": report.get("placement_request", report.get("placement")),
                "workers": report.get("row_workers", requested.get("workers", 0)),
                "matrix_layout": report.get("matrix_layout", requested.get("layout", "shared")),
                "frames": report.get("frames", requested.get("frames")),
            }
            normalized_runs.append(normalized)
            evidence_by_directory[canonical_directory] = classic_capacity.load_run_evidence(
                normalized, requested
            )

    # Successful arithmetic reports attest the common fixture across backends.
    # A delivery failure may prevent that report from being produced: retain the
    # missing attestation, using the pre-ingress parameter/profile hashes for
    # within-path comparability rather than inventing a successful output check.
    fixture_maps = {
        json.dumps(run["arithmetic"]["fixture_sha256"], sort_keys=True)
        for run in normalized_runs if _zero_qos_gate(run)["passed"] is True
        and isinstance(run.get("arithmetic", {}).get("fixture_sha256"), dict)
        and run["arithmetic"]["fixture_sha256"]
    }
    if len(fixture_maps) > 1:
        raise ValueError("matched backends have incompatible scientific fixture hashes")

    # Capacity is a comparison of one receiver under a stated camera schedule.
    # Reject mixed identities before either percentile or rate aggregation.
    for path_name in PATH_EXECUTION:
        runs = [run for run in normalized_runs if run["path"] == path_name]
        admitted = [run for run in runs if _zero_qos_gate(run)["passed"] is True]
        identities = {json.dumps(run["comparison_identity"], sort_keys=True) for run in admitted}
        if len(identities) > 1:
            raise ValueError(f"{path_name}: incompatible source, binary, fixture or placement identities")
        readouts = {run.get("readout_us") for run in admitted}
        if readout_fraction is None:
            if len(readouts) > 1:
                raise ValueError(f"{path_name}: mixed readouts require an explicit readout-fraction contract")
        else:
            for run in admitted:
                expected = math.floor(1_000_000 * readout_fraction / run["rate_hz"])
                if run.get("readout_us") != expected:
                    raise ValueError(f"{path_name}/{run['rate_hz']}: readout differs from declared fraction")

    merged = {
        "requested": {"frames": None},
        "runs": normalized_runs,
        "source_manifests": manifests,
        "readout_contract": ({"kind": "fixed within each path"} if readout_fraction is None else
                             {"kind": "fraction of frame period", "fraction": readout_fraction,
                              "law": "readout_us = floor(1e6 * fraction / rate_hz)"}),
    }
    return merged, manifests, evidence_by_directory


def _finite(value, label):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValueError(f"{label} must be finite numeric data")
    return value


def _zero_qos_gate(run):
    qos = run.get("cpu_latency_request")
    if not isinstance(qos, dict):
        return {"passed": None, "explanation": "zero CPU-latency QoS admission was not recorded"}
    if qos.get("requested_us") != 0:
        return {"passed": False, "explanation": "run did not request zero CPU-latency QoS"}
    if qos.get("effective_during_us") != 0:
        return {"passed": False, "explanation": "zero CPU-latency QoS was not effective during capture"}
    return {"passed": True, "explanation": "requested and effective CPU-latency QoS were both zero"}


def _apply_qos_admission(classified, run_index):
    """Exclude a latency0 window whose zero-QoS admission is failed or unobserved."""
    for path_series in classified["series"]:
        for rate_series in path_series["rates"]:
            for window in rate_series["windows"]:
                run = run_index[(window["directory"], window["repeat"])]
                admission = _zero_qos_gate(run)
                window["gates"]["zero_qos_admission"] = admission
                if admission["passed"] is not True:
                    window["status_before_qos_admission"] = window["status"]
                    window["delivery_status_before_qos_admission"] = window["delivery_status"]
                    window["deadline_status_before_qos_admission"] = window["deadline_status"]
                    window["status"] = "excluded"
                    window["delivery_status"] = "excluded"
                    window["deadline_status"] = "excluded"
                    window["reasons"].append("zero_qos_admission")

            contracts = {}
            for contract in ("delivery", "deadline"):
                status_key = contract + "_status"
                eligible = [item for item in rate_series["windows"]
                            if item[status_key] in ("passed", "failed")]
                if rate_series["duplicate_windows"] or len({
                        json.dumps(item["conditions"], sort_keys=True)
                        for item in eligible
                }) > 1:
                    status = "incomparable_windows"
                elif len(eligible) < rate_series["required_windows"]:
                    status = "insufficient_windows"
                elif any(item[status_key] == "failed" for item in eligible):
                    status = "failed"
                else:
                    status = "passed"
                contracts[contract] = {
                    "status": status,
                    "eligible_windows": len(eligible),
                    "excluded_windows": sum(item[status_key] == "excluded"
                                            for item in rate_series["windows"]),
                    "unassessed_windows": sum(item[status_key] == "unassessed"
                                               for item in rate_series["windows"]),
                }
            rate_series["contracts"] = contracts
            rate_series["status"] = contracts["deadline"]["status"]
            rate_series["delivery_status"] = contracts["delivery"]["status"]
            rate_series["deadline_status"] = contracts["deadline"]["status"]
            rate_series["eligible_windows"] = contracts["deadline"]["eligible_windows"]
            rate_series["excluded_windows"] = contracts["deadline"]["excluded_windows"]
            rate_series["unassessed_windows"] = contracts["deadline"]["unassessed_windows"]

        bounds = {}
        for contract in ("delivery", "deadline"):
            passing = [item["rate_hz"] for item in path_series["rates"]
                       if item["contracts"][contract]["status"] == "passed"]
            failing = [item["rate_hz"] for item in path_series["rates"]
                       if item["contracts"][contract]["status"] == "failed"]
            highest = max(passing) if passing else None
            above = [rate for rate in failing if highest is None or rate > highest]
            bounds[contract] = {
                "highest_tested_passing_rate_hz": highest,
                "first_tested_failure_upper_bound_hz": min(above) if above else None,
                "lower_rate_failures_hz": [rate for rate in failing
                                           if highest is not None and rate < highest],
            }
        path_series["contracts"] = bounds
        path_series["highest_tested_exact_delivery_rate_hz"] = bounds["delivery"]["highest_tested_passing_rate_hz"]
        path_series["highest_tested_deadline_clean_rate_hz"] = bounds["deadline"]["highest_tested_passing_rate_hz"]


def _percentile_ranges(windows, run_index):
    result = {}
    for extent in ("all", "after_first_100"):
        extent_result = {}
        for metric in ("first_to_dm_us", "terminal_to_dm_us"):
            grouped = {"p50": [], "p99": []}
            sample_counts = []
            for item in windows:
                run = run_index[(item["directory"], item["repeat"])]
                stats_root = run.get("latency", {}).get(extent)
                stats = stats_root.get(metric) if isinstance(stats_root, dict) else None
                all_stats = run.get("latency", {}).get("all", {}).get(metric, {})
                if extent == "after_first_100" and stats is None:
                    if all_stats.get("count", 0) <= 100:
                        continue
                    raise ValueError(f"{item['path']}/{item['rate_hz']} lacks {extent}.{metric}")
                if not isinstance(stats, dict):
                    raise ValueError(f"{item['path']}/{item['rate_hz']} lacks {extent}.{metric}")
                count = stats.get("count")
                expected = all_stats.get("count")
                if not isinstance(count, int) or isinstance(count, bool) or count <= 0:
                    raise ValueError(f"{extent}.{metric} has invalid count")
                if extent == "after_first_100" and count != max(expected - 100, 0):
                    raise ValueError(f"{extent}.{metric} count does not match all-frame extent")
                sample_counts.append(count)
                if "p50" not in stats:
                    raise ValueError(f"{extent}.{metric} lacks p50")
                grouped["p50"].append(_finite(stats["p50"], f"{extent}.{metric}.p50"))
                if "p99" in stats:
                    if count < 100:
                        raise ValueError(f"{extent}.{metric} claims p99 with fewer than 100 samples")
                    grouped["p99"].append(_finite(stats["p99"], f"{extent}.{metric}.p99"))
            if sample_counts and len(set(sample_counts)) != 1:
                raise ValueError(f"inconsistent sample counts for {extent}.{metric}")
            extent_result[metric] = {
                name: ({"min": min(values), "max": max(values), "windows": len(values)} if values else None)
                for name, values in grouped.items()
            }
        result[extent] = extent_result
    return result


def _condition_record(run, requested):
    report = run.get("report", {})
    arithmetic = run.get("arithmetic", {})
    hashes = report.get("sha256", {}) if isinstance(report, dict) else {}
    fixture_hashes = arithmetic.get("fixture_sha256", {}) if isinstance(arithmetic, dict) else {}
    reconstructor_hashes = {
        source: {key: value for key, value in values.items()
                 if "reconstruct" in str(key).lower()}
        for source, values in (("report.sha256", hashes), ("arithmetic.fixture_sha256", fixture_hashes))
        if isinstance(values, dict)
    }
    known_reconstructor_hash = any(values for values in reconstructor_hashes.values())
    return {
        "mode": run.get("mode"),
        "cpu_latency_request": run.get("cpu_latency_request"),
        "fgn_root": requested.get("fgn_root"),
        "jfg_root": requested.get("jfg_root"),
        "reconstructor_hashes": reconstructor_hashes if known_reconstructor_hash else None,
        "reconstructor_hash_status": "recorded" if known_reconstructor_hash else "not identified in run hash maps",
        "report_hashes": hashes,
        "arithmetic_fixture_hashes": fixture_hashes,
        "requested_configuration": requested,
    }


def _artifact_references(directory):
    references = {}
    for name, filename in REPORT_ARTIFACT_KEYS.items():
        path = Path(directory) / filename
        reference = {"path": str(path), "present": path.is_file()}
        if path.is_file():
            reference["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
        references[name] = reference
    return references


def summarize(merged, manifests, evidence_by_directory, pacing_tolerance, minimum_windows):
    classified = classic_capacity.classify_manifest(
        merged, evidence_by_directory, pacing_tolerance, minimum_windows
    )
    run_index = {
        (run["directory"], run["repeat"]): run
        for run in merged["runs"]
    }
    _apply_qos_admission(classified, run_index)
    details = []
    for path_series in classified["series"]:
        path_name = path_series["path"]
        for rate_series in path_series["rates"]:
            for window in rate_series["windows"]:
                source_run = run_index[(window["directory"], window["repeat"])]
                details.append({
                    **window,
                    "path": path_name,
                    "rate_hz": window["rate_hz"],
                    "path_execution": PATH_EXECUTION[path_name],
                    "source_manifest": source_run["source_manifest"],
                    "source_manifest_sha256": source_run["source_manifest_sha256"],
                    "source_repeat": source_run.get("source_repeat"),
                    "repeat": source_run["repeat"],
                    "command": source_run.get("command"),
                    "run_errors": source_run.get("errors"),
                    "conditions": _condition_record(
                        source_run,
                        next(item["requested"] for item in manifests
                             if item["path"] == source_run["source_manifest"]),
                    ),
                    "capacity_conditions": window.get("conditions"),
                    "zero_qos_admission": window["gates"]["zero_qos_admission"],
                    "artifact_references": _artifact_references(source_run["directory"]),
                })

    groups = []
    group_keys = sorted({(run["path"], run["rate_hz"], run.get("readout_us"))
                         for run in merged["runs"]}, key=lambda value: (value[0], value[1], value[2] or 0))
    detail_by_group = defaultdict(list)
    for item in details:
        source = run_index[(item["directory"], item["repeat"])]
        detail_by_group[(item["path"], item["rate_hz"], source.get("readout_us"))].append(item)
    for path_name, rate, readout in group_keys:
        group = detail_by_group[(path_name, rate, readout)]
        eligible = [item for item in group if item["delivery_status"] == "passed"]
        exact = [item for item in group
                 if item["gates"]["exact_wire_delivery"]["passed"] is True
                 and item["gates"]["zero_qos_admission"]["passed"] is True
                 and isinstance(item.get("frames"), int) and item["frames"] > 0]
        groups.append({
            "path": path_name,
            "path_execution": PATH_EXECUTION[path_name],
            "rate_hz": rate,
            "readout_us": readout,
            "counts": {
                "windows": len(group),
                "delivery_qualified_windows": len(eligible),
                "exact_delivery_windows": len(exact),
                "proven_frames": sum(item["frames"] for item in exact),
                "proven_wfs_packets": sum(item["frames"] * 32 for item in exact),
                "proven_dm_commands": sum(item["frames"] for item in exact),
            },
            "percentile_ranges_across_delivery_qualified_window_values": _percentile_ranges(eligible, run_index),
            "windows": group,
        })

    classified["schema"] = "classic-merged-live-summary/1"
    classified["aggregation_policy"] = (
        "capacity gates classify every recorded window; percentile ranges use only delivery-qualified windows; "
        "ranges are across per-window percentiles, never pooled; exact packet/command counts include only windows "
        "whose exact wire-delivery and zero-QoS-admission gates passed"
    )
    classified["criteria"]["zero_cpu_latency_qos"] = (
        "a requested and effective value of zero is required for capacity eligibility; missing or ineffective "
        "admission is retained as an excluded window"
    )
    classified["path_execution"] = PATH_EXECUTION
    classified["source_manifests"] = manifests
    classified["readout_contract"] = merged["readout_contract"]
    classified["analyzer_sha256"] = {
        str(path): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in (Path(__file__), Path(classic_capacity.__file__),
                     Path(__file__).with_name("classic_wire.py"))
    }
    classified["groups"] = groups
    classified["window_records"] = details
    return classified


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifests", nargs="+", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pacing-tolerance", type=float, default=0.01)
    parser.add_argument("--minimum-windows", type=int, default=3)
    parser.add_argument("--readout-fraction", type=float,
                        help="explicit capacity camera law; otherwise require fixed readout per path")
    args = parser.parse_args(argv)
    merged, manifest_refs, evidence = read_manifests(args.manifests, args.readout_fraction)
    result = summarize(merged, manifest_refs, evidence, args.pacing_tolerance, args.minimum_windows)
    args.output.write_text(json.dumps(result, indent=2, allow_nan=False) + "\n")
    print(json.dumps({"output": str(args.output), "manifests": len(manifest_refs),
                      "windows": len(result["window_records"])}, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
