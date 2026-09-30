"""Record and check requested Classic laboratory thread placement off-path."""
from __future__ import annotations

import json
import re
from pathlib import Path

from lab_placement import snapshot_process


def check_loop(snapshot: dict, name: str, cpu: int, priority: int) -> None:
    matches = [thread for thread in snapshot['threads'] if thread['name'] == name]
    if len(matches) != 1:
        raise RuntimeError(f'expected one {name} thread, found {len(matches)}')
    thread = matches[0]
    if thread['affinity'] != [cpu] or thread['scheduler']['policy'] != 'fifo' or thread['scheduler']['priority'] != priority:
        raise RuntimeError(f'{name} placement differs from CPU {cpu}, FIFO {priority}: {thread}')


def record_placement(directory: Path, phase: str, processes: list, args) -> None:
    records = {}
    for role, process in processes:
        snapshot = snapshot_process(process.pid)
        records[role] = snapshot
        # Retain the failing observation before checking the requested policy.
        (directory / f'placement-{phase}.json').write_text(json.dumps(records, indent=2) + '\n')
        cpu = getattr(args, {'daemon': 'lab_loop_cpu', 'adapter': 'adapter_loop_cpu', 'node': 'node_loop_cpu'}.get(role, ''), None)
        if cpu is not None:
            check_loop(snapshot, 'rtc-data-loop' if role == 'daemon' else 'data-loop.0', cpu, args.lab_loop_rt_priority)
        if role == 'heart' and args.cpu_map:
            placements = re.findall(r"(?m)^([A-Za-z0-9.]+\.w)\s*=\s*\{\s*(\d+)\s*\}", args.cpu_map.read_text())
            if not placements:
                raise RuntimeError('HEART measurement CPU map has no explicit worker placements')
            for name, cpu in placements:
                check_loop(snapshot, name, int(cpu), 15)
    (directory / f'placement-{phase}.json').write_text(json.dumps(records, indent=2) + '\n')
