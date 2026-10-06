#!/usr/bin/env python3
"""Supervise one unchanged HEART controller; the external source owns ingress.

Command SUCCESS acknowledgements confirm command completion, not effective flag
readback or numerical qualification. Stop the source transport before reset or
shutdown: HEART's SHUTDOWN can emit a final zero/flat command.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import re
import signal
import socket
import subprocess
import sys
import tempfile
import time

MAX_REQUEST_BYTES = 16 * 1024
MAX_REPLY_BYTES = 64 * 1024
GMS_SECTIONS = {"clwcBlock": "CLWFC", "tfcBlock": "TFC"}
COMMAND_TIMEOUT = 5.0
START_TIMEOUT = 30.0
STOP_TIMEOUT = 5.0
RESET_TIMEOUT = 12.0
POLL_SECONDS = 0.005


def remaining_timeout(deadline, maximum):
    if deadline is None:
        return maximum
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError("HEART reset exceeded its absolute deadline")
    return min(maximum, remaining)


def write_json_atomic(path, value):
    payload = json.dumps(value, allow_nan=False).encode() + b"\n"
    if len(payload) > MAX_REPLY_BYTES:
        raise ValueError("response exceeds 64 KiB")
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(payload)
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def acknowledged(returncode, text):
    return returncode == 0 and "ack<0><ACCEPTED>" in text and "status<0><SUCCESS>" in text


def guard_port():
    # Reject an existing controller before starting a child or touching SHM.
    for family, address in ((socket.AF_INET, "0.0.0.0"), (socket.AF_INET6, "::")):
        with socket.socket(family, socket.SOCK_STREAM) as probe:
            probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            probe.bind((address, 5001))


def listener_ready(process):
    if process.poll() is not None:
        raise RuntimeError(f"HEART child exited with {process.returncode}")
    # Match the listening socket to this child's open descriptors. Never probe
    # by connecting: the HEART command server need not tolerate empty clients.
    descriptors = Path(f"/proc/{process.pid}/fd")
    sockets = set()
    try:
        for descriptor in descriptors.iterdir():
            try:
                link = os.readlink(descriptor)
                if link.startswith("socket:["):
                    sockets.add(link[8:-1])
            except FileNotFoundError:
                pass
    except FileNotFoundError:
        return False
    for table in (Path("/proc/net/tcp"), Path("/proc/net/tcp6")):
        for line in table.read_text().splitlines()[1:]:
            fields = line.split()
            if (len(fields) >= 10 and fields[3] == "0A"
                    and int(fields[1].rsplit(":", 1)[1], 16) == 5001
                    and fields[9] in sockets):
                return True
    return False


def read_requirements(path):
    with path.open("rb") as stream:
        payload = stream.read(MAX_REPLY_BYTES + 1)
    if len(payload) > MAX_REPLY_BYTES:
        raise ValueError("requirements exceeds 64 KiB")
    data = json.loads(payload)
    requirements = data.get("runtime_requirements") if isinstance(data, dict) else None
    if not isinstance(requirements, list):
        raise ValueError("requirements must contain runtime_requirements")
    flags = []
    blocks = {}
    for requirement in requirements:
        if not isinstance(requirement, dict):
            raise ValueError("runtime requirement must be an object")
        if "block" not in requirement:
            continue
        block = requirement["block"]
        if block not in GMS_SECTIONS or requirement.get("control") != "ENABLE_HRT_FLAGS":
            raise ValueError("unsupported HEART runtime requirement")
        values = requirement.get("flags")
        if block in blocks or not isinstance(values, dict) or not values:
            raise ValueError("missing or repeated HEART flag block")
        blocks[block] = values
        for field, value in values.items():
            if (not isinstance(field, str) or not field.startswith("enable")
                    or not field.isidentifier() or len(field) > 128
                    or type(value) is not int or value not in (0, 1)):
                raise ValueError("invalid HEART flag")
            flags.append((GMS_SECTIONS[block], field, value))
    # The selected matched Classic profile must actually produce the HO/DM
    # correction and clear controller state on entry to CORRECT.
    required = {"clwcBlock": {"enableClippingFeedback": 1, "enableNotClearingIntg": 0},
                "tfcBlock": {"enableInHoVect": 1, "enableOutDmErrs": 1}}
    for block, expected in required.items():
        if any(blocks.get(block, {}).get(field) != value for field, value in expected.items()):
            raise ValueError("requirements omit meaningful matched Classic correction flags")
    return flags


def thread_snapshot(pid):
    directory = Path(f"/proc/{pid}/task")
    before = {int(path.name) for path in directory.iterdir()}
    result = []
    for tid in sorted(before):
        task = directory / str(tid)
        result.append({"tid": tid, "name": (task / "comm").read_text().strip(),
                       "cpus": sorted(os.sched_getaffinity(tid)),
                       "policy": os.sched_getscheduler(tid),
                       "priority": os.sched_getparam(tid).sched_priority})
    after = {int(path.name) for path in directory.iterdir()}
    if before != after:
        raise RuntimeError("HEART thread set changed during placement observation")
    return result


def read_placement(path):
    if path is None:
        return None
    with path.open("rb") as stream:
        payload = stream.read(MAX_REPLY_BYTES + 1)
    if len(payload) > MAX_REPLY_BYTES:
        raise ValueError("placement exceeds 64 KiB")
    data = json.loads(payload)
    if not isinstance(data, dict) or set(data) - {"cpus", "workers", "allowed_priorities"}:
        raise ValueError("invalid HEART placement declaration")
    def valid_cpus(values):
        return (isinstance(values, list) and bool(values) and len(set(values)) == len(values)
                and all(type(cpu) is int and cpu >= 2 for cpu in values))
    if not valid_cpus(data.get("cpus")):
        raise ValueError("HEART placement CPUs must be distinct integers excluding 0 and 1")
    priorities = data.get("allowed_priorities", [5, 10, 15, 20])
    if (not isinstance(priorities, list) or not priorities
            or any(type(value) is not int or value not in (5, 10, 15, 20) for value in priorities)):
        raise ValueError("invalid HEART allowed FIFO priorities")
    data["allowed_priorities"] = priorities
    workers = data.get("workers")
    if not isinstance(workers, list):
        raise ValueError("HEART placement workers must be a list")
    names = set()
    for worker in workers:
        if (not isinstance(worker, dict) or set(worker) != {"name", "cpus", "policy", "priority"}
                or not isinstance(worker["name"], str) or not worker["name"]
                or len(worker["name"].encode()) > 15 or worker["name"] in names
                or not valid_cpus(worker["cpus"]) or not set(worker["cpus"]) <= set(data["cpus"])
                or type(worker["policy"]) is not int or type(worker["priority"]) is not int
                or (worker["policy"], worker["priority"]) not in
                   [(0, 0), *((1, value) for value in priorities)]):
            raise ValueError("invalid HEART worker placement")
        names.add(worker["name"])
    return data


def validate_placement(threads, declaration):
    envelope = set(declaration["cpus"])
    policies = {(0, 0), *((1, value) for value in declaration["allowed_priorities"])}
    for thread in threads:
        if not thread["cpus"] or not set(thread["cpus"]) <= envelope:
            raise RuntimeError(f"HEART thread {thread['name']} affinity exceeds declared CPUs")
        if (thread["policy"], thread["priority"]) not in policies:
            raise RuntimeError(f"HEART thread {thread['name']} scheduling policy/priority differs")
    for worker in declaration["workers"]:
        matches = [thread for thread in threads if thread["name"] == worker["name"]]
        if len(matches) != 1:
            raise RuntimeError(f"HEART worker {worker['name']} must match exactly one native thread")
        thread = matches[0]
        if (set(thread["cpus"]) != set(worker["cpus"])
                or thread["policy"] != worker["policy"] or thread["priority"] != worker["priority"]):
            raise RuntimeError(f"HEART worker {worker['name']} placement differs")


class HeartOwner:
    def __init__(self, options):
        self.options = options
        self.source_config_sha256 = hashlib.sha256(options.config.read_bytes()).hexdigest()
        self.flags = read_requirements(options.requirements)
        self.placement = read_placement(getattr(options, "placement", None))
        self.child = None
        self.child_log = None
        self.generation = 0
        self.last_id = 0
        self.last_payload = None
        self.last_reply = None
        self.stopping = False
        self.status_path = options.runtime / "heart-owner-status.json"

    def report(self, error=None):
        threads = []
        observation_error = None
        if self.child is not None and self.child.poll() is None:
            try:
                threads = thread_snapshot(self.child.pid)
            except (OSError, RuntimeError) as exception:
                observation_error = str(exception)
        write_json_atomic(self.status_path, {
            "version": 1, "owner_pid": os.getpid(),
            "child_pid": self.child.pid if self.child else None,
            "child_returncode": self.child.poll() if self.child else None,
            "generation": self.generation, "native_threads": threads,
            "placement_observation_error": observation_error,
            "placement_validated": self.placement is not None and error is None,
            "placement_declaration": self.placement,
            "source_config": str(self.options.config),
            "source_config_sha256": self.source_config_sha256,
            "rendered_config": str(self.options.runtime / "config/heart.yaml"),
            "state": "failed" if error else "paused", "sequence": 0,
            "completed": False, "error": error,
            "flag_verification": "command SUCCESS acknowledgements only; no effective readback"})

    def command(self, command, flag=None, required=True, deadline=None):
        if required and (self.stopping or self.options.quit_request.exists()):
            raise RuntimeError("HEART command interrupted by owner shutdown")
        argv = [str(self.options.client), "-cmdName", command,
                "-address", "127.0.0.1", "-port", "5001"]
        if flag is not None:
            section, field, value = flag
            argv += ["-configEnableHrtFlag", str(value), "-configEnableHrtFlagField", field,
                     "-configEnableHrtFlagSec", section]
        suffix = "-" + "-".join(map(str, flag)) if flag else ""
        log = self.options.runtime / f"command-{self.generation}-{command}{suffix}.log"
        # Output goes to a file so a malfunctioning client cannot exhaust RAM.
        with log.open("wb") as stream:
            result = subprocess.run(argv, cwd=self.options.runtime, stdout=stream,
                                    stderr=subprocess.STDOUT, timeout=remaining_timeout(deadline, COMMAND_TIMEOUT))
        with log.open("rb") as stream:
            stream.seek(max(0, log.stat().st_size - MAX_REPLY_BYTES))
            text = stream.read(MAX_REPLY_BYTES).decode(errors="replace")
        success = acknowledged(result.returncode, text)
        if required and not success:
            raise RuntimeError(f"HEART {command} did not acknowledge SUCCESS; see {log}")
        return success

    def start(self, deadline=None):
        remaining_timeout(deadline, START_TIMEOUT)
        guard_port()
        self.generation += 1
        self.child_log = (self.options.runtime / f"heart-{self.generation}.log").open("ab")
        env = os.environ.copy()
        env["HRT_CPU_MACHINE_FILE"] = str(self.options.runtime / "config/host.cpu")
        env["HRT_THREAD_MAP_FILE"] = str(self.options.runtime / "config/host.threads")
        self.child = subprocess.Popen([str(self.options.executable), "-shm", "-config",
                                       str(self.options.runtime / "config/heart.yaml")], cwd=self.options.runtime,
                                      env=env, stdin=subprocess.DEVNULL, stdout=self.child_log, stderr=subprocess.STDOUT)
        listener_deadline = time.monotonic() + remaining_timeout(deadline, START_TIMEOUT)
        while not listener_ready(self.child):
            if self.stopping or self.options.quit_request.exists():
                raise RuntimeError("HEART preparation interrupted")
            if time.monotonic() >= listener_deadline:
                raise TimeoutError("HEART command listener timed out")
            time.sleep(POLL_SECONDS)
        self.command("INIT", deadline=deadline)
        self.command("RUN", deadline=deadline)
        for flag in self.flags:
            self.command("ENABLE_HRT_FLAGS", flag, deadline=deadline)
        self.command("CORRECT", deadline=deadline)
        if self.child.poll() is not None:
            raise RuntimeError(f"HEART child exited with {self.child.returncode}")
        # Validate placement after all workers have entered their correcting
        # state, before readiness or reset acknowledgement is exposed.
        placement_deadline = time.monotonic() + remaining_timeout(deadline, 2.0)
        while True:
            try:
                threads = thread_snapshot(self.child.pid)
                break
            except (FileNotFoundError, ProcessLookupError, RuntimeError):
                if self.child.poll() is not None or time.monotonic() >= placement_deadline:
                    raise
                time.sleep(POLL_SECONDS)
        if self.placement is not None:
            validate_placement(threads, self.placement)
        remaining_timeout(deadline, COMMAND_TIMEOUT)
        self.report()
        remaining_timeout(deadline, COMMAND_TIMEOUT)

    def stop(self, deadline=None):
        try:
            if self.child is not None and self.child.poll() is None:
                try:
                    if listener_ready(self.child):
                        self.command("SHUTDOWN", required=False, deadline=deadline)
                except (OSError, RuntimeError, TimeoutError, subprocess.TimeoutExpired):
                    pass
                try:
                    self.child.wait(timeout=remaining_timeout(deadline, STOP_TIMEOUT))
                except subprocess.TimeoutExpired:
                    self.child.terminate()
                    try:
                        self.child.wait(timeout=remaining_timeout(deadline, STOP_TIMEOUT))
                    except subprocess.TimeoutExpired:
                        self.child.kill()
                        self.child.wait(timeout=remaining_timeout(deadline, STOP_TIMEOUT))
            elif self.child is not None:
                self.child.wait()
        except TimeoutError:
            # An exhausted reset budget permits only a final kill/reap window.
            if self.child is not None and self.child.poll() is None:
                self.child.kill()
                self.child.wait(timeout=1.0)
            raise
        finally:
            if self.child_log is not None:
                self.child_log.close()
                self.child_log = None

    def response(self, request_id, operation, error=None):
        return {"version": 1, "id": request_id, "operation": operation, "state": "paused",
                "sequence": 0, "completed": False, "ok": error is None, "error": error}

    def control(self, payload):
        request_id, operation = 0, "invalid"
        try:
            if len(payload) > MAX_REQUEST_BYTES:
                raise ValueError()
            request = json.loads(payload)
            if not isinstance(request, dict):
                raise ValueError()
        except (ValueError, UnicodeDecodeError):
            return self.response(request_id, operation, "invalid JSON request")
        raw_id, raw_operation = request.get("id"), request.get("operation")
        if type(raw_id) is int and 1 <= raw_id <= 2**63 - 1:
            request_id = raw_id
        if isinstance(raw_operation, str) and len(raw_operation.encode()) <= 32:
            operation = raw_operation
        if (set(request) != {"version", "id", "operation"} or type(request.get("version")) is not int
                or request["version"] != 1 or request_id == 0 or operation not in ("reset", "status")):
            return self.response(request_id, operation, "expected version 1, positive integer id and reset or status")
        if request_id <= self.last_id:
            return self.response(request_id, operation, "stale request id")
        self.last_id = request_id
        if operation == "reset":
            deadline = time.monotonic() + RESET_TIMEOUT
            try:
                self.stop(deadline=deadline)
                self.start(deadline=deadline)
            except Exception:
                # Reset failures are fatal; there must be no success reply or
                # live half-prepared replacement after the shared deadline.
                try:
                    self.stop(deadline=time.monotonic())
                except TimeoutError:
                    pass
                raise
        else:
            self.report()
        return self.response(request_id, operation)

    def run(self):
        self.start()
        write_json_atomic(self.options.prepared_event, {"version": 1, "state": "prepared", "sequence": 0})
        connected = False
        while not self.stopping and not self.options.quit_request.exists():
            if self.child.poll() is not None:
                raise RuntimeError(f"HEART child exited unexpectedly with {self.child.returncode}")
            if not connected and self.options.connect_request.exists():
                write_json_atomic(self.options.connect_reply, {"version": 1, "state": "connected", "sequence": 0})
                connected = True
            if self.options.control_request.is_file():
                with self.options.control_request.open("rb") as stream:
                    payload = stream.read(MAX_REQUEST_BYTES + 1)
                if payload != self.last_payload:
                    self.last_payload = payload
                    self.last_reply = self.control(payload)
                    write_json_atomic(self.options.control_reply, self.last_reply)
                # Identical files are cached, preventing repeated reset while
                # the supervisor waits for the matching acknowledgement.
            time.sleep(POLL_SECONDS)


def arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("executable", "client", "config", "requirements", "runtime", "prepared-event",
                 "connect-request", "connect-reply", "quit-request", "control-request", "control-reply",
                 "cpu-map", "thread-map"):
        parser.add_argument("--" + name, required=True, type=Path)
    parser.add_argument("--package", type=Path)
    parser.add_argument("--calibration-root", type=Path)
    parser.add_argument("--placement", type=Path)
    options = parser.parse_args(argv)
    if options.package is None:
        options.package = options.config.resolve().parent.parent
    for name in ("prepared_event", "connect_request", "connect_reply", "quit_request",
                 "control_request", "control_reply"):
        if getattr(options, name).is_symlink():
            raise ValueError(f"instance path is a symlink: {getattr(options, name)}")
    for name, value in vars(options).items():
        if value is not None:
            setattr(options, name, value.resolve())
    inputs = [options.executable, options.client, options.config, options.requirements,
              options.cpu_map, options.thread_map]
    outputs = [options.prepared_event, options.connect_request, options.connect_reply,
               options.quit_request, options.control_request, options.control_reply,
               options.runtime / "heart-owner-status.json"]
    reserved = {options.runtime / "config" / name for name in ("heart.yaml", "host.cpu", "host.threads")}
    if len(set(outputs)) != len(outputs) or set(inputs) & set(outputs) or set(outputs) & reserved:
        raise ValueError("input, marker, control and report paths must differ")
    for path in inputs:
        if not path.is_file():
            raise ValueError(f"required file is missing: {path}")
    for path in (options.executable, options.client):
        if not os.access(path, os.X_OK):
            raise ValueError(f"required executable is not executable: {path}")
    for path in outputs:
        if path.exists() or path.is_symlink():
            raise ValueError(f"instance path already exists: {path}")
    # A new runtime avoids clobbering another owner's files, logs or maps.
    options.runtime.mkdir(parents=True, exist_ok=False)
    (options.runtime / "config").mkdir()
    shutil.copy2(options.cpu_map, options.runtime / "config/host.cpu")
    shutil.copy2(options.thread_map, options.runtime / "config/host.threads")
    if options.calibration_root is not None:
        if not options.calibration_root.is_dir():
            raise ValueError("calibration root must be a directory")
        for source in sorted(options.calibration_root.iterdir()):
            destination = options.runtime / "config" / source.name
            if (not source.is_file() or source.resolve().parent != options.calibration_root
                    or destination.exists() or source.name == "heart.yaml"):
                raise ValueError(f"invalid or conflicting calibration file: {source}")
            destination.symlink_to(source.resolve())
    # HEART's native parser copies quoted scalar bytes without JSON escape
    # decoding. Relative calibration links avoid long installed paths.
    package = str(options.package)
    config = options.config.read_text()
    if "@PACKAGE@" in config:
        if any(character in ('"', "\\") or ord(character) < 32 or ord(character) == 127
               for character in package):
            raise ValueError("HEART package substitution cannot contain quote, backslash or control characters")
        config = config.replace("@PACKAGE@", package)
    for scalar in re.findall(r'"([^"\n]*)"', config):
        if len(scalar.encode()) >= 128:
            raise ValueError("HEART quoted configuration scalar must be shorter than 128 bytes")
    if re.search(r"@[A-Z][A-Z_]*@", config):
        raise ValueError("unresolved HEART configuration binding")
    (options.runtime / "config/heart.yaml").write_text(config)
    return options


def main(argv=None):
    owner = None
    try:
        owner = HeartOwner(arguments(argv))
        def terminate(_signum, _frame):
            owner.stopping = True
        signal.signal(signal.SIGTERM, terminate)
        signal.signal(signal.SIGINT, terminate)
        owner.run()
        return 0
    except Exception as error:
        if owner is not None:
            owner.options.prepared_event.unlink(missing_ok=True)
            owner.options.connect_reply.unlink(missing_ok=True)
            owner.report(str(error))
            write_json_atomic(owner.options.control_reply, owner.response(owner.last_id, "failure", str(error)))
        print(f"HEART owner failed: {error}", file=sys.stderr)
        return 1
    finally:
        if owner is not None:
            owner.stop()


if __name__ == "__main__":
    raise SystemExit(
        "Python live HEART ownership is retired; use deployment/julia/src/heart_owner.jl")
