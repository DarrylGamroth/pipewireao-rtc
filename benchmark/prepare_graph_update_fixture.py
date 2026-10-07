#!/usr/bin/env python3
"""Prepare a sealed development fixture; never modify the supplied packages."""
import argparse
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import subprocess


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def decode(path):
    env = dict(os.environ, LD_LIBRARY_PATH='/opt/pipewireao/lib/x86_64-linux-gnu')
    text = subprocess.check_output(['/opt/pipewireao/bin/pwao-spa-json-dump', '-N', '-R', str(path)], env=env, text=True)
    return json.loads(text)


def save(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


TRACE_WRITER = '''
# Development fixture instrumentation: preallocated native callback counters;
# serialization only after the node and its workers have stopped.
function save_graph_update_trace(owner)
    directory = ENV["RTC_GRAPH_UPDATE_TRACE_DIR"]
    mkpath(directory)
    trace = owner.callback_trace
    open(joinpath(directory, "callbacks.csv"), "w") do io
        println(io, "sequence,offset,start_ns,end_ns,gc_pause_start,gc_pause_end,gc_total_start_ns,gc_total_end_ns,allocated_start,allocated_end")
        for i in 1:trace.count
            println(io, join((trace.sequence[i], trace.offset[i], trace.start_ns[i], trace.end_ns[i],
                trace.gc_pause_start[i], trace.gc_pause_end[i], trace.gc_total_time_start_ns[i],
                trace.gc_total_time_end_ns[i], trace.gc_allocated_bytes_start[i], trace.gc_allocated_bytes_end[i]), ','))
        end
    end
    open(joinpath(directory, "trace-summary.txt"), "w") do io
        println(io, "count=", trace.count, " omitted=", trace.omitted, " capacity=", length(trace.sequence), " gc_enabled=", trace.record_gc)
    end
    return nothing
end
'''


ALLOCATION_WRITER = '''
using Profile
function save_graph_update_allocations()
    samples = Profile.Allocs.fetch().allocs
    directory = ENV["RTC_GRAPH_UPDATE_TRACE_DIR"]
    mkpath(directory)
    # Aggregate after stop: never expand parameterized types or repeat entire
    # stacks per allocation. Include every sample; no task pointer is inspected.
    totals = Dict{Symbol,Tuple{Int,Int}}(:frame => (0,0))
    hot = Set((:_process_graph_callback!, :_process_graph_buffers!,
        :_process_feedback_buffers!, :_process_synchronized_buffers!,
        :_process_admitted!, :_adopt_pending_properties!,
        :_adopt_pending_parameters!, :GraphProcessCallback))
    properties = Set((:GraphGetPropertiesCallback, :GraphSetPropertiesCallback,
        :_graph_properties, :_stage_property_transaction!, :_prepare_property_update))
    sites = Dict{Tuple{Symbol,Symbol,Int},Tuple{Int,Int}}()
    first_timestamp = typemax(UInt64)
    last_timestamp = UInt64(0)
    for sample in samples
        first_timestamp = min(first_timestamp, sample.timestamp)
        last_timestamp = max(last_timestamp, sample.timestamp)
        category = :other
        if any(frame -> frame.func in hot, sample.stacktrace)
            category = :frame
        elseif any(frame -> frame.func == :_stage_parameter_transaction! ||
                frame.func == :_prepare_parameter_transaction, sample.stacktrace)
            category = :parameter_preparation
        elseif any(frame -> frame.func in properties, sample.stacktrace)
            category = :property_control
        elseif isempty(sample.stacktrace)
            category = :empty_stack
        end
        count, bytes = get(totals, category, (0,0))
        totals[category] = (count+1, bytes+sample.size)
        if category == :frame
            for frame in sample.stacktrace
                frame.from_c && continue
                key = (frame.func, frame.file, frame.line)
                count, bytes = get(sites, key, (0,0))
                sites[key] = (count+1, bytes+sample.size)
            end
        end
    end
    open(joinpath(directory, "allocation-summary.tsv"), "w") do io
        println(io, "category\\tcount\\tbytes")
        for category in sort!(collect(keys(totals)); by=string)
            count, bytes = totals[category]
            println(io, category, '\\t', count, '\\t', bytes)
        end
    end
    open(joinpath(directory, "allocation-frame-sites.tsv"), "w") do io
        println(io, "function\\tfile\\tline\\tcount\\tbytes")
        for (key, value) in sites
            println(io, join((key..., value...), '\\t'))
        end
    end
    open(joinpath(directory, "allocation-capture.txt"), "w") do io
        println(io, "samples=", length(samples), " sample_rate=1.0 timestamp_raw_first=",
            isempty(samples) ? 0 : first_timestamp, " timestamp_raw_last=", last_timestamp)
    end
    return nothing
end
'''


def prepare(jfg, destination, fgn=None, trace=None, allocations=False):
    assert not destination.exists() and not destination.is_symlink()
    assert re.fullmatch(r"[a-z0-9-]{1,40}", destination.name), 'Deployment name must fit the public 40-character limit'
    for source in (jfg, fgn):
        if source is None:
            continue
        assert not any(p.is_symlink() for p in source.rglob('*'))
        spec = json.loads((source / 'deployment.conf').read_text())
        assert all(digest(source / name) == expected for name, expected in spec['artifacts'].items())
    shutil.copytree(jfg, destination)
    spec = json.loads((destination / 'deployment.conf').read_text())
    provenance = json.loads((destination / 'provenance.json').read_text())
    changes = []
    if fgn:
        old = json.loads((fgn / 'deployment.conf').read_text())
        # Native graph/placement are existing FGN declarations; optical model,
        # detector offsets, all calibration arrays and current SDK stay JFG's.
        for relative in ('core.conf.in', 'client-rtc.conf.in', 'graphs/graph.conf.in'):
            shutil.copyfile(fgn / relative, destination / relative)
            changes.append(relative)
        shutil.copytree(fgn / 'lib', destination / 'lib')
        spec['owners'] = [o for o in spec['owners'] if o['role'] != 'julia']
        spec['placement'] = old['placement']
        spec['client'].pop('julia')
        session = decode(fgn / old['session'])
        save(destination / spec['session'], session)
        changes.append(spec['session'])
        provenance['engine'] = 'fgn'
        provenance['parameters'] = json.loads((fgn / 'provenance.json').read_text())['parameters']
        for parameter in provenance['parameters']:
            path = destination / 'calibration' / parameter['file']
            parameter['sha256'] = digest(path)
        provenance['graph_sha256'] = digest(destination / 'graphs/graph.conf.in')
    elif trace:
        owner = next(o for o in spec['owners'] if o['role'] == 'julia')
        owner.setdefault('environment', {}).update(JULIA_RTC_TRACE_GC='1', RTC_GRAPH_UPDATE_TRACE_DIR=str(trace))
        wrapper = destination / 'hil/jfg_owner.jl'
        text = wrapper.read_text()
        anchor = 'fifo_inputs=options.fifo_inputs, feedback=options.feedback)'
        assert text.count(anchor) == 1
        text = text.replace(anchor, 'fifo_inputs=options.fifo_inputs, feedback=options.feedback, trace_callbacks=1024)')
        anchor = 'Bootstrap.finishing!(runtime)\n            close(node)'
        assert text.count(anchor) == 1
        text = text.replace(anchor, anchor + '\n            save_graph_update_trace(node.owner)')
        if allocations:
            assert text.count('Bootstrap.prepared!(runtime)') == 1
            text = text.replace('Bootstrap.prepared!(runtime)',
                'Profile.Allocs.start(sample_rate=1.0)\n            Bootstrap.prepared!(runtime)')
            assert text.count('Bootstrap.finishing!(runtime)') == 1
            text = text.replace('Bootstrap.finishing!(runtime)',
                'Profile.Allocs.stop()\n            Bootstrap.finishing!(runtime)')
            text = text.replace('save_graph_update_trace(node.owner)',
                'save_graph_update_trace(node.owner)\n            save_graph_update_allocations()')
            text = ALLOCATION_WRITER + text
        wrapper.write_text(TRACE_WRITER + text)
        changes.append('hil/jfg_owner.jl')
    simulator = next(o for o in spec['owners'] if o['role'] == 'simulator')
    for flag, value in (('--frames', '256'), ('--total-exchanges', '512'), ('--wall-rate', '100')):
        simulator['argv'][simulator['argv'].index(flag) + 1] = value
    provenance['hil'].update(frames=256, total_exchanges=512, wall_rate='100', wall_rate_hz=100)
    provenance['graph_update_fixture'] = {'jfg_source': str(jfg), 'fgn_graph_source': str(fgn) if fgn else None,
        'scope': 'functional controls fixture; no new scientific calibration or released qualification',
        'configuration_changes': changes, 'model_rate_unchanged': True}
    save(destination / 'provenance.json', provenance)
    spec['name'] = destination.name
    spec['artifacts'] = {str(p.relative_to(destination)): digest(p) for p in destination.rglob('*')
                         if p.is_file() and p.name != 'deployment.conf'}
    save(destination / 'deployment.conf', spec)
    protected = [p for p in jfg.rglob('*') if p.is_file() and
                 (p.relative_to(jfg).parts[0] in ('calibration', 'hil', 'jfg')) and
                 str(p.relative_to(jfg)) not in changes]
    assert all(digest(p) == digest(destination / p.relative_to(jfg)) for p in protected)
    assert all(digest(destination / name) == expected for name, expected in spec['artifacts'].items())
    save(destination.with_suffix('.fixture.json'), {'package': str(destination), 'protected_original_files': len(protected),
        'descriptor_sha256': digest(destination / 'deployment.conf'), 'changes': changes,
        'jfg_source_descriptor_sha256': digest(jfg / 'deployment.conf'),
        'fgn_source_descriptor_sha256': digest(fgn / 'deployment.conf') if fgn else None})
    print(f'Prepared {destination}; protected {len(protected)} original scientific/source files')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('jfg', type=Path)
    parser.add_argument('destination', type=Path)
    parser.add_argument('--fgn', type=Path)
    parser.add_argument('--trace', type=Path)
    parser.add_argument('--allocations', action='store_true', help='Diagnostic only: collect allocation stacks in the Julia owner')
    args = parser.parse_args()
    assert not (args.fgn and args.trace)
    assert not args.allocations or (args.trace and not args.fgn)
    prepare(args.jfg.resolve(), args.destination.absolute(), args.fgn.resolve() if args.fgn else None,
            args.trace.absolute() if args.trace else None, allocations=args.allocations)
