#!/usr/bin/env python3
"""Offline scheduler/idle attribution for a bounded Classic diagnostic case.

All clocks are monotonic nanoseconds. Completed intervals enter summaries only
when both endpoints fall inside the attested capture window. Edge intervals are
retained with censorship flags. A wakeup tracepoint measures scheduler-observed
wakeup to switch-in, not the complete physical wake or packet handoff time.
"""
from __future__ import annotations

import argparse
from collections import Counter
import csv
import hashlib
import json
from pathlib import Path
import re

from classic_wire import open_evidence


EVENT = re.compile(r'\[(\d+)\]\s+(\d+)\.(\d{1,9}):\s+([\w]+:[\w]+):\s+(.*)$')
FIELDS = re.compile(r'(\w+)=(.*?)(?=\s+\w+=|\s+==>|$)')
LOSS = re.compile(r'PERF_RECORD_LOST|\bLOST\b|\blost\s+\d+\s+(?:events|samples)|\b\d+\s+(?:events|samples)\s+lost', re.I)
SUPPORTED = {'sched:sched_switch', 'sched:sched_wakeup', 'sched:sched_wakeup_new',
             'sched:sched_migrate_task', 'power:cpu_idle'}


def summarize_ns(values):
    """Linear sample quantiles in microseconds; p99 needs at least 100 samples."""
    values = sorted(values)
    if not values:
        return {'count': 0, 'unit': 'us', 'p50': None, 'max': None}
    def quantile(fraction):
        index = (len(values) - 1) * fraction
        lower = int(index)
        upper = min(lower + 1, len(values) - 1)
        return (values[lower] + (values[upper] - values[lower]) * (index - lower)) / 1000
    result = {'count': len(values), 'unit': 'us', 'p50': quantile(.5), 'max': values[-1] / 1000}
    if len(values) >= 100:
        result['p99'] = quantile(.99)
    return result


def parse_perf(lines):
    """Parse standard perf script --ns output, retaining every malformed line."""
    events, errors, loss = [], [], []
    previous = -1
    for number, line in enumerate(lines, 1):
        text = line.strip()
        if LOSS.search(text):
            loss.append({'line': number, 'text': text})
            continue
        if not text or text.startswith('#'):
            continue
        try:
            match = EVENT.search(text)
            if match is None:
                raise ValueError('missing perf event prefix or nanosecond timestamp')
            cpu, seconds, fraction, kind, payload = match.groups()
            if kind not in SUPPORTED:
                raise ValueError(f'unsupported event {kind}')
            timestamp = int(seconds) * 1_000_000_000 + int(fraction.ljust(9, '0'))
            if timestamp < previous:
                raise ValueError('event timestamps move backward')
            previous = timestamp
            fields = dict(FIELDS.findall(payload))
            item = {'time_ns': timestamp, 'cpu': int(cpu), 'event': kind}
            if kind == 'sched:sched_switch':
                item.update(prev_tid=int(fields['prev_pid']), next_tid=int(fields['next_pid']),
                            prev_state=fields['prev_state'])
            elif kind.startswith('sched:sched_wakeup'):
                item.update(tid=int(fields['pid']), target_cpu=int(fields['target_cpu']),
                            success=int(fields.get('success', '1')))
            elif kind == 'sched:sched_migrate_task':
                item.update(tid=int(fields['pid']), orig_cpu=int(fields['orig_cpu']),
                            dest_cpu=int(fields['dest_cpu']))
            else:
                item.update(state=int(fields['state'], 0), idle_cpu=int(fields['cpu_id']))
            events.append(item)
        except (KeyError, ValueError) as error:
            errors.append({'line': number, 'error': str(error), 'text': text})
    return {'events': events, 'event_counts': dict(Counter(row['event'] for row in events)),
            'parse_errors': errors, 'loss_records': loss,
            'complete': bool(events) and not errors and not loss}


