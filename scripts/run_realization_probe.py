#!/usr/bin/env python3
"""Development-only wrapper for the ignored same-process realization test."""

import argparse
import os
from pathlib import Path
import sys


TEST_NAME = "live::wireplumber::tests::same_process_unload_fences_before_next_realization"
BINARY_ENV = "PIPEWIREAO_REALIZATION_TEST_BINARY"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True)
    parser.add_argument("--remote", required=True)
    parser.add_argument("--start-paused", action="store_true")
    parser.add_argument("--control-node", required=True)
    parser.add_argument("--control-instance", required=True, type=int)
    parser.add_argument("--wireplumber-client", nargs=2, required=True,
                        metavar=("ID", "SERIAL"))
    parser.add_argument("--realization-node", required=True)
    args = parser.parse_args()

    binary_value = os.environ.get(BINARY_ENV)
    if not binary_value:
        parser.error(f"{BINARY_ENV} must name an absolute executable")
    binary = Path(binary_value)
    if not binary.is_absolute() or not binary.is_file() or not os.access(binary, os.X_OK):
        parser.error(f"{BINARY_ENV} must name an absolute executable")

    try:
        manager_id = int(args.wireplumber_client[0], 10)
        manager_serial = int(args.wireplumber_client[1], 10)
    except ValueError:
        parser.error("--wireplumber-client requires numeric ID and SERIAL")

    os.environ["PIPEWIREAO_REALIZATION_REMOTE"] = args.remote
    os.environ["PIPEWIREAO_REALIZATION_CONFIG"] = args.config
    os.environ["PIPEWIREAO_REALIZATION_MANAGER_ID"] = str(manager_id)
    os.environ["PIPEWIREAO_REALIZATION_MANAGER_SERIAL"] = str(manager_serial)
    os.environ["PIPEWIREAO_REALIZATION_MARKER_NAME"] = args.realization_node

    argv = [str(binary), "--ignored", "--exact", TEST_NAME, "--nocapture"]
    os.execv(str(binary), argv)
    return 127


if __name__ == "__main__":
    sys.exit(main())
