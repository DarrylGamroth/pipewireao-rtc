#!/usr/bin/env python3
"""Match Classic row handoff timestamps on the attested host monotonic clock.

Source R is after UDP receive, P is publication, native G is an input-ready/pre-process
observation after collection/projection/region validation. Sink C brackets
metadata bookkeeping and transmit_command. R has frame/packet ordinal but no stored
row offset: the reviewed 32-packet Classic layout gives offset=11*(ordinal-1).
Sink S is a lifecycle Start event and is never used as a transmission timestamp.
"""
from __future__ import annotations
import argparse
import csv
import io
import json
from pathlib import Path
import re

from analyze_classic_scheduler import read_callbacks, record_hash, summarize_ns
from classic_wire import open_evidence


def read_native(lines):
    source = iter(lines)
    match = re.fullmatch(r'# capacity=(\d+) used=(\d+) omitted=(\d+)\s*', next(source, ''))
    if match is None:
        raise ValueError('native trace lacks capacity/use/omission header')
    capacity, used, omitted = map(int, match.groups())
    if capacity <= 0 or not 0 <= used <= capacity or omitted:
        raise ValueError('native trace has omissions or invalid counters')
    reader = csv.DictReader(source)
    if not {'event', 'frame', 'offset'}.issubset(reader.fieldnames or []):
        raise ValueError('native trace columns missing')
    rows = [{key: value if key in ('event', 'direction') else int(value)
             for key, value in row.items()} for row in reader]
    if len(rows) != used:
        raise ValueError('native trace CSV count differs from header')
    return rows


def match_rows(rows, event, frames, *, receive=False, native_input_ready=False):
    selected = [row for row in rows if row['event'] == event
                and (not native_input_ready or (row['direction'] == 'I' and row['port'] == 0))]
    expected = [(frame, offset) for frame in range(frames) for offset in range(0, 352, 11)]
    keys = [(row['frame'], 11*(row['ordinal']-1) if receive else row['offset']) for row in selected]
    if keys != expected:
        raise ValueError(f'{event} row identities are incomplete, duplicated or unordered')
    if receive and any(row['offset'] != 0 for row in selected):
        raise ValueError('source R offset differs from the reviewed unset-field convention')
    if event == 'P' and any(row['offset'] != 11*(row['ordinal']-1) for row in selected):
        raise ValueError('source publication ordinal and row offset disagree')
    return selected


def derive_handoffs(receives, publications, callbacks, window, input_ready=None, sinks=None, gc=None):
    if len(receives) != len(publications) or len(receives) != len(callbacks) or (input_ready is not None and len(input_ready) != len(callbacks)):
        raise ValueError('handoff counts disagree')
    rows = []
    for index, (receive, publication, callback) in enumerate(zip(receives, publications, callbacks)):
        r, p, begin, end = receive['start_ns'], publication['start_ns'], callback['start_ns'], callback['end_ns']
        chain = [r, p] + ([] if input_ready is None else [input_ready[index]['monotonic_ns']]) + [begin, end]
        if not window[0] <= chain[0] or chain[-1] > window[1] or any(a > b for a, b in zip(chain, chain[1:])):
            raise ValueError(f'negative or out-of-window handoff at callback {index+1}')
        row = dict(frame=callback['sequence'], offset=callback['offset'], receive_ns=r,
                   publication_ns=p, body_start_ns=begin, body_end_ns=end,
                   receive_to_publication_ns=p-r, publication_to_body_start_ns=begin-p,
                   body_wall_ns=end-begin)
        if input_ready is not None:
            g = input_ready[index]['monotonic_ns']
            row.update(native_input_ready_ns=g, publication_to_native_input_ready_ns=g-p, native_input_ready_to_body_start_ns=begin-g)
        if gc is not None:
            row.update(gc[index])
        if row['offset'] == 341 and sinks is not None:
            sink = sinks[row['frame']]
            if not end <= sink['start_ns'] <= sink['end_ns'] <= window[1]:
                raise ValueError(f'negative or out-of-window command handoff at frame {row["frame"]}')
            row.update(sink_start_ns=sink['start_ns'], sink_end_ns=sink['end_ns'],
                       body_end_to_sink_start_ns=sink['start_ns']-end,
                       sink_command_bracket_ns=sink['end_ns']-sink['start_ns'],
                       terminal_receive_to_sink_end_ns=sink['end_ns']-r)
        rows.append(row)
    terminal = [row for row in rows if row['offset'] == 341]
    fields = sorted({key for row in rows for key in row if key.endswith('_ns') and '_to_' in key}
                    | {'body_wall_ns'} | ({'sink_command_bracket_ns'} if sinks is not None else set()))
    def summaries(values):
        return {field: summarize_ns([row[field] for row in values if field in row]) for field in fields}
    report = {'rows': rows, 'all_rows': summaries(rows), 'terminal_rows': summaries(terminal),
              'terminal_after_first_100': summaries([row for row in terminal if row['frame'] >= 100])}
    if gc is not None:
        def counters(values):
            return {field: {'callbacks_changed': sum(row[field] != 0 for row in values),
                            'sum_delta': sum(row[field] for row in values),
                            'max_delta': max((row[field] for row in values), default=0)}
                    for field in ('gc_pause_delta', 'gc_total_time_delta_ns', 'gc_allocated_bytes_delta')}
        report['gc'] = {'all_rows': counters(rows), 'terminal_rows': counters(terminal),
                        'scope': 'process-wide Julia counter changes during callback bodies, including concurrent Julia tasks and diagnostic counter reads; sums do not measure isolated algorithm allocation or GC attribution'}
    return report


