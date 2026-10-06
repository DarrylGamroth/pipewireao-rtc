"""Run the unchanged cold oracle with exact RAM evidence in a private namespace."""
import json
import os
from pathlib import Path
import subprocess
import sys

receipt = Path(sys.argv[1]).resolve()
repo = Path(__file__).resolve().parents[3]
original = Path('/home/dgamroth/.cache/rtc-calibration-completion-20261003/classic-native-transfer-v2-evidence')
ram = Path(json.loads(receipt.read_text())['destination'])
julia = '/home/dgamroth/.julia/juliaup/julia-1.12.7+0.x64.linux.gnu/bin/julia'
if len(sys.argv) == 2:
    print('host_mount_namespace=', os.readlink('/proc/self/ns/mnt'), flush=True)
    code = subprocess.run(['unshare', '--user', '--map-root-user', '--mount',
                           '--propagation', 'private', 'python3', str(Path(__file__).resolve()),
                           str(receipt), '--child']).returncode
    assert len([p for p in original.rglob('*') if p.is_file()]) == 202
    print('host_evidence_unchanged_entries=202', flush=True)
    sys.exit(code)
assert sys.argv[2:] == ['--child']
print('private_mount_namespace=', os.readlink('/proc/self/ns/mnt'), flush=True)
subprocess.run(['mount', '--bind', str(ram), str(original)], check=True)
subprocess.run(['mount', '-o', 'remount,bind,ro', str(original)], check=True)
assert len([p for p in original.rglob('*') if p.is_file()]) == 205
print('private_evidence_entries=205', flush=True)
sys.exit(subprocess.run([julia, '--startup-file=no', '--compiled-modules=existing',
                         f'--project={repo / "deployment/julia"}',
                         str(Path(__file__).with_name('historical-transfer-oracle.jl'))],
                        cwd=repo).returncode)
