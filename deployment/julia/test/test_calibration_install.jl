module CalibrationInstallTests
using Test, PipeWireAODeployment
include(joinpath(PipeWireAODeployment.package_root(),"wireplumber_install.jl"))
const Installer = WirePlumberInstall
const Common = PipeWireAODeployment.Common
const Configuration = PipeWireAODeployment.DeploymentConfiguration
@testset "calibration installer validates Julia entrypoint and preserves sealed Rust" begin
    mktempdir() do root
        path=joinpath(root,"bin/rtc-calibrate")
        mkpath(dirname(path))
        wrappers=Configuration.installed_wrappers(Base.julia_cmd().exec[1])
        script=wrappers["rtc-calibrate"]
        write(path,script)
        spec=Dict("artifacts"=>Dict("bin/rtc-calibrate"=>Common.sha256_file(path)))
        Common.write_json(joinpath(root,"provenance.json"),Dict("calibration_command"=>Dict(
            "path"=>"bin/rtc-calibrate","implementation"=>"julia")))
        before=read(path)
        @test Installer.validate_sealed_wrappers(root,spec,wrappers)===nothing
        @test read(path)==before
        write(path,script*"# changed\n")
        @test_throws ArgumentError Installer.validate_sealed_wrappers(root,spec,wrappers)
        @test endswith(read(path,String),"# changed\n")
        write(path,UInt8[0x7f,0x45,0x4c,0x46,0xff])
        before=read(path)
        for metadata in (Dict("path"=>"bin/rtc-calibrate"),nothing)
            Common.write_json(joinpath(root,"provenance.json"),Dict("calibration_command"=>metadata))
            @test Installer.validate_sealed_wrappers(root,spec,wrappers)===nothing
            @test read(path)==before
        end
        Common.write_json(joinpath(root,"provenance.json"),Dict())
        @test Installer.validate_sealed_wrappers(root,spec,wrappers)===nothing
        @test read(path)==before
        @test Installer.validate_sealed_wrappers(root,Dict("artifacts"=>Dict()),wrappers)===nothing
    end
end
end
