#!/usr/bin/env python3
"""Recompress retained wire archives without changing their uncompressed bytes."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
from classic_wire import open_evidence


def digest(path):
    result = hashlib.sha256()
    with open_evidence(path, "rb") as stream:
        while data := stream.read(1048576):
            result.update(data)
    return result.hexdigest()


def recompress(directory):
    manifest = directory / "wire-archives.json"
    records = json.loads(manifest.read_text())
    changes = []
    for record in records:
        original = directory / record["archive"]
        if original.suffix == ".zst":
            continue
        target = directory / (record["file"] + ".zst")
        if target.exists():
            raise ValueError(f"archive destination exists: {target}")
        checksum = hashlib.sha256()
        with target.open("xb") as output, open_evidence(original, "rb") as source:
            with subprocess.Popen(["zstd", "-q", "-T1", "-3", "--long=23", "--stdout"],
                                  stdin=subprocess.PIPE, stdout=output) as process:
                while data := source.read(1048576):
                    checksum.update(data)
                    process.stdin.write(data)
                process.stdin.close()
                if process.wait() != 0:
                    raise RuntimeError("compressor failed; original retained")
        expected = record["sha256_uncompressed"]
        if checksum.hexdigest() != expected or digest(target) != expected:
            raise ValueError("uncompressed checksum mismatch; original retained")
        changes.append({"source": original.name, "target": target.name,
                        "old_bytes": original.stat().st_size, "new_bytes": target.stat().st_size,
                        "sha256_uncompressed": expected})
        record["archive"] = target.name
        record["compression"] = "zstd level3 window8MiB"
        manifest.write_text(json.dumps(records, indent=2) + "\n")
        original.unlink()
    if changes:
        (directory / "archive-recompression.json").write_text(json.dumps(changes, indent=2) + "\n")
    return changes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("campaign", type=Path)
    args = parser.parse_args()
    for manifest in sorted(args.campaign.glob("*/wire-archives.json")):
        changes = recompress(manifest.parent)
        print(manifest.parent.name, sum(item["old_bytes"] - item["new_bytes"] for item in changes), flush=True)

if __name__ == "__main__":
    main()
