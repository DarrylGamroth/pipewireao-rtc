#!/usr/bin/env python3
"""Derive completed Classic SH/MVM prefixes from synchronous row callback ends.

This is source-derived work under an endpoint clock-envelope assumption, not a
measurement of individual science kernels, allocation freedom, or capacity.
"""
from __future__ import annotations
import argparse
import csv
from decimal import Decimal
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import re
import struct
import sys
import tomllib

from classic_wire import open_evidence

WFS_HEADER = struct.Struct('<4B8HIQII')
DEFAULT_FIXTURE = Path('/home/dgamroth/.cache/rtc-classic-matched-arrays-20260930/fixture')
ORIGINS_SHA256 = '8d648983755d662c98a4e66e9f6173d945a928c118153f1ca1699ebf17412279'
JFG_GRAPH_SHA256 = 'e5d8ae5f9dec86089f704b120b84343334dd5ae079465e79570c50821ea55425'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def integer(value):
    return type(value) is int


def digest(data):
    return hashlib.sha256(data).hexdigest()


class Evidence:
    def __init__(self):
        self.sha256 = {}

    def read(self, path):
        path = Path(path)
        data = path.read_bytes()
        self.sha256[str(path.resolve())] = digest(data)
        return data

    def json(self, path):
        return json.loads(self.read(path))


def clock_envelope(anchors, role, extra_margin_ns=0):
    require(integer(extra_margin_ns) and extra_margin_ns >= 0, 'clock margin must be a nonnegative integer')
    names = ('before_connect', 'after_close') if role == 'jfg' else ('before_run', 'after_run')
    intervals = []
    for name in names:
        anchor = anchors[name]
        before, realtime, after = (anchor[key] for key in ('monotonic_before_ns', 'realtime_ns', 'monotonic_after_ns'))
        require(all(integer(value) and value >= 0 for value in (before, realtime, after)) and before <= after,
                'invalid integer clock bracket')
        # Julia uses time() Float64 seconds *1e9, then integer conversion.
        rounding = math.ceil(math.ulp(realtime / 1e9) * 1e9 / 2 + math.ulp(float(realtime)) / 2) if role == 'jfg' else 0
        intervals.append({'name': name, 'monotonic_before_ns': before, 'monotonic_after_ns': after,
                          'float_conversion_margin_ns': rounding,
                          'offset_low_ns': realtime - after - rounding - extra_margin_ns,
                          'offset_high_ns': realtime - before + rounding + extra_margin_ns})
    require(intervals[0]['monotonic_after_ns'] < intervals[1]['monotonic_before_ns'], 'clock anchors are not ordered')
    return {'offset_low_ns': min(item['offset_low_ns'] for item in intervals),
            'offset_high_ns': max(item['offset_high_ns'] for item in intervals),
            'extra_margin_ns': extra_margin_ns, 'anchors': intervals,
            'assumption': 'realtime-minus-monotonic offset throughout replay remains within the hull of both endpoint brackets plus stated margins; unobserved interior clock excursions are not bounded by two anchors'}


def read_packets(path, frames):
    packets = []
    previous = -1
    with open_evidence(path, 'rt') as source:
        for ordinal, line in enumerate(source):
            require(ordinal < frames * 32, 'extra WFS packets')
            timestamp, length, payload = line.rstrip('\n').split('\t')
            raw = bytes.fromhex(payload)
            require(len(raw) >= WFS_HEADER.size, 'short WFS header')
            fields = WFS_HEADER.unpack_from(raw)
            _, _, bits, _, data_bytes, pixels, width, rows, _, _, sequence, datagrams, raster, _, frame, _ = fields
            expected_frame, packet = divmod(ordinal, 32)
            require((frame, sequence, datagrams, raster) == (expected_frame, packet + 1, 32, packet * 11 * 352),
                    'WFS frame/row packet order differs from the complete window')
            require((bits, width, rows, pixels, data_bytes) == (16, 352, 11, 3872, 7744)
                    and int(length) == WFS_HEADER.size + data_bytes + 8
                    and len(raw) == WFS_HEADER.size + data_bytes, 'WFS geometry/length differs from Classic')
            now = Decimal(timestamp) * 1_000_000_000
            require(now.is_finite() and now == now.to_integral_value() and now >= previous,
                    'WFS timestamps are nonfinite, subnanosecond or out of order')
            packets.append(int(now))
            previous = now
    require(len(packets) == frames * 32, 'incomplete WFS packet window')
    return packets


