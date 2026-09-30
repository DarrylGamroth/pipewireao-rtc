"""Transport-only regressions for the Classic installed-SPA sender helper."""

import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
SPEC = importlib.util.spec_from_file_location("run_classic_spa_sender", HERE / "run_classic_spa_sender.py")
SENDER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SENDER)


def cube(path, frames=1):
    values = np.arange(frames * 352 * 352, dtype=np.uint32).astype(np.uint16)
    cards = []
    for key, value in (("SIMPLE", "T"), ("BITPIX", "16"), ("NAXIS", "3"),
                       ("NAXIS1", "352"), ("NAXIS2", "352"), ("NAXIS3", str(frames)),
                       ("BSCALE", "1"), ("BZERO", "32768")):
        cards.append(f"{key:8}= {value:>20}".ljust(80))
    cards.append("END".ljust(80))
    header = "".join(cards).encode().ljust(2880, b" ")
    payload = (values.astype(np.int32) - 32768).astype(">i2").tobytes()
    path.write_bytes(header + payload + b"\0" * (-len(payload) % 2880))
    return values.astype("<u2").tobytes()


def packets(payload, frames=1):
    result = []
    for frame in range(frames):
        for seq in range(1, 33):
            raster = (seq - 1) * 352 * 11
            header = SENDER.HEADER.pack(0, 1, 16, 0, 7744, 3872, 352, 11,
                                        0, 0, seq, 32, raster, 1000 + frame, frame, 0)
            start = (frame * 352 * 352 + raster) * 2
            result.append((frame * 0.1 + (seq - 1) * 0.002 / 32,
                           header + payload[start:start + 7744]))
    return result


class ClassicSpaSenderTests(unittest.TestCase):
    def exercise_cleanup(self, *, replay_error=None, stop_error=None, remove_error=None):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / 'input.fits'
            cube(source)
            client = root / 'client.conf'
            client.write_text('')
            installation = SimpleNamespace(client_conf=client, module_directory=root,
                spa_library_directory=root, library_directory=root, daemon=root / 'daemon',
                working_directory=root, tool=lambda name: root / name)
            daemon = Mock(returncode=0)
            daemon.poll.return_value = None
            helper = Mock()
            helper.placed.side_effect = lambda argv, cpus: argv
            helper.sha256_file.return_value = 'fixture-digest'
            helper.start.return_value = (daemon, io.StringIO())
            helper.stop.side_effect = stop_error
            def command(argv, env):
                if replay_error is not None:
                    raise replay_error
                if Path(argv[0]).name == 'pwao-dump':
                    return json.dumps([{'id': 1, 'info': {'props': {'node.name': SENDER.SINK}}}])
                return 'Long 1\nLong 0\nLong 32\nLong 0\n'
            helper.command.side_effect = command
            original_rmtree = SENDER.shutil.rmtree
            caught = None
            with patch.dict(SENDER.os.environ, {'XDG_RUNTIME_DIR': str(root)}), \
                    patch.object(SENDER.shutil, 'rmtree', side_effect=remove_error,
                                 wraps=None if remove_error else original_rmtree):
                try:
                    SENDER.run_sender(helper=helper, installation=installation,
                                      directory=root / 'run', cube=source, frames=1)
                except Exception as error:
                    caught = error
            report = json.loads((root / 'run/report.json').read_text())
            helper.stop.assert_called_once()
            return report, caught

    def test_normal_cleanup_state_is_recorded(self):
        report, error = self.exercise_cleanup()
        self.assertIsNone(error)
        self.assertTrue(report['qualified'])
        self.assertEqual(report['cleanup'], {'daemon': 'stopped', 'runtime': 'removed'})
        self.assertEqual(report['process_returncode'], 0)

    def test_cleanup_failures_preserve_sender_report_and_cannot_pass(self):
        for failure in ('stop_error', 'remove_error'):
            with self.subTest(failure=failure):
                report, error = self.exercise_cleanup(**{failure: OSError('cleanup fault')})
                self.assertIsInstance(error, RuntimeError)
                self.assertFalse(report['qualified'])
                self.assertTrue(any('cleanup fault' in item for item in report['errors']))
                self.assertEqual(report['cleanup']['daemon' if failure == 'stop_error' else 'runtime'], 'failed')

    def test_cleanup_failures_preserve_primary_replay_exception(self):
        primary = RuntimeError('primary replay fault')
        report, error = self.exercise_cleanup(replay_error=primary,
            stop_error=OSError('stop fault'), remove_error=OSError('remove fault'))
        self.assertIs(error, primary)
        self.assertFalse(report['qualified'])
        self.assertEqual(report['cleanup'], {'daemon': 'failed', 'runtime': 'failed'})
        self.assertEqual(report['errors'], ['primary replay fault',
            'sender daemon cleanup failed: stop fault', 'sender runtime cleanup failed: remove fault'])

    def test_config_uses_installed_transport_factories_and_native_raw_pacing(self):
        config = SENDER.sender_config(Path('/cube "quoted".fits'), 100, 2000)
        for expected in ("api.fits.source", "api.ndarray.video-view", "api.heart.std-wfs.sink",
                         "api.fits.loop = false", "api.fits.readiness = timerfd",
                         "api.ndarray.video-format = GRAY16_LE",
                         "api.heart.std-wfs.pixels-per-datagram = 3872",
                         "api.heart.std-wfs.rows-per-datagram = true",
                         "api.heart.std-wfs.readout-time = 2000",
                         "api.heart.std-wfs.network-byte-order = false",
                         "api.heart.std-wfs.checksum = none", "node.cache-params = false"):
            self.assertIn(expected, config)
        self.assertIn('api.fits.path = "/cube \\"quoted\\".fits"', config)

    def test_settings_require_classic_packetization_and_readout_margin(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "input.fits"
            cube(path)
            self.assertEqual(SENDER.validate_settings(path, 1, 100, 2000), 1)
            for kwargs in ((2, 100, 2000, 11), (1, 100, 9500, 11), (1, 100, 2000, 22)):
                with self.assertRaises(ValueError):
                    SENDER.validate_settings(path, *kwargs)

    def test_sink_counters_fail_closed_on_missing_or_duplicate_values(self):
        text = "Long 7\nLong 0\nLong 224\nLong 0\n"
        self.assertEqual(SENDER.sink_counters(text), {"frames_sent": 7, "frames_rejected": 0,
                                                    "datagrams_sent": 224, "send_errors": 0})
        for invalid in ("", text + "Long 0", "Long 7 Long 0 Long 224"):
            with self.assertRaises(ValueError):
                SENDER.sink_counters(invalid)

    def test_wire_qualification_checks_values_frame_ids_order_completeness(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "input.fits"
            payload = cube(path, 2)
            records = packets(payload, 2)
            summary = SENDER.qualify_packets(path, records, 2, 10, 2000)
            self.assertTrue(summary["qualified"], summary)
            self.assertEqual(summary["frame_ids"], [0, 1])
            self.assertAlmostEqual(summary["observed_first_to_terminal_us"][0], 1937.5)
            corrupted = list(records)
            corrupted[0] = (records[0][0], records[0][1][:-1] + b"\xff")
            self.assertFalse(SENDER.qualify_packets(path, corrupted, 2, 10, 2000)["qualified"])
            self.assertFalse(SENDER.qualify_packets(path, records[1:], 2, 10, 2000)["qualified"])
            reordered = [records[1], records[0], *records[2:]]
            self.assertFalse(SENDER.qualify_packets(path, reordered, 2, 10, 2000)["qualified"])


if __name__ == "__main__":
    unittest.main()
