using Test, PipeWireAODeployment
const D = PipeWireAODeployment.Deployment
@testset "Pre-admission session manager configuration" begin
    manager = Dict("argv"=>["@PACKAGE@/wireplumber/wireplumber","-c","@RUNTIME@/wireplumber/wireplumber.conf","-p","ao-rtc"],
        "environment"=>Dict{String,String}(), "marker-node"=>"pipewireao.rtc.realization.test")
    @test D.validate_session_manager(manager) === nothing
    for mutated in (merge(manager,Dict("unknown"=>true)), merge(manager,Dict("marker-node"=>"bad/name")),
            merge(manager,Dict("argv"=>["wireplumber","-c","saved.json","-p","ao-rtc"])),
            merge(manager,Dict("environment"=>Dict("BAD=NAME"=>"value"))))
        @test_throws D.DeploymentError D.validate_session_manager(mutated)
    end
    config = D.session_manager_configuration(manager["marker-node"],"/tmp/private/core")
    @test occursin("ao.rtc-realization = required",config)
    @test occursin("realization.lua",config)
    @test !occursin("monitor.alsa",config)
    @test occursin("remote.name = \"/tmp/private/core\"",config)
end
