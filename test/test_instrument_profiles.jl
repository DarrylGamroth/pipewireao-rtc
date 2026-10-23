using Test, PipeWireAORTC

const E = PipeWireAORTC.InstrumentExport
const C = PipeWireAORTC.Common

@testset "portable instrument and host profile composition" begin
    portable = Dict("mode" => "hardware", "devices" => [], "calibration" => nothing,
        "bindings" => Dict("WFS_NODE" => "camera"))
    host = Dict("bindings" => Dict("WFS_NODE" => "camera"),
        "scheduling" => Dict("processes" => Dict("core" => Dict("cpus" => [2,3], "leader-cpu" => 3)),
            "bindings" => Dict("CORE_CPU" => Dict("\$ref" => "/processes/core/cpus/0"))))
    original = deepcopy((portable, host))
    combined = E.combine_profile(portable, host)
    @test combined["mode"] == "hardware"
    @test combined["devices"] == []
    @test combined["calibration"] === nothing
    @test combined["bindings"] == Dict("WFS_NODE" => "camera", "CORE_CPU" => 2)
    @test combined["placement"]["core"] == Dict("cpus"=>[2,3], "leader-cpu"=>3,
        "rt-priority"=>0, "locked-bytes"=>0, "threads"=>[])
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
        host = Dict("scheduling" => Dict("processes" => Dict(role => placement() for role in ("core", "rtc")),
            "bindings" => Dict("CORE_CPU" => Dict("\$ref"=>"/processes/core/cpus/0"),
                "OBSERVER_CPU" => Dict("\$ref"=>"/processes/core/leader-cpu"),
                "JULIA_CPU" => Dict("\$ref"=>"/processes/rtc/cpus/0"),
                "RT_PRIORITY" => Dict("\$ref"=>"/processes/core/rt-priority"))))
        C.write_yaml(host_path, host)
        @test E.load_profile(profile_path) == Dict("mode" => "simulation")
        combined = E.load_profile(profile_path; host=host_path)
        @test combined["mode"] == "simulation"
        @test !haskey(combined,"scheduling")
        spec() = Dict{String,Any}("owners" => [])
        bindings = E.profile_bindings(combined, Base.julia_cmd().exec[1])
        @test E.profile!(spec(), combined, bindings)["placement"] == host["scheduling"]["processes"]
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

@testset "one scheduling description configures and verifies arbitrary owners" begin
    reference(pointer) = Dict("\$ref" => pointer)
    worker = Dict("cpus"=>[7], "policy"=>"fifo", "priority"=>73,
        "count"=>1, "name"=>"camera-worker")
    host = Dict("scheduling"=>Dict(
        "defaults"=>Dict("rt-priority"=>73, "locked-bytes"=>4096),
        "processes"=>Dict("camera-acquisition"=>Dict("cpus"=>[9,7], "leader-cpu"=>9, "threads"=>[worker]),
            "mirror-output"=>Dict("cpus"=>[11], "leader-cpu"=>11, "rt-priority"=>0)),
        "bindings"=>Dict{String,Any}("ACQUISITION_CPU"=>reference("/processes/camera-acquisition/threads/0/cpus/0"),
            "WORKER_CPUS"=>reference("/processes/camera-acquisition/cpus"),
            "WORKER_PRIORITY"=>reference("/processes/camera-acquisition/rt-priority"),
            "PIN_CPUS"=>[reference("/processes/camera-acquisition/threads/0/cpus/0"),
                reference("/processes/mirror-output/leader-cpu")])),
        "bindings"=>Dict{String,Any}("DEVICE_NODE"=>"camera"))
    original = deepcopy(host)
    compiled = E.combine_profile(Dict("mode"=>"hardware"),host)
    @test compiled["bindings"] == Dict("ACQUISITION_CPU"=>7,"WORKER_CPUS"=>"9,7",
        "WORKER_PRIORITY"=>73,"DEVICE_NODE"=>"camera","PIN_CPUS"=>"7,11")
    @test compiled["placement"]["camera-acquisition"] == Dict("cpus"=>[9,7],"leader-cpu"=>9,
        "rt-priority"=>73,"locked-bytes"=>4096,"threads"=>[worker])
    @test compiled["placement"]["mirror-output"]["rt-priority"] == 0
    @test compiled["placement"]["mirror-output"]["threads"] == []
    changed = deepcopy(host)
    changed["scheduling"]["processes"]["camera-acquisition"]["cpus"] = [9,8]
    changed["scheduling"]["processes"]["camera-acquisition"]["threads"][1]["cpus"] = [8]
    next = E.combine_profile(Dict(),changed)
    @test next["bindings"]["ACQUISITION_CPU"] == 8
    @test next["bindings"]["WORKER_CPUS"] == "9,8"
    @test next["placement"]["camera-acquisition"]["threads"][1]["cpus"] == [8]
    compiled["placement"]["camera-acquisition"]["threads"][1]["cpus"][1] = 12
    @test host == original
    # Defaults and separate compilations do not share mutable thread storage.
    push!(compiled["placement"]["mirror-output"]["threads"],worker)
    @test isempty(E.combine_profile(Dict(),host)["placement"]["mirror-output"]["threads"])
    for (selector, error) in ((7, ArgumentError), ([7], ArgumentError),
            ([reference("/processes/camera-acquisition/cpus")], PipeWireAORTC.Placement.PlacementError),
            (reference("/environment/CPU"), ArgumentError),
            (reference("/processes/absent/cpus/0"), ArgumentError),
            (reference("/processes/camera-acquisition/cpus/01"), ArgumentError),
            (reference("/processes/camera-acquisition/cpus/9"), ArgumentError),
            (reference("/processes/camera-acquisition/threads/0/name"), ArgumentError),
            (reference("/processes/camera-acquisition/threads"), PipeWireAORTC.Placement.PlacementError),
            (Dict("\$ref"=>"/processes/mirror-output/leader-cpu","other"=>true), ArgumentError))
        invalid = deepcopy(host)
        invalid["scheduling"]["bindings"]["ACQUISITION_CPU"] = selector
        @test_throws error E.combine_profile(Dict(),invalid)
    end
    for key in ("processes","bindings")
        invalid=deepcopy(host)
        delete!(invalid["scheduling"],key)
        @test_throws ArgumentError E.combine_profile(Dict(),invalid)
    end
    invalid=deepcopy(host)
    invalid["bindings"]["ACQUISITION_CPU"]=7
    @test_throws ArgumentError E.combine_profile(Dict(),invalid)
    invalid=deepcopy(host)
    invalid["bindings"]["JULIA_CPUS"]="9,7"
    @test_throws ArgumentError E.combine_profile(Dict(),invalid)
    invalid=deepcopy(host)
    invalid["scheduling"]["bindings"]["REMOTE"]=reference("/processes/mirror-output/leader-cpu")
    @test_throws ArgumentError E.combine_profile(Dict(),invalid)
    @test_throws ArgumentError E.combine_profile(Dict(),Dict("placement"=>compiled["placement"]))
end
