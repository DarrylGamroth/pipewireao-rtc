# No connect, attach, graph dump, control or main function is called here.
module Final
using Test
include(joinpath(@__DIR__,"native_stream_verification.jl"))
const APPLICATION=get(ENV,"GPI2_OFFLINE_APPLICATION","/tmp/gpi2-controlled-shape-application")
@testset "Fourteen cold native declarations and restored baseline contracts" begin
    @test endswith(ROOT,"gpi2-shape-live-20261025")
    session=D.decode(joinpath(APPLICATION,"rtc/session.conf.in"),PREFIX)
    specs=(M.observation_spec(APPLICATION,session,"simulator-detector-queue-input","detector",PREFIX),)
    for mirror in ("tiptilt","tweeter","woofer")
        specs=(specs...,M.observation_spec(APPLICATION,session,"rtc-"*mirror*"-command-queue-input",mirror,PREFIX))
    end
    for mirror in ("woofer","tweeter"),product in ("applied","correction-role","constraint-feedback","offset","shape-offset")
        specs=(specs...,M.observation_spec(APPLICATION,session,"rtc-"*mirror*"-"*product*"-queue-input",mirror*"-"*product,PREFIX))
    end
    @test length(specs)==14
    @test first(specs).type===UInt16
    @test first(specs).shape==(242,240)
    for mirror in ("woofer","tweeter"),product in ("offset","shape-offset")
        name=mirror*"-"*product
        spec=only(filter(s -> s.name==name,specs))
        @test spec.type===Float32
        @test spec.schema=="pipewireao/requested-pdm-command-f32/1"
        @test spec.shape==(mirror=="woofer" ? 97 : 2304,)
        @test all(iszero,(product=="shape-offset" ? shape_baseline(APPLICATION,mirror) : read_parameter(APPLICATION,name)).data)
    end
    roles,provenance=expected_roles(APPLICATION,"tweeter")
    @test provenance["counts"]==Dict("0"=>588,"1"=>1412,"2"=>304,"3"=>0)
    mask=C.read_json(joinpath(APPLICATION,"instrument.json"))["deformable_mirrors"]["tweeter"]["shape_control"]["controlled_actuators"]
    @test mask==map(==(UInt8(1)),roles)
end
end
module Offset
using Test
include(joinpath(@__DIR__,"native_shape_roundtrip.jl"))
const APPLICATION=get(ENV,"GPI2_OFFLINE_APPLICATION","/tmp/gpi2-controlled-shape-application")
@testset "Controlled physical probe, native codecs, aliases and declared/FITS baselines" begin
    @test endswith(OFFSET_ROOT,"gpi2-shape-live-20261025")
    graph=D.decode(joinpath(APPLICATION,"rtc/graph.conf"),PREFIX)["filter.graph"]
    # Prove that the explicit default baseline needs no startup FITS binding.
    mkpath(joinpath(@__DIR__,"tmp"))
    mktempdir(joinpath(@__DIR__,"tmp")) do unbound
        mkpath(joinpath(unbound,"rtc"))
        for file in ("graph.conf","session.conf.in")
            cp(joinpath(APPLICATION,"rtc",file),joinpath(unbound,"rtc",file))
        end
        @test !isfile(joinpath(unbound,"rtc/parameters.conf"))
        for(m,n) in (("woofer",97),("tweeter",2304))
            baseline=shape_baseline(unbound,m)
            @test size(baseline.data)==(n,)
            @test all(x -> reinterpret(UInt32,x)==UInt32(0),baseline.data)
        end
    end
    for(m,n,selected) in (("woofer",97,1),("tweeter",2304,163))
        selection=controlled_probe(APPLICATION,m,n)
        @test selection["index_one_based"]==selected
        @test selection["index_zero_based"]==selected-1
        original=offset_baseline(APPLICATION,m,n).data
        @test length(original)==n
        @test all(iszero,original)
        probe=copy(original);probe[selected]+=4f-9
        @test count(!iszero,probe.-original)==1
        @test 0<maximum(abs,Float64.(probe).-Float64.(original))<=5e-9
        @test length(A.packed_bytes(probe))==4n
        @test PipeWireAORTC.RunnerCommands.parse(["parameter",GRAPH,m*"-shape-offset","F32_LE",string(n),OFFSET_SCHEMA,"/home/dgamroth/offline-only.bin"])!==nothing
        @test PipeWireAORTC.RunnerCommands.parse(["parameter-generation",GRAPH,m*"-shape"])!==nothing
        alias=only(filter(p -> p["name"]==m*"-shape-offset",graph["inputs"]))
        @test alias["endpoint"]==m*"-shape:shape-offset"
        node=only(filter(p -> p["name"]==m*"-shape",graph["nodes"]))
        @test node["label"]=="vdm-shape-offset-f32"
        @test offset_baseline(APPLICATION,m,n).provenance["origin"]=="VdmShapeOffsetF32 declared zero initialization"
        @test reinterpret(UInt32,original)==reinterpret(UInt32,offset_baseline(APPLICATION,m,n;product="offset").data)
    end
end
end
