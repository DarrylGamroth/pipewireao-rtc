using Test
include("service.jl")
const V=WirePlumberService
length(ARGS)==2 && ARGS[1]=="--deployment" || error("expected --deployment INSTALLED_PACKAGE/deployment.conf")
const PACKAGE=dirname(realpath(ARGS[2]))

@testset "optional observer service boundaries" begin
    @test V.unit_quote("/path with space/100%") == "\"/path with space/100%%\""
    @test V.unit_quote("/path/\$name";argument=true) == "\"/path/\$\$name\""
    @test V.unit_quote("KEY=/path/\$name") == "\"KEY=/path/\$name\""
    @test_throws ErrorException V.path_argument("/tmp/path:other";search=true)
    @test_throws ErrorException V.path_argument("/tmp/path\nother")
    @test_throws ErrorException V.unit_identity("wireplumber.service")
    @test_throws ErrorException V.unit_identity("pipewireao-rtc@bad/name.service")
    @test V.supported_package(PACKAGE,"/opt/pipewireao")["source-owner"]=="simulator"
    spec=Dict("source-owner"=>"simulator","owners"=>[Dict("role"=>"simulator")])
    @test V.verify_supported(spec,Dict("profile"=>"copper"))["source-owner"]=="simulator"
    @test_throws ErrorException V.verify_supported(spec,Dict("profile"=>"classic"))
    @test_throws ErrorException V.verify_supported(merge(spec,Dict("source-owner"=>"heart")),Dict("profile"=>"copper"))
    @test_throws ErrorException V.verify_supported(merge(spec,Dict("owners"=>[Dict("role"=>"simulator"),Dict("role"=>"julia-wfs")])),Dict("profile"=>"copper"))
    @test V.verify_package_owner(getpid(),PACKAGE)===nothing
    mktempdir() do other
        write(joinpath(other,"deployment.conf"),"{}")
        @test_throws ErrorException V.verify_package_owner(getpid(),other)
    end
    locator=V.N.Locator("/tmp/remote","test",UInt32(123),Int64(1))
    @test V.verify_locator_owner(locator,123)
    @test_throws ErrorException V.verify_locator_owner(locator,124)
    @test V.verify_unit_owner(unit->123,"test",123)
    @test_throws ErrorException V.verify_unit_owner(unit->124,"test",123)
    before=Dict("processes"=>Dict("rtc"=>123))
    @test V.verify_cohort(before,before,"uuid","uuid")
    @test_throws ErrorException V.verify_cohort(before,before,"uuid","other")
    @test_throws ErrorException V.verify_cohort(before,Dict("processes"=>Dict("rtc"=>124)),"uuid","uuid")
    config=V.configuration(Dict("objects"=>Any[]),"/tmp/exact remote")
    @test occursin("remote.name = \"/tmp/exact remote\"",config)
    @test !occursin("link-factory",config)
    mktempdir() do dir
        write(joinpath(dir,"wireplumber.conf"),"old cohort")
        @test_throws ErrorException V.prepare(PACKAGE,dir,"pipewireao-rtc@test.service",dir,"/opt/pipewireao";
            inspect=unit->error("inactive RTC"))
        @test !ispath(joinpath(dir,"wireplumber.conf"))
    end
    template=read(joinpath(@__DIR__,"pipewireao-wireplumber@.service.in"),String)
    for expected in ("BindsTo=pipewireao-rtc@%i.service","After=pipewireao-rtc@%i.service",
        "PartOf=pipewireao-rtc@%i.service","Restart=no","Type=simple","KillMode=control-group")
        @test occursin(expected,template)
    end
    @test !occursin("CPUSchedulingPolicy",template)
    @test !occursin("WantedBy",template)
end
