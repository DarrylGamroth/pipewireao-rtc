using PipeWireAORTC,SHA
const V=(PipeWireAORTC=PipeWireAORTC,IC=PipeWireAORTC.InstrumentConfiguration)
const C=PipeWireAORTC.Common
include("resource-path-resolver.jl")
workaround=install_resource_paths!()
cal="/home/dgamroth/.local/state/pipewireao/gpi2-registered-live-20261025/application/calibration"
receipt=C.read_yaml(joinpath(cal,"result.yaml"))
source="/home/dgamroth/.cache/pipewireao/gpi2-validation-20261025/instrument-source-v8/gpi2"
declaration=V.IC.load_simulation(joinpath(source,receipt["recipe"]["simulation"]))
settings=V.IC.settings(declaration,get(receipt["recipe"],"settings",Dict()))
identity=V.IC.prescription_identity(declaration,settings)
@assert identity==receipt["source_prescription_identity"]
C.write_json(joinpath(@__DIR__,"resource-preflight.json"),Dict("passed"=>true,"source_prescription_identity"=>identity,"original_receipt_source_identity"=>receipt["source_prescription_identity"],"resource_workaround"=>workaround))
println("Resource path workaround preserves frozen source prescription identity: ",identity)
