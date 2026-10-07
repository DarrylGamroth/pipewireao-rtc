using Test
include("qualify_wireplumber_hil.jl")
const W = WirePlumberHILQualification

@testset "coexistence pins declared topology and role owners" begin
    mktempdir() do package
        session = Dict("sources"=>[Dict("node.name"=>"pixels","ownership"=>"external")],
            "graphs"=>[Dict("node.name"=>"graph")],
            "sinks"=>[Dict("node.name"=>"commands","ownership"=>"external")],
            "links"=>[Dict("output"=>"pixels:out","input"=>"graph:in","passive"=>true),
                Dict("output"=>"graph:out","input"=>"commands:in","passive"=>false)])
        W.C.write_json(joinpath(package,"session.conf.in"),session)
        ready=Dict("processes"=>Dict("rtc"=>Dict("pid"=>100),"simulator"=>Dict("pid"=>200)))
        object(id,type,props;extra=Dict())=Dict("id"=>id,"type"=>"PipeWire:Interface:"*type,
            "info"=>merge(Dict("props"=>merge(Dict("object.serial"=>id),props)),extra))
        objects=Any[object(1,"Client",Dict("application.process.id"=>100)),
            object(2,"Client",Dict("application.process.id"=>200)),
            object(3,"Node",Dict("node.name"=>"pixels","client.id"=>2)),
            object(4,"Node",Dict("node.name"=>"graph","client.id"=>1)),
            object(5,"Node",Dict("node.name"=>"commands","client.id"=>2))]
        for (id,node,name,direction) in ((6,3,"out","out"),(7,4,"in","in"),(8,4,"out","out"),(9,5,"in","in"))
            push!(objects,object(id,"Port",Dict("node.id"=>node,"port.name"=>name,"port.direction"=>direction)))
        end
        format=Dict("mediaType"=>"application","mediaSubtype"=>"ndarray","elementType"=>"F32_LE",
            "shape"=>[2],"layout"=>"COLUMN_MAJOR","schema"=>"test/1")
        for (id,onode,oport,inode,iport,passive) in ((10,3,6,4,7,true),(11,4,8,5,9,false))
            push!(objects,object(id,"Link",Dict("client.id"=>1,"link.output.node"=>onode,
                "link.output.port"=>oport,"link.input.node"=>inode,"link.input.port"=>iport,"link.passive"=>passive);
                extra=Dict("output-node-id"=>onode,"output-port-id"=>oport,"input-node-id"=>inode,
                    "input-port-id"=>iport,"state"=>"paused","format"=>format)))
        end
        manifest,required,nodes=W.manifest(objects,ready,package)
        @test length(manifest["objects"])==6
        @test length(nodes)==3
        @test W.verify_links(objects,required)===nothing
        changed=deepcopy(objects);W.properties(changed[end])["link.passive"]=true
        @test_throws ErrorException W.manifest(changed,ready,package)
        changed=deepcopy(objects);W.properties(changed[end])["client.id"]=2
        @test_throws ErrorException W.manifest(changed,ready,package)
        changed=deepcopy(objects);W.properties(changed[4])["client.id"]=2
        @test_throws ErrorException W.manifest(changed,ready,package)
        changed=deepcopy(objects);W.properties(changed[end])["object.serial"]=100
        @test_throws ErrorException W.verify_links(changed,required)
        changed=deepcopy(objects);changed[end]["info"]["state"]="error"
        @test_throws ErrorException W.verify_links(changed,required)
        changed=deepcopy(objects);changed[end]["info"]["format"]["shape"]=[3]
        @test_throws ErrorException W.verify_links(changed,required)
    end
end
