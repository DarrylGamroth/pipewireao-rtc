# Array validation of the same calibrated graph and complete named command set.
function Calibration._validate_system(::Val{:pyramid}, source, recipe, calibration, report_path;
        target=AdaptiveOpticsSim.Backends.HostComputeDevice(), steps=48,
        execution=nothing, pupil_field_output=nothing)
    ispath(report_path) && throw(ArgumentError("validation output must be fresh"))
    steps>=16 || throw(ArgumentError("validation needs at least 16 correction steps"))
    declaration=IC.load_simulation(joinpath(source,recipe["simulation"]))
    settings=IC.settings(declaration,get(recipe,"settings",Dict()))
    receipt=Calibration.read_bundle(calibration).report
    expected=IC.prescription_identity(declaration,settings)
    expected in (receipt["source_prescription_identity"],get(receipt,"staged_prescription_identity",nothing)) || throw(ArgumentError("calibration belongs to another simulation prescription"))
    Calibration.digest(joinpath(calibration,"graph.conf"))==receipt["graph_sha256"] || throw(ArgumentError("calibration graph changed"))
    for (name, expected_hash) in receipt["artifact_sha256"]
        Calibration.digest(joinpath(calibration,"artifacts",name)) == expected_hash ||
            throw(ArgumentError("calibration artifact changed: $name"))
    end
    system=IC.prepare_system(declaration.path;settings=IC._instrument_seal(settings),calibration=true,target,execution)
    concrete=PipeWireAORTC.DeploymentConfiguration.decode(joinpath(calibration,"graph.conf"),"/opt/pipewireao")
    results=Dict{String,Any}()
    graph=bundle_graph(calibration)
    report=Dict("graph_sha256"=>receipt["graph_sha256"],
        "prescription_identity"=>expected,
        "controller_properties"=>only(n for n in concrete["filter.graph"]["nodes"] if n["name"]=="closed-loop-correction")["props"],
        "scope"=>"finite simulation-local calibrated array loop; no native timing or hardware claim",
        "steps"=>steps,"cases"=>results,"backend"=>string(typeof(target)),
        "execution"=>string(typeof(AdaptiveOpticsSim.AlgorithmGraphs.graph_execution_policy(system.graph))), "pupil_field_output"=>isnothing(pupil_field_output) ? nothing : String(pupil_field_output),
        "pupil_opd_rms_gate"=>isnothing(pupil_field_output),
        "calibration_sha256"=>Calibration.digest(joinpath(calibration,"result.yaml")),
        "passed"=>false)
    try
        inputs=map(f->zeros(f.element_type,f.shape),JuliaFilterGraph.input_formats(graph))
        outputs=map(f->zeros(f.element_type,f.shape),JuliaFilterGraph.output_formats(graph))
        commands=map(zero,HIL.hil_command_buffer(system.boundary))
        reference_field = if isnothing(pupil_field_output)
            nothing
        else
            modal_frame!(system,commands)
            Array(HIL.graph_output(system.graph,Symbol(pupil_field_output)))
        end
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
            history=Float64[];times=Float64[];overlap=Float64[]
            case=Dict{String,Any}("history_rms_m"=>history,"step_ms"=>times)
            results[String(name)]=case
            isnothing(reference_field) || (case["pupil_field_overlap"]=overlap)
            for step in 1:steps
                started=time_ns()
                frame=modal_frame!(system,commands)
                residual=Float64(rms(HIL.graph_output(system.graph,:pupil_opd)))
                isfinite(residual) || throw(ArgumentError("nonfinite residual for $name step $step"))
                push!(history,residual)
                if !isnothing(reference_field)
                    push!(overlap,pupil_field_overlap(reference_field,
                        Array(HIL.graph_output(system.graph,Symbol(pupil_field_output)))))
                end
                inputs.raw .= round.(UInt16,frame)
                result=JuliaFilterGraph.process!(outputs,graph,inputs)
                all(values(result)) || throw(ArgumentError("controller rejected $name step $step: $result"))
                for key in keys(commands)
                    all(isfinite,getproperty(outputs,key)) ||
                        throw(ArgumentError("nonfinite $key command for $name step $step"))
                    copyto!(getproperty(commands,key),getproperty(outputs,key))
                end
                copyto!(inputs.var"constraint-feedback",outputs.var"controller-constraint-feedback")
                push!(times,Float64(time_ns()-started)/1e6)
            end
            before=rms(disturbance);after=sum(history[end-7:end])/8
            merge!(case,Dict("uncorrected_rms_m"=>Float64(before),
                "residual_rms_m"=>after,"residual_ratio"=>after/before,
                "history_rms_m"=>history,"step_ms"=>times,
                "final_command_max_m"=>Dict(String(key)=>maximum(abs,getproperty(commands,key)) for key in keys(commands))))
            if !isnothing(reference_field)
                final_overlap=sum(overlap[end-7:end])/8
                results[String(name)]["pupil_field_overlap"]=overlap
                results[String(name)]["initial_pupil_field_overlap"]=first(overlap)
                results[String(name)]["trailing_pupil_field_overlap"]=final_overlap
                1-final_overlap < 0.8*(1-first(overlap)) ||
                    throw(ArgumentError("$name did not improve propagated pupil-field overlap"))
            else
                after<0.8before || throw(ArgumentError("$name did not improve wavefront RMS: $(after/before)"))
            end
        end
        report["passed"]=true
    catch error
        report["error"]=sprint(showerror,error)
        rethrow()
    finally
        FilterGraphIsland.close_execution(graph)
        PipeWireAORTC.Common.write_yaml(report_path,report;header="Generated finite closed-loop validation receipt; preserve failed gates.")
    end
    return report
end

# Piston-invariant coherent overlap against the propagated zero-command field.
# This compares normalized amplitude profiles and phase, not total throughput.
# It makes no phase-unwrapping claim.
function pupil_field_overlap(reference::AbstractArray{<:Complex}, field::AbstractArray{<:Complex})
    size(reference)==size(field) || throw(DimensionMismatch("pupil field grids differ"))
    all(isfinite,reference) && all(isfinite,field) || throw(ArgumentError("pupil fields must be finite"))
    a=ComplexF64.(vec(reference)); b=ComplexF64.(vec(field))
    power=sum(abs2,a)*sum(abs2,b)
    isfinite(power) && power>0 || throw(ArgumentError("pupil fields must have finite nonzero power"))
    return clamp(abs2(LA.dot(a,b))/power,0.0,1.0)
end
