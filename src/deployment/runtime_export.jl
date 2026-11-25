"""File copying for explicit runtime exports, independent of scientific packages."""
module RuntimeExport

public copy_file, copy_tree

"""
    copy_file(source, destination)

Copy a regular file, rejecting a symbolic-link source.
"""
function copy_file(source::AbstractString, destination::AbstractString)
    isfile(source) && !islink(source) ||
        throw(ArgumentError("missing or symlinked export prerequisite: $source"))
    mkpath(dirname(destination))
    cp(source, destination; force = true, follow_symlinks = true)
    return destination
end

"""
    copy_tree(source, destination; ignored=Set{String}())

Copy a directory to a fresh destination, rejecting symbolic links in the source.
Omit entries whose basenames appear in `ignored`.
"""
function copy_tree(
    source::AbstractString, destination::AbstractString; ignored = Set{String}()
)
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

end # module RuntimeExport
