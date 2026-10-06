using Test, PipeWireAODeployment
const D = PipeWireAODeployment.Deployment
@testset "fresh installed native outputs retain strict profile validation" begin
    for package in (
        "/home/dgamroth/.cache/rtc-native-calibration-final-20261006/classic-fgn-native-calibration-v1-installed",
        "/home/dgamroth/.cache/rtc-native-final-deployment-20261006/classic-heart-native-v1-installed")
        specification = D.profile(joinpath(package,"deployment.conf"),"/opt/pipewireao")
        @test all(owner -> D.native_acquisition(owner) || D.native_bootstrap(owner) ||
            D.native_heart(owner),specification["owners"])
    end
end
