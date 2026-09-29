#!/usr/bin/env python3
"""Gate unchanged HEART wfsSimulator before its first synchronized frame.

The caller supplies its normal wfsSimulator arguments and places this wrapper
under the requested source CPU/scheduler envelope. A separate native pacer
owns HEART's named synchronization semaphores. This wrapper verifies every
source and pacer thread before releasing the pacer. It is benchmark machinery,
outside the RTC processing graph.
"""

from __future__ import annotations

from decimal import Decimal, InvalidOperation
import hashlib
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import time

from lab_placement import (LaunchError, parse_cpu_list, parse_thread_policy,
                           snapshot_process)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def option(argv: list[str], name: str) -> str:
    require(argv.count(name) == 1, f"expected exactly one {name} argument")
    index = argv.index(name)
    require(index + 1 < len(argv), f"missing value for {name}")
    return argv[index + 1]


def wait_line(process: subprocess.Popen[str], expected: str,
              other: subprocess.Popen[str] | None, timeout_s: float) -> None:
    deadline = time.monotonic() + timeout_s
    assert process.stdout is not None
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"pacer exited before {expected}: {process.returncode}")
        if other is not None and other.poll() is not None:
            raise RuntimeError(f"wfsSimulator exited before {expected}: {other.returncode}")
        readable, _, _ = select.select([process.stdout], [], [], 0.1)
        if readable:
            line = process.stdout.readline().strip()
            require(line == expected, f"pacer reported {line!r}; expected {expected!r}")
            return
    raise RuntimeError(f"timed out waiting for pacer {expected}")


def verified_snapshot(pid: int, cpus: set[int], policy: tuple[str, int]) -> dict:
    snapshot = snapshot_process(pid)
    require(bool(snapshot["threads"]), f"process {pid} has no threads")
    for thread in snapshot["threads"]:
        observed = thread["scheduler"]
        require(set(thread["affinity"]) == cpus,
                f"thread {thread['tid']} has CPUs {thread['affinity_list']}; expected {sorted(cpus)}")
        require((observed["policy"], observed["priority"]) == policy,
                f"thread {thread['tid']} has scheduler {observed}; expected {policy}")
    return snapshot


def trigger_summary(path: Path, frames: int, rate_hz: int) -> dict:
    lines = path.read_text().splitlines()
    require(lines[0] == "frame,target_monotonic_ns,actual_monotonic_ns",
            "unexpected trigger schedule header")
    require(len(lines) == frames + 1, f"expected {frames} trigger records")
    targets: list[int] = []
    actual: list[int] = []
    for frame, line in enumerate(lines[1:]):
        fields = line.split(",")
        require(len(fields) == 3 and int(fields[0]) == frame,
                f"trigger record {frame} has wrong identity")
        targets.append(int(fields[1]))
        actual.append(int(fields[2]))
    release_ns = targets[0] - 1_000_000_000 // rate_hz
    require(all(target == release_ns + ((frame + 1) * 1_000_000_000) // rate_hz
                for frame, target in enumerate(targets)),
            "trigger targets do not match the declared rational rate")
    require(all(observed >= target for observed, target in zip(actual, targets)),
            "a trigger was posted before its scheduled target")
    require(all(b > a for a, b in zip(targets, targets[1:])),
            "trigger target times do not advance")
    require(all(b > a for a, b in zip(actual, actual[1:])),
            "actual trigger times do not advance")
    intervals = [b - a for a, b in zip(actual, actual[1:])]
    return {"count": frames, "rate_hz": rate_hz,
            "first_target_monotonic_ns": targets[0],
            "last_target_monotonic_ns": targets[-1],
            "max_absolute_lateness_ns": max(abs(a - t) for a, t in zip(actual, targets)),
            "first_actual_monotonic_ns": actual[0],
            "last_actual_monotonic_ns": actual[-1],
            "min_actual_interval_ns": min(intervals) if intervals else None,
            "max_actual_interval_ns": max(intervals) if intervals else None}


