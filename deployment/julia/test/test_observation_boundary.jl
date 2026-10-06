using Test, PipeWireAODeployment, PipeWireAO, JSON3
const O = PipeWireAODeployment.ObservationBoundary

struct RegistryFixture
    objects::Vector{NamedTuple}
end
function PipeWireAO.find_globals(registry::RegistryFixture; interface, properties)
    filter(object->object.interface == interface &&
        all(pair->get(object.properties,first(pair),nothing) == last(pair),properties),registry.objects)
end
global_fixture(id,interface,properties) = (;id=UInt32(id),interface="PipeWire:Interface:"*interface,properties)

@testset "sparse registry globals discover queue without private owner properties" begin
    registry = RegistryFixture(NamedTuple[
        global_fixture(10,"Node",Dict("node.name"=>"detector","object.serial"=>"42")),
        global_fixture(20,"Node",Dict("node.name"=>O.INPUT_NAME,"object.serial"=>"52")),
        global_fixture(30,"Node",Dict("node.name"=>O.OUTPUT_NAME,"object.serial"=>"62")),
        global_fixture(11,"Port",Dict("node.id"=>"10","port.direction"=>"out","port.name"=>"output_1","object.serial"=>"43")),
        global_fixture(21,"Port",Dict("node.id"=>"20","port.direction"=>"in","object.serial"=>"53"))])
    @test map(object->object.id,O.endpoints(registry,"detector",UInt32(10),"42")) == UInt32.((10,11,20,21,30))
end

mutable struct LinkObservation
    info::Union{Nothing,LinkInfo}
    passive::Bool
    failure::Union{Nothing,String}
end

@testset "passive evidence survives public state-only link deltas" begin
    update(mask,state,properties) = LinkInfo(UInt32(1),UInt32(10),UInt32(11),UInt32(20),UInt32(21),
        mask,state,nothing,nothing,properties)
    observed = LinkObservation(nothing,false,nothing)
    O.observe_link!(observed,update(PipeWireAO.LINK_CHANGE_STATE|PipeWireAO.LINK_CHANGE_PROPERTIES,
        PipeWireAO.LINK_STATE_INIT,Dict("link.passive"=>"true")))
    O.observe_link!(observed,update(PipeWireAO.LINK_CHANGE_STATE,PipeWireAO.LINK_STATE_PAUSED,Dict{String,String}()))
    @test observed.passive && observed.failure === nothing
    @test observed.info.state == PipeWireAO.LINK_STATE_PAUSED
    O.observe_link!(observed,update(PipeWireAO.LINK_CHANGE_FORMAT,PipeWireAO.LINK_STATE_INIT,Dict{String,String}()))
    @test observed.passive && observed.info.state == PipeWireAO.LINK_STATE_PAUSED
    O.observe_link!(observed,update(PipeWireAO.LINK_CHANGE_PROPERTIES,PipeWireAO.LINK_STATE_INIT,Dict("link.passive"=>"false")))
    @test !observed.passive && observed.failure !== nothing
    missing = LinkObservation(nothing,false,nothing)
    O.observe_link!(missing,update(PipeWireAO.LINK_CHANGE_STATE,PipeWireAO.LINK_STATE_PAUSED,Dict{String,String}()))
    @test !missing.passive
    O.observe_link!(missing,update(PipeWireAO.LINK_CHANGE_PROPERTIES,PipeWireAO.LINK_STATE_INIT,Dict{String,String}()))
    @test !missing.passive && missing.failure !== nothing
end

@testset "detector boundary exact identities and passive link" begin
    nodes = NamedTuple[global_fixture(10,"Node",Dict("node.name"=>"detector","object.serial"=>"42")),
        global_fixture(20,"Node",Dict("node.name"=>O.INPUT_NAME,"object.serial"=>"52")),
        global_fixture(30,"Node",Dict("node.name"=>O.OUTPUT_NAME,"object.serial"=>"62")),
        global_fixture(11,"Port",Dict("node.id"=>"10","port.direction"=>"out","port.name"=>"output_1","object.serial"=>"43")),
        global_fixture(21,"Port",Dict("node.id"=>"20","port.direction"=>"in","port.name"=>"input","object.serial"=>"53"))]
    registry = RegistryFixture(nodes)
    candidates = O.endpoints(registry,"detector",UInt32(10),"42")
    @test map(object->object.id,candidates) == UInt32.((10,11,20,21,30))
    @test_throws ErrorException O.endpoints(registry,"detector",UInt32(12),"42")
    @test_throws ErrorException O.endpoints(registry,"detector",UInt32(10),"43")
    # Capture copied candidates, then simulate each ID being reused while
    # awaiting asynchronous NodeInfo or link state. Output is fenced too.
    for index in eachindex(nodes)
        original = nodes[index]
        properties = copy(original.properties)
        properties["object.serial"] = "replacement"
        nodes[index] = global_fixture(original.id,replace(original.interface,"PipeWire:Interface:"=>""),properties)
        @test_throws ErrorException O.fence_endpoints(registry,candidates,"detector",UInt32(10),"42")
        nodes[index] = original
    end
    @test O.fence_endpoints(registry,candidates,"detector",UInt32(10),"42") == candidates
    push!(nodes,nodes[1])
    @test_throws ErrorException O.endpoints(registry,"detector",UInt32(10),"42")
    pop!(nodes)
    pop!(nodes)
    @test O.endpoints(registry,"detector",UInt32(10),"42") === nothing
    props = O.passive_link_properties(UInt32(10),UInt32(11),UInt32(20),UInt32(21))
    @test props == Dict("link.output.node"=>"10","link.output.port"=>"11",
        "link.input.node"=>"20","link.input.port"=>"21","link.passive"=>"true","object.linger"=>"false")
    @test_throws ArgumentError O.connect("unused","detector",UInt32(10),"42";deadline=Inf)
    @test_throws ArgumentError O.connect("unused","detector",UInt32(10),"42";deadline=0.0)
