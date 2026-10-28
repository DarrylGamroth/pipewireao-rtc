using Test, PipeWireAORTC, PipeWireAO, LinearAlgebra
Base.include(@__MODULE__,joinpath(@__DIR__,"composition_documents.jl"))
Base.include(@__MODULE__,joinpath(@__DIR__,"aos_graph_documents.jl"))
const E=PipeWireAORTC.InstrumentExport
const C=PipeWireAORTC.Common
const D=PipeWireAORTC.DeploymentConfiguration
const Calibration=PipeWireAORTC.InstrumentCalibration
const PREFIX=PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir

@testset "feedback preparation binds physical order and calibrated frontend" begin
    mktempdir() do temporary
        base=joinpath(temporary,"base");mkpath(base)
        fixture=aos_graph_documents(base)
        composition_fixture(base,"base","julia","pupil")
        C.write_json(joinpath(base,"simulation.conf"),fixture.document)
        Calibration.write_fits(joinpath(base,"existing.fits"),zeros(Float32,1))
        C.write_json(joinpath(base,"parameters.conf"),Dict("parameters"=>[Dict("port"=>"existing","path"=>"existing.fits","hdu"=>1)]))
        residual=PipeWireAORTC.Schemas.identifier("controller_residual_error")
        baseline=Dict("filter.graph"=>Dict("nodes"=>[Dict("type"=>"ndarray","label"=>"vector-offset-f32","name"=>name,
            "config"=>Dict("extent"=>1,"schema"=>residual)) for name in ("raw","reconstruction")],
            "links"=>[Dict("output"=>"raw:output","input"=>"reconstruction:requested")],
            "inputs"=>[Dict("name"=>"image","endpoint"=>"raw:requested"),Dict("name"=>"existing","endpoint"=>"reconstruction:offset")],
            "outputs"=>[Dict("name"=>"residual","endpoint"=>"reconstruction:output")]))
        C.write_json(joinpath(base,"graph.conf"),baseline)
        E.seal!(base)
        component=composition_fixture(joinpath(temporary,"component"),"component","simulator","sensor")
        directory=joinpath(component,"generated/calibration");mkpath(directory)
        identity="sha256:"*repeat("b",64)
        C.write_json(joinpath(component,"simulation.conf"),Dict("backend"=>"cpu","device"=>0,
            "rtc_configuration"=>"generated/calibration/rtc.yaml","calibration_identity"=>identity))
        C.write_yaml(joinpath(directory,"rtc.yaml"),Dict("calibration_identity"=>identity,
            "calibration"=>"generated/calibration/context.yaml"))
        recipe=Dict("branch_modes"=>Dict("llowfs"=>[1],"scc"=>[2]))
        for name in ("llowfs","scc")
            report=Dict("recipe"=>recipe,"source_graph_sha256"=>repeat("c",64),
                "source_prescription_identity"=>"sha256:"*repeat("d",64),"status"=>"accepted",
                "calibration_identity"=>identity,"built_application_calibration"=>true,"deployable"=>true,"diagnostic"=>false,
                "branch"=>name,"branches"=>Dict(name=>Dict("accepted"=>true)),"held_out"=>Dict("accepted"=>true),
                "upstream_prescription_identity"=>fixture.document["prescription_identity"],
                "upstream_reference"=>Dict("source_graph_sha256"=>C.sha256_file(joinpath(base,"graph.conf")),
                    "method"=>"host-expectation","reference_backend"=>"host","source_backend_qualification"=>"host",
                    "parameter_sha256"=>Dict("existing"=>C.sha256_file(joinpath(base,"existing.fits"))),
                    "baseline_parameter_sha256"=>Dict(),"reference_sign"=>-1,"raw_endpoint"=>"raw:requested","residual_endpoint"=>"reconstruction:output",
                    "effective_settings_identity"=>PipeWireAORTC.InstrumentDefinition.scientific_identity(
                        PipeWireAORTC.InstrumentConfiguration.canonical(PipeWireAORTC.InstrumentConfiguration.settings(fixture.declaration))),"adc_settings"=>Dict(),
                    "execution_graph"=>"production",
                    "execution_graph_identity"=>PipeWireAORTC.InstrumentDefinition.scientific_identity(PipeWireAORTC.InstrumentConfiguration.canonical(
                        PipeWireAORTC.InstrumentConfiguration.graph_document(fixture.declaration,PipeWireAORTC.InstrumentConfiguration.settings(fixture.declaration)))),
                    "calibration_graph_identity"=>PipeWireAORTC.InstrumentDefinition.scientific_identity(PipeWireAORTC.InstrumentConfiguration.canonical(
                        PipeWireAORTC.InstrumentConfiguration.graph_document(fixture.declaration,PipeWireAORTC.InstrumentConfiguration.settings(fixture.declaration);calibration=true)))))
            Calibration.write_bundle(joinpath(directory,name),report,Dict(),Dict("filter.graph"=>Dict("nodes"=>[])),
                Dict("command-projection"=>Matrix{Float32}(I,2,2));
                diagnostics=Dict("physical-to-modes"=>Matrix{Float32}(I,2,2),"modes-to-reference"=>zeros(Float32,1,2)))
        end
        shared=Dict(name=>Dict("path"=>"llowfs/artifacts/"*name*".fits",
            "sha256"=>C.sha256_file(joinpath(directory,"llowfs/artifacts/"*name*".fits")))
            for name in ("command-projection","physical-to-modes","modes-to-reference"))
        index=Dict("version"=>1,"kind"=>"optical-calibration-index","calibration_identity"=>identity,"physical_projection"=>shared,
            "branches"=>Dict(name=>Dict("path"=>name,"result_sha256"=>C.sha256_file(joinpath(directory,name,"result.yaml"))) for name in ("llowfs","scc")))
        C.write_yaml(joinpath(directory,"calibration.yaml"),index)
        Calibration.write_fits(joinpath(directory,"zero.fits"),zeros(Float32,2))
        C.write_yaml(joinpath(directory,"selection.yaml"),Dict("calibration_identity"=>identity,
            "calibration_index_sha256"=>C.sha256_file(joinpath(directory,"calibration.yaml")),
            "rtc_configuration"=>Dict("path"=>"rtc.yaml","sha256"=>C.sha256_file(joinpath(directory,"rtc.yaml"))),
            "zero_command"=>Dict("path"=>"zero.fits","sha256"=>C.sha256_file(joinpath(directory,"zero.fits")),"shape"=>[2])))
        E.seal!(component)
        authoring=joinpath(temporary,"authoring");mkpath(authoring)
        inputs=[Dict("name"=>name,"endpoint"=>"reference:"*endpoint) for (name,endpoint) in
            (("offset","offset"),("inverse","physical-to-modes"),("reference","modes-to-reference"))]
        variant=deepcopy(baseline)
        append!(variant["filter.graph"]["inputs"],inputs)
        push!(variant["filter.graph"]["nodes"],Dict("type"=>"ndarray","name"=>"reference","label"=>"physical-offset-reference-f32",
            "config"=>Dict("residual_count"=>1,"physical_count"=>2,"mode_count"=>2,"reference_sign"=>-1,
                "residual_schema"=>residual,"physical_schema"=>PipeWireAORTC.Schemas.identifier("requested_pdm_command"),
                "physical_to_modes_schema"=>"test.q/1","modes_to_reference_schema"=>"test.c/1")))
        push!(variant["filter.graph"]["links"],Dict("output"=>"reconstruction:output","input"=>"reference:reconstructed-residual"))
        append!(variant["filter.graph"]["outputs"],[Dict("name"=>"physical","endpoint"=>"reference:physical-offset"),
            Dict("name"=>"compensated","endpoint"=>"reference:compensated-residual")])
        C.write_json(joinpath(authoring,"graph.conf"),variant)
        projection(name,shape)=Dict("path"=>"components/cal2/generated/calibration/llowfs/artifacts/"*name*".fits",
            "sha256"=>Dict("\$ref"=>"/calibration/cal2/"*Dict("command-projection"=>"projection","physical-to-modes"=>"inverse","modes-to-reference"=>"reference")[name]*"_sha256"),
            "shape"=>shape,"axes"=>[2,1])
        contract=Dict("version"=>1,"parameter"=>"offset","algorithm"=>"reference","clock_output"=>"physical",
            "reference_sign"=>-1,"command_limit_m"=>1e-6,"calibration_identity"=>Dict("\$ref"=>"/calibration/cal2/calibration_identity"),
            "command_order"=>Dict("\$ref"=>"/calibration/cal2/command_order"),
            "projection"=>projection("command-projection",[2,2]),"inverse"=>projection("physical-to-modes",[2,2]),
            "reference"=>projection("modes-to-reference",[1,2]),"branches"=>Dict(name=>Dict("node_name"=>name*"-offset",
                "schema"=>"pipewireao/requested-pdm-command-opd-m-f32/1","modes"=>recipe["branch_modes"][name],
                "command_limit_m"=>1e-6,"coefficient_limit_m"=>1e-8,"max_age_ns"=>1000,"silence_ns"=>1000) for name in ("llowfs","scc")))
        C.write_yaml(joinpath(authoring,"receiver.yaml"),contract)
        C.write_yaml(joinpath(authoring,"parameters.yaml"),Dict("parameters"=>[
            Dict("port"=>name,"path"=>path,"hdu"=>1,"axes"=>axes) for (name,path,axes) in
            (("offset","components/cal2/generated/calibration/zero.fits",[1]),
             ("inverse",contract["inverse"]["path"],[2,1]),("reference",contract["reference"]["path"],[2,1]))]))
        C.write_yaml(joinpath(authoring,"profile.yaml"),Dict("version"=>1,"backend"=>"cpu","device"=>0,"pacing_rate_hz"=>0.1,
            "silence_ns"=>Dict("llowfs"=>100_000_000_000,"scc"=>300_000_000_000)))
        document=Dict("version"=>1,"namespace"=>"cal2","profile"=>"profile.yaml","roles"=>Dict("simulator"=>"cal2-optics"),"links"=>[],
            "calibration"=>"generated/calibration","receiver"=>Dict("owner"=>"julia","mirror"=>"primary",
                "rtc_configuration"=>"rtc/configuration.yaml","simulation_configuration"=>"simulation.conf",
                "graph_template"=>"graph.conf","graph"=>"graph.conf","parameters_append"=>"parameters.yaml",
                "parameters"=>"parameters.conf","template"=>"receiver.yaml","configuration"=>"offsets.yaml"),
            "owner_arguments"=>Dict("role"=>"julia","threads"=>"3,0","append"=>["--physical-offsets","@PACKAGE@/offsets.yaml"]))
        recipepath=joinpath(authoring,"composition.yaml");C.write_yaml(recipepath,document)
        output=E.prepare_feedback(base,component,joinpath(temporary,"composed"),recipepath;prefix=PREFIX)
        spec=C.read_json(joinpath(output,"deployment.conf"))
        @test spec["source-owner"]=="julia" && spec["auxiliary-source-owners"]==["cal2-optics"]
        @test Set(keys(spec["node-owners"]))==Set(["pupil","sensor","llowfs-offset","scc-offset"])
        @test "--threads=3,0" in first(spec["owners"])["argv"]
        @test "--physical-offsets" in first(spec["owners"])["argv"]
        @test startswith(C.read_yaml(joinpath(output,"offsets.yaml"))["command_order"],"sha256:")
        @test length(C.read_json(joinpath(output,"parameters.conf"))["parameters"])==4
        @test length(D.decode(joinpath(output,spec["session"]),PREFIX)["sinks"])==2
        @test C.read_json(joinpath(output,"simulation.conf"))["pacing_rate_hz"]==0.1
        @test C.read_json(joinpath(output,"simulation.conf"))["rate"]==fixture.document["rate"]
        @test C.read_yaml(joinpath(output,"offsets.yaml"))["branches"]["scc"]["silence_ns"]==300_000_000_000
        # The optical consumer and producer use an explicitly matched profile,
        # but a Host expectation does not qualify the accelerator detector RNG.
        gpu_base=joinpath(temporary,"gpu-base");cp(base,gpu_base)
        gpu_component=joinpath(temporary,"gpu-component");cp(component,gpu_component)
        for path in (gpu_base,gpu_component)
            simulation=C.read_json(joinpath(path,"simulation.conf"))
            simulation["backend"]="amdgpu";simulation["device"]=1
            C.write_json(joinpath(path,"simulation.conf"),simulation);E.seal!(path)
        end
        gpu_profile=joinpath(authoring,"gpu.yaml")
        profile=C.read_yaml(joinpath(authoring,"profile.yaml"))
        profile["backend"]="amdgpu";profile["device"]=1
        C.write_yaml(gpu_profile,profile)
        @test_throws ArgumentError E.prepare_feedback(gpu_base,gpu_component,joinpath(temporary,"unqualified-gpu"),recipepath;
            prefix=PREFIX,profile=gpu_profile)
        @test !ispath(joinpath(temporary,"unqualified-gpu"))
        # Selecting the consumer independently must not change the calibrated
        # Host producer. Omitting upstream preserves the legacy matched choice.
        @test_throws ArgumentError E.prepare_feedback(base,gpu_component,joinpath(temporary,"implicit-mixed"),recipepath;
            prefix=PREFIX,profile=gpu_profile)
        profile["upstream"]=Dict("backend"=>"cpu","device"=>0)
        C.write_yaml(gpu_profile,profile)
        mixed=E.prepare_feedback(base,gpu_component,joinpath(temporary,"explicit-mixed"),recipepath;prefix=PREFIX,profile=gpu_profile)
        @test C.read_json(joinpath(mixed,"simulation.conf"))["backend"]=="cpu"
        @test C.read_json(joinpath(mixed,"components/cal2/simulation.conf"))["backend"]=="amdgpu"
        @test C.read_yaml(joinpath(mixed,"rtc/feedback-profile.yaml"))["upstream"]==Dict("backend"=>"cpu","device"=>0)
        @test_throws ArgumentError E.prepare_feedback(gpu_base,gpu_component,joinpath(temporary,"wrong-upstream"),recipepath;
            prefix=PREFIX,profile=gpu_profile)
        for (name,selection) in (("unknown-key",Dict("backend"=>"cpu","device"=>0,"extra"=>1)),
                ("missing-device",Dict("backend"=>"cpu")),("invalid-type",["cpu",0]),
                ("boolean-device",Dict("backend"=>"cpu","device"=>false)),
                ("cpu-device",Dict("backend"=>"cpu","device"=>1)),
                ("gpu-device",Dict("backend"=>"amdgpu","device"=>0)),
                ("unknown-backend",Dict("backend"=>"cuda","device"=>0)))
            invalid=deepcopy(profile);invalid["upstream"]=selection
            path=joinpath(authoring,name*".yaml");C.write_yaml(path,invalid)
            output=joinpath(temporary,name)
            @test_throws ArgumentError E.prepare_feedback(base,gpu_component,output,recipepath;prefix=PREFIX,profile=path)
            @test !ispath(output)
        end
        for (name,key,value) in (("root-unknown-key","extra",1),("root-boolean-device","device",true),
                ("root-string-device","device","1"),("root-overflow-device","device",Int(typemax(Int32))+1),
                ("root-unknown-backend","backend","cuda"))
            invalid=deepcopy(profile);invalid[key]=value
            path=joinpath(authoring,name*".yaml");C.write_yaml(path,invalid)
            output=joinpath(temporary,name)
            @test_throws ArgumentError E.prepare_feedback(base,gpu_component,output,recipepath;prefix=PREFIX,profile=path)
            @test !ispath(output)
        end
        @test !any(id->id.name in ("CUDA","AMDGPU"),keys(Base.loaded_modules))
        for name in ("changed-selected-rtc","disconnected-selected-rtc","changed-selected-identity",
                "changed-selected-document-identity","changed-selected-context","escaped-selected-rtc")
            altered=joinpath(temporary,name);cp(component,altered)
            if name=="changed-selected-rtc"
                open(joinpath(altered,"generated/calibration/rtc.yaml"),"a") do file;write(file,"# changed\n");end
            elseif name=="disconnected-selected-rtc"
                execution=C.read_json(joinpath(altered,"simulation.conf"))
                execution["rtc_configuration"]="rtc/configuration.yaml"
                C.write_json(joinpath(altered,"simulation.conf"),execution)
            elseif name=="changed-selected-identity"
                execution=C.read_json(joinpath(altered,"simulation.conf"))
                execution["calibration_identity"]="sha256:"*repeat("e",64)
                C.write_json(joinpath(altered,"simulation.conf"),execution)
            elseif name in ("changed-selected-document-identity","changed-selected-context")
                path=joinpath(altered,"generated/calibration/rtc.yaml")
                rtc=C.read_yaml(path)
                rtc[name=="changed-selected-context" ? "calibration" : "calibration_identity"]=
                    name=="changed-selected-context" ? "other/context.yaml" : "sha256:"*repeat("e",64)
                C.write_yaml(path,rtc)
                selectionpath=joinpath(altered,"generated/calibration/selection.yaml")
                selection=C.read_yaml(selectionpath);selection["rtc_configuration"]["sha256"]=C.sha256_file(path)
                C.write_yaml(selectionpath,selection)
            else
                selectionpath=joinpath(altered,"generated/calibration/selection.yaml")
                selection=C.read_yaml(selectionpath);selection["rtc_configuration"]["path"]="../rtc.yaml"
                C.write_yaml(selectionpath,selection)
            end
            E.seal!(altered)
            @test_throws ArgumentError E.prepare_feedback(base,altered,joinpath(temporary,name*"-output"),recipepath;prefix=PREFIX)
            @test !ispath(joinpath(temporary,name*"-output"))
        end
        changed_frontend=deepcopy(variant)
        changed_frontend["filter.graph"]["nodes"][1]["config"]["extent"]=2
        C.write_json(joinpath(authoring,"graph.conf"),changed_frontend)
        @test_throws ArgumentError E.prepare_feedback(base,component,joinpath(temporary,"changed-frontend"),recipepath;prefix=PREFIX)
        @test !ispath(joinpath(temporary,"changed-frontend"))
        C.write_json(joinpath(authoring,"graph.conf"),variant)
        unknown=deepcopy(variant);unknown["filter.graph"]["nodes"][end]["label"]="unsupported-offset-algorithm"
        C.write_json(joinpath(authoring,"graph.conf"),unknown)
        @test_throws Exception E.prepare_feedback(base,component,joinpath(temporary,"unsupported"),recipepath;prefix=PREFIX)
        @test !ispath(joinpath(temporary,"unsupported"))
        C.write_json(joinpath(authoring,"graph.conf"),variant)
        altered=joinpath(temporary,"altered-component");cp(component,altered)
        resultpath=joinpath(altered,"generated/calibration/scc/result.yaml")
        altered_report=C.read_yaml(resultpath);altered_report["status"]="rejected";C.write_yaml(resultpath,altered_report)
        indexpath=joinpath(altered,"generated/calibration/calibration.yaml")
        altered_index=C.read_yaml(indexpath);altered_index["branches"]["scc"]["result_sha256"]=C.sha256_file(resultpath);C.write_yaml(indexpath,altered_index)
        selectionpath=joinpath(altered,"generated/calibration/selection.yaml")
        altered_selection=C.read_yaml(selectionpath);altered_selection["calibration_index_sha256"]=C.sha256_file(indexpath);C.write_yaml(selectionpath,altered_selection)
        E.seal!(altered)
        @test_throws ArgumentError E.prepare_feedback(base,altered,joinpath(temporary,"rejected-scc"),recipepath;prefix=PREFIX)
        @test !ispath(joinpath(temporary,"rejected-scc"))
        for (name,mutate) in (("swapped-branch",report->(report["branch"]="llowfs")),
                ("diagnostic-scc",report->(report["diagnostic"]=true)))
            altered=joinpath(temporary,name);cp(component,altered)
            resultpath=joinpath(altered,"generated/calibration/scc/result.yaml")
            report=C.read_yaml(resultpath);mutate(report);C.write_yaml(resultpath,report)
            indexpath=joinpath(altered,"generated/calibration/calibration.yaml")
            updated_index=C.read_yaml(indexpath);updated_index["branches"]["scc"]["result_sha256"]=C.sha256_file(resultpath);C.write_yaml(indexpath,updated_index)
            selectionpath=joinpath(altered,"generated/calibration/selection.yaml")
            updated_selection=C.read_yaml(selectionpath);updated_selection["calibration_index_sha256"]=C.sha256_file(indexpath);C.write_yaml(selectionpath,updated_selection)
            E.seal!(altered)
            @test_throws ArgumentError E.prepare_feedback(base,altered,joinpath(temporary,name*"-output"),recipepath;prefix=PREFIX)
            @test !ispath(joinpath(temporary,name*"-output"))
        end
        escaped=joinpath(temporary,"escaped");cp(component,escaped)
        indexpath=joinpath(escaped,"generated/calibration/calibration.yaml")
        escaped_index=C.read_yaml(indexpath);escaped_index["branches"]["llowfs"]["path"]="../../outside"
        C.write_yaml(indexpath,escaped_index);E.seal!(escaped)
        @test_throws ArgumentError E.prepare_feedback(base,escaped,joinpath(temporary,"escaped-output"),recipepath;prefix=PREFIX)
        @test !ispath(joinpath(temporary,"escaped-output"))
        # Full effective settings catch a valid mutable execution override even
        # when the structural prescription identity stored in the owner is unchanged.
        changed_base=joinpath(temporary,"changed-base");cp(base,changed_base)
        simulation=deepcopy(fixture.document);simulation["plant"]["settings"]["temperature_c"]=21.0
        C.write_json(joinpath(changed_base,"simulation.conf"),simulation);E.seal!(changed_base)
        @test_throws ArgumentError E.prepare_feedback(changed_base,component,joinpath(temporary,"changed-settings"),recipepath;prefix=PREFIX)
        @test !ispath(joinpath(temporary,"changed-settings"))
        write(joinpath(base,"existing.fits"),"changed")
        E.seal!(base)
        @test_throws ArgumentError E.prepare_feedback(base,component,joinpath(temporary,"changed"),recipepath;prefix=PREFIX)
        @test !ispath(joinpath(temporary,"changed"))
    end
end
