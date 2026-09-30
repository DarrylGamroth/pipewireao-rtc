import gzip
import lzma
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from classic_wire import open_evidence


class EvidenceTests(unittest.TestCase):
    def test_plain_and_legacy_compression(self):
        for suffix, writer in (("", open), (".xz", lzma.open), (".gz", gzip.open)):
            with tempfile.TemporaryDirectory() as temp:
                path = Path(temp) / "packets.tsv"
                with writer(Path(str(path) + suffix), "wb") as stream:
                    stream.write(b"retained packet evidence\n")
                with open_evidence(path) as stream:
                    self.assertEqual(stream.read(), "retained packet evidence\n")

    @unittest.skipUnless(shutil.which("zstd"), "zstd not installed")
    def test_zstd_and_corrupt_archive(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "packets.tsv"
            archive = Path(str(path) + ".zst")
            with archive.open("wb") as stream:
                subprocess.run(["zstd", "-q", "--stdout"], input=b"retained\n", stdout=stream, check=True)
            with open_evidence(path) as stream:
                self.assertEqual(stream.read(), "retained\n")
            archive.write_bytes(b"invalid")
            with self.assertRaises(ValueError):
                with open_evidence(path) as stream:
                    stream.read()

    def test_missing_file_and_invalid_mode(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaises(FileNotFoundError):
                with open_evidence(Path(temp) / "missing"):
                    pass
            with self.assertRaises(ValueError):
                with open_evidence(Path(temp) / "missing", "w"):
                    pass

if __name__ == "__main__":
    unittest.main()
