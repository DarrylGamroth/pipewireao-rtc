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
        "plant"=>process(Dict("pipewire"=>[3],"optical-diagnostics"=>[2])))
    spec=Dict("owners"=>[owner("jfg","controller-a"),owner("jfg","controller-b"),owner("aos","plant")])
    E.prepare_owner_scheduling!(spec,Dict("scheduling"=>Dict("processes"=>processes)))
    a,b,plant=spec["owners"]
    @test !haskey(a,"kind")
    @test "--threads=2,0" in a["argv"]
    @test a["argv"][end-1:end] == ["--pin-cpus","3,2"]
    @test "--threads=3,0" in b["argv"]
    @test b["argv"][end-1:end] == ["--pin-cpus","4,5,6"]
    @test plant["argv"][end-3:end] == ["--pipewire-cpu","3","--optical-diagnostics-cpu","2"]
    @test isempty(plant["environment"])
    @test "--threads=2,0" in plant["argv"]
    pupil = owner("aos", "plant")
    E.owner_scheduling!(Val(:aos), pupil,
        process(Dict("pipewire"=>[3], "optical-diagnostics"=>[2], "pupil-output"=>[4])))
    @test "--threads=3,0" in pupil["argv"]
    @test pupil["argv"][end-1:end] == ["--pupil-output-cpu", "4"]
    for cpu in (2, 3)
        @test_throws ArgumentError E.owner_scheduling!(Val(:aos), owner("aos", "plant"),
            process(Dict("pipewire"=>[3], "optical-diagnostics"=>[2], "pupil-output"=>[cpu])))
    end
    for (kind,workers) in (("jfg",Dict("julia"=>[3])),("jfg",Dict("julia"=>[2,3])), ("jfg",Dict("unknown"=>[3,2])),
            ("aos",Dict("optical-diagnostics"=>[2])),("aos",Dict("pipewire"=>[2,3])),
            ("aos",Dict("pipewire"=>[2],"optical-diagnostics"=>[3])),("unknown",Dict()))
        @test_throws ArgumentError E.owner_scheduling!(Val(Symbol(kind)),owner(kind,"instance"),process(workers))
    end
    declared=owner("jfg","instance")
    append!(declared["argv"],["--pin-cpus","3,2"])
    @test_throws ArgumentError E.owner_scheduling!(Val(:jfg),declared,process(Dict("julia"=>[3,2])))
    declared=owner("aos","instance")
    declared["environment"]["PIPEWIREAO_OPTICAL_CPU"]="2"
    @test_throws ArgumentError E.owner_scheduling!(Val(:aos),declared,process(Dict("pipewire"=>[3],"optical-diagnostics"=>[2])))
    missing=owner("jfg","instance")
    delete!(missing,"kind")
    @test_throws ArgumentError E.prepare_owner_scheduling!(Dict("owners"=>[missing]),
        Dict("scheduling"=>Dict("processes"=>Dict("instance"=>process(Dict("julia"=>[3,2]))))))
end

@testset "explicit Julia pins match cold owner arguments and placement" begin
    D=PipeWireAORTC.DeploymentConfiguration
    placement=Dict("cpus"=>[2,3,4],"leader-cpu"=>3)
    declaration=Dict("role"=>"controller","argv"=>["julia","--threads=3,0","--pin-cpus","3,2,4"])
    @test D.validate_owner_pins(declaration,placement) === nothing
    for argv in (["julia","--threads=3,1","--pin-cpus=3,2,4"],
            ["julia","--threads","3,auto","--pin-cpus=3,2,4"],
            ["julia","--threads=1","--pin-cpus=3"],
            ["julia","--threads=3,0","--pin-cpus=3,3,2"], ["unmanaged"])
        @test D.validate_owner_pins(merge(declaration,Dict("argv"=>argv)),placement) === nothing
    end
    for argv in (["julia","--threads=3,0","--pin-cpus","3,2"],
            ["julia","--threads=3,0","--pin-cpus=3,2,5"],
            ["julia","--threads=3,0","--pin-cpus=2,3,4"],
            ["julia","--threads=auto","--pin-cpus=3,2,4"],
            ["julia","--threads=3,0","--pin-cpus=3,2,"],
            ["julia","--threads=3,0","--pin-cpus=3,2,1"],
            ["julia","--threads=3,0","--pin-cpus=3,2,4","--pin-cpus=3,2,4"],
            ["julia","--threads=3,0","--pin-cpus"], ["julia","--pin-cpus=3,2,4"])
        @test_throws D.DeploymentError D.validate_owner_pins(merge(declaration,Dict("argv"=>argv)),placement)
    end
end
