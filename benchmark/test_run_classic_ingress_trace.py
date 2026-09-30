"""Private diagnostic overlay and failure-preservation checks; no live replay."""
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import run_classic_ingress_trace as runner


@dataclass(frozen=True)
class Installation:
    library_directory: Path
    module_directory: Path
    daemon: Path


class IngressTraceTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.output = self.root / 'result'
        self.library_directory = self.root / 'diagnostic-library'
        self.library_directory.mkdir()
        self.library = self.library_directory / 'libpipewire-ao-0.3.so.0.1700.0'
        self.library.write_bytes(b'diagnostic core')
        (self.library_directory / 'libpipewire-ao-0.3.so').symlink_to(self.library)
        self.module = self.root / 'diagnostic-module.so'
        self.module.write_bytes(b'diagnostic module')
        self.heart_plugin = self.root / 'deployed-heart' / 'libspa-heart.so'
        self.heart_plugin.parent.mkdir()
        self.heart_plugin.write_bytes(b'deployed HEART')
        self.installed_modules = self.root / 'installed-modules'
        self.installed_modules.mkdir()
        for name in ('libpipewire-module-ndarray-filter-chain.so', 'other-module.so'):
            (self.installed_modules / name).write_bytes(b'deployed module')
        self.installed = Installation(self.root / 'installed-library',
                                      self.installed_modules, self.root / 'installed-daemon')
        self.helper = SimpleNamespace(
            pipewire_installation=Mock(return_value=self.installed),
            make_environment=Mock(side_effect=lambda directory, marker, selected: {
                'KEEP': marker, 'LD_LIBRARY_PATH': str(selected.library_directory),
                'PIPEWIREAO_MODULE_DIR': str(selected.module_directory)}))
        self.argv = ['trace', '--output', str(self.output), '--library-directory',
                     str(self.library_directory), '--module-library', str(self.module),
                     '--corpus', str(self.root / 'corpus'), '--frames', '63']
        self.command = ['python', 'run_classic_live.py', '--output', str(self.output),
                        '--heart-plugin', str(self.heart_plugin), '--heart-plugin-sha256',
                        hashlib.sha256(self.heart_plugin.read_bytes()).hexdigest()]

    def invoke(self, live, archive=None, interval=None):
        original_load = Mock(return_value=self.helper)
        archive = archive or Mock()
        interval = interval or Mock()
        with patch.object(runner.sys, 'argv', self.argv), \
             patch.object(runner.run_classic_live, 'load_script', original_load), \
             patch.object(runner.run_classic_live, 'main', side_effect=live), \
             patch.object(runner, 'command', return_value=self.command) as command, \
             patch.object(runner, 'archive_wire', archive), \
             patch.object(runner, 'intervals', interval):
            try:
                runner.main()
            finally:
                self.command_call = command.call_args
                self.restored_loader = runner.run_classic_live.load_script is original_load
                self.restored_argv = runner.sys.argv is self.argv
        return archive, interval

    def test_private_overlay_environment_and_binary_hashes(self):
        def live():
            helper = runner.run_classic_live.load_script('classic_live_transport', Path('helper'))
            selected = helper.pipewire_installation()
            self.output.mkdir()
            env = helper.make_environment(self.output, 'preserved', selected)
            overlay = self.root / 'result.modules'
            self.assertEqual(selected.daemon, self.installed.daemon)
            self.assertEqual(selected.library_directory, self.library_directory)
            self.assertEqual(selected.module_directory, overlay)
            self.assertEqual((overlay / 'libpipewire-module-ndarray-filter-chain.so').resolve(), self.module)
            self.assertEqual((overlay / 'other-module.so').resolve(), self.installed_modules / 'other-module.so')
            trace = self.output / 'native-ingress-trace'
            self.assertTrue(trace.is_dir())
            self.assertEqual(env['PW_FGN_PROCESS_TRACE_DIR'], str(trace))
            self.assertEqual(env['PW_NDARRAY_FILTER_TRACE_DIR'], str(trace))
            self.assertEqual(env['HEART_RTC_TRACE_DIR'], str(trace))
            self.assertNotIn('JULIA_RTC_TRACE_GC', env)
            self.assertEqual(env['KEEP'], 'preserved')
            self.assertEqual(env['LD_LIBRARY_PATH'], str(self.library_directory))
            self.assertEqual(runner.sys.argv, self.command[1:])
        archive, interval = self.invoke(live)
        diagnostic = json.loads((self.output / 'diagnostic-library.json').read_text())
        self.assertEqual(diagnostic['sha256'], hashlib.sha256(self.library.read_bytes()).hexdigest())
        self.assertEqual(diagnostic['module_sha256'], hashlib.sha256(self.module.read_bytes()).hexdigest())
        self.assertEqual(diagnostic['library'], str(self.library))
        self.assertEqual(diagnostic['module'], str(self.module))
        self.assertEqual(diagnostic['heart_plugin'], str(self.heart_plugin))
        self.assertEqual(diagnostic['heart_plugin_sha256'], hashlib.sha256(self.heart_plugin.read_bytes()).hexdigest())
        self.assertFalse(diagnostic['heart_plugin_override'])
        self.assertEqual((diagnostic['role'], diagnostic['rate_hz'], diagnostic['readout_us']), ('fgn', 100, 2000))
        self.assertEqual(self.command_call.args, ('fgn-row', self.root / 'corpus', self.output, 100, 2000, 63))
        self.assertEqual(self.command_call.kwargs, {'trace': 0})
        self.assertEqual({Path(name).name for name in diagnostic['source_sha256']},
                         {'run_classic_ingress_trace.py', 'run_classic_live.py', 'run_classic_campaign.py'})
        for name, digest in diagnostic['source_sha256'].items():
            self.assertEqual(digest, hashlib.sha256(Path(name).read_bytes()).hexdigest())
        self.assertEqual((self.installed_modules / 'libpipewire-module-ndarray-filter-chain.so').read_bytes(), b'deployed module')
        archive.assert_called_once_with(self.output)
        interval.assert_not_called()
        self.assertTrue(self.restored_loader and self.restored_argv)

    def test_julia_role_rate_plugin_override_and_callback_trace(self):
        plugin = self.root / 'trace-heart' / 'libspa-heart.so'
        plugin.parent.mkdir()
        plugin.write_bytes(b'instrumented HEART')
        self.argv += ['--role', 'jfg', '--rate-hz', '250', '--readout-us', '850',
                      '--heart-plugin', str(plugin)]
        def live():
            helper = runner.run_classic_live.load_script('classic_live_transport', Path('helper'))
            selected = helper.pipewire_installation()
            self.output.mkdir()
            env = helper.make_environment(self.output, 'preserved', selected)
            (self.output / 'dm-packets.tsv').touch()
            self.assertEqual(env['JULIA_RTC_TRACE_GC'], '1')
            self.assertEqual(env['HEART_RTC_TRACE_DIR'], str(self.output / 'native-ingress-trace'))
            self.assertEqual(selected.library_directory, self.library_directory)
            self.assertEqual((selected.module_directory / 'libpipewire-module-ndarray-filter-chain.so').resolve(), self.module)
        _, interval = self.invoke(live)
        self.assertEqual(self.command_call.args, ('jfg-row', self.root / 'corpus', self.output, 250, 850, 63))
        self.assertEqual(self.command_call.kwargs, {'trace': 2016})
        interval.assert_called_once_with(self.output, 63, 0, 250)
        selected_command = json.loads((self.root / 'result.command.json').read_text())
        self.assertEqual(selected_command[selected_command.index('--heart-plugin') + 1], str(plugin))
        digest = hashlib.sha256(plugin.read_bytes()).hexdigest()
        self.assertEqual(selected_command[selected_command.index('--heart-plugin-sha256') + 1], digest)
        diagnostic = json.loads((self.output / 'diagnostic-library.json').read_text())
        self.assertEqual((diagnostic['role'], diagnostic['rate_hz'], diagnostic['readout_us'],
                          diagnostic['callback_trace_capacity']), ('jfg', 250, 850, 2016))
        self.assertEqual(diagnostic['heart_plugin_sha256'], digest)
        self.assertTrue(diagnostic['heart_plugin_override'])
        self.assertEqual(self.heart_plugin.read_bytes(), b'deployed HEART')
        self.assertTrue(self.restored_loader and self.restored_argv)

    def test_nonstandard_plugin_filename_cannot_verify_a_different_loaded_file(self):
        other = self.heart_plugin.parent / 'other-plugin.so'
        other.write_bytes(b'different DSO')
        self.argv += ['--heart-plugin', str(other)]
        with patch.object(runner.sys, 'stderr'), self.assertRaises(SystemExit) as caught:
            self.invoke(lambda: None)
        self.assertEqual(caught.exception.code, 2)
        self.assertFalse(self.output.exists())

    def test_invalid_rates_readout_and_frame_counts_fail_before_replay(self):
        original = list(self.argv)
        for flag in ('--rate-hz', '--readout-us', '--frames'):
            with self.subTest(flag=flag):
                self.argv = original + [flag, '0']
                with patch.object(runner.sys, 'stderr'), self.assertRaises(SystemExit):
                    self.invoke(lambda: None)
                self.assertFalse(self.output.exists())

    def test_campaign_julia_command_contains_live_callback_capacity(self):
        from run_classic_campaign import command
        selected = command('jfg-row', self.root / 'corpus', self.output, 250, 2000, 63, trace=2016)
        self.assertEqual(selected[selected.index('--role') + 1], 'jfg')
        self.assertEqual(selected[selected.index('--trace-callbacks') + 1], '2016')
        self.assertEqual(selected[selected.index('--rate-hz') + 1], '250')
        self.assertEqual(selected[selected.index('--readout-us') + 1], '2000')

    def test_primary_failure_survives_archive_failure(self):
        failure = RuntimeError('original replay failure')
        def live():
            raise failure
        with patch.object(runner.sys, 'stderr') as stderr, self.assertRaises(RuntimeError) as caught:
            self.invoke(live,
                        archive=Mock(side_effect=OSError('archive failure')))
        self.assertIs(caught.exception, failure)
        self.assertTrue(self.restored_loader and self.restored_argv)
        self.assertTrue((self.output / 'diagnostic-library.json').is_file())
        self.assertIn('archive failure', ''.join(call.args[0] for call in stderr.write.call_args_list))

    def test_primary_failure_survives_diagnostic_write_failure(self):
        failure = RuntimeError('original replay failure')
        original_write = Path.write_text
        def live():
            raise failure
        def write(path, text, *args, **kwargs):
            if path.name == 'diagnostic-library.json':
                raise OSError('diagnostic write failure')
            return original_write(path, text, *args, **kwargs)
        with patch.object(Path, 'write_text', write), patch.object(runner.sys, 'stderr'), \
             self.assertRaises(RuntimeError) as caught:
            self.invoke(live)
        self.assertIs(caught.exception, failure)
        self.assertTrue(self.restored_loader and self.restored_argv)

    def test_exit_status_survives_archive_failure(self):
        def live():
            raise SystemExit(2)
        with patch.object(runner.sys, 'stderr'), self.assertRaises(SystemExit) as caught:
            self.invoke(live, archive=Mock(side_effect=OSError('archive failure')))
        self.assertEqual(caught.exception.code, 2)
        self.assertTrue(self.restored_loader and self.restored_argv)

    def test_archive_failure_after_success_is_reported(self):
        with self.assertRaisesRegex(OSError, 'archive failure'):
            self.invoke(lambda: None, archive=Mock(side_effect=OSError('archive failure')))
        self.assertTrue(self.restored_loader and self.restored_argv)

    def test_bad_intervals_are_retained_and_wire_is_archived(self):
        def live():
            self.output.mkdir()
            (self.output / 'dm-packets.tsv').touch()
        archive, interval = self.invoke(live, interval=Mock(side_effect=ValueError('packet identity mismatch')))
        self.assertEqual(json.loads((self.output / 'interval-error.json').read_text()), 'packet identity mismatch')
        interval.assert_called_once_with(self.output, 63, 0, 100)
        archive.assert_called_once_with(self.output)

    def test_integer_clock_anchor_brackets_realtime_read(self):
        with patch.object(runner.time, 'monotonic_ns', side_effect=[10, 30]), \
             patch.object(runner.time, 'time_ns', return_value=1_790_000_000_000_000_012):
            self.assertEqual(runner.clock_anchor(), {'monotonic_before_ns': 10,
                'monotonic_after_ns': 30, 'realtime_ns': 1_790_000_000_000_000_012})


if __name__ == '__main__':
    unittest.main()
