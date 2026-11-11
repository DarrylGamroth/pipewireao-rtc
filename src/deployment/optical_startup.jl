"""Build and load the CPU optical preparation workload for an installed owner."""
module OpticalStartup

using TOML, UUIDs
import ..Common
import ..DeploymentConfiguration as D

const NAME = "PipeWireAOOpticalStartup"
const MANAGED_ENTRY =
    "include(joinpath(dirname(Base.find_package(\"AdaptiveOpticsSimPipeWireHIL\")), \"managed.jl\"))"

directory(package, role) = joinpath(package, "optical-startup", role)

function configuration(package, owner)
    argv = owner["argv"]
    MANAGED_ENTRY in argv || return nothing
    index = findfirst(==("--config"), argv)
    index !== nothing && index < length(argv) || return nothing
    config = argv[index + 1]
    startswith(config, "@PACKAGE@/") || return nothing
    path = D.relative_asset(package, String(chopprefix(config, "@PACKAGE@/")))
    document = Common.read_json(path)
    get(document, "backend", nothing) == "cpu" &&
        get(document, "version", nothing) in (4, 6) || return nothing
    return path
end

function build!(package, environment, owner, config, prefix)
    path = directory(package, owner["role"])
    manifest = joinpath(environment, "Manifest.toml")
    if !haskey(TOML.parsefile(manifest)["deps"], "PrecompileTools")
        @info "Optical startup image unavailable in the installed environment" owner=owner["role"]
        return nothing
    end
    !(ispath(path) || islink(path)) || throw(ArgumentError("optical startup directory must be new"))
    mkpath(joinpath(path, "src"))
    project = TOML.parsefile(joinpath(environment, "Project.toml"))
    project["name"] = NAME
    project["uuid"] = string(uuid4())
    project["version"] = "0.1.0"
    project["deps"]["PrecompileTools"] = "aea7be01-6a6a-4083-8856-8a6e6704d82a"
    open(io -> TOML.print(io, project; sorted = true), joinpath(path, "Project.toml"), "w")
    cp(manifest, joinpath(path, "Manifest.toml"))
    optics_import = haskey(project["deps"], "Proper") ? "using Proper" : ""
    write(
        joinpath(path, "src", NAME * ".jl"),
        """
        module $NAME
        using PipeWireAORTC, AdaptiveOpticsSimPipeWireHIL
        $optics_import
        using PrecompileTools: @compile_workload
        const Simulation = AdaptiveOpticsSimPipeWireHIL.Simulation
        if isdefined(Simulation, :prepare_optical_startup)
            @compile_workload begin
                Simulation.prepare_optical_startup($(repr(config)))
            end
        end
        end
        """,
    )
    argv = owner["argv"]
    julia = D.selected_julia_executable(first(argv))
    threads = filter(arg -> startswith(arg, "--threads="), argv)
    depot = joinpath(path, "depot")
    env = copy(ENV)
    merge!(env, owner["environment"])
    env["JULIA_DEPOT_PATH"] = join([depot; DEPOT_PATH], ':')
    env["JULIA_LOAD_PATH"] = "@:@stdlib"
    env["PIPEWIREAO_PREFIX"] = prefix
    code = "using PipeWireAOOpticalStartup; if isdefined(PipeWireAOOpticalStartup.Simulation, :prepare_optical_startup); touch(only(ARGS)); end"
    build = Cmd([julia, "--startup-file=no", threads..., "--project=" * path,
        "-e", code, joinpath(path, "ready")])
    Common.startup_phase(owner["role"], "build optical startup image") do
        run(setenv(build, env))
    end
    isfile(joinpath(path, "ready")) || rm(path; recursive = true)
    return nothing
end

function configure_owner!(argv, env, package, owner)
    path = directory(package, owner["role"])
    isfile(joinpath(path, "ready")) || return nothing
    # Reuse the installation's image without building a new one during launch.
    insert!(argv, 2, "--compiled-modules=existing")
    insert!(argv, 3, "--pkgimages=existing")
    env["PIPEWIREAO_OPTICAL_STARTUP"] = path
    env["JULIA_LOAD_PATH"] = "@:" * path * ":@stdlib"
    env["JULIA_DEPOT_PATH"] = joinpath(path, "depot") * ":" * env["JULIA_DEPOT_PATH"]
    return nothing
end

end
