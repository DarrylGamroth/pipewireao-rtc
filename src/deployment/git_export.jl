module GitExport

const DIRECTORY = ".rtc-export.git"

repository_path(package) = package * ".git"
available() = Sys.which("git") !== nothing

function export_pin(package)
    repository = repository_path(package)
    available() && (ispath(repository) || islink(repository)) || return (nothing, nothing)
    commit = strip(read(command("rev-parse", "--verify", "HEAD"; repository), String))
    return (repository, commit)
end

function command(args...; repository, worktree = nothing)
    argv = String["git", "--no-replace-objects", "--git-dir=" * repository]
    worktree === nothing || push!(argv, "--work-tree=" * worktree)
    append!(argv, args)
    # Use raw application bytes and the generated repository and index.
    env = Dict(key => value for (key, value) in ENV if !startswith(key, "GIT_"))
    env["GIT_CONFIG_NOSYSTEM"] = "1"
    env["GIT_CONFIG_GLOBAL"] = "/dev/null"
    env["GIT_ATTR_NOSYSTEM"] = "1"
    env["GIT_OPTIONAL_LOCKS"] = "0"
    return setenv(Cmd(argv), env)
end

function verified_paths(package)
    available() || return nothing
    repository = joinpath(package, DIRECTORY)
    pin = get(ENV, "PIPEWIREAO_RTC_EXPORT_COMMIT", nothing)
    if !(ispath(repository) || islink(repository))
        pin === nothing && return nothing
        throw(ArgumentError("missing installed export Git repository: $repository"))
    end
    isdir(repository) && !islink(repository) ||
        throw(ArgumentError("invalid installed export Git repository: $repository"))
    git(args...) = command(args...; repository, worktree = package)
    if pin !== nothing
        strip(read(git("rev-parse", "--verify", "HEAD"), String)) == pin ||
            throw(ArgumentError("installed export Git HEAD differs from its pinned commit"))
    end
    isempty(read(git("diff-index", "--cached", "--name-only", "-z", "HEAD", "--"))) ||
        throw(ArgumentError("installed export Git index differs from its pinned commit"))
    tracked = split(read(git("ls-files", "-v", "-z"), String), '\0'; keepempty = false)
    paths = Set{String}()
    for entry in tracked
        startswith(entry, "H ") ||
            throw(ArgumentError("invalid installed export Git index entry: $entry"))
        push!(paths, entry[3:end])
    end
    changed = split(read(git("diff-files", "--name-only", "-z", "--"), String), '\0';
                    keepempty = false)
    isempty(changed) ||
        throw(ArgumentError("installed export differs from its Git commit: " * first(changed)))
    return paths
end

function stage_tree!(repository, package, format)
    git(args...) = command(args...; repository, worktree = package)
    run(git("init", "--quiet", "--template=", "--object-format=" * format))
    run(git("config", "--local", "core.filemode", "true"))
    run(git("config", "--local", "core.trustctime", "true"))
    mkpath(joinpath(repository, "info"))
    write(joinpath(repository, "info", "attributes"),
          "* -text -filter -ident -working-tree-encoding -crlf\n")
    run(git("add", "--all", "--force", "--", ".", ":(exclude)" * DIRECTORY))
    return strip(read(git("write-tree"), String))
end

function snapshot!(package)
    available() || return nothing
    repository = repository_path(package)
    !(ispath(repository) || islink(repository)) ||
        throw(ArgumentError("export Git repository must be new: $repository"))
    mktempdir(dirname(repository)) do directory
        snapshot = joinpath(directory, "export.git")
        tree = stage_tree!(snapshot, package, "sha1")
        git(args...) = command(args...; repository = snapshot)
        commit = strip(read(git(
            "-c", "user.name=PipeWireAORTC",
            "-c", "user.email=pipewireao-export@localhost",
            "commit-tree", tree, "-m", "Simulation export",
        ), String))
        run(git("update-ref", "--no-deref", "HEAD", commit))
        # The installed package builds its own index for its copied files.
        rm(joinpath(snapshot, "index"))
        # git init records the separate work tree in non-bare repositories.
        run(ignorestatus(git("config", "--local", "--unset-all", "core.worktree")))
        run(git("config", "--local", "core.bare", "true"))
        mv(snapshot, repository)
    end
    return repository
end

function verify_install!(package, source_repository, commit)
    occursin(r"\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z", commit) ||
        throw(ArgumentError("export commit must be a full Git object ID"))
    source(args...) = command(args...; repository = source_repository)
    strip(read(source("cat-file", "-t", commit), String)) == "commit" ||
        throw(ArgumentError("Git export object must be a commit"))
    tree = strip(read(source("rev-parse", commit * "^{tree}"), String))
    repository = joinpath(package, DIRECTORY)
    git(args...) = command(args...; repository, worktree = package)
    format = length(commit) == 40 ? "sha1" : "sha256"
    actual = stage_tree!(repository, package, format)
    if tree != actual
        expected = split(read(source("ls-tree", "-r", "-z", tree), String), '\0';
                         keepempty = false)
        found = Set(split(read(git("ls-tree", "-r", "-z", actual), String), '\0';
                          keepempty = false))
        mismatch = findfirst(entry -> !(entry in found), expected)
        detail = mismatch === nothing ? "unexpected export files" :
                 last(split(expected[mismatch], '\t'; limit = 2))
        throw(ArgumentError("Git export tree mismatch for $commit: $detail"))
    end
    data = read(source("cat-file", "commit", commit))
    actual_commit = strip(read(pipeline(git("hash-object", "-t", "commit", "-w", "--stdin");
                                       stdin = IOBuffer(data)), String))
    actual_commit == commit || throw(ArgumentError("Git export commit changed during install"))
    run(git("update-ref", "--no-deref", "HEAD", commit))
    return nothing
end

end # module
