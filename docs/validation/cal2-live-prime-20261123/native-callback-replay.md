# CAL2 native callback first-use timing

On the shared workstation, the first published LLOWFS callback took
249.6–361.6 µs with the online synthetic check and 317.4–703.5 µs when it
was skipped. The first complete SCC pair took 633.8–991.0 µs with the
check and 704.9–799.3 µs when skipped. The first-callback ranges overlap
and the median changes differ by branch and exposure phase. Three fresh
processes per arm give a first-use scale for this replay.

| Candidate owner and timed callback | Online check, median (range), µs | Online check skipped, median (range), µs |
| --- | ---: | ---: |
| LLOWFS first published exposure | 264.536 (249.638–361.558) | 349.104 (317.415–703.539) |
| LLOWFS later exposures | 82.746 (78.307–321.843) | 92.764 (80.451–225.643) |
| SCC first unpaired exposure | 227.026 (225.783–229.921) | 249.368 (204.523–348.374) |
| SCC first complete pair | 808.155 (633.838–991.008) | 731.080 (704.902–799.349) |
| SCC later complete pairs | 433.918 (369.643–844.834) | 470.467 (381.104–855.714) |

Later rows pool 128 callbacks per process on sequences 3 through 130. A
separate reference run of each deployed baseline graph loaded that owner's
own installed image and ran the online check. LLOWFS took 275.076 µs for
its first exposure and had a 137.528 µs later median. SCC took 216.827 µs
for the unpaired exposure and 640.962 µs for the first complete pair, with
a 472.115 µs later median. The baseline graph lacks the candidate's live
priming observer. The controlled table uses the same installed candidate
graph and package image in both arms to isolate the online check.

## Boundary and correctness

The fixture constructs the installed graph owner with its bound FITS
calibration, then invokes its actual `on_process` callback over
`pw_ndarray_filter_buffer` leases. It replays archived row-major camera
bytes and reconstructs the native Headers, acquisition identities,
exposure durations and chopper records. The first exposures retain their
captured sequence and model time. For later repeats the fixture cycles
the captured payloads and advances the sequences and model time.
Every run verified that the first SCC exposure withheld all outputs, the
second and later SCC exposures published a complete pair, and every LLOWFS
exposure published. Published results retained the input acquisition
identity and Header time, with finite nonzero residuals and exact-zero
physical offsets. [Archived camera bytes and acquisition records](../cal2-fixed-pupil-20261122/paired-managed.tar.zst)

The replay measures host monotonic time around the first and later
invocations of the Julia native-buffer callback through `Base.invokelatest`.
This includes dispatch and any process-local first-use JIT, buffer
preflight, controller execution and output metadata. The median warmed
no-op dispatch shim was 30–50 ns. The disconnected graph fixture excludes
the native driver's scheduling, camera cadence, Links and observer queues.
Its operation time cannot establish a detector-to-command deadline. CPU 15
was pinned for the replay as an ordinary process on the AMD Ryzen 7 6800H
workstation, outside the service owners' assigned CPUs.

Each run used Julia 1.13.3 at its default optimization level with two
default threads, one BLAS thread and `--compiled-modules=existing`. The
installed manifests selected PipeWireAORTC 0.7.29, FilterGraphPipeWire
0.5.11 and FilterGraphs 0.10.6. The fixture verified the branch-specific
`ExportedGraphWarmup.so` mapping in each process. The [run record](native-callback-replay.json)
contains package trees, graph, calibration-binding, application-manifest,
package-image and camera-payload hashes, process order and all callback
samples.

## Reproduction

Set `application` to the installed baseline or candidate application from
this validation cohort. Use its service fixture's `JULIA_DEPOT_PATH`
and `JULIA_LOAD_PATH` so its installed package images can load their exact
dependencies. From this evidence directory, extract the camera inputs and
run the [native replay](native-replay.jl) in a fresh process.

```sh
replay_dir=$(mktemp -d)
capture_member=sealed-cal2/candidate/handshake
tar --zstd -xf ../cal2-fixed-pupil-20261122/paired-managed.tar.zst -C "$replay_dir" \
    "$capture_member/cal2-samples.json" "$capture_member/llowfs-image.f32le" \
    "$capture_member/scc-image.f32le"
CAL2_REPLAY_RESULT="$replay_dir/scc-skip.json" OPENBLAS_NUM_THREADS=1 \
    taskset -c 15 julia +1.13.3 --startup-file=no --threads=2,0 \
    --compiled-modules=existing --project="$application" native-replay.jl \
    "$application" scc skip "$replay_dir/$capture_member"
```

Use branch `llowfs` for LLOWFS and mode `warm` to run the configured
synthetic workload before the timed callbacks.
