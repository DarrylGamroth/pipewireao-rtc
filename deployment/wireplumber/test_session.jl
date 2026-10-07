using Test
include("session.jl")
const W=WirePlumberSession

@testset "declared formats and shared providers" begin
    port=Dict("element-type"=>"F32_LE","shape"=>[2],"schema"=>"test/1")
    expected=W.declared_format(Dict("rate"=>"500/1"),port)
    @test expected["layout"]=="ROW_MAJOR"
    @test W.verify_format(expected,expected)===nothing
    @test W.verify_format(merge(expected,Dict("rate"=>Dict("num"=>1000,"denom"=>2))),expected)===nothing
    for (key,value) in (("elementType","U16_LE"),("shape",[3]),("schema","other/1"),
            ("layout","COLUMN_MAJOR"),("mediaType","video"),("mediaSubtype","raw"),
            ("rate",Dict("num"=>501,"denom"=>1)),("rate",Dict("num"=>0,"denom"=>1)))
        @test_throws ErrorException W.verify_format(merge(expected,Dict(key=>value)),expected)
    end
    @test_throws ErrorException W.verify_format(filter(v->v.first!="rate",expected),expected)
    parameter=W.declared_format(Dict("rate"=>"500/1"),merge(port,Dict("parameter"=>true)))
    @test !haskey(parameter,"rate")
    @test W.verify_format(parameter,parameter)===nothing
    @test_throws ErrorException W.declared_format(Dict("rate"=>"0/1"),port)

    mktempdir() do package
        specification(name,direction)=merge(port,Dict("name"=>name,"direction"=>direction))
        session=Dict("rate"=>"500/1","sources"=>Any[],"graphs"=>Any[],"sinks"=>Any[],"links"=>Any[])
        object(id,type,props;extra=Dict())=Dict("id"=>id,"type"=>"PipeWire:Interface:"*type,
            "info"=>merge(Dict("props"=>merge(Dict("object.serial"=>id+100),props)),extra))
        objects=Any[object(1,"Client",Dict("application.process.id"=>100)),
            object(2,"Client",Dict("application.process.id"=>200)),
            object(3,"Client",Dict("application.process.id"=>300))]
        for branch in 1:2
            base=branch*20
            for (group,name,ports,node_id,client_id) in (
                    ("sources","pixels-$branch",[specification("out","output")],base,2),
                    ("graphs","graph-$branch",[specification("in","input"),specification("out","output")],base+1,3),
                    ("sinks","commands-$branch",[specification("in","input")],base+2,2))
                push!(session[group],Dict("node.name"=>name,"ownership"=>"external","ports"=>ports))
                push!(objects,object(node_id,"Node",Dict("node.name"=>name,"client.id"=>client_id)))
            end
            for (id,node,name,direction) in ((base+3,base,"out","out"),(base+4,base+1,"in","in"),
                    (base+5,base+1,"out","out"),(base+6,base+2,"in","in"))
                push!(objects,object(id,"Port",Dict("node.id"=>node,"port.name"=>name,"port.direction"=>direction)))
            end
            for (id,output,input,onode,oport,inode,iport,passive) in (
                    (base+7,"pixels-$branch:out","graph-$branch:in",base,base+3,base+1,base+4,true),
                    (base+8,"graph-$branch:out","commands-$branch:in",base+1,base+5,base+2,base+6,false))
                push!(session["links"],Dict("output"=>output,"input"=>input,"passive"=>passive))
                push!(objects,object(id,"Link",Dict("client.id"=>1,"link.output.node"=>onode,
                    "link.output.port"=>oport,"link.input.node"=>inode,"link.input.port"=>iport,"link.passive"=>passive);
                    extra=Dict("output-node-id"=>onode,"output-port-id"=>oport,"input-node-id"=>inode,
                        "input-port-id"=>iport,"state"=>"paused","format"=>expected)))
            end
        end
        W.C.write_json(joinpath(package,"session.conf.in"),session)
        ready=Dict("processes"=>Dict("rtc"=>Dict("pid"=>100),"simulator"=>Dict("pid"=>200),"julia"=>Dict("pid"=>300)))
        arguments,required,nodes=W.manifest(objects,ready,package)
        @test length(nodes)==6
        @test length(required)==4
        @test length(arguments["owners"])==2 # One AOS client supplies both source/sink pairs.
        @test Set(v["pid"] for v in arguments["owners"])==Set([200,300])
        @test W.verify_links(objects,required)===nothing
        unrelated=object(99,"Node",Dict("node.name"=>"optional-observer","client.id"=>2))
        @test W.manifest(vcat(objects,[unrelated]),ready,package)[1]==arguments
        @test W.manifest(objects,ready,package)[1]==arguments # Optional observer absence is non-gating.
        missing=filter(v->v["id"]!=20,objects)
        @test_throws ErrorException W.manifest(vcat(missing,[unrelated]),ready,package)
        duplicate=object(98,"Node",Dict("node.name"=>"pixels-1","client.id"=>2))
        @test_throws ErrorException W.manifest(vcat(objects,[duplicate]),ready,package)
        changed=deepcopy(objects);W.properties(only(v for v in changed if v["id"]==20))["client.id"]=3
        @test_throws ErrorException W.manifest(changed,ready,package)
        changed=deepcopy(objects);only(v for v in changed if v["id"]==27)["info"]["format"]=merge(expected,Dict("schema"=>"other/1"))
        @test_throws ErrorException W.manifest(changed,ready,package)
    end
end
