#!/usr/bin/env python3
"""Check installed property controls and lifecycle preservation on a private core.

The rendered FITS source loops for this functional check. Installed files stay
immutable. This check does not measure numerical correctness or timing.
"""
from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import re
import signal
import struct
import time

import deploy


def require(condition, message):
    if not condition:
        raise deploy.DeploymentError(message)


def enable_looping_source(path: Path) -> dict:
    session = json.loads(path.read_text())
    sources = [source for source in session["sources"] if source.get("factory") == "api.fits.source"]
    require(len(sources) == 1, "property check requires exactly one recorded FITS source")
    previous = sources[0]["args"].get("api.fits.loop")
    sources[0]["args"]["api.fits.loop"] = True
    path.write_text(json.dumps(session, indent=2) + "\n")
    return {"field": "api.fits.loop", "installed_value": previous, "rendered_value": True,
            "rendered_session_sha256": deploy.digest(path)}


def invalid_transactions(graph: str, node: str) -> list[tuple[str, list[str]]]:
    gain = f"{node}:gain"
    return [
        ("unknown_graph", ["property", graph + "-unknown", gain, "float", "0.2"]),
        ("unknown_property", ["property", graph, f"{node}:__rtc_unknown_property__", "float", "0.2"]),
        ("wrong_int_type", ["property", graph, gain, "int", "1"]),
        ("wrong_double_type", ["property", graph, gain, "double", "0.2"]),
        ("unqualified_name", ["property", graph, "gain", "float", "0.2"]),
        ("read_only", ["property", graph, f"{node}:requested-generation", "long", "1"]),
        ("mixed_transaction", ["properties-set", graph, gain, "float", "0.2",
                               f"{node}:__rtc_unknown_property__", "float", "0.3"]),
    ]


