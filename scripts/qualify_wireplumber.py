#!/usr/bin/env python3
"""Development-only isolated NDArray compatibility check; not an RTC launcher."""
import argparse
import json
import os
from pathlib import Path
import signal
import struct
import subprocess
import tempfile
import time


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def write_cube(path, frames=32):
    cards = ["SIMPLE  =                    T", "BITPIX  =                   16",
             "NAXIS   =                    3", "NAXIS1  =                    4",
             "NAXIS2  =                    3", f"NAXIS3  = {frames:20d}",
             "BZERO   =                32768", "BSCALE  =                    1", "END"]
    header = "".join(card.ljust(80) for card in cards).encode("ascii")
    header += b" " * (-len(header) % 2880)
    payload = b"".join(struct.pack(">h", sample - 32768) for sample in range(1, frames * 12 + 1))
    path.write_bytes(header + payload + b"\0" * (-len(payload) % 2880))


def expected_digest():
    digest = 14695981039346656037
    for sample in range(1, 32 * 12 + 1):
        for byte in struct.pack("<H", sample):
            digest = ((digest ^ byte) * 1099511628211) & ((1 << 64) - 1)
    return digest


def wait_for(check, processes, description, seconds=8):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        for process in processes:
            if process.poll() is not None:
                raise RuntimeError(f"Process {process.args} exited with {process.returncode}")
        value = check()
        if value:
            return value
        time.sleep(0.02)
    raise RuntimeError(f"Timed out waiting for {description}")


