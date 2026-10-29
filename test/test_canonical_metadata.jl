using Test, JSON, PipeWireAORTC
const IC = PipeWireAORTC.InstrumentConfiguration
const ID = PipeWireAORTC.InstrumentDefinition
const Common = PipeWireAORTC.Common

struct CommandScale
    metres::Float32
end
JSON.lower(scale::CommandScale) = (;metres=scale.metres, units="m OPD")

@testset "sealed metadata preserves JSON lowering and field order" begin
    declarations = (
        (;z=(true, false), a=(;y=0.1f0, x=-0.0)),
        (;empty=(), object=NamedTuple(), scalars=(nothing, missing, :command,
            typemax(UInt64), typemin(Int64), 1//3, 2+3im, "pupil\nα")),
        (;matrix=reshape(Float32[1,2,3,4,5,6],2,3),
            scalar_array=fill(0.1f0), pairs=[:z=>1, :a=>2],
            custom=CommandScale(0.1f0)),
    )
    for declaration in declarations
        expected = JSON.json(declaration)
        @test Common.metadata_json(declaration) == expected
        @test ID.scientific_identity(declaration) == "sha256:" * ID.digest(expected)
        @test IC.json_value(declaration) == Common.parse_json(expected)
    end
end

@testset "physical command arrays have length-independent JSON types" begin
    # A physical mirror's sealed shape-control and sampled-basis declarations.
    n = 2304
    controlled = ntuple(index -> isodd(index), n)
    positions = Tuple((Float32(index)/n, -Float32(index)/n) for index in 1:n)
    samples = Tuple(Float32(index)/n for index in 1:n)
    declaration = (;controlled_actuators=controlled, bases=((;kind="sampled",
        positions, modes=((;name="Command", values=samples),)),))
    expected = "{\"controlled_actuators\":" * JSON.json(collect(controlled)) *
        ",\"bases\":[{\"kind\":\"sampled\",\"positions\":" * JSON.json(collect(positions)) *
        ",\"modes\":[{\"name\":\"Command\",\"values\":" * JSON.json(collect(samples)) * "}]}]}"
    @test Common.metadata_json(declaration) == expected
    @test ID.scientific_identity(declaration) == "sha256:" * ID.digest(expected)
    @test IC.json_value(declaration) == Common.parse_json(expected)
    @test typeof(Common.metadata_json_value(controlled)) == typeof(Common.metadata_json_value((true,false)))
    @test Common.metadata_json_value(declaration).controlled_actuators !== controlled
    @test declaration.controlled_actuators === controlled
end

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
