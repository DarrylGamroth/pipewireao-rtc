# CPU-only cold publication measurement; no optional science imports or cores.
using PipeWireAORTC
const IC = PipeWireAORTC.InstrumentConfiguration
const ID = PipeWireAORTC.InstrumentDefinition
const C = PipeWireAORTC.Common

println("julia=", VERSION, " package=", pathof(PipeWireAORTC))
flush(stdout)
configuration = abspath(ARGS[1])
first_call = @timed IC.publication(configuration)
println("publication_seconds=", first_call.time, " bytes=", first_call.bytes,
    " compile_seconds=", first_call.compile_time)
flush(stdout)
selected = IC.json_value(first_call.value)
println("scientific_identity=", selected["scientific_identity"])
if get(ENV, "PIPEWIREAORTC_COMPARE_LEGACY_JSON", "0") == "1"
    @assert C.metadata_json(first_call.value) == IC.JSON.json(first_call.value)
    println("legacy_publication_bytes_equal=true")
end
if length(ARGS) > 1
    frozen_path = abspath(ARGS[2])
    frozen_bytes = strip(read(frozen_path, String))
    frozen = C.parse_json(frozen_bytes)
    @assert selected == frozen
    # The frozen publication includes the scientific hash of the original
    # ordered declaration, as well as every scalar and array entry.
    println("frozen_publication_equal=true sha256=", C.sha256_file(frozen_path))
end
warmed = @timed IC.publication(configuration)
@assert selected == IC.json_value(warmed.value)
println("warmed_publication_seconds=", warmed.time, " bytes=", warmed.bytes)
@assert all(id -> id.name ∉ ("AdaptiveOpticsSim", "AdaptiveOpticsSimPipeWireHIL", "CUDA", "AMDGPU", "Proper"), keys(Base.loaded_modules))
println("optional_science_imported=false")
