# CPU science checks

This project runs RTC's optional science extensions with registered CPU-only
dependencies. Use Julia 1.13.4 and a Linux host supported by the PipeWireAO
artifact. The HIL package uses a system C compiler to build its command
receiver. The manifest locks the dependency trees and uses the current RTC
checkout as its package source.
It requires authenticated Git access to `AdaptiveOpticsCalibration.jl`,
`AdaptiveOpticsSimPipeWireHIL.jl`, and `JuliaFilterGraph.jl`. These repositories
must be accessible when instantiating the full project.
AdaptiveOpticsSim also depends on AdaptiveOpticsCalibration for the
optics-only checks.

Add General and [DarrylGamrothRegistry](https://github.com/DarrylGamroth/PackageRegistry)
to the Julia depot if they are absent, then instantiate the project from the
RTC repository root.

```sh
julia --startup-file=no -e '
using Pkg
Pkg.Registry.add("General")
Pkg.Registry.add(RegistrySpec(url="https://github.com/DarrylGamroth/PackageRegistry.git"))'
JULIA_PKG_USE_CLI_GIT=true JULIA_LOAD_PATH='@:@stdlib' julia --startup-file=no --project=test/science \
  -e 'using Pkg; Pkg.instantiate()'
```

Use separate processes for cold preparation and the private-core test groups.
The selectors bind their temporary daemons to the registered PipeWireAO
artifact used by the Julia client.

```sh
export JULIA_LOAD_PATH='@:@stdlib'
export OPENBLAS_NUM_THREADS=1
julia --startup-file=no --project=test/science --threads=4,0 test/science/runtests.jl cold
julia --startup-file=no --project=test/science --threads=4,1 test/science/runtests.jl private_core
julia --startup-file=no --project=test/science --threads=3,0 test/science/runtests.jl retained_owner
julia --startup-file=no --project=test/science --threads=3,0 test/science/runtests.jl physical_offset_inputs
julia --startup-file=no --project=test/science --threads=4,0 test/science/runtests.jl physical_offsets
```

For RTC coverage, add
`--code-coverage=@ --code-coverage=/absolute/path/to/selection-%p.info`
before the script in each command. Use a separate trace name per selection.
The process ID separates results from the test process and its Julia children. The private cores exercise software transport and lifecycle on
disposable sockets. Installed-session, instrument-data, timing, and hardware
qualification use the [integration checks](../integration/README.md) and
instrument-specific procedures.
