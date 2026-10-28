# Expected residual under the ideal independent Poisson/Gaussian simulation law.
# Native UInt16 ADC exposures remain the only detector/frontend transport.
# The conditional envelope is qualified for the explicitly checked Host cold
# configuration below. It is separate from Monte Carlo sampling uncertainty.
optical_host_poisson_mean(x) = -log(Float64(exp(-Float32(x))))

function optical_conditional_average(λ,values)
    0 <= λ <= 8 || throw(ArgumentError("conditional envelope is qualified for Poisson mean in [0,8]"))
    probability = exp(-λ)
    mean = probability*values[1]
    for k in 1:64
        probability *= λ/k
        mean += probability*values[k+1]
    end
    return mean+1e-24
end

function optical_conditional_envelopes(;gain,factor,scale,bias,readnoise_e)
    gain==5000 && scale==1/64 && bias==1024 && 0<factor<=1 && 678<=readnoise_e<=679 ||
        throw(ArgumentError("unqualified cold detector/ADC expectation envelope"))
    u = 2.0^-24
    expected_absolute_normal = sqrt(2/π)
    adc_error = Float64[]
    calibrated_error = Float64[]
    for k in 0:65
        coefficient = Float64(Float32(Float32(factor)*sqrt(Float32(k))))
        coefficient_error = abs(coefficient-factor*sqrt(k))
        em_error = gain*(u*(2+u)*k+(coefficient_error+
            coefficient*((1+u)^3-1+u*(1+u)^3))*expected_absolute_normal)
        em_maximum = gain*(1+u)^2*(k+coefficient*(1+u)^2*12)
        read_maximum = readnoise_e*(1+u)^2*12
        shift = scale*readnoise_e*(2u+u^2)*12+scale*u*(em_maximum+read_maximum)+
            u*(scale*(1+u)*(em_maximum+read_maximum)+bias)
        # Independent read Gaussian smooths every ADC threshold. For this cold
        # envelope, |Z|>12, ADC rails and Poisson k>64 tails contribute <1e-24.
        error = scale*em_error+2shift+1e-24
        push!(adc_error,error)
        absolute_charge = scale*gain*(1+u)^2*(k+coefficient*(1+u)^2*expected_absolute_normal)+
            scale*readnoise_e*(1+u)^2*expected_absolute_normal+0.5+shift
        push!(calibrated_error,error+u*absolute_charge)
    end
    # Monotone envelopes permit the endpoint λ=8 for the entire qualified domain.
    adc_error = accumulate(max,adc_error)
    calibrated_error = accumulate(max,calibrated_error)
    return (;adc=adc_error,calibrated_input=calibrated_error,
        adc_lipschitz=optical_conditional_average(8.0,adc_error[1:65]+adc_error[2:66]),
        calibrated_input_lipschitz=optical_conditional_average(8.0,calibrated_error[1:65]+calibrated_error[2:66]))
end

"Differential selected-pixel and control-variate centering error, in native pupil-block order."
function optical_differential_response_bound(;absolute_R,selected_flat,selected_lambda_delta,
        selected_baseline_error,flux_lambda_delta,flux_baseline_error,
        adc_lipschitz,calibrated_input_lipschitz,gain_i,gain_j,rz_i,rz_j,
        mu_i,mu_j,mu_lower,deterministic_shift,gain_sampling_allowance)
    flux_error = adc_lipschitz*flux_lambda_delta
    gain_error = abs(gain_i-gain_j)+gain_sampling_allowance+flux_error/mu_lower^2+
        2flux_baseline_error*abs(mu_i-mu_j)/mu_lower^3
    selected = (max(gain_i,gain_j)+gain_sampling_allowance/2)*
        LA.norm(absolute_R*(selected_flat.*calibrated_input_lipschitz.*selected_lambda_delta))+
        gain_error*LA.norm(absolute_R*selected_baseline_error)
    centering = LA.norm(rz_i)*flux_error/mu_i^2+
        LA.norm(rz_i/mu_i^2-rz_j/mu_j^2)*flux_baseline_error
    return (;selected,centering,deterministic_shift,total=selected+centering+deterministic_shift)
