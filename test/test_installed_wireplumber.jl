using Test, PipeWireAODeployment

const InstalledWirePlumber = PipeWireAODeployment.ScienceExport
const InstalledWirePlumberCommon = PipeWireAODeployment.Common

function wireplumber_prefix(root; library_dir="lib/x86_64-linux-gnu")
    prefix = joinpath(root, "prefix")
    directory = joinpath(prefix, library_dir)
    scripts = joinpath(prefix, "share/wireplumber/scripts")
    mkpath(joinpath(prefix, "bin"))
    mkpath(directory)
    mkpath(joinpath(directory, "wireplumber-0.5"))
    mkpath(joinpath(scripts, "ao"))
    mkpath(joinpath(scripts, "lib"))

    binary = joinpath(prefix, "bin/wireplumber")
    write(binary, "synthetic executable")
    chmod(binary, 0o755)
    library = joinpath(directory, "libwireplumber-0.5.so.0.0")
    write(library, "synthetic library")
    symlink(basename(library), joinpath(directory, "libwireplumber-0.5.so.0"))
    for name in ("lua-scripting", "ao-control-endpoint")
        write(joinpath(directory, "wireplumber-0.5", "libwireplumber-module-$name.so"),
            "synthetic $name module")
    end
    for relative in ("ao/session.lua", "lib/ao-control.lua", "lib/ao-owner.lua",
                     "lib/ao-acquisition.lua", "lib/ao-session-control.lua",
                     "lib/ao-connections.lua")
        path = joinpath(scripts, relative)
        mkpath(dirname(path))
        write(path, "synthetic $relative")
    end
    mkpath(joinpath(scripts, "tests"))
    write(joinpath(scripts, "tests/ignored.lua"), "not packaged")
    mkpath(joinpath(scripts, "test"))
    write(joinpath(scripts, "test/ignored.lua"), "not packaged")
    return prefix
end

function wireplumber_hashes(root)
    return Dict(relpath(path, root) => InstalledWirePlumberCommon.sha256_file(path)
        for (directory, _, names) in walkdir(root) for name in names
        for path in (joinpath(directory, name),))
end

function check_failed_wireplumber_stage(change, prefix, package)
    target = joinpath(package, "wireplumber")
    before = wireplumber_hashes(target)
    change(prefix)
    @test_throws ArgumentError InstalledWirePlumber.stage_wireplumber!(package; prefix)
    @test wireplumber_hashes(target) == before
    @test isempty(filter(name -> startswith(name, "wireplumber-stage-"), readdir(package)))
end

@testset "installed WirePlumber prefix stages the sealed manager layout" begin
    mktempdir() do root
        prefix = wireplumber_prefix(root)
        package = joinpath(root, "package")
        mkpath(package)
        target = InstalledWirePlumber.stage_wireplumber!(package; prefix)
        @test target == joinpath(package, "wireplumber")
        @test isfile(joinpath(target, "bin/wireplumber"))
        @test (stat(joinpath(target, "bin/wireplumber")).mode & 0o111) != 0
        @test read(joinpath(target, "lib/wp/libwireplumber-0.5.so.0"), String) == "synthetic library"
        @test read(joinpath(target, "modules/libwireplumber-module-lua-scripting.so"), String) ==
            "synthetic lua-scripting module"
        @test read(joinpath(target, "modules/libwireplumber-module-ao-control-endpoint.so"), String) ==
            "synthetic ao-control-endpoint module"
        for relative in ("ao/session.lua", "lib/ao-control.lua", "lib/ao-owner.lua",
                         "lib/ao-acquisition.lua", "lib/ao-session-control.lua",
                         "lib/ao-connections.lua")
            @test read(joinpath(target, "scripts", relative), String) == "synthetic $relative"
        end
        @test !ispath(joinpath(target, "scripts/tests"))
        @test !ispath(joinpath(target, "scripts/test"))
        @test InstalledWirePlumber.validate_wireplumber(target) === nothing
        @test InstalledWirePlumber.stage_wireplumber!(package) == target
    end
end

@testset "invalid installed WirePlumber prefix preserves prior staged manager" begin
    for missing in (:library, :module, :script)
        mktempdir() do root
            prefix = wireplumber_prefix(root)
            package = joinpath(root, "package")
            mkpath(package)
            InstalledWirePlumber.stage_wireplumber!(package; prefix)
            check_failed_wireplumber_stage(prefix, package) do selected_prefix
                if missing == :library
                    rm(joinpath(selected_prefix, "lib/x86_64-linux-gnu/libwireplumber-0.5.so.0"))
                elseif missing == :module
                    rm(joinpath(selected_prefix,
                        "lib/x86_64-linux-gnu/wireplumber-0.5/libwireplumber-module-lua-scripting.so"))
                else
                    rm(joinpath(selected_prefix, "share/wireplumber/scripts/lib/ao-owner.lua"))
                end
            end
        end
    end
end

@testset "installed WirePlumber library layout and source selection are exact" begin
    mktempdir() do root
        prefix = wireplumber_prefix(root)
        package = joinpath(root, "package")
        mkpath(package)
        target = InstalledWirePlumber.stage_wireplumber!(package; prefix)
        before = wireplumber_hashes(target)
        duplicate = joinpath(prefix, "lib64")
        mkpath(duplicate)
        write(joinpath(duplicate, "libwireplumber-0.5.so.0"), "ambiguous library")
        @test_throws ArgumentError InstalledWirePlumber.stage_wireplumber!(package; prefix)
        @test wireplumber_hashes(target) == before
        @test isempty(filter(name -> startswith(name, "wireplumber-stage-"), readdir(package)))
        @test_throws ArgumentError InstalledWirePlumber.stage_wireplumber!(package; build="build")
        @test_throws ArgumentError InstalledWirePlumber.stage_wireplumber!(package; source="source")
    end
end

@testset "installed WirePlumber staging rejects a symlink target" begin
    mktempdir() do root
        prefix = wireplumber_prefix(root)
        package = joinpath(root, "package")
        external = joinpath(root, "external")
        mkpath(package)
        mkpath(external)
        write(joinpath(external, "sentinel"), "unchanged")
        symlink(external, joinpath(package, "wireplumber"))
        @test_throws ArgumentError InstalledWirePlumber.stage_wireplumber!(package; prefix)
        @test read(joinpath(external, "sentinel"), String) == "unchanged"
        @test islink(joinpath(package, "wireplumber"))
        @test isempty(filter(name -> startswith(name, "wireplumber-stage-"), readdir(package)))
    end
end
