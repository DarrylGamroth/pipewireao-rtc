using Test, PipeWireAODeployment
const D = PipeWireAODeployment.Deployment
const C = PipeWireAODeployment.Common
const X = PipeWireAODeployment.HeartClassicTransfer
const root = "/home/dgamroth/.cache/rtc-calibration-completion-20261003"
const package = joinpath(root, "classic-native-transfer-v2")
const evidence = package * "-evidence"
const lifecycle = evidence * ".lifecycle.json"
const score = joinpath(root,"classic-native-transfer-managed-v5.json")
const score_sha = "1f51e4914936491a61f950815037d5911b9ca1e31b2e94de4179a2167d29363a"

println("loaded_source_sha256=", C.sha256_file(joinpath(PipeWireAODeployment.package_root(),
    "src", "heart_classic_transfer.jl")))
@testset "immutable historical Classic transfer admission" begin
    preparation = C.read_json(package * ".preparation.json"; maximum=64*1024*1024)
    before = PipeWireAODeployment.CalibrationCampaign.file_identity(package)
    @test before == preparation["package_files_sha256"]
    @test C.sha256_file(score) == score_sha
    @test_throws D.DeploymentError D.profile(joinpath(package,"deployment.conf"),"/opt/pipewireao")
    admitted = try
        X.admit(package,evidence,lifecycle)
    catch exception
        println("admission_failure=",sprint(showerror,exception))
        nothing
    end
    @test admitted !== nothing
    if admitted !== nothing
        @test admitted["package_files"] == before
        @test admitted["lifecycle_sha256"] == C.sha256_file(lifecycle)
    end
    @test before == PipeWireAODeployment.CalibrationCampaign.file_identity(package)
    @test C.sha256_file(score) == score_sha
    mktempdir() do temporary
        launch = C.read_json(lifecycle)
        for key in ("driver_sha256","preparation_sha256","descriptor_sha256")
            changed = copy(launch)
            changed[key] = repeat("0",64)
            path = joinpath(temporary,key * ".json")
            C.write_json(path,changed)
            @test_throws ArgumentError X.admit(package,evidence,path)
        end
        malformed = C.read_json(joinpath(package,"deployment.conf"))
        only(filter(owner -> owner["role"] == "heart",malformed["owners"]))["quit"] = false
        path = joinpath(temporary,"malformed.conf")
        C.write_json(path,malformed)
        failure = try
            D.profile(path,"/opt/pipewireao";legacy_export_input=true)
            nothing
        catch exception
            exception
        end
        @test failure isa D.DeploymentError
        @test occursin("quit must be a marker basename",sprint(showerror,failure))
    end
end
