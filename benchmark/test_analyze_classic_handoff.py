"""Synthetic monotonic handoff checks; no live controller or perf recording."""
import io
import unittest

from analyze_classic_handoff import derive_handoffs, match_rows, read_gc, read_native


class HandoffTests(unittest.TestCase):
    def test_native_omissions_and_truncation_rejected(self):
        for header in ('# capacity=100 used=1 omitted=1\n', '# capacity=100 used=2 omitted=0\n', ''):
            text = header + 'event,start_ns,end_ns,frame,ordinal,offset\nR,10,0,0,1,0\n'
            with self.subTest(header=header), self.assertRaises(ValueError):
                read_native(io.StringIO(text))

    def test_receive_ordinal_maps_to_offset_and_complete_order_is_required(self):
        rows = [{'event': 'R', 'frame': 0, 'ordinal': packet+1, 'offset': 0} for packet in range(32)]
        self.assertEqual(len(match_rows(rows, 'R', 1, receive=True)), 32)
        for damaged in (rows[:-1], rows+[rows[-1]], rows[::-1]):
            with self.assertRaises(ValueError):
                match_rows(damaged, 'R', 1, receive=True)

    def test_publication_ordinal_must_match_actual_row_offset(self):
        rows = [{'event': 'P', 'frame': 0, 'ordinal': packet+1, 'offset': packet*11} for packet in range(32)]
        match_rows(rows, 'P', 1)
        rows[-1]['ordinal'] = 1
        with self.assertRaises(ValueError):
            match_rows(rows, 'P', 1)

    def test_native_input_ready_uses_only_input_port_zero(self):
        rows = [{'event': 'G', 'direction': 'I', 'port': 0, 'frame': 0, 'offset': packet*11} for packet in range(32)]
        rows.append({'event': 'G', 'direction': 'I', 'port': 1, 'frame': 88, 'offset': 999})
        self.assertEqual(len(match_rows(rows, 'G', 1, native_input_ready=True)), 32)

    def sample(self):
        return ([{'start_ns': 10}], [{'start_ns': 20}],
                [{'sequence': 0, 'offset': 341, 'start_ns': 40, 'end_ns': 70}],
                [{'monotonic_ns': 30}], [{'start_ns': 90, 'end_ns': 100}])

    def test_terminal_residual_decomposes_and_body_wall_is_separate(self):
        receives, publications, callbacks, input_ready, sinks = self.sample()
        report = derive_handoffs(receives, publications, callbacks, (0, 110), input_ready, sinks)
        row = report['rows'][0]
        self.assertEqual(row['terminal_receive_to_sink_end_ns'], 90)
        self.assertEqual(sum(row[field] for field in ('receive_to_publication_ns', 'publication_to_native_input_ready_ns',
                                                      'native_input_ready_to_body_start_ns', 'body_wall_ns',
                                                      'body_end_to_sink_start_ns', 'sink_command_bracket_ns')), 90)
        self.assertEqual(report['terminal_rows']['body_wall_ns']['max'], .030)

    def test_negative_handoff_or_sink_boundary_and_outside_window_rejected(self):
        receives, publications, callbacks, input_ready, sinks = self.sample()
        for changed_gets, changed_sinks, window in ([{'monotonic_ns': 19}], sinks, (0, 110)), (input_ready, [{'start_ns': 69, 'end_ns': 100}], (0, 110)), (input_ready, sinks, (11, 110)):
            with self.subTest(window=window), self.assertRaises(ValueError):
                derive_handoffs(receives, publications, callbacks, window, changed_gets, changed_sinks)

    def test_fgn_handoff_has_no_native_input_ready_claim(self):
        receives, publications, callbacks, _, sinks = self.sample()
        report = derive_handoffs(receives, publications, callbacks, (0, 110), sinks=sinks)
        self.assertEqual(report['rows'][0]['publication_to_body_start_ns'], 20)
        self.assertNotIn('native_input_ready_ns', report['rows'][0])

    def test_gc_delta_and_global_counter_summary(self):
        text = ('gc_pause_start,gc_pause_end,gc_total_time_start_ns,gc_total_time_end_ns,gc_allocated_bytes_start,gc_allocated_bytes_end\n'
                '3,4,10,30,100,120\n')
        gc = read_gc(text)
        receives, publications, callbacks, input_ready, sinks = self.sample()
        report = derive_handoffs(receives, publications, callbacks, (0, 110), input_ready, sinks, gc)
        self.assertEqual(report['gc']['all_rows']['gc_pause_delta']['callbacks_changed'], 1)
        self.assertEqual(report['gc']['terminal_rows']['gc_allocated_bytes_delta']['sum_delta'], 20)
        self.assertIsNone(read_gc('callback,start_ns\n1,10\n'))
        with self.assertRaises(ValueError):
            read_gc('gc_pause_start\n1\n')
        with self.assertRaises(ValueError):
            read_gc(text.replace('3,4,10,30,100,120', '3,2,10,30,100,120'))


if __name__ == '__main__':
    unittest.main()
