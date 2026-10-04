using Test, PipeWireAODeployment, JSON3
const P = PipeWireAODeployment

@testset "named deployment package and operational source closure" begin
    @test P.ScienceExport.Parameter("name", "endpoint", "F32_LE", (2, 3), "value", "schema").shape == [2, 3]
    @test nameof(P) == :PipeWireAODeployment
    @test Base.PkgId(P).uuid !== nothing
    @test isfile(joinpath(P.package_root(), "src", "PipeWireAODeployment.jl"))
    inventory = P.CalibrationCampaign.orchestration_sources()
    @test haskey(inventory, joinpath(P.package_root(), "src", "common.jl"))
    @test haskey(inventory, joinpath(P.resource_root(), "calibration_campaign.jl"))
    @test_throws ArgumentError P.source_relative_path(dirname(P.resource_root()))
    @test_throws ArgumentError P.ScienceExport.copy_deployment_runtime(dirname(P.package_root()))
    @test_throws ArgumentError P.ScienceExport.copy_deployment_runtime(joinpath(P.package_root(), "nested-output"))
    for directory in ("hil", "templates")
        rejected = tempname(joinpath(P.resource_root(), directory))
        @test_throws ArgumentError P.ScienceExport.copy_deployment_runtime(rejected)
        @test !ispath(rejected)
    end
    @test P.CalibrationCampaign.orchestration_sources() == inventory
    # The checkout's deployment directory is not itself copied recursively.
    # An unrelated child is safe; an installed package contains its resources
    # in the copied package tree, so every child there overlaps by definition.
    if P.resource_root() == dirname(P.package_root())
        mktempdir(P.resource_root()) do unrelated
            exported = P.ScienceExport.copy_deployment_runtime(unrelated)
            @test isfile(joinpath(exported, "src", "PipeWireAODeployment.jl"))
        end
    end
    @test isfile(joinpath(P.package_root(), "src", "PipeWireAODeployment.jl"))
    @test all(!occursin("/test/", path) && !endswith(path, ".py") for path in keys(inventory))
    for path in keys(inventory)
        relative = P.source_relative_path(path)
        @test !isabspath(relative)
        @test !(relative == ".." || startswith(relative, "../"))
    end
    mktempdir() do directory
        source = joinpath(directory, "export")
        mkdir(source)
        sdk = P.ScienceExport.copy_deployment_runtime(source)
        @test isfile(joinpath(sdk, "test", "Project.toml"))
        @test isfile(joinpath(sdk, "test", "runtests.jl"))
        @test sort(readdir(joinpath(sdk, "test"))) == sort(readdir(joinpath(P.package_root(), "test")))
        before = P.CalibrationCampaign.file_identity(sdk)
        # Compile at the original location, then load from a renamed SDK.
        command = [Base.julia_cmd().exec[1], "--startup-file=no", "--project=" * sdk,
            "-e", "using PipeWireAODeployment; @assert startswith(PipeWireAODeployment.package_root(), ARGS[1])", sdk]
        @test P.Common.run_checked(command; timeout=60).returncode == 0
        relocated = joinpath(directory, "relocated SDK")
        mv(source, relocated)
        sdk = joinpath(relocated, "julia")
        code = "using PipeWireAODeployment; P=PipeWireAODeployment; " *
            "@assert P.package_root()==ARGS[1]; " *
            "@assert P.resource_root()==joinpath(ARGS[1],\"assets/deployment\"); " *
            "@assert all(isfile, keys(P.CalibrationCampaign.orchestration_sources())); " *
            "P.ScienceExport.copy_deployment_runtime(ARGS[2])"
        copied = joinpath(directory, "second export")
        mkdir(copied)
        @test P.Common.run_checked([Base.julia_cmd().exec[1], "--startup-file=no", "--project=" * sdk,
            "-e", code, sdk, copied]; timeout=60).returncode == 0
        @test P.CalibrationCampaign.file_identity(sdk) == before
        @test isfile(joinpath(copied, "julia", "src", "common.jl"))
    end
end

@testset "unsupported SDK rejection preserves sealed sources" begin
    mktempdir() do directory
        legacy = joinpath(directory, "legacy")
        mkpath(joinpath(legacy, "src"))
        write(joinpath(legacy, "PipeWireAODeployment.jl"), "module PipeWireAODeployment; end")
        identity = P.CalibrationCampaign.file_identity(legacy)
        @test_throws P.Deployment.DeploymentError P.Deployment.validate_runtime(legacy)
        @test P.CalibrationCampaign.file_identity(legacy) == identity
        copied = joinpath(directory, "package")
        mkdir(copied)
        sdk = P.ScienceExport.copy_deployment_runtime(copied)
        @test P.Deployment.validate_runtime(sdk) == sdk
        project = read(joinpath(sdk, "Project.toml"), String)
        write(joinpath(sdk, "Project.toml"), replace(project, "version = \"0.1.0\"" => "version = \"9.0.0\""))
        @test_throws P.Deployment.DeploymentError P.Deployment.validate_runtime(sdk)
    end
end
