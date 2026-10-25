# Array validation of the same calibrated graph and complete named command set.
function Calibration.validate_modal_system(source, recipe, calibration, report_path;
        target=AdaptiveOpticsSim.Backends.HostComputeDevice(), steps=48)
    steps>=16 || throw(ArgumentError("validation needs at least 16 correction steps"))
    declaration=IC.load_simulation(joinpath(source,recipe["simulation"]))
    settings=IC.settings(declaration,get(recipe,"settings",Dict()))
    receipt=PipeWireAORTC.Common.read_yaml(joinpath(calibration,"result.yaml"))
    expected=IC.prescription_identity(declaration,settings)
    expected in (receipt["source_prescription_identity"],get(receipt,"staged_prescription_identity",nothing)) || throw(ArgumentError("calibration belongs to another simulation prescription"))
    Calibration.digest(joinpath(calibration,"graph.conf"))==receipt["graph_sha256"] || throw(ArgumentError("calibration graph changed"))
    system=IC.prepare_system(declaration.path;settings=IC._instrument_seal(settings),calibration=true,target)
    concrete=PipeWireAORTC.DeploymentConfiguration.decode(joinpath(calibration,"graph.conf"),"/opt/pipewireao")
    results=Dict{String,Any}()
    mktempdir() do temporary
        graph_path=joinpath(temporary,"graph.conf")
        PipeWireAORTC.ScienceExport.write_spa_config(graph_path,concrete;
            header="Generated finite simulation validation graph; do not edit.")
        graph=JuliaFilterGraph.prepare_graph(graph_path;algorithms=FGA.algorithms())
        formats=JuliaFilterGraph.parameter_formats(graph)
        parameters=map(collect(pairs(formats))) do (name,format)
            path=joinpath(calibration,"artifacts",String(name)*".fits")
            artifact=PipeWireAORTC.Artifacts.FITSArtifact(path;axes=reverse(ntuple(identity,length(format.shape))))
            name=>PipeWireAORTC.Artifacts.prepare(artifact,format.element_type,format.shape).data
        end
        JuliaFilterGraph.replace_parameters!(graph,parameters...)
        inputs=map(f->zeros(f.element_type,f.shape),JuliaFilterGraph.input_formats(graph))
        outputs=map(f->zeros(f.element_type,f.shape),JuliaFilterGraph.output_formats(graph))
        commands=map(zero,HIL.hil_command_buffer(system.boundary))
        support=IC.binding_values(declaration,settings,Dict("kind"=>"pupil_support","resolution"=>"pupil_resolution"))
        xy=IC.binding_values(declaration,settings,Dict("kind"=>"pupil_coordinates","resolution"=>"pupil_resolution"))
        valid=findall(vec(support).!=0)
        x,y=view(xy,:,:,1),view(xy,:,:,2)
        disturbances=(tiptilt=Float32.(40e-9 .*x .- 25e-9 .*y),
            focus=Float32.(50e-9 .*(2 .*x.^2 .+ 2 .*y.^2 .- 1)),
            astigmatism=Float32.(60e-9 .*(x.^2 .- y.^2)),
            mixed=Float32.(20e-9 .*sin.(6 .*x).*cos.(8 .*y) .+ 30e-9 .*x))
        rms(values)=begin
            samples=vec(Array(values))[valid]
            average=sum(samples)/length(samples)
            sqrt(sum(v->abs2(v-average),samples)/length(samples))
        end
        for (name,disturbance) in pairs(disturbances)
            HIL.reset_hil_boundary!(system.boundary)
            JuliaFilterGraph.reset!(graph)
            foreach(c->fill!(c,0f0),commands)
            fill!(inputs.var"constraint-feedback",0f0)
            copyto!(HIL.graph_input(system.graph,:uncompensated_opd),disturbance)
            history=Float64[];times=Float64[]
            for step in 1:steps
                started=time_ns()
                frame=modal_frame!(system,commands)
                push!(history,Float64(rms(HIL.graph_output(system.graph,:pupil_opd))))
                inputs.raw .= round.(UInt16,frame)
                result=JuliaFilterGraph.process!(outputs,graph,inputs)
                all(values(result)) || throw(ArgumentError("controller rejected $name step $step: $result"))
                for key in keys(commands)
                    copyto!(getproperty(commands,key),getproperty(outputs,key))
                end
                copyto!(inputs.var"constraint-feedback",outputs.var"controller-constraint-feedback")
                push!(times,Float64(time_ns()-started)/1e6)
            end
            before=rms(disturbance);after=sum(history[end-7:end])/8
            results[String(name)]=Dict("uncorrected_rms_m"=>Float64(before),
                "residual_rms_m"=>after,"residual_ratio"=>after/before,
                "history_rms_m"=>history,"step_ms"=>times,
                "final_command_max_m"=>Dict(String(key)=>maximum(abs,getproperty(commands,key)) for key in keys(commands)))
            after<0.8before || throw(ArgumentError("$name did not improve wavefront RMS: $(after/before)"))
        end

    end
    report=Dict("graph_sha256"=>receipt["graph_sha256"],
        "prescription_identity"=>expected,
        "controller_properties"=>only(n for n in concrete["filter.graph"]["nodes"] if n["name"]=="closed-loop-correction")["props"],
        "scope"=>"finite simulation-local calibrated array loop; no native timing or hardware claim",
        "steps"=>steps,"cases"=>results,"backend"=>string(typeof(target)),
        "calibration_sha256"=>Calibration.digest(joinpath(calibration,"result.yaml")))
    PipeWireAORTC.Common.write_yaml(report_path,report;header="Generated finite closed-loop validation receipt; do not edit.")
    return report
end