def target_threads(result, placement):
    """Resolve TIDs only from process identities and the saved thread snapshot."""
    processes = result.get('prepared', {}).get('processes', [])
    if not processes:
        raise ValueError('missing prepared process identities')
    targets = {}
    roles = set()
    for process in processes:
        role, pid = process['role'], process['pid']
        if role in roles:
            raise ValueError(f'duplicate prepared role {role}')
        roles.add(role)
        snapshot = placement.get(role, {})
        if snapshot.get('pid') != pid or not snapshot.get('available'):
            raise ValueError(f'placement does not attest prepared {role} PID {pid}')
        threads = snapshot.get('threads', [])
        if not threads or sorted(snapshot.get('thread_ids', [])) != sorted(row['tid'] for row in threads):
            raise ValueError(f'incomplete thread snapshot for {role}')
        for thread in threads:
            tid = thread['tid']
            if type(tid) is not int or tid <= 0 or tid in targets or not thread.get('name'):
                raise ValueError('invalid or duplicate thread identity')
            targets[tid] = {'role': role, 'pid': pid, 'tid': tid, 'name': thread['name'],
                            'affinity': thread.get('affinity'), 'scheduler': thread.get('scheduler')}
    return targets


def bounded_interval(start, end, window, trace_end, **extra):
    """Retain a possibly censored interval; never impute a missing endpoint."""
    lo, hi = window
    if (end is not None and end <= lo) or (start is not None and start >= hi):
        return None
    left = start is None or start < lo
    right = end is None or end > hi
    known_start = None if start is None else max(start, lo)
    observed_end = min(end if end is not None else trace_end, hi)
    if known_start is not None and observed_end < known_start:
        return None
    return dict(start_ns=start, end_ns=end, window_start_ns=known_start,
                window_end_ns=observed_end, left_censored=left, right_censored=right,
                observed_duration_ns=None if known_start is None else observed_end-known_start,
                **extra)


def completed_durations(rows):
    return [row['end_ns'] - row['start_ns'] for row in rows
            if not row['left_censored'] and not row['right_censored']]


