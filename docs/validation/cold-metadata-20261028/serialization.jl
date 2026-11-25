# CPU-only physical-metadata serializer measurement, without graph preparation.
using PipeWireAORTC
const IC = PipeWireAORTC.InstrumentConfiguration
println("julia=", VERSION, " package=", pathof(PipeWireAORTC))
physical = IC.physical_definition(IC.load(abspath(ARGS[1])))
println("physical_loaded=true")
flush(stdout)
first_call = @timed IC.json_value(physical)
println("serialization_seconds=", first_call.time, " bytes=", first_call.bytes,
    " compile_seconds=", first_call.compile_time)
flush(stdout)
warmed = @timed IC.json_value(physical)
@assert first_call.value == warmed.value
println("warmed_serialization_seconds=", warmed.time, " bytes=", warmed.bytes)
@assert all(id -> id.name ∉ ("AdaptiveOpticsSim", "AdaptiveOpticsSimPipeWireHIL", "CUDA", "AMDGPU", "Proper"), keys(Base.loaded_modules))
