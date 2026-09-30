#!/usr/bin/env python3
"""Run an instrumented Classic row replay with the existing native ingress trace.

The diagnostic library replaces only the private replay library. No installed
file is changed. This is transport attribution, separate from latency trials.
"""
from __future__ import annotations
import argparse
from dataclasses import replace
import hashlib
import json
from pathlib import Path
import sys
import time

from run_classic_campaign import command, archive_wire, intervals
import run_classic_live


def clock_anchor():
    before = time.monotonic_ns()
    realtime = time.time_ns()
    return {'monotonic_before_ns': before, 'realtime_ns': realtime,
            'monotonic_after_ns': time.monotonic_ns()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--library-directory', type=Path, required=True)
    parser.add_argument('--module-library', type=Path, required=True)
    parser.add_argument('--corpus', type=Path, required=True)
    parser.add_argument('--frames', type=int, default=63)
    args = parser.parse_args()
    args.output = args.output.resolve()
    if args.output.exists():
        parser.error('output must be new')
    library = (args.library_directory / 'libpipewire-ao-0.3.so').resolve(strict=True)
    module_library = args.module_library.resolve(strict=True)
    module_directory = args.output.parent / (args.output.name + '.modules')
    # Resolve all other binaries and modules through the deployed installation.
    original_load = run_classic_live.load_script
    def load(name, path):
        result = original_load(name, path)
        if name == 'classic_live_transport':
            original_installation = result.pipewire_installation
            original_environment = result.make_environment
            def installation(*parameters):
                installed = original_installation(*parameters)
                module_directory.mkdir()
                for entry in installed.module_directory.iterdir():
                    (module_directory / entry.name).symlink_to(entry)
                module = module_directory / 'libpipewire-module-ndarray-filter-chain.so'
                module.unlink()
                module.symlink_to(module_library)
                return replace(installed, library_directory=library.parent,
                               module_directory=module_directory)
            def environment(directory, *parameters):
                env = original_environment(directory, *parameters)
                trace = directory / 'native-ingress-trace'
                trace.mkdir()
                env['PW_NDARRAY_FILTER_TRACE_DIR'] = str(trace)
                env['PW_FGN_PROCESS_TRACE_DIR'] = str(trace)
                return env
            result.pipewire_installation = installation
            result.make_environment = environment
        return result
    cmd = command('fgn-row', args.corpus, args.output, 100, 2000, args.frames)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    (args.output.parent / (args.output.name + '.command.json')).write_text(json.dumps(cmd) + '\n')
    diagnostic = {'library': str(library),
                  'sha256': hashlib.sha256(library.read_bytes()).hexdigest(),
                  'module': str(module_library),
                  'module_sha256': hashlib.sha256(module_library.read_bytes()).hexdigest(),
                  'source_sha256': {str(path.resolve()): hashlib.sha256(path.read_bytes()).hexdigest()
                      for path in (Path(__file__), Path(run_classic_live.__file__),
                                   Path(__file__).with_name('run_classic_campaign.py'))},
                  'before_run': clock_anchor(),
                  'scope': 'instrumented attribution; not the deployed latency baseline'}
    original_argv = sys.argv
    run_error = None
    run_classic_live.load_script = load
    sys.argv = cmd[1:]
    try:
        run_classic_live.main()
    except BaseException as error:
        run_error = error
        raise
    finally:
        run_classic_live.load_script = original_load
        sys.argv = original_argv
        try:
            diagnostic['after_run'] = clock_anchor()
            args.output.mkdir(exist_ok=True)
            (args.output / 'diagnostic-library.json').write_text(json.dumps(diagnostic, indent=2) + '\n')
            if (args.output / 'dm-packets.tsv').exists():
                try:
                    intervals(args.output, args.frames, 0, 100)
                except ValueError as error:
                    (args.output / 'interval-error.json').write_text(json.dumps(str(error)) + '\n')
            archive_wire(args.output)
        except Exception as error:
            if run_error is None:
                raise
            print(f'trace finalization failed after replay failure: {error}', file=sys.stderr)

if __name__ == '__main__':
    main()
