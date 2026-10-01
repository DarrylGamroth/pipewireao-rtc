#!/usr/bin/env python3
"""Matched Classic CPU-latency experiments, with separate scheduler diagnostics."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import time

from classic_platform import cpu_latency_request, effective_cpu_latency
import run_classic_campaign as campaign

WORKSPACE = Path(__file__).resolve().parents[2]
ROOT = Path(__file__).resolve().parents[1]
EVENTS = ('sched:sched_switch', 'sched:sched_wakeup', 'sched:sched_wakeup_new',
          'sched:sched_migrate_task', 'power:cpu_idle')


def snapshot():
    result = {'monotonic_ns': time.monotonic_ns(), 'realtime_ns': time.time_ns(),
              'cpus': {}, 'effective_cpu_latency_us': effective_cpu_latency()}
    for cpu in range(os.cpu_count() or 1):
        base = Path(f'/sys/devices/system/cpu/cpu{cpu}')
        values = {}
        for name in ('cpufreq/scaling_driver', 'cpufreq/scaling_governor',
                     'cpufreq/energy_performance_preference', 'cpufreq/scaling_cur_freq',
                     'topology/thread_siblings_list'):
            path = base / name
            if path.exists():
                values[name] = path.read_text().strip()
        values['idle'] = {state.name: {name: (state/name).read_text().strip()
                                    for name in ('name', 'latency', 'residency', 'usage', 'time', 'disable')}
                          for state in (base/'cpuidle').glob('state*')}
        result['cpus'][str(cpu)] = values
    for name in ('/proc/sys/kernel/sched_rt_runtime_us', '/proc/interrupts', '/proc/softirqs',
                 '/proc/cmdline', '/sys/devices/system/cpu/isolated'):
        result[name] = Path(name).read_text()
    result['temperatures_millicelsius'] = {}
    for path in Path('/sys/class/hwmon').glob('hwmon*/temp*_input'):
        try:
            result['temperatures_millicelsius'][str(path)] = path.read_text().strip()
        except OSError as error:
            result['temperatures_millicelsius'][str(path)] = {'read_error': str(error)}
    return result


def source_revisions():
    roots = [ROOT, WORKSPACE/'JuliaFilterGraph.jl', WORKSPACE/'calculon-algorithms-main-copper',
             WORKSPACE/'pipewire', WORKSPACE/'pipewireao-spa-plugin-heart',
             WORKSPACE.parent/'heart/heart-copper-comparison', WORKSPACE.parent/'heart/revolt-rtc']
    return {str(root): {
        'head': subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip(),
        'status': subprocess.check_output(['git', '-C', str(root), 'status', '--porcelain'], text=True)}
        for root in roots}


def write_json(path, value):
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


def archive_diagnostics(case):
    records = []
    for name in ('perf-events.txt', 'perf.data'):
        source = case/name
        if not source.is_file():
            continue
        digest = hashlib.sha256()
        with source.open('rb') as stream:
            while data := stream.read(1024*1024):
                digest.update(data)
        target = case/(name+'.zst')
        partial = case/(name+'.zst.partial')
        with partial.open('xb') as output:
            subprocess.run(['taskset', '-c', '14', 'zstd', '-q', '-T1', '-3', '--stdout', str(source)],
                           stdout=output, check=True)
        if target.exists():
            raise FileExistsError(target)
        partial.rename(target)
        records.append({'file': name, 'sha256_uncompressed': digest.hexdigest(),
                        'bytes': source.stat().st_size, 'archive': target.name})
        write_json(case/(name+'.archive.json'), records[-1])
        source.unlink()
    return records


def run_command(path, directory, args, ready, release):
    if args.diagnostic and path != 'heart':
        command = [sys.executable, str(ROOT/'benchmark/run_classic_ingress_trace.py'),
                   '--output', str(directory), '--corpus', str(args.corpus),
                   '--frames', str(args.frames), '--role', path.split('-')[0],
                   '--rate-hz', str(args.current_rate), '--readout-us', str(args.readout_us),
                   '--library-directory', str(args.trace_library_directory),
                   '--module-library', str(args.trace_module),
                   '--heart-plugin', str(args.trace_heart_plugin)]
    else:
        command = campaign.command(path, args.corpus, directory, args.current_rate,
                                   args.readout_us, args.frames)
        command += ['--fgn-root', str(WORKSPACE/'calculon-algorithms-main-copper'),
                    '--jfg-root', str(WORKSPACE/'JuliaFilterGraph.jl')]
    # The orchestrator runs on housekeeping CPU 14. Receiver admission must see
    # the host envelope before its own role-specific placement is applied.
    return ['taskset', '-c', '0-15', *command,
            '--ingress-ready-file', str(ready), '--ingress-release-file', str(release),
            '--ingress-done-file', str(ready.parent/'ingress.done')]


def group_members(group):
    """Inspect only the owned case group; zombies cannot process more pixels."""
    members = []
    for path in Path('/proc').glob('[0-9]*/stat'):
        try:
            fields = path.read_text().rsplit(')', 1)[1].split()
        except FileNotFoundError:
            continue
        if int(fields[2]) == group and fields[0] != 'Z':
            members.append(int(path.parent.name))
    return sorted(members)


def cleanup_case_group(process, record):
    members = group_members(process.pid)
    record['case_group_empty'] = not members
    if not members:
        return
    record['errors'].append(f'receiver left case processes running: {members}')
    for action in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(process.pid, action)
        except ProcessLookupError:
            break
        deadline = time.monotonic() + 2
        while group_members(process.pid) and time.monotonic() < deadline:
            time.sleep(.02)
        if not group_members(process.pid):
            break
    record['remaining_case_processes'] = group_members(process.pid)
    record['case_group_empty'] = not record['remaining_case_processes']
    if not record['case_group_empty']:
        raise RuntimeError('case group cleanup failed; stop the campaign')


class PerfCapture:
    """Start disabled; require perf's acknowledgement before releasing pixels."""
    def __init__(self, directory):
        self.directory = directory
        self.control_read, self.control_write = os.pipe()
        self.ack_read, self.ack_write = os.pipe()
        self.log = (directory/'perf.log').open('w')
        self.command = ['taskset', '-c', '14', 'perf', 'record', '-a', '--clockid', 'mono',
                        '--delay=-1', '--no-buildid-cache', '-m', '256',
                        '--control', f'fd:{self.control_read},{self.ack_write}',
                        '-o', str(directory/'perf.data')]
        for event in EVENTS:
            self.command += ['-e', event]
            if event == 'power:cpu_idle':
                self.command += ['--filter', 'cpu_id == 0 || cpu_id == 2 || cpu_id == 4']
        try:
            self.process = subprocess.Popen(self.command, stdout=self.log, stderr=self.log,
                                            pass_fds=(self.control_read, self.ack_write))
        except BaseException:
            for fd in (self.control_read, self.control_write, self.ack_read, self.ack_write):
                os.close(fd)
            self.log.close()
            raise
        os.close(self.control_read)
        os.close(self.ack_write)

    def control(self, command):
        data = (command+'\n').encode()
        if os.write(self.control_write, data) != len(data):
            raise RuntimeError('short perf control write')
        if not select.select([self.ack_read], [], [], 10)[0]:
            raise RuntimeError(f'perf did not acknowledge {command}; see perf.log')
        if os.read(self.ack_read, 5) != b'ack\n\0':
            raise RuntimeError(f'perf failed {command}; see perf.log')

    def close(self):
        if self.process.poll() is None:
            self.process.send_signal(signal.SIGINT)
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
            raise
        finally:
            self.log.close()
            os.close(self.control_write)
            os.close(self.ack_read)
        # perf writes its trailer and re-raises the requested interrupt on exit.
        if self.process.returncode not in (0, -signal.SIGINT):
            raise RuntimeError(f'perf exited {self.process.returncode}; see perf.log')


