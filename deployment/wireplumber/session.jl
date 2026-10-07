module WirePlumberSession
using PipeWireAODeployment
const D=PipeWireAODeployment.Deployment
const C=PipeWireAODeployment.Common
require(value,message)=value || error(message)

function registry(remote; prefix="/opt/pipewireao")
    paths=D.installed_paths(prefix)
    result=C.run_checked([joinpath(prefix,"bin/pwao-dump"),"-r",remote];
        env=Dict("LD_LIBRARY_PATH"=>paths["library"]),timeout=10,maximum_output_bytes=4*1024*1024)
    require(result.returncode==0,"AO registry inspection failed: $(result.stderr)")
    C.parse_json(result.stdout)
end
properties(object) = object["info"]["props"]
identity(object) = (object["id"], properties(object)["object.serial"])
links(objects) = filter(object -> object["type"] == "PipeWire:Interface:Link", objects)
function verify_links(objects, original)
    actual = links(objects)
    require(Set(identity.(actual)) == Set(identity.(original)), "Runtime link cohort changed")
    for previous in original
        current = only(filter(object -> identity(object) == identity(previous), actual))
        require(current["info"]["state"] in ("active", "paused"), "Runtime link is not negotiated")
        require(current["info"]["format"] == previous["info"]["format"], "Negotiated format changed")
        require(properties(current)["client.id"] == properties(previous)["client.id"], "Link owner changed")
    end
end

function manifest(objects, ready, package; prefix="/opt/pipewireao")
    session = D.decode(joinpath(package,"session.conf.in"),prefix)
    names = Set(v["node.name"] for group in ("sources","graphs","sinks") for v in session[group])
    nodes = filter(object -> object["type"] == "PipeWire:Interface:Node" &&
        get(properties(object),"node.name",nothing) in names, objects)
    require(length(nodes)==length(names) && Set(properties(object)["node.name"] for object in nodes) == names,
        "Declared nodes were not discovered exactly")
    clients = Dict(object["id"] => properties(object) for object in objects
        if object["type"] == "PipeWire:Interface:Client")
    expected_pids = Dict(v["node.name"] => ready["processes"][
        group=="graphs" && get(v,"ownership",nothing)=="external" ? "julia" :
        group in ("sources","sinks") && get(v,"ownership",nothing)=="external" ? "simulator" : "rtc"]["pid"]
        for group in ("sources","graphs","sinks") for v in session[group])
    for object in nodes
        pid = clients[properties(object)["client.id"]]["application.process.id"]
        require(pid == expected_pids[properties(object)["node.name"]], "Endpoint belongs to the wrong role owner")
    end
    required = links(objects)
    require(length(required) == length(session["links"]), "Unexpected runtime link count")
    node_ids = Dict(properties(v)["node.name"]=>v["id"] for v in nodes)
    ports = filter(v->v["type"]=="PipeWire:Interface:Port",objects)
    function endpoint(value, direction)
        name,port_name=split(value,':';limit=2)
        node=node_ids[name]
        port=only(filter(v->properties(v)["node.id"]==node &&
            properties(v)["port.name"]==port_name && properties(v)["port.direction"]==direction,ports))
        return node,port["id"]
    end
    declared=Set((endpoint(v["output"],"out")...,endpoint(v["input"],"in")...,get(v,"passive",false))
        for v in session["links"])
    observed=Set((v["info"]["output-node-id"],v["info"]["output-port-id"],
        v["info"]["input-node-id"],v["info"]["input-port-id"],
        string(get(properties(v),"link.passive",false))=="true") for v in required)
    require(declared==observed,"Runtime links differ from declared endpoints or passive policy")
    entries = Any[]
    port_entries = Dict{Int,Any}()
    for object in required
        require(clients[properties(object)["client.id"]]["application.process.id"]==ready["processes"]["rtc"]["pid"],
            "Link is not owned by the RTC runner")
        require(object["info"]["state"] in ("active","paused"), "Link negotiation incomplete")
        info = object["info"]
        require(info["format"]["mediaSubtype"] == "ndarray", "Non-NDArray link")
        for direction in ("output","input")
            port = only(filter(v -> v["id"] == info[direction*"-port-id"], objects))
            require(port["type"] == "PipeWire:Interface:Port", "Link endpoint is not a port")
            entry=Dict("role"=>"port-$(port["id"])","kind"=>"port",
                "id"=>port["id"],"serial"=>properties(port)["object.serial"],
                "node"=>info[direction*"-node-id"],"direction"=>direction,"format"=>info["format"])
            if haskey(port_entries,port["id"])
                require(port_entries[port["id"]]==entry,"Shared port has inconsistent contracts")
            else
                port_entries[port["id"]]=entry
                push!(entries,entry)
            end
        end
        push!(entries,Dict("role"=>"link-$(object["id"])","kind"=>"link",
            "id"=>object["id"],"serial"=>properties(object)["object.serial"],
            "properties"=>Dict(key=>properties(object)[key] for key in
                ("link.output.node","link.output.port","link.input.node","link.input.port","client.id"))))
    end
    return Dict("objects"=>entries),required,nodes
end

end
