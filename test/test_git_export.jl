using Test, PipeWireAORTC

const Export = PipeWireAORTC.GitExport
const Deployment = PipeWireAORTC.DeploymentConfiguration

@testset "Pinned Git deployment export" begin
    mktempdir() do root
        source = mkdir(joinpath(root, "source"))
        git(args...) = Cmd(["git", "-C", source, args...])
        run(git("init", "--quiet", "--template="))
        write(joinpath(source, "asset.fits"), UInt8[0x01, 0x02, 0x03])
        write(joinpath(source, ".gitattributes"), "*.fits filter=unsupported\n")
        run(git("add", "--", "."))
        run(git("-c", "user.name=RTC test", "-c", "user.email=rtc@example.invalid",
                "commit", "--quiet", "--no-gpg-sign", "-m", "Export"))
        pin = strip(read(git("rev-parse", "HEAD"), String))
        install = mkdir(joinpath(root, "installed"))
        asset = joinpath(install, "asset.fits")
        cp(joinpath(source, "asset.fits"), asset)
        cp(joinpath(source, ".gitattributes"), joinpath(install, ".gitattributes"))
        Export.verify_install!(install, joinpath(source, ".git"), pin)
        @test Export.verified_paths(install) == Set([".gitattributes", "asset.fits"])
        withenv("PIPEWIREAO_RTC_EXPORT_COMMIT" => pin, "GIT_DIR" => "irrelevant") do
            @test "asset.fits" in Export.verified_paths(install)
            @test_throws ArgumentError Export.verified_paths(source)
        end
        withenv("PIPEWIREAO_RTC_EXPORT_COMMIT" => repeat("0", length(pin))) do
            @test_throws ArgumentError Export.verified_paths(install)
        end
        installed_git = Export.command("update-index", "--skip-worktree", "asset.fits";
                                       repository = joinpath(install, Export.DIRECTORY),
                                       worktree = install)
        run(installed_git)
        @test_throws ArgumentError Export.verified_paths(install)
        run(Export.command("update-index", "--no-skip-worktree", "asset.fits";
                           repository = joinpath(install, Export.DIRECTORY), worktree = install))
        @test_throws Deployment.DeploymentError Deployment.validate_deployment_artifacts(
            Dict("asset.fits" => "invalid"), joinpath(install, "deployment.conf")
        )
        timestamp = joinpath(root, "timestamp")
        run(`touch -r $asset $timestamp`)
        write(asset, UInt8[0x01, 0x02, 0x04])
        run(`touch -r $timestamp $asset`)
        @test_throws ArgumentError Export.verified_paths(install)
        tampered = mkdir(joinpath(root, "tampered"))
        cp(asset, joinpath(tampered, "asset.fits"))
        cp(joinpath(source, ".gitattributes"), joinpath(tampered, ".gitattributes"))
        @test_throws ArgumentError Export.verify_install!(tampered, joinpath(source, ".git"), pin)
    end
end

@testset "Optional export Git snapshot" begin
    mktempdir() do directory
        application = mkdir(joinpath(directory, "export"))
        asset = joinpath(application, "asset.fits")
        bytes = UInt8[0x00, 0x05, 0x0d, 0x0a]
        write(asset, bytes)
        @test Export.export_pin(application) == (nothing, nothing)
        withenv("PATH" => directory) do
            @test Export.snapshot!(application) === nothing
        end
        snapshot = Export.snapshot!(application)
        repository, commit = Export.export_pin(application)
        @test repository == snapshot == application * ".git"
        @test read(Export.command("show", commit * ":asset.fits"; repository)) == bytes
        @test_throws ArgumentError Export.snapshot!(application)
        copied = mkdir(joinpath(directory, "copy"))
        cp(asset, joinpath(copied, "asset.fits"))
        Export.verify_install!(copied, repository, commit)
        @test Export.verified_paths(copied) == Set(["asset.fits"])
        withenv("PATH" => directory, "PIPEWIREAO_RTC_EXPORT_COMMIT" => commit) do
            @test Export.export_pin(application) == (nothing, nothing)
            @test Export.verified_paths(copied) === nothing
        end
    end
end
