import tempfile
from pathlib import Path
import unittest
from run_classic_campaign import intervals, WFS, DM, command, archive_wire, summarize

class CampaignTests(unittest.TestCase):
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
            import lzma
            self.assertEqual(lzma.open(directory/'wire.pcapng.xz','rb').read(),b'abc')
            self.assertTrue((directory/'wire-archives.json').exists())
    def test_command_records_defined_placement(self):
        c=command('jfg-row',Path('/corpus'),Path('/out'),100,2000,1029,100,2,'sharded')
        self.assertIn('--julia-pin-cpus',c);self.assertIn('2,6,8,10',c)
        self.assertIn('source-arithmetic',c)
    def test_unsupported_tail_not_reported(self):
        self.assertNotIn('p99',summarize([1,2,3]))

if __name__=='__main__':unittest.main()
