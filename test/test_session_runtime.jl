using Test, PipeWireAORTC
const Runtime = PipeWireAORTC.SessionRuntime

source_endpoint(profile, instance) = Dict{String,Any}(
    "control-protocol" => profile, "control-node" => "simulator-wfs",
    "control-instance" => instance)

@testset "readiness accepts the declared native source profile" begin
    for profile in ("pipewireao.rtc.calibration-lifecycle/1", "pipewireao.rtc.correction-lifecycle/1",
                    "pipewireao.source-control/1")
        source = source_endpoint(profile, "19")
        @test Runtime._source_endpoint(source) == Dict(
            "node" => "simulator-wfs", "instance" => Int64(19), "profile" => profile)
        if PipeWireAORTC.DeploymentConfiguration.native_source(source)
            # Native source owners publish their live mailbox incarnation;
            # SessionLaunch does not reserve an acquisition control-instance.
            source["control-instance"] = nothing
            @test Runtime._source_endpoint(source) == Dict(
                "node" => "simulator-wfs", "instance" => nothing, "profile" => profile)
        else
            source["control-instance"] = nothing
            @test_throws ArgumentError Runtime._source_endpoint(source)
        end
        for invalid in (0, -1, "", "not-an-instance", "1.0", string(big(typemax(Int64)) + 1))
            source["control-instance"] = invalid
            @test_throws ArgumentError Runtime._source_endpoint(source)
        end
        for node in (nothing, "", "source with spaces", "a"^129)
            source["control-instance"] = "19"
            source["control-node"] = node
            @test_throws ArgumentError Runtime._source_endpoint(source)
        end
    end
    for profile in (nothing, "", "pipewireao.source-control/2", "pipewireao.rtc.heart/1")
        @test_throws ArgumentError Runtime._source_endpoint(source_endpoint(profile, "19"))
    end
end

@testset "source Status remains calibration-specific" begin
    # Invalid profiles must fail before any connection or process lookup.
    for profile in ("pipewireao.source-control/1", "pipewireao.rtc.correction-lifecycle/1", "unknown")
        record = Dict("source_endpoint" => Dict("profile" => profile))
        @test_throws ArgumentError Runtime.source_status(record, "classic"; deadline=0)
    end
    @test_throws ArgumentError Runtime.source_status(Dict(), "unsupported"; deadline=0)
end
