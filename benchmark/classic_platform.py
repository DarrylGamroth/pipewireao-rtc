"""Small control-plane helpers for recording and requesting CPU latency QoS."""
from contextlib import contextmanager
import os
from pathlib import Path
import struct


_INT32_MAX = (1 << 31) - 1
_INT32 = struct.Struct("=i")


def effective_cpu_latency(device=Path("/dev/cpu_dma_latency")):
    """Read the kernel's current CPU DMA latency request, in microseconds."""
    descriptor = os.open(device, os.O_RDONLY)
    try:
        raw = os.read(descriptor, _INT32.size)
        if len(raw) != _INT32.size:
            raise ValueError(f"short CPU latency read: {len(raw)} bytes, expected {_INT32.size}")
        return _INT32.unpack(raw)[0]
    finally:
        os.close(descriptor)


@contextmanager
def cpu_latency_request(value: int | None, device=Path("/dev/cpu_dma_latency")):
    """Temporarily request a CPU latency limit and yield its evidence record."""
    if value is not None and (not isinstance(value, int) or isinstance(value, bool)
                              or value < 0 or value > _INT32_MAX):
        raise ValueError("CPU latency request must be None or an integer in [0, INT32_MAX]")

    record = {"requested_us": value, "device": str(device),
              "effective_before_us": effective_cpu_latency(device),
              "effective_during_us": None, "released": False}
    if value is None:
        record["effective_during_us"] = record["effective_before_us"]
        try:
            yield record
        finally:
            record["released"] = True
        return

    descriptor = None
    try:
        descriptor = os.open(device, os.O_RDWR)
        raw = _INT32.pack(value)
        written = os.write(descriptor, raw)
        if written != _INT32.size:
            raise ValueError(f"short CPU latency write: {written} bytes, expected {_INT32.size}")
        during = effective_cpu_latency(device)
        if during > value:
            raise RuntimeError(f"effective CPU latency {during} us exceeds requested {value} us")
        record["effective_during_us"] = during
    except BaseException:
        if descriptor is not None:
            os.close(descriptor)
        raise

    body_error = None
    try:
        yield record
    except BaseException as error:
        body_error = error
        raise
    finally:
        os.close(descriptor)
        record["released"] = True
        try:
            record["effective_after_release_us"] = effective_cpu_latency(device)
        except BaseException as error:
            record["release_read_error"] = str(error)
            if body_error is None:
                raise
