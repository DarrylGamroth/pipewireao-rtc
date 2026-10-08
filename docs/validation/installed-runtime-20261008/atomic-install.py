from pathlib import Path
import os, shutil, hashlib, json, tempfile, sys
stage = Path(sys.argv[1]); prefix = Path('/opt/pipewireao')
backup = Path('/tmp/rtc-installed-runtime-20261008-prefix-backup')
receipt = Path(sys.argv[2])
def state(path):
    if path.is_symlink(): return {'symlink': os.readlink(path)}
    if path.is_file(): return {'sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'mode': path.stat().st_mode & 0o777}
    if path.exists(): raise RuntimeError(f'unexpected destination type: {path}')
    return None
files = sorted(p for p in stage.rglob('*') if p.is_file() or p.is_symlink())
records = []
for source in files:
    relative = source.relative_to(stage); destination = prefix / relative
    if not destination.parent.resolve().is_relative_to(prefix.resolve()): raise RuntimeError(f'escaping parent: {destination}')
    if source.is_symlink() and os.path.isabs(os.readlink(source)): raise RuntimeError(f'absolute staged link: {source}')
    records.append({'path': str(relative), 'before': state(destination), 'after': state(source)})
managed = {str(p.relative_to(stage)) for p in files}
external = {str(p.relative_to(prefix)): state(p) for p in prefix.rglob('*') if (p.is_file() or p.is_symlink()) and str(p.relative_to(prefix)) not in managed}
for record in records:
    relative = Path(record['path']); destination = prefix / relative; source = stage / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    if record['before'] is not None:
        saved = backup / relative; saved.parent.mkdir(parents=True, exist_ok=True)
        if not os.path.lexists(saved):
            if destination.is_symlink(): saved.symlink_to(os.readlink(destination))
            else: shutil.copy2(destination, saved)
    fd, temporary = tempfile.mkstemp(prefix='.pwao-install-', dir=destination.parent); os.close(fd)
    try:
        if source.is_symlink():
            os.unlink(temporary); os.symlink(os.readlink(source), temporary)
        else: shutil.copy2(source, temporary)
        os.replace(temporary, destination)
    finally:
        if os.path.lexists(temporary): os.unlink(temporary)
    assert state(destination) == record['after']
for relative, expected in external.items(): assert state(prefix / relative) == expected, relative
receipt.write_text(json.dumps({'files': records, 'external_preserved': external}, indent=2) + '\n')
print(f'Atomic install verified: {len(records)} managed files; {len(external)} external files preserved')
