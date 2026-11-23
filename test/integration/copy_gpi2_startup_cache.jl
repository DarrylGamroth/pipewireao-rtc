# Trace and copy the exact Julia package-image dependency closure without editing its inputs.
function cache_record(path)
    open(path) do io
        checksum = Base.isvalid_cache_header(io)
        iszero(checksum) && return nothing
        modules, _, required, _, _, _, flags = Base.parse_cache_header(io, path)
        pkg, id = first(modules)
        build = (UInt128(checksum) << 64) | (id % UInt64)
        return (; path, pkg, build, required, native = Base.CacheFlags(flags).use_pkgimages)
    end
end

function copy_cache(record, destination)
    subdir = joinpath(destination, "compiled", "v$(VERSION.major).$(VERSION.minor)", record.pkg.name)
    mkpath(subdir)
    if record.native
        native = Base.ocachefile_from_cachefile(record.path)
        isfile(native) || error("Missing native object cache $native")
        cp(native, joinpath(subdir, basename(native)); force = true)
    end
    cp(record.path, joinpath(subdir, basename(record.path)); force = true)
    return nothing
end

function main(cache, destination, installed_depot, user_depot)
    ispath(destination) && error("Use a fresh destination")
    mkpath(destination)
    for entry in ("packages", "artifacts", "juliaup")
        source = joinpath(user_depot, entry)
        entry == "juliaup" && !isdir(source) && continue
        symlink(source, joinpath(destination, entry); dir_target = true)
    end
    source_depots = [installed_depot, user_depot, dirname(dirname(Sys.STDLIB))]
    image = something(cache_record(cache))
    copy_cache(image, destination)
    missing = Pair{Base.PkgId,UInt128}[]
    for (pkg, build) in image.required
        if haskey(Base.loaded_modules, pkg) && Base.module_build_id(Base.loaded_modules[pkg]) == build
            continue
        end
        matching = nothing
        for path in Base.find_all_in_cache_path(pkg, source_depots)
            info = cache_record(path)
            info === nothing && continue
            if info.pkg == pkg && info.build == build
                matching = info
                break
            end
        end
        if matching === nothing
            push!(missing, pkg => build)
            continue
        end
        if !startswith(matching.path, source_depots[end] * "/")
            copy_cache(matching, destination)
        end
        println(pkg.name, " ", string(build; base = 16), " ", matching.path)
    end
    for (pkg, build) in missing
        println("MISSING ", pkg.name, " ", string(build; base = 16))
    end
    isempty(missing) || error("Unable to locate $(length(missing)) exact cache dependencies")
    return nothing
end

length(ARGS) == 4 || error(
    "usage: copy_gpi2_startup_cache.jl STARTUP_CACHE FRESH_DEPOT IMAGE_DEPOT SOURCE_DEPOT"
)
main(ARGS...)