end

@testset "bound node owner properties are gated and survive state deltas" begin
    observed = LinkObservation(nothing,false,nothing)
    input = O.WatchedNode(UInt32(20),"52",O.INPUT_NAME,nothing,nothing)
    output = O.WatchedNode(UInt32(30),"62",O.OUTPUT_NAME,nothing,nothing)
    update(id,mask,properties) = NodeInfo(UInt32(id),UInt32(1),UInt32(1),mask,
        UInt32(1),UInt32(1),PipeWireAO.NODE_STATE_IDLE,nothing,properties,PipeWireAO.ParamInfo[])
    function properties(watched)
        result = Dict("node.name"=>watched.name,"object.serial"=>watched.serial,
            "pipewireao.queue.id"=>"module-owned")
        watched.name == O.OUTPUT_NAME && (result["device.api"] = "pipewireao.queue")
        return result
    end
    @test !O.queue_identity(input.properties,output.properties)
    O.observe_node!(observed,input,update(20,PipeWireAO.NODE_CHANGE_STATE,Dict{String,String}()))
    @test input.properties === nothing
    O.observe_node!(observed,input,update(20,PipeWireAO.NODE_CHANGE_PROPERTIES,properties(input)))
    @test !O.queue_identity(input.properties,output.properties)
    O.observe_node!(observed,output,update(30,PipeWireAO.NODE_CHANGE_PROPERTIES,properties(output)))
    @test O.queue_identity(input.properties,output.properties)
    @test !haskey(input.properties,"device.api") # Actual exported capture has no output-only tag.
    O.observe_node!(observed,output,update(30,PipeWireAO.NODE_CHANGE_STATE,Dict{String,String}()))
    @test O.queue_identity(input.properties,output.properties)
    @test observed.failure === nothing
    mismatched = properties(output)
    mismatched["pipewireao.queue.id"] = "another-module"
    O.observe_node!(observed,output,update(30,PipeWireAO.NODE_CHANGE_PROPERTIES,mismatched))
    @test_throws ErrorException O.queue_identity(input.properties,output.properties)
    O.observe_node!(observed,output,update(30,PipeWireAO.NODE_CHANGE_PROPERTIES,Dict{String,String}()))
    @test observed.failure !== nothing # Full empty properties are not prior evidence.
    for (id,serial) in ((31,"62"),(30,"new-incarnation"))
        failed = LinkObservation(nothing,false,nothing)
        metadata = properties(output)
        metadata["object.serial"] = serial
        O.observe_node!(failed,output,update(id,PipeWireAO.NODE_CHANGE_PROPERTIES,metadata))
        @test failed.failure !== nothing
    end
end

mutable struct OptionalResource
    closes::Int
end
Base.close(resource::OptionalResource) = (resource.closes += 1; nothing)
O.failure(::OptionalResource) = "optional queue disappeared"

@testset "optional cleanup retains deployment admission" begin
    D = PipeWireAODeployment.Deployment
    resource = OptionalResource(0)
    record = Dict{String,Any}("admitted"=>true,"phase"=>"running","error"=>nothing)
    runner = D.DeploymentRunner((;),"",Dict{String,Any}(),Dict{String,String}(),Set{Int}(),
        Tuple{String,Base.Process}[],IdDict{Base.Process,Int}(),nothing,nothing,nothing,nothing,
        nothing,nothing,nothing,nothing,0,"running",false,false,false,nothing,record,nothing,resource,nothing)
    D.close_observation!(runner)
    D.close_observation!(runner)
    @test resource.closes == 1
    @test runner.observation_boundary === nothing
    @test record["admitted"] && record["phase"] == "running" && record["error"] === nothing
    @test !runner.source_failed && runner.source_state == "running"
    @test D.prepare_observation!(runner) === nothing
    mktempdir() do directory
        runner.state_path = joinpath(directory,"state.json")
        runner.observation_boundary = OptionalResource(0)
        D.observe_boundary!(runner)
        persisted = JSON3.read(read(runner.state_path,String),Dict{String,Any})
        @test persisted["detector-observation"]["state"] == "unavailable"
        @test persisted["detector-observation"]["error"] == "optional queue disappeared"
        @test persisted["admitted"] && persisted["phase"] == "running" && persisted["error"] === nothing
        @test runner.observation_boundary === nothing && !runner.source_failed
    end
end
