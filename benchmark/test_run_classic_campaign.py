import tempfile
import hashlib
import json
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import run_classic_campaign as campaign
from run_classic_campaign import intervals, WFS, DM, command, archive_wire, summarize

class CampaignTests(unittest.TestCase):
    def write_timestamp_fixture(self, directory, *, kind=None, ordinal=0, timestamp=None,
                                equal=False):
        for packet_kind, count in (('wfs', 96), ('dm', 3)):
            rows = []
            for index in range(count):
                if packet_kind == 'wfs':
                    frame, packet = divmod(index, 32)
                    header = WFS.pack(0,0,0,0,352,352,0,0,0,0,packet+1,32,0,0,frame,0)
                    nanoseconds = frame * 10_000_000 + (0 if equal else packet * 10_000)
                else:
                    header = DM.pack(0,0,1,1,0,0,0,index,0)
                    nanoseconds = index * 10_000_000 + 500_000
                value = f'1.{nanoseconds:09d}'
                if packet_kind == kind and index == ordinal:
                    value = timestamp
                rows.append(f'{value}\t0\t{header.hex()}\n')
            (directory / f'{packet_kind}-packets.tsv').write_text(''.join(rows))

    def test_rejects_backward_packet_timestamps(self):
        cases = [('wfs', 1, '0.999000000'),  # first row after a clock reversal
                 ('wfs', 31, '0.999000000'), # terminal before first
                 ('dm', 0, '1.020500000')]  # both DM times still follow their WFS
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            for kind, ordinal, timestamp in cases:
                with self.subTest(kind=kind, ordinal=ordinal):
                    self.write_timestamp_fixture(directory, kind=kind, ordinal=ordinal,
                                                 timestamp=timestamp)
                    with self.assertRaisesRegex(ValueError, 'timestamp'):
                        intervals(directory, 3, 0, 100)
                    self.assertFalse((directory / 'latency-intervals.json').exists())

    def test_rejects_nonfinite_packet_timestamps(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            for kind in ('wfs', 'dm'):
                for timestamp in ('NaN', 'Infinity', '-Infinity'):
                    with self.subTest(kind=kind, timestamp=timestamp):
                        self.write_timestamp_fixture(directory, kind=kind, ordinal=1,
                                                     timestamp=timestamp)
                        with self.assertRaisesRegex(ValueError, 'timestamp'):
                            intervals(directory, 3, 0, 100)
                        self.assertFalse((directory / 'latency-intervals.json').exists())

    def test_equal_packet_timestamps_are_valid(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            self.write_timestamp_fixture(directory, equal=True)
            result = intervals(directory, 3, 0, 100)
            self.assertEqual(result['all']['readout_us']['max'], 0)
            self.assertEqual(result['achieved_source_rate_hz'], 100)

    def test_packet_boundaries_exact_decimal(self):
        with tempfile.TemporaryDirectory() as temp:
            directory=Path(temp)
            w=[];d=[]
            for frame in range(2):
                for packet in range(32):
                    h=WFS.pack(0,0,0,0,352,352,0,0,0,0,packet+1,32,0,0,frame,0)
                    w.append(f'1.{frame*10000+packet*10:09d}\t0\t{h.hex()}\n')
                h=DM.pack(0,0,1,1,0,0,0,frame,0)
                d.append(f'1.{frame*10000+400:09d}\t0\t{h.hex()}\n')
            (directory/'wfs-packets.tsv').write_text(''.join(w));(directory/'dm-packets.tsv').write_text(''.join(d))
            result=intervals(directory,2,0,100)
            self.assertAlmostEqual(result['all']['terminal_to_dm_us']['p50'],.09)
            self.assertAlmostEqual(result['all']['first_to_dm_us']['p50'],.4)
            (directory/'dm-packets.tsv').write_text(''.join(reversed(d)))
            with self.assertRaises(ValueError):intervals(directory,2,0,100)
    def test_failed_preflight_has_no_archive_directory(self):
        with tempfile.TemporaryDirectory() as temp:
            archive_wire(Path(temp) / 'never-created')

    def test_archives_preserve_evidence(self):
        with tempfile.TemporaryDirectory() as temp:
            directory=Path(temp);(directory/'wire.pcapng').write_bytes(b'abc')
            archive_wire(directory)
            from classic_wire import open_evidence
            with open_evidence(directory/'wire.pcapng','rb') as reader:
                self.assertEqual(reader.read(),b'abc')
            self.assertTrue((directory/'wire-archives.json').exists())

    def test_intervals_read_archived_packets(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            self.write_timestamp_fixture(directory)
            expected = intervals(directory, 3, 0, 100)
            archive_wire(directory)
            self.assertEqual(intervals(directory, 3, 0, 100), expected)
    def test_command_records_defined_placement(self):
        c=command('jfg-row',Path('/corpus'),Path('/out'),100,2000,1029,100,2,'sharded')
        self.assertIn('--julia-pin-cpus',c);self.assertIn('4,14,6,10',c)
        self.assertIn('source-arithmetic',c)

    def test_command_default_keeps_frozen_plugin_without_reading_files(self):
        with patch.object(Path, 'read_bytes', side_effect=AssertionError('unexpected file read')):
            c=command('fgn-frame',Path('/corpus'),Path('/out'),100,2000,63)
        self.assertEqual(c[c.index('--heart-plugin')+1],
                         '/opt/pipewireao/lib/x86_64-linux-gnu/spa-ao-0.2/heart/libspa-heart.so')
        self.assertEqual(c[c.index('--heart-plugin-sha256')+1],
                         'efaf3a810284a6a39b9c84fb433cf9669a638da14b41cd528b8a18cc593ce7d6')

    def test_commands_forward_selected_plugin_and_precomputed_digest(self):
        for path in ('fgn-frame','jfg-frame','fgn-row','jfg-row'):
            with self.subTest(path=path), patch.object(Path, 'read_bytes', side_effect=AssertionError('rehash')):
                c=command(path,Path('/corpus'),Path('/out'),100,2000,63,
                          heart_plugin=Path('/candidate/libspa-heart.so'),heart_plugin_sha256='candidate-digest')
            self.assertEqual(c[c.index('--heart-plugin')+1], '/candidate/libspa-heart.so')
            self.assertEqual(c[c.index('--heart-plugin-sha256')+1], 'candidate-digest')

    def test_command_can_hash_an_explicit_plugin_when_called_directly(self):
        with tempfile.TemporaryDirectory() as temp:
            plugin=Path(temp)/'libspa-heart.so';plugin.write_bytes(b'candidate HEART')
            c=command('jfg-row',Path('/corpus'),Path('/out'),100,2000,63,heart_plugin=plugin)
            self.assertEqual(c[c.index('--heart-plugin')+1],str(plugin.resolve()))
            self.assertEqual(c[c.index('--heart-plugin-sha256')+1],hashlib.sha256(b'candidate HEART').hexdigest())

    def test_cli_hashes_plugin_once_and_records_selection(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);plugin=root/'libspa-heart.so';plugin.write_bytes(b'candidate HEART')
            output=root/'campaign'
            def run_selected(cmd, **kwargs):
                directory=Path(cmd[cmd.index('--output')+1]);directory.mkdir()
                (directory/'report.json').write_text('{}')
                (directory/'physical-summary.json').write_text('{"qualified":true}')
                return SimpleNamespace(returncode=0)
            argv=['campaign','--output',str(output),'--heart-plugin',str(plugin),
                  '--paths','fgn-frame','jfg-row','--repeats','1','--frames','7']
            with patch.object(campaign.sys,'argv',argv), \
                    patch.object(campaign,'host_record',return_value={}), \
                    patch.object(campaign.subprocess,'check_output',return_value='revision\n'), \
                    patch.object(campaign.subprocess,'run',side_effect=run_selected) as replay, \
                    patch.object(campaign,'intervals',return_value={}), \
                    patch.object(campaign,'archive_wire'), \
                    patch.object(campaign.hashlib,'sha256',wraps=hashlib.sha256) as digest:
                campaign.main()
                digest.assert_called_once_with(b'candidate HEART')
            expected=hashlib.sha256(b'candidate HEART').hexdigest()
            manifest=json.loads((output/'manifest.json').read_text())
            self.assertEqual(manifest['heart_plugin'],{'path':str(plugin.resolve()),'sha256':expected})
            self.assertEqual(manifest['requested']['heart_plugin'],str(plugin))
            self.assertEqual(replay.call_count,2)
            for record in manifest['runs']:
                c=record['command']
                self.assertEqual(c[c.index('--heart-plugin')+1],str(plugin.resolve()))
                self.assertEqual(c[c.index('--heart-plugin-sha256')+1],expected)

    def test_cli_rejects_a_file_the_plugin_directory_would_not_load(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);(root/'libspa-heart.so').write_bytes(b'loaded HEART')
            other=root/'other.so';other.write_bytes(b'different HEART')
            output=root/'campaign'
            argv=['campaign','--output',str(output),'--heart-plugin',str(other)]
            with patch.object(campaign.sys,'argv',argv), patch.object(campaign.sys,'stderr'), \
                    self.assertRaises(SystemExit) as caught:
                campaign.main()
            self.assertEqual(caught.exception.code,2)
            self.assertFalse(output.exists())

    def test_unsupported_tail_not_reported(self):
        self.assertNotIn('p99',summarize([1,2,3]))

if __name__=='__main__':unittest.main()
