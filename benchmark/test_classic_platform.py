"""Mocked tests for CPU latency control; these never open the host device."""
import struct
import unittest
from unittest.mock import patch

import classic_platform as platform


class CpuLatencyTests(unittest.TestCase):
    def setUp(self):
        self.opened = []
        self.closed = []
        self.reads = []
        self.writes = []
        self.next_fd = 10

    def fake_open(self, path, flags):
        fd = self.next_fd
        self.next_fd += 1
        self.opened.append((fd, path, flags))
        return fd

    def fake_read(self, fd, size):
        result = self.reads.pop(0)
        if isinstance(result, BaseException):
            raise result
        return result

    def fake_write(self, fd, value):
        self.writes.append((fd, value))
        result = self.write_result
        if isinstance(result, BaseException):
            raise result
        return result

    def mocked(self):
        return patch.multiple(platform.os, open=self.fake_open, read=self.fake_read,
                              write=self.fake_write, close=self.closed.append)

    @staticmethod
    def packed(value):
        return struct.pack("=i", value)

    def test_effective_read_uses_readonly_descriptor_and_rejects_short_read(self):
        self.reads = [self.packed(-1)]
        with self.mocked():
            self.assertEqual(platform.effective_cpu_latency("device"), -1)
        self.assertEqual(self.opened[0][2], platform.os.O_RDONLY)
        self.assertEqual(self.closed, [10])

        self.reads = [b"\0\0"]
        with self.mocked(), self.assertRaisesRegex(ValueError, "short CPU latency read"):
            platform.effective_cpu_latency("device")
        self.assertEqual(self.closed[-1], 11)

    def test_none_records_snapshot_without_writable_descriptor(self):
        self.reads = [self.packed(100)]
        with self.mocked():
            with platform.cpu_latency_request(None, "device") as record:
                self.assertEqual(record["effective_during_us"], 100)
                self.assertFalse(record["released"])
        self.assertEqual(record["requested_us"], None)
        self.assertTrue(record["released"])
        self.assertEqual(len(self.opened), 1)

    def test_integer_request_closes_owned_fd_after_release_and_tracks_effective_values(self):
        self.reads = [self.packed(100), self.packed(20), self.packed(100)]
        self.write_result = 4
        with self.mocked():
            with platform.cpu_latency_request(25, "device") as record:
                self.assertEqual(record["effective_during_us"], 20)
                self.assertFalse(record["released"])
        self.assertEqual([entry[2] for entry in self.opened],
                         [platform.os.O_RDONLY, platform.os.O_RDWR,
                          platform.os.O_RDONLY, platform.os.O_RDONLY])
        self.assertEqual(self.writes, [(11, self.packed(25))])
        self.assertEqual(self.closed, [10, 12, 11, 13])
        self.assertTrue(record["released"])
        self.assertEqual(record["effective_after_release_us"], 100)

    def test_invalid_values_fail_before_any_open(self):
        with self.mocked():
            for value in (-1, 1 << 31, True, 1.5):
                with self.subTest(value=value), self.assertRaises(ValueError):
                    with platform.cpu_latency_request(value, "device"):
                        pass
        self.assertEqual(self.opened, [])

    def test_zero_and_int32_max_are_valid_requests(self):
        self.reads = [self.packed(0), self.packed(0), self.packed(0),
                      self.packed(0), self.packed(0), self.packed(0)]
        self.write_result = 4
        with self.mocked():
            for value in (0, (1 << 31) - 1):
                with platform.cpu_latency_request(value, "device") as record:
                    self.assertEqual(record["requested_us"], value)
        self.assertEqual(len(self.writes), 2)

    def test_short_write_closes_request_descriptor(self):
        self.reads = [self.packed(100)]
        self.write_result = 3
        with self.mocked(), self.assertRaisesRegex(ValueError, "short CPU latency write"):
            with platform.cpu_latency_request(25, "device"):
                self.fail("short write must not yield")
        self.assertEqual(self.closed, [10, 11])

    def test_setup_effective_read_failure_closes_request_descriptor(self):
        self.reads = [self.packed(100), b"bad"]
        self.write_result = 4
        with self.mocked(), self.assertRaisesRegex(ValueError, "short CPU latency read"):
            with platform.cpu_latency_request(25, "device"):
                self.fail("failed setup must not yield")
        self.assertEqual(self.closed, [10, 12, 11])

    def test_body_exception_is_preserved_and_request_is_released(self):
        self.reads = [self.packed(100), self.packed(20), self.packed(100)]
        self.write_result = 4
        with self.mocked(), self.assertRaisesRegex(LookupError, "body"):
            with platform.cpu_latency_request(25, "device") as record:
                raise LookupError("body")
        self.assertTrue(record["released"])
        self.assertEqual(record["effective_after_release_us"], 100)

    def test_release_read_failure_is_recorded_or_raised_after_success(self):
        self.reads = [self.packed(100), self.packed(20), OSError("release read")]
        self.write_result = 4
        with self.mocked(), self.assertRaisesRegex(OSError, "release read"):
            with platform.cpu_latency_request(25, "device") as record:
                pass
        self.assertTrue(record["released"])
        self.assertIn("release read", record["release_read_error"])

        self.reads = [self.packed(100), self.packed(20), OSError("release read")]
        with self.mocked(), self.assertRaisesRegex(LookupError, "body"):
            with platform.cpu_latency_request(25, "device") as record:
                raise LookupError("body")
        self.assertIn("release read", record["release_read_error"])


if __name__ == "__main__":
    unittest.main()
