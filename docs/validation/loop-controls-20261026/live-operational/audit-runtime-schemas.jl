using PipeWireAORTC, AdaptiveOpticsSimPipeWireHIL, PipeWireAO
const C=PipeWireAORTC.Common
const D=PipeWireAORTC.DeploymentConfiguration
const H=AdaptiveOpticsSimPipeWireHIL
const root="/home/dgamroth/.local/state/pipewireao/gpi2-loop-controls-live-20261026"
const application=joinpath(root,"application")
const prefix=ENV["PIPEWIREAO_PREFIX"]
const declarations=C.read_yaml(joinpath(pkgdir(PipeWireAORTC),"data/schemas.yaml"))
const known=Set(entry["id"] for entry in values(declarations))
const observed=Set{String}()
function audit(value::AbstractString)
 if startswith(value,"pipewireao/")
  value in known || error("Undeclared scientific schema: $value")
  push!(observed,value)
 end
 occursin("org.calculon",value) && error("Legacy schema in active application: $value")
 nothing
end
audit(value::AbstractDict)=foreach(audit,values(value))
audit(value::AbstractVector)=foreach(audit,value)
audit(value)=nothing
files=("simulation.conf","rtc/session.conf.in","rtc/graph.conf","rtc/parameters.conf","instrument.json")
for file in files
 audit(D.decode(joinpath(application,file),prefix))
end
audit(C.read_yaml(joinpath(application,"gui/operator-views.yaml")))
options=PipeWireAORTC.AOSOwner.configuration(joinpath(application,"simulation.conf"))
configuration=H.PipeWireHILConfiguration(remote="schema-audit-no-connection",
 frame_node_name="simulator-wfs",command_node_name=options.command_node,
 frame_schema=options.frame_schema,command_schema=options.command_schema,
 frame_encoding=options.frame_encoding,command_scale=options.command_scale,rate=PipeWireAO.SPA.Fraction(UInt32(options.rate),UInt32(1)),
 exposure_duration_ns=options.exposure_ns)
commands=map(count -> zeros(Float32,count),options.command_count)
contracts=H._applied_command_contracts(configuration,commands)
session=D.decode(joinpath(application,"rtc/session.conf.in"),prefix)
result=Dict{String,Any}()
for name in keys(contracts)
 source_name=options.command_node[name]*"-applied"
 source=only(filter(entry -> entry["node.name"]==source_name,session["sources"]))
 port=only(source["ports"])
 @assert port["schema"]==contracts[name].schema
 @assert Tuple(port["shape"])==size(commands[name])
 @assert port["element-type"]=="F32_LE"
 result[String(name)]=Dict("schema"=>contracts[name].schema,"units"=>String(contracts[name].units),
  "shape"=>collect(size(commands[name])),"command_divisor_m"=>contracts[name].command_scale)
end
@assert !isempty(observed)
C.write_json(joinpath(root,"schema-audit.json"),Dict("completed"=>true,
 "files"=>collect(files),"scientific_schemas"=>sort!(collect(observed)),"applied"=>result,
 "scope"=>"Cold declared-schema and selected HIL publisher-contract comparison; no native connection or GPU"))
println("Schema audit passed: ",length(observed)," canonical scientific identifiers; all Applied contracts match RTC ports")