def derive_scheduler(events, targets, window):
    """Pair switch-out/in and wakeup/in, preserving trace and window edges."""
    lo, hi = window
    if type(lo) is not int or type(hi) is not int or not 0 <= lo < hi or not events:
        raise ValueError('invalid window or empty scheduler trace')
    if events[-1]['time_ns'] <= lo or events[0]['time_ns'] >= hi:
        raise ValueError('scheduler trace does not overlap the attested window')
    trace_end = events[-1]['time_ns']
    threads = {tid: dict(identity, off_cpu=[], wake_to_switch_in=[], migrations=[],
                         wakeup_while_running=0, repeated_wakeups=0, switches_in_window=0)
               for tid, identity in targets.items()}
    state = {tid: {'status': 'unknown', 'out': None, 'wake': None, 'out_state': None} for tid in targets}
    idle, pending_idle, issues = [], {}, []
    def append_interval(rows, start, end, **extra):
        interval = bounded_interval(start, end, window, trace_end, **extra)
        if interval is not None:
            rows.append(interval)
    for event in events:
        timestamp, kind = event['time_ns'], event['event']
        if kind == 'sched:sched_switch':
            prev, following = event['prev_tid'], event['next_tid']
            if prev == following:
                continue
            if prev in state:
                current = state[prev]
                if current['status'] == 'off':
                    issues.append(f'TID {prev} switched out twice without switch-in at {timestamp}')
                current.update(status='off', out=timestamp, wake=None, out_state=event['prev_state'])
            if following in state:
                current, thread = state[following], threads[following]
                if current['status'] == 'running':
                    issues.append(f'TID {following} switched in twice without switch-out at {timestamp}')
                append_interval(thread['off_cpu'], current['out'], timestamp,
                                switch_out_state=current['out_state'], switch_in_cpu=event['cpu'])
                if current['wake'] is not None:
                    append_interval(thread['wake_to_switch_in'], current['wake'], timestamp,
                                    switch_in_cpu=event['cpu'])
                if lo <= timestamp < hi:
                    thread['switches_in_window'] += 1
                current.update(status='running', out=None, wake=None, out_state=None)
        elif kind.startswith('sched:sched_wakeup') and event['tid'] in state and event['success']:
            current, thread = state[event['tid']], threads[event['tid']]
            if current['status'] == 'running':
                if lo <= timestamp < hi:
                    thread['wakeup_while_running'] += 1
            elif current['wake'] is not None:
                if lo <= timestamp < hi:
                    thread['repeated_wakeups'] += 1
            else:
                current['wake'] = timestamp
        elif kind == 'sched:sched_migrate_task' and event['tid'] in threads and lo <= timestamp < hi:
            threads[event['tid']]['migrations'].append(event)
        elif kind == 'power:cpu_idle':
            cpu, idle_state = event['idle_cpu'], event['state']
            if idle_state in (-1, 4294967295, 18446744073709551615):
                start, saved_state = pending_idle.pop(cpu, (None, None))
                append_interval(idle, start, timestamp, cpu=cpu, state=saved_state)
            else:
                if cpu in pending_idle:
                    issues.append(f'CPU {cpu} entered idle twice without exit at {timestamp}')
                pending_idle[cpu] = (timestamp, idle_state)
    for tid, current in state.items():
        if current['out'] is not None:
            append_interval(threads[tid]['off_cpu'], current['out'], None,
                            switch_out_state=current['out_state'], switch_in_cpu=None)
        if current['wake'] is not None:
            append_interval(threads[tid]['wake_to_switch_in'], current['wake'], None, switch_in_cpu=None)
    for cpu, (start, idle_state) in pending_idle.items():
        append_interval(idle, start, None, cpu=cpu, state=idle_state)
    groups = {}
    for thread in threads.values():
        key = thread['role'], thread['name']
        group = groups.setdefault(key, {'role': key[0], 'name': key[1], 'tids': [],
                                        'off': [], 'wake': [], 'censored_off_cpu_count': 0,
                                        'censored_wakeup_count': 0, 'migration_count': 0})
        group['tids'].append(thread['tid'])
        group['off'].extend(completed_durations(thread['off_cpu']))
        group['wake'].extend(completed_durations(thread['wake_to_switch_in']))
        group['censored_off_cpu_count'] += sum(row['left_censored'] or row['right_censored'] for row in thread['off_cpu'])
        group['censored_wakeup_count'] += sum(row['left_censored'] or row['right_censored'] for row in thread['wake_to_switch_in'])
        group['migration_count'] += len(thread['migrations'])
    for group in groups.values():
        group['off_cpu'] = summarize_ns(group.pop('off'))
        group['wake_to_switch_in'] = summarize_ns(group.pop('wake'))
    idle_groups = []
    for cpu, idle_state in sorted({(row['cpu'], row['state']) for row in idle}, key=lambda pair: (pair[0], -1 if pair[1] is None else pair[1])):
        rows = [row for row in idle if (row['cpu'], row['state']) == (cpu, idle_state)]
        idle_groups.append({'cpu': cpu, 'state': idle_state, 'duration': summarize_ns(completed_durations(rows)),
                            'censored_count': sum(row['left_censored'] or row['right_censored'] for row in rows)})
    return {'threads': list(threads.values()), 'groups': list(groups.values()),
            'idle_intervals': idle, 'idle_groups': idle_groups, 'pairing_errors': issues,
            'trace_start_ns': events[0]['time_ns'], 'trace_end_ns': trace_end,
            'window_covered': events[0]['time_ns'] <= lo and trace_end >= hi}


