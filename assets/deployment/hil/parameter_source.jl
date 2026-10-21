#!/usr/bin/env julia
# Ordinary sparse parameter owner; RTC owns session links and policy.
using PipeWireAORTC: NativeParameterSource

abspath(PROGRAM_FILE) == abspath(@__FILE__) && NativeParameterSource.main(ARGS)
