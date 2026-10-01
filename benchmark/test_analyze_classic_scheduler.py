"""Offline synthetic scheduler checks; never record perf or run RTC traffic."""
import gzip
import io
import json
from pathlib import Path
import tempfile
import unittest

from analyze_classic_scheduler import (analyze_case, callback_intersections,
                                       derive_scheduler, discard_idle_intervals, parse_perf, read_callbacks,
                                       summarize_ns, target_threads)


def event(stamp, kind, fields, cpu=0):
    seconds, fraction = divmod(stamp, 1_000_000_000)
    return f'       task 7 [{cpu:03d}] {seconds}.{fraction:09d}: {kind}: {fields}\n'


def switch(stamp, previous, following, state='S', cpu=0):
    return event(stamp, 'sched:sched_switch',
                 f'prev_comm=task with spaces prev_pid={previous} prev_prio=83 prev_state={state} ==> '
                 f'next_comm=next next_pid={following} next_prio=83', cpu)


def wake(stamp, tid=42, success=None):
    suffix = '' if success is None else f' success={success}'
    return event(stamp, 'sched:sched_wakeup', f'comm=task pid={tid} prio=83{suffix} target_cpu=000')


def targets():
    return {42: {'role': 'daemon', 'pid': 40, 'tid': 42, 'name': 'rtc-data-loop'}}


def callbacks_csv(rows, omitted=0, used=None):
    if used is None:
        used = len(rows)
    return (f'# capacity=32768 used={used} omitted={omitted}\n'
            'callback,sequence,offset,start_ns,end_ns,result\n'
            + ''.join(','.join(map(str, row)) + '\n' for row in rows))


class PerfParsingTests(unittest.TestCase):
    def test_nanosecond_precision_and_all_supported_formats(self):
        lines = [switch(1_000_000_001, 42, 7, 'R+'), wake(1_000_000_012),
                 event(1_000_000_013, 'sched:sched_wakeup_new', 'comm=x pid=43 prio=120 target_cpu=003'),
                 event(1_000_000_014, 'sched:sched_migrate_task', 'comm=x pid=42 prio=83 orig_cpu=0 dest_cpu=2'),
                 event(1_000_000_015, 'power:cpu_idle', 'state=4294967295 cpu_id=0')]
        parsed = parse_perf(lines)
        self.assertTrue(parsed['complete'])
        self.assertEqual(parsed['events'][0]['time_ns'], 1_000_000_001)
        self.assertEqual(parsed['events'][0]['prev_state'], 'R+')
        self.assertEqual(parsed['events'][2]['target_cpu'], 3)
        self.assertEqual(parsed['events'][3]['dest_cpu'], 2)
        self.assertEqual(parsed['events'][4]['state'], 4294967295)

    def test_loss_unknown_lines_missing_fields_and_time_reversal_invalidate(self):
        for bad in ('CPU 0: PERF_RECORD_LOST 17 events\n', '# lost 4 samples\n',
                    'unparsed output\n', event(20, 'sched:sched_switch', 'prev_pid=42'),
                    switch(9, 7, 42)):
            with self.subTest(bad=bad):
                parsed = parse_perf([switch(10, 42, 7), bad])
                self.assertFalse(parsed['complete'])
                self.assertTrue(parsed['parse_errors'] or parsed['loss_records'])


