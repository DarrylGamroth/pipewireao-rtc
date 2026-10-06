using PipeWireAODeployment
const C=PipeWireAODeployment.Common
const D=PipeWireAODeployment.Deployment
const H=PipeWireAODeployment.HILExport
const S=PipeWireAODeployment.ScienceExport
source,output,mode=ARGS
mode in ("disabled","enabled") || error("select disabled or enabled")
source=realpath(source);output=abspath(output)
!ispath(output) && !islink(output) || error("fresh output required")
spec=D.profile(joinpath(source,"deployment.conf"),"/opt/pipewireao")
p=C.read_json(joinpath(source,"provenance.json"))
p["hil"]["backend"]=="cuda" || error("frozen source must use CUDA AOS")
p["engine"] in ("fgn","jfg") || error("CPU FGN/JFG reference required")
!get(spec,"detector-observation",false) || error("reference already observes")
for (path,hash) in spec["artifacts"]
    C.sha256_file(joinpath(source,path))==hash || error("source seal changed: $path")
end
cp(source,output)
isdir(joinpath(output,"systemd")) && rm(joinpath(output,"systemd");recursive=true)
owner=only(filter(o->o["role"]==spec["source-owner"],spec["owners"]))
function set_argument!(argv,key,value)
    positions=findall(==(key),argv)
    length(positions)==1 && only(positions)<length(argv) || error("missing/duplicate $key")
    argv[only(positions)+1]=value
end
set_argument!(owner["argv"],"--frames","256")
set_argument!(owner["argv"],"--total-exchanges","256")
set_argument!(owner["argv"],"--wall-rate","10")
if mode=="enabled"
    append!(owner["argv"],["--detector-observation","true"])
    spec["detector-observation"]=true
    core=D.decode(joinpath(output,spec["core"]),"/opt/pipewireao")
    loops=core["context.properties"]["context.data-loops"]
    length(loops)==1 && only(loops)["loop.name"]=="rtc-data-loop" || error("unexpected core loops")
    # Reuse the maintained export recipe for the optional observation loop and
    # queue. Existing science nodes/modules and the required loop are retained.
    recipe=H.hil_core(Dict("context.properties"=>Dict("context.data-loops"=>[
        Dict("loop.name"=>"rtc-data-loop"),Dict("loop.name"=>"source-loop"),Dict("loop.name"=>"sink-loop")]),
        "context.modules"=>Any[]);detector_observation=true)
    only(loops)["loop.class"]=recipe["context.properties"]["context.data-loops"][1]["loop.class"]
    push!(loops,recipe["context.properties"]["context.data-loops"][2])
    append!(core["context.modules"],recipe["context.modules"])
    S.write_spa_config(joinpath(output,spec["core"]),core)
    push!(spec["placement"]["core"]["threads"],Dict("cpus"=>[14],"policy"=>"fifo","priority"=>83,"count"=>1,"name"=>"observer-loop"))
    p["hil"]["detector_observation"]="raw transported ADC behind capacity-one copy/drop-oldest queue; optional observer"
end
p["hil"]["frames"]=256;p["hil"]["total_exchanges"]=256
p["hil"]["wall_rate"]="10";p["hil"]["wall_rate_hz"]=10
protected=Dict(path=>hash for (path,hash) in spec["artifacts"] if
    !startswith(path,"systemd/") && path!="provenance.json" && (mode=="disabled" || path!=spec["core"]))
for (path,hash) in protected
    C.sha256_file(joinpath(output,path))==hash || error("protected byte changed: $path")
end
p["native_gui_observation_cohort"]=Dict("source"=>source,
    "source_descriptor_sha256"=>C.sha256_file(joinpath(source,"deployment.conf")),
    "helper_sha256"=>C.sha256_file(@__FILE__),"protected_files"=>protected,
    "scope"=>"frozen CUDA AOS/CPU RTC scientific bytes; complete256 recordings at10Hz wall pacing; optional maintained observer queue only")
C.write_json(joinpath(output,"provenance.json"),p)
# Both variants retain the same human label; UUID/incarnation remain runtime
# owner identities. The separate duplicate-name fixture can match this label.
spec["name"]="revolt-$(p["profile"])-$(p["engine"])-hil-cuda"
spec["artifacts"]=H._package_artifacts(output)
C.write_json(joinpath(output,"deployment.conf"),spec)
D.profile(joinpath(output,"deployment.conf"),"/opt/pipewireao")
installed=output*"-installed"
D.install((;package=output,destination=installed,pipewire_prefix="/opt/pipewireao"))
final=C.read_json(joinpath(installed,"deployment.conf"))
for (path,hash) in final["artifacts"]
    C.sha256_file(joinpath(installed,path))==hash || error("installed seal changed: $path")
end
C.write_json(output*"-proof.json",Dict("installed"=>installed,"protected_files"=>protected,
    "installed_descriptor_sha256"=>C.sha256_file(joinpath(installed,"deployment.conf")),
    "scope"=>"cold preparation only; no science admission or observation qualification"))
println(installed)