def read_callbacks(path, frames, role, declared=None):
    with Path(path).open(newline='') as source:
        if role == 'fgn':
            match = re.fullmatch(r'# capacity=(\d+) used=(\d+) omitted=(\d+)\n?', source.readline())
            require(match is not None, 'FGN trace lacks capacity/use/omission header')
            capacity, used, omitted = map(int, match.groups())
            require(capacity == 32768 and used <= capacity and omitted == 0, 'FGN trace overflow or invalid capacity')
        else:
            require(isinstance(declared, dict), 'missing JFG trace report')
            capacity, used, omitted = (declared.get(key) for key in ('capacity', 'records', 'omitted'))
            require(all(integer(value) for value in (capacity, used, omitted)) and 0 <= used <= capacity and omitted == 0,
                    'JFG trace omitted records or has invalid counters')
        require(used == frames * 32, 'trace count differs from complete row window')
        reader = csv.DictReader(source)
        required = {'callback', 'sequence', 'offset', 'start_ns', 'end_ns'} | ({'result'} if role == 'fgn' else set())
        require(required.issubset(reader.fieldnames or ()), 'trace columns missing')
        callbacks = []
        previous_end = 0
        for ordinal, row in enumerate(reader):
            require(ordinal < used, 'trace has more rows than its declared count')
            item = {key: int(row[key]) for key in required}
            frame, packet = divmod(ordinal, 32)
            require((item['callback'], item['sequence'], item['offset']) == (ordinal + 1, frame, packet * 11),
                    'trace sequence/offset order is missing, duplicated, invalid or rearranged')
            require(0 < item['start_ns'] <= item['end_ns'] and previous_end <= item['start_ns'],
                    'trace timestamps are invalid or callbacks overlap')
            # spa_fgn_process_result: NONE=0, PROPS_CHANGED=1; neither proves
            # a science output was produced. Complete-stream gates remain required.
            require(role != 'fgn' or item['result'] in (0, 1), 'FGN graph call failed or returned unknown flags')
            callbacks.append(item)
            previous_end = item['end_ns']
    require(len(callbacks) == used, 'trace CSV is truncated')
    return callbacks


def validate_fixture(fixture, run, arithmetic, evidence):
    origins_data = evidence.read(fixture / 'subaperture-origins.u32le')
    require(digest(origins_data) == ORIGINS_SHA256, 'ROI file differs from reviewed Classic ordering')
    origins = list(struct.iter_unpack('<II', origins_data))
    active = evidence.read(fixture / 'active-subapertures.u8')
    require(active == bytes([1]) * 188, 'requires all 188 subapertures active')
    require(len(origins) == 188 and all(0 <= y <= 330 and 0 <= x <= 330 for y, x in origins)
            and all(a[0] <= b[0] for a, b in zip(origins, origins[1:])), 'ROI geometry/order mismatch')
    profile_data = evidence.read(fixture / 'prepared-profile.toml')
    profile = tomllib.loads(profile_data.decode())
    detector, sh, dm = (profile[key] for key in ('detector', 'shack_hartmann', 'deformable_mirror'))
    require((detector['width'], detector['height'], sh['subaperture_count'], sh['subaperture_width'],
             sh['subaperture_height'], dm['controlled_vdm_size']) == (352, 352, 188, 22, 22, 221)
            and sh['subaperture_origins'] == [list(origin) for origin in origins], 'prepared profile differs from reviewed geometry')
    profile_hashes = [value for name, value in run.get('sha256', {}).items() if Path(name).name == 'prepared-profile.toml']
    require(profile_hashes == [digest(profile_data)], 'run does not attest this prepared profile')
    for name, recorded in run.get('parameter_sha256', {}).items():
        require(Path(name).name == name and digest(evidence.read(fixture / name)) == recorded,
                f'run parameter hash mismatch: {name}')
    for name in ('active-subapertures.u8', 'subaperture-origins.u32le', 'thresholds.f32le', 'reconstructor.f32le'):
        actual = digest(evidence.read(fixture / name))
        require(run.get('parameter_sha256', {}).get(name) == actual
                and arithmetic.get('fixture_sha256', {}).get(name) == actual,
                f'run/arithmetic fixture identity is missing or disagrees: {name}')
    return [sum(y + 22 <= offset + 11 for y, _ in origins) for offset in range(0, 352, 11)]


