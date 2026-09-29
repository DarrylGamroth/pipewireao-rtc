#!/usr/bin/env python3
"""Fail-closed process-envelope launcher for RTC-ARCH-019 laboratory runs.

This tool starts one already-configured process under a CPU and scheduler
envelope.  The process creates its own threads and signals warmup by creating
``--ready-file``.  Only after every live thread is inspected does this tool
create ``--gate-file``.  It does not schedule graph work or alter host policy.

For a qualified run, the target must also create ``--finished-file`` after its
measured ingress ends, keep all threads alive, and wait for ``--release-file``.
The launcher takes and verifies the post-run thread snapshot before it creates
that release. The Copper baseline uses the read-only ``verify`` interface on
processes started by its existing runners.
"""

from __future__ import annotations

import argparse
from datetime import UTC, datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import socket
import subprocess
import sys
import time
from typing import Any


class LaunchError(RuntimeError):
    """A condition that must prevent frame ingress."""


ThreadPolicy = tuple[str, int]
SCHED_RESET_ON_FORK = getattr(os, "SCHED_RESET_ON_FORK", 0x40000000)
THREAD_PROFILE_ENV = "PIPEWIREAO_RTC_THREAD_PROFILE"


def now() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def parse_cpu_list(value: str) -> set[int]:
    """Parse Linux's comma-separated CPU-list form, without stride syntax."""
    if not value:
        raise argparse.ArgumentTypeError("CPU list must not be empty")
    cpus: set[int] = set()
    for item in value.split(","):
        if not item:
            raise argparse.ArgumentTypeError(f"invalid empty CPU-list item in {value!r}")
        try:
            if "-" in item:
                start_text, end_text = item.split("-", 1)
                start, end = int(start_text), int(end_text)
                if start < 0 or end < start:
                    raise ValueError
                cpus.update(range(start, end + 1))
            else:
                cpu = int(item)
                if cpu < 0:
                    raise ValueError
                cpus.add(cpu)
        except ValueError as error:
            raise argparse.ArgumentTypeError(f"invalid CPU-list item {item!r}") from error
    return cpus


def format_cpu_list(cpus: set[int]) -> str:
    """Return a canonical Linux CPU-list string."""
    ordered = sorted(cpus)
    ranges: list[str] = []
    index = 0
    while index < len(ordered):
        end = index
        while end + 1 < len(ordered) and ordered[end + 1] == ordered[end] + 1:
            end += 1
        ranges.append(str(ordered[index]) if end == index else f"{ordered[index]}-{ordered[end]}")
        index = end + 1
    return ",".join(ranges)


def parse_thread_policy(value: str) -> ThreadPolicy:
    if value == "other":
        return ("other", 0)
    kind, separator, priority_text = value.partition(":")
    if kind != "fifo" or not separator:
        raise argparse.ArgumentTypeError("thread policy must be other or fifo:PRIORITY")
    try:
        priority = int(priority_text)
    except ValueError as error:
        raise argparse.ArgumentTypeError(f"invalid FIFO priority in {value!r}") from error
    if not 1 <= priority <= 99:
        raise argparse.ArgumentTypeError("FIFO priority must be in 1..99")
    return ("fifo", priority)


def format_thread_policy(policy: ThreadPolicy) -> str:
    return policy[0] if policy[0] == "other" else f"{policy[0]}:{policy[1]}"


def parse_required_thread_policy(value: str) -> tuple[ThreadPolicy, int]:
    policy_text, separator, count_text = value.rpartition("=")
    if not separator:
        raise argparse.ArgumentTypeError("required thread policy must have the form POLICY=COUNT")
    policy = parse_thread_policy(policy_text)
    try:
        count = int(count_text)
    except ValueError as error:
        raise argparse.ArgumentTypeError(f"invalid required thread count in {value!r}") from error
    if count < 1:
        raise argparse.ArgumentTypeError("required thread count must be positive")
    return policy, count


def read_status(path: Path) -> dict[str, str]:
    fields: dict[str, str] = {}
    for line in path.read_text().splitlines():
        if ":" in line:
            key, value = line.split(":", 1)
            fields[key] = value.strip()
    return fields


