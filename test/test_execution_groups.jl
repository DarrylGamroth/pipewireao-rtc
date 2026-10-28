using Test, PipeWireAORTC
const D = PipeWireAORTC.DeploymentConfiguration

function execution_group_document()
    branches = ("llowfs","scc")
    graphs = [Dict("node.name"=>name,"ownership"=>"external","run-control"=>"session")
        for name in ("gpi2-jfg-frame-graph","cal2-llowfs-controller","cal2-scc-controller")]
    sources = [Dict("node.name"=>name,"ownership"=>"external")
        for name in ("simulator-wfs","simulator-pupil-output","cal2-llowfs","cal2-scc")]
    sinks = [Dict("node.name"=>name,"ownership"=>"external")
        for name in ("cal2-pupil-input","gpi2-cal2-llowfs-offset","gpi2-cal2-scc-offset")]
    groups = [Dict("name"=>graph["node.name"],"nodes"=>[graph["node.name"]]) for graph in graphs]
    links = [Dict{String,Any}("output"=>"simulator-wfs:out_$i","input"=>"gpi2-jfg-frame-graph:in_$i","passive"=>true)
        for i in 1:31]
    append!(links,[Dict("output"=>"cal2-$branch:output_1","input"=>"cal2-$branch-controller:image","passive"=>true)
        for branch in branches])
    push!(links,Dict("output"=>"simulator-pupil-output:output_1","input"=>"cal2-pupil-input:input_1"))
    append!(links,[Dict("output"=>"cal2-$branch-controller:physical-offset","input"=>"gpi2-cal2-$branch-offset:input_1")
        for branch in branches])
    return Dict{String,Any}("sources"=>sources,"graphs"=>graphs,"sinks"=>sinks,
        "links"=>links,"execution-groups"=>groups)
end

@testset "native execution-group admission is available before owner startup" begin
    document = execution_group_document()
    @test D.validate_execution_groups(document) === nothing
    @test length(document["links"]) == 36 && length(document["execution-groups"]) == 3
    @test D.validate_execution_groups(Dict("graphs"=>[],"links"=>[])) === nothing
    invalid = deepcopy(document);resize!(invalid["execution-groups"],1)
    failure = try D.validate_execution_groups(invalid); nothing catch problem; problem end
    @test failure isa D.DeploymentError
    @test occursin("has no execution group: cal2-",sprint(showerror,failure))
    invalid = deepcopy(document);invalid["links"][32]["passive"] = false
    failure = try D.validate_execution_groups(invalid); nothing catch problem; problem end
    @test failure isa D.DeploymentError
    @test occursin("passive boundary: cal2-llowfs:output_1",sprint(showerror,failure))
    for mutate! in (
            d->empty!(d["execution-groups"]),
            d->(d["execution-groups"][2]["name"]=d["execution-groups"][1]["name"]),
            d->push!(d["execution-groups"][2]["nodes"],"absent"),
            d->push!(d["execution-groups"][2]["nodes"],"gpi2-jfg-frame-graph"),
            d->push!(d["execution-groups"][2]["nodes"],"cal2-pupil-input"),
            d->empty!(d["execution-groups"][2]["nodes"]),
            d->delete!(d["graphs"][2],"run-control"),
            d->(d["graphs"][2]["run-control"]="application"),
            d->(d["sources"][1]["run-control"]="session"),
            d->(d["graphs"][2]["ownership"]="other"),
            d->(d["links"][1]["passive"]=false),
            d->(d["links"][34]["passive"]=true),
            d->push!(d["links"],Dict("output"=>"gpi2-jfg-frame-graph:out","input"=>"cal2-scc-controller:image")))
        invalid = deepcopy(document);mutate!(invalid)
        @test_throws D.DeploymentError D.validate_execution_groups(invalid)
    end
    invalid = deepcopy(document)
    invalid["graphs"][2]["factory"] = "api.ndarray.latest-hold"
    @test_throws D.DeploymentError D.validate_execution_groups(invalid)
    # External application-owned products do not acquire session control.
    external = deepcopy(document)
    external["graphs"][2]["run-control"] = "application"
    deleteat!(external["execution-groups"],2)
    external["links"][32]["passive"] = false
    @test D.validate_execution_groups(external) === nothing
end