def validate_graph(directory, fixture, run, node, evidence):
    if run['role'] == 'jfg':
        require(node.get('row_workers') == 0 and node.get('mode') == 'row'
                and node.get('feedback_bridge_failed') is False and node.get('status') == 'stopped',
                'requires stopped JFG row run with zero helpers and intact feedback')
        source = evidence.read(Path(node['graph_fixture']))
        require(digest(source) == node.get('graph_sha256') == JFG_GRAPH_SHA256,
                'JFG authored graph is not the reviewed split fixture')
        text = source.decode()
        boundary = '        outputs = [\n            "pdm-command:demanded"\n            "vdm-feedback-to-controller:controller-constraint-feedback"\n        ]'
        expected, count = re.subn(r'^\s*outputs\s*=\s*\[.*?^\s*\]', boundary, text, flags=re.M | re.S)
        require(count == 1 and expected == node.get('live_graph_configuration')
                and digest(expected.encode()) == node.get('live_graph_sha256'), 'JFG live graph differs from reviewed output-boundary adaptation')
        require(node.get('public_data_inputs') == ['raw'] and node.get('fifo_inputs') is True
                and node.get('parameter_sha256', {}).get('subaperture-origins.u32le') == ORIGINS_SHA256,
                'JFG input mapping/order/ROI evidence missing')
        require(all(node.get('parameter_sha256', {}).get(name) == value
                    for name, value in run['parameter_sha256'].items())
                and node.get('prepared_profile_sha256') == digest(evidence.read(fixture / 'prepared-profile.toml')),
                'JFG runtime parameter/profile identity differs from runner evidence')
        return {'algorithm_path': 'split SH measurement block then synchronous incremental dense reconstruction',
                'graph_sha256': node['live_graph_sha256']}
    graph = evidence.read(directory / 'graph.conf').decode()
    daemon = evidence.read(directory / 'config/fgn-copper-live.conf').decode()
    require(digest(daemon.encode()) == run.get('daemon_configuration_sha256'), 'saved FGN daemon config hash mismatch')
    plugins = [Path(name) for name in run.get('sha256', {}) if Path(name).name == 'libcalculon_fgn_bundle.so']
    require(len(plugins) == 1, 'ambiguous FGN algorithm binary provenance')
    plugin = plugins[0]
    qualifier_path = plugin.parents[2] / 'scripts/qualify_fgn_revolt_classic.py'
    evidence.read(qualifier_path)
    spec = importlib.util.spec_from_file_location('classic_row_work_qualifier', qualifier_path)
    qualifier = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = qualifier
    spec.loader.exec_module(qualifier)
    evidence.read(qualifier.ROOT / 'examples/revolt-classic-row-feedback-filter-chain.conf.in')
    profile = qualifier.load_prepared_profile(fixture / 'prepared-profile.toml')
    expected = qualifier.resolve_row_feedback_config(plugin, profile, 11, 0, 7)
    require(expected.count('active = null') == 1, 'reviewed FGN template active field changed')
    expected = expected.replace('active = null', 'active = [ ' + ' '.join(['true'] * 188) + ' ]')
    expected = expected.replace(f'rate = [ {profile.frame_rate[0]} {profile.frame_rate[1]} ]', f'rate = [ {run["rate_hz"]} 1 ]')
    expected, count = re.subn(r'outputs = \[.*?\]', 'outputs = [ "pdm-command:demanded" "vdm-feedback-to-controller:controller-constraint-feedback" ]', expected, flags=re.S)
    require(count == 1 and graph == expected, 'FGN graph differs from the reviewed fixed synchronous generator')
    body = graph.split('filter.graph = ', 1)[1].rsplit('\n}', 1)[0]
    require(daemon.count('filter.graph = ') == 1 and body in daemon,
            'FGN deployed graph differs from saved generated graph')
    require(re.search(r'inputs\s*=\s*\[\s*"pixel-calibration:raw"', graph) is not None
            and 'workers = { helpers = 0 }' in graph and 'label = shwfs-row-reconstructor-f32' in graph,
            'FGN synchronous raw-input row composition missing')
    return {'algorithm_path': 'fused Rust SH row reconstruction with synchronous ordered column accumulation',
            'graph_sha256': digest(graph.encode()), 'recorded_algorithm_binary': str(plugin),
            'recorded_algorithm_binary_sha256': run['sha256'][str(plugin)]}


