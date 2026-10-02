#!/usr/bin/env python3
"""Qualify finite installed AOS/HIL exchange and controls on a private core."""
from __future__ import annotations

import argparse
import array
import hashlib
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import shutil
import sys
import time

import deploy


def validate_report(report: dict, expected: int) -> None:
    if report["failure"] is not None or not report["completed"]:
        raise AssertionError(f"simulator did not complete: {report['failure']}")
    assert report["completed_frames"] == report["completed_commands"] == expected
    assert report["sequences"] == list(range(1, expected + 1))
    period = report["model_period_ns"]
    assert report["model_timestamps_ns"] == list(range(0, expected * period, period))
    assert 0 < report["exposure_ns"] <= period
    assert report["command"]["transport_to_plant_scale"] == 1e-6 or abs(
        report["command"]["transport_to_plant_scale"] - 1e-6) < 1e-13
    assert report["command"]["recorded_units"] == "metre OPD"
    assert report["frame"]["layout"] == "ROW_MAJOR"
    assert report["frame"]["element_type"] == "U16_LE"
    for descriptor, size in ((report["frame"], 2 * expected * report["frame"]["shape"][0] * report["frame"]["shape"][1]),
                             (report["command"], 4 * expected * 277)):
        data = Path(descriptor["file"]).read_bytes()
        assert len(data) == size
        assert hashlib.sha256(data).hexdigest() == descriptor["sha256"]
    commands = array.array("f", Path(report["command"]["file"]).read_bytes())
    if sys.byteorder != "little":
        commands.byteswap()
    # Validate finite values and the maintained +/-0.8 micrometre limiter.
    assert all(abs(value) <= (0.8 + report["command_limit_tolerance_um"]) * 1e-6 for value in commands)
    sources, received, latency = (report[key] for key in
        ("source_published_ns", "command_received_ns", "source_to_command_latency_ns"))
    assert len(sources) == len(received) == len(latency) == expected
    assert all(received[i] - sources[i] == latency[i] >= 0 for i in range(expected))
    assert all(sources[i] < sources[i + 1] for i in range(expected - 1))


