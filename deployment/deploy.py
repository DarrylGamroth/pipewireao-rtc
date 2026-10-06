#!/usr/bin/env python3
"""Install and supervise existing non-actuating PipeWireAO RTC configurations."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import time
import uuid

from placement import DeploymentError, cpu_set, credentials, snapshot

MAX_CONFIG_BYTES = 16 * 1024 * 1024
MAX_REPLY_BYTES = 64 * 1024
MAX_REQUEST_BYTES = 16 * 1024
SOURCE_TIMEOUT = 8
BROKER_IO_TIMEOUT = 1
REQUIRED_KEYS = {"version", "name", "session", "core", "client", "placement",
                 "owners", "environment", "artifacts", "cpu-latency-us"}


def digest(path: Path) -> str:
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def installed_paths(prefix: Path) -> dict[str, Path]:
    candidates = [prefix / "lib", prefix / "lib64", *(prefix / "lib").glob("*")]
    libraries = [path for path in candidates if (path / "libpipewire-ao-0.3.so").is_file()]
    if len(libraries) != 1:
        raise DeploymentError(f"expected one installed PipeWireAO library directory in {prefix}")
    library = libraries[0]
    paths = {"library": library, "modules": library / "pipewire-ao-0.3",
             "spa": library / "spa-ao-0.2", "daemon": prefix / "bin/pipewire-ao",
             "parser": prefix / "bin/pwao-spa-json-dump"}
    for label, path in paths.items():
        if not path.exists():
            raise DeploymentError(f"missing installed {label}: {path}")
    return paths


def decode(path: Path, prefix: Path) -> dict:
    if path.stat().st_size > MAX_CONFIG_BYTES:
        raise DeploymentError("deployment configuration exceeds 16 MiB")
    # Strict JSON is a subset of SPA-JSON. Delegate relaxed syntax to PipeWire's
    # parser instead of maintaining another configuration lexer.
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError:
        paths = installed_paths(prefix)
        env = os.environ.copy()
        env["LD_LIBRARY_PATH"] = str(paths["library"])
        result = subprocess.run([str(paths["parser"]), "-N", "-R", str(path)],
                                capture_output=True, check=True, timeout=10, env=env)
        if len(result.stdout) > MAX_CONFIG_BYTES:
            raise DeploymentError("decoded deployment configuration exceeds 16 MiB")
        return json.loads(result.stdout)


def profile(path: Path, prefix: Path) -> dict:
    value = decode(path, prefix)
    if (not isinstance(value, dict) or set(value) not in (REQUIRED_KEYS, REQUIRED_KEYS | {"source-owner"})
            or type(value["version"]) is not int or value["version"] != 1):
        raise DeploymentError("expected version 1 deployment with the documented fields")
    if not isinstance(value["name"], str) or not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,39}", value["name"]):
        raise DeploymentError("deployment name must use 1..40 lowercase letters, digits or hyphens")
    if not isinstance(value["owners"], list) or len(value["owners"]) > 4:
        raise DeploymentError("deployment permits at most four external owners")
    roles = {"core", "rtc"}
    validate_environment(value["environment"], "deployment")
    source_role = value.get("source-owner")
    if "source-owner" in value and (not isinstance(source_role, str) or not source_role):
        raise DeploymentError("source-owner must name an existing external owner")
    markers = set()
    for owner in value["owners"]:
        fields = {"role", "argv", "environment", "prepared", "connect", "connected", "quit"}
        if isinstance(owner, dict) and source_role is not None and owner.get("role") == source_role:
            fields |= {"control-request", "control-reply"}
        if not isinstance(owner, dict) or set(owner) != fields:
            raise DeploymentError("external owner fields do not match the deployment contract")
        if (not isinstance(owner["role"], str) or owner["role"] in roles
                or not re.fullmatch(r"[a-z][a-z0-9-]{0,31}", owner["role"])):
            raise DeploymentError("external owner role must be unique and filesystem-safe")
        roles.add(owner["role"])
        if (not isinstance(owner["argv"], list) or not owner["argv"]
                or len(owner["argv"]) > 256
                or not all(isinstance(arg, str) and "\0" not in arg for arg in owner["argv"])
                or not owner["argv"][0]):
            raise DeploymentError("owner argv must be a nonempty bounded string list")
        validate_environment(owner["environment"], f"owner {owner['role']}")
        marker_keys = ("prepared", "connect", "connected", "quit")
        if owner["role"] == source_role:
            marker_keys += ("control-request", "control-reply")
        for key in marker_keys:
            if (not isinstance(owner[key], str) or owner[key] in (".", "..")
                    or not re.fullmatch(r"[a-zA-Z0-9_.-]{1,64}", owner[key])):
                raise DeploymentError(f"owner {key} must be a marker basename")
        names = {owner[key] for key in marker_keys}
        if len(names) != len(marker_keys) or names & markers:
            raise DeploymentError("owner markers must be distinct")
        markers.update(names)
    if source_role is not None and source_role not in {owner["role"] for owner in value["owners"]}:
        raise DeploymentError("source-owner must name an existing external owner")
    if markers & (roles | {"control.sock", "native-control.sock", "native-prefix", "julia-depot"}):
        raise DeploymentError("owner markers conflict with deployment runtime paths")
    if source_role is not None:
        source = next(owner for owner in value["owners"] if owner["role"] == source_role)
        staging = Path(source["control-request"]).with_suffix(".new").name
        if staging in markers or staging in roles | {"control.sock", "native-control.sock", "native-prefix", "julia-depot"}:
            raise DeploymentError("source request staging path conflicts with runtime paths")
    if not isinstance(value["placement"], dict) or set(value["placement"]) != roles:
        raise DeploymentError("each owned process requires an explicit placement contract")
    for role, placement in value["placement"].items():
        if not isinstance(placement, dict) or set(placement) != {
                "cpus", "leader-cpu", "rt-priority", "threads", "locked-bytes"}:
            raise DeploymentError(f"invalid placement contract for {role}")
        if not isinstance(placement["cpus"], list):
            raise DeploymentError("process CPU envelope must be a list")
        cpu_set(placement["cpus"])
        if type(placement["leader-cpu"]) is not int or placement["leader-cpu"] not in placement["cpus"]:
            raise DeploymentError("process leader CPU must belong to its declared envelope")
        priority = placement["rt-priority"]
        if type(priority) is not int or not 0 <= priority <= 99:
            raise DeploymentError("RT priority must be an integer in 0..99")
        if type(placement["locked-bytes"]) is not int or placement["locked-bytes"] < 0:
            raise DeploymentError("locked-bytes must be nonnegative")
        if not isinstance(placement["threads"], list) or len(placement["threads"]) > 128:
            raise DeploymentError("thread requirements must be a bounded list")
        for thread in placement["threads"]:
            if not isinstance(thread, dict) or not {"cpus", "policy", "priority", "count"} <= set(thread) <= {
                    "cpus", "policy", "priority", "count", "name"}:
                raise DeploymentError("invalid required thread fields")
            if not isinstance(thread["cpus"], list):
                raise DeploymentError("required thread CPUs must be a list")
            if not cpu_set(thread["cpus"]) <= cpu_set(placement["cpus"]):
                raise DeploymentError("required thread exceeds process envelope")
            if (thread["policy"] not in ("fifo", "other") or type(thread["count"]) is not int
                    or type(thread["priority"]) is not int
                    or not 1 <= thread["count"] <= 128
                    or thread["priority"] != (priority if thread["policy"] == "fifo" else 0)):
                raise DeploymentError("invalid required thread policy/count")
            if "name" in thread and (not isinstance(thread["name"], str)
                                      or not thread["name"] or "\0" in thread["name"]):
                raise DeploymentError("required thread name must be a nonempty string")
    latency = value["cpu-latency-us"]
    if latency is not None and (type(latency) is not int or not 0 <= latency <= 2**31 - 1):
        raise DeploymentError("cpu-latency-us must be null or a nonnegative Int32")
    if not isinstance(value["client"], dict) or set(value["client"]) != roles:
        raise DeploymentError("each owned process requires an explicit client configuration")
    for name in value["client"].values():
        relative_asset(path.parent, name)
    for key in ("session", "core"):
        relative_asset(path.parent, value[key])
    if not isinstance(value["artifacts"], dict):
        raise DeploymentError("deployment artifacts must be a path/hash mapping")
    for name, sha in value["artifacts"].items():
        asset = relative_asset(path.parent, name)
        if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{64}", sha) or digest(asset) != sha:
            raise DeploymentError(f"deployment artifact hash mismatch: {name}")
    return value


def validate_environment(value, label: str) -> None:
    if (not isinstance(value, dict)
            or any(not isinstance(key, str) or not key or "=" in key or "\0" in key
                   or not isinstance(item, str) or "\0" in item for key, item in value.items())):
        raise DeploymentError(f"{label} environment must map valid names to strings")


def relative_asset(package: Path, name: str) -> Path:
    if not isinstance(name, str) or not name or "\0" in name or Path(name).is_absolute():
        raise DeploymentError("installed asset must be a package-relative path")
    candidate = (package / name).resolve(strict=True)
    if not candidate.is_relative_to(package.resolve()) or not candidate.is_file():
        raise DeploymentError(f"asset escapes package or is not a file: {name}")
    return candidate


def substitute(value: str, bindings: dict[str, str], *, quoted: bool = False) -> str:
    for name, replacement in bindings.items():
        value = value.replace(f"@{name}@", json.dumps(replacement)[1:-1] if quoted else replacement)
    if re.search(r"@[A-Z_]+@", value):
        raise DeploymentError(f"unresolved deployment binding in {value[:200]!r}")
    return value


def control(path: Path, argv: list[str], timeout: float = 8, *, request_id=None,
            allow_rejection: bool = False, check=None) -> dict:
    """Legacy JSON client retained for imported development fixtures."""
    if not isinstance(argv, list) or not all(isinstance(arg, str) for arg in argv):
        raise DeploymentError("control argv must be a string list")
    if not math.isfinite(timeout) or timeout <= 0:
        raise DeploymentError("control timeout must be finite and positive")
    deadline = time.monotonic() + timeout
    request_id = uuid.uuid4().hex if request_id is None else request_id
    payload = json.dumps({"version": 1, "id": request_id, "argv": argv},
                         ensure_ascii=False, separators=(",", ":")).encode() + b"\n"
    if len(payload) > 16 * 1024 or len(argv) > 128:
        raise DeploymentError("control request exceeds protocol limits")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        def remaining() -> None:
            if check is not None:
                check()
            budget = deadline - time.monotonic()
            if budget <= 0:
                raise TimeoutError("control deadline expired")
            client.settimeout(budget)

        try:
            remaining()
            client.connect(str(path))
            remaining()
            client.sendall(payload)
            data = bytearray()
            while b"\n" not in data:
                remaining()
                block = client.recv(min(4096, MAX_REPLY_BYTES + 1 - len(data)))
                if not block:
                    raise DeploymentError("control peer disconnected; mutation outcome may be unknown")
                data.extend(block)
                if len(data) > MAX_REPLY_BYTES:
                    raise DeploymentError("control reply exceeds 64 KiB")
            remaining()
        except TimeoutError as error:
            raise DeploymentError("control timed out; mutation outcome may be unknown") from error
        except OSError as error:
            raise DeploymentError(f"control transport failed; mutation outcome may be unknown: {error}") from error
    reply = json.loads(data)
    if (not isinstance(reply, dict) or type(reply.get("version")) is not int
            or reply.get("version") != 1 or reply.get("id") != request_id
            or type(reply.get("ok")) is not bool):
        raise DeploymentError("control reply does not match request identity")
    if not reply.get("ok") and not allow_rejection:
        raise DeploymentError(f"control rejected: {reply.get('error')}")
    return reply


def validate_source_reply(payload: bytes) -> dict:
    if len(payload) > MAX_REPLY_BYTES:
        raise DeploymentError("source reply exceeds 64 KiB")
    reply = json.loads(payload)
    keys = {"version", "id", "operation", "state", "sequence", "completed", "ok", "error"}
    if (not isinstance(reply, dict) or set(reply) != keys
            or type(reply["version"]) is not int or reply["version"] != 1
            or type(reply["id"]) is not int or reply["id"] <= 0
            or reply["operation"] not in ("resume", "pause", "reset", "status")
            or reply["state"] not in ("running", "paused")
            or type(reply["sequence"]) is not int or reply["sequence"] < 0
            or type(reply["completed"]) is not bool
            or type(reply["ok"]) is not bool
            or not (reply["error"] is None or isinstance(reply["error"], str))
            or (reply["ok"] and reply["error"] is not None)):
        raise DeploymentError("invalid source control reply")
    return reply


def validate_control_request(payload: bytes) -> dict:
    if len(payload) > MAX_REQUEST_BYTES:
        raise DeploymentError("control request exceeds 16 KiB")
    request = json.loads(payload)
    if (not isinstance(request, dict) or set(request) != {"version", "id", "argv"}
            or type(request["version"]) is not int or request["version"] != 1
            or not isinstance(request["id"], str) or not 1 <= len(request["id"].encode()) <= 128
            or not isinstance(request["argv"], list) or len(request["argv"]) > 128
            or not all(isinstance(arg, str) for arg in request["argv"])):
        raise DeploymentError("invalid version 1 control request")
    return request


def control_error(request_id, field: str, message: str) -> dict:
    return {"version": 1, "id": request_id, "session_id": None, "state": None,
            "result": None, "ok": False, "error": {"field": field, "message": message}}


def notify(message: str) -> None:
    address = os.environ.get("NOTIFY_SOCKET")
    if address:
        with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as channel:
            channel.settimeout(1)
            channel.connect("\0" + address[1:] if address.startswith("@") else address)
            channel.sendall(message.encode())


def atomic_record(path: Path, value: dict) -> None:
    temporary = path.with_suffix(".new")
    with temporary.open("w", encoding="utf-8") as output:
        json.dump(value, output, indent=2)
        output.write("\n")
    temporary.replace(path)


class Deployment:
    def __init__(self, arguments):
        self.args = arguments
        self.package = arguments.deployment.resolve().parent
        self.spec = profile(arguments.deployment.resolve(), arguments.pipewire_prefix)
        self.inherited_cpus = os.sched_getaffinity(0)
        self.paths = installed_paths(arguments.pipewire_prefix)
        self.processes: list[tuple[str, subprocess.Popen]] = []
        self.stopping = False
        self.runtime: Path | None = None
        self.latency_fd: int | None = None
        self.socket: Path | None = None
        self.native_socket: Path | None = None
        self.broker: socket.socket | None = None
        self.source_owner = next((owner for owner in self.spec["owners"]
                                  if owner["role"] == self.spec.get("source-owner")), None)
        self.source_id = 0
        self.source_state: str | None = None
        self.source_failed = False
        self.native_shutdown = False
        self.state_path: Path | None = None
        self.record = {"version": 1, "name": self.spec["name"], "phase": "preflight",
                       "pid": os.getpid(), "admitted": False, "processes": {}, "error": None}

    def preflight(self) -> dict:
        available = self.inherited_cpus
        for role, contract in self.spec["placement"].items():
            if not cpu_set(contract["cpus"]) <= available:
                raise DeploymentError(f"{role} CPUs unavailable in inherited affinity: {sorted(available)}")
        priority = max(contract["rt-priority"] for contract in self.spec["placement"].values())
        locked = max(contract["locked-bytes"] for contract in self.spec["placement"].values())
        rights = credentials(priority, locked, self.spec["cpu-latency-us"])
        if self.source_owner is None and (self.args.fits is None or not self.args.fits.is_file()):
            raise DeploymentError(f"recorded FITS source is missing: {self.args.fits}")
        dependencies = [("RTC", self.package / "bin/pipewireao-rtc")]
        if self.source_owner is None:
            dependencies += [("FITS plugin", self.paths["spa"] / "fits/libspa-fits.so"),
                             ("discard plugin", self.paths["spa"] / "discard/libspa-pipewireao-discard.so")]
        for label, path in dependencies:
            if not path.is_file():
                raise DeploymentError(f"missing {label}: {path}")
        return rights

    def environment(self, role: str, bindings: dict[str, str]) -> dict[str, str]:
        env = os.environ.copy()
        env.pop("NOTIFY_SOCKET", None)  # Only the supervisor reports service readiness.
        env.update({"LD_LIBRARY_PATH": str(self.paths["library"]),
                    "PIPEWIREAO_RUNTIME_DIR": str(self.runtime),
                    "PIPEWIREAO_CONFIG_DIR": str(self.runtime / role),
                    "PIPEWIREAO_MODULE_DIR": str(self.paths["modules"]),
                    "PIPEWIREAO_SPA_PLUGIN_DIR": str(self.paths["spa"]),
                    "PIPEWIREAO_FITS_PLUGIN": str(self.paths["spa"] / "fits/libspa-fits.so"),
                    "PIPEWIREAO_DISCARD_PLUGIN": str(self.paths["spa"] / "discard/libspa-pipewireao-discard.so"),
                    "PIPEWIREAO_REMOTE": bindings["REMOTE"], "PIPEWIRE_REMOTE": bindings["REMOTE"]})
        if self.source_owner is None:
            env["PIPEWIREAO_RTC_FITS_PATH"] = str(self.args.fits.resolve())
        env.update({key: substitute(value, bindings) for key, value in self.spec["environment"].items()})
        if self.spec["owners"]:
            # An ordinary JLL artifact override selects the same installed
            # PipeWireAO client library used by Rust. Package sources and the
            # resolved Julia environment are installed by the exporter.
            env["JULIA_DEPOT_PATH"] = str(self.runtime / "julia-depot") + ":" + os.environ.get(
                "JULIA_DEPOT_PATH", str(Path.home() / ".julia") + ":")
        return env

    def prepare_julia_override(self) -> None:
        if not self.spec["owners"]:
            return
        overlay = self.runtime / "native-prefix"
        overlay.mkdir()
        (overlay / "lib").symlink_to(self.paths["library"], target_is_directory=True)
        for name in ("bin", "share", "etc", "include"):
            path = self.args.pipewire_prefix / name
            if path.exists():
                (overlay / name).symlink_to(path.resolve(), target_is_directory=True)
        artifacts = self.runtime / "julia-depot/artifacts"
        artifacts.mkdir(parents=True)
        (artifacts / "Overrides.toml").write_text(
            '[cde84cf6-9a21-5ce0-b5e3-1526e778c30b]\n'
            f'PipeWireAO = {json.dumps(str(overlay))}\n')

    def spawn(self, role: str, argv: list[str], env: dict) -> None:
        mask = str(self.spec["placement"][role]["leader-cpu"])
        # Affinity is inherited at exec. Libraries configure individual workers;
        # control/JIT threads keep SCHED_OTHER.
        process = subprocess.Popen(["taskset", "--cpu-list", mask, *argv], env=env,
                                   cwd=self.runtime / role, stdin=subprocess.DEVNULL,
                                   start_new_session=True)
        self.processes.append((role, process))
        self.record["processes"][role] = {"pid": process.pid}

    def check(self) -> None:
        if self.stopping:
            raise InterruptedError("deployment stop requested")
        self.check_processes()

    def check_processes(self, ignore_roles=()) -> None:
        for role, process in self.processes:
            if role not in ignore_roles and process.poll() is not None:
                raise DeploymentError(f"required {role} exited with status {process.returncode}")

    def wait(self, predicate, stage: str, timeout: float = 90) -> None:
        deadline = time.monotonic() + timeout
        while True:
            self.check()
            if predicate():
                return
            if time.monotonic() >= deadline:
                raise DeploymentError(f"timed out waiting for {stage}")
            time.sleep(0.05)

    def source_control(self, operation: str, *, initial: bool = False,
                       shutdown: bool = False, allow_rejection: bool = False) -> dict:
        """One acknowledged owner operation; frame completion remains owner-owned."""
        if operation not in ("resume", "pause", "reset", "status") or self.source_owner is None:
            raise DeploymentError("invalid source control operation")
        self.source_id += 1
        request = {"version": 1, "id": self.source_id, "operation": operation}
        deadline = time.monotonic() + (16 if operation == "reset" else SOURCE_TIMEOUT)
        try:
            atomic_record(self.runtime / self.source_owner["control-request"], request)
            reply_path = self.runtime / self.source_owner["control-reply"]
            while True:
                self.check_processes(ignore_roles=("rtc",)) if shutdown else self.check()
                if time.monotonic() >= deadline:
                    raise DeploymentError(f"source {operation} ACK timed out")
                try:
                    # Do not follow an owner-created alias outside this instance.
                    fd = os.open(reply_path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
                except FileNotFoundError:
                    time.sleep(0.05)
                    continue
                with os.fdopen(fd, "rb") as source:
                    info = os.fstat(source.fileno())
                    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
                        raise DeploymentError("source reply must be an owner-owned regular file")
                    payload = source.read(MAX_REPLY_BYTES + 1)
                reply = validate_source_reply(payload)
                if reply["id"] < self.source_id:
                    time.sleep(0.05)
                    continue
                if reply["id"] != self.source_id or reply["operation"] != operation:
                    raise DeploymentError("source ACK does not match request identity/operation")
                expected = ("running" if operation == "resume" else "paused"
                            if operation != "status" else reply["state"])
                if not reply["ok"] and allow_rejection:
                    self.source_state = reply["state"]
                    self.record["source"] = reply
                    return reply
                if not reply["ok"] or reply["state"] != expected:
                    raise DeploymentError(f"source {operation} rejected: {reply['error']}")
                if (initial or operation == "reset") and reply["sequence"] != 0:
                    raise DeploymentError("source admission/reset requires sequence zero")
                if time.monotonic() >= deadline:
                    raise DeploymentError(f"source {operation} ACK timed out")
                self.source_state = reply["state"]
                self.record["source"] = reply
                return reply
        except (DeploymentError, OSError, ValueError) as error:
            self.source_failed = True
            self.record.update({"phase": "failed", "admitted": False})
            if self.record["error"] is None:
                self.record["error"] = str(error)
            else:
                self.record.setdefault("cleanup_errors", []).append(str(error))
            if self.state_path is not None:
                atomic_record(self.state_path, self.record)
            raise DeploymentError(f"source coordination failed: {error}") from error

    def open_broker(self) -> None:
        # The fresh instance path must not replace any pre-existing object.
        if self.socket.exists() or self.socket.is_symlink():
            raise DeploymentError("public control path already exists")
        self.broker = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.broker.bind(str(self.socket))
        self.socket.chmod(0o600)
        self.broker.listen(1)
        self.broker.settimeout(0.1)

    def native_control(self, argv: list[str], request_id=None) -> dict:
        check = (lambda: self.check_processes(ignore_roles=("rtc",))) if argv in (["quit"], ["exit"]) else self.check
        return control(self.native_socket, argv, request_id=request_id,
                       allow_rejection=True, check=check)

    def coordinate(self, argv: list[str], request_id: str) -> dict:
        # Exact arities avoid changing source admission for malformed commands.
        stopping = argv in (["session-stop"], ["source-ended"], ["quit"], ["exit"]) or (len(argv) == 2 and argv[0] == "stop")
        starting = argv == ["session-start"] or (len(argv) == 2 and argv[0] == "start")
        resetting = argv == ["reset"]
        if not (stopping or starting or resetting):
            return self.native_control(argv, request_id)
        observed = self.native_control(["status"])
        # Native control decides legal states and group names. A reset outside
        # Ready must reach that executor without any owner operation.
        if not observed["ok"] or (resetting and observed["state"] != "Ready"):
            return self.native_control(argv, request_id)
        source = self.source_control("status")
        if starting and source["completed"]:
            reply = dict(observed)
            reply.update({"id": request_id, "ok": False, "result": None,
                          "error": {"field": "source.state",
                                    "message": "finite source completed; reset before start"}})
            return reply
        was_running = source["state"] == "running"
        if stopping:
            source = self.source_control("pause")
        try:
            reply = self.native_control(argv, request_id)
        except (DeploymentError, OSError, ValueError) as error:
            self.source_failed = True
            self.record.update({"phase": "failed", "admitted": False, "error": str(error)})
            if self.state_path is not None:
                atomic_record(self.state_path, self.record)
            raise
        if reply["ok"]:
            if starting and reply["state"] == "Running":
                resumed = self.source_control("resume", allow_rejection=True)
                if not resumed["ok"]:
                    reply = dict(reply)
                    reply.update({"ok": False, "error": {"field": "source.state",
                        "message": resumed["error"] or "source rejected resume"},
                        "result": {"native": reply.get("result"), "source": resumed}})
            elif resetting:
                self.source_control("reset")
            if argv in (["quit"], ["exit"]):
                self.native_shutdown = True
                self.stopping = True
        elif stopping and was_running and not source["completed"]:
            self.source_control("resume")
        return reply

    def serve_control(self) -> None:
        try:
            client, _ = self.broker.accept()
        except TimeoutError:
            return
        failure = None
        request_id = None
        with client:
            deadline = time.monotonic() + BROKER_IO_TIMEOUT
            data = bytearray()
            try:
                while b"\n" not in data:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise DeploymentError("control inbound deadline expired")
                    client.settimeout(remaining)
                    block = client.recv(min(4096, MAX_REQUEST_BYTES + 1 - len(data)))
                    if not block:
                        raise DeploymentError("control client disconnected before request")
                    data.extend(block)
                    if len(data) > MAX_REQUEST_BYTES:
                        raise DeploymentError("control request exceeds 16 KiB")
                request = validate_control_request(data)
                request_id = request["id"]
            except (DeploymentError, ValueError, OSError) as error:
                reply = control_error(request_id, "protocol.request", str(error))
            else:
                try:
                    reply = self.coordinate(request["argv"], request_id)
                except (DeploymentError, ValueError, OSError) as error:
                    reply = control_error(request_id, "control.outcome", str(error))
                    failure = error
            payload = json.dumps(reply).encode() + b"\n"
            if len(payload) > MAX_REPLY_BYTES:
                payload = json.dumps(control_error(request_id, "protocol.reply", "reply exceeds 64 KiB")).encode() + b"\n"
            try:
                client.settimeout(BROKER_IO_TIMEOUT)
                client.sendall(payload)
            except OSError:
                # The accepted operation is never replayed on disconnect.
                pass
        if failure is not None:
            raise failure

    def run(self) -> None:
        """Run the historical Python fixture launcher; the active CLI rejects it."""
        self.record["credentials"] = self.preflight()
        os.sched_setaffinity(0, {self.spec["placement"]["rtc"]["leader-cpu"]})
        if self.args.runtime.is_symlink():
            raise DeploymentError("runtime base must not be a symlink")
        base = self.args.runtime.resolve()
        base.mkdir(mode=0o700, parents=True, exist_ok=True)
        info = base.stat()
        if base.is_symlink() or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise DeploymentError("runtime base must be an owner-only directory")
        with (base / "deployment.lock").open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise DeploymentError("deployment runtime is already owned by another launcher") from error
            self.state_path = base / "state.json"
            self.runtime = Path(tempfile.mkdtemp(prefix="run-", dir=base))
            primary_error = None
            try:
                self.socket = self.runtime / "control.sock"
                self.native_socket = (self.runtime / "native-control.sock"
                                      if self.source_owner else self.socket)
                if len(os.fsencode(self.native_socket)) >= 108:
                    raise DeploymentError("runtime path is too long for a Unix control socket")
                bindings = {"PACKAGE": str(self.package), "PREFIX": str(self.args.pipewire_prefix.resolve()),
                            "RUNTIME": str(self.runtime), "REMOTE": "rtc-" + uuid.uuid4().hex[:12]}
                if self.source_owner is None:
                    bindings["FITS"] = str(self.args.fits.resolve())
                self.record.update({"instance": self.runtime.name, "socket": str(self.socket),
                                    "remote": bindings["REMOTE"]})
                if self.source_owner:
                    self.record.update({"source-owner": self.source_owner["role"],
                                        "control_operation_bound_seconds": 40,
                                        "control_client_timeout_seconds": 48})
                else:
                    self.record["fits_sha256"] = digest(self.args.fits)
                self.prepare_julia_override()
                for role in self.spec["placement"]:
                    directory = self.runtime / role
                    directory.mkdir(mode=0o700)
                    for key in ("client", "core", "session"):
                        name = self.spec["client"][role] if key == "client" else self.spec[key]
                        source = relative_asset(self.package, name)
                        (directory / f"{key if key != 'core' else 'daemon'}.conf").write_text(
                            substitute(source.read_text(), bindings, quoted=True))
                # Render native module arguments into runtime. Session templates refer
                # to them, while scientific arrays remain immutable installed files.
                for source in self.package.glob("graphs/*.conf.in"):
                    destination = self.runtime / source.name.removesuffix(".in")
                    destination.write_text(substitute(source.read_text(), bindings, quoted=True))
                atomic_record(base / "state.json", self.record)
                latency = self.spec["cpu-latency-us"]
                if latency is not None:
                    self.latency_fd = os.open("/dev/cpu_dma_latency", os.O_RDWR | os.O_CLOEXEC)
                    if os.write(self.latency_fd, struct.pack("=i", latency)) != 4:
                        raise DeploymentError("short cpu_dma_latency request write")
                self.spawn("core", [str(self.paths["daemon"]), "-c", "daemon.conf"],
                           self.environment("core", bindings))
                self.wait(lambda: (self.runtime / bindings["REMOTE"]).is_socket(), "private core")
                for owner in self.spec["owners"]:
                    role = owner["role"]
                    env = self.environment(role, bindings)
                    env.update({key: substitute(value, bindings) for key, value in owner["environment"].items()})
                    self.spawn(role, [substitute(arg, bindings) for arg in owner["argv"]], env)
                    self.wait(lambda: (self.runtime / owner["prepared"]).is_file(), f"{role} preparation")
                    (self.runtime / owner["connect"]).touch(exist_ok=False)
                    self.wait(lambda: (self.runtime / owner["connected"]).is_file(), f"{role} connection")
                if self.source_owner:
                    self.source_control("pause", initial=True)
                self.spawn("rtc", [str(self.package / "bin/pipewireao-rtc"),
                                   "--config", str(self.runtime / "rtc/session.conf"),
                                   "--remote", bindings["REMOTE"], "--start-paused",
                                   "--control-socket", str(self.native_socket)], self.environment("rtc", bindings))
                self.wait(lambda: self.native_socket.is_socket(), "RTC control endpoint")
                ready = control(self.native_socket, ["status"])
                if ready["state"] != "Ready":
                    raise DeploymentError(f"RTC admission requires Ready, observed {ready['state']}")
                before = {}
                for role, process in self.processes:
                    before[role] = snapshot(process.pid, self.spec["placement"][role])
                self.check()
                self.record.update({"phase": "prepared", "placement": before, "ready": ready})
                atomic_record(base / "state.json", self.record)
                started = control(self.native_socket, ["session-start"])
                if started["state"] != "Running":
                    raise DeploymentError("RTC did not admit session start")
                if self.source_owner:
                    self.source_control("resume")
                    self.open_broker()
                self.record.update({"phase": "running", "admitted": True, "start": started})
                atomic_record(base / "state.json", self.record)
                print(f"DEPLOYMENT_READY name={self.spec['name']} socket={self.socket}", flush=True)
                notify("READY=1\nSTATUS=RTC admitted; local control available")
                while not self.stopping:
                    self.check()
                    if self.source_owner:
                        self.serve_control()
                    else:
                        time.sleep(0.1)
            except InterruptedError:
                pass
            except BaseException as error:
                primary_error = error
                self.record.update({"phase": "failed", "error": str(error), "admitted": False})
                atomic_record(base / "state.json", self.record)
                raise
            finally:
                try:
                    self.stop()
                except BaseException as error:
                    cleanup_errors = self.record.setdefault("cleanup_errors", [])
                    if not any(previous in str(error) for previous in cleanup_errors):
                        cleanup_errors.append(str(error))
                    if self.record["error"] is None:
                        self.record["error"] = str(error)
                        raise
                    if primary_error is not None:
                        cleanup_note = f"cleanup also failed: {error}"
                        if hasattr(primary_error, "add_note"):
                            primary_error.add_note(cleanup_note)
                        else:
                            primary_error.args = (f"{primary_error}; {cleanup_note}",)
                finally:
                    if self.broker is not None:
                        self.broker.close()
                    self.record.update({"phase": "failed" if self.record["error"] else "stopped",
                                        "admitted": False})
                    try:
                        atomic_record(base / "state.json", self.record)
                    finally:
                        # Only this launch's freshly created directory is owned.
                        shutil.rmtree(self.runtime)

    def stop(self) -> None:
        self.record["admitted"] = False
        errors = []
        try:
            notify("STOPPING=1\nSTATUS=Stopping RTC deployment")
        except OSError as error:
            errors.append(error)
        if self.source_owner:
            self.stop_source_deployment(errors)
            return
        ingress_stopped = False
        if self.socket is not None and self.socket.is_socket():
            try:
                observed = control(self.socket, ["status"], timeout=8)
                if observed["state"] == "Running":
                    observed = control(self.socket, ["session-stop"], timeout=8)
                ingress_stopped = observed["state"] == "Ready"
            except (OSError, DeploymentError, ValueError):
                pass
            try:
                control(self.socket, ["quit"], timeout=8)
            except (OSError, DeploymentError, ValueError):
                pass
        # A quit ACK is only acceptance. Complete RTC teardown first. If no
        # completed stop was observed, terminate the private source-owning core
        # before asking any consumer to quit.
        for role, process in self.processes:
            if role == "rtc":
                try:
                    self.wait_owned_process(process, 8)
                except (OSError, subprocess.SubprocessError) as error:
                    errors.append(error)
        if not ingress_stopped:
            cores = [process for role, process in self.processes if role == "core"]
            for process in cores:
                try:
                    self.wait_owned_process(process, 0)
                    ingress_stopped = True
                except (OSError, subprocess.SubprocessError) as error:
                    errors.append(error)
        # Graceful consumers require acknowledged ingress revocation or a
        # terminated source-owning core. Forced cleanup remains bounded.
        if self.runtime and ingress_stopped:
            for owner in self.spec["owners"]:
                try:
                    (self.runtime / owner["quit"]).touch(exist_ok=True)
                except OSError as error:
                    errors.append(error)
        for role, process in reversed(self.processes):
            try:
                self.wait_owned_process(process, 8 if role not in ("core", "rtc") else 0)
            except (OSError, subprocess.SubprocessError) as error:
                errors.append(error)
        if self.latency_fd is not None:
            try:
                os.close(self.latency_fd)
            except OSError as error:
                errors.append(error)
            finally:
                self.latency_fd = None
        if errors:
            raise DeploymentError(f"deployment cleanup failed: {errors[0]}") from errors[0]

    def stop_source_deployment(self, errors: list) -> None:
        """Revoke external ingress before any consumer teardown, even on failure."""
        source_started = any(role == self.source_owner["role"] for role, _ in self.processes)
        paused = self.native_shutdown and self.source_state == "paused"
        if source_started and not self.source_failed and not paused:
            try:
                self.source_control("pause", shutdown=True)
                paused = True
            except (DeploymentError, OSError, ValueError) as error:
                errors.append(error)
        revoked = paused
        if not paused:
            # An unconfirmed pause cannot authorize a graceful consumer quit.
            # Kill both the application source and its private transport first.
            revoked = True
            for role, process in self.processes:
                if role in (self.source_owner["role"], "core"):
                    try:
                        self.wait_owned_process(process, 0)
                    except (OSError, subprocess.SubprocessError) as error:
                        revoked = False
                        errors.append(error)
        if revoked and self.native_socket is not None and self.native_socket.is_socket():
            try:
                observed = control(self.native_socket, ["status"], timeout=8)
                if observed["state"] == "Running":
                    control(self.native_socket, ["session-stop"], timeout=8)
            except (OSError, DeploymentError, ValueError):
                pass
            try:
                control(self.native_socket, ["quit"], timeout=8)
            except (OSError, DeploymentError, ValueError):
                pass
        for role, process in self.processes:
            if role == "rtc":
                try:
                    self.wait_owned_process(process, 8)
                except (OSError, subprocess.SubprocessError) as error:
                    errors.append(error)
        # Close the source command stream before a consumer shutdown can emit
        # an unsolicited flat/zero command (for example HEART SHUTDOWN).
        source_closed = not source_started
        if self.runtime and revoked:
            try:
                (self.runtime / self.source_owner["quit"]).touch(exist_ok=True)
                for role, process in self.processes:
                    if role == self.source_owner["role"]:
                        self.wait_owned_process(process, 8)
                source_closed = True
            except (OSError, subprocess.SubprocessError) as error:
                errors.append(error)
            if source_closed:
                for owner in self.spec["owners"]:
                    if owner is self.source_owner:
                        continue
                    try:
                        (self.runtime / owner["quit"]).touch(exist_ok=True)
                    except OSError as error:
                        errors.append(error)
            else:
                # A failed stream closure cannot authorize consumer shutdown.
                # Revoke the private transport and source before forcing other
                # owners down; do not send their graceful quit markers.
                for role, process in self.processes:
                    if role in ("core", self.source_owner["role"]):
                        try:
                            self.wait_owned_process(process, 0)
                        except (OSError, subprocess.SubprocessError) as error:
                            errors.append(error)
        for role, process in reversed(self.processes):
            try:
                self.wait_owned_process(process, 8 if revoked and source_closed and role not in ("core", "rtc") else 0)
            except (OSError, subprocess.SubprocessError) as error:
                errors.append(error)
        if self.latency_fd is not None:
            try:
                os.close(self.latency_fd)
            except OSError as error:
                errors.append(error)
            finally:
                self.latency_fd = None
        if errors:
            raise DeploymentError(f"deployment cleanup failed: {errors[0]}") from errors[0]

    @staticmethod
    def wait_owned_process(process, grace: float) -> None:
        try:
            process.wait(timeout=grace)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                process.wait(timeout=5)
                return
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait(timeout=5)


def install(args) -> None:
    source = args.package.resolve()
    destination = args.destination.resolve()
    if source == destination or destination.exists():
        raise DeploymentError("install destination must be a new directory")
    profile(source / "deployment.conf", args.pipewire_prefix)
    shutil.copytree(source, destination, symlinks=False)
    scripts = Path(__file__).resolve().parent
    (destination / "bin").mkdir(exist_ok=True)
    launcher = destination / "bin/pipewireao-rtc-deploy"
    shutil.copy2(Path(__file__).resolve(), launcher)
    launcher.chmod(0o755)
    shutil.copy2(scripts / "placement.py", destination / "bin/placement.py")
    template = scripts / "pipewireao-rtc@.service.in"
    shutil.copy2(template, destination / "bin" / template.name)
    unit = template.read_text()
    unit = unit.replace("@LAUNCHER@", json.dumps(str(launcher).replace("%", "%%")))
    unit = unit.replace("@PIPEWIRE_PREFIX@", json.dumps(str(args.pipewire_prefix.resolve()).replace("%", "%%")))
    spec = profile(destination / "deployment.conf", args.pipewire_prefix)
    cpus = sorted({cpu for contract in spec["placement"].values() for cpu in contract["cpus"]})
    unit = unit.replace("@CPUS@", " ".join(map(str, cpus)))
    unit = unit.replace("@FITS_ARGUMENT@", "" if "source-owner" in spec else
                        " --fits %h/.config/pipewireao-rtc/%i/input.fits")
    output = destination / "systemd/pipewireao-rtc@.service"
    output.parent.mkdir(exist_ok=True)
    output.write_text(unit)
    print(destination)


def parser() -> argparse.ArgumentParser:
    cli = argparse.ArgumentParser(description=__doc__)
    commands = cli.add_subparsers(dest="command", required=True)
    for name in ("preflight", "run"):
        command = commands.add_parser(name)
        command.add_argument("--deployment", type=Path, required=True)
        command.add_argument("--pipewire-prefix", type=Path, default=Path("/opt/pipewireao"))
        command.add_argument("--fits", type=Path)
        command.add_argument("--runtime", type=Path,
                             default=Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"))
                             / "pipewireao-rtc")
    command = commands.add_parser("control")
    command.add_argument("--runtime", type=Path, required=True)
    command.add_argument("argv", nargs=argparse.REMAINDER)
    command = commands.add_parser("install")
    command.add_argument("--package", type=Path, required=True)
    command.add_argument("--destination", type=Path, required=True)
    command.add_argument("--pipewire-prefix", type=Path, default=Path("/opt/pipewireao"))
    return cli


def main() -> int:
    args = parser().parse_args()
    try:
        if args.command in ("run", "control"):
            raise DeploymentError(
                "Python live deployment control is retired; use deployment/julia/deploy_cli.jl")
        if args.command == "install":
            install(args)
        else:
            deployment = Deployment(args)
            if args.command == "preflight":
                print(json.dumps(deployment.preflight(), indent=2))
            else:
                for signum in (signal.SIGTERM, signal.SIGINT):
                    signal.signal(signum, lambda _number, _frame: setattr(deployment, "stopping", True))
                deployment.run()
        return 0
    except (DeploymentError, OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"pipewireao-rtc-deploy: {error}", file=sys.stderr)
        notes = getattr(error, "__notes__", ())
        for note in notes[:8]:
            print(f"pipewireao-rtc-deploy: {note[:1024]}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