def read_smaps_rollup(pid: int) -> dict[str, Any]:
    path = Path(f"/proc/{pid}/smaps_rollup")
    try:
        fields: dict[str, int] = {}
        for line in path.read_text().splitlines():
            parts = line.split()
            if len(parts) == 3 and parts[1].isdigit() and parts[2] == "kB":
                fields[parts[0].rstrip(":")] = int(parts[1])
        return {"available": True, "kilobytes": fields}
    except (FileNotFoundError, PermissionError, ProcessLookupError) as error:
        return {"available": False, "error": str(error)}


def scheduler_name(policy: int) -> str:
    policy &= ~SCHED_RESET_ON_FORK
    names = {
        os.SCHED_OTHER: "other",
        os.SCHED_FIFO: "fifo",
        os.SCHED_RR: "rr",
        getattr(os, "SCHED_BATCH", -1): "batch",
        getattr(os, "SCHED_IDLE", -1): "idle",
        getattr(os, "SCHED_DEADLINE", -1): "deadline",
    }
    return names.get(policy, f"unknown({policy})")


def scheduler_details(policy: int) -> tuple[str, bool]:
    """Split Linux's reset-on-fork flag from the scheduler class."""
    return scheduler_name(policy), bool(policy & SCHED_RESET_ON_FORK)


def inspect_thread(tid: int) -> dict[str, Any]:
    status = read_status(Path(f"/proc/{tid}/status"))
    allowed_text = status.get("Cpus_allowed_list")
    if allowed_text is None:
        raise LaunchError(f"thread {tid} has no Cpus_allowed_list in /proc status")
    try:
        affinity = parse_cpu_list(allowed_text)
        raw_policy = os.sched_getscheduler(tid)
        priority = os.sched_getparam(tid).sched_priority
    except (OSError, argparse.ArgumentTypeError) as error:
        raise LaunchError(f"cannot inspect thread {tid}: {error}") from error
    policy, reset_on_fork = scheduler_details(raw_policy)
    return {
        "tid": tid,
        "name": status.get("Name"),
        "state": status.get("State"),
        "affinity": sorted(affinity),
        "affinity_list": format_cpu_list(affinity),
        "scheduler": {
            "policy": policy,
            "priority": priority,
            "reset_on_fork": reset_on_fork,
        },
    }


def snapshot_process(pid: int) -> dict[str, Any]:
    """Capture a stable task set before the caller evaluates its placement."""
    task_dir = Path(f"/proc/{pid}/task")
    try:
        before = sorted(int(path.name) for path in task_dir.iterdir())
    except (FileNotFoundError, ProcessLookupError) as error:
        raise LaunchError(f"process {pid} is unavailable for placement inspection: {error}") from error

    threads: list[dict[str, Any]] = []
    try:
        for tid in before:
            thread = inspect_thread(tid)
            threads.append(thread)
        after = sorted(int(path.name) for path in task_dir.iterdir())
    except (FileNotFoundError, ProcessLookupError) as error:
        raise LaunchError(f"process {pid} changed during placement inspection: {error}") from error
    if before != after:
        raise LaunchError(f"process {pid} thread set changed during placement inspection: {before} -> {after}")

    process_status = read_status(Path(f"/proc/{pid}/status"))
    vm_lck = process_status.get("VmLck")
    return {
        "available": True,
        "captured_at": now(),
        "pid": pid,
        "thread_ids": before,
        "threads": threads,
        "status": {"vm_lck": vm_lck},
        "smaps_rollup": read_smaps_rollup(pid),
    }


