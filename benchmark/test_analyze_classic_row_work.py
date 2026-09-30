"""Offline checks for source-derived counts, trace integrity and clock uncertainty."""
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from analyze_classic_row_work import (WFS_HEADER, clock_envelope, derive_counts,
                                      read_callbacks, read_packets, validate_graph, validate_fixture, Evidence, digest)


def anchors():
    return {'before_run': {'monotonic_before_ns': 100, 'realtime_ns': 1105, 'monotonic_after_ns': 110},
            'after_run': {'monotonic_before_ns': 100000, 'realtime_ns': 101005, 'monotonic_after_ns': 100010}}


def callbacks():
    return [{'callback': n + 1, 'sequence': 0, 'offset': 11 * n,
             'start_ns': 200 + n * 100, 'end_ns': 230 + n * 100, 'result': 0} for n in range(32)]


def packets():
    return [1150 + n * 100 for n in range(32)]


def write_callbacks(path, rows, role='fgn', used=32, omitted=0):
    fields = 'callback,sequence,offset,start_ns,end_ns' + (',result' if role == 'fgn' else '')
    prefix = f'# capacity=32768 used={used} omitted={omitted}\n' if role == 'fgn' else ''
    path.write_text(prefix + fields + '\n' + ''.join(','.join(str(row[key]) for key in fields.split(',')) + '\n' for row in rows))


def packet_line(frame, packet, stamp):
    fields = [0] * 16
    fields[2] = 16
    fields[4:8] = (7744, 3872, 352, 11)
    fields[10:13] = (packet + 1, 32, packet * 11 * 352)
    fields[-2] = frame
    raw = WFS_HEADER.pack(*fields) + bytes(7744)
    return f'{stamp}\t{len(raw) + 8}\t{raw.hex()}\n'