end

optical_average(samples) = sum(samples) / length(samples)
function optical_standard_error(samples)
    length(samples) > 1 || throw(ArgumentError("sampling uncertainty requires at least two samples"))
    mean = optical_average(samples)
    return sqrt(sum(x -> abs2(x-mean),samples)/(length(samples)*(length(samples)-1)))
end
function optical_vector_standard_error(samples,mean)
    length(samples) > 1 || throw(ArgumentError("vector uncertainty requires independent batches"))
    return sqrt(sum(column -> sum(abs2,column-mean),samples)/(length(samples)*(length(samples)-1)))
end

function optical_expectation_options(samples,rounding_samples,training_seed,validation_seed)
    samples isa Integer && 128 <= samples <= 8192 && samples%8 == 0 ||
        throw(ArgumentError("host expectation samples must be a multiple of eight in 128:8192"))
    rounding_samples isa Integer && 128 <= rounding_samples <= samples && rounding_samples%8 == 0 ||
        throw(ArgumentError("host expectation rounding_samples must be a multiple of eight in 128:samples"))
    all(seed -> seed isa Integer && !(seed isa Bool) && 0 <= seed < typemax(Int32)-1,
        (training_seed,validation_seed)) && training_seed != validation_seed && training_seed != validation_seed+1 ||
        throw(ArgumentError("host expectation requires distinct nonnegative Int32 training/validation seeds"))
    return nothing
end

function optical_expectation_nodes(document)
    nodes = document["filter.graph"]["nodes"]
    selected = map((FGA.PixelCalibrationU16F32,FGA.PyramidPupilImageF32,FGA.PyramidPupilReconstructorF32)) do declaration
        label = FGA.algorithm_label(declaration)
        String(only(node["name"] for node in nodes if node["label"]==label))
    end
    return (;raw=selected[1],pyramid=selected[2],reconstruction=selected[3])
end

"Prove the captured photon rate and raw HIL frame are the executed direct detector/ADC chain."
function optical_expectation_chain(runtime,calibration,frame_output)
    function chain(graph)
        detector = only(node for node in graph["nodes"] if node["type"]=="detector")
        adc = only(node for node in graph["nodes"] if node["type"]=="detector_frame_layout_f32")
        links = get(graph,"links",[])
        inputs = get(graph,"inputs",[])
        delayed = get(graph,"delayed_links",[])
        frame_source = only(output["source"] for output in graph["outputs"] if output["name"]==frame_output)
        photon_source = only(output["source"] for output in graph["outputs"] if output["name"]=="photon_rate")
        frame_source==adc["name"]*".frame" ||
            throw(ArgumentError("expected-response HIL frame must directly expose the executed ADC frame"))
        for (destination,source) in ((adc["name"]*".detector_frame",detector["name"]*".frame"),
                (detector["name"]*".photon_rate",photon_source))
            producers = filter(link->link["destination"]==destination,links)
            length(producers)==1 && only(producers)["source"]==source &&
                !any(input->get(input,"destination",nothing)==destination,inputs) &&
                !any(link->get(link,"destination",nothing)==destination,delayed) ||
                throw(ArgumentError("expected-response capture must match the executed direct photon/detector/ADC links"))
        end
        return (;detector=detector["name"],adc=adc["name"],photon_source,frame_source,
            adc_configuration=adc["config"])
    end
    executed,held = chain(runtime),chain(calibration)
    executed==held || throw(ArgumentError("runtime and held calibration detector/ADC chains differ"))
    return Dict("detector"=>executed.detector,"adc"=>executed.adc,"photon_source"=>executed.photon_source,
        "frame_source"=>executed.frame_source,"HIL_frame_output"=>frame_output)
end

