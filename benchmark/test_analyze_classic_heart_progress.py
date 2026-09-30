"""Synthetic event semantics; no controller or live network activity."""
import tempfile
import unittest
from pathlib import Path
from analyze_classic_heart_progress import analyze, read_trace, FIELDS


def event(kind, time, progress, total, aux=0, frame=1, sync=42, thread=1):
    return dict(zip(FIELDS, (thread, time, kind, frame, sync, progress, total, aux)))


def sample():
    packets = [event(1, 100 + n * 10, n + 1, 32, frame=0, thread=0) for n in range(32)]
    return packets + [event(5, 220, 100, 352, 50), event(5, 450, 352, 352, 188),
                      event(7, 230, 50, 188, 50, thread=2),
                      event(7, 400, 100, 188, 50, thread=2),
                      event(7, 460, 188, 188, 88, thread=2),
                      event(8, 490, 188, 188, thread=2),
                      event(10, 500, 188, 188, thread=2)]


class ProgressTests(unittest.TestCase):
    def test_availability_is_not_completion_of_new_batch(self):
        report = analyze(sample(), 1, True)
        row = report['per_frame'][0]
        self.assertEqual(row['final_receive_ns'], 410)
        self.assertEqual(row['sh_completed_subapertures_lower_bound'], 50)
        self.assertEqual(row['mvm_completed_xy_pairs_lower_bound'], 50)
        self.assertEqual(row['mvm_completed_matrix_columns_lower_bound'], 100)
        self.assertEqual(row['wire_frame'], 0)
        self.assertEqual(row['mvm_bucket'], 1)

    def test_arithmetic_requires_active_subaperture_attestation(self):
        row = analyze(sample(), 1)['per_frame'][0]
        self.assertEqual(row['mvm_traversed_subapertures_lower_bound'], 50)
        self.assertIsNone(row['mvm_completed_xy_pairs_lower_bound'])

    def test_equal_timestamp_is_excluded(self):
        events = sample()
        next(e for e in events if e['kind'] == 7 and e['progress'] == 100)['monotonic_ns'] = 410
        self.assertEqual(analyze(events, 1, True)['per_frame'][0]['mvm_completed_xy_pairs_lower_bound'], 0)

    def test_bad_identity_missing_packets_streaming_and_duplicate_worker_rejected(self):
        variants = []
        events = sample(); events.pop(0); variants.append(events)
        events = sample(); events[0]['sync'] = 999; variants.append(events)
        events = sample(); events.append(event(9, 300, 50, 188)); variants.append(events)
        events = sample(); next(e for e in events if e['kind'] == 7)['thread'] = 3; variants.append(events)
        events = sample(); next(e for e in events if e['kind'] == 7)['aux'] = 49; variants.append(events)
        for events in variants:
            with self.subTest(events=events[-1]), self.assertRaises(ValueError):
                analyze(events, 1, True)

    def test_missing_loss_counter_and_lost_events_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'trace.csv'
            csv = ','.join(FIELDS) + '\n' + '\n'.join(','.join(str(e[k]) for k in FIELDS) for e in sample()) + '\n'
            complete = '# lost_thread_0=0\n# lost_thread_1=0\n# lost_thread_2=0\n# untraced_threads=0\n'
            path.write_text(csv + complete)
            self.assertEqual(len(read_trace(path)[0]), len(sample()))
            for suffix in ('', complete.replace('lost_thread_2=0', 'lost_thread_2=1')):
                path.write_text(csv + suffix)
                with self.assertRaises(ValueError):
                    read_trace(path)


if __name__ == '__main__':
    unittest.main()
