#!/usr/bin/env julia
# Ordinary sparse parameter owner; RTC owns session links and policy.
using PipeWireAORTC: ParameterSource

abspath(PROGRAM_FILE) == abspath(@__FILE__) && ParameterSource.main(ARGS)
