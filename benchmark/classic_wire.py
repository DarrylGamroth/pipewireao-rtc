"""Read retained packet evidence in plain or standard compressed files."""
from contextlib import contextmanager
import gzip
import lzma
from pathlib import Path
import subprocess


@contextmanager
def open_evidence(path, mode="rt"):
    path = Path(path)
    if mode not in ("rt", "rb"):
        raise ValueError("evidence is read-only")
    if not path.is_file():
        path = next((candidate for suffix in (".zst", ".xz", ".gz")
                     if (candidate := Path(str(path) + suffix)).is_file()), path)
    if path.suffix != ".zst":
        opener = {".xz": lzma.open, ".gz": gzip.open}.get(path.suffix, open)
        with opener(path, mode) as stream:
            yield stream
        return
    with subprocess.Popen(["zstd", "-q", "-d", "--stdout", str(path)],
                          stdout=subprocess.PIPE, text=mode == "rt") as process:
        try:
            yield process.stdout
        except BaseException:
            process.kill()
            process.wait()
            raise
        process.stdout.close()
        if process.wait() != 0:
            raise ValueError(f"cannot decompress evidence: {path}")