def read_gc(text):
    reader = csv.DictReader(io.StringIO(text))
    pairs = {'gc_pause_delta': ('gc_pause_start', 'gc_pause_end'),
             'gc_total_time_delta_ns': ('gc_total_time_start_ns', 'gc_total_time_end_ns'),
             'gc_allocated_bytes_delta': ('gc_allocated_bytes_start', 'gc_allocated_bytes_end')}
    columns = {field for pair in pairs.values() for field in pair}
    present = columns & set(reader.fieldnames or [])
    if not present:
        return None
    if present != columns:
        raise ValueError('partial Julia GC counter columns')
    rows = [{key: int(row[end])-int(row[start]) for key, (start, end) in pairs.items()} for row in reader]
    if any(value < 0 for row in rows for value in row.values()):
        raise ValueError('Julia GC counters move backward')
    return rows


def analyze_case(case):
    case = Path(case).resolve()
    hashes = {}
    def text(path):
        record_hash(path, hashes)
        with open_evidence(path) as source:
            return source.read()
    result = json.loads(text(case/'result.json'))
    report = {'case': str(case), 'path': result.get('path'), 'qualified': False, 'errors': [], 'sha256': hashes,
              'scope': 'instrumented monotonic handoff attribution; no packet epoch/NIC clock mixing or scientific arithmetic',
              'limits': ['R is a post-recv observation, P publication, G native input-ready/pre-process observation; all include diagnostic overhead.',
                         'Sink C is an inclusive command bracket containing metadata bookkeeping and transmit_command, not physical DM receipt; S is lifecycle Start.',
                         'Julia clock equivalence applies to the independently attested installed Julia1.12.7 libjulia-internal SHA256 e36f5186f293ebc66ee8a5ebf0ee29cd6bf5e72ccf091f5a58ab44b59fdf52c5, not all runtimes.',
                         'R to P includes assembler/admission, queue residence, downstream availability and any source-loop descheduling; it is not source self time.',
                         'Source R offsets are reconstructed from exact frame/ordinal identities using the reviewed 11-row/32-packet Classic layout.']}
    try:
        role = result['path'].split('-')[0]
        if result['path'] not in ('fgn-row', 'jfg-row') or result.get('diagnostic') is not True:
            raise ValueError('requires an instrumented Classic FGN/JFG row case')
        frames = result['frames']
        processes = result['prepared']['processes']
        pids = {item['role']: item['pid'] for item in processes}
        if len(pids) != len(processes):
            raise ValueError('prepared process roles are ambiguous')
        trace = case/'run/native-ingress-trace'
        def unique(pattern):
            paths = sorted(trace.glob(pattern + '.csv*'))
            if len(paths) != 1:
                raise ValueError(f'expected one trace matching {pattern}')
            return paths[0]
        source = read_native(io.StringIO(text(unique(f'source-rtc-heart-wfs-row-source-{pids["daemon"]}-*'))))
        receives = match_rows(source, 'R', frames, receive=True)
        publications = match_rows(source, 'P', frames)
        input_ready, declared, gc = None, None, None
        if role == 'fgn':
            callback_text = text(unique(f'fgn-process-{pids["daemon"]}-*'))
        else:
            node = json.loads(text(case/'run/node-report.json'))
            declared = node.get('callback_trace')
            if not declared or declared.get('clock') != 'Julia time_ns monotonic nanoseconds':
                raise ValueError('JFG monotonic callback clock is not attested')
            callback_text = text(case/'run'/Path(declared['path']).name)
            gc = read_gc(callback_text)
            native = read_native(io.StringIO(text(unique(f'ndarray-filter-{pids["node"]}-*'))))
            input_ready = match_rows(native, 'G', frames, native_input_ready=True)
        callbacks = read_callbacks(io.StringIO(callback_text), role, declared, frames*32)
        sink = read_native(io.StringIO(text(unique(f'sink-rtc-heart-std-dm-sink-{pids["daemon"]}-*'))))
        sends = [row for row in sink if row['event'] == 'C']
        if [row['frame'] for row in sends] != list(range(frames)) or any(row['result'] < 0 or row['gap_before'] for row in sends):
            raise ValueError('sink transmit identities incomplete, unordered or failed')
        report.update(derive_handoffs(receives, publications, callbacks,
                                     (result['release_monotonic_ns'], result['after_capture']['monotonic_ns']),
                                     input_ready, sends, gc))
        report['qualified'] = result.get('comparison_qualified') is True
        if not report['qualified']:
            report['errors'].append('source run did not pass comparison qualification')
    except (KeyError, ValueError, TypeError, OSError) as error:
        report['errors'].append(f'{type(error).__name__}: {error}')
    for name in ('analyze_classic_handoff.py', 'analyze_classic_scheduler.py', 'classic_wire.py'):
        record_hash(Path(__file__).with_name(name), hashes)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('case', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    report = analyze_case(args.case)
    output = args.output or args.case/'handoff-analysis.json'
    with output.open('x') as destination:
        json.dump(report, destination, indent=2, allow_nan=False)
        destination.write('\n')
    print(json.dumps({'output': str(output), 'qualified': report['qualified'], 'errors': report['errors']}))


if __name__ == '__main__':
    main()
