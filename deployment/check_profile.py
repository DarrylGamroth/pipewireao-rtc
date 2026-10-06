#!/usr/bin/env python3
"""Focused installed-profile qualification; no latency or rate measurements."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import signal
import time

import deploy


def qualify(args):
    original_control = deploy.control
    evidence = {"deployment": str(args.deployment.resolve()), "checks": {}}
    runner = deploy.Deployment(args)
    session = json.loads((runner.package / runner.spec["session"]).read_text())
    # A progressive parameter transaction may intentionally abandon an
    # in-flight publication unit. Exact replay tests the prepared graph;
    # control/adoption tests exercise mutations separately.
    exercise_updates = session["execution"] == "complete-frame"
    evidence["exercise_updates"] = exercise_updates
    graph = session["graphs"][0]
    graph_name = graph["node.name"]
    parameter = next(port for port in graph["ports"] if port.get("parameter"))
    matrix_path = deploy.substitute(runner.spec["environment"]["PIPEWIREAO_RTC_PARAMETER_RECONSTRUCTOR"],
                                   {"PACKAGE": str(runner.package)})
    control_node = "closed-loop-correction" if "classic" in runner.spec["name"] else "correction"
    if runner.spec["name"].startswith("revolt-copper-fgn-"):
        control_node = "control"
    control_gain = "-0.3" if "classic" in runner.spec["name"] else "0.01"
    reconstructor_node = "reconstruction" if "classic" in runner.spec["name"] else "reconstruct"
    began = None
    admission_checked = False
    parameter_changed = False

    def call(socket, argv, timeout=8):
        nonlocal admission_checked
        if argv == ["session-start"] and not admission_checked:
            admission_checked = True
            snapshots = []
            for _ in range(3):
                status = original_control(socket, ["status"])
                assert status["state"] == "Ready", status
                assert status["result"]["discarded_buffers"] == 0, status
                snapshots.append(status)
                time.sleep(args.hold_seconds / 3)
            evidence["checks"]["held_before_admission"] = snapshots
            if exercise_updates:
                changed = original_control(socket, ["properties-set", graph_name,
                    f"{control_node}:gain", "float", control_gain,
                    f"{control_node}:pole", "float", "0.99"])
                assert not changed["result"]["active_adoption_observed"], changed
                evidence["checks"]["stopped_property_submission"] = changed
        return original_control(socket, argv, timeout)

    original_check = runner.check

    def check():
        nonlocal began, parameter_changed
        original_check()
        if not runner.record["admitted"]:
            return
        if began is None:
            began = time.monotonic()
        status = original_control(runner.socket, ["status"])
        count = status["result"]["discarded_buffers"]
        if exercise_updates and count >= 1 and not parameter_changed and status["state"] == "Running":
            changed = original_control(runner.socket, ["parameter", graph_name, parameter["name"],
                "F32_LE", "x".join(map(str, parameter["shape"])), parameter["schema"], matrix_path])
            assert not changed["result"]["active_adoption_observed"], changed
            evidence["checks"]["running_reconstructor_submission"] = changed
            parameter_changed = True
        if count > args.frames:
            raise deploy.DeploymentError(f"unexpected command count {count} > {args.frames}")
        if count == args.frames:
            time.sleep(0.2)
            final = original_control(runner.socket, ["status"])
            assert final["result"]["discarded_buffers"] == args.frames, final
            evidence["checks"]["exact_commands"] = final
            evidence["checks"]["properties"] = original_control(runner.socket, ["properties", graph_name])
            evidence["checks"]["property_generation"] = original_control(runner.socket,
                ["property-generation", graph_name, control_node])
            evidence["checks"]["parameter_generation"] = original_control(runner.socket,
                ["parameter-generation", graph_name, reconstructor_node])
            for key in ("property_generation", "parameter_generation"):
                observed = evidence["checks"][key]["result"]
                assert observed["requested"] == observed["active"], observed
            evidence["checks"]["groups"] = original_control(runner.socket, ["groups"])
            # A finite owned FITS source can return the lifecycle to Ready
            # between queries. Stop only if needed; acknowledge an already-Ready
            # result instead of attributing it to a processing failure.
            latest = original_control(runner.socket, ["status"])
            if latest["state"] == "Running":
                try:
                    evidence["checks"]["session-stop"] = original_control(runner.socket, ["session-stop"])
                except deploy.DeploymentError:
                    assert original_control(runner.socket, ["status"])["state"] == "Ready"
            evidence["checks"]["reset"] = original_control(runner.socket, ["reset"])
            # Invalid requests reject without faulting or terminating the owner.
            try:
                original_control(runner.socket, ["not-a-command"])
            except deploy.DeploymentError:
                pass
            else:
                raise AssertionError("invalid command was accepted")
            assert original_control(runner.socket, ["status"])["state"] == "Ready"
            runner.stopping = True
        elif time.monotonic() - began > args.timeout:
            raise deploy.DeploymentError(f"only {count}/{args.frames} commands before functional timeout")

    deploy.control = call
    runner.check = check
    for signum in (signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, lambda _number, _frame: setattr(runner, "stopping", True))
    try:
        runner.run()
    finally:
        deploy.control = original_control
    assert not any(args.runtime.glob("run-*")), "owned runtime remains after shutdown"
    assert all(process.poll() is not None for _, process in runner.processes), "owned process survived"
    evidence["placement"] = runner.record["placement"]
    evidence["checks"]["shutdown_clean"] = True
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(evidence, indent=2) + "\n")
    print(f"QUALIFIED {runner.spec['name']} {args.frames} commands")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--deployment", type=Path, required=True)
    parser.add_argument("--fits", type=Path, required=True)
    parser.add_argument("--frames", type=int, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--runtime", type=Path, default=Path(f"/run/user/{deploy.os.getuid()}/rtc-check"))
    parser.add_argument("--pipewire-prefix", type=Path, default=Path("/opt/pipewireao"))
    parser.add_argument("--hold-seconds", type=float, default=0.6)
    parser.add_argument("--timeout", type=float, default=20)
    args = parser.parse_args()
    if args.frames < 1 or args.hold_seconds <= 0 or args.timeout <= 0:
        parser.error("frame count and durations must be positive")
    qualify(args)


if __name__ == "__main__":
    raise SystemExit(
        "Python live profile qualification is retired; use deployment/julia/deploy_cli.jl "
        "for deployment control (this focused check has no Julia counterpart).")