"Expected residual, native sampling, and independent validation for one explicit probe."
function optical_expected_reference(system,frontend,calibration,commands,mirror,h,runtime;
        samples=512,rounding_samples=128,training_seed=200002,validation_seed=400002,
        tolerance=0.05)
    optical_expectation_options(samples,rounding_samples,training_seed,validation_seed)
    Detectors = AdaptiveOpticsSim.Detectors
    owner = Base.get_extension(PipeWireAORTC,:PipeWireAORTCAOSExt)
    detector_node = only(node for node in runtime["nodes"] if get(node,"type",nothing)=="detector")
    adc_node = only(node for node in runtime["nodes"] if get(node,"type",nothing)=="detector_frame_layout_f32")
    adc = adc_node["config"]
    adc["rounding"] == "nearest_even" && adc["range"] == [0,16383] &&
        adc["output_element_type"] == "uint16" && adc["origin"] == [0,0] ||
        throw(ArgumentError("host expectation requires qualified nearest-even UInt16 ADC rails/layout"))
    all(key -> get(detector_node["config"],key,false) === true,("photon_noise","readout_noise")) ||
        throw(ArgumentError("host expectation requires the executed independent photon/readnoise law"))
    selected_nodes = optical_expectation_nodes(frontend.document)
    raw_node = selected_nodes.raw
    raw_declaration = only(node for node in frontend.document["filter.graph"]["nodes"] if node["name"]==raw_node)
    raw_declaration["label"] == "pixel-calibration-u16-f32" &&
        keys(frontend.graph.input_formats) == (:raw,) && frontend.graph.input_formats.raw.element_type===UInt16 &&
        frontend.graph.output_formats.residual.element_type===Float32 ||
        throw(ArgumentError("host expectation requires the deployed UInt16 pixel-calibration and Float32 residual frontend"))
    pyramid_node = selected_nodes.pyramid
    reconstruction_node = selected_nodes.reconstruction
    pixel = only(node for node in frontend.graph.nodes if String(node.name)==raw_node).prepared.plan
    pyramid = only(node for node in frontend.graph.nodes if String(node.name)==pyramid_node).prepared
    reconstruction = only(node for node in frontend.graph.nodes if String(node.name)==reconstruction_node).prepared
    eltype(reconstruction.plan.matrix)===Float32 || throw(ArgumentError("host expectation requires the frozen Float32 reconstructor"))
    pp = pyramid.plan
    R = Float64.(reconstruction.plan.matrix)
    absolute_R = abs.(R)
    selected_indices = vec(pp.selected_indices)
    regions = pp.pupil_regions
    mean_scale = Float64(pp.normalization.mean_scale)
    flat = Float64.(pixel.flat)
    background = Float64.(pixel.background)
    weights = zeros(Float64,size(flat))
    region_weights = Float64[]
    region_backgrounds = Float64[]
    for (row,column) in regions.origins
        rows = row+1:row+regions.region_size[1]
        columns = column+1:column+regions.region_size[2]
        weight,bias = first(flat[rows,columns]),first(background[rows,columns])
        all(==(weight),flat[rows,columns]) && all(==(bias),background[rows,columns]) ||
            throw(ArgumentError("host expectation exact rectangle control variate needs constant pupil flat/background"))
        weights[rows,columns] .+= mean_scale .* flat[rows,columns]
        push!(region_weights,weight)
        push!(region_backgrounds,bias)
    end
    all(>=(0),flat) || throw(ArgumentError("host expectation requires nonnegative pixel gains"))
    flux = FGA.prepare_algorithm(FGA.PyramidPupilFluxU16F64,
        FGA.PyramidPupilFluxU16F64Configuration(image_size=regions.image_size,
            pupil_size=regions.region_size,pupil_origins=[collect(origin) for origin in regions.origins]))
    flux_values = zeros(Float64,4)
    prefix = Calibration.calibration_graph(system.application;
        inputs=(raw=raw_node*":raw",),outputs=(mean=pyramid_node*":mean-pupil-intensity",))
    try
        pin = map(format->zeros(format.element_type,format.shape),prefix.graph.input_formats)
        pout = map(format->zeros(format.element_type,format.shape),prefix.graph.output_formats)
        pworkspace = only(node for node in prefix.graph.nodes if String(node.name)==pyramid_node).prepared.workspace
        fin = map(format->zeros(format.element_type,format.shape),frontend.graph.input_formats)
        fout = map(format->zeros(format.element_type,format.shape),frontend.graph.output_formats)
        noise_node = deepcopy(detector_node)
        noise_node["config"]["rng_seed"] = training_seed
        graph = Dict("schema_version"=>1,"name"=>"optical_expected_residual",
            "nodes"=>[noise_node,deepcopy(adc_node)],
            "inputs"=>[Dict("name"=>"photon_rate","binding"=>"photon_rate","destination"=>noise_node["name"]*".photon_rate")],
            "links"=>[Dict("source"=>noise_node["name"]*".frame","destination"=>adc_node["name"]*".detector_frame")],
            "outputs"=>[Dict("name"=>"raw","source"=>adc_node["name"]*".frame")])
        flat_raw = Array(modal_frame!(system.plant,commands))
        rate_shape = size(HIL.graph_output(system.plant.graph,:photon_rate))
        function prepare_noise(seed)
            document = deepcopy(graph)
            document["nodes"][1]["config"]["rng_seed"] = seed
            definition = HIL.load_algorithm_graph(document;bindings=(photon_rate=zeros(Float32,rate_shape),),
                node_types=owner.configured_graph_node_types())
            return HIL.prepare_algorithm_graph(definition;target=AdaptiveOpticsSim.Backends.HostComputeDevice())
        end
        noise = prepare_noise(training_seed)
        native = getproperty(noise.nodes,Symbol(noise_node["name"])).owner.prepared.detector
        native_owner = getproperty(noise.nodes,Symbol(noise_node["name"])).owner.prepared
        layout = getproperty(noise.nodes,Symbol(adc_node["name"])).owner
        sensor = native.params.sensor
        eltype(native.products.frame)===Float32 || throw(ArgumentError("qualified Host detector arithmetic requires Float32"))
        sensor isa Detectors.EMCCDSensor && sensor.operating_mode isa Detectors.LinearEMMode &&
            sensor.output_path isa Detectors.EMOutput && sensor.multiplication_model isa Detectors.ClippedGaussianMultiplicationApproximation &&
            native.params.full_well === nothing && sensor.register_full_well === nothing &&
            native.params.bits === nothing && native.params.binning == 1 && native.params.dark_current == 0 ||
            throw(ArgumentError("host expectation requires the qualified unsaturated linear EMCCD law"))
        gain = Float64(native.params.gain)
        factor = Float64(Detectors.em_conditional_noise_factor(sensor.multiplication_model,sensor))
        scale,bias = Float64(layout.scale),Float64(layout.bias)
        readnoise = detector_node["config"]["readout_noise_e"]
        envelope = optical_conditional_envelopes(;gain,factor,scale,bias,readnoise_e=readnoise)
        cic = Float64(sensor.clock_induced_charge_per_frame)
        body(command) = begin
            getproperty(commands,mirror) .= command
            raw = Array(modal_frame!(system.plant,commands))
            rate = Array(HIL.graph_output(system.plant.graph,:photon_rate))
            input = HIL.graph_input(noise,:photon_rate)
            copyto!(input,rate)
            Detectors.fill_frame!(native,input,native.params.exposure_duration,native.params.qe,native_owner.plan.rate_scale)
            signal = Float64.(native.products.frame)
            λ = signal .+ cic
            effective_signal = optical_host_poisson_mean.(signal)
            effective_cic = optical_host_poisson_mean(cic)
            effective = effective_signal .+ effective_cic
            maximum(λ)<=8 && maximum(effective)<=8 || throw(ArgumentError("host expectation conditional envelope is qualified for per-pixel Poisson mean ≤8"))
            function expected_raw(electrons,cic_mean)
                means = zeros(Float64,size(flat))
                means[1:rate_shape[1],1:rate_shape[2]] .= map(electrons) do input_mean
                    value = Detectors.emccd_mean(input_mean,sensor;cic_electrons=cic_mean,gain)
                    value.truncation_bound_electrons*scale <= 1e-20 ||
                        throw(ArgumentError("EMCCD mean Poisson truncation exceeds qualified envelope"))
                    bias + scale*value.mean_electrons
                end
                return means
            end
            mean_raw = expected_raw(signal,cic)
            effective_raw = expected_raw(effective_signal,effective_cic)
            calibrated = Float32.(flat.*(mean_raw.-background))
            selected = permutedims(calibrated[pp.selected_indices])
            residual = zeros(Float32,size(R,1))
            FGA.process!(residual,reconstruction,selected) === nothing ||
                throw(ArgumentError("native reconstruction rejected expected calibrated pixels"))
            μ = sum(weights.*(mean_raw.-background))
            μeff = sum(weights.*(effective_raw.-background))
            μ>0 && μeff>0 || throw(ArgumentError("expected flux must be positive"))
            padded = zeros(Float64,size(flat));padded[1:rate_shape[1],1:rate_shape[2]].=effective
            adc_error = map(x->optical_conditional_average(x,envelope.adc),effective)
            cal_error = map(x->optical_conditional_average(x,envelope.calibrated_input),effective)
            aerror = zeros(Float64,size(flat));aerror[1:rate_shape[1],1:rate_shape[2]].=adc_error
            cerror = zeros(Float64,size(flat));cerror[1:rate_shape[1],1:rate_shape[2]].=cal_error
            return (;raw,rate,λ=padded,rz=Float64.(residual),μ,μeff,
                rz_eff=R*(flat.*(effective_raw.-background))[selected_indices],
                baseline_error=(flat.*cerror)[selected_indices],flux_error=sum(weights.*aerror))
        end
        count = size(calibration.projection,2)
        physical = [zeros(Float32,size(calibration.projection,1))]
        for amplitude in (h,h/2),mode in 1:count,sign in (1f0,-1f0)
            push!(physical,(sign*amplitude).*calibration.projection[:,mode])
        end
        for column in eachcol(calibration.held_out_coefficients)
            push!(physical,calibration.projection*column)
        end
        @info "Acquiring held optical exposures for expected residual" pose_count=length(physical)
        data = map(body,physical)
        return optical_expected_samples(noise,prepare_noise,prefix,pin,pout,pworkspace,
            frontend,fin,fout,pyramid.workspace,data,physical,calibration,h,
            (;R,absolute_R,selected_indices,flat,background,weights,mean_scale,
                flux,flux_values,region_weights,region_backgrounds,region_count=prod(regions.region_size),envelope),
            (;samples,rounding_samples,training_seed,validation_seed,tolerance),flat_raw)
    finally
        FilterGraphIsland.close_execution(prefix.graph)
    end
