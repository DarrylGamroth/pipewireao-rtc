# Shared cold/native physical-command fixture; all matrices and command order are explicit.
function physical_offset_fixture(directory;P,Q,C)
    file=joinpath(directory,"graph.conf")
    write(file,"""
    filter.graph={nodes=[{type=ndarray name=reference label=physical-offset-reference-f32
      config={residual_count=2 physical_count=4 mode_count=2 reference_sign=-1
       residual_schema="$CONTROLLER_RESIDUAL_ERROR_V1" physical_schema="$REQUESTED_PDM_COMMAND_V1"
       physical_to_modes_schema="test.q/1" modes_to_reference_schema="test.c/1"}}]
      links=[]
      inputs=[{name=residual endpoint="reference:reconstructed-residual"}
       {name=offset endpoint="reference:offset"} {name=q endpoint="reference:physical-to-modes"}
       {name=c endpoint="reference:modes-to-reference"}]
      outputs=[{name=compensated endpoint="reference:compensated-residual"}
       {name=physical endpoint="reference:physical-offset"}]}
    """)
    graph=JFG.prepare_graph(file;algorithms=algorithms())
    JFG.replace_parameters!(graph,:q=>Q,:c=>C,:offset=>zeros(Float32,4))
    artifacts=Dict{String,Any}()
    for (name,data) in (("projection",P),("inverse",Q),("reference",C))
        path=joinpath(directory,name*".fits")
        Cal.write_fits(path,data)
        artifacts[name]=Dict("path"=>name*".fits","sha256"=>bytes2hex(sha256(read(path))),
            "axes"=>[2,1],"shape"=>collect(size(data)))
    end
    branches=Dict(string(name)=>Dict("node_name"=>"receive-"*string(name),"schema"=>REQUESTED_PDM_COMMAND_V1,
        "modes"=>[i],"command_limit_m"=>1e-6,"coefficient_limit_m"=>5e-9,"max_age_ns"=>100000000,
        "silence_ns"=>10000000000) for (i,name) in enumerate((:llowfs,:scc)))
    config=merge(artifacts,Dict("version"=>1,"parameter"=>"offset","algorithm"=>"reference",
        "clock_output"=>"compensated","command_limit_m"=>1e-6,"calibration_identity"=>"test-calibration",
        "command_order"=>"test-explicit-order","branches"=>branches,"reference_sign"=>-1))
    path=joinpath(directory,"offsets.yaml")
    Common.write_yaml(path,config)
    return graph,path
end