def verify_snapshot(
    snapshot: dict[str, Any],
    declared_cpus: set[int],
    initial_policy: ThreadPolicy,
    allowed_policies: set[ThreadPolicy],
    required_policy_counts: dict[ThreadPolicy, int],
) -> None:
    """Reject a snapshot that does not satisfy the requested process envelope."""
    observed_policy_counts: dict[ThreadPolicy, int] = {}
    found_leader = False
    for thread in snapshot["threads"]:
        tid = thread["tid"]
        affinity = set(thread["affinity"])
        if not affinity <= declared_cpus:
            raise LaunchError(
                f"thread {tid} affinity {thread['affinity_list']} is outside declared CPUs "
                f"{format_cpu_list(declared_cpus)}"
            )
        scheduler = thread["scheduler"]
        thread_policy = (scheduler["policy"], scheduler["priority"])
        if tid == snapshot["pid"]:
            found_leader = True
            if thread_policy != initial_policy:
                raise LaunchError(
                    f"initial process thread {tid} scheduler is {format_thread_policy(thread_policy)}; "
                    f"leader policy requires {format_thread_policy(initial_policy)}"
                )
        if thread_policy not in allowed_policies:
            raise LaunchError(
                f"thread {tid} scheduler is {scheduler['policy']} priority {scheduler['priority']}; "
                f"allowed policies are {', '.join(sorted(format_thread_policy(item) for item in allowed_policies))}"
            )
        observed_policy_counts[thread_policy] = observed_policy_counts.get(thread_policy, 0) + 1
    if not found_leader:
        raise LaunchError(f"process leader {snapshot['pid']} was absent from its thread snapshot")
    for required_policy, required_count in required_policy_counts.items():
        observed_count = observed_policy_counts.get(required_policy, 0)
        if observed_count != required_count:
            raise LaunchError(
                f"observed {observed_count} threads with {format_thread_policy(required_policy)}; "
                f"required exactly {required_count}"
            )


def read_thread_profile(path: Path) -> dict[str, Any]:
    """Validate a host-specific thread contract before any process is released."""
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError) as error:
        raise LaunchError(f"cannot read thread profile {path}: {error}") from error
    if (not isinstance(data, dict) or set(data) != {"schema_version", "roles"}
            or type(data["schema_version"]) is not int or data["schema_version"] != 1):
        raise LaunchError(f"thread profile {path} must have schema_version 1 and roles")
    roles = data["roles"]
    if not isinstance(roles, dict) or not roles:
        raise LaunchError(f"thread profile {path} has no roles")
    for role, contract in roles.items():
        if not isinstance(role, str) or not role or not isinstance(contract, dict):
            raise LaunchError(f"thread profile {path} has an invalid role")
        required_keys = {"cpus", "leader_policy", "required_policy_counts", "required_thread_placements"}
        if set(contract) != required_keys:
            raise LaunchError(f"thread profile role {role} requires exactly {sorted(required_keys)}")
        try:
            if not isinstance(contract["cpus"], str) or not isinstance(contract["leader_policy"], str):
                raise ValueError("role CPUs and leader policy must be strings")
            cpus = parse_cpu_list(contract["cpus"])
            parse_thread_policy(contract["leader_policy"])
            policies = contract["required_policy_counts"]
            placements = contract["required_thread_placements"]
            if not isinstance(policies, dict) or not isinstance(placements, list):
                raise ValueError("policy counts must be an object and placements an array")
            for policy, count in policies.items():
                if not isinstance(policy, str):
                    raise ValueError("policy names must be strings")
                parse_thread_policy(policy)
                if type(count) is not int or count < 1:
                    raise ValueError("policy counts must be positive integers")
            seen: set[tuple[str, str]] = set()
            for placement in placements:
                if not isinstance(placement, dict) or set(placement) != {"policy", "cpus", "count"}:
                    raise ValueError("each placement requires policy, cpus, and count")
                if not isinstance(placement["policy"], str) or not isinstance(placement["cpus"], str):
                    raise ValueError("placement policy and CPUs must be strings")
                parse_thread_policy(placement["policy"])
                pinned = parse_cpu_list(placement["cpus"])
                if not pinned <= cpus:
                    raise ValueError("placement CPUs exceed the role CPU envelope")
                if type(placement["count"]) is not int or placement["count"] < 1:
                    raise ValueError("placement count must be a positive integer")
                key = (placement["policy"], format_cpu_list(pinned))
                if key in seen:
                    raise ValueError(f"duplicate placement {key}")
                seen.add(key)
        except (argparse.ArgumentTypeError, TypeError, ValueError) as error:
            raise LaunchError(f"invalid thread profile role {role}: {error}") from error
    return data


