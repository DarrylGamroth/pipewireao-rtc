function physical_inputs_document(directory;P=Float32[1 0;0 1;1 1;1 -1])
    Q=Float32.(pinv(Float64.(P)))
    artifacts=Dict{String,Any}()
    for (name,data) in (("projection",P),("inverse",Q))
        path=joinpath(directory,name*".fits")
        A.write_fits(path,data)
        artifacts[name]=Dict("path"=>name*".fits","sha256"=>C.sha256_file(path),"axes"=>[2,1],"shape"=>collect(size(data)))
    end
    branches=Dict(string(name)=>Dict("node_name"=>"receive-"*string(name),"schema"=>"test.physical/1","modes"=>[i],
        "command_limit_m"=>1e-6,"coefficient_limit_m"=>5e-9,"max_age_ns"=>100,"silence_ns"=>1000,
        "acquisition_version"=>(i==1 ? 2 : 3)) for (i,name) in enumerate((:llowfs,:scc)))
    return merge(artifacts,Dict("version"=>2,"command_limit_m"=>1e-6,"calibration_identity"=>"accepted-calibration",
        "command_order"=>"actual-physical-order","branches"=>branches))
end