def stop(process):
    if process.poll() is None:
        process.send_signal(signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--wireplumber-source", type=Path, required=True)
    parser.add_argument("--wireplumber-build", type=Path, required=True)
    parser.add_argument("--prefix", type=Path, default=Path("/opt/pipewireao"))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cpu", type=int, default=6)
    parser.add_argument("--stale-serial", action="store_true")
    parser.add_argument("--termination", choices=["graceful", "kill", "endpoint-loss"], default="graceful")
    options = parser.parse_args()
    if options.cpu < 2 or options.cpu not in os.sched_getaffinity(0):
        parser.error("Choose an available CPU other than CPU0/1")
    os.sched_setaffinity(0, {options.cpu})
    options.output.mkdir(parents=True, exist_ok=False)
    prefix = options.prefix.resolve()
    libraries = [p for p in (prefix / "lib", prefix / "lib64",
                             prefix / "lib/x86_64-linux-gnu")
                 if (p / "libpipewire-ao-0.3.so").exists()]
    if len(libraries) != 1:
        raise RuntimeError("Cannot identify exactly one AO library directory")
    library = libraries[0]
    wp_build = options.wireplumber_build.resolve()
    wp_source = options.wireplumber_source.resolve()
    linked = subprocess.check_output(["ldd", wp_build / "src/wireplumber"], text=True)
    if "libpipewire-ao-0.3.so.0" not in linked or "libpipewire-0.3.so.0" in linked:
        raise RuntimeError("WirePlumber must link to AO, without a stock PipeWire library")
    repository = Path(__file__).resolve().parents[1]
    processes = []
    logs = []
    receipt = {"scope": "isolated FITS → discard compatibility; no RTC admission or timing claim",
               "cpu": options.cpu, "frames": 32, "passed": False,
               "stale_serial": options.stale_serial, "termination": options.termination}
    try:
        with tempfile.TemporaryDirectory(prefix="rtc-wp-", dir="/tmp") as temporary:
            root = Path(temporary)
            remote = "ao-compatibility"
            env = dict(os.environ)
            env.pop("NOTIFY_SOCKET", None)
            env.update(PIPEWIREAO_RUNTIME_DIR=str(root), PIPEWIREAO_REMOTE=remote,
                       PIPEWIRE_REMOTE=remote,
                       PIPEWIREAO_MODULE_DIR=str(library / "pipewire-ao-0.3"),
                       PIPEWIREAO_SPA_PLUGIN_DIR=str(library / "spa-ao-0.2"),
                       LD_LIBRARY_PATH=f"{wp_build / 'lib/wp'}:{library}",
                       WIREPLUMBER_MODULE_DIR=str(wp_build / "modules"),
                       WIREPLUMBER_DATA_DIR=f"{root}:{wp_source / 'src'}",
                       WIREPLUMBER_CONFIG_DIR=str(root))
            cube = root / "frames.fits"
            write_cube(cube)
            modules = ["scheduler-v1", "protocol-native", "spa-node-factory", "client-node",
                       "metadata", "access", "link-factory"]
            core = {
                "context.properties": {"core.daemon": True, "core.name": remote,
                    "library.use-fallback": False, "default.clock.min-quantum": 1,
                    "default.clock.quantum-floor": 1, "mem.mlock-all": False,
                    "context.data-loops": [{"loop.name": "pilot-loop", "thread.name": "pilot-loop",
                                            "loop.class": ["data.rt"], "loop.idle": "eventfd",
                                            "thread.affinity": [options.cpu]}]},
                "context.spa-libs": {"support.*": "support/libspa-support",
                    "api.ndarray.*": "ndarray/libspa-ndarray",
                    "api.fits.source": "fits/libspa-fits",
                    "api.pipewireao.discard": "discard/libspa-pipewireao-discard"},
                "context.modules": [{"name": "libpipewire-module-" + name} for name in modules],
                "context.objects": [
                    {"factory": "spa-node-factory", "args": {"factory.name": "support.node.driver",
                     "node.name": "pilot-driver", "node.loop.name": "pilot-loop", "priority.driver": 200000}},
                    {"factory": "spa-node-factory", "args": {"factory.name": "api.fits.source",
                     "node.name": "pilot-source", "node.loop.name": "pilot-loop", "node.cache-params": False,
                     "api.fits.path": str(cube),
                     "api.fits.sample-rank": 2, "api.fits.rate": "100/1", "api.fits.loop": False,
                     "api.fits.readiness": "timerfd", "api.fits.output-mode": "frame",
                     "api.fits.schema": "org.pipewireao.test.wireplumber/1"}},
                    {"factory": "spa-node-factory", "args": {"factory.name": "api.pipewireao.discard",
                     "node.name": "pilot-sink", "node.loop.name": "pilot-loop", "node.want-driver": True,
                     "node.cache-params": False}},
                ],
            }
            (root / "core.conf").write_text(json.dumps(core, indent=2) + "\n")

            def launch(argv, label):
                log = (options.output / (label + ".log")).open("w")
                logs.append(log)
                process = subprocess.Popen(["taskset", "-c", str(options.cpu), *map(str, argv)],
                                           env=env, stdout=log, stderr=subprocess.STDOUT)
                processes.append(process)
                return process

            daemon = launch([prefix / "bin/pipewire-ao", "-c", root / "core.conf"], "core")
            wait_for(lambda: (root / remote).exists(), [daemon], "isolated AO socket")

            def snapshot():
                command = [prefix / "bin/pwao-dump", "-r", remote]
                return json.loads(subprocess.check_output(command, env=env, timeout=5))

            initial = snapshot()
            (options.output / "before.json").write_text(json.dumps(initial, indent=2) + "\n")
            nodes = {obj["info"]["props"].get("node.name"): obj for obj in initial
                     if obj["type"] == "PipeWire:Interface:Node"}
            source, sink = nodes["pilot-source"], nodes["pilot-sink"]
            ports = {obj["info"]["props"]["node.id"]: obj for obj in initial
                     if obj["type"] == "PipeWire:Interface:Port"}
            selected = {"source": source, "sink": sink,
                        "output": ports[source["id"]], "input": ports[sink["id"]]}
            args = {key: value for name, obj in selected.items()
                    for key, value in ((name + ".id", obj["id"]),
                                       (name + ".serial", obj["info"]["props"]["object.serial"]))}
            receipt["identities"] = dict(args)
            if options.stale_serial:
                args["source.serial"] += 1000
            receipt["requested_identities"] = dict(args)
            require(not any(obj["type"] == "PipeWire:Interface:Link" for obj in initial),
                    "Unexpected existing link on private core")
            configuration = """
context.properties = { library.use-fallback = false }
context.modules = [ { name = libpipewire-module-protocol-native } ]
wireplumber.profiles = {
    ao-pilot = { support.lua-scripting = required ao.ndarray-pilot = required }
}
wireplumber.components = [
    { name = libwireplumber-module-lua-scripting type = module
      provides = support.lua-scripting }
    { name = ndarray-pilot.lua type = script/lua
      provides = ao.ndarray-pilot requires = [ support.lua-scripting ]
      arguments = @ARGUMENTS@ }
]
""".replace("@ARGUMENTS@", json.dumps(args))
            (root / "scripts").mkdir()
            (root / "scripts/ndarray-pilot.lua").write_bytes(
                (repository / "deployment/wireplumber/ndarray-pilot.lua").read_bytes())
            (root / "wireplumber.conf").write_text(configuration)
            wp = launch(["stdbuf", "-oL", wp_build / "src/wireplumber", "-c", "wireplumber.conf", "-p", "ao-pilot"], "wireplumber")

            def complete():
                objects = snapshot()
                (options.output / "last.json").write_text(json.dumps(objects, indent=2) + "\n")
                current_sink = next(obj for obj in objects if obj["id"] == sink["id"])
                props = current_sink["info"]["params"]["Props"][0]
                # The custom properties are numeric SPA IDs, not a JSON control protocol.
                if props.get("id-01000000") == 32:
                    return objects

            if options.stale_serial:
                wait_for(lambda: "PILOT_NO_LINK" in (options.output / "wireplumber.log").read_text(),
                         [daemon, wp], "finite identity rejection")
                objects = snapshot()
                require(not any(obj["type"] == "PipeWire:Interface:Link" for obj in objects),
                        "Stale identity created a link")
                current_sink = next(obj for obj in objects if obj["id"] == sink["id"])
                require(current_sink["info"]["params"]["Props"][0]["id-01000000"] == 0,
                        "Stale identity allowed frame delivery")
                receipt["passed"] = True
                print("PASS: stale source serial rejected without linking or delivery")
                return

            completed = wait_for(complete, [daemon, wp], "32 discarded frames")
            (options.output / "connected.json").write_text(json.dumps(completed, indent=2) + "\n")
            links = [obj for obj in completed if obj["type"] == "PipeWire:Interface:Link"]
            require(len(links) == 1 and links[0]["info"]["state"] == "active", "Expected one active link")
            require(links[0]["info"]["format"] == {
                "mediaType": "application", "mediaSubtype": "ndarray", "elementType": "U16_LE",
                "shape": [4, 3], "layout": "COLUMN_MAJOR", "rate": {"num": 100, "denom": 1},
                "schema": "org.pipewireao.test.wireplumber/1"}, "Negotiated format differs from contract")
            current_sink = next(obj for obj in completed if obj["id"] == sink["id"])
            props = current_sink["info"]["params"]["Props"][0]
            require(props["id-01000001"] == 32, "Expected 32 data blocks")
            require(props["id-01000002"] == props["id-01000006"] == 768, "Expected 768 payload/digest bytes")
            require(props["id-01000003"] == 0, "Discard reports protocol errors")
            require(props["id-01000005"] & ((1 << 64) - 1) == expected_digest(), "Ordered payload digest differs")
            receipt["discard"] = props
            receipt["link"] = links[0]
            if options.termination == "endpoint-loss":
                subprocess.run([prefix / "bin/pwao-cli", "-r", remote, "destroy", str(source["id"])],
                               env=env, check=True, capture_output=True, timeout=5)
            elif options.termination == "kill":
                wp.kill()
                wp.wait(timeout=5)
                require(wp.returncode == -signal.SIGKILL, "WirePlumber did not terminate by SIGKILL")
            else:
                wp.send_signal(signal.SIGTERM)
                wp.wait(timeout=5)
                require(wp.returncode == 0, "WirePlumber did not exit gracefully")
            receipt["termination_returncode"] = wp.poll()
            def disconnected():
                objects = snapshot()
                if not any(obj["type"] == "PipeWire:Interface:Link" for obj in objects):
                    return objects

            clean = wait_for(disconnected, [daemon, wp] if options.termination == "endpoint-loss" else [daemon], "link removal")
            if options.termination == "endpoint-loss":
                require(not any(obj["id"] == source["id"] for obj in clean), "Required source still exists")
            (options.output / "after.json").write_text(json.dumps(clean, indent=2) + "\n")
            receipt["passed"] = True
    finally:
        for process in reversed(processes):
            stop(process)
        for log in logs:
            log.close()
        (options.output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"PASS: NDArray discovery, format, explicit link, 32 frames and owner teardown ({options.output})")


if __name__ == "__main__":
    main()
