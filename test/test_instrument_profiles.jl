using Test, PipeWireAORTC
const E = PipeWireAORTC.InstrumentExport
const C = PipeWireAORTC.Common

function host_profile()
    Dict{String,Any}("scheduling" => Dict{String,Any}("defaults" => Dict{String,Any}("locked-bytes"=>4096),
        "processes" => Dict{String,Any}(role => Dict{String,Any}("cpus"=>[2,3], "leader-cpu"=>3)
            for role in ("core", "rtc"))))
end

@testset "portable choices and launcher scheduling stay separate" begin
    portable = Dict{String,Any}("mode"=>"hardware", "devices"=>[], "calibration"=>nothing,
        "bindings"=>Dict{String,Any}("WFS_NODE"=>"camera"))
    host = host_profile()
    host["bindings"] = Dict{String,Any}("WFS_NODE"=>"camera")
    original = deepcopy((portable,host))
    combined = E.combine_profile(portable,host)
    @test combined["bindings"] == Dict{String,Any}("WFS_NODE"=>"camera")
    @test combined["placement"]["core"] == Dict{String,Any}("cpus"=>[2,3],"leader-cpu"=>3,
        "locked-bytes"=>4096,"rt-priority"=>0,"threads"=>[])
    @test combined["scheduling"]["processes"]["core"]["workers"] == Dict{String,Any}()
    @test E.combine_profile(portable) == portable
    combined["placement"]["core"]["cpus"][1]=4
    @test (portable,host) == original
    for fragment in (Dict{String,Any}("mode"=>"simulation"),Dict{String,Any}("devices"=>[]),
            Dict{String,Any}("calibration"=>nothing),Dict{String,Any}("unknown"=>true),
            Dict{String,Any}("bindings"=>Dict{String,Any}("WFS_NODE"=>"different")))
        @test_throws ArgumentError E.combine_profile(portable,merge(host,fragment))
    end
    for name in ("CORE_CPU","OPTICAL_CPU","TRANSPORT_CPU","JULIA_CPUS","RT_PRIORITY","REMOTE")
        @test_throws ArgumentError E.combine_profile(portable,merge(host,Dict{String,Any}("bindings"=>Dict{String,Any}(name=>2))))
    end
    @test_throws ArgumentError E.combine_profile(portable,Dict{String,Any}("placement"=>Dict{String,Any}()))
    @test_throws ArgumentError E.combine_profile(portable,[])
    @test_throws ArgumentError E.combine_profile([],host)
end

@testset "named loops and workers configure arbitrary process instances" begin
    requirement = Dict{String,Any}("cpus"=>[7],"policy"=>"fifo","priority"=>73,"count"=>1,"name"=>"camera-worker")
    host = Dict{String,Any}("scheduling"=>Dict{String,Any}("defaults"=>Dict{String,Any}("rt-priority"=>73,"locked-bytes"=>4096),
        "processes"=>Dict{String,Any}("reconstruction"=>Dict{String,Any}("cpus"=>[9,7],"leader-cpu"=>9,
                "workers"=>Dict{String,Any}("julia"=>[9,7]),"data-loops"=>Dict{String,Any}("julia-data-loop"=>[7]),"threads"=>[requirement]),
            "wavefront"=>Dict{String,Any}("cpus"=>[11],"leader-cpu"=>11,"rt-priority"=>0))))
    original=deepcopy(host)
    compiled=E.combine_profile(Dict{String,Any}(),host)
    @test !haskey(compiled,"bindings")
    @test compiled["scheduling"]["processes"]["reconstruction"]["workers"]["julia"] == [9,7]
    @test compiled["placement"]["reconstruction"]["threads"] == [requirement]
    @test compiled["placement"]["wavefront"]["rt-priority"] == 0
    @test !haskey(compiled["placement"]["reconstruction"],"workers")
    @test !haskey(compiled["placement"]["reconstruction"],"data-loops")
    compiled["scheduling"]["processes"]["reconstruction"]["workers"]["julia"][1]=4
    push!(compiled["placement"]["wavefront"]["threads"],requirement)
    @test host == original
    @test isempty(E.combine_profile(Dict{String,Any}(),host)["placement"]["wavefront"]["threads"])
    for field in ("workers","data-loops")
        invalid=deepcopy(host)
        invalid["scheduling"]["processes"]["reconstruction"][field]=Dict{String,Any}("unknown"=>[12])
        @test_throws ArgumentError E.combine_profile(Dict{String,Any}(),invalid)
    end
    invalid=deepcopy(host)
    invalid["scheduling"]["bindings"]=Dict{String,Any}()
    @test_throws ArgumentError E.combine_profile(Dict{String,Any}(),invalid)
end

@testset "bounded YAML loading and exact process roles" begin
    mktempdir() do directory
        portable=joinpath(directory,"profile.yaml")
        host=joinpath(directory,"host.yaml")
        C.write_yaml(portable,Dict{String,Any}("mode"=>"simulation"))
        C.write_yaml(host,host_profile())
        compiled=E.load_profile(portable;host)
        bindings=E.profile_bindings(compiled,"/julia")
        @test bindings == Dict{String,Any}("JULIA"=>"/julia")
        spec()=Dict{String,Any}("owners"=>[])
        @test E.profile!(spec(),compiled,bindings)["placement"] == compiled["placement"]
        for roles in (("core",),("core","rtc","camera"))
            invalid=deepcopy(compiled)
            invalid["placement"]=Dict{String,Any}(role=>deepcopy(compiled["placement"]["core"]) for role in roles)
            @test_throws ArgumentError E.profile!(spec(),invalid,bindings)
        end
        for payload in ("scheduling:\n  processes: {}\n  processes: {}\n", "placement: {}\n",
                "scheduling:\n  bindings: {}\n  processes: {}\n", "mode: hardware\n",
                "- simulation\n",repeat("#",1024*1024+1))
            write(host,payload)
            @test_throws ArgumentError E.load_profile(portable;host)
        end
    end
end