def main(argv: list[str]) -> int:
    real = Path(os.environ["PIPEWIREAO_RTC_WFS_REAL"]).resolve()
    pacer_path = Path(os.environ["PIPEWIREAO_RTC_WFS_PACER"]).resolve()
    report_path = Path(os.environ["PIPEWIREAO_RTC_WFS_GATE_REPORT"]).resolve()
    cpus = parse_cpu_list(os.environ["PIPEWIREAO_RTC_WFS_SOURCE_CPUS"])
    policy = parse_thread_policy(os.environ["PIPEWIREAO_RTC_WFS_SOURCE_POLICY"])
    require(real.is_file() and os.access(real, os.X_OK), f"real wfsSimulator is unavailable: {real}")
    require(pacer_path.is_file() and os.access(pacer_path, os.X_OK),
            f"native WFS pacer is unavailable: {pacer_path}")
    require(report_path.parent.is_dir(), f"gate report directory is absent: {report_path.parent}")
    require(not report_path.exists(), f"gate report already exists: {report_path}")
    require("-wfs" not in argv and "-sync" not in argv and "-trigger" not in argv,
            "caller must not supply WFS synchronization options")
    frames = int(option(argv, "-numFrames"))
    require(1 <= frames <= 1024, "gated source supports 1..1024 frames")
    try:
        period = Decimal(option(argv, "-period"))
    except InvalidOperation as error:
        raise RuntimeError("invalid WFS period") from error
    require(period.is_finite() and period > 0, "WFS period must be finite and positive")
    rate_hz = round(1 / period)
    require(1 <= rate_hz <= 10000 and abs(rate_hz * period - 1) < Decimal("0.000001"),
            "WFS period must describe an integer frame rate within 1 ppm")
    timeout_s = float(os.environ.get("PIPEWIREAO_RTC_WFS_GATE_TIMEOUT_S", "20"))
    require(timeout_s > 0, "gate timeout must be positive")
    trigger_csv = report_path.with_suffix(".triggers.csv")
    pacer_log = report_path.with_suffix(".pacer.log")
    report = {"qualified": False, "frames": frames, "requested_period_s": str(period),
              "rate_hz": rate_hz,
              "timing_qualification": "target rate and trigger sequence only; no lateness bound",
              "real_wfs_simulator": str(real), "real_wfs_simulator_sha256": sha256(real),
              "pacer": str(pacer_path), "pacer_sha256": sha256(pacer_path),
              "wrapper_sha256": sha256(Path(__file__)),
              "expected_source_cpus": sorted(cpus), "expected_policy": list(policy),
              "source_argv": [str(real), *argv, "-wfs", "1", "-sync", "1"],
              "trigger_csv": str(trigger_csv), "pacer_log": str(pacer_log)}
    source: subprocess.Popen[str] | None = None
    pacer: subprocess.Popen[str] | None = None

    def stop_child(child: subprocess.Popen[str] | None) -> None:
        if child is not None and child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()

    cleanup_started = False
    cancellation_seen = False
    launching_child = False

    def interrupted(_signum: int, _frame: object) -> None:
        nonlocal cancellation_seen
        if not cleanup_started and not cancellation_seen:
            cancellation_seen = True
            if not launching_child:
                raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    exit_code = 1
    try:
        with pacer_log.open("w") as log:
            launching_child = True
            pacer = subprocess.Popen([str(pacer_path), str(frames), str(rate_hz),
                                      str(trigger_csv)], stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=log, text=True,
                                     bufsize=1)
            launching_child = False
            if cancellation_seen:
                raise KeyboardInterrupt
            wait_line(pacer, "sem-created", None, timeout_s)
            launching_child = True
            source = subprocess.Popen(report["source_argv"], text=True)
            launching_child = False
            if cancellation_seen:
                raise KeyboardInterrupt
            wait_line(pacer, "sender-ready", source, timeout_s)
            report["before_release"] = {
                "wrapper": verified_snapshot(os.getpid(), cpus, policy),
                "source": verified_snapshot(source.pid, cpus, policy),
                "pacer": verified_snapshot(pacer.pid, cpus, policy),
            }
            require(pacer.poll() is None and source.poll() is None,
                    "source or pacer exited before release")
            report["release_monotonic_ns"] = time.monotonic_ns()
            assert pacer.stdin is not None
            pacer.stdin.write("\n")
            pacer.stdin.flush()
            deadline = time.monotonic() + frames / rate_hz + timeout_s
            while pacer.poll() is None and time.monotonic() < deadline:
                require(source.poll() in (None, 0),
                        "wfsSimulator failed before pacing ended")
                time.sleep(0.005)
            require(pacer.poll() is not None, "pacer did not finish its schedule")
            require(pacer.returncode == 0, f"pacer failed with status {pacer.returncode}")
            require(source.wait(timeout=timeout_s) == 0,
                    f"wfsSimulator failed with status {source.returncode}")
            report["pacer_exit_status"] = pacer.returncode
            report["source_exit_status"] = source.returncode
            report["trigger_schedule"] = trigger_summary(trigger_csv, frames, rate_hz)
            report["trigger_csv_sha256"] = sha256(trigger_csv)
            report["qualified"] = True
            exit_code = 0
    except (Exception, KeyboardInterrupt) as error:
        report["qualified"] = False
        report["error"] = str(error) or type(error).__name__
        print(f"gated WFS source failed: {error}", file=sys.stderr)
        exit_code = 1
    finally:
        cleanup_started = True
        for child in (source, pacer):
            try:
                stop_child(child)
            except Exception as error:
                report["qualified"] = False
                report["cleanup_error"] = str(error)
                exit_code = 1
        try:
            report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        except OSError as error:
            print(f"could not persist WFS gate report: {error}", file=sys.stderr)
            exit_code = 1
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
