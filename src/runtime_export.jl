"""File copying for explicit runtime exports, independent of scientific packages."""
module RuntimeExport

function copy_file(source::AbstractString, destination::AbstractString)
    isfile(source) && !islink(source) ||
        throw(ArgumentError("missing or symlinked export prerequisite: $source"))
    mkpath(dirname(destination))
    cp(source, destination; force=true, follow_symlinks=true)
    return destination
end

function copy_tree(source::AbstractString, destination::AbstractString; ignored=Set{String}())
    isdir(source) && !islink(source) ||
        throw(ArgumentError("missing or symlinked export directory: $source"))
    !ispath(destination) && !islink(destination) ||
        throw(ArgumentError("export destination exists: $destination"))
    mkpath(destination)
    for name in readdir(source)
        name in ignored && continue
        from, to = joinpath(source, name), joinpath(destination, name)
        islink(from) && throw(ArgumentError("symlink in export source: $from"))
        if isdir(from)
            copy_tree(from, to; ignored)
        elseif isfile(from)
            copy_file(from, to)
        end
    end
    return destination
end

_outside(relative) = relative == ".." ||
    startswith(relative, ".." * string(Base.Filesystem.path_separator))

"""Copy only declared relative entries into a new directory.

Callers own the file list; this helper has no instrument or package selection
policy. Listed directories are copied recursively with the requested exclusions.
"""
function copy_entries(source::AbstractString, destination::AbstractString, entries;
        ignored=Set{String}())
    isdir(source) && !islink(source) ||
        throw(ArgumentError("missing or symlinked export directory: $source"))
    !ispath(destination) && !islink(destination) ||
        throw(ArgumentError("export destination exists: $destination"))
    selected = String[]
    for entry in entries
        entry isa AbstractString && !isempty(entry) && !isabspath(entry) &&
            all(part -> !(part in (".", "..")), splitpath(entry)) ||
            throw(ArgumentError("export entries must be contained relative paths"))
        relative = normpath(entry)
        relative in selected && throw(ArgumentError("duplicate export entry: $entry"))
        path = source
        for part in splitpath(relative)
            path = joinpath(path, part)
            islink(path) && throw(ArgumentError("symlink in export entry: $entry"))
        end
        isfile(path) || isdir(path) ||
            throw(ArgumentError("missing export entry: $entry"))
        push!(selected, relative)
    end
    isempty(selected) && throw(ArgumentError("runtime export has no entries"))
    ancestor = abspath(destination)
    while !ispath(ancestor)
        ancestor = dirname(ancestor)
    end
    _outside(relpath(realpath(ancestor), realpath(source))) ||
        throw(ArgumentError("export destination must not overlap source"))
    mkpath(destination)
    for entry in selected
        from, to = joinpath(source, entry), joinpath(destination, entry)
        if isdir(from)
            copy_tree(from, to; ignored)
        else
            copy_file(from, to)
        end
    end
    return destination
end

end # module RuntimeExport
