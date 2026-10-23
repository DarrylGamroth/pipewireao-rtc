using Test, PipeWireAORTC

const E = PipeWireAORTC.InstrumentExport
const C = PipeWireAORTC.Common

@testset "portable instrument and host profile composition" begin
    portable = Dict("mode" => "hardware", "devices" => [], "calibration" => nothing,
        "bindings" => Dict("WFS_NODE" => "camera"))
    host = Dict("bindings" => Dict("CORE_CPU" => 2, "WFS_NODE" => "camera"),
        "placement" => Dict("core" => Dict("cpus" => [2, 3])))
    original = deepcopy((portable, host))
    combined = E.combine_profile(portable, host)
    @test combined["mode"] == "hardware"
    @test combined["devices"] == []
    @test combined["calibration"] === nothing
    @test combined["bindings"] == Dict("WFS_NODE" => "camera", "CORE_CPU" => 2)
    @test combined["placement"] == host["placement"]
    combined["placement"]["core"]["cpus"][1] = 7
    @test (portable, host) == original
    @test E.combine_profile(portable) == portable

    for invalid in (Dict("mode" => "simulation"), Dict("devices" => []),
            Dict("calibration" => nothing), Dict("unknown" => 1),
            Dict("bindings" => Dict("WFS_NODE" => "different")))
        @test_throws ArgumentError E.combine_profile(portable, invalid)
    end
    for invalid in (Dict("placement" => Dict()), Dict("simulation" => Dict()),
            Dict("unknown" => 1), Dict("bindings" => Dict("CORE_CPU" => 2)),
            Dict("bindings" => Dict("JULIA_CPUS" => "2,3")),
            Dict("bindings" => Dict("RT_PRIORITY" => 0)),
            Dict("bindings" => Dict("REMOTE" => "other")),
            Dict("bindings" => Dict("wfs_node" => "camera")),
            Dict("bindings" => Dict("WFS_NODE" => ["camera"])))
        @test_throws ArgumentError E.combine_profile(invalid, host)
    end
    @test_throws ArgumentError E.combine_profile([], host)
    @test_throws ArgumentError E.combine_profile(portable, [])

    # The merge contract keeps vectors intact and rejects conflicting leaves.
    left = Dict("nested" => Dict("cpus" => [2, 3], "one" => 1))
    right = Dict("nested" => Dict("cpus" => [2, 3], "two" => 2))
    @test E.merge_profile(left, right)["nested"] ==
        Dict("cpus" => [2, 3], "one" => 1, "two" => 2)
    @test_throws ArgumentError E.merge_profile(left, Dict("nested" => Dict("cpus" => [4])))
    @test_throws ArgumentError E.merge_profile(left, Dict("nested" => 1))
    @test_throws ArgumentError E.merge_profile(left, Dict("nested" => Dict("one" => 2)))
end

@testset "bounded YAML profile loading and exact process roles" begin
    mktempdir() do directory
        profile_path = joinpath(directory, "profile.yaml")
        host_path = joinpath(directory, "host.yaml")
        C.write_yaml(profile_path, Dict("mode" => "simulation"))
        placement() = Dict("cpus" => [2, 3], "leader-cpu" => 3,
            "locked-bytes" => 0, "rt-priority" => 0, "threads" => [])
        host = Dict("placement" => Dict(role => placement() for role in ("core", "rtc")),
            "bindings" => Dict("CORE_CPU" => 2, "OBSERVER_CPU" => 3,
                "JULIA_CPU" => 2, "RT_PRIORITY" => 0))
        C.write_yaml(host_path, host)
        @test E.load_profile(profile_path) == Dict("mode" => "simulation")
        combined = E.load_profile(profile_path; host=host_path)
        @test combined == merge(Dict("mode" => "simulation"), host)
        spec() = Dict{String,Any}("owners" => [])
        bindings = E.profile_bindings(combined, Base.julia_cmd().exec[1])
        @test E.profile!(spec(), combined, bindings)["placement"] == host["placement"]
        for roles in (("core",), ("core", "rtc", "camera"))
            invalid = deepcopy(combined)
            invalid["placement"] = Dict(role => placement() for role in roles)
            @test_throws ArgumentError E.profile!(spec(), invalid, bindings)
        end
        for payload in ("mode: simulation\nmode: hardware\n",
                "bindings:\n  WFS_NODE: one\n  WFS_NODE: two\n",
                "mode: simulation\n---\nmode: hardware\n", "- simulation\n",
                "mode: simulation\nunknown: true\n", repeat("#", 1024 * 1024 + 1))
            write(profile_path, payload)
            @test_throws ArgumentError E.load_profile(profile_path; host=host_path)
        end
        C.write_yaml(profile_path, Dict("mode" => "simulation"))
        for payload in ("bindings:\n  CORE_CPU: 2\n  CORE_CPU: 3\n",
                "mode: hardware\n", "placement: {}\nunknown: true\n")
            write(host_path, payload)
            @test_throws ArgumentError E.load_profile(profile_path; host=host_path)
        end
    end
end
