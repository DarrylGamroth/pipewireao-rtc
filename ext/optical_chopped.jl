# The retained authored controller prefix is the calibration measurement owner.
# Optical graph roles select actual F/U images; no received-sequence parity or
# exposure-command feedforward is inferred.
function optical_chopped_document(concrete, branch)
    document = deepcopy(concrete)
    specification = document["filter.graph"]
    residuals = filter(node -> node["label"] == "scc-pixel-residual-f32", specification["nodes"])
    length(residuals) == 1 || throw(ArgumentError("chopped calibration requires one SCC pixel-residual Node"))
    endpoint = only(residuals)["name"] * ":selected-residuals"
    nodes = Dict(node["name"]=>node for node in specification["nodes"])
    links = get(specification,"links",[])
    selected = Set{String}()
    visiting = Set{String}()
    function visit(name)
        name in visiting && throw(ArgumentError("cycle in chopped measurement prefix"))
        name in selected && return
        haskey(nodes,name) || throw(ArgumentError("unknown chopped measurement dependency"))
        push!(visiting,name)
        for link in links
            calibration_endpoint(link["input"])[2] == name || continue
            visit(calibration_endpoint(link["output"])[2])
        end
        delete!(visiting,name)
        push!(selected,name)
    end
    visit(only(residuals)["name"])
    labels = [nodes[name]["label"] for name in selected]
    Set(labels) == Set(("pixel-selection-f32","pixel-validity-f32",
        "chopped-image-difference-f32","scc-pixel-residual-f32")) && length(labels) == 4 ||
        throw(ArgumentError("chopped calibration requires the declared selection, validity, pair and residual prefix"))
    pair = only(node for node in values(nodes) if node["name"] in selected && node["label"] == "chopped-image-difference-f32")
    get(pair["config"],"require_acquisition_identity",false) === true ||
        throw(ArgumentError("chopped calibration requires acquisition identity continuity"))
    specification["nodes"] = [node for node in specification["nodes"] if node["name"] in selected]
    specification["links"] = [link for link in links if calibration_endpoint(link["input"])[2] in selected]
    specification["inputs"] = [port for port in specification["inputs"] if calibration_port(port).node in selected]
    specification["outputs"] = [Dict("name"=>"measurements","endpoint"=>endpoint)]
    names = Set(calibration_port(port).name for port in specification["inputs"])
    names == Set((:image,Symbol(string(branch)*"-reference-difference"))) ||
        throw(ArgumentError("chopped prefix must expose image and its matched reference-difference parameter"))
    return document
end

optical_frontend_identity(document) = PipeWireAORTC.InstrumentDefinition.scientific_identity(IC.canonical(document))

function optical_chopped_template(plan, name)
    dimensions = plan.rtc.document["dimensions"]
    calibration = merge(deepcopy(plan.frames), Dict("pixel_selection_mask"=>
        fill(true,dimensions["image_rows"]*dimensions["image_columns"])))
    context = PipeWireAORTC.InstrumentExport.graph_context(plan.instrument;
        dimensions,mirror_controls=plan.rtc.controls["deformable_mirrors"],calibration)
    graph = PipeWireAORTC.InstrumentExport.resolve_graph_configuration(getproperty(plan.templates,name),context)
    document = optical_chopped_document(graph,name)
    pair = only(node for node in document["filter.graph"]["nodes"] if node["label"] == "chopped-image-difference-f32")
    pair["config"]["trigger_high_is_fringed"] == getproperty(plan.chopping,name).trigger_high_is_fringed ||
        throw(ArgumentError("chopped measurement polarity differs from its optical publisher"))
    return document
end

function prepare_optical_chopped_frontend(document, name, reference, duration, polarity)
    parameter = Symbol(string(name)*"-reference-difference")
    reference_pixels = optical_pixels(reference,trues(size(reference)))
    graph = mktempdir() do directory
        path = joinpath(directory,"graph.conf")
        PipeWireAORTC.ScienceExport.write_spa_config(path,document)
        options = FilterGraphIsland.parse_arguments(["--graph",path,"--check","--execution","complete-frame"])
        FilterGraphIsland.prepare_service_graph(options; initial_parameters=formats -> begin
            keys(formats) == (parameter,) && getproperty(formats,parameter).shape == (length(reference_pixels),) ||
                throw(ArgumentError("chopped frontend reference parameter differs from detector pixels"))
            [parameter=>reference_pixels]
        end)
    end
    try
        formats = JuliaFilterGraph.input_formats(graph)
        keys(formats) == (:image,) && formats.image.element_type === Float32 && formats.image.shape == size(reference) ||
            throw(ArgumentError("chopped frontend must consume the actual Float32 detector image"))
        output = JuliaFilterGraph.output_formats(graph).measurements
        output.shape == (length(reference),) && output.schema == FGA.SCC_SELECTED_PIXEL_RESIDUALS_V1 ||
            throw(ArgumentError("initial chopped calibration requires the declared full-image pixel profile"))
        return (; graph,document,duration,polarity,reference=copy(reference),
            inputs=(image=zeros(Float32,size(reference)),),outputs=(measurements=zeros(Float32,length(reference)),))
    catch
        FilterGraphIsland.close_execution(graph)
        rethrow()
    end
end

function optical_chopped_measurement!(frontend, fringed, unfringed)
    JuliaFilterGraph.reset!(frontend.graph)
    for (index,image) in enumerate((fringed,unfringed))
        size(image) == size(frontend.reference) || throw(DimensionMismatch("chopped calibration image shape changed"))
        copyto!(frontend.inputs.image,optical_image(image))
        # These unpublished records describe the two explicitly selected static
        # optical roles in this calibration, not an acquired camera stream.
        metadata = FGA.SampleMetadata(index; terminal=true, acquisition_version=3,
            trigger_high=(index == 1) == frontend.polarity,
            chopped_image_kind=index == 1 ? FGA.ChoppedImageFringed : FGA.ChoppedImageUnfringed,
            exposure_duration_nanoseconds=frontend.duration,
            acquisition_identity=FGA.SampleAcquisitionIdentity(ntuple(_->UInt8(0xc1),16),1,index))
        result = JuliaFilterGraph.process!(frontend.outputs,frontend.graph,frontend.inputs,(image=metadata,))
        if index == 1
            result === FGA.SccPixelResidualIncompletePair || throw(ArgumentError("chopped frontend did not prime on its first optical role"))
        else
            result isa NamedTuple && all(values(result)) || throw(ArgumentError("chopped frontend rejected its complete pair: $result"))
        end
    end
    rows,columns = size(frontend.reference)
    return permutedims(reshape(copy(frontend.outputs.measurements),columns,rows),(2,1))
end