end

function optical_expected_samples(noise,prepare_noise,prefix,pin,pout,pworkspace,
        frontend,fin,fout,fworkspace,data,physical,calibration,h,model,options,flat_raw)
    (;R,absolute_R,selected_indices,flat,background,weights,mean_scale,
        flux,flux_values,region_weights,region_backgrounds,region_count,envelope) = model
    (;samples,rounding_samples,training_seed,validation_seed,tolerance) = options
    mode_count = size(calibration.projection,2)
    held_count = size(calibration.held_out_coefficients,2)
    held_start = 2+4mode_count
    μlower = minimum(entry->entry.μeff,data)
    batch_count = 8
    sample_indices = [((batch-1)*(samples÷batch_count)+1):(batch*(samples÷batch_count)) for batch in 1:batch_count]
    function capture(graph)
        HIL.step_graph!(graph)
        raw = HIL.graph_output(graph,:raw)
        eltype(raw)===UInt16 || throw(ArgumentError("native expected-response ADC must retain UInt16"))
        return raw
    end
    function sample_gain(graph,entry)
        HIL.reset_graph!(graph)
        JuliaFilterGraph.reset!(prefix.graph)
        copyto!(HIL.graph_input(graph,:photon_rate),entry.rate)
        gains = zeros(Float64,samples)
        uncorrected = similar(gains)
        fluxes = similar(gains)
        linear_fluxes = similar(gains)
        raw_peak = 0
        clipped = 0
        for sample in 1:samples
            raw = capture(graph)
            copyto!(pin.raw,raw)
            all(values(JuliaFilterGraph.process!(pout,prefix.graph,pin))) ||
                throw(ArgumentError("native pyramid rejected expected-response sample"))
            fluxes[sample] = Float64(only(pout.mean))
            uncorrected[sample] = Float64(FGA.pyramid_normalization_gain(pworkspace))
            FGA.process!(flux_values,flux,raw) === nothing ||
                throw(ArgumentError("native exact raw flux rejected a sample"))
            linear_fluxes[sample] = sum(region_weights.*(flux_values.-region_count.*region_backgrounds))*mean_scale
            # E[T] is supplied by the linear expected raw pixels. Native g(S),
            # including its nonpositive-flux rule, remains unchanged.
            gains[sample] = uncorrected[sample]+(linear_fluxes[sample]-entry.μ)/entry.μ^2
            raw_peak = max(raw_peak,maximum(raw))
            clipped += count(==(UInt16(16383)),raw)
        end
        summary = Dict("samples"=>samples,"mean_flux"=>optical_average(fluxes),
            "standard_deviation_flux"=>optical_standard_error(fluxes)*sqrt(samples),
            "minimum_flux"=>minimum(fluxes),"maximum_flux"=>maximum(fluxes),
            "zero_or_negative_flux"=>count(<=(0),fluxes),"rejected_samples"=>0,
            "high_clipped_pixels"=>clipped,"raw_peak_adu"=>Int(raw_peak),
            "gain_mean"=>optical_average(gains),"gain_standard_error"=>optical_standard_error(gains),
            "uncorrected_gain_standard_error"=>optical_standard_error(uncorrected),
            "maximum_absolute_linear_minus_native_flux"=>maximum(abs,linear_fluxes.-fluxes))
        clipped==0 && summary["zero_or_negative_flux"]==0 ||
            throw(ArgumentError("host expectation sampled clipping or nonpositive normalization flux"))
        return (;gains,summary)
    end
    @info "Sampling native expected residual" pose_count=length(data) samples=samples
    train = map(entry->sample_gain(noise,entry),data)
    validation_noise = prepare_noise(validation_seed)
    validation_indices = vcat(1,collect(held_start:held_start+held_count-1))
    validation = map(index->sample_gain(validation_noise,data[index]),validation_indices)
    gain_means = [optical_average(entry.gains) for entry in train]
    function matrix(indices;half=false)
        start = half ? 2mode_count : 0
        amplitude = half ? h/2 : h
        return hcat([(data[2+start+2(mode-1)].rz.*optical_average(train[2+start+2(mode-1)].gains[indices]).-
            data[3+start+2(mode-1)].rz.*optical_average(train[3+start+2(mode-1)].gains[indices]))./(2amplitude)
            for mode in 1:mode_count]...)
    end
    C = Float32.(matrix(1:samples))
    half = Float32.(matrix(1:samples;half=true))
    batches = map(matrix,sample_indices)
    half_batches = [matrix(indices;half=true) for indices in sample_indices]
    correction(entry,g) = entry.rz*g-entry.rz_eff*(g-(entry.μeff-entry.μ)/entry.μ^2)
    function pair_bound(i,j,gi,gj,semi,semj)
        a,b = data[i],data[j]
        delta = abs.(a.λ.-b.λ)
        allowance = 6*(semi+semj)
        return optical_differential_response_bound(;absolute_R,
            selected_flat=flat[selected_indices],selected_lambda_delta=delta[selected_indices],
            selected_baseline_error=b.baseline_error,
            flux_lambda_delta=sum(weights.*delta),flux_baseline_error=b.flux_error,
            adc_lipschitz=envelope.adc_lipschitz,calibrated_input_lipschitz=envelope.calibrated_input_lipschitz,
            gain_i=gi,gain_j=gj,rz_i=a.rz_eff,rz_j=b.rz_eff,mu_i=a.μ,mu_j=b.μ,mu_lower=μlower,
            deterministic_shift=LA.norm(correction(a,gi)-correction(b,gj)),gain_sampling_allowance=allowance)
    end
    model_columns = zeros(Float64,2mode_count)
    for index in 1:2mode_count
        i,j = 2index,2index+1
        amplitude = index<=mode_count ? h : h/2
        model_columns[index] = pair_bound(i,j,gain_means[i],gain_means[j],
            optical_standard_error(train[i].gains),optical_standard_error(train[j].gains)).total/(2amplitude)
    end
    # Measure the actual complete native F32 frontend against linear F64 pixels
    # and the SAME previous native normalization gain. Independent native draws
    # retain the deployed UInt16 path; neither noise nor normalization is replaced.
    rounding_noise = prepare_noise(validation_seed+1)
    function frontend_rounding(entry,count)
        HIL.reset_graph!(rounding_noise)
        JuliaFilterGraph.reset!(frontend.graph)
        copyto!(HIL.graph_input(rounding_noise,:photon_rate),entry.rate)
        errors = zeros(Float64,size(R,1),count)
        for sample in 0:count
            raw = capture(rounding_noise)
            previous_gain = Float64(FGA.pyramid_normalization_gain(fworkspace))
            copyto!(fin.raw,raw)
            all(values(JuliaFilterGraph.process!(fout,frontend.graph,fin))) ||
                throw(ArgumentError("complete native frontend rejected rounding validation"))
            sample==0 && continue
            pixels = flat.*(Float64.(raw).-background)
            errors[:,sample] .= Float64.(vec(fout.residual)).-R*(pixels[selected_indices].*previous_gain)
        end
        return errors
    end
    @info "Checking complete native frontend rounding" pose_count=length(data) training_samples=rounding_samples validation_samples=samples
    rounding = map(eachindex(data)) do index
        count = index==1 || index>=held_start ? samples : rounding_samples
        frontend_rounding(data[index],count)
    end
    mean_vector(array) = vec(sum(array;dims=2)./size(array,2))
    vector_sem(array) = optical_vector_standard_error(
        [mean_vector(view(array,:,((batch-1)*(size(array,2)÷8)+1):(batch*(size(array,2)÷8)))) for batch in 1:8],
        mean_vector(array))
    rounding_columns = zeros(Float64,2mode_count)
    for index in 1:2mode_count
        error = rounding[2index].-rounding[2index+1]
        amplitude = index<=mode_count ? h : h/2
        rounding_columns[index] = (LA.norm(mean_vector(error))+3vector_sem(error))/(2amplitude)
    end
    derivative_point = optical_reference_prediction_error(half,C)
    derivative_sampling = maximum(optical_reference_prediction_error(b,a) for (a,b) in zip(batches,half_batches))
    derivative_model = LA.norm(model_columns[1:mode_count]+model_columns[mode_count+1:end])/LA.norm(half)
    derivative_rounding = LA.norm(rounding_columns[1:mode_count]+rounding_columns[mode_count+1:end])/LA.norm(half)
    derivative_upper = derivative_sampling+derivative_model+derivative_rounding
    results = map(1:held_count) do held
        coefficients = Float64.(calibration.held_out_coefficients[:,held])
        i = held_start+held-1
        gi,g0 = optical_average(validation[held+1].gains),optical_average(validation[1].gains)
        measured = data[i].rz*gi-data[1].rz*g0
        prediction = Float64.(C)*coefficients
        values = [data[i].rz*optical_average(validation[held+1].gains[indices])-
            data[1].rz*optical_average(validation[1].gains[indices]) for indices in sample_indices]
        validation_sem = optical_vector_standard_error(values,measured)
        training_prediction = matrix(1:samples)*coefficients
        training_sem = optical_vector_standard_error([batch*coefficients for batch in batches],training_prediction)
        response_model = pair_bound(i,1,gi,g0,optical_standard_error(validation[held+1].gains),
            optical_standard_error(validation[1].gains)).total
        prediction_model = sum(abs.(coefficients).*model_columns[1:mode_count])
        rounding_error = rounding[i].-rounding[1]
        response_rounding = LA.norm(mean_vector(rounding_error))+3vector_sem(rounding_error)
        prediction_rounding = sum(abs.(coefficients).*rounding_columns[1:mode_count])
        denominator = LA.norm(measured)-3validation_sem-response_model-response_rounding
        numerator = LA.norm(measured-prediction)+3hypot(validation_sem,training_sem)+
            response_model+prediction_model+response_rounding+prediction_rounding
        upper = denominator>0 ? numerator/denominator : Inf
        Dict("heldout"=>held,"signal_norm_m"=>LA.norm(measured),
            "point_error_ratio"=>LA.norm(measured-prediction)/LA.norm(measured),
            "validation_vector_standard_error_m"=>validation_sem,"training_vector_standard_error_m"=>training_sem,
            "response_model_bound_m"=>response_model,"C_prediction_model_bound_m"=>prediction_model,
            "response_frontend_rounding_three_sem_m"=>response_rounding,
            "C_prediction_frontend_rounding_three_sem_m"=>prediction_rounding,
            "positive_denominator"=>denominator>0,"combined_error_ratio_upper_estimate"=>upper,
            "accepted"=>isfinite(upper)&&upper<=tolerance)
    end
    accepted = isfinite(derivative_upper) && derivative_upper<=tolerance && all(row->row["accepted"],results)
    report = Dict("method"=>"host-expectation","reference_backend"=>"host","source_backend_qualification"=>"host",
        "method_version"=>1,"mean_statistic"=>"AdaptiveOpticsSim.Detectors.emccd_mean",
        "AdaptiveOpticsSim_version"=>string(pkgversion(AdaptiveOpticsSim)),"poisson_cutoff"=>64,
        "statistical_model"=>"ideal independent Poisson/Gaussian draws represented by native Host PRNG",
        "scope"=>"conditional simulated mean response at held physical poses; not individual noisy exposures, simultaneous-loop or hardware qualification",
        "samples"=>samples,"rounding_samples"=>rounding_samples,"batch_count"=>batch_count,
        "sampling_standard_error_multiplier"=>3,"gain_model_standard_error_multiplier"=>6,
        "training_seed"=>training_seed,"validation_seed"=>validation_seed,"rounding_seed"=>validation_seed+1,
        "control_variate"=>"E[g(S)] = E[g(S)+(T-E[T])/E[T]^2], T exact affine raw UInt16 rectangle flux; native g(S) unchanged",
        "normalization"=>"independent previous/current exposure expectation; frozen linear R after expected calibrated pixels",
        "derivative_point_error"=>derivative_point,"derivative_batch_maximum"=>derivative_sampling,
        "derivative_conditional_model_bound"=>derivative_model,"derivative_frontend_rounding_three_sem"=>derivative_rounding,
        "derivative_upper_estimate"=>derivative_upper,"heldout_results"=>results,
        "training_observations"=>[entry.summary for entry in train],"validation_observations"=>[entry.summary for entry in validation],
        "maximum_effective_poisson_mean"=>maximum(entry->maximum(entry.λ),data),
        "held_out_coefficients_m"=>[collect(row) for row in eachrow(calibration.held_out_coefficients)],
        "C_column_model_bounds"=>model_columns,"C_column_frontend_rounding_three_sem"=>rounding_columns,
        "conditional_ADC_lipschitz"=>envelope.adc_lipschitz,"conditional_calibrated_input_lipschitz"=>envelope.calibrated_input_lipschitz,
        "probe_m"=>h,"half_probe_m"=>h/2,"tolerance"=>tolerance,"accepted"=>accepted,
        "uncertainty_scope"=>"conditional arithmetic/ADC envelope plus empirical three-vector-SEM native frontend and independent sampling estimates; not deterministic support bounds",
        "native_sensor_configuration"=>Dict(),"rare_flux_scope"=>"all sampled fluxes positive; declared independent Poisson/Gaussian detector law and qualified high-flux domain; no finite PRNG period or hardware-tail proof")
    trial = Dict("poke_m"=>h,"derivative_error"=>derivative_upper,
        "held_out_errors"=>[row["combined_error_ratio_upper_estimate"] for row in results],"accepted"=>accepted)
    chosen = accepted ? (;interaction=C,half_interaction=half,flat_frame=flat_raw,
        flat_residual=data[1].rz*gain_means[1],reference_sign=-1f0,poke_m=h,trial) : nothing
    return (;chosen,trials=[trial],report)
end
