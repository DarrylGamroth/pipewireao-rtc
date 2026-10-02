#!/usr/bin/env python3
"""Kill the owned native HEART child before admission and check fault cleanup."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import signal
import time

import deploy


def check(args):
    if args.output.exists():
        raise deploy.DeploymentError("failure evidence output must be new")
    runner = deploy.Deployment(args)
    assert json.loads((runner.package / "provenance.json").read_text())["engine"] == "heart"
    original = deploy.control
    evidence = {"deployment": str(args.deployment.resolve()), "injected": False}

    def control(socket, argv, timeout=8, **kwargs):
        if argv == ["session-start"] and not evidence["injected"]:
            source = runner.source_control("status")
            assert source["state"] == "paused" and source["sequence"] == 0
            status = json.loads((runner.runtime / "heart/native/heart-owner-status.json").read_text())
            native = status["child_pid"]
            # The PID was reported by this launch's supervised owner. Confirm
            # its parent before sending the intentional test failure signal.
            owner = next(process for role, process in runner.processes if role == "heart")
            fields = Path(f"/proc/{native}/status").read_text().splitlines()
            assert int(next(line.split()[1] for line in fields if line.startswith("PPid:"))) == owner.pid
            evidence.update({"injected": True, "child_pid": native, "source_before_failure": source})
            os.kill(native, signal.SIGKILL)
            deadline = time.monotonic() + 5
            while owner.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            assert owner.poll() not in (None, 0), "native child death must fault its owner"
            runner.check_processes()
            raise AssertionError("supervisor did not detect required HEART owner death")
        return original(socket, argv, timeout, **kwargs)

    deploy.control = control
    try:
        try:
            runner.run()
        except deploy.DeploymentError as error:
            evidence["observed_error"] = str(error)
        else:
            raise AssertionError("required child death did not fail deployment")
        assert evidence["injected"] and not runner.record["admitted"]
        assert all(process.poll() is not None for _, process in runner.processes)
        assert not Path(f"/proc/{evidence['child_pid']}").exists(), "owned native child survived"
        assert not any(args.runtime.glob("run-*")), "owned runtime survived"
        evidence.update({"passed": True, "exit_codes": {
            role: process.returncode for role, process in runner.processes}, "final": runner.record})
    finally:
        deploy.control = original
        args.output.parent.mkdir(parents=True, exist_ok=True)
        deploy.atomic_record(args.output, evidence)
    return evidence


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--deployment", type=Path, required=True)
    parser.add_argument("--pipewire-prefix", type=Path, default=Path("/opt/pipewireao"))
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.fits = None
    check(args)
