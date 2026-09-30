#!/usr/bin/env python3
"""Analyze existing HEART progress instrumentation; this is a functional diagnostic.

All timestamps are HEART CLOCK_MONOTONIC nanoseconds. A receive event is stamped
immediately after daoUdp_recv returns, not at NIC arrival. mvmAvailable advertises
new input BEFORE its computation. Only progress - aux is already traversed.
"""
from __future__ import annotations
import argparse
from collections import defaultdict
import csv
import hashlib
import io
import json
from pathlib import Path

FIELDS = ['thread', 'monotonic_ns', 'kind', 'frame', 'sync', 'progress', 'total', 'aux']


def read_trace(path):
    content = Path(path).read_bytes()
    lines = content.decode().splitlines()
    losses = {}
    data = []
    for line in lines:
        if line.startswith('# '):
            name, value = line[2:].split('=', 1)
            if name in losses:
                raise ValueError('duplicate loss counter')
            losses[name] = int(value)
        else:
            data.append(line)
    reader = csv.DictReader(io.StringIO('\n'.join(data)))
    if reader.fieldnames != FIELDS:
        raise ValueError('unexpected HEART progress trace columns')
    events = [{key: int(value) for key, value in row.items()} for row in reader]
    if not events or any(value < 0 for row in events for value in row.values()):
        raise ValueError('empty trace or negative event field')
    threads = {event['thread'] for event in events}
    if 'untraced_threads' not in losses or any(f'lost_thread_{thread}' not in losses for thread in threads):
        raise ValueError('missing loss counters: clean destructor export not established')
    if any(value != 0 for value in losses.values()):
        raise ValueError('trace lost events or untraced threads; refuse complete frame claims')
    return events, {'trace_sha256': hashlib.sha256(content).hexdigest(), 'loss_counters': losses}


