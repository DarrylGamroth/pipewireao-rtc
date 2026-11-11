# Precompile managed CPU optical startup

This experiment uses the exact optical configuration from an exported CAL2
or fitted-dual SPIDERS application. It exercises the managed HIL extension's
optical graph preparation and warmup with its normal synthetic samples. The
workload opens no PipeWire remote and asserts that warmup leaves the
acquisition sequence at zero. It uses an offline cancellation callback.

Use an application whose manifest already contains PrecompileTools, and the
Julia/depot combination used to run that application. Run the commands in
a separate development shell. The application is read-only and the
generated project and depot are disposable.

```bash
# Set application to the exported application and bench to this directory.
application=$(realpath "$application")
bench=$(realpath "$bench")
trial=$(mktemp -d)
export JULIA_DEPOT_PATH="$trial/depot:${JULIA_DEPOT_PATH:-$HOME/.julia:}"
export JULIA_LOAD_PATH=@:@stdlib
export OPENBLAS_NUM_THREADS=1

# Fresh process with the application's usual dependency caches.
julia --startup-file=no --threads=2,0 --project="$application" \
  "$bench/baseline.jl" "$application/simulation.conf"

mkdir "$trial/src"
cp "$bench/"{baseline,workload}.jl "$trial/"
cp "$bench/OpticalStartup.jl" "$trial/src/"
cp "$application/Manifest.toml" "$trial/"
printf '%s\n' "$application" > "$trial/application"
{
  printf 'name = "OpticalStartup"\nuuid = "1c9110c7-8607-431e-9602-7e407532da81"\nversion = "0.1.0"\n\n'
  sed '/^\[deps\]$/a PrecompileTools = "aea7be01-6a6a-4083-8856-8a6e6704d82a"' \
    "$application/Project.toml"
} > "$trial/Project.toml"

# One-time workload compilation in its own process.
time julia --startup-file=no --threads=2,0 --project="$trial" \
  -e 'using OpticalStartup'

# Fresh process. Allow reuse of existing images without building a new one.
time julia --startup-file=no --compiled-modules=existing --pkgimages=existing \
  --threads=2,0 --project="$trial" \
  -e '@time using OpticalStartup; include(popfirst!(ARGS))' \
  "$trial/baseline.jl" "$application/simulation.conf"
```

The last command loads the image and then calls the same baseline script.
It checks that the cache benefits the optical methods outside the
package's own workload entry point. The total printed by `baseline.jl`
covers configuration verification, graph preparation, allocation and
warmup, following package imports. The phase lines break out the
preparation and warmup portions. The script neither models nor measures
a managed owner's native bootstrap, connection, or RTC admission.

## Results

Julia 1.13.3, two default threads, one OpenBLAS thread, AOS 0.3.23,
HIL 0.5.2, RTC 0.7.9, and FilterGraphPipeWire 0.5.5. Baselines used
the existing dependency caches. The image builds and test processes
used a separate writable depot above those caches. Both CPU
configurations passed the warmup reset check. These are single-run
measurements on the shared workstation.

| Workload | Dependency caches | With workload image | Image import | Native image |
| --- | ---: | ---: | ---: | ---: |
| CAL2 external pupil | 308.5 s | 151.4 s | 1.7 s | 70 MiB |
| SPIDERS fitted dual | 211.5 s | 125.8 s | 3.9 s | 83 MiB |

CAL2 optical preparation went from 152.1 s to 50.1 s, and warmup from
108.1 s to 93.6 s. The CAL2 image built in 199.6 s. SPIDERS preparation
went from 152.5 s to 101.7 s, and warmup from 31.5 s to 22.6 s.
The total workload includes configuration verification and allocation
between these timed phases.

The separate CAL2 compiler trace attributed approximately 30.6 s to the
specialized `ExternalPupil.warmup!` call after the image loaded. Its
arguments include the prepared external-pupil execution type and the
cancellation callback type. Compare the specialization in image creation
with the one loaded by the managed owner before adding more workloads.
The trace timings include instrumentation and are separate from the table.

## Installed CPU profiles

The session installer builds an image for each managed CPU optical owner
that has a supported optical configuration and workload dependencies.
The installed application retains the per-owner package and cache under
`optical-startup/<role>`. The owner loads it after establishing its
bootstrap connection. Offline image creation and the owner share the HIL
preparation and warmup function, including the type used to check for
cancellation. The offline callback has no connection to PipeWire.

Installation builds the image once for that installation. Starting the
installed systemd service reuses it. The convenience API
`SessionRuntime.start!` installs into a fresh directory before it starts
the service, so its elapsed time includes the installation and image
build. A new installation builds a new image for its manifest and
optical configuration. Accelerator, lockstep, and pupil-source modes
follow their usual startup paths.


### Fresh private RTC launches

Installed source candidates were RTC `6fb6c25` and HIL `a46dcb8` with
AOS 0.3.23, FilterGraphPipeWire 0.5.5, PipeWireAO 4.0.2 and Julia 1.13.3.
The standalone CAL2 and fitted-dual SPIDERS CPU profiles were run
sequentially with the same placement as their earlier registered runs.
The CAL2 profile is the standalone optical and controller deployment.
The prior 9:25 CAL2 measurement included a separate upstream test plant.

| CPU profile | Earlier time to Ready | Fresh time to Ready | One-time image build | Image |
| --- | ---: | ---: | ---: | ---: |
| Standalone CAL2 | 439.7 s | 252.2 s | 224.3 s | 70 MiB |
| Fitted-dual SPIDERS | 508.1 s | 228.6 s | 288.7 s | 83 MiB |

Ready time runs from systemd start to service activation, following
installation. Earlier times are separate archived runs of the same
profiles, with the prior registered code and no optical startup image.
Full installation took 262.3 s for CAL2 and 329.3 s for SPIDERS,
including their image builds.

Both fresh native simulator processes mapped their installed package
image, verified using the process memory maps. CAL2 optical preparation
and warmup took 51.1 and 78.0 s. SPIDERS took 99.7 and 21.7 s. The
remaining SPIDERS controller preparation and warmup overlapped the
optical work and finished later.

Each session passed a fresh native Ready check, Start, and a fresh
Running check. CAL2 acknowledged native Quit. The SPIDERS stop attempt
failed after the RTC reported a required object's serial had changed.
The private cohort stopped and its ledger confirmed cleanup and unit
removal. GPI2 stayed stopped. The focused session runtime, installed
session and owner entrypoint suites passed 273 assertions.
