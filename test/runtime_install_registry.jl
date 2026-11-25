# Run the registered installation selector using the checked-out Git tree and
# the instantiated workspace's dependency trees in a disposable Julia depot.
using Pkg, TOML, UUIDs
import PipeWireAO

function write_toml(path, document)
    open(path, "w") do io
        TOML.print(io, document; sorted = true)
    end
end

function install_registries(depot, manifest, package, snapshot, tree)
    registry_dir = mkpath(joinpath(depot, "registries"))
    package_uuid = UUID(package["uuid"])
    reachable = Pkg.Registry.reachable_registries()
    package_registry = first(r for r in reachable if r.name == "DarrylGamrothRegistry")
    for (name, declaration) in manifest["registries"]
        registry = first(r for r in reachable if r.uuid == UUID(declaration["uuid"]))
        if isdir(registry.path)
            # Pkg must never update the original registry or its Git metadata.
            destination = mkdir(joinpath(registry_dir, name))
            for entry in readdir(registry.path)
                entry == ".git" && continue
                cp(joinpath(registry.path, entry), joinpath(destination, entry))
            end
        else
            archive = basename(TOML.parsefile(registry.path)["path"])
            cp(registry.path, joinpath(registry_dir, basename(registry.path)))
            cp(joinpath(dirname(registry.path), archive), joinpath(registry_dir, archive))
        end
    end

    # Replace the entry in the private copy, so an already registered release
    # with this version cannot silently select a different tree.
    entry = joinpath(
        registry_dir, package_registry.name, package_registry[package_uuid].path
    )
    version = package["version"]
    write_toml(
        joinpath(entry, "Package.toml"),
        Dict("name" => package["name"], "uuid" => package["uuid"], "repo" => snapshot),
    )
    write_toml(
        joinpath(entry, "Versions.toml"), Dict(version => Dict("git-tree-sha1" => tree))
    )
    compat = package["compat"]
    for (kind, file, bounds) in
        (("deps", "Deps", "Compat"), ("weakdeps", "WeakDeps", "WeakCompat"))
        dependencies = get(package, kind, Dict())
        write_toml(joinpath(entry, file * ".toml"), Dict(version => dependencies))
        names =
            kind == "deps" ? [collect(keys(dependencies)); "julia"] :
            collect(keys(dependencies))
        ranges = Dict(
            name => string.(Pkg.Versions.semver_spec(compat[name]).ranges) for
            name in names if haskey(compat, name)
        )
        write_toml(joinpath(entry, bounds * ".toml"), Dict(version => ranges))
    end
    return package_registry.name
end

function copy_locked_sources(depot, manifest, package)
    packages = Dict{String,Any}()
    remaining = [package]
    installed = Pkg.dependencies()
    while !isempty(remaining)
        name = pop!(remaining)
        haskey(packages, name) && continue
        records = manifest["deps"][name]
        record = only(records)
        packages[name] = records
        append!(remaining, get(record, "deps", String[]))
        name == package && continue
        haskey(record, "path") && error("$name is not resolved to a registered tree")
        haskey(record, "git-tree-sha1") || continue # Julia supplies its bundled stdlibs.
        dependency = installed[UUID(record["uuid"])]
        dependency.tree_hash == record["git-tree-sha1"] || error(
            "instantiate the checked-out manifest before running this selector ($name)"
        )
        source = dependency.source
        isfile(joinpath(source, "Project.toml")) ||
            error("instantiate $name before running this selector")
        target = mkpath(joinpath(depot, "packages", name))
        symlink(realpath(source), joinpath(target, basename(source)))
    end
    artifacts = mkpath(joinpath(depot, "artifacts"))
    for source in DEPOT_PATH
        directory = joinpath(source, "artifacts")
        isdir(directory) || continue
        for hash in readdir(directory)
            occursin(r"^[a-f0-9]{40}$", hash) || continue
            artifact = joinpath(directory, hash)
            target = joinpath(artifacts, hash)
            isdir(artifact) && !islink(target) && symlink(realpath(artifact), target)
        end
    end
    manifest["deps"] = packages
    return nothing
end

function write_registered_coverage(output, directory, package, root)
    open(output, "w") do io
        for action in ("export", "install")
            report = joinpath(directory, action * ".info")
            selected = false
            for record in eachline(report)
                if startswith(record, "SF:")
                    source = record[4:end]
                    path = relpath(source, package)
                    selected = startswith(path, "src/") || startswith(path, "ext/")
                    if selected
                        read(source) == read(joinpath(root, path)) ||
                            error("registered source differs from checkout: $path")
                        println(io, "SF:", path)
                    end
                elseif selected
                    println(io, record)
                    record == "end_of_record" && (selected = false)
                end
            end
        end
    end
    filesize(output) > 0 || error("the registered CLI produced no project coverage")
    return nothing
