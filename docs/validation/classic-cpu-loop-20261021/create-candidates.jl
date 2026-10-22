using PipeWireAORTC, TOML
const C = PipeWireAORTC.Common
source = "/home/dgamroth/workspaces/codex/pipewire/revolt-classic-rtc"
for (name, finite) in (("application-fault", false), ("application-closed-loop", true))
    destination = joinpath(@__DIR__, name)
    ispath(destination) && error("candidate must be fresh")
    cp(source, destination)
    simulation = C.read_json(joinpath(destination,"simulation.conf"))
    simulation["backend"] = "cpu"
    simulation["wall_rate"] = 10
    finite && (simulation["total_exchanges"] = 256)
    C.write_json(joinpath(destination,"simulation.conf"), simulation)
    spec = C.read_json(joinpath(destination,"deployment.conf"))
    spec["name"] = "classic-cpu-validation-20261021-" * (finite ? "closed" : "fault")
    spec["environment"]["CUDA_VISIBLE_DEVICES"] = ""
    spec["environment"]["ROCR_VISIBLE_DEVICES"] = ""
    for owner in spec["owners"]
        env = get!(owner,"environment",Dict{String,Any}())
        env["CUDA_VISIBLE_DEVICES"] = ""
        env["ROCR_VISIBLE_DEVICES"] = ""
        if owner["role"] == "simulator"
            argv = owner["argv"]
            argv[findfirst(==("--phase-timing-frames"),argv)+1] = "256"
            argv[findfirst(==("--phase-timing-warmup"),argv)+1] = "0"
        end
    end
    for relative in keys(spec["artifacts"])
        spec["artifacts"][relative] = C.sha256_file(joinpath(destination,relative))
    end
    C.write_json(joinpath(destination,"deployment.conf"),spec)
    original = C.read_json(joinpath(source,"deployment.conf"))
    changed = sort([path for path in keys(original["artifacts"])
        if original["artifacts"][path] != spec["artifacts"][path]])
    @assert changed == ["simulation.conf"]
    @assert TOML.parsefile(joinpath(destination,"Manifest.toml")) == TOML.parsefile(joinpath(source,"Manifest.toml"))
    C.write_json(joinpath(@__DIR__,name*"-provenance.json"),Dict("source"=>source,
        "source_commit"=>readchomp(`git -C $source rev-parse HEAD`),"candidate"=>destination,
        "backend"=>"cpu","model_rate_hz"=>500,"wall_rate_hz"=>10,
        "finite"=>finite,"changed_scientific_assets"=>changed,
        "manifest_unchanged"=>true,"artifacts"=>spec["artifacts"],
        "deployment_sha256"=>C.sha256_file(joinpath(destination,"deployment.conf"))))
    println(destination)
end
