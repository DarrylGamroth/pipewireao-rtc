using Test,PipeWireAODeployment
const X=PipeWireAODeployment.HeartCorrectionExport
const HC=PipeWireAODeployment.HeartConfiguration
const C=PipeWireAODeployment.Common

@testset "native correction name respects the unchanged deployment bound" begin
    mktempdir() do root
        asset=joinpath(root,"fixture.conf");write(asset,"fixture")
        placement=Dict("cpus"=>[2],"leader-cpu"=>2,"rt-priority"=>0,"threads"=>[],"locked-bytes"=>0)
        specification=Dict("version"=>1,"name"=>"copper-fgn-cuda-correction-heart-hil-active-correction",
            "session"=>"fixture.conf","core"=>"fixture.conf","client"=>Dict("core"=>"fixture.conf","rtc"=>"fixture.conf"),
            "placement"=>Dict("core"=>placement,"rtc"=>placement),"owners"=>[],"environment"=>Dict(),
            "artifacts"=>Dict("fixture.conf"=>C.sha256_file(asset)),"cpu-latency-us"=>nothing)
        path=joinpath(root,"deployment.conf");C.write_json(path,specification)
        @test_throws PipeWireAODeployment.Deployment.DeploymentError PipeWireAODeployment.Deployment.profile(path,"/opt/pipewireao")
        for backend in ("cpu","cuda")
            specification["name"]=X.deployment_name("copper",backend);C.write_json(path,specification)
            actual=PipeWireAODeployment.Deployment.profile(path,"/opt/pipewireao")
            @test actual["name"]=="copper-heart-$backend-correction"
            @test ncodeunits(actual["name"])<=40
        end
        @test X.deployment_name("classic","cuda")=="classic-heart-cuda-correction"
        @test_throws ArgumentError X.deployment_name("copper","amdgpu")
    end
end

function native_config_fixture()
    return Dict("GEN"=>Dict("MODAL_CTRL"=>1,"HO_POLC"=>0,"LO_POLC"=>0),
        "HO"=>Dict("RECONSTRUCTED_VECT_SIZE"=>253,"NCPA_GRADS_FILE"=>[Dict("WFS_NUM"=>0,"FILE"=>"")],
            "OPTICAL_GAIN_INITIAL"=>[Dict("WFS_NUM"=>0,"X"=>1.0,"Y"=>1.0)]),
        "LO"=>Dict("WFS_COUNT"=>0),"DM"=>Dict("VDM_COUNT"=>1,"PDM_COUNT"=>1,
            "VDM_SIZES"=>[Dict("VDM_NUM"=>0,"SIZE"=>253,"SIZE_FULL"=>253,"NUM_OF_PDM"=>1)],
            "PDM_SYS_FLAT_FILE"=>[Dict("PDM_NUM"=>0,"FILE"=>"")],"PDM_OFFSETS_FILE"=>[Dict("PDM_NUM"=>0,"FILE"=>"")]),
        "TFC"=>Dict("TFC_INIT_GAIN_FILTER"=>[Dict("HO"=>0.01,"LO"=>0.0)],"TFC_HO_NCPA_REF_VEC_FILEPATH"=>""),
        "CLWC"=>Dict("CLWC_DM_SCALAR"=>1.0,"CLWC_DM_LEAK_PARAM"=>0.99))
end
@testset "native correction preserves actual recurrence and zero terms" begin
    config=native_config_fixture();before=deepcopy(config)
    proof=X.native_config_contract(config)
    @test proof["gain"]==0.01
    @test proof["pole"]==0.99
    @test proof["controller_sign"]==-1
    @test config==before
    for (section,key,value) in (("GEN","MODAL_CTRL",0),("GEN","HO_POLC",1),("CLWC","CLWC_DM_LEAK_PARAM",0.9),
        ("TFC","TFC_INIT_GAIN_FILTER",[Dict("HO"=>0.0,"LO"=>0.0)]),
        ("DM","PDM_SYS_FLAT_FILE",[Dict("PDM_NUM"=>0,"FILE"=>"nonzero.fits")]),
        ("HO","OPTICAL_GAIN_HO_VECT_INITIAL",[Dict("WFS_NUM"=>0,"FILE"=>"gain.fits")]),
        ("TFC","TFC_HO_TEMPORAL_FILTER",[Dict("EXISTS"=>1)]),("DM","PDM_MODE_SELECT",[Dict("NUM_MODES"=>253)]))
        changed=deepcopy(config);changed[section][key]=value
        @test_throws ArgumentError X.native_config_contract(changed)
    end
