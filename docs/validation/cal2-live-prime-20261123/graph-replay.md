# CAL2 controller replay from captured optical measurements

Replay used the sealed fixed-pupil CPU application's two controller graphs and
FITS bindings. Its camera inputs came from the previously captured running
private-core CAL2 simulator under a 30 nm astigmatic pupil stimulus. The replay
uses ordinary FilterGraphs execution with Julia 1.13.4, PipeWireAORTC 0.7.28,
FilterGraphs 0.10.6, FilterGraphAlgorithms 0.12.12 and FilterGraphPipeWire
0.5.10. It measures graph behavior in process. The installed native control
and transport trial has its own timestamps. [Captured optical cohort](../cal2-fixed-pupil-20261122/README.md#live-optical-and-controller-comparison)

The clean replay passed 33 checks. LLOWFS published a zero offset on the first
valid camera exposure. SCC published its first zero offset on sequence 2 after
the first real fringed/unfringed pair. Both reconstructed a nonzero finite modal
residual while open. An explicit close after sequence 2 produced the first
nonzero offset on sequence 3 in both branches. Each matched the same-frame modal
residual multiplied by the authored −0.05 gain and the branch's FITS command
projection, at relative tolerance of two Float32 epsilons. The peak absolute
projected demand was 4.6138595 × 10⁻⁹ m for LLOWFS and 7.490888 × 10⁻¹⁰ m for
SCC. The stand-alone software replay observed these values at the controller
graph outputs and establishes output causality for this stimulus.

Separate replay cases verified that a missing SCC partner or a new acquisition
generation cannot reuse the earlier pair. Each required a new adjacent
opposite-role pair. A nonfinite LLOWFS exposure left the held state unchanged.
A session Reset clears the live priming observation and retains the applied
correction property. To prime again within a process whose loop is closed,
open the loop and collect a new valid live measurement. A replacement CAL2
owner starts open from its authored graph.

The finite Header CORRUPTED discriminator kept the same LLOWFS image bytes,
changed only the replayed `SampleMetadata.corrupted` fact and delivered that
sample immediately after an explicit close. LLOWFS accepted it, wrote a nonzero
offset and changed the next clean frame's result. The zero-state and first-clean
command checks failed. The new priming observer excludes such a frame from
closure evidence. Ongoing LLOWFS handling of finite corrupt frames after
closure remains separate. That repair must preserve SCC's existing consumption
of corrupt sequence identities to invalidate its retained chop history.

## Reproduction

Set `application` to the sealed fixed-pupil CAL2 application directory used in
the [paired trial](../cal2-fixed-pupil-20261122/README.md#sealed-applications).
From this evidence directory, extract the three original capture files and run
the [replay](replay_graphs.jl).

```sh
capture=$(mktemp -d)
capture_member=sealed-cal2/candidate/handshake
tar --zstd -xf ../cal2-fixed-pupil-20261122/paired-managed.tar.zst -C "$capture" \
    "$capture_member/cal2-samples.json" "$capture_member/llowfs-image.f32le" \
    "$capture_member/scc-image.f32le"
julia --startup-file=no --project="$application" replay_graphs.jl \
    "$application" "$capture/$capture_member"
```

Append `--corrupted-header` to reproduce the two failing checks on the recorded
software cohort.