def analyze(events, frames, all_subapertures_active=False):
    """Use shared sync identity, retaining distinct producer frame/bucket counters.

    Actual MVM pair completion additionally requires the documented Classic
    single-worker, non-streaming, 188-active-subaperture configuration. Without
    that attestation we report traversed subapertures, not completed arithmetic.
    """
    if type(frames) is not int or frames < 1:
        raise ValueError('positive frame count required')
    receives = defaultdict(list)
    stages = defaultdict(list)
    for event in events:
        if event['kind'] == 1:
            receives[event['frame']].append(event)
        elif event['kind'] in (5, 7, 8, 9, 10):
            stages[event['sync']].append(event)
    if sorted(receives) != list(range(frames)):
        raise ValueError('wire frame identities differ from the complete requested window')
    used_sync = set()
    rows = []
    for frame in range(frames):
        packets = sorted(receives[frame], key=lambda event: event['monotonic_ns'])
        if ([event['progress'] for event in packets] != list(range(1, 33))
                or any(event['total'] != 32 for event in packets)):
            raise ValueError(f'frame {frame}: expected 32 ordered receive events')
        syncs = {event['sync'] for event in packets}
        if len(syncs) != 1 or next(iter(syncs)) in used_sync:
            raise ValueError(f'frame {frame}: ambiguous receive-to-stage sync identity')
        sync = next(iter(syncs))
        used_sync.add(sync)
        first, terminal = packets[0]['monotonic_ns'], packets[-1]['monotonic_ns']
        work = sorted(stages[sync], key=lambda event: event['monotonic_ns'])
        if any(event['kind'] == 9 for event in work):
            raise ValueError('streaming MVM input submission is outside this Classic analysis')
        sh = [event for event in work if event['kind'] == 5]
        mvm = [event for event in work if event['kind'] == 7]
        done = [event for event in work if event['kind'] == 10]
        columns = [event for event in work if event['kind'] == 8]
        if not sh or not mvm or len(done) != 1:
            raise ValueError(f'frame {frame}: missing or ambiguous SH/MVM completion evidence')
        if len({event['thread'] for event in mvm + columns + done}) != 1 or len({event['thread'] for event in sh}) != 1:
            raise ValueError('multiple stage workers require a different progress interpretation')
        if len({event['frame'] for event in sh}) != 1 or len({event['frame'] for event in mvm + columns + done}) != 1:
            raise ValueError('stage bucket identity changed within a receive frame')
        if any(event['total'] != 352 or not 0 <= event['aux'] <= 188 or not 0 < event['progress'] <= 352 for event in sh):
            raise ValueError('SH dimensions differ from Classic 352 rows / 188 subapertures')
        if any(event['total'] != 188 or not 0 < event['aux'] <= event['progress'] <= 188 for event in mvm):
            raise ValueError('MVM dimensions differ from Classic 188 subapertures')
        if any(later['progress'] <= earlier['progress'] or later['aux'] < earlier['aux']
               for earlier, later in zip(sh, sh[1:])):
            raise ValueError('SH rows or completed subapertures do not advance monotonically')
        previous = 0
        for event in mvm:
            if event['progress'] - event['aux'] != previous:
                raise ValueError('MVM availability does not follow one sequential traversal')
            previous = event['progress']
        if previous != 188 or done[0]['progress'] != 188 or done[0]['total'] != 188:
            raise ValueError('MVM traversal did not complete all 188 subapertures')
        if done[0]['monotonic_ns'] < mvm[-1]['monotonic_ns'] or sh[-1]['aux'] != 188 or sh[-1]['progress'] != 352:
            raise ValueError('stage completion ordering or full SH count is inconsistent')
        if any(event['monotonic_ns'] < first for event in work):
            raise ValueError('stage work predates this frame reception; sync mapping is unsafe')
        before_sh = [event for event in sh if event['monotonic_ns'] < terminal]
        before_mvm = [event for event in mvm if event['monotonic_ns'] < terminal]
        traversed = max((event['progress'] - event['aux'] for event in before_mvm), default=0)
        # Explicit completion events can tighten the lower bound, if any occur.
        explicit = [event for event in work if event['kind'] in (8, 10) and event['monotonic_ns'] < terminal]
        for event in explicit:
            if event['total'] != 188 or not 0 <= event['progress'] <= 188:
                raise ValueError('invalid explicit MVM completion count')
            traversed = max(traversed, event['progress'])
        sh_count = max((event['aux'] for event in before_sh), default=0)
        pairs = traversed if all_subapertures_active else None
        rows.append({'wire_frame': frame, 'sync': sync, 'sh_bucket': sh[0]['frame'],
                     'mvm_bucket': mvm[0]['frame'], 'first_receive_ns': first,
                     'final_receive_ns': terminal, 'receive_span_ns': terminal - first,
                     'sh_completed_subapertures_lower_bound': sh_count,
                     'sh_completed_xy_gradient_values_lower_bound': 2 * sh_count,
                     'mvm_traversed_subapertures_lower_bound': traversed,
                     'mvm_completed_xy_pairs_lower_bound': pairs,
                     'mvm_completed_matrix_columns_lower_bound': None if pairs is None else 2 * pairs})
    unmatched = sorted(set(stages) - used_sync)
    if unmatched:
        raise ValueError(f'stage sync identities have no received frame: {unmatched}')
    return {'scope': 'instrumented functional readout overlap; no uninstrumented timing or capacity claim',
            'clock': 'CLOCK_MONOTONIC, nanoseconds', 'frames': frames,
            'terminal_boundary': 'timestamp immediately after final daoUdp_recv returns; not physical NIC arrival',
            'active_subaperture_attestation': all_subapertures_active,
            'sh_overlap_frames': sum(row['sh_completed_subapertures_lower_bound'] > 0 for row in rows),
            'mvm_traversal_overlap_frames': sum(row['mvm_traversed_subapertures_lower_bound'] > 0 for row in rows),
            'mvm_arithmetic_overlap_frames': None if not all_subapertures_active else sum(row['mvm_completed_xy_pairs_lower_bound'] > 0 for row in rows),
            'lower_bound_ranges': {key: {'min': min(row[key] for row in rows), 'max': max(row[key] for row in rows)}
                                   for key in ('sh_completed_subapertures_lower_bound', 'mvm_traversed_subapertures_lower_bound')},
            'column_mapping': 'one active subaperture = x/y pair = two adjacent reconstruction matrix columns; each column has 277 padded actuator rows',
            'limitations': ['progress - aux at mvmAvailable counts completed previous loop iterations; the advertised new batch is not counted',
                            'actual completed work may exceed this lower bound between trace events',
                            'MVM arithmetic interpretation requires all 188 subapertures active, non-streaming single-worker reconstruction and inclFluxFlag=0',
                            'SH completed count includes x/y gradients and flux; input readiness alone is not called completed work',
                            'events exactly at the final receive timestamp are excluded',
                            'the clock sample follows recv return; an unmeasured preemption gap prevents a bound against the exact syscall-return or NIC-arrival instant'],
            'per_frame': rows}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('trace', type=Path)
    parser.add_argument('--frames', type=int, default=63)
    parser.add_argument('--all-subapertures-active', action='store_true',
                        help='attest the documented Classic active-mask, flux, single-worker and non-streaming assumptions')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    events, provenance = read_trace(args.trace)
    result = analyze(events, args.frames, args.all_subapertures_active)
    result.update(provenance)
    result['analyzer_sha256'] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    args.output.write_text(json.dumps(result, indent=2) + '\n')


if __name__ == '__main__':
    main()
