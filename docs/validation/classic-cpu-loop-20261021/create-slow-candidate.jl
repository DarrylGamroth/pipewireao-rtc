using PipeWireAORTC
const C=PipeWireAORTC.Common
source=joinpath(@__DIR__,"application-closed-loop")
destination=joinpath(@__DIR__,"application-closed-loop-wall1")
ispath(destination) && error("destination must be fresh")
cp(source,destination)
simulation=C.read_json(joinpath(destination,"simulation.conf"))
simulation["wall_rate"]=1
C.write_json(joinpath(destination,"simulation.conf"),simulation)
spec=C.read_json(joinpath(destination,"deployment.conf"))
spec["name"]="classic-cpu-loop-20261021"
spec["artifacts"]["simulation.conf"]=C.sha256_file(joinpath(destination,"simulation.conf"))
C.write_json(joinpath(destination,"deployment.conf"),spec)
@assert all(C.sha256_file(joinpath(destination,path))==hash for (path,hash) in spec["artifacts"])
C.write_json(joinpath(@__DIR__,"application-closed-loop-wall1-provenance.json"),Dict(
    "source"=>source,"candidate"=>destination,"backend"=>"cpu",
    "model_rate_hz"=>500,"wall_rate_hz"=>1,"frames"=>256,
    "manifest_sha256"=>C.sha256_file(joinpath(destination,"Manifest.toml")),
    "artifacts"=>spec["artifacts"],"deployment_sha256"=>C.sha256_file(joinpath(destination,"deployment.conf"))))
