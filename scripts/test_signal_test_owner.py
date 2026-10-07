import os
from pathlib import Path
import signal
import subprocess
import sys
import unittest

from signal_test_owner import terminate


class TestOwnerSignal(unittest.TestCase):
    def test_identity_rejection_and_pidfd_termination(self):
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        try:
            fields = Path(f"/proc/{child.pid}/stat").read_text().rsplit(")", 1)[1].split()
            start_ticks = int(fields[19])
            with self.assertRaises(RuntimeError):
                terminate(child.pid, os.getpid() + 1, start_ticks)
            with self.assertRaises(RuntimeError):
                terminate(child.pid, os.getpid(), start_ticks + 1)
            self.assertIsNone(child.poll())
            terminate(child.pid, os.getpid(), start_ticks)
            self.assertEqual(child.wait(timeout=5), -signal.SIGKILL)
        finally:
            if child.poll() is None:
                child.terminate()
                child.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
