#!/usr/bin/env julia
# Operational entry point; reusable implementation is owned by the package.
using PipeWireAORTC: SessionCLI

abspath(PROGRAM_FILE) == abspath(@__FILE__) && exit(SessionCLI.main(ARGS))
