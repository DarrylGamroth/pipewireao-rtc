#!/usr/bin/env python3
"""Terminate an identified development-test child through a Linux pidfd."""
import argparse
import os
from pathlib import Path
import signal


def terminate(pid, parent_pid, start_ticks):
    fd = os.pidfd_open(pid)
    try:
        # Open the pidfd first. If this process exits during validation, the
        # signal fails rather than targeting a later occupant of its numeric PID.
        fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
        if int(fields[1]) != parent_pid or int(fields[19]) != start_ticks:
            raise RuntimeError("Test owner identity changed; no signal sent")
        signal.pidfd_send_signal(fd, signal.SIGKILL)
    finally:
        os.close(fd)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pid", type=int)
    parser.add_argument("parent_pid", type=int)
    parser.add_argument("start_ticks", type=int)
    args = parser.parse_args()
    terminate(args.pid, args.parent_pid, args.start_ticks)