class PropertyCheck:
    def __init__(self, args):
        self.args = args
        self.runner = deploy.Deployment(args)
        self.client = deploy.control
        self.session = deploy.decode(self.runner.package / self.runner.spec["session"], args.pipewire_prefix)
        graphs = [graph for graph in self.session["graphs"]
                  if args.graph is None or graph["node.name"] == args.graph]
        require(len(graphs) == 1, "select exactly one graph with --graph")
        self.graph = graphs[0]["node.name"]
        parameters = [port for port in graphs[0]["ports"] if port.get("parameter")
                      and (args.parameter is None or port["name"] == args.parameter)]
        require(len(parameters) == 1, "select exactly one declared parameter with --parameter")
        self.parameter = parameters[0]
        groups = [group["name"] for group in self.session["execution-groups"]
                  if args.group is None or group["name"] == args.group]
        require(len(groups) == 1, "select exactly one execution group with --group")
        self.group = groups[0]
        self.phase = "preparation"
        self.prepared = False
        self.completed = False
        self.evidence = {"deployment": str(args.deployment.resolve()), "name": self.runner.spec["name"],
                         "graph": self.graph, "node": args.node, "passed": False,
                         "validation": "functional local control; numerical and timing qualification excluded",
                         "installed_artifacts": self.runner.spec["artifacts"],
                         "checks": {}, "commands": []}

    def request(self, argv):
        result = self.client(self.runner.socket, argv, timeout=self.args.timeout)
        self.evidence["commands"].append({"phase": self.phase, "argv": argv, "response": result})
        return result

    def reject(self, argv, state, *, diagnostic=None):
        try:
            self.request(argv)
        except deploy.DeploymentError as error:
            message = str(error)
            require(message.startswith("control rejected:"),
                    f"transport failure cannot establish operator rejection: {message}")
            if diagnostic:
                require(diagnostic in message, f"expected rejection diagnostic {diagnostic!r}: {message}")
            result = {"argv": argv, "error": message}
        else:
            raise deploy.DeploymentError(f"invalid request was accepted: {argv}")
        status = self.request(["status"])
        require(status["state"] == state, f"rejection changed {state} lifecycle: {status}")
        result["status"] = status
        return result

    def properties(self):
        return self.request(["properties", self.graph])["result"]["properties"]

    def generation(self):
        return self.request(["property-generation", self.graph, self.args.node])["result"]

    def active_values(self):
        observed = self.properties()
        for name, value in (("gain", self.args.gain), ("pole", self.args.pole)):
            expected = {"type": "float", "bits": struct.unpack("=I", struct.pack("=f", value))[0]}
            require(observed.get(f"{self.args.node}:{name}") == expected,
                    f"active {name} does not match the submitted Float value")
        return observed

    def invalid(self, state):
        # Other nodes' parameter observations can advance during source delivery.
        # Check the target transaction and its own scalar generations.
        target_names = [f"{self.args.node}:{name}" for name in ("gain", "pole")]
        snapshot = self.properties()
        before_properties = {name: snapshot[name] for name in target_names}
        before_generation = self.generation()
        results = {}
        for name, argv in invalid_transactions(self.graph, self.args.node):
            results[name] = self.reject(argv, state)
            snapshot = self.properties()
            properties = {name: snapshot[name] for name in target_names}
            generation = self.generation()
            require(properties == before_properties, f"{name} changed active properties")
            require(generation == before_generation, f"{name} changed property generations")
            results[name].update({"properties": properties, "generation": generation})
        self.evidence["checks"][f"invalid_{state.lower()}"] = results

    def transaction(self, state):
        before = self.generation()
        changed = self.request(["properties-set", self.graph,
                                f"{self.args.node}:gain", "float", str(self.args.gain),
                                f"{self.args.node}:pole", "float", str(self.args.pole)])
        result = changed["result"]
        require(changed["state"] == state, "valid transaction changed lifecycle")
        require(result["outcome"] == ("active" if state == "Running" else "submitted"),
                f"incorrect property submission/adoption outcome: {changed}")
        require(result["active_adoption_observed"] == (state == "Running"),
                f"incorrect active adoption observation: {changed}")
        after = self.generation()
        if state == "Running":
            require(after["requested"] > before["requested"] and after["active"] == after["requested"],
                    "running transaction did not advance and adopt its generation")
        return {"before": before, "response": changed, "after": after,
                "active_properties": self.active_values() if state == "Running" else None}

    def prepared_checks(self):
        self.invalid("Ready")
        bindings = {"PACKAGE": str(self.runner.package), "PREFIX": str(self.args.pipewire_prefix.resolve()),
                    "RUNTIME": str(self.runner.runtime), "REMOTE": self.runner.record["remote"],
                    "FITS": str(self.args.fits.resolve())}
        configured = self.session["parameters"].get(f"{self.graph}:{self.parameter['name']}")
        pending_initial = configured is not None
        if configured is None:
            configured = str(self.args.parameter_file) if self.args.parameter_file else \
                self.runner.spec["environment"].get("PIPEWIREAO_RTC_PARAMETER_RECONSTRUCTOR")
            require(configured is not None,
                    "live-update-only property check requires --parameter-file")
        reference = re.fullmatch(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", configured)
        if reference:
            configured = self.runner.environment("rtc", bindings)[reference[1]]
        payload = deploy.substitute(configured, bindings)
        argv = ["parameter", self.graph, self.parameter["name"], self.parameter["element-type"],
                "x".join(map(str, self.parameter["shape"])), self.parameter["schema"], payload]
        if not pending_initial:
            # This control fixture explicitly queues a value while stopped.
            # Normal preloaded profiles do not duplicate it at startup.
            self.evidence["checks"]["stopped_parameter_submission"] = self.request(argv)
        rejected = self.reject(argv, "Ready", diagnostic="already pending")
        require(rejected["status"]["result"]["discarded_buffers"] == 0,
                "pending parameter rejection consumed source input")
        self.evidence["checks"]["pending_initial_parameter"] = rejected
        self.evidence["checks"]["stopped_transaction"] = self.transaction("Ready")
        require(self.request(["status"])["result"]["discarded_buffers"] == 0,
                "source consumed input before admission")

    def running_checks(self):
        self.phase = "running"
        self.invalid("Running")
        self.evidence["checks"]["running_transaction"] = self.transaction("Running")
        stopped = self.request(["stop", self.group])
        require(stopped["state"] == "Running", "group stop changed session lifecycle")
        before = self.request(["status"])
        time.sleep(self.args.hold_seconds)
        after = self.request(["status"])
        require(before["result"]["discarded_buffers"] == after["result"]["discarded_buffers"],
                "stopped execution group continued source delivery")
        started = self.request(["start", self.group])
        require(started["state"] == "Running", "group start changed session lifecycle")
        self.evidence["checks"]["group_stop_start"] = {"stop": stopped, "held_before": before,
                                                      "held_after": after, "start": started}
        self.evidence["checks"]["running_reset_rejection"] = self.reject(["reset"], "Running")
        self.request(["session-stop"])
        reset = self.request(["reset"])
        require(reset["state"] == "Ready", "stopped reset did not preserve Ready")
        self.evidence["checks"]["stopped_reset"] = reset
        submitted = self.transaction("Ready")
        restarted = self.request(["session-start"])
        active = self.generation()
        require(restarted["state"] == "Running", "restart did not reach Running")
        require(active["requested"] > submitted["before"]["requested"]
                and active["active"] == active["requested"], "stopped transaction was not adopted after start")
        self.evidence["checks"]["adoption_after_restart"] = {"submission": submitted,
                                                             "start": restarted, "generation": active,
                                                             "properties": self.active_values()}
        self.completed = True
        self.phase = "shutdown"
        self.runner.stopping = True

    def run(self):
        original_spawn, original_check = self.runner.spawn, self.runner.check

        def spawn(role, argv, environment):
            if role == "rtc":
                self.evidence["runtime_override"] = enable_looping_source(self.runner.runtime / "rtc/session.conf")
            original_spawn(role, argv, environment)

        def control(path, argv, timeout=8):
            if argv == ["session-start"] and not self.prepared:
                self.prepared = True
                self.prepared_checks()
            result = self.client(path, argv, timeout=timeout)
            self.evidence["commands"].append({"phase": self.phase, "argv": argv, "response": result})
            return result

        def check():
            original_check()
            if self.runner.record["admitted"] and not self.completed:
                self.running_checks()

        self.runner.spawn, self.runner.check = spawn, check
        previous_signals = {number: signal.getsignal(number) for number in (signal.SIGTERM, signal.SIGINT)}
        for number in previous_signals:
            signal.signal(number, lambda _number, _frame: setattr(self.runner, "stopping", True))
        deploy.control = control
        try:
            self.runner.run()
            require(self.completed, "property checks were interrupted before completion")
            require(self.runner.runtime is not None and not self.runner.runtime.exists(),
                    "fresh owned runtime remains after shutdown")
            require(all(process.poll() is not None for _, process in self.runner.processes),
                    "owned process survived shutdown")
            shutdown = [entry["argv"][0] for entry in self.evidence["commands"] if entry["phase"] == "shutdown"]
            require("session-stop" in shutdown and "quit" in shutdown
                    and shutdown.index("session-stop") < shutdown.index("quit"),
                    "launcher did not complete ingress stop before quit")
            self.evidence["checks"]["shutdown_clean"] = True
            self.evidence["passed"] = True
        except BaseException as error:
            self.evidence["error"] = str(error)
            raise
        finally:
            deploy.control = self.client
            for number, previous in previous_signals.items():
                signal.signal(number, previous)
            self.evidence["deployment_record"] = self.runner.record
            self.args.output.parent.mkdir(parents=True, exist_ok=True)
            self.args.output.write_text(json.dumps(self.evidence, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--deployment", type=Path, required=True)
    parser.add_argument("--fits", type=Path, required=True)
    parser.add_argument("--node", required=True, help="scientific node declaring Float gain and pole")
    parser.add_argument("--gain", type=float, required=True)
    parser.add_argument("--pole", type=float, required=True)
    parser.add_argument("--graph")
    parser.add_argument("--parameter")
    parser.add_argument("--parameter-file", type=Path)
    parser.add_argument("--group")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--runtime", type=Path, default=Path(f"/run/user/{os.getuid()}/rtc-property-check"))
    parser.add_argument("--pipewire-prefix", type=Path, default=Path("/opt/pipewireao"))
    parser.add_argument("--hold-seconds", type=float, default=0.2)
    parser.add_argument("--timeout", type=float, default=8, help="deadline for each control request")
    args = parser.parse_args()
    if (not all(math.isfinite(value) for value in (args.gain, args.pole, args.hold_seconds, args.timeout))
            or args.hold_seconds <= 0 or args.timeout <= 0):
        parser.error("property values must be finite; hold interval and control deadline must be positive")
    checker = PropertyCheck(args)
    checker.run()
    print(f"QUALIFIED property controls {checker.runner.spec['name']}; evidence={args.output}")


if __name__ == "__main__":
    main()
