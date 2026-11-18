using FilterGraphPipeWire
using PipeWireAORTC

const RTC = PipeWireAORTC
const E = RTC.InstrumentExport
const C = RTC.Common

function stage(source, app, bundles, prefix)
    E.seal!(app)
    selection = "generated/dual-calibration"
    rm(joinpath(source, selection); recursive = true, force = true)
    E.materialize_calibration(source, app, bundles; prefix,
        graphs = Dict("llowfs" => "rtc/llowfs-branch.conf", "scc" => "rtc/scc-branch.conf"),
        provenance = "generated/fitted-exposure/receipt.yaml",
        destination = selection, rtc_configuration = "rtc/configuration-dual.yaml",
        recipe = "calibration/optical-dark-hole.yaml", zero_command = "dm-native-zero.fits")
    path = joinpath(source, "rtc/dual-parameters.yaml")
    bindings = C.read_yaml(path)
    parameters = Dict(entry["port"] => entry for entry in bindings["parameters"])
    @assert !haskey(parameters, "system-flat")
    parameters["scc-reconstructor"]["path"] = "../calibration/acquisition-reconstructor.fits"
    parameters["scc-reference-difference"]["path"] = "../calibration/acquisition-reference.fits"
    C.write_yaml(path, bindings; atomic = true)
end
stage(ARGS...)