class SchedulerIntervalTests(unittest.TestCase):
    def test_completed_off_cpu_and_wakeup_pair_with_actual_tid(self):
        parsed = parse_perf([switch(10, 42, 7), wake(15),
                             event(18, 'sched:sched_migrate_task', 'comm=x pid=42 prio=83 orig_cpu=0 dest_cpu=2'),
                             switch(25, 7, 42, cpu=2), switch(35, 42, 7), switch(40, 7, 42)])
        result = derive_scheduler(parsed['events'], targets(), (0, 50))
        thread = result['threads'][0]
        self.assertEqual([row['end_ns']-row['start_ns'] for row in thread['off_cpu']], [15, 5])
        self.assertEqual(thread['wake_to_switch_in'][0]['end_ns'], 25)
        self.assertEqual(result['groups'][0]['wake_to_switch_in']['max'], .010)
        self.assertEqual(result['groups'][0]['off_cpu']['p50'], .010)
        self.assertEqual(thread['migrations'][0]['dest_cpu'], 2)
        self.assertEqual(result['pairing_errors'], [])

    def test_edges_retained_and_never_counted_as_complete_durations(self):
        parsed = parse_perf([switch(10, 7, 42), switch(20, 42, 7), wake(25),
                             switch(30, 7, 42), switch(40, 42, 7), wake(45)])
        result = derive_scheduler(parsed['events'], targets(), (15, 43))
        rows = result['threads'][0]['off_cpu']
        self.assertEqual(len(rows), 2)
        self.assertFalse(rows[0]['left_censored'])
        self.assertIsNone(rows[1]['end_ns'])
        self.assertTrue(rows[1]['right_censored'])
        self.assertEqual(rows[1]['observed_duration_ns'], 3)
        self.assertEqual(result['groups'][0]['off_cpu']['count'], 1)

    def test_left_censored_switch_in_and_clipped_known_start(self):
        parsed = parse_perf([switch(10, 7, 42), switch(20, 42, 7), switch(30, 7, 42)])
        result = derive_scheduler(parsed['events'], targets(), (5, 25))
        rows = result['threads'][0]['off_cpu']
        self.assertIsNone(rows[0]['start_ns'])
        self.assertIsNone(rows[0]['observed_duration_ns'])
        self.assertTrue(rows[0]['left_censored'])
        self.assertTrue(rows[1]['right_censored'])
        self.assertEqual(result['groups'][0]['off_cpu']['count'], 0)

    def test_failed_wake_not_paired_and_running_wake_not_carried_forward(self):
        parsed = parse_perf([switch(5, 7, 42), wake(7), switch(10, 42, 7),
                             wake(12, success=0), switch(20, 7, 42)])
        result = derive_scheduler(parsed['events'], targets(), (0, 30))
        thread = result['threads'][0]
        self.assertEqual(thread['wakeup_while_running'], 1)
        self.assertEqual(thread['wake_to_switch_in'], [])

    def test_idle_pairs_and_censored_exit(self):
        lines = [event(2, 'power:cpu_idle', 'state=4294967295 cpu_id=0'),
                 event(10, 'power:cpu_idle', 'state=3 cpu_id=0'),
                 event(20, 'power:cpu_idle', 'state=-1 cpu_id=0'),
                 event(30, 'power:cpu_idle', 'state=2 cpu_id=0')]
        result = derive_scheduler(parse_perf(lines)['events'], targets(), (0, 40))
        self.assertEqual(len(result['idle_intervals']), 3)
        state3 = next(group for group in result['idle_groups'] if group['state'] == 3)
        self.assertEqual(state3['duration']['max'], .010)
        self.assertTrue(result['idle_intervals'][-1]['right_censored'])

    def test_saved_idle_summary_drops_raw_rows_without_changing_derive_api(self):
        lines = [event(2, 'power:cpu_idle', 'state=4294967295 cpu_id=0'),
                 event(10, 'power:cpu_idle', 'state=3 cpu_id=0'),
                 event(20, 'power:cpu_idle', 'state=-1 cpu_id=0')]
        result = derive_scheduler(parse_perf(lines)['events'], targets(), (0, 30))
        self.assertEqual(len(result['idle_intervals']), 2)
        groups = result['idle_groups']
        discard_idle_intervals(result)
        self.assertNotIn('idle_intervals', result)
        self.assertEqual(result['idle_interval_count'], 2)
        self.assertEqual(result['idle_censored_interval_count'], 1)
        self.assertIs(result['idle_groups'], groups)

    def test_duplicate_switch_out_is_reported(self):
        parsed = parse_perf([switch(5, 42, 7), switch(10, 42, 8), switch(20, 7, 42)])
        result = derive_scheduler(parsed['events'], targets(), (0, 30))
        self.assertTrue(result['pairing_errors'])

    def test_p99_only_for_at_least_100_samples(self):
        self.assertNotIn('p99', summarize_ns(range(99)))
        self.assertAlmostEqual(summarize_ns(range(100))['p99'], .09801)
        self.assertEqual(summarize_ns([])['count'], 0)


