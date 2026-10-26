# Hidden-mode source and export verification

Source bases: RTC `e23c30a`, instruments `5ae24c8`; both use the dedicated
`codex/gpi2-heart-20261025` branch. The science environment uses Julia 1.13.2
and the registered dependency environment with a validation-only RTC source
override. No application dependency pins, live service or GUI changed.

The shared calibration selector passes 65/65 checks; the focused RTC exporter
selector passes every testset. See `calibration-tests-final.log` and
`export-tests-final.log`. Run from the RTC source:

```sh
julia --startup-file=no --project=/path/to/science-environment test/modal_hidden_modes.jl
julia --startup-file=no --project=/path/to/science-environment test/test_instrument_export.jl
```

The full profile selector runs from the instrument source:

```sh
TMPDIR=/path/to/task-owned-disk-directory timeout 900 \
  julia --startup-file=no --project=/path/to/science-environment test/gpi2_hidden_modes.jl
```

The initial run exposed a mistaken assertion that all parameter inputs must have
FITS bindings: the two mirror shape offsets intentionally retain zero defaults.
The corrected test requires precisely that missing set and loads every supplied
binding. The same run then exhausted the shared `/tmp` filesystem. No foreign
files were removed. The next attempt used a task-owned directory on disk and
`--compile=min`; it was interrupted after more than 13 minutes without finishing
the first export. These failed harness runs remain in `profile-tests.log` and
`profile-tests-v2.log`. The final run uses normal compilation and the owned disk
directory. It passes **27/27 checks** in 9m44.8s, within the 900-second bound;
see `profile-tests-final.log`. Both modes export, their exact FITS bindings load,
and selected RTC/simulator/publication identities agree. This verifies the
exported zero-gain option, not a nonzero-gain deployment or optical benefit.

The parent calibration receipt SHA-256 remains
`96f09d4c29e21e2f8143d4c326dc7e507309d0cfa47afd20e4cc418d8a89c9d4`;
the reconstructor remains
`2a3a8d14176cf224887be016d5865563dd03d4c8fca87d056771903eb8b0d0bf`.
The generated receipt hash is
`bfa6ee7d1af0f832827f68b88f2807a1da05521e26656b895d0b7edb13ceb61a`,
matching its configuration/profile identity after formatting. Focused yamlfmt
checks and both source trees' whitespace checks pass. Pre-existing calibration
formatting is preserved to retain its recorded bytes.

`RUN.md` and the raw numerical records are copied verbatim from the diagnostic
scratch directory. Its summary hashes also list large process-specific Julia
serialization snapshots and a one-off scratch summary script that are not
shipped as maintained tools. The retained Julia replay and raw JSON contain the
scientific observations. `SHA256SUMS` identifies this retained evidence subset.