def read_callbacks(lines, role, declared=None, expected_count=None):
    """Read recorded callback intervals and reject omissions and truncation."""
    source = iter(lines)
    if role == 'fgn':
        match = re.fullmatch(r'# capacity=(\d+) used=(\d+) omitted=(\d+)\s*', next(source, ''))
        if match is None:
            raise ValueError('FGN trace lacks capacity/use/omission header')
        capacity, used, omitted = map(int, match.groups())
    elif role == 'jfg' and isinstance(declared, dict):
        capacity, used, omitted = (declared.get(key) for key in ('capacity', 'records', 'omitted'))
    else:
        raise ValueError('missing JFG callback trace counters')
    if (any(type(value) is not int for value in (capacity, used, omitted))
            or capacity <= 0 or not 0 <= used <= capacity or omitted != 0):
        raise ValueError('callback trace has omissions or invalid counters')
    if expected_count is not None and used != expected_count:
        raise ValueError('callback count differs from expected complete row window')
    reader = csv.DictReader(source)
    required = {'callback', 'sequence', 'offset', 'start_ns', 'end_ns'}
    if role == 'fgn':
        required.add('result')
    if not required.issubset(reader.fieldnames or []):
        raise ValueError('missing callback CSV columns')
    rows, previous_end = [], 0
    for ordinal, row in enumerate(reader):
        item = {key: int(row[key]) for key in required}
        if len(rows) >= used or item['callback'] != ordinal + 1:
            raise ValueError('extra or unordered callback records')
        if not 0 < item['start_ns'] <= item['end_ns'] or item['start_ns'] < previous_end:
            raise ValueError('invalid or overlapping callback intervals')
        if expected_count is not None and (item['sequence'], item['offset']) != (ordinal // 32, (ordinal % 32) * 11):
            raise ValueError('callback frame/offset identities are incomplete or unordered')
        if role == 'fgn' and item['result'] not in (0, 1):
            raise ValueError('FGN callback failed or returned unknown result flags')
        previous_end = item['end_ns']
        rows.append(item)
    if len(rows) != used:
        raise ValueError('truncated callback CSV')
    return rows


def callback_intersections(callbacks, thread, window, trace_bounds=None):
    """Intersect callback wall intervals with that exact thread's known off CPU."""
    rows = []
    off = thread['off_cpu']
    cursor = 0
    for callback in callbacks:
        start, end = callback['start_ns'], callback['end_ns']
        if end <= window[0] or start >= window[1]:
            continue
        while cursor < len(off) and off[cursor]['window_end_ns'] <= start:
            cursor += 1
        duration, uncertain = 0, False
        index = cursor
        while index < len(off):
            interval = off[index]
            known_start = interval['window_start_ns']
            if known_start is not None and known_start >= end:
                break
            if interval['window_end_ns'] > start:
                if known_start is None:
                    uncertain = True
                else:
                    duration += max(0, min(end, interval['window_end_ns']) - max(start, known_start))
                if interval['end_ns'] is None and interval['window_end_ns'] < end:
                    uncertain = True
            index += 1
        censored = (start < window[0] or end > window[1]
                    or (trace_bounds is not None and
                        (start < trace_bounds[0] or end > trace_bounds[1])))
        rows.append(dict(callback, tid=thread['tid'], wall_ns=end-start, off_cpu_ns=duration,
                         wall_minus_off_cpu_ns=end-start-duration,
                         censored=censored, off_cpu_complete=not uncertain and not censored))
        if censored:
            # Preserve original endpoints, but do not present durations outside
            # the capture/trace boundary as measured callback attribution.
            rows[-1].update(wall_ns=None, off_cpu_ns=None, wall_minus_off_cpu_ns=None)
    completed = [row for row in rows if row['off_cpu_complete']]
    return {'role': thread['role'], 'name': thread['name'], 'tid': thread['tid'], 'rows': rows,
            'excluded_count': len(rows)-len(completed),
            'outside_window_count': len(callbacks)-len(rows),
            'wall': summarize_ns([row['wall_ns'] for row in completed]),
            'off_cpu': summarize_ns([row['off_cpu_ns'] for row in completed]),
            'wall_minus_off_cpu': summarize_ns([row['wall_minus_off_cpu_ns'] for row in completed]),
            'boundary': 'wall minus scheduler off CPU includes execution, interrupts, trace overhead and unobserved effects; it is not isolated science self time'}


def retained_path(path):
    path = Path(path)
    if path.is_file():
        return path
    for suffix in ('.zst', '.xz', '.gz'):
        candidate = Path(str(path) + suffix)
        if candidate.is_file():
            return candidate
    raise FileNotFoundError(path)


def record_hash(path, hashes):
    path = retained_path(path)
    digest = hashlib.sha256()
    with path.open('rb') as source:
        while block := source.read(1024 * 1024):
            digest.update(block)
    hashes[str(path.resolve())] = digest.hexdigest()
    return path


def discard_idle_intervals(scheduler):
    """Keep idle summaries; raw events remain in the hashed perf evidence."""
    rows = scheduler.pop('idle_intervals')
    scheduler['idle_interval_count'] = len(rows)
    scheduler['idle_censored_interval_count'] = sum(
        row['left_censored'] or row['right_censored'] for row in rows)


def analyze_case(case):
    case = Path(case).resolve()
    hashes, errors = {}, []
    def read_json(path):
        record_hash(path, hashes)
        with open_evidence(path) as source:
            return json.load(source)
    result = read_json(case / 'result.json')
    placement = read_json(case / 'run/placement-before.json')
    perf_path = record_hash(case / 'perf-events.txt', hashes)
    for name in ('perf.data', 'perf-events.txt.archive.json', 'perf.data.archive.json'):
        try:
            record_hash(case / name, hashes)
        except FileNotFoundError:
            pass
    with open_evidence(perf_path) as source:
        parsed = parse_perf(source)
    for name in ('perf.log', 'perf-decode.log'):
        try:
            path = record_hash(case / name, hashes)
            with open_evidence(path) as source:
                for number, line in enumerate(source, 1):
                    if LOSS.search(line):
                        parsed['loss_records'].append({'file': name, 'line': number, 'text': line.strip()})
        except FileNotFoundError:
            errors.append(f'missing {name}; capture/decode loss diagnostics unavailable')
    parsed['complete'] = parsed['complete'] and not parsed['loss_records']
    report = {'scope': 'instrumented scheduler/idle attribution; no physical wake or deadline guarantee',
              'case': str(case), 'path': result.get('path'), 'clock': 'CLOCK_MONOTONIC ns',
              'comparison_qualified': result.get('comparison_qualified', False),
              'source_result_errors': result.get('errors', []), 'qualified_trace': False,
              'qualified_callbacks': False, 'errors': errors, 'sha256': hashes,
              'perf': {key: value for key, value in parsed.items() if key != 'events'},
              'limits': ['Only observed switch pairs establish off CPU intervals.',
                         'Off CPU includes deliberate sleep and does not by itself establish scheduler delay.',
                         'Wakeup tracepoint to switch-in excludes work before the tracepoint and does not measure full physical wake time.',
                         'Censored intervals are retained but excluded from duration quantiles.',
                         'The release-to-capture interval includes source startup and capture stop margin, not only frame processing.',
                         'Thread placement is a saved snapshot; threads created later are not silently assigned identities.',
                         'Idle intervals are summarized here; individual events remain in the hashed original perf trace.',
                         'Julia time_ns and perf/native CLOCK_MONOTONIC share a clock only for the separately attested installed Julia 1.12.7 runtime; this is not a portable Julia clock guarantee. The host attestation identifies libjulia-internal SHA256 e36f5186f293ebc66ee8a5ebf0ee29cd6bf5e72ccf091f5a58ab44b59fdf52c5.',
                         'No scheduler attribution establishes scientific correctness.']}
    try:
        start = result['release_monotonic_ns']
        end = result['after_capture']['monotonic_ns']
        command = result.get('perf_command', [])
        if '--clockid=mono' not in command and not any(command[index:index+2] == ['--clockid', 'mono'] for index in range(len(command))):
            raise ValueError('perf CLOCK_MONOTONIC is not attested')
        if result.get('perf_decoded') is not True:
            raise ValueError('successful perf decoding is not attested')
        targets = target_threads(result, placement)
        scheduler = derive_scheduler(parsed['events'], targets, (start, end))
        # Free the large all-CPU idle list before deriving another window.
        discard_idle_intervals(scheduler)
        report['window'] = {'start_ns': start, 'end_ns': end,
                            'boundary': 'prepared receiver ingress release through capture completion; includes source startup and capture stop margin, not a pure frame-processing interval'}
        report['scheduler'] = scheduler
        # Enable/disable barriers bracket the events. The first/last event can
        # fall inside those barriers without loss: retain these trace edges.
        if not scheduler['window_covered']:
            report['limits'].append('The first/last observed event does not cover both window edges; edge intervals and callbacks remain censored.')
        errors.extend(scheduler['pairing_errors'])
        report['qualified_trace'] = parsed['complete'] and not errors
        role = result.get('path')
        if role in ('fgn-row', 'jfg-row'):
            owner, name = ('daemon', 'rtc-data-loop') if role == 'fgn-row' else ('node', 'data-loop.0')
            loops = [thread for thread in scheduler['threads'] if thread['role'] == owner and thread['name'] == name]
            if len(loops) != 1:
                raise ValueError('callback owner loop TID is not unambiguous in placement')
            native_role = role.split('-')[0]
            declared = None
            if native_role == 'fgn':
                candidates = sorted((case / 'run/native-ingress-trace').glob(f'fgn-process-{loops[0]["pid"]}-*.csv*'))
                if len(candidates) != 1:
                    raise ValueError('expected one FGN callback trace for the attested daemon')
                callback_path = candidates[0]
            else:
                node = read_json(case / 'run/node-report.json')
                declared = node.get('callback_trace')
                if not declared or declared.get('clock') != 'Julia time_ns monotonic nanoseconds':
                    raise ValueError('JFG monotonic callback trace is not attested')
                callback_path = case / 'run' / Path(declared['path']).name
            record_hash(callback_path, hashes)
            with open_evidence(callback_path) as source:
                callbacks = read_callbacks(source, native_role, declared, result['frames'] * 32)
            report['callbacks'] = callback_intersections(callbacks, loops[0], (start, end),
                                                        (scheduler['trace_start_ns'], scheduler['trace_end_ns']))
            report['qualified_callbacks'] = (report['qualified_trace']
                                              and report['callbacks']['excluded_count'] == 0
                                              and report['callbacks']['outside_window_count'] == 0)
            if callbacks:
                callback_start = max(start, callbacks[0]['start_ns'])
                callback_end = min(end, callbacks[-1]['end_ns'])
                if callback_start >= callback_end:
                    raise ValueError('callback trace does not overlap the attested window')
                span_scheduler = derive_scheduler(parsed['events'], targets, (callback_start, callback_end))
                discard_idle_intervals(span_scheduler)
                report['callback_span'] = {
                    'start_ns': callback_start, 'end_ns': callback_end,
                    'boundary': 'first recorded callback start through last recorded callback end; excludes source startup, includes gaps between frames, and is not the exact packet ingress/egress interval',
                    'scheduler': span_scheduler,
                    'qualified': report['qualified_callbacks'],
                }
    except (KeyError, TypeError, ValueError, OSError) as error:
        errors.append(f'{type(error).__name__}: {error}')
    record_hash(Path(__file__), hashes)
    record_hash(Path(__file__).with_name('classic_wire.py'), hashes)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('case', type=Path)
    parser.add_argument('--output', type=Path, help='default: CASE/scheduler-analysis.json; must be new')
    args = parser.parse_args()
    report = analyze_case(args.case)
    output = args.output or args.case / 'scheduler-analysis.json'
    with output.open('x') as destination:
        json.dump(report, destination, indent=2, allow_nan=False)
        destination.write('\n')
    print(json.dumps({'output': str(output), 'qualified_trace': report['qualified_trace'],
                      'qualified_callbacks': report['qualified_callbacks'], 'errors': report['errors']}))


if __name__ == '__main__':
    main()