def run_case(path, case, args):
    case.mkdir()
    ready, release = case/'ingress.ready.json', case/'ingress.release'
    directory = case/'run'
    command = run_command(path, directory, args, ready, release)
    env = dict(os.environ, OPENBLAS_NUM_THREADS='1')
    if args.diagnostic and path == 'heart':
        env['HRT_PROGRESS_TRACE_FILE'] = str(case/'heart-progress.csv')
    record = {'path': path, 'rate_hz': args.current_rate, 'frames': args.frames,
              'readout_us': args.readout_us, 'directory': str(directory),
              'command': command, 'diagnostic': args.diagnostic, 'errors': []}
    perf = None
    request_record = None
    try:
        with (case/'launch.log').open('w') as log:
            process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT,
                                       env=env, start_new_session=True)
            record['case_group_empty'] = False
            try:
                deadline = time.monotonic() + 180
                while not ready.exists():
                    if process.poll() is not None:
                        raise RuntimeError(f'receiver exited before ingress barrier: {process.returncode}')
                    if time.monotonic() > deadline:
                        raise TimeoutError('receiver preparation timed out')
                    time.sleep(.02)
                while True:
                    try:
                        record['prepared'] = json.loads(ready.read_text())
                        break
                    except json.JSONDecodeError:
                        if time.monotonic() > deadline:
                            raise TimeoutError('incomplete ingress marker')
                        time.sleep(.01)
                record['prepared_platform'] = snapshot()
                record['process_group'] = process.pid
                if any(os.getpgid(item['pid']) != process.pid
                       for item in record['prepared']['processes']):
                    raise RuntimeError('receiver escaped the case process group')
                # Avoid holding the power constraint during imports and compilation.
                with cpu_latency_request(args.current_latency) as request_record:
                    if args.current_latency is None and request_record['effective_during_us'] == 0:
                        raise RuntimeError('off condition already has an external zero-latency constraint')
                    record['before_ingress'] = snapshot()
                    if args.diagnostic:
                        perf = PerfCapture(case)
                        record['perf_command'] = perf.command
                        perf.control('enable')
                    record['release_monotonic_ns'] = time.monotonic_ns()
                    release.touch(exist_ok=False)
                    deadline = time.monotonic() + args.frames/args.current_rate + 60
                    while not (case/'ingress.done').exists() and process.poll() is None:
                        if time.monotonic() > deadline:
                            raise TimeoutError('capture completion timed out')
                        time.sleep(.02)
                    if perf is not None:
                        perf.close()
                        perf = None
                    record['after_capture'] = snapshot()
                record['returncode'] = process.wait(timeout=180)
                record['after_run'] = snapshot()
            except BaseException as error:
                record['errors'].append(f'run: {type(error).__name__}: {error}')
                raise
            finally:
                if process.poll() is None:
                    process.send_signal(signal.SIGINT)
                    try:
                        process.wait(timeout=120)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait()
                if perf is not None:
                    try:
                        perf.close()
                    except Exception as error:
                        record['errors'].append(f'perf cleanup: {error}')
                    perf = None
                cleanup_case_group(process, record)
        if args.diagnostic:
            with (case/'perf-events.txt').open('w') as events, (case/'perf-decode.log').open('w') as errors:
                subprocess.run(['taskset', '-c', '14', 'perf', 'script', '--ns',
                                '--show-lost-events', '-i', str(case/'perf.data')],
                               stdout=events, stderr=errors, check=True)
            record['perf_decoded'] = True
        record['cpu_latency_request'] = request_record
        for name in ('report.json', 'physical-summary.json', 'arithmetic-acceptance.json'):
            record[name] = json.loads((directory/name).read_text())
        record['exact_wire_delivery'] = record['physical-summary.json']['qualified']
        record['science_passed'] = record['arithmetic-acceptance.json']['arithmetic_consistency_passed']
        if path == 'heart':
            record['science_passed'] &= record['arithmetic-acceptance.json']['exact_model_passed']
        report = record['report.json']
        child_codes = ([item['returncode'] for item in report['commands'] if item.get('kind') == 'process']
                       if path == 'heart' else report['process_returncodes'])
        record['normal_child_exit'] = bool(child_codes) and all(code == 0 for code in child_codes)
        record['functional_passed'] = report.get('functional_wire_qualified', report['qualified'])
        if (not record['errors'] and record['returncode'] == 0 and record['exact_wire_delivery']
                and record['science_passed'] and record['normal_child_exit'] and record['functional_passed']):
            if args.current_latency is None and any(record[phase]['effective_cpu_latency_us'] == 0
                                                    for phase in ('before_ingress', 'after_capture')):
                raise RuntimeError('off capture has an external zero-latency constraint')
            record['latency'] = campaign.intervals(directory, args.frames, 1 if path=='heart' else 0,
                                                 args.current_rate)
            achieved = record['latency']['achieved_source_rate_hz']
            record['source_pacing_passed'] = achieved is not None and abs(achieved/args.current_rate - 1) <= .01
            if not record['source_pacing_passed']:
                record['errors'].append('source pacing outside 1% of requested rate')
        else:
            record['errors'].append('wire/science/child-exit/functional gate failed; no latency summary')

    except Exception as error:
        record['errors'].append(f'{type(error).__name__}: {error}')
        record['cpu_latency_request'] = request_record
    finally:
        # Preserve reports even when delivery fails; do not publish latency for incomplete frames.
        for name in ('report.json', 'physical-summary.json', 'arithmetic-acceptance.json'):
            file = directory/name
            if file.is_file() and name not in record:
                try:
                    record[name] = json.loads(file.read_text())
                except Exception as error:
                    record['errors'].append(f'{name}: {error}')
        try:
            if not (directory/'wire-archives.json').is_file():
                campaign.archive_wire(directory)
            if args.diagnostic:
                record['diagnostic_archives'] = archive_diagnostics(case)
        except Exception as error:
            record['errors'].append(f'archive: {error}')
        record['comparison_qualified'] = bool(record.get('latency') and
                                             record.get('source_pacing_passed') and not record['errors'])
        write_json(case/'result.json', record)
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--corpus', type=Path, default=Path('/home/dgamroth/.cache/rtc-classic-corpus1029-20260930'))
    parser.add_argument('--paths', nargs='+', choices=campaign.PATHS, default=['heart', 'fgn-row', 'jfg-row'])
    parser.add_argument('--rates', nargs='+', type=int, default=[100, 250])
    parser.add_argument('--modes', nargs='+', choices=['off', 'latency0'], default=['off', 'latency0'])
    parser.add_argument('--repeats', type=int, default=3)
    parser.add_argument('--frames', type=int, default=1029)
    parser.add_argument('--readout-us', type=int, default=2000)
    parser.add_argument('--diagnostic', action='store_true')
    trace_root = WORKSPACE/'pipewire-classic-fgn-trace/build-rtc-trace/src'
    parser.add_argument('--trace-library-directory', type=Path, default=trace_root/'pipewire')
    parser.add_argument('--trace-module', type=Path, default=trace_root/'modules/libpipewire-module-ndarray-filter-chain.so')
    parser.add_argument('--trace-heart-plugin', type=Path, default=WORKSPACE/'pipewireao-spa-plugin-heart-row-admission/build-classic-diagnostic-20260930/spa/plugins/heart/libspa-heart.so')
    args = parser.parse_args()
    if not 1 <= args.frames <= 1029 or args.frames % 7 or args.repeats < 1:
        parser.error('frames must be a multiple of seven through 1029; repeats must be positive')
    if any(rate < 1 or rate*args.readout_us >= 950000 for rate in args.rates):
        parser.error('positive readout must be below 95% of each frame period')
    if args.readout_us < 1:
        parser.error('readout must be positive')
    if args.diagnostic and (args.frames > 252 or any(path.endswith('-frame') for path in args.paths)):
        parser.error('diagnostics support HEART/row paths and at most 252 frames within trace capacities')
    args.output.mkdir(parents=True, exist_ok=False)
    manifest = {'scope': 'instrumented causal attribution' if args.diagnostic else 'uninstrumented finite-window QoS comparison',
                'requested': {key:str(value) if isinstance(value,Path) else value for key,value in vars(args).items()},
                'initial_platform': snapshot(), 'runs': [],
                'excluded_conditions': ['HEART/off: unchanged hrtTemplate requests zero CPU latency itself'],
                'source_revisions': source_revisions(),
                'harness_revision': subprocess.check_output(['git','-C',str(ROOT),'rev-parse','HEAD'],text=True).strip(),
                'harness_sha256': {str(path):hashlib.sha256(path.read_bytes()).hexdigest()
                    for path in (Path(__file__), ROOT/'benchmark/classic_platform.py',
                                 ROOT/'benchmark/run_classic_campaign.py',
                                 ROOT/'benchmark/run_classic_live.py',ROOT/'benchmark/run_classic_heart_live.py',
                                 ROOT/'benchmark/run_classic_ingress_trace.py')}}
    write_json(args.output/'manifest.json',manifest)
    for repeat in range(args.repeats):
        for rate in (args.rates if repeat%2==0 else args.rates[::-1]):
            for index,path in enumerate(args.paths if repeat%2==0 else args.paths[::-1]):
                for mode in (args.modes if (repeat+index)%2==0 else args.modes[::-1]):
                    args.current_rate = rate
                    args.current_latency = None if mode=='off' else 0
                    case = args.output/f'{path}-{rate}hz-{mode}-r{repeat+1}'
                    if path == 'heart' and mode == 'off':
                        print('SKIP '+case.name+': unchanged HEART requests zero latency itself', flush=True)
                        continue
                    print('START '+case.name,flush=True)
                    record = run_case(path,case,args)
                    record.update(mode=mode,repeat=repeat+1)
                    manifest['runs'].append(record)
                    write_json(args.output/'manifest.json',manifest)
                    print(json.dumps({'case':case.name,'returncode':record.get('returncode'),
                                      'exact':record.get('exact_wire_delivery'),'errors':record['errors']}),flush=True)
                    if record.get('cpu_latency_request') is None:
                        raise SystemExit('case failed before QoS admission; no further experiments started')
                    if record.get('case_group_empty') is False:
                        raise SystemExit('case processes remain; no further experiments started')

if __name__ == '__main__':
    main()
