#!/usr/bin/env python3
"""Run unchanged HEART with its existing bounded progress trace enabled.

This diagnostic delegates all controller/replay setup to the current campaign
command. It preserves raw trace and executable/mapped-library hashes. Coordinate
shared UDP ports before invocation; tracing is not a capacity measurement.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

from run_classic_campaign import command


def sha256(path):
    with Path(path).open('rb') as source:
        result = hashlib.sha256()
        while data := source.read(1024 * 1024):
            result.update(data)
    return result.hexdigest()


def descendants(pid):
    pending, seen = [pid], set()
    while pending:
        current = pending.pop()
        try:
            children = Path(f'/proc/{current}/task/{current}/children').read_text().split()
        except OSError:
            continue
        for child in map(int, children):
            if child not in seen:
                seen.add(child)
                pending.append(child)
    return seen


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--corpus', type=Path, default=Path('/home/dgamroth/.cache/rtc-classic-corpus63-20260930'))
    parser.add_argument('--frames', type=int, default=63)
    parser.add_argument('--observer-cpu', type=int, default=14)
    parser.add_argument('--rate-hz', type=int, default=100)
    parser.add_argument('--readout-us', type=int, default=2000)
    args = parser.parse_args()
    if args.observer_cpu not in os.sched_getaffinity(0):
        parser.error('observer CPU is outside the inherited affinity')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    trace = output / 'heart-progress.csv'
    cmd = command('heart', args.corpus.resolve(), output / 'run', args.rate_hz, args.readout_us, args.frames)
    heart_root = Path(cmd[cmd.index('--heart-root') + 1])
    executable = heart_root / 'source/template/bin/scaoTemplate'
    provenance = {'scope': 'functional trace diagnostic; excluded from capacity characterization',
                  'command': cmd, 'trace_environment': {'HRT_PROGRESS_TRACE_FILE': str(trace)},
                  'executable': str(executable), 'executable_sha256_before': sha256(executable),
                  'clock': 'CLOCK_MONOTONIC', 'mapped_files': [], 'observation_errors': []}
    env = dict(os.environ, HRT_PROGRESS_TRACE_FILE=str(trace))
    mapped = set()
    captured = set()
    with (output / 'launch.log').open('w') as log:
        process = subprocess.Popen(cmd, env=env, stdout=log, stderr=subprocess.STDOUT)
        # Preserve the campaign runner's inherited CPU availability, then pin
        # only this diagnostic observer. The runner validates its own CPU set.
        os.sched_setaffinity(0, {args.observer_cpu})
        provenance['observer_affinity_after_launch'] = sorted(os.sched_getaffinity(0))
        while process.poll() is None:
            for pid in descendants(process.pid):
                try:
                    if Path(f'/proc/{pid}/exe').resolve() != executable.resolve():
                        continue
                    # Capture after startup and again once ready; no hashing in the replay window.
                    phase = 'ready' if (output / 'run/gms-pre-ingress-clwfc.log').exists() else 'startup'
                    if (pid, phase) in captured:
                        continue
                    maps = Path(f'/proc/{pid}/maps').read_text()
                    (output / f'heart-{pid}-{phase}.maps').write_text(maps)
                    captured.add((pid, phase))
                    for line in maps.splitlines():
                        fields = line.split(maxsplit=5)
                        if len(fields) == 6 and fields[5].startswith('/'):
                            mapped.add(fields[5])
                except OSError as error:
                    provenance['observation_errors'].append(str(error))
            time.sleep(.025)
    provenance['returncode'] = process.returncode
    provenance['executable_sha256_after'] = sha256(executable)
    for filename in sorted(mapped):
        item = {'path': filename}
        try:
            item['sha256'] = sha256(filename)
        except OSError as error:
            item['error'] = str(error)
        provenance['mapped_files'].append(item)
    provenance['maps_observed'] = bool(captured)
    if trace.exists():
        provenance['trace_sha256'] = sha256(trace)
    provenance['heart_source_sha256'] = {}
    for relative in ('source/util/src/hrtProgressTrace.c', 'source/util/include/hrtProgressTrace.h',
                     'source/device/src/hrtStdWfsHandler.c', 'source/blocks/src/hrtWfsProcBlock.c',
                     'source/blocks/src/hrtHoReconBlock.c', 'source/config/src/hrtConfig.c',
                     'source/pipes/src/hrtHoPipe.c'):
        provenance['heart_source_sha256'][relative] = sha256(heart_root / relative)
    provenance['heart_git_revision'] = subprocess.check_output(['git', '-C', str(heart_root), 'rev-parse', 'HEAD'], text=True).strip()
    provenance['heart_git_status'] = subprocess.check_output(['git', '-C', str(heart_root), 'status', '--short'], text=True)
    provenance['helper_sha256'] = sha256(__file__)
    for name in ('run_classic_campaign.py', 'run_classic_heart_live.py'):
        provenance[f'{name}_sha256'] = sha256(Path(__file__).with_name(name))
    (output / 'diagnostic-provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')
    raise SystemExit(process.returncode)


if __name__ == '__main__':
    main()