end
@testset "normal owner and immutable clipping contract" begin
    argv=["julia","--startup-file=no","@PACKAGE@/hil/simulator.jl","--correction-diagnostics","true"]
    actual=X.owner_arguments(argv,"/tmp/fixture-native",16777216)
    @test actual[3]=="@PACKAGE@/hil/heart_correction_owner.jl"
    @test argv[3]=="@PACKAGE@/hil/simulator.jl"
    @test "@PACKAGE@/heart-active-contract.json" in actual
    @test_throws ArgumentError X.owner_arguments(replace(argv,"true"=>"false"),"/tmp/fixture-native",1024)
    mktempdir() do root
        path=joinpath(root,"limits.csv")
        write(path,"2 277 1 float\n"*join(fill("0.8",277),',')*"\n"*join(fill("-0.8",277),',')*"\n")
        @test X.validate_clipping_file(path)===nothing
        write(path,replace(read(path,String),"0.8"=>"0.4"))
        @test_throws ArgumentError X.validate_clipping_file(path)
    end
end
@testset "metadata alone cannot prepare a native correction" begin
    mktempdir() do root
        selected=Dict("engine"=>"heart","mode"=>"select","passed"=>true,"input_files"=>Dict(),
            "preparation_sha256"=>"grid","native_reference_seal_sha256"=>"reference","policy_sha256"=>"policy",
            "controller_sign"=>-1,"estimator_shape"=>[253,3600],"layout"=>"ROW_MAJOR","element_type"=>"F32_LE")
        estimator=zeros(Float32,253,3600);estimator[4,1]=0.25f0
        controller=-estimator;fill!(view(controller,1:3,:),0f0)
        estimator_path=joinpath(root,"selected-estimator.f32le");controller_path=joinpath(root,"selected-controller.f32le")
        write(estimator_path,vec(permutedims(estimator)));write(controller_path,vec(permutedims(controller)))
        selected["selected_estimator_sha256"]=C.sha256_file(estimator_path)
        selected["selected_controller_sha256"]=C.sha256_file(controller_path)
        selected_path=joinpath(root,"selection.json");C.write_json(selected_path,selected)
        locked=Dict("engine"=>"heart","mode"=>"locked","passed"=>true,"native_ingress_mode"=>"deferred","input_files"=>Dict(),
            "selection_path"=>selected_path,"selection_sha256"=>C.sha256_file(selected_path),
            "preparation_sha256"=>"grid","native_reference_seal_sha256"=>"reference","policy_sha256"=>"policy",
            "selected_estimator_sha256"=>selected["selected_estimator_sha256"],"selected_controller_sha256"=>selected["selected_controller_sha256"])
        locked_path=joinpath(root,"locked.json");C.write_json(locked_path,locked);hash=C.sha256_file(locked_path)
        metadata=X.locked_inputs(locked_path,hash)
        @test metadata.controller==controller_path
        @test_throws KeyError X.replay_admission(metadata,locked_path,hash)
        @test !ispath(joinpath(root,"package"))
        write(controller_path,zeros(UInt8,253*3600*4))
        @test_throws ArgumentError X.locked_inputs(locked_path,hash)
    end
end

@testset "active phase and receipt source contracts are packaged explicitly" begin
    @test "heart_correction_phases.jl" in X.HELPERS
    @test "heart_correction_analysis.jl" in X.HELPERS
    @test "source/util/src/hrtTelemetry.c" in X.SOURCE_FILES
    @test "source/device/src/hrtStdDmHandler.c" in X.SOURCE_FILES
    @test "source/blocks/src/hrtWcOutputBlock.c" in X.SOURCE_FILES
end