def verify_thread_profile(snapshot: dict[str, Any], role: str, requested_cpus: set[int],
                          leader_policy: ThreadPolicy, profile: dict[str, Any]) -> None:
    contract = profile["roles"].get(role)
    if contract is None:
        raise LaunchError(f"thread profile has no contract for role {role}")
    expected_cpus = parse_cpu_list(contract["cpus"])
    if requested_cpus != expected_cpus:
        raise LaunchError(f"role {role} requested CPUs {format_cpu_list(requested_cpus)}; "
                          f"profile requires {format_cpu_list(expected_cpus)}")
    expected_leader = parse_thread_policy(contract["leader_policy"])
    if leader_policy != expected_leader:
        raise LaunchError(f"role {role} requested leader policy {format_thread_policy(leader_policy)}; "
                          f"profile requires {format_thread_policy(expected_leader)}")
    threads = snapshot["threads"]
    for policy_text, count in contract["required_policy_counts"].items():
        policy = parse_thread_policy(policy_text)
        observed = sum((thread["scheduler"]["policy"], thread["scheduler"]["priority"]) == policy
                       for thread in threads)
        if observed != count:
            raise LaunchError(f"role {role} has {observed} {policy_text} threads; profile requires exactly {count}")
    for placement in contract["required_thread_placements"]:
        policy = parse_thread_policy(placement["policy"])
        cpus = parse_cpu_list(placement["cpus"])
        observed = sum((thread["scheduler"]["policy"], thread["scheduler"]["priority"]) == policy
                       and set(thread["affinity"]) == cpus for thread in threads)
        if observed != placement["count"]:
            raise LaunchError(f"role {role} has {observed} {placement['policy']} threads on "
                              f"{format_cpu_list(cpus)}; profile requires exactly {placement['count']}")


def unavailable_snapshot(pid: int, reason: str) -> dict[str, Any]:
    return {"available": False, "captured_at": now(), "pid": pid, "reason": reason}


def host_record() -> dict[str, Any]:
    online = Path("/sys/devices/system/cpu/online")
    return {
        "hostname": socket.gethostname(),
        "uname": list(platform.uname()),
        "python": sys.version,
        "launcher_affinity": sorted(os.sched_getaffinity(0)),
        "online_cpus": online.read_text().strip() if online.is_file() else None,
    }


def wrapper_argv(command: list[str], cpus: set[int], policy: str, priority: int) -> list[str]:
    # util-linux chrt takes its command immediately after the priority; unlike
    # taskset, it does not accept a ``--`` command separator.
    chrt = ["chrt", "--fifo", str(priority)] if policy == "fifo" else ["chrt", "--other", "0"]
    return ["taskset", "--cpu-list", format_cpu_list(cpus), *chrt, *command]


def wait_for_file(path: Path, process: subprocess.Popen[Any], timeout_seconds: float, stage: str) -> None:
    deadline = time.monotonic() + timeout_seconds
    while not path.exists():
        returncode = process.poll()
        if returncode is not None:
            raise LaunchError(f"process exited with status {returncode} before creating {stage} file")
        if time.monotonic() >= deadline:
            raise LaunchError(f"timed out waiting {timeout_seconds:g}s for {stage} file")
        time.sleep(0.01)


