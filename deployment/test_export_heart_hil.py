"""Cold HEART bridge topology and exact simulated-offset encoding."""
import array
import struct
import tempfile
from pathlib import Path
import unittest

import export_heart_hil as heart


class HEARTExportTests(unittest.TestCase):
    def test_selected_readout_defaults_and_period_boundary(self):
        self.assertEqual(heart.readout_interval("classic", None, 10), 0)
        self.assertEqual(heart.readout_interval("copper", None, 10), 2000)
        self.assertEqual(heart.readout_interval("copper", 0, 10), 0)
        for readout, rate in ((-1, 10), (95000, 10), (2000, 500), (0, 0), (True, 10)):
            with self.subTest(readout=readout, rate=rate), self.assertRaises(ValueError):
                heart.readout_interval("copper", readout, rate)

    def test_complete_frame_bridge_has_two_exact_transport_legs(self):
        for instrument, extent in (("classic", 352), ("copper", 64)):
            with self.subTest(instrument=instrument):
                value = heart.bridge_session(instrument, 10)
                self.assertEqual(value['execution'], 'external-rtc')
                self.assertEqual(value['graphs'], [])
                self.assertEqual(value['execution-groups'], [])
                self.assertEqual(len(value['links']), 2)
                self.assertTrue(all(not link['passive'] for link in value['links']))
                ports = [node['ports'][0] for node in value['sources'] + value['sinks']]
                self.assertEqual(ports[0]['shape'], [extent, extent])
                self.assertEqual(ports[0]['schema'], heart.RAW_SCHEMA)
                self.assertEqual(ports[1]['schema'], heart.COMMAND_SCHEMA)
                self.assertEqual(ports[1]['shape'], [277])
                self.assertEqual(ports[2]['schema'], ports[0]['schema'])
                self.assertEqual(ports[3]['schema'], ports[1]['schema'])

    def test_fits_keeps_interleaved_reference_order_and_float_values(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, destination = root/'offsets.f32', root/'offsets.fits'
            source.write_bytes(struct.pack('<6f', 1, -2, 3, -4, 5, -6))
            heart.write_offset_fits(source, destination, [3, 2])
            data = destination.read_bytes()
            self.assertEqual(len(data), 5760)
            cards = {data[i:i+8].decode().strip(): data[i+10:i+30].decode().strip()
                     for i in range(0, 480, 80)}
            self.assertEqual(cards['BITPIX'], '-32')
            self.assertEqual(cards['NAXIS1'], '2')
            self.assertEqual(cards['NAXIS2'], '3')
            self.assertEqual(struct.unpack('>6f', data[2880:2904]), (1, -2, 3, -4, 5, -6))

    def test_fits_rejects_wrong_extent_and_nonfinite_values(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, destination = root/'bad.f32', root/'bad.fits'
            source.write_bytes(struct.pack('<f', 1))
            with self.assertRaisesRegex(ValueError, 'extent'):
                heart.write_offset_fits(source, destination, [2])
            source.write_bytes(struct.pack('<f', float('nan')))
            with self.assertRaisesRegex(ValueError, 'nonfinite'):
                heart.write_offset_fits(source, destination, [1])
            self.assertFalse(destination.exists())

    def test_only_identical_alias_repetition_is_removed(self):
        source = '- ALIASES:\n    RATE: &rate 10\n    RATE: &rate 10\n- HO:\n    RATE: 10\n'
        self.assertEqual(heart.normalize_aliases(source),
                         '- ALIASES:\n    RATE: &rate 10\n- HO:\n    RATE: 10\n')
        with self.assertRaisesRegex(ValueError, 'conflicting'):
            heart.normalize_aliases(source.replace('RATE: &rate 10\n- HO', 'RATE: &rate 20\n- HO'))
