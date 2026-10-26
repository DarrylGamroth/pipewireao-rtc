using Test, PipeWireAORTC

const E = PipeWireAORTC.ScienceExport
const C = PipeWireAORTC.Common

@testset "staged RTC scripts include their application dependencies" begin
    scripts = joinpath(pkgdir(PipeWireAORTC), "native", "scripts")
    for relative in E.RTC_SCRIPTS
        source = read(joinpath(scripts, relative), String)
        for required in eachmatch(r"require\s*\(\s*\"(ao-[^\"]+)\"\s*\)", source)
            @test "lib/" * required[1] * ".lua" in E.RTC_SCRIPTS
        end
    end
end

function dependency_prefix(root; library_dir="lib/x86_64-linux-gnu")
    prefix = joinpath(root, "dependency")
    directory = joinpath(prefix, library_dir)
    scripts = joinpath(prefix, "share/wireplumber/scripts")
    mkpath(joinpath(directory, "wireplumber-0.5"))
    mkpath(joinpath(scripts, "lib"))
    library = joinpath(directory, "libwireplumber-0.5.so.0.0")
    write(library, "library")
    symlink(basename(library), joinpath(directory, "libwireplumber-0.5.so.0"))
    for name in E.WIREPLUMBER_MODULES
        write(joinpath(directory, "wireplumber-0.5/libwireplumber-module-$name.so"), name)
    end
    write(joinpath(scripts, "lib/common.lua"), "generic dependency helper")
    # Stale custom prefix files must not become application assets.
    mkpath(joinpath(prefix, "bin"))
    write(joinpath(prefix, "bin/wireplumber"), "old daemon")
    for relative in E.RTC_SCRIPTS
        mkpath(dirname(joinpath(scripts, relative)))
        write(joinpath(scripts, relative), "old application policy")
    end
    return prefix
end

function native_build(root)
    build = joinpath(root, "native-build")
    source = joinpath(root, "native-source")
    mkpath(joinpath(build, "modules"))
    binary = joinpath(build, "pipewireao-rtc")
    write(binary, "native RTC")
    chmod(binary, 0o755)
    for name in E.RTC_MODULES
        write(joinpath(build, "modules/libwireplumber-module-$name.so"), name)
    end
    for relative in E.RTC_SCRIPTS
        path = joinpath(source, "scripts", relative)
        mkpath(dirname(path))
        write(path, relative)
    end
    return build, source
end

hashes(root) = Dict(relpath(joinpath(parent, name), root) => C.sha256_file(joinpath(parent, name))
    for (parent, _, names) in walkdir(root) for name in names)

@testset "separate generic dependency and headless RTC staging" begin
    mktempdir() do root
        prefix = dependency_prefix(root)
        build, source = native_build(root)
        package = mkpath(joinpath(root, "package"))
        dependency = E.stage_wireplumber!(package; prefix)
        rtc = E.stage_rtc!(package; native_build=build, native_source=source)
        @test read(joinpath(dependency, "scripts/lib/common.lua"), String) == "generic dependency helper"
        @test !ispath(joinpath(dependency, "bin"))
        @test all(!ispath(joinpath(dependency, "scripts", path)) for path in E.RTC_SCRIPTS)
        @test read(joinpath(rtc, "bin/pipewireao-rtc"), String) == "native RTC"
        @test (stat(joinpath(rtc, "bin/pipewireao-rtc")).mode & 0o111) != 0
        @test all(isfile(joinpath(rtc, "scripts", path)) for path in E.RTC_SCRIPTS)
        @test E.stage_wireplumber!(package) == dependency
        @test E.stage_rtc!(package) == rtc
        @test E.validate_wireplumber(dependency) === nothing
        @test E.validate_rtc(rtc) === nothing
        before_dependency, before_rtc = hashes(dependency), hashes(rtc)
        rm(joinpath(prefix, "lib/x86_64-linux-gnu/wireplumber-0.5/libwireplumber-module-lua-scripting.so"))
        @test_throws ArgumentError E.stage_wireplumber!(package; prefix)
        @test hashes(dependency) == before_dependency
        rm(joinpath(source, "scripts/lib/ao-owner.lua"))
        @test_throws ArgumentError E.stage_rtc!(package; native_build=build, native_source=source)
        @test hashes(rtc) == before_rtc
        @test isempty(filter(name -> occursin("-stage-", name), readdir(package)))
    end
end

@testset "RTC installed prefix and exact stage selection" begin
    mktempdir() do root
        build, source = native_build(root)
        prefix = mkpath(joinpath(root, "prefix"))
        mkpath(joinpath(prefix, "bin"))
        cp(joinpath(build, "pipewireao-rtc"), joinpath(prefix, "bin/pipewireao-rtc"))
        mkpath(joinpath(prefix, "lib/pipewireao-rtc"))
        cp(joinpath(build, "modules"), joinpath(prefix, "lib/pipewireao-rtc/modules"))
        mkpath(joinpath(prefix, "share/pipewireao-rtc"))
        cp(joinpath(source, "scripts"), joinpath(prefix, "share/pipewireao-rtc/scripts"))
        package = mkpath(joinpath(root, "package"))
        @test isdir(E.stage_rtc!(package; native_prefix=prefix))
        @test_throws ArgumentError E.stage_rtc!(package; native_build=build)
        @test_throws ArgumentError E.stage_rtc!(package; native_source=source)
        @test_throws ArgumentError E.stage_rtc!(package; native_build=build, native_source=source, native_prefix=prefix)
        @test_throws ArgumentError E.stage_wireplumber!(package; build=build)
        @test_throws ArgumentError E.stage_wireplumber!(package; source=source)
        external = mkpath(joinpath(root, "external"))
        rm(joinpath(package, "rtc"); recursive=true)
        symlink(external, joinpath(package, "rtc"))
        @test_throws ArgumentError E.stage_rtc!(package; native_prefix=prefix)
        @test islink(joinpath(package, "rtc"))
    end
end

@testset "generic dependency rejects daemon and RTC application policy" begin
    mktempdir() do root
        prefix = dependency_prefix(root)
        package = mkpath(joinpath(root, "package"))
        target = E.stage_wireplumber!(package; prefix)
        mkpath(joinpath(target, "bin"))
        @test_throws ArgumentError E.validate_wireplumber(target)
        rm(joinpath(target, "bin"); recursive=true)
        mkpath(joinpath(target, "scripts/ao"))
        write(joinpath(target, "scripts/ao/session.lua"), "untrusted")
        @test_throws ArgumentError E.validate_wireplumber(target)
    end
end
