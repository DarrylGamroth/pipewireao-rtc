# Optional preparation-time transfer proof. Runtime source admission depends
# only on P/Q and native branch metadata, never this calibration toolbox.
const Export=PipeWireAORTC.InstrumentExport

function Export.validate_pupil_equivalence(base,component,simulation,report,P;mirror,prefix)
    source=IC.load_simulation(PipeWireAORTC.DeploymentConfiguration.relative_asset(base,simulation["plant"]["definition"]))
    settings=IC.settings(source,get(simulation["plant"],"settings",Dict()))
    source_identity=IC.prescription_identity(source,settings)
    source_identity==simulation["prescription_identity"] || throw(ArgumentError("pupil source prescription changed"))
    upstream=IC.load_simulation(PipeWireAORTC.DeploymentConfiguration.relative_asset(base,report["recipe"]["upstream_simulation"]))
    reference=get(report,"upstream_reference",Dict())
    # Cross-prescription transfer requires the original complete executed
    # settings. A shape/order match cannot stand in for these source inputs.
    original=if haskey(reference,"effective_settings")
        configured=IC.settings(upstream,reference["effective_settings"])
        PipeWireAORTC.InstrumentDefinition.scientific_identity(IC.canonical(configured))==reference["effective_settings_identity"] ||
            throw(ArgumentError("calibrated mirror effective settings differ"))
        configured
    elseif source_identity==report["upstream_prescription_identity"]
        settings
    else
        throw(ArgumentError("cross-prescription physical transfer requires recorded executed settings"))
    end
    calibrated_identity=IC.prescription_identity(upstream,original)
    calibrated_identity==report["upstream_prescription_identity"] || throw(ArgumentError("original calibrated mirror prescription differs"))
    report["recipe"]["mirror"]==mirror && report["provenance"]["mirror_component"]==mirror ||
        throw(ArgumentError("physical transfer names a different calibrated mirror"))
    owner=Base.get_extension(PipeWireAORTC,:PipeWireAORTCAOSExt)
    actual=physical_mirror_response(source,settings,mirror;simulation_graph=simulation["plant"]["graph"])
    calibrated=physical_mirror_response(upstream,original,mirror)
    IC.json_value(actual.geometry.description)==IC.json_value(calibrated.geometry.description) &&
        actual.geometry.registration==calibrated.geometry.registration &&
        source.instrument.document["deformable_mirrors"][mirror]["units"]==upstream.instrument.document["deformable_mirrors"][mirror]["units"] &&
        source.instrument.document["deformable_mirrors"][mirror]["command_scale_m"]==upstream.instrument.document["deformable_mirrors"][mirror]["command_scale_m"]==1 ||
        throw(ArgumentError("physical mirror description, registration or units differ"))
    declared=IC.pupil_output(source,settings;simulation_graph=simulation["plant"]["graph"])
    previous=IC.pupil_output(upstream,original;simulation_graph="calibration")
    declared!==nothing && previous!==nothing || throw(ArgumentError("physical transfer requires both declared scientific pupils"))
    a=owner.PupilOutput.contract(source,settings;simulation_graph=simulation["plant"]["graph"])
    b=owner.PupilOutput.contract(upstream,original;simulation_graph="calibration")
    a.schema==b.schema && a.shape==b.shape || throw(ArgumentError("physical transfer pupil contracts differ"))
    amplitude=owner.prepare_bindings(source,settings,(declared.amplitude,)) |> x->getproperty(x,declared.amplitude)
    original_amplitude=owner.prepare_bindings(upstream,original,(previous.amplitude,)) |> x->getproperty(x,previous.amplitude)
    amplitude==original_amplitude && eltype(amplitude)===eltype(original_amplitude)===Float32 ||
        throw(ArgumentError("physical transfer pupil amplitude differs"))
    support=IC.binding_values(source,settings,Dict("kind"=>"pupil_support","resolution"=>"pupil_resolution"))
    support==IC.binding_values(upstream,original,Dict("kind"=>"pupil_support","resolution"=>"pupil_resolution")) ||
        throw(ArgumentError("physical transfer pupil support differs"))
    n,m=size(P)
    zero=zeros(Float32,n)
    maximum_error=0.0
    for command in (zero,eachcol(P)...)
        x=actual.surface(command)
        y=calibrated.surface(command)
        eltype(x)===eltype(y)===Float32 && size(x)==size(y)==size(amplitude) && all(isfinite,x) && all(isfinite,y) ||
            throw(ArgumentError("physical transfer requires matching finite Float32 OPD grids"))
        maximum_error=max(maximum_error,maximum(abs,Float64.(x).-Float64.(y)))
        x==y || throw(ArgumentError("physical mirror response differs on accepted projection"))
    end
    return Dict("calibrated_prescription_identity"=>calibrated_identity,"source_prescription_identity"=>source_identity,
        "source_definition_sha256"=>PipeWireAORTC.Common.sha256_file(source.path),
        "calibrated_definition_sha256"=>PipeWireAORTC.Common.sha256_file(upstream.path),
        "effective_settings_identity"=>PipeWireAORTC.InstrumentDefinition.scientific_identity(IC.canonical(original)),
        "pupil_schema"=>a.schema,"pupil_shape"=>collect(a.shape),"pupil_coordinates"=>"mirror[x,y]; packet[quantity,y,x]",
        "pupil_amplitude_identity"=>PipeWireAORTC.InstrumentDefinition.scientific_identity(IC.canonical(amplitude)),
        "responses"=>m+1,"maximum_opd_error_m"=>maximum_error,"backend"=>"cpu","accepted"=>true)
end

function Export.validate_pupil_source(application,simulation_path,receiver_path;prefix)
    config=PipeWireAORTC.DeploymentConfiguration.relative_asset(application,simulation_path)
    options=PipeWireAORTC.AOSOwner.configuration(config)
    PipeWireAORTC.AOSOwner.verify_pupil_source_declaration(options)
    prepared=PipeWireAORTC.PhysicalOffsets.prepare(PipeWireAORTC.DeploymentConfiguration.relative_asset(application,receiver_path);
        options.command_count,options.command_order,options.calibration_identity)
    science=PipeWireAORTC.AOSOwner.prepare_pupil_source_science(merge(options,(;backend=:cpu,device=0)))
    try
        length(prepared.inputs.total)==length(science.command) || throw(DimensionMismatch("source command differs from receiver"))
    finally
        Base.get_extension(PipeWireAORTC,:PipeWireAORTCAOSExt).PupilOutput.close!(science.publisher)
    end
    return nothing
end
