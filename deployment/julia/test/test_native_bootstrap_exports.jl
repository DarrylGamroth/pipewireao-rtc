using Test, PipeWireAODeployment

@testset "exported bootstrap descriptors pass the strict deployment profile" begin
    D = PipeWireAODeployment.DeploymentConfiguration
    H = PipeWireAODeployment.HILExport
    C = PipeWireAODeployment.Common
    mktempdir() do root
        asset = joinpath(root,"fixture.conf")
        write(asset,"{}\n")
        legacy = Dict{String,Any}("role"=>"julia","environment"=>Dict("OPENBLAS_NUM_THREADS"=>"1"),
            "argv"=>["julia","--threads=2,0","--project=@PACKAGE@/jfg/deployment",
                "@PACKAGE@/jfg/deployment/run_island.jl","--session-run-control","--remote","@REMOTE@",
                "--graph","@RUNTIME@/graph.conf","--pin-cpus","14,10"])
        for (flag,key) in H.LEGACY_BOOTSTRAP_FLAGS
            legacy[key] = "julia." * key
            append!(legacy["argv"],[flag,"@RUNTIME@/julia." * key])
        end
        source = H.bind_bootstrap_owner!(Dict{String,Any}("role"=>"simulator","environment"=>H.simulator_environment("cpu"),
            "argv"=>["julia","--threads=2,0","--project=@PACKAGE@/hil","@PACKAGE@/hil/simulator.jl",
                "--remote","@RUNTIME@/@REMOTE@","--control-node","simulator-wfs","--profile","classic"],
            "control-protocol"=>"pipewireao.source-control/1","control-node"=>"simulator-wfs"))
        placement = Dict("cpus"=>[6,14],"leader-cpu"=>6,"rt-priority"=>0,"threads"=>Any[],"locked-bytes"=>0)
        roles = ["core","rtc","julia","simulator"]
        value = Dict{String,Any}("version"=>1,"name"=>"bootstrap-export-fixture",
            "session"=>"fixture.conf","core"=>"fixture.conf","source-owner"=>"simulator",
            "client"=>Dict(role=>"fixture.conf" for role in roles),
            "placement"=>Dict(role=>deepcopy(placement) for role in roles),
            "owners"=>[legacy,source],"environment"=>Dict(),"artifacts"=>Dict("fixture.conf"=>C.sha256_file(asset)),
            "cpu-latency-us"=>nothing)
        path = joinpath(root,"deployment.conf")
        C.write_json(path,value)
        @test_throws D.DeploymentError D.profile(path,"/opt/pipewireao")
        @test D.profile(path,"/opt/pipewireao";legacy_export_input=true)["owners"][1]["prepared"] == "julia.prepared"
        original_hash = C.sha256_file(path)
        H.upgrade_legacy_julia_owner!(legacy)
        for role in ("julia","simulator")
            H.bootstrap_placement!(value["placement"][role])
        end
        C.write_json(path,value)
        selected = D.profile(path,"/opt/pipewireao")
        @test C.sha256_file(path) != original_hash
        @test all(D.native_bootstrap,selected["owners"])
        @test D.native_source(selected["owners"][2])
        @test selected["owners"][2]["bootstrap-node"] != selected["owners"][2]["control-node"]
        for owner in selected["owners"]
            @test !any(haskey(owner,key) for (_,key) in H.LEGACY_BOOTSTRAP_FLAGS)
            @test owner["argv"][findfirst(==("--bootstrap-instance"),owner["argv"])+1] ==
                "@" * D.bootstrap_instance_key(owner["role"]) * "@"
        end
        for role in ("julia","simulator")
            requirement = only(selected["placement"][role]["threads"])
            @test requirement["name"] == "rtc-bootstrap" && requirement["policy"] == "other" && requirement["cpus"] == [6]
        end
    end
end