end

function registered_runtime_install(root, report; direct_session = false)
    commit = readchomp(`git -C $root rev-parse HEAD`)
    tree = readchomp(`git -C $root rev-parse $(commit * "^{tree}")`)
    package = TOML.parse(read(`git -C $root show $(commit * ":Project.toml")`, String))
    manifest = TOML.parse(read(`git -C $root show $(commit * ":Manifest.toml")`, String))
    success(`git -C $root diff --quiet $commit -- src ext assets Project.toml`) ||
        error("runtime source and package metadata must match the checked-out commit")
    prefix = get(
        ENV, "PIPEWIREAO_PREFIX", String(PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir)
    )
    mktempdir("/var/tmp"; prefix = "rtc-install-registry-") do scratch
        depot = mkdir(joinpath(scratch, "depot"))
        snapshot = joinpath(scratch, "checkout.git")
        run(`git init --quiet --bare $snapshot`)
        run(`git --git-dir=$snapshot fetch --quiet --depth=1 --no-tags $root $commit`)
        run(`git --git-dir=$snapshot update-ref HEAD FETCH_HEAD`)
        registry = install_registries(depot, manifest, package, snapshot, tree)
        name = package["name"]
        copy_locked_sources(depot, manifest, name)
        record = only(manifest["deps"][name])
        delete!(record, "path")
        record["git-tree-sha1"] = tree
        record["registries"] = registry

        # Fetch the RTC through its registry entry. The test then resolves an
        # empty application against the exact cached dependency trees offline.
        seed = mkdir(joinpath(scratch, "seed"))
        project = Dict(
            "deps" => Dict(name => package["uuid"]),
            "compat" => Dict(name => "=" * package["version"]),
        )
        write_toml(joinpath(seed, "Project.toml"), project)
        manifest["project_hash"] = Pkg.Types.project_resolve_hash(
            Pkg.Types.EnvCache(joinpath(seed, "Project.toml")), VERSION
        )
        write_toml(joinpath(seed, "Manifest.toml"), manifest)
        environment = Dict(
            "JULIA_DEPOT_PATH" => depot,
            "JULIA_LOAD_PATH" => "@:@stdlib",
            "JULIA_PKG_PRECOMPILE_AUTO" => "0",
            "PIPEWIREAO_PREFIX" => prefix,
            "TMPDIR" => "/var/tmp",
        )
        julia = Base.julia_cmd()
        run(
            addenv(
                `$julia --startup-file=no --project=$seed -e 'using Pkg; Pkg.instantiate(update_registry=false)'`,
                environment...,
                "JULIA_PKG_OFFLINE" => "false",
            ),
        )
        println("Testing registered RTC commit $commit (tree $tree)")
        flush(stdout)
        test = joinpath(root, "test", "runtime_install.jl")
        coverage = report === nothing ? nothing : mkdir(joinpath(scratch, "coverage"))
        installed = only(readdir(joinpath(depot, "packages", name); join = true))
        run(
            addenv(
                `$julia --startup-file=no --project=$root $test`,
                environment...,
                "JULIA_PKG_OFFLINE" => "true",
                "PIPEWIREAORTC_INSTALL_MANIFEST" => joinpath(seed, "Manifest.toml"),
                "PIPEWIREAORTC_INSTALL_COVERAGE" => coverage,
                "PIPEWIREAORTC_INSTALL_REGISTERED_SOURCE" => installed,
            ),
        )
        if direct_session
            selector = joinpath(root, "test", "integration", "portable_direct_session.jl")
            run(addenv(`$julia --startup-file=no --project=$root $selector $seed`,
                environment..., "JULIA_PKG_OFFLINE" => "true"))
        end
        report === nothing || write_registered_coverage(report, coverage, installed, root)
    end
    return nothing
end

direct_session = "--direct-session" in ARGS
reports = filter(!=("--direct-session"), ARGS)
length(reports) <= 1 ||
    error("usage: julia --project=. test/runtime_install_registry.jl [--direct-session] [COVERAGE.info]")
registered_runtime_install(dirname(@__DIR__), isempty(reports) ? nothing : abspath(only(reports)); direct_session)
