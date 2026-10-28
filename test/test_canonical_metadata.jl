using Test, JSON, PipeWireAORTC
const IC = PipeWireAORTC.InstrumentConfiguration
const ID = PipeWireAORTC.InstrumentDefinition

@testset "canonical metadata preserves scientific JSON bytes" begin
    document = Dict("scale"=>0.5,"label"=>"SCC",
        "array"=>Any[Dict("z"=>2,"a"=>true),[1,2,3]])
    expected = "{\"array\":[{\"a\":true,\"z\":2},[1,2,3]],\"label\":\"SCC\",\"scale\":0.5}"
    @test JSON.json(IC.canonical(document))==expected
    @test ID.scientific_identity(IC.canonical(document))=="sha256:"*ID.digest(expected)
    @test JSON.json(IC.canonical(Bool[true,false]))==JSON.json((true,false))
    @test JSON.json(IC.canonical(Float32[0.25,-0.5]))==JSON.json((0.25f0,-0.5f0))
end

@testset "full detector mask identity has a length-independent array type" begin
    mask = fill(true,1024^2)
    document = Dict("mask"=>mask,"shape"=>[1024,1024])
    selected = IC.canonical(document)
    isvector = selected.mask isa AbstractVector
    @test isvector
    if isvector
        @test typeof(selected.mask)==typeof(IC.canonical(fill(true,4)))
        # Array values and ordering, rather than their Julia container type,
        # determine the identity. This string is the historical JSON payload.
        expected = "{\"mask\":["*join(fill("true",length(mask)),",")*"],\"shape\":[1024,1024]}"
        @test ID.scientific_identity(selected)=="sha256:"*ID.digest(expected)
        mask[end] = false
        @test ID.scientific_identity(IC.canonical(document))!=ID.scientific_identity(selected)
        @test selected.mask[end] === true
    end
end
