using Test, PipeWireAODeployment
include(joinpath(dirname(@__DIR__), "wireplumber_launch.jl"))

@testset "exact installed graceful stop hook" begin
    request = WirePlumberLaunch.Request("/sdk", "/prefix", "pipewireao-session@test.service",
        "/sdk/bin/pipewireao-rtc-session", "/run/user/1000/pipewireao-session-test")
    hook = "{ path=/sdk/bin/pipewireao-rtc-session ; argv[]=/sdk/bin/pipewireao-rtc-session stop --unit pipewireao-session@test.service --runtime-root /run/user/1000/pipewireao-session-test ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0 }"
    @test WirePlumberLaunch.stop_hook_valid(hook, request)
    for changed in (replace(hook, "stop --unit"=>"control --unit"),
                    replace(hook, "@test.service"=>"@foreign.service"),
                    replace(hook, "ignore_errors=no"=>"ignore_errors=yes"),
                    replace(hook, "session-test ;"=>"session-foreign ;"),
                    hook * " " * hook, "", "/sdk/bin/pipewireao-rtc-session")
        @test !WirePlumberLaunch.stop_hook_valid(changed, request)
    end
    template = read(joinpath(dirname(@__DIR__), "assets/deployment/pipewireao-session@.service.in"), String)
    @test "ExecStop=@LAUNCHER@ stop --unit %n --runtime-root %t/pipewireao-session-%i" in split(template, '\n')
    @test first(findfirst("ExecStop=", template)) < first(findfirst("ExecStopPost=", template))
    @test "KillMode=control-group" in split(template, '\n')
    @test "TimeoutStopSec=300" in split(template, '\n')
end
