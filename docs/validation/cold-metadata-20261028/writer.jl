# Run only on a disposable copy of the built application. prepare_publication
# regenerates its declared output; all source/frozen application inputs are read-only.
using PipeWireAORTC
const IC = PipeWireAORTC.InstrumentConfiguration
const ID = PipeWireAORTC.InstrumentDefinition
const C = PipeWireAORTC.Common

application = abspath(ARGS[1])
configuration = "rtc/cal2-testplant/configuration.yaml"
publication_path = joinpath(application, "instrument.json")
frozen = read(publication_path, String)
expected_hash = "0e12b61a9353da16967c108bd54d2c9bfa75326cd64518b7b9a656e7e09cea37"
@assert C.sha256_file(publication_path) == expected_hash
println("julia=", VERSION, " package=", pathof(PipeWireAORTC))
flush(stdout)
timing = @timed IC.publication(joinpath(application, configuration))
println("publication_seconds=", timing.time, " compile_seconds=", timing.compile_time)
@assert C.metadata_json(timing.value) * "\n" == frozen
@assert IC.json_value(timing.value) == C.parse_json(frozen)
println("ordered_publication_bytes_equal=true scientific_identity=", timing.value.scientific_identity)
flush(stdout)
@assert IC.prepare_publication(application; configuration) == publication_path
@assert read(publication_path, String) == frozen
@assert C.sha256_file(publication_path) == expected_hash
println("regenerated_publication_bytes_equal=true sha256=", expected_hash)

accepted_root = joinpath(application, "generated", "physical-offset-calibration")
accepted_path = joinpath(accepted_root, "instrument.json")
accepted_before = read(accepted_path, String)
accepted = IC.publication(joinpath(accepted_root, "rtc.yaml"))
selected = IC.json_value(accepted)
@assert selected == C.parse_json(accepted_before)
# The accepted materializer writes parsed JSON objects, whose keys JSON sorts.
@assert IC.JSON.json(selected) * "\n" == accepted_before
@assert selected["scientific_identity"] == timing.value.scientific_identity
println("accepted_publication_bytes_equal=true sha256=", C.sha256_file(accepted_path))
@assert all(id -> id.name ∉ ("AdaptiveOpticsSim", "AdaptiveOpticsSimPipeWireHIL", "CUDA", "AMDGPU", "Proper"), keys(Base.loaded_modules))
println("optional_science_imported=false")
