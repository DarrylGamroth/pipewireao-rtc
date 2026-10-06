"""Restore a bounded cold historical evidence copy into a fresh RAM directory."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile

cache = Path('/home/dgamroth/.cache/rtc-calibration-completion-20261003')
source = cache / 'classic-native-transfer-v2-evidence'
archive = cache / 'historical-telemetry-archive-20261005'
manifest = json.loads((source / 'native-evidence-manifest.json').read_text())
records = json.loads((archive / 'manifest.json').read_text())['files']
archived = {row['path']: row for row in records}
present = [p for p in source.rglob('*') if p.is_file()]
assert not any(p.is_symlink() for p in source.rglob('*'))
missing = sorted(set(manifest) - {str(p.relative_to(source)) for p in present})
assert len(present) == 202 and len(missing) == 3
expanded = sum(p.stat().st_size for p in present)
expanded += sum(archived[f'{source.name}/{name}']['size'] for name in missing)
assert expanded <= 1.3 * 1024**3
assert shutil.disk_usage('/dev/shm').free - expanded >= 2 * 1024**3

def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(8 * 1024**2), b''):
            h.update(block)
    return h.hexdigest()

root = Path(tempfile.mkdtemp(prefix='rtc-classic-transfer-', dir='/dev/shm'))
destination = root / source.name
receipt = {'root': str(root), 'destination': str(destination),
           'scope': 'cold exact historical evidence copy; no SCI',
           'archive_manifest_sha256': sha(archive / 'manifest.json'),
           'expanded_bytes': expanded, 'entries': {}}
for path in present:
    relative = path.relative_to(source)
    target = destination / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(path, target)
    info = path.stat()
    receipt['entries'][str(relative)] = {
        'sha256': sha(path), 'size': info.st_size, 'mode': stat.S_IMODE(info.st_mode),
        'mtime_ns': info.st_mtime_ns, 'uid': info.st_uid, 'gid': info.st_gid}
command = ['python3', str(archive / 'restore.py'), '--destination', str(root)]
for name in missing:
    command += ['--path', f'{source.name}/{name}']
subprocess.run(command, check=True)
for name in missing:
    row = archived[f'{source.name}/{name}']
    receipt['entries'][name] = {key: row[key] for key in
                               ('sha256', 'size', 'mode', 'mtime_ns', 'uid', 'gid')}
actual = {str(p.relative_to(destination)) for p in destination.rglob('*') if p.is_file()}
assert actual == set(receipt['entries']) and len(actual) == 205
expected = dict(manifest)
for name in ('native-evidence-manifest.json', 'native-plan-result.json'):
    expected[name] = sha(source / name)
for name, row in receipt['entries'].items():
    path = destination / name
    info = path.stat()
    assert not path.is_symlink()
    assert sha(path) == row['sha256'] == expected[name]
    assert info.st_size == row['size']
    assert stat.S_IMODE(info.st_mode) == row['mode']
    assert (info.st_mtime_ns, info.st_uid, info.st_gid) == (row['mtime_ns'], row['uid'], row['gid'])
receipt['verified'] = True
receipt['ramfs_free_after'] = shutil.disk_usage('/dev/shm').free
assert receipt['ramfs_free_after'] >= 2 * 1024**3
Path(sys.argv[1]).write_text(json.dumps(receipt, indent=2) + '\n')
print('verified_ram_evidence=', destination, 'entries=', len(actual), 'bytes=', expanded)