class CallbackTests(unittest.TestCase):
    def test_native_omissions_missing_header_and_truncation_rejected(self):
        row = (1, 0, 0, 10, 20, 0)
        for text in (callbacks_csv([row], omitted=1), callbacks_csv([row], used=2),
                     'callback,sequence,offset,start_ns,end_ns,result\n1,0,0,10,20,0\n'):
            with self.subTest(text=text), self.assertRaises(ValueError):
                read_callbacks(io.StringIO(text), 'fgn')

    def test_jfg_requires_zero_omissions_and_record_count(self):
        text = 'callback,sequence,offset,start_ns,end_ns\n1,0,0,10,20\n'
        declared = {'capacity': 32, 'records': 1, 'omitted': 0}
        self.assertEqual(read_callbacks(io.StringIO(text), 'jfg', declared)[0]['end_ns'], 20)
        with self.assertRaises(ValueError):
            read_callbacks(io.StringIO(text), 'jfg', declared | {'omitted': 1})
        with self.assertRaises(ValueError):
            read_callbacks(io.StringIO(text), 'jfg', declared, expected_count=32)

    def test_callback_intersection_and_wall_remainder(self):
        parsed = parse_perf([switch(1, 7, 42), switch(12, 42, 7), switch(18, 7, 42),
                             switch(22, 42, 7), switch(30, 7, 42)])
        scheduler = derive_scheduler(parsed['events'], targets(), (0, 40))
        callbacks = read_callbacks(io.StringIO(callbacks_csv([(1, 0, 0, 10, 25, 0)])), 'fgn')
        result = callback_intersections(callbacks, scheduler['threads'][0], (0, 40), (1, 30))
        self.assertEqual(result['rows'][0]['wall_ns'], 15)
        self.assertEqual(result['rows'][0]['off_cpu_ns'], 9)
        self.assertEqual(result['rows'][0]['wall_minus_off_cpu_ns'], 6)
        self.assertEqual(result['excluded_count'], 0)

    def test_callback_crossing_trace_edge_excluded(self):
        parsed = parse_perf([switch(10, 7, 42), switch(20, 42, 7), switch(30, 7, 42)])
        scheduler = derive_scheduler(parsed['events'], targets(), (0, 50))
        result = callback_intersections([{'callback': 1, 'start_ns': 5, 'end_ns': 15}],
                                        scheduler['threads'][0], (0, 50), (10, 30))
        self.assertFalse(result['rows'][0]['off_cpu_complete'])
        self.assertEqual(result['wall']['count'], 0)

    def test_callback_outside_capture_is_reported_and_not_summarized(self):
        thread = dict(targets()[42], off_cpu=[])
        result = callback_intersections([{'callback': 1, 'start_ns': 1, 'end_ns': 5}],
                                        thread, (10, 50), (0, 60))
        self.assertEqual(result['outside_window_count'], 1)
        self.assertEqual(result['rows'], [])
        self.assertEqual(result['wall']['count'], 0)


class CaseTests(unittest.TestCase):
    def fixture(self, directory, capture=True):
        (directory/'run').mkdir()
        result = {'path': 'heart', 'release_monotonic_ns': 10, 'perf_decoded': True,
                  'perf_command': ['perf', 'record', '--clockid', 'mono'],
                  'prepared': {'processes': [{'role': 'daemon', 'pid': 40}]}}
        if capture:
            result['after_capture'] = {'monotonic_ns': 30}
        placement = {'daemon': {'pid': 40, 'available': True, 'thread_ids': [42],
                                'threads': [{'tid': 42, 'name': 'rtc-data-loop'}]}}
        (directory/'result.json').write_text(json.dumps(result))
        (directory/'run/placement-before.json').write_text(json.dumps(placement))
        for name in ('perf.log', 'perf-decode.log'):
            (directory/name).write_text('')
        with gzip.open(directory/'perf-events.txt.gz', 'wt') as output:
            output.writelines([switch(5, 42, 7), wake(15), switch(25, 7, 42), switch(35, 42, 7)])
        return result, placement

    def test_compressed_input_hash_and_window(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            self.fixture(directory)
            result = analyze_case(directory)
            self.assertTrue(result['qualified_trace'])
            self.assertEqual(result['scheduler']['groups'][0]['wake_to_switch_in']['count'], 1)
            self.assertIn(str(directory/'perf-events.txt.gz'), result['sha256'])

    def test_missing_capture_end_does_not_fall_back_to_after_run(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            source, _ = self.fixture(directory, capture=False)
            source['after_run'] = {'monotonic_ns': 999}
            (directory/'result.json').write_text(json.dumps(source))
            result = analyze_case(directory)
            self.assertFalse(result['qualified_trace'])
            self.assertNotIn('scheduler', result)
            self.assertTrue(result['errors'])

    def test_loss_in_decode_log_rejects_trace(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            self.fixture(directory)
            (directory/'perf-decode.log').write_text('WARNING: lost 17 events\n')
            result = analyze_case(directory)
            self.assertFalse(result['qualified_trace'])
            self.assertEqual(len(result['perf']['loss_records']), 1)

    def test_wrong_process_and_duplicate_tid_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            result, placement = self.fixture(Path(temp))
            placement['daemon']['pid'] = 99
            with self.assertRaises(ValueError):
                target_threads(result, placement)
            placement['daemon']['pid'] = 40
            placement['daemon']['threads'].append({'tid': 42, 'name': 'other'})
            placement['daemon']['thread_ids'].append(42)
            with self.assertRaises(ValueError):
                target_threads(result, placement)


if __name__ == '__main__':
    unittest.main()
