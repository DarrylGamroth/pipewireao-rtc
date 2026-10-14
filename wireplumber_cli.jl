#!/usr/bin/env julia
# Compatibility entry point; reusable implementation is owned by the package.
using PipeWireAORTC: WirePlumberCLI

abspath(PROGRAM_FILE) == abspath(@__FILE__) && exit(WirePlumberCLI.main(ARGS))