def terminate(process: subprocess.Popen[Any]) -> None:
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def write_record(path: Path, record: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")


def verify(args: argparse.Namespace) -> int:
    """Record and validate the placement of an already-running process."""
    output = args.output.resolve()
    record: dict[str, Any] = {
        "schema_version": 2,
        "profile": "RTC-ARCH-019 / RTC-DEV-019 process placement verification",
        "role": args.role,
        "requested": {
            "pid": args.pid,
            "cpus": sorted(args.cpus),
            "cpu_list": format_cpu_list(args.cpus),
            "leader_policy": format_thread_policy(args.initial_thread_policy),
            "allowed_thread_policies": [format_thread_policy(item) for item in args.allowed_thread_policies],
            "required_thread_policy_counts": {
                format_thread_policy(item): count for item, count in args.required_thread_policy_counts.items()
            },
        },
        "host": host_record(),
        "started_at": now(),
        "outcome": "failed",
    }
    try:
        profile_path = os.environ.get(THREAD_PROFILE_ENV)
        profile = None
        if profile_path:
            path = Path(profile_path).resolve()
            record["requested"]["thread_profile"] = str(path)
            profile = read_thread_profile(path)
            record["requested"]["thread_profile_sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
        snapshot = snapshot_process(args.pid)
        record["observed"] = snapshot
        verify_snapshot(snapshot, args.cpus, args.initial_thread_policy,
                        args.allowed_thread_policy_set, args.required_thread_policy_counts)
        if profile is not None:
            verify_thread_profile(snapshot, args.role, args.cpus, args.initial_thread_policy, profile)
        record["outcome"] = "verified"
        return 0
    except (LaunchError, OSError, ProcessLookupError) as error:
        record["error"] = str(error)
        if "observed" not in record:
            record["observed"] = unavailable_snapshot(args.pid, str(error))
        return 1
    finally:
        record["finished_at"] = now()
        write_record(output, record)


def run(args: argparse.Namespace) -> int:
    output = args.output.resolve()
    record: dict[str, Any] = {
        "schema_version": 2,
        "profile": "RTC-ARCH-019 / RTC-DEV-019 process envelope",
        "role": args.role,
        "requested": {
            "cpus": sorted(args.cpus),
            "cpu_list": format_cpu_list(args.cpus),
            "scheduler": {"policy": args.policy, "priority": args.priority},
            "allowed_thread_policies": [format_thread_policy(item) for item in args.allowed_thread_policies],
            "required_thread_policy_counts": {
                format_thread_policy(item): count for item, count in args.required_thread_policy_counts.items()
            },
            "qualified": args.qualified,
        },
        "paths": {
            "ready_file": str(args.ready_file),
            "gate_file": str(args.gate_file),
            "finished_file": str(args.finished_file) if args.finished_file else None,
            "release_file": str(args.release_file) if args.release_file else None,
            "output": str(output),
        },
        "command": {"argv": args.command, "cwd": os.getcwd()},
        "host": host_record(),
        "started_at": now(),
        "outcome": "failed",
    }
    process: subprocess.Popen[Any] | None = None
    gate_created = False
    try:
        signal_paths = {
            "ready": args.ready_file.resolve(),
            "gate": args.gate_file.resolve(),
        }
        if args.finished_file is not None:
            signal_paths["finished"] = args.finished_file.resolve()
            signal_paths["release"] = args.release_file.resolve()
        if len(set(signal_paths.values())) != len(signal_paths):
            raise LaunchError("ready, gate, finished, and release files must have distinct paths")
        if output in signal_paths.values():
            raise LaunchError("output path must differ from every handshake file")
        available = set(os.sched_getaffinity(0))
        unavailable = args.cpus - available
        if unavailable:
            raise LaunchError(
                f"declared CPUs {format_cpu_list(unavailable)} are unavailable to this launcher; "
                f"available CPUs are {format_cpu_list(available)}"
            )
        for stage, path in (("ready", args.ready_file), ("gate", args.gate_file),
                            ("finished", args.finished_file), ("release", args.release_file)):
            if path is not None and path.exists():
                raise LaunchError(f"{stage} file already exists before launch: {path}")

        wrapped = wrapper_argv(args.command, args.cpus, args.policy, args.priority)
        record["command"]["launcher_argv"] = wrapped
        process = subprocess.Popen(wrapped)
        record["process"] = {"pid": process.pid}

        wait_for_file(args.ready_file, process, args.ready_timeout_seconds, "ready")
        record["ready_at"] = now()

        before_gate = snapshot_process(process.pid)
        record["snapshots"] = {"before_gate": before_gate}
        verify_snapshot(before_gate, args.cpus, args.initial_thread_policy,
                        args.allowed_thread_policy_set, args.required_thread_policy_counts)
        try:
            args.gate_file.parent.mkdir(parents=True, exist_ok=True)
            with args.gate_file.open("x") as gate:
                gate.write("placement verified\n")
        except FileExistsError as error:
            raise LaunchError(f"gate file appeared before verification completed: {args.gate_file}") from error
        gate_created = True
        record["gate_created"] = True
        record["gate_at"] = now()

        if args.finished_file is not None:
            wait_for_file(args.finished_file, process, args.finished_timeout_seconds, "finished")
            record["finished_signal_at"] = now()
            after_run = snapshot_process(process.pid)
            record["snapshots"]["after_run"] = after_run
            verify_snapshot(after_run, args.cpus, args.initial_thread_policy,
                            args.allowed_thread_policy_set, args.required_thread_policy_counts)
            try:
                args.release_file.parent.mkdir(parents=True, exist_ok=True)
                with args.release_file.open("x") as release:
                    release.write("post-run placement verified\n")
            except FileExistsError as error:
                raise LaunchError(f"release file appeared before post-run verification completed: {args.release_file}") from error
            record["release_at"] = now()

        returncode = process.wait()
        record["process"]["returncode"] = returncode
        record["snapshots"]["after_exit"] = unavailable_snapshot(
            process.pid, "process exited and was reaped; /proc snapshot unavailable"
        )
        if returncode:
            raise LaunchError(f"process exited with status {returncode} after gate creation")
        record["outcome"] = "completed"
        return 0
    except (LaunchError, OSError, subprocess.SubprocessError) as error:
        record["error"] = str(error)
        if process is not None:
            if "snapshots" not in record:
                record["snapshots"] = {}
            if process.poll() is None:
                try:
                    record["snapshots"]["failure"] = snapshot_process(process.pid)
                except LaunchError as inspect_error:
                    record["snapshots"]["failure"] = unavailable_snapshot(process.pid, str(inspect_error))
                terminate(process)
            record["process"]["returncode"] = process.returncode
        record["gate_created"] = gate_created
        return 1
    finally:
        record["finished_at"] = now()
        write_record(output, record)


def inspect(args: argparse.Namespace) -> int:
    output = args.output.resolve()
    record: dict[str, Any] = {"schema_version": 1, "pid": args.pid, "host": host_record(), "captured_at": now()}
    try:
        # Inspection mode records facts without asserting a requested placement.
        task_dir = Path(f"/proc/{args.pid}/task")
        tids = sorted(int(path.name) for path in task_dir.iterdir())
        record["snapshot"] = {
            "available": True,
            "thread_ids": tids,
            "threads": [inspect_thread(tid) for tid in tids],
            "status": {"vm_lck": read_status(Path(f"/proc/{args.pid}/status")).get("VmLck")},
            "smaps_rollup": read_smaps_rollup(args.pid),
        }
        result = 0
    except (LaunchError, FileNotFoundError, ProcessLookupError, PermissionError, OSError) as error:
        record["snapshot"] = unavailable_snapshot(args.pid, str(error))
        record["error"] = str(error)
        result = 1
    write_record(output, record)
    return result


def configure_thread_policy_rules(
    args: argparse.Namespace, leader_policy: ThreadPolicy, argument_parser: argparse.ArgumentParser
) -> None:
    args.initial_thread_policy = leader_policy
    args.allowed_thread_policies = args.allowed_thread_policy or [leader_policy]
    if leader_policy not in args.allowed_thread_policies:
        args.allowed_thread_policies.append(leader_policy)
    args.allowed_thread_policy_set = set(args.allowed_thread_policies)
    required_pairs = args.required_thread_policy or []
    args.required_thread_policy_counts = dict(required_pairs)
    if len(args.required_thread_policy_counts) != len(required_pairs):
        argument_parser.error("each --required-thread-policy may appear only once")
    for required_policy in args.required_thread_policy_counts:
        if required_policy not in args.allowed_thread_policy_set:
            argument_parser.error("a required thread policy must also be permitted by --allowed-thread-policy")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    subcommands = result.add_subparsers(dest="subcommand", required=True)
    run_parser = subcommands.add_parser("run", help="launch, verify, then open one process gate")
    run_parser.add_argument("--role", required=True)
    run_parser.add_argument("--cpus", required=True, type=parse_cpu_list)
    run_parser.add_argument("--policy", choices=("other", "fifo"), required=True)
    run_parser.add_argument("--priority", type=int, help="SCHED_FIFO priority (1 through 99)")
    run_parser.add_argument("--allowed-thread-policy", action="append", type=parse_thread_policy,
                            help="permitted thread policy: other or fifo:PRIORITY; repeat as needed")
    run_parser.add_argument("--required-thread-policy", action="append", type=parse_required_thread_policy,
                            help="exact required count, POLICY=COUNT; for example fifo:20=1")
    run_parser.add_argument("--ready-file", type=Path, required=True)
    run_parser.add_argument("--gate-file", type=Path, required=True)
    run_parser.add_argument("--finished-file", type=Path,
                            help="target writes this after measured ingress, before post-run inspection")
    run_parser.add_argument("--release-file", type=Path,
                            help="launcher writes this after the live post-run inspection")
    run_parser.add_argument("--qualified", action="store_true",
                            help="require the finished/release post-run verification handshake")
    run_parser.add_argument("--output", type=Path, required=True)
    run_parser.add_argument("--ready-timeout-seconds", type=float, default=60.0)
    run_parser.add_argument("--finished-timeout-seconds", type=float, default=60.0)
    run_parser.add_argument("command", nargs=argparse.REMAINDER, metavar="COMMAND")
    verify_parser = subcommands.add_parser("verify", help="verify one already-running process without launching it")
    verify_parser.add_argument("--role", required=True)
    verify_parser.add_argument("--pid", type=int, required=True)
    verify_parser.add_argument("--cpus", required=True, type=parse_cpu_list)
    verify_parser.add_argument("--leader-policy", required=True, type=parse_thread_policy,
                               help="leader policy: other or fifo:PRIORITY")
    verify_parser.add_argument("--allowed-thread-policy", action="append", type=parse_thread_policy,
                               help="permitted thread policy: other or fifo:PRIORITY; repeat as needed")
    verify_parser.add_argument("--required-thread-policy", action="append", type=parse_required_thread_policy,
                               help="exact required count, POLICY=COUNT; for example fifo:20=1")
    verify_parser.add_argument("--output", type=Path, required=True)
    inspect_parser = subcommands.add_parser("inspect", help="capture current thread placement for one PID")
    inspect_parser.add_argument("--pid", type=int, required=True)
    inspect_parser.add_argument("--output", type=Path, required=True)
    return result


def main() -> int:
    argument_parser = parser()
    args = argument_parser.parse_args()
    if args.subcommand == "inspect":
        return inspect(args)
    if args.subcommand == "verify":
        configure_thread_policy_rules(args, args.leader_policy, argument_parser)
        return verify(args)
    if not args.command:
        argument_parser.error("run requires COMMAND after --")
    if args.ready_timeout_seconds <= 0:
        argument_parser.error("--ready-timeout-seconds must be positive")
    if args.finished_timeout_seconds <= 0:
        argument_parser.error("--finished-timeout-seconds must be positive")
    if args.policy == "fifo":
        if args.priority is None or not 1 <= args.priority <= 99:
            argument_parser.error("--policy fifo requires --priority in 1..99")
    elif args.priority is not None:
        argument_parser.error("--priority is valid only with --policy fifo")
    else:
        args.priority = 0
    configure_thread_policy_rules(args, (args.policy, args.priority), argument_parser)
    if (args.finished_file is None) != (args.release_file is None):
        argument_parser.error("--finished-file and --release-file must be used together")
    if args.qualified and args.finished_file is None:
        argument_parser.error("--qualified requires --finished-file and --release-file")
    return run(args)


if __name__ == "__main__":
    raise SystemExit(main())
