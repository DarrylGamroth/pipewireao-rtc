# Cold checks: no services, native connections, or process mutations.
using Test, PipeWireAO, PipeWireAORTC
include("managed_session_lifecycle.jl")
const Managed = ManagedSessionLifecycle

@testset "managed observer reads declared queue contracts" begin
    mktempdir() do application
        mkpath(joinpath(application,"rtc"))
        descriptions = (("camera",UInt16,"U16_LE",[242,240]),
            ("low",Float32,"F32_LE",[97]),("high",Float32,"F32_LE",[2304]),
            ("ramp",Float32,"F32_LE",[2]),("role",UInt8,"U8",[2304]))
        modules, sinks = [], []
        for (name,element,wire,shape) in descriptions
            push!(modules,Dict("name"=>"libpipewire-module-queue","args"=>Dict(
                "capture.props"=>Dict("node.name"=>name*"-in"),
                "playback.props"=>Dict("node.name"=>name*"-out","media.name"=>name))))
            push!(sinks,Dict("node.name"=>name*"-in","ports"=>[
                Dict("element-type"=>wire,"shape"=>shape,"schema"=>"test/"*name,"rate"=>"2000/1")]))
        end
        Managed.C.write_json(joinpath(application,"rtc/core.conf"),Dict("context.modules"=>modules))
        session = Dict("sinks"=>sinks)
        for (name,element,wire,shape) in descriptions
            product = Managed.observation_spec(application,session,name*"-in",name,"/unused-prefix")
            @test product.type === element
            @test product.shape == Tuple(shape)
            @test product.node == name*"-out"
            @test product.media == name
            @test product.schema == "test/"*name
            @test product.rate == SPA.Fraction(2000,1)
        end
        @test_throws ArgumentError Managed.observation_spec(application,session,"missing","missing","/unused-prefix")
    end
end

@testset "managed coherent command observations require full identity" begin
    domain = AcquisitionDomain(ntuple(i -> UInt8(i),PipeWireAO.ACQUISITION_DOMAIN_SIZE))
    other_domain = AcquisitionDomain(ntuple(i -> UInt8(i+1),PipeWireAO.ACQUISITION_DOMAIN_SIZE))
    first = AcquisitionIdentity(domain,UInt64(1),UInt64(1))
    second = AcquisitionIdentity(domain,UInt64(1),UInt64(2))
    foreign = AcquisitionIdentity(other_domain,UInt64(1),UInt64(2))
    future = AcquisitionIdentity(domain,UInt64(2),UInt64(2))
    complete = ((identities=[first,second],),(identities=[second],),
        (identities=[first,second],),(identities=[second],))
    @test Managed.common_identity(complete) == second
    @test Managed.common_identity(complete;after_sequence=1) == second
    @test Managed.common_identity(complete;after_sequence=2) === nothing
    for identity in (first,foreign,future,nothing)
        incomplete = (complete[1:3]...,(identities=[identity],))
        # The third named command must agree; a shared integer sequence is insufficient.
        @test Managed.common_identity(incomplete;after_sequence=1) === nothing
    end
end