class RowWorkTests(unittest.TestCase):
    def test_clock_hull_uses_both_endpoints_and_extra_margin(self):
        values = anchors()
        values['after_run']['realtime_ns'] += 40
        model = clock_envelope(values, 'fgn', 10)
        self.assertEqual((model['offset_low_ns'], model['offset_high_ns']), (985, 1055))
        self.assertTrue(all(row['float_conversion_margin_ns'] == 0 for row in model['anchors']))
        with self.assertRaises(ValueError):
            clock_envelope(values, 'fgn', -1)
        values['before_run']['monotonic_after_ns'] = 99
        with self.assertRaises(ValueError):
            clock_envelope(values, 'fgn')

    def test_julia_float_seconds_anchor_rounding_is_included(self):
        values = {'before_connect': {'monotonic_before_ns': 100, 'realtime_ns': 1790793592074132992, 'monotonic_after_ns': 110},
                  'after_close': {'monotonic_before_ns': 200, 'realtime_ns': 1790793592074133248, 'monotonic_after_ns': 210}}
        model = clock_envelope(values, 'jfg')
        self.assertEqual([row['float_conversion_margin_ns'] for row in model['anchors']], [248, 248])

    def test_counts_are_cumulative_prefix_not_sum_or_ready_announcement(self):
        prefixes = [min(188, n * 6) for n in range(31)] + [188]
        result = derive_counts(callbacks(), packets(), prefixes, clock_envelope(anchors(), 'fgn'))
        row = result['per_frame'][0]
        # Callback offset330 ends at3230; latest epoch4235 precedes terminal4250.
        self.assertEqual(row['last_definitely_completed_row_offset'], 330)
        self.assertEqual(row['sh_completed_subapertures_lower_bound'], 180)
        self.assertEqual(row['mvm_completed_matrix_columns_lower_bound'], 360)
        self.assertEqual(result['frames_with_positive_science_work_lower_bound'], 1)

    def test_strict_end_boundary_and_sensitivity_never_increase_proof(self):
        values = packets(); values[-1] = 4235
        # Keep preceding packet order; last known call end4235 is exactly boundary.
        prefixes = [min(188, n * 6) for n in range(31)] + [188]
        narrow = derive_counts(callbacks(), values, prefixes, clock_envelope(anchors(), 'fgn'))
        wide = derive_counts(callbacks(), values, prefixes, clock_envelope(anchors(), 'fgn', 10000))
        self.assertEqual(narrow['per_frame'][0]['last_definitely_completed_row_offset'], 319)
        self.assertEqual(wide['subaperture_lower_bound_range']['max'], 0)

    def test_callback_before_own_input_or_outside_anchors_rejected(self):
        rows = callbacks(); rows[0]['start_ns'] = 100
        with self.assertRaises(ValueError):
            derive_counts(rows, packets(), [0] * 31 + [188], clock_envelope(anchors(), 'fgn'))
        values = packets(); values[0] = 2000
        with self.assertRaises(ValueError):
            derive_counts(callbacks(), values, [0] * 31 + [188], clock_envelope(anchors(), 'fgn'))

    def test_complete_c_trace_and_error_omission_identity_rejection(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'trace.csv'
            write_callbacks(path, callbacks())
            self.assertEqual(len(read_callbacks(path, 1, 'fgn')), 32)
            rows = callbacks(); rows[0]['result'] = 1
            write_callbacks(path, rows)
            self.assertEqual(read_callbacks(path, 1, 'fgn')[0]['result'], 1)
            for mutation in ('result', 'unknown_flags', 'offset', 'order', 'sentinel', 'overlap', 'short', 'omitted'):
                rows = callbacks()
                if mutation == 'result': rows[5]['result'] = -5
                if mutation == 'unknown_flags': rows[5]['result'] = 2
                if mutation == 'offset': rows[5]['offset'] = 0
                if mutation == 'order': rows[5], rows[6] = rows[6], rows[5]
                if mutation == 'sentinel': rows[5]['sequence'] = 2**64 - 1
                if mutation == 'overlap': rows[5]['start_ns'] = rows[4]['end_ns'] - 1
                if mutation == 'short': rows.pop()
                write_callbacks(path, rows, omitted=1 if mutation == 'omitted' else 0)
                with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                    read_callbacks(path, 1, 'fgn')

    def test_jfg_trace_counts_and_helpers_excluded(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'trace.csv'
            write_callbacks(path, callbacks(), role='jfg')
            declared = {'capacity': 32, 'records': 32, 'omitted': 0}
            self.assertEqual(len(read_callbacks(path, 1, 'jfg', declared)), 32)
            with self.assertRaises(ValueError):
                read_callbacks(path, 1, 'jfg', dict(declared, records=31))
            with self.assertRaises(ValueError):
                validate_graph(Path(directory), Path(directory), {'role': 'jfg'},
                               {'row_workers': 1, 'mode': 'row'}, None)

    def test_inactive_roi_rejected_before_any_count_claim(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory)
            origins = bytes(188 * 8)
            (fixture / 'subaperture-origins.u32le').write_bytes(origins)
            (fixture / 'active-subapertures.u8').write_bytes(bytes([1]) * 187 + bytes([0]))
            with patch('analyze_classic_row_work.ORIGINS_SHA256', digest(origins)):
                with self.assertRaisesRegex(ValueError, 'all 188'):
                    validate_fixture(fixture, {}, {}, Evidence())

    def test_packet_parser_checks_exact_order_geometry_and_decimal_times(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'wfs-packets.tsv'
            lines = [packet_line(0, n, f'1790793600.{n:09d}') for n in range(32)]
            path.write_text(''.join(lines))
            result = read_packets(path, 1)
            self.assertEqual(result[0], 1790793600000000000)
            self.assertEqual(result[-1], 1790793600000000031)
            for mutation in ('short', 'order', 'subnanosecond', 'nonfinite', 'geometry'):
                changed = list(lines)
                if mutation == 'short': changed.pop()
                if mutation == 'order': changed[1], changed[2] = changed[2], changed[1]
                if mutation == 'subnanosecond': changed[0] = changed[0].replace('1790793600.000000000', '1790793600.0000000001')
                if mutation == 'nonfinite': changed[0] = changed[0].replace('1790793600.000000000', 'Infinity')
                if mutation == 'geometry': changed[0] = changed[0].replace('\t7792\t', '\t1\t')
                path.write_text(''.join(changed))
                with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                    read_packets(path, 1)


if __name__ == '__main__':
    unittest.main()
