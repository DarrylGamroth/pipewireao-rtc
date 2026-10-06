using PipeWireAODeployment,TOML
const C=PipeWireAODeployment.Common
const S=PipeWireAODeployment.ScienceExport
const H=PipeWireAODeployment.HILExport
const D=PipeWireAODeployment.Deployment
source,output,fits,label,sdk,runner=ARGS
source=realpath(source);output=abspath(output)
!ispath(output) && !islink(output) || error("fresh output required")
spec=D.profile(joinpath(source,"deployment.conf"),"/opt/pipewireao";legacy_export_input=true)
isempty(spec["owners"]) && !haskey(spec,"source-owner") || error("recorded fixture only")
for (path,hash) in spec["artifacts"]
    C.sha256_file(joinpath(source,path))==hash || error("original seal changed: $path")
end
cp(source,output)
S.copy_deployment_runtime(output)
cp(runner,joinpath(output,"bin/pipewireao-rtc");force=true)
H.copy_package(realpath(sdk),joinpath(output,"sdk/PipeWireAO"))
manifest=TOML.parsefile(joinpath(output,"julia/Manifest.toml"))
dependency=only(manifest["deps"]["PipeWireAO"])
for key in ("git-tree-sha1","repo-url","repo-rev");pop!(dependency,key,nothing);end
dependency["path"]="../sdk/PipeWireAO"
open(io->TOML.print(io,manifest;sorted=true),joinpath(output,"julia/Manifest.toml"),"w")
S.copy_file(realpath(fits),joinpath(output,"input.fits"))
protected=Dict(path=>hash for (path,hash) in spec["artifacts"] if
    !startswith(path,"julia/") && !startswith(path,"systemd/") && path!="bin/pipewireao-rtc" && path!="provenance.json")
for (path,hash) in protected
    C.sha256_file(joinpath(output,path))==hash || error("original scientific byte changed: $path")
end
p=C.read_json(joinpath(output,"provenance.json"))
p["gui_recorded_control_fixture"]=Dict("source"=>source,"source_descriptor_sha256"=>C.sha256_file(joinpath(source,"deployment.conf")),
    "helper_sha256"=>C.sha256_file(@__FILE__),"protected_files"=>protected,
    "fits_sha256"=>C.sha256_file(joinpath(output,"input.fits")),
    "scope"=>"recorded non-actuating Copper algorithm controls/discovery fixture; human label deliberately matches primary, no AO algorithm equivalence or cadence claim")
C.write_json(joinpath(output,"provenance.json"),p)
spec["name"]=label;spec["artifacts"]=H._package_artifacts(output)
C.write_json(joinpath(output,"deployment.conf"),spec)
D.profile(joinpath(output,"deployment.conf"),"/opt/pipewireao")
installed=output*"-installed"
D.install((;package=output,destination=installed,pipewire_prefix="/opt/pipewireao"))
println(installed)
