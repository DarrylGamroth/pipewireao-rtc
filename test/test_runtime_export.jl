using Test, PipeWireAORTC
const R = PipeWireAORTC.RuntimeExport
tree_identity(root) = Dict(relpath(joinpath(parent, file), root) => PipeWireAORTC.Common.sha256_file(joinpath(parent, file)) for (parent, _, files) in walkdir(root) for file in files)

@testset "explicit runtime entries" begin
    mktempdir() do root
        source = joinpath(root, "source"); mkpath(joinpath(source, "src"))
        write(joinpath(source, "Project.toml"), "project")
        write(joinpath(source, "src", "owner.jl"), "owner")
        write(joinpath(source, "src", "ignored.tmp"), "scratch")
        write(joinpath(source, "unrelated-build.bin"), "build output")
        mkpath(joinpath(source, "other-instrument"))
        write(joinpath(source, "other-instrument", "matrix"), "not selected")
        destination = joinpath(root, "selected")
        @test R.copy_entries(source, destination, ("Project.toml", "src");
            ignored=Set(["ignored.tmp"])) == destination
        @test read(joinpath(destination, "Project.toml"), String) == "project"
        @test read(joinpath(destination, "src", "owner.jl"), String) == "owner"
        @test !ispath(joinpath(destination, "src", "ignored.tmp"))
        @test !ispath(joinpath(destination, "unrelated-build.bin"))
        @test !ispath(joinpath(destination, "other-instrument"))
        @test_throws ArgumentError R.copy_entries(source, destination, ("src",))
        for entries in ((), ("missing",), ("src", "missing"), ("src", "src"),
                ("../source/src",), ("src/../Project.toml",), (".",), (source,), (1,))
            rejected = joinpath(root, "rejected")
            @test_throws ArgumentError R.copy_entries(source, rejected, entries)
            @test !ispath(rejected)
        end
        @test_throws ArgumentError R.copy_entries(source, joinpath(source, "nested"), ("src",))
        @test !ispath(joinpath(source, "nested"))
        symlink(joinpath(source, "src"), joinpath(source, "linked"))
        @test_throws ArgumentError R.copy_entries(source, joinpath(root, "linked-output"), ("linked",))
        @test_throws ArgumentError R.copy_entries(source, joinpath(root, "linked-parent"), ("linked/owner.jl",))
        symlink(joinpath(root, "absent"), joinpath(root, "dangling"))
        @test_throws ArgumentError R.copy_entries(source, joinpath(root, "dangling"), ("src",))
        # Relative file paths also preserve their parent directories.
        partial = joinpath(root, "partial")
        R.copy_entries(source, partial, ("src/owner.jl",))
        @test readdir(joinpath(partial, "src")) == ["owner.jl"]
    end
end

@testset "file helpers preserve the exporter API" begin
    @test PipeWireAORTC.ScienceExport.copy_file === R.copy_file
    @test PipeWireAORTC.ScienceExport.copy_tree === R.copy_tree
    # The extracted helper loads without the operational or science package.
    standalone = Module(:StandaloneRuntimeExport)
    Base.include(standalone, joinpath(PipeWireAORTC.package_root(), "src", "deployment", "runtime_export.jl"))
    @test isdefined(standalone, :RuntimeExport)
    @test !isdefined(standalone, :PipeWireAORTC)
    @test !isdefined(standalone, :ScienceExport)
end

@testset "SDK export uses the declared source closure" begin
    # Use a copied source tree so tests do not modify loaded or sealed packages.
    mktempdir() do root
        source = joinpath(root, "source")
        R.copy_entries(PipeWireAORTC.package_root(), source,
            (PipeWireAORTC.ScienceExport.RUNTIME_ENTRIES..., "assets/deployment"))
        write(joinpath(source, "unrelated-build.bin"), "not runtime data")
        mkpath(joinpath(source, "other-instrument"))
        write(joinpath(source, "other-instrument", "matrix"), "not selected")
        exported = joinpath(root, "exported")
        R.copy_entries(source, exported, PipeWireAORTC.ScienceExport.RUNTIME_ENTRIES)
        @test !ispath(joinpath(exported, "unrelated-build.bin"))
        @test !ispath(joinpath(exported, "other-instrument"))
        @test !ispath(joinpath(exported, "assets", "deployment"))
        for entry in PipeWireAORTC.ScienceExport.RUNTIME_ENTRIES
            original, copied = joinpath(source, entry), joinpath(exported, entry)
            @test isfile(original) ? read(original) == read(copied) :
                tree_identity(original) ==
                tree_identity(copied)
        end
    end
end

@testset "installed validation requires declared runtime entries" begin
    mktempdir() do root
        sdk = PipeWireAORTC.ScienceExport.copy_deployment_runtime(root)
        @test PipeWireAORTC.DeploymentConfiguration.validate_runtime(sdk) == sdk
        for name in ("session_install.jl", "src/deployment/session_install.jl",
                     "src/native/native_control_codec.jl", "assets/deployment/hil/parameter_source.jl")
            path = joinpath(sdk, name)
            bytes = read(path)
            rm(path)
            @test_throws PipeWireAORTC.DeploymentConfiguration.DeploymentError PipeWireAORTC.DeploymentConfiguration.validate_runtime(sdk)
            write(path, bytes)
            @test PipeWireAORTC.DeploymentConfiguration.validate_runtime(sdk) == sdk
        end
    end
end