def qualify(args) -> dict:
    evidence = {"deployment": str(args.deployment.resolve()), "checks": {}}
    runner = deploy.Deployment(args)
    if runner.source_owner is None:
        raise deploy.DeploymentError("qualification requires an AOS/HIL source-owner profile")
    target = json.loads((runner.package / "provenance.json").read_text())["hil"]["frames"]
    original_control, original_check = deploy.control, runner.check
    original_killpg = deploy.os.killpg
    began, iteration, admission_checked = None, 1, False
    checking = False
    output = args.output.resolve()
    if output.exists():
        raise deploy.DeploymentError("evidence output must be new")
    output.mkdir(parents=True)
    evidence["cleanup_signals"] = []

    def track_signal(pid, number):
        role = next((role for role, process in runner.processes if process.pid == pid), None)
        evidence["cleanup_signals"].append({"pid": pid, "role": role, "signal": int(number)})
        return original_killpg(pid, number)

    def call(socket, argv, timeout=8, **kwargs):
        nonlocal admission_checked
        if argv == ["session-start"] and not admission_checked:
            source = runner.source_control("status")
            assert source["state"] == "paused" and source["sequence"] == 0 and not source["completed"]
            ready = original_control(socket, ["status"])
            assert ready["state"] == "Ready"
            time.sleep(args.hold_seconds)
            held = runner.source_control("status")
            assert held["state"] == "paused" and held["sequence"] == 0
            evidence["checks"]["held_before_admission"] = {"source": held, "rtc": ready}
            admission_checked = True
        return original_control(socket, argv, timeout, **kwargs)

    def operator(argv, *, rejected=False):
        # The supervisor serves the public broker on this thread. Keep only
        # the test client on another thread while exercising the actual socket.
        with ThreadPoolExecutor(max_workers=1) as clients:
            pending = clients.submit(original_control, runner.socket, argv,
                                     timeout=48, allow_rejection=True)
            while not pending.done():
                runner.serve_control()
            reply = pending.result()
        assert reply["ok"] == (not rejected), reply
        return reply

    def qualify_batch():
        nonlocal began, iteration
        original_check()
        if not runner.record["admitted"]:
            return
        if began is None:
            began = time.monotonic()
        source = runner.source_control("status")
        if not source["completed"]:
            if iteration == 1 and source["sequence"] >= 1 and "mid_batch_pause" not in evidence["checks"]:
                evidence["checks"]["mid_batch_pause"] = operator(["session-stop"])
                held = runner.source_control("status")
                assert held["state"] == "paused" and not held["completed"]
                time.sleep(args.hold_seconds)
                still = runner.source_control("status")
                assert still["sequence"] == held["sequence"] and still["state"] == "paused"
                evidence["checks"]["mid_batch_held"] = still
                evidence["checks"]["mid_batch_resume"] = operator(["session-start"])
            if time.monotonic() - began > args.timeout:
                raise deploy.DeploymentError("finite HIL batch did not complete before qualification timeout")
            return
        report = json.loads((runner.runtime / "simulator-result.json").read_text())
        validate_report(report, target)
        destination = output / f"batch-{iteration}"
        destination.mkdir()
        for name in ("simulator-result.json", "simulator-result.frames.u16le", "simulator-result.commands.f32le"):
            shutil.copy2(runner.runtime / name, destination / name)
        for descriptor in (report["frame"], report["command"]):
            descriptor["runtime_file"] = descriptor["file"]
            descriptor["file"] = str(destination / Path(descriptor["file"]).name)
        deploy.atomic_record(destination / "simulator-result.json", report)
        validate_report(report, target)
        evidence["checks"][f"batch-{iteration}"] = report
        if iteration == 1:
            evidence["checks"]["reset_while_running"] = operator(["reset"], rejected=True)
            assert operator(["status"])["state"] == "Running"
            evidence["checks"]["stop"] = operator(["session-stop"])
            assert operator(["status"])["state"] == "Ready"
            evidence["checks"]["completed_start_rejected"] = operator(["session-start"], rejected=True)
            evidence["checks"]["invalid_request"] = operator(["not-a-command"], rejected=True)
            assert operator(["status"])["state"] == "Ready"
            evidence["checks"]["reset"] = operator(["reset"])
            reset = runner.source_control("status")
            assert reset["state"] == "paused" and reset["sequence"] == 0 and not reset["completed"]
            evidence["checks"]["reset_source"] = reset
            evidence["checks"]["restart"] = operator(["session-start"])
            iteration = 2
            began = time.monotonic()
        else:
            evidence["checks"]["quit"] = operator(["quit"])
            evidence["placement"] = runner.record["placement"]
            runner.stopping = True

    def check():
        nonlocal checking
        if checking:
            original_check()
            return
        checking = True
        try:
            qualify_batch()
        finally:
            checking = False

    deploy.control, runner.check, deploy.os.killpg = call, check, track_signal
    try:
        runner.run()
        required = {"held_before_admission", "batch-1", "batch-2",
                    "reset_while_running", "stop", "completed_start_rejected",
                    "invalid_request", "reset", "reset_source", "restart", "quit",
                    "mid_batch_pause", "mid_batch_held", "mid_batch_resume"}
        assert required <= evidence["checks"].keys(), "qualification ended before all checks completed"
        assert iteration == 2 and runner.native_shutdown, "acknowledged final quit missing"
        assert all(process.poll() is not None for _, process in runner.processes)
        evidence["exit_codes"] = {role: process.returncode for role, process in runner.processes}
        assert all(process.returncode == 0 for role, process in runner.processes if role != "core"), \
            f"owner required forced or unsuccessful shutdown: {evidence['exit_codes']}"
        assert all(item["role"] == "core" for item in evidence["cleanup_signals"]), \
            f"owner required shutdown escalation: {evidence['cleanup_signals']}"
        assert not any(args.runtime.glob("run-*")), "owned runtime survived cleanup"
        evidence["checks"]["shutdown_clean"] = True
        evidence["passed"] = True
    finally:
        deploy.control = original_control
        deploy.os.killpg = original_killpg
        evidence["final"] = runner.record
        deploy.atomic_record(output / "result.json", evidence)
    return evidence


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--deployment", type=Path, required=True)
    parser.add_argument("--pipewire-prefix", type=Path, default=Path("/opt/pipewireao"))
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--hold-seconds", type=float, default=0.2)
    parser.add_argument("--timeout", type=float, default=120)
    args = parser.parse_args()
    args.fits = None
    qualify(args)


if __name__ == "__main__":
    main()
