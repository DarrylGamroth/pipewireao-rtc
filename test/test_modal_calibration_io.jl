using Test, PipeWireAORTC
const K=PipeWireAORTC.InstrumentCalibration
const A=PipeWireAORTC.Artifacts

@testset "first-order low-pass temporal coefficient preparation" begin
    # Evaluate the returned transfer polynomial independently of filter design.
    response(c, frequency, rate) = begin
        z = cis(-2π*frequency/rate)
        (c[1]+c[2]*z+c[3]*z^2)/(1+c[4]*z+c[5]*z^2)
    end
    for T in (Float32,Float64), (cutoff,rate) in ((25,1000),(125,1000),(400,1000),(1,500))
        c = K.lowpass_coefficients(T;cutoff_frequency_hz=cutoff,sample_rate_hz=rate)
        @test c isa Vector{T}
        @test length(c)==5 && c[3]==c[5]==0
        @test abs(c[4])<1
        @test response(c,0,rate) ≈ 1 rtol=4eps(T)
        @test abs(response(c,cutoff,rate)) ≈ inv(sqrt(2)) rtol=16eps(T)
        @test abs(response(c,rate/2,rate)) < 8eps(T)
        complement = [1-c[1], c[4]-c[2], c[5]-c[3], c[4], c[5]]
        for frequency in range(0,rate/2;length=19)
            @test response(c,frequency,rate)+response(complement,frequency,rate) ≈ 1 atol=8eps(T)
        end
    end
    for T in (Float32,Float64)
        for cutoff in (-1,0,500,501,Inf,-Inf,NaN,true,"25")
            @test_throws ArgumentError K.lowpass_coefficients(T;cutoff_frequency_hz=cutoff,sample_rate_hz=1000)
        end
        for rate in (-1,0,50,Inf,-Inf,NaN,true,"1000")
            @test_throws ArgumentError K.lowpass_coefficients(T;cutoff_frequency_hz=25,sample_rate_hz=rate)
        end
        @test_throws ArgumentError K.lowpass_coefficients(T;cutoff_frequency_hz=1e-30,sample_rate_hz=1000)
    end
    @test_throws ArgumentError K.lowpass_coefficients(Float32;cutoff_frequency_hz=prevfloat(500.0),sample_rate_hz=1000)
    @test abs(K.lowpass_coefficients(Float64;cutoff_frequency_hz=prevfloat(500.0),sample_rate_hz=1000)[4])<1
end

@testset "bounded optional temporal recipe and declared cadence" begin
    absent = K._tiptilt_temporal(Dict(),0.001)
    @test absent.coefficients == Float32[1,0,0,0,0]
    @test absent.description == Dict("frame_period_s"=>0.001,"sample_rate_hz"=>1000.0,
        "tiptilt"=>Dict("kind"=>"identity"))
    recipe = Dict("temporal"=>Dict("tiptilt"=>Dict("kind"=>"lowpass","cutoff_frequency_hz"=>25)))
    prepared = K._tiptilt_temporal(recipe,0.001)
    @test prepared.coefficients == K.lowpass_coefficients(Float32;cutoff_frequency_hz=25,sample_rate_hz=1000)
    @test prepared.description["tiptilt"] == recipe["temporal"]["tiptilt"]
    @test prepared.description["sample_rate_hz"] == 1000
    for temporal in (nothing,25,Dict(),Dict("modal"=>Dict()),
            Dict("tiptilt"=>nothing), Dict("tiptilt"=>Dict()),
            Dict("tiptilt"=>Dict("kind"=>"lowpass")),
            Dict("tiptilt"=>Dict("kind"=>"identity","cutoff_frequency_hz"=>25)),
            Dict("tiptilt"=>Dict("kind"=>"lowpass","cutoff_frequency_hz"=>25,"order"=>1)),
            Dict("tiptilt"=>Dict("kind"=>"lowpass","cutoff_frequency_hz"=>25),"sample_rate_hz"=>1000))
        @test_throws ArgumentError K._tiptilt_temporal(Dict("temporal"=>temporal),0.001)
    end
    for period in (0,-1,Inf,NaN,true,"0.001",nextfloat(0.0))
        @test_throws ArgumentError K._tiptilt_temporal(recipe,period)
    end
end

@testset "calibration FITS preserves non-square and coefficient-bank axes" begin
    mktempdir() do directory
        for shape in ((3,7),(5,2,3),(9,))
            values=reshape(Float32.(1:prod(shape)),shape)
            path=joinpath(directory,"coefficients.fits")
            K.write_fits(path,values)
            artifact=A.FITSArtifact(path;axes=reverse(ntuple(identity,length(shape))))
            @test A.prepare(artifact,Float32,shape).data==values
        end
    end
end

@testset "shape calibration aliases track completion dimensions and owned values" begin
    for prefix in ("","mirror-")
        key(suffix)=Symbol(prefix*suffix)
        parameters=Dict{Symbol,Array{Float32}}(
            key("active-to-full")=>Float32[1 0;0 1;0.5 0.5],
            key("pdm-to-vdm")=>Float32[1 0 0;0 1 0;0 0 1],
            key("shape-active-to-full")=>zeros(Float32,3,1),
            key("shape-pdm-to-vdm")=>zeros(Float32,3,3),
            key("shape-offset")=>fill(1f0,3))
        @test K.initialize_shape_offsets!(parameters,prefix)===parameters
        for (alias,source) in (("shape-active-to-full","active-to-full"),("shape-pdm-to-vdm","pdm-to-vdm"))
            @test parameters[key(alias)]==parameters[key(source)]
            @test parameters[key(alias)]!==parameters[key(source)]
        end
        @test all(iszero,parameters[key("shape-offset")])
        delete!(parameters,key("shape-offset"))
        @test K.initialize_shape_offsets!(parameters,prefix)===parameters
        @test !haskey(parameters,key("shape-offset"))
        delete!(parameters,key("shape-pdm-to-vdm"))
        @test_throws ArgumentError K.initialize_shape_offsets!(parameters,prefix)
    end
    absent=Dict{Symbol,Array{Float32}}()
    @test K.initialize_shape_offsets!(absent)===absent && isempty(absent)
    parameters=Dict{Symbol,Array{Float32}}(Symbol("pdm-to-vdm")=>Float32[1 0 0;0 1 0;0 0 1],
        Symbol("shape-active-to-full")=>zeros(Float32,3,1),
        Symbol("shape-pdm-to-vdm")=>zeros(Float32,3,3),Symbol("shape-offset")=>fill(1f0,3))
    completion=Float32[1 0;0 1;0.5 0.5]
    K.allocation_parameters(parameters,completion,[1,2];measurement_count=4)
    @test parameters[Symbol("shape-active-to-full")]==completion
    @test all(iszero,parameters[Symbol("shape-offset")])
end
