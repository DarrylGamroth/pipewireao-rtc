function composition_fixture(root, name, role, node)
    mkpath(root)
    for filename in ("core.conf", "client.conf")
        C.write_json(joinpath(root, filename), Dict())
    end
    C.write_json(joinpath(root,"session.conf"), Dict("sources"=>[Dict("node.name"=>node)],
        "graphs"=>[],"sinks"=>[],"links"=>[],"parameters"=>Dict(),"observations"=>[]))
    write(joinpath(root,"graph.conf"), "{}")
    owner=Dict("role"=>role,"bootstrap-protocol"=>"pipewireao.rtc.owner-bootstrap/1",
        "bootstrap-node"=>node*"-bootstrap","control-protocol"=>"pipewireao.source-control/1",
        "control-node"=>node*"-source","environment"=>Dict(),
        "argv"=>["julia","--threads=2,0","--project=@PACKAGE@","@PACKAGE@/entry.jl",
            "--bootstrap-node",node*"-bootstrap","--bootstrap-instance",
            "@"*D.bootstrap_instance_key(role)*"@","--control-node",node*"-source",
            "--remote","@RUNTIME@/@REMOTE@"])
    roles=["core","rtc",role]
    spec=Dict("version"=>1,"name"=>name,"session"=>"session.conf","core"=>"core.conf",
        "client"=>Dict(role=>"client.conf" for role in roles),"owners"=>[owner],
        "source-owner"=>role,"node-owners"=>Dict(node=>role),"environment"=>Dict(),
        "artifacts"=>Dict(),"cpu-latency-us"=>nothing,
        "placement"=>Dict(role=>Dict("cpus"=>[2],"leader-cpu"=>2,"rt-priority"=>0,
            "threads"=>[],"locked-bytes"=>0) for role in roles))
    C.write_json(joinpath(root,"deployment.conf"),spec)
    E.seal!(root)
    return root
end
