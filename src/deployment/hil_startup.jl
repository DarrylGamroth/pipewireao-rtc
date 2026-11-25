# Resolve the optional lightweight HIL deployment interface from the application
# Manifest. Loading HIL here would also load the scientific packages.
module HILStartup

using UUIDs: UUID

const HIL = Base.PkgId(UUID("355e2bce-7765-4934-ac1c-873e1c98ec3d"), "AdaptiveOpticsSimPipeWireHIL")

function interface(environment)
    entry = Base.explicit_manifest_uuid_path(joinpath(environment, "Project.toml"), HIL)
    (entry === nothing || entry === missing) && return nothing
    path = normpath(dirname(entry), "..", "ext", "PipeWireAORTCExt", "startup_image.jl")
    isfile(path) || return nothing
    return Base.include(Module(:HILDeployment), path)
end

function requested(environment, package, owners)
    api = interface(environment)
    api === nothing && return false
    return Base.invokelatest(() -> api.requested(package, owners))
end

function install!(environment, package, owners, prefix)
    api = interface(environment)
    api === nothing && return nothing
    return Base.invokelatest(() -> api.install!(environment, package, owners, prefix))
end

configure_owner!(::Nothing, argv, env, package, owner) = nothing
function configure_owner!(api::Module, argv, env, package, owner)
    return Base.invokelatest(() -> api.configure_owner!(argv, env, package, owner))
end

end