def derive_counts(callbacks, packets, prefixes, clock):
    require(len(callbacks) == len(packets) and len(callbacks) % 32 == 0, 'incomplete frame counts')
    require(len(prefixes) == 32 and prefixes[-1] == 188 and all(0 <= x <= 188 for x in prefixes)
            and prefixes == sorted(prefixes), 'invalid cumulative prefix map')
    first_anchor, last_anchor = clock['anchors'][0], clock['anchors'][-1]
    require(callbacks[0]['start_ns'] >= first_anchor['monotonic_after_ns']
            and callbacks[-1]['end_ns'] <= last_anchor['monotonic_before_ns'], 'callbacks lie outside clock anchors')
    low, high = clock['offset_low_ns'], clock['offset_high_ns']
    rows = []
    for frame in range(len(callbacks) // 32):
        terminal = packets[frame * 32 + 31]
        completed = []
        possible = []
        for packet in range(32):
            callback = callbacks[frame * 32 + packet]
            require(callback['start_ns'] + high >= packets[frame * 32 + packet],
                    'callback precedes its own input throughout the clock envelope')
            if callback['end_ns'] + high < terminal:
                completed.append(packet)
            if callback['end_ns'] + low < terminal:
                possible.append(packet)
        count = max((prefixes[packet] for packet in completed), default=0)
        rows.append({'frame': frame, 'terminal_packet_epoch_ns': terminal,
                     'callbacks_definitely_complete_before_terminal': len(completed),
                     'last_definitely_completed_row_offset': completed[-1] * 11 if completed else None,
                     'sh_completed_subapertures_lower_bound': count,
                     'sh_completed_xy_gradient_values_lower_bound': 2 * count,
                     'mvm_completed_xy_pairs_lower_bound': count,
                     'mvm_completed_matrix_columns_lower_bound': 2 * count,
                     'possible_completed_prefix_subapertures': max((prefixes[packet] for packet in possible), default=0)})
    counts = [row['sh_completed_subapertures_lower_bound'] for row in rows]
    return {'frames_with_positive_science_work_lower_bound': sum(count > 0 for count in counts),
            'subaperture_lower_bound_range': {'min': min(counts), 'max': max(counts)},
            'matrix_column_lower_bound_range': {'min': 2 * min(counts), 'max': 2 * max(counts)},
            'per_frame': rows}


def analyze(directory, fixture=DEFAULT_FIXTURE, extra_margin_ns=0):
    directory, fixture = Path(directory), Path(fixture)
    evidence = Evidence()
    run = evidence.json(directory / 'report.json')
    physical = evidence.json(directory / 'physical-summary.json')
    arithmetic = evidence.json(directory / 'arithmetic-acceptance.json')
    numerical = evidence.json(directory / 'numerical-summary.json')
    frames, role = run.get('frames'), run.get('role')
    require(integer(frames) and frames > 0 and role in ('fgn', 'jfg'), 'requires positive FGN/JFG frame count')
    require(run.get('qualified') is True and physical.get('qualified') is True and not run.get('errors')
            and run.get('process_returncodes') and all(code == 0 for code in run['process_returncodes']),
            'run lacks qualified wire/science result and normal child exits')
    require(run.get('receiver_mode') == 'row-block' and run.get('row_workers') == 0
            and run.get('rows_per_packet') == 11, 'only synchronous zero-helper Classic row mode is supported')
    require((physical.get('fits_width'), physical.get('fits_height'), physical.get('lines_per_datagram'),
             physical.get('captured_wfs_packets'), physical.get('captured_dm_commands')) == (352, 352, 11, frames * 32, frames),
            'physical record is not the complete requested geometry/window')
    require(arithmetic.get('arithmetic_consistency_passed') is True
            and arithmetic.get('frames') == frames
            and arithmetic.get('role') == role and arithmetic.get('mode') == 'row'
            and math.isfinite(arithmetic.get('minimum_flux_threshold_margin', -1))
            and arithmetic.get('minimum_flux_threshold_margin', -1) > 0
            and numerical.get('clipping_decision_mismatches') == 0,
            'arithmetic/active-flux/clipping evidence missing')
    wire = evidence.read(directory / 'dm-wire-um.f32')
    require(len(wire) == frames * 277 * 4 and digest(wire) == arithmetic.get('actual_commands_f32le_sha256'),
            'recorded command bytes differ from arithmetic evidence')
    prefixes = validate_fixture(fixture, run, arithmetic, evidence)
    node = evidence.json(directory / 'node-report.json') if role == 'jfg' else None
    graph = validate_graph(directory, fixture, run, node, evidence)
    if role == 'jfg':
        trace = directory / 'callback-trace.csv'
        callbacks = read_callbacks(trace, frames, role, node['callback_trace'])
        require(node.get('callback_count') == len(callbacks), 'JFG callback report mismatch')
        anchors = node['clock_anchors']
        provenance = {'runtime': node.get('runtime'), 'callback_boundary': node['callback_trace'].get('boundary'),
                      'allocation_scope': node['callback_trace'].get('allocation_scope'),
                      'pipewire': run.get('pipewire_provenance')}
    else:
        traces = list(directory.rglob('fgn-process-*.csv'))
        require(len(traces) == 1, 'requires exactly one FGN graph process trace')
        trace = traces[0]
        callbacks = read_callbacks(trace, frames, role)
        anchors = evidence.json(directory / 'diagnostic-library.json')
        native = run.get('pipewire_provenance', {})
        require(anchors.get('module_sha256') == native.get('ndarray_filter_chain_sha256')
                and anchors.get('module_sha256') is not None
                and anchors.get('sha256') == native.get('pipewire_client_library_sha256'),
                'diagnostic module/library identity differs from runner provenance')
        provenance = {'diagnostic': anchors, 'pipewire': native,
                      'callback_boundary': 'spa_fgn_graph_process call before feedback commit; includes trace-bracketing overhead',
                      'allocation_scope': 'not measured by this C trace'}
    evidence.read(trace)
    packet_base = directory / 'wfs-packets.tsv'
    packets = read_packets(packet_base, frames)
    packet_file = next(path for path in (packet_base, *(Path(str(packet_base) + suffix) for suffix in ('.zst', '.xz', '.gz'))) if path.is_file())
    evidence.read(packet_file)
    clock = clock_envelope(anchors, role, extra_margin_ns)
    wider_clock = clock_envelope(anchors, role, extra_margin_ns + 10000)
    return {'schema_version': 1, 'claim': 'DERIVED completed SH/MVM prefix lower bounds under fixed-graph and clock-envelope assumptions',
            'role': role, 'frames': frames, 'row_workers': 0, 'graph': graph,
            'clock_model': clock, 'result': derive_counts(callbacks, packets, prefixes, clock),
            'sensitivity_plus_10us': {'clock_model': wider_clock, 'result': derive_counts(callbacks, packets, prefixes, wider_clock)},
            'prefix_by_row_offset': {str(packet * 11): value for packet, value in enumerate(prefixes)},
            'units': '188 subapertures, 376 x/y matrix columns, 221 controlled output coordinates per column',
            'historical_strict_numerical_result': numerical, 'application_accuracy': 'not assessed',
            'provenance': provenance, 'input_sha256': evidence.sha256,
            'analyzer_sha256': digest(Path(__file__).read_bytes()),
            'limitations': ['individual SH/MVM kernels are not timestamped; callback completion plus reviewed synchronous source supplies the count',
                            'two anchors do not bound unobserved interior clock excursions; positive counts are conditional on the clock model',
                            'pcap timestamps identify local capture observations, not physical sensor/NIC arrival',
                            'normal return alone is insufficient: dropped row metadata can return Deferred; complete ordered callbacks and exact per-frame output are mandatory',
                            'helper workers, changed parameter plans and alternate graph topologies are excluded',
                            'JFG allocation counters cover the recorded callback body only; no whole-stack allocation, timing-capacity or physical-loop qualification']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run_directory', type=Path)
    parser.add_argument('--fixture', type=Path, default=DEFAULT_FIXTURE)
    parser.add_argument('--clock-margin-ns', type=int, default=0)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = analyze(args.run_directory, args.fixture, args.clock_margin_ns)
    args.output.write_text(json.dumps(result, indent=2, allow_nan=False) + '\n')


if __name__ == '__main__':
    main()
