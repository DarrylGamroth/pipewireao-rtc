#!/usr/bin/env python3
"""Sequential open-loop Classic campaign; retains failures and raw intervals."""
from __future__ import annotations
import argparse
from decimal import Decimal
import lzma
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys

import numpy as np
from lab_placement import host_record

ROOT = Path(__file__).resolve().parents[1]
WORKSPACE = ROOT.parent
WFS = struct.Struct('<4B8HIQII')
DM = struct.Struct('<4BHHQII')
PATHS = ('heart', 'fgn-frame', 'jfg-frame', 'fgn-row', 'jfg-row')


def summarize(values):
    values = np.asarray(values, dtype=np.float64)
    if not len(values): return None
    result = {'count':len(values), 'min':float(values.min()), 'p50':float(np.quantile(values,.5)), 'max':float(values.max())}
    if len(values) >= 100: result['p99'] = float(np.quantile(values,.99))
    return result


def intervals(directory: Path, frames: int, dm_base: int, rate: int):
    times = []
    for kind, header, count in [('wfs',WFS,frames*32),('dm',DM,frames)]:
        result=[]
        with (directory/f'{kind}-packets.tsv').open() as source:
            for ordinal,line in enumerate(source):
                timestamp,_,packet=line.rstrip('\n').split('\t')
                decoded=header.unpack(bytes.fromhex(packet[:header.size*2]))
                expected=(ordinal//32,ordinal%32+1,32) if kind=='wfs' else (ordinal+dm_base,1,1)
                observed=(decoded[-2],decoded[10],decoded[11]) if kind=='wfs' else (decoded[-2],decoded[2],decoded[3])
                if observed != expected:raise ValueError(f'{kind} packet identity/order {observed} != {expected}')
                result.append(Decimal(timestamp))
        if len(result)!=count:raise ValueError(f'{kind} count {len(result)} != {count}')
        times.append(result)
    wfs,dm=times
    rows=[]
    for n in range(frames):
        first=float((dm[n]-wfs[n*32])*1000000)
        terminal=float((dm[n]-wfs[n*32+31])*1000000)
        if terminal<0:raise ValueError('DM before terminal packet')
        rows.append({'frame':n,'first_to_dm_us':first,'terminal_to_dm_us':terminal,
                     'readout_us':first-terminal,'deadline_exceeded':first>1e6/rate})
    (directory/'latency-intervals.json').write_text(json.dumps(rows)+'\n')
    periods=[float((wfs[n*32]-wfs[(n-1)*32])*1000000) for n in range(1,frames)]
    return {'all':{field:summarize([row[field] for row in rows]) for field in ('first_to_dm_us','terminal_to_dm_us','readout_us')},
            'after_first_100':{field:summarize([row[field] for row in rows[100:]]) for field in ('first_to_dm_us','terminal_to_dm_us','readout_us')},
            'deadline_exceeded_count':sum(row['deadline_exceeded'] for row in rows),
            'source_period_us':summarize(periods),
            'achieved_source_rate_hz':(frames-1)/float(wfs[-32]-wfs[0]) if frames>1 else None}


def archive_wire(directory):
    if not directory.is_dir():
        return
    records=[]
    for name in ('wire.pcapng','wfs-packets.tsv','dm-packets.tsv'):
        source=directory/name
        if not source.is_file():continue
        digest=hashlib.sha256()
        zstd = shutil.which('zstd')
        target=source.with_suffix(source.suffix+('.zst' if zstd else '.xz'))
        with source.open('rb') as reader:
            while data:=reader.read(1024*1024):
                digest.update(data)
        if zstd:
            with target.open('xb') as writer:
                subprocess.run([zstd,'-q','-T1','-3','--long=23','--stdout',str(source)],
                               stdout=writer,check=True)
        else:
            with source.open('rb') as reader,lzma.open(target,'xb',preset=4) as writer:
                shutil.copyfileobj(reader,writer,1024*1024)
        records.append({'file':name,'sha256_uncompressed':digest.hexdigest(),'bytes':source.stat().st_size,
                        'archive':target.name,'compression':'zstd level3 window8MiB' if zstd else 'lzma preset4'})
        source.unlink()
    (directory/'wire-archives.json').write_text(json.dumps(records,indent=2)+'\n')


def command(path, corpus, output, rate, readout, frames, trace=0, workers=0, layout='shared'):
    fixture=Path('/home/dgamroth/.cache/rtc-classic-matched-arrays-20260930/fixture')
    common=['--fixture',str(fixture),'--cube',str(corpus/'input.fits'),'--replay-corpus',str(corpus),
            '--frames',str(frames),'--output',str(output),'--rate-hz',str(rate),'--readout-us',str(readout),
            '--rtc-cpus','0,2,4,6,8,10,14','--source-cpus','12','--numerical-acceptance','source-arithmetic']
    if path=='heart':
        return [sys.executable,str(ROOT/'benchmark/run_classic_heart_live.py'),*common,
                '--heart-root',str(WORKSPACE.parent/'heart/heart-copper-comparison'),
                '--calibration-root',str(WORKSPACE.parent/'heart/revolt-rtc'),
                '--cpu-map',str(ROOT/'benchmark/profiles/ryzen-6800h-classic.cpu'),
                '--thread-map',str(ROOT/'benchmark/profiles/ryzen-6800h-classic.threads'),
                '--telemetry-python','/home/dgamroth/.cache/rtc-heart-telemetry-venv-20260930/bin/python']
    role,mode=path.split('-')
    result=[sys.executable,str(ROOT/'benchmark/run_classic_live.py'),*common,'--role',role,'--mode',mode,
            '--plugin',str(WORKSPACE/'calculon-algorithms-main-copper/target/release/libcalculon_fgn_bundle.so'),
            '--heart-plugin','/opt/pipewireao/lib/x86_64-linux-gnu/spa-ao-0.2/heart/libspa-heart.so',
            '--heart-plugin-sha256','db021461bfb05d41939e0db54e56620c3d7ae38e626763aee59110becd65f784',
            '--wfs-simulator',str(WORKSPACE.parent/'heart/heart-copper-comparison/source/testServer/bin/wfsSimulator'),
            '--lab-loop-cpu','0','--adapter-loop-cpu','4']
    if role=='jfg':
        result+=['--node-loop-cpu','2','--julia-pin-cpus',','.join(map(str,[2,6,8,10][:workers+2])),
                 '--row-workers',str(workers),'--matrix-layout',layout]
        if trace:result+=['--trace-callbacks',str(trace)]
    return result


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--corpus',type=Path,default=Path('/home/dgamroth/.cache/rtc-classic-corpus1029-20260930'))
    parser.add_argument('--paths',nargs='+',choices=PATHS,default=PATHS)
    parser.add_argument('--rates',nargs='+',type=int,default=[100])
    parser.add_argument('--frames',type=int,default=1029)
    parser.add_argument('--repeats',type=int,default=3)
    parser.add_argument('--readout-us',type=int,default=2000)
    parser.add_argument('--trace',type=int,default=0)
    parser.add_argument('--workers',type=int,default=0)
    parser.add_argument('--layout',choices=('shared','sharded'),default='shared')
    args=parser.parse_args()
    if args.output.exists():parser.error('output must be new')
    args.output.mkdir()
    revisions = {}
    for name in ('pipewireao-rtc-progressive-requal', 'JuliaFilterGraph-progressive-requal',
                 'calculon-algorithms-main-copper', 'pipewire'):
        repo = WORKSPACE / name
        revisions[name] = {
            'revision': subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip(),
            'status': subprocess.check_output(['git', '-C', str(repo), 'status', '--short'], text=True),
        }
    manifest={'host':host_record(),'source_revisions':revisions,'runs':[],'requested':vars(args)|{'output':str(args.output),'corpus':str(args.corpus)},
              'scope':'finite-window open-loop characterization; strict numerical failures retained separately; no physical-loop qualification'}
    for rate in args.rates:
        readout=min(args.readout_us,int(850000/rate))
        for repeat in range(args.repeats):
            paths=list(args.paths)
            if repeat%2:paths.reverse()
            for path in paths:
                directory=args.output/f'{path}-{rate}hz-r{repeat+1}'
                cmd=command(path,args.corpus,directory,rate,readout,args.frames,args.trace,args.workers,args.layout)
                competing = subprocess.check_output(['ps', '-eo', 'pid,comm,psr,pcpu', '--sort=-pcpu'], text=True).splitlines()[:16]
                print(f'START {path} {rate} Hz repeat{repeat+1}',flush=True)
                with (args.output/f'{directory.name}.launch.log').open('w') as log:
                    result=subprocess.run(cmd,stdout=log,stderr=subprocess.STDOUT,check=False)
                record={'path':path,'rate_hz':rate,'readout_us':readout,'repeat':repeat+1,'directory':str(directory),'command':cmd,'returncode':result.returncode,'competing_process_snapshot_before':competing}
                try:
                    report=json.loads((directory/'report.json').read_text());record['report']=report
                    record['latency']=intervals(directory,args.frames,1 if path=='heart' else 0,rate)
                    physical=json.loads((directory/'physical-summary.json').read_text())
                    record['exact_wire_delivery']=physical.get('qualified') is True
                except Exception as error:record['analysis_error']=str(error);record['exact_wire_delivery']=False
                manifest['runs'].append(record)
                (args.output/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
                try:
                    archive_wire(directory)
                except Exception as error:
                    record['archive_error'] = str(error)
                (args.output/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
                print(json.dumps({'path':path,'rate':rate,'returncode':result.returncode,'exact_wire_delivery':record['exact_wire_delivery'],'latency':record.get('latency')}),flush=True)

if __name__=='__main__':main()
