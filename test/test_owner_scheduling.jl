using Test, PipeWireAORTC
const E=PipeWireAORTC.InstrumentExport
function process(workers; leader=3)
    Dict("cpus"=>[2,3],"leader-cpu"=>leader,"workers"=>workers)
end
function owner(kind,role)
    Dict{String,Any}("role"=>role,"kind"=>kind,"environment"=>Dict{String,String}(),
        "argv"=>["/julia","--threads=99,0","-e","opaque-entrypoint","--"])
end
@testset "launcher adapters use explicit kinds and worker roles" begin
    processes=Dict("controller-a"=>process(Dict("julia"=>[3,2])),
        "controller-b"=>Dict("cpus"=>[4,5,6],"leader-cpu"=>4,"workers"=>Dict("julia"=>[4,5,6])),
        "plant"=>process(Dict("pipewire"=>[3],"observation"=>[2])))
    spec=Dict("owners"=>[owner("jfg","controller-a"),owner("jfg","controller-b"),owner("aos","plant")])
    E.prepare_owner_scheduling!(spec,Dict("scheduling"=>Dict("processes"=>processes)))
    a,b,plant=spec["owners"]
    @test !haskey(a,"kind")
    @test "--threads=2,0" in a["argv"]
    @test a["argv"][end-1:end] == ["--pin-cpus","3,2"]
    @test "--threads=3,0" in b["argv"]
    @test b["argv"][end-1:end] == ["--pin-cpus","4,5,6"]
    @test plant["argv"][end-3:end] == ["--pipewire-cpu","3","--observation-cpu","2"]
    @test isempty(plant["environment"])
    @test "--threads=2,0" in plant["argv"]
    for (kind,workers) in (("jfg",Dict("julia"=>[3])),("jfg",Dict("julia"=>[2,3])), ("jfg",Dict("unknown"=>[3,2])),
            ("aos",Dict("observation"=>[2])),("aos",Dict("pipewire"=>[2,3])),
            ("aos",Dict("pipewire"=>[2],"observation"=>[3])),("unknown",Dict()))
        @test_throws ArgumentError E.owner_scheduling!(Val(Symbol(kind)),owner(kind,"instance"),process(workers))
    end
    declared=owner("jfg","instance")
    append!(declared["argv"],["--pin-cpus","3,2"])
    @test_throws ArgumentError E.owner_scheduling!(Val(:jfg),declared,process(Dict("julia"=>[3,2])))
    declared=owner("aos","instance")
    declared["environment"]["PIPEWIREAO_OPTICAL_CPU"]="2"
    @test_throws ArgumentError E.owner_scheduling!(Val(:aos),declared,process(Dict("pipewire"=>[3],"observation"=>[2])))
    missing=owner("jfg","instance")
    delete!(missing,"kind")
    @test_throws ArgumentError E.prepare_owner_scheduling!(Dict("owners"=>[missing]),
        Dict("scheduling"=>Dict("processes"=>Dict("instance"=>process(Dict("julia"=>[3,2]))))))
end