@testset "Classic active export requires retained native transfer and original recurrence" begin
    config=native_config_fixture();config["GEN"]["MODAL_CTRL"]=0
    config["HO"]["RECONSTRUCTED_VECT_SIZE"]=277
    config["HO"]["NCPA_GRADS_FILE"]=[Dict("WFS_NUM"=>0,"FILE"=>"./config/operational-reference.fits")]
    config["DM"]["VDM_SIZES"]=[Dict("VDM_NUM"=>0,"SIZE"=>277,"SIZE_FULL"=>277,"NUM_OF_PDM"=>1)]
    config["DM"]["VDM_EXTRAPOLATION_FILE"]=[Dict("VDM_NUM"=>0,"FILE"=>"./config/original.sparse")]
    config["TFC"]["TFC_INIT_GAIN_FILTER"]=[Dict("HO"=>-.3,"LO"=>0.0)]
    before=deepcopy(config)
    proof=X.native_config_contract(config;profile="classic")
    @test proof["gain"]==-.3 && proof["pole"]==.99 && proof["controller_sign"]==1
    @test config==before
    for (section,key,value) in (("GEN","MODAL_CTRL",1),("TFC","TFC_INIT_GAIN_FILTER",[Dict("HO"=>.01,"LO"=>0.0)]),
        ("DM","VDM_TO_PDM_FILE",[Dict("PDM_NUM"=>0,"FILE"=>"replacement.fits")]))
        changed=deepcopy(config);changed[section][key]=value
        @test_throws ArgumentError X.native_config_contract(changed;profile="classic")
    end
    argv=["julia","@PACKAGE@/hil/simulator.jl","--correction-diagnostics","true"]
    native=X.owner_arguments(argv,"/tmp/fixture-native",128*1024*1024;profile="classic")
    @test native[findfirst(==("--heart-native-ingress-mode"),native)+1]=="streaming"
    @test "@PACKAGE@/heart/classic-active.u8" in native
    mktempdir() do root
        @test_throws ArgumentError X.export_classic_package((;),root,joinpath(root,"output"),"cuda",Dict(),Dict())
        @test !ispath(joinpath(root,"output"))
    end
end

@testset "exact native profile flags are included in both runtime resource copies" begin
    @test "heart_correction_flags.jl" in X.HELPERS
    @test length(X.NativeFlags.required_flags(:copper))==13
    @test length(X.NativeFlags.required_flags(:classic))==24
    mktempdir() do root
        package=joinpath(root,"package");mkdir(package)
        PipeWireAODeployment.ScienceExport.copy_deployment_runtime(package)
        mirrored=joinpath(package,"julia/assets/deployment/hil/heart_correction_flags.jl")
        mkpath(joinpath(package,"hil"))
        copied=joinpath(package,"hil/heart_correction_flags.jl")
        PipeWireAODeployment.ScienceExport.copy_file(X.FLAGS_RESOURCE,copied)
        @test C.sha256_file(mirrored)==C.sha256_file(copied)==C.sha256_file(X.FLAGS_RESOURCE)
        @test occursin("heart_correction_flags.jl",read(joinpath(package,"julia/assets/deployment/hil/heart_correction_analysis.jl"),String))
    end
end


@testset "correction freezes the moved scientific body and cold SDK" begin
    @test all(name->name in X.FROZEN_HELPERS,("simulator.jl","simulator_owner.jl","native_owner_bootstrap.jl","jfg_owner.jl"))
    @test all(name->name in X.HELPERS,X.FROZEN_HELPERS)
    source = Meta.parseall(read(joinpath(PipeWireAODeployment.resource_root(),"hil/heart_correction_owner.jl"),String))
    function frozen_assignment(expression)
        expression isa Expr || return nothing
        if expression.head == :(=) && expression.args[1] == :FROZEN_HELPERS
            return expression.args[2]
        end
        for child in expression.args
            result = frozen_assignment(child)
            result === nothing || return result
        end
        nothing
    end
    assignment = frozen_assignment(source)
    @test assignment !== nothing && assignment.head == :tuple
    @test Tuple(assignment.args) == X.FROZEN_HELPERS
end
