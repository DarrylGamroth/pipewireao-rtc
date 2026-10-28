# Physical sampled masks are field-amplitude responses, not intensity maps.
# FITS decoding stays at the existing cold artifact boundary (no AOS/GPU load).
function mask_artifact(reference, directory, label; amplitude=false)
    required = ("path", "sha256", "hdu", "axes", "type", "shape")
    fields(reference, required, required, label)
    _validate_optical_asset(Dict(key => reference[key] for key in ("path", "sha256")), directory, label; check_hash=false)
    _validate_artifact_values(reference, directory, label)
    length(reference["shape"]) == 2 || throw(ArgumentError("$label must have rank two"))
    reference["type"] in ("Float32", "Float64") || throw(ArgumentError("$label requires Float32 or Float64"))
    T = reference["type"] == "Float32" ? Float32 : Float64
    source = Artifacts.FITSArtifact(D.relative_asset(directory, reference["path"]);
        hdu=reference["hdu"], axes=reference["axes"])
    prepared = Artifacts.prepare(source, T, reference["shape"])
    prepared.provenance["original_sha256"] == reference["sha256"] ||
        throw(ArgumentError("$label SHA-256 mismatch"))
    amplitude && !all(value -> 0 <= value <= 1, prepared.data) &&
        throw(ArgumentError("$label field amplitude must be in [0,1]"))
    return nothing
end

function _validate_optical_masks(value, directory)
    masks = _declaration_object(value, "optical masks")
    1 <= length(masks) <= 16 || throw(ArgumentError("instrument requires 1:16 optical masks"))
    for (name, mask) in masks
        _declaration_identifier(name, "optical mask identifier")
        responses = _declaration_object(mask, "optical mask responses")
        !isempty(responses) && all(port -> port in ("transmitted", "reflected"), keys(responses)) ||
            throw(ArgumentError("optical mask requires transmitted and/or reflected responses"))
        for (port, response) in responses
            label = "optical mask $name $port"
            required = ("amplitude", "sampling_m", "center_pixel", "outside_amplitude", "outside_phase_rad")
            fields(response, (required..., "phase", "wavelength_m"), required, label)
            for (key, valid) in (("sampling_m", isfinite_positive), ("center_pixel", isfinite_real))
                pair = _declaration_array(response[key], "$label $key")
                length(pair) == 2 && all(valid, pair) || throw(ArgumentError("$label $key requires a finite row/column pair"))
            end
            isfinite_real(response["outside_amplitude"]) && 0 <= response["outside_amplitude"] <= 1 ||
                throw(ArgumentError("$label outside_amplitude must be in [0,1]"))
            isfinite_real(response["outside_phase_rad"]) || throw(ArgumentError("$label outside_phase_rad must be finite"))
            haskey(response, "wavelength_m") && !isfinite_positive(response["wavelength_m"]) &&
                throw(ArgumentError("$label wavelength_m must be positive and finite"))
            mask_artifact(response["amplitude"], directory, "$label amplitude"; amplitude=true)
            if haskey(response, "phase")
                haskey(response, "wavelength_m") || throw(ArgumentError("$label phase requires wavelength_m"))
                mask_artifact(response["phase"], directory, "$label phase")
                response["phase"]["shape"] == response["amplitude"]["shape"] ||
                    throw(ArgumentError("$label phase and amplitude logical shapes must agree"))
            end
        end
    end
    return nothing
end

selected_optical_mask_responses(document, instrument, graphs::AbstractDict, configured=document["defaults"]) =
    selected_optical_mask_responses(document, instrument, optical_graph_names(document, instrument, keys(graphs)), configured)

function selected_optical_mask_responses(document, instrument, path_names, configured=document["defaults"])
    selections = get(document["defaults"], "masks", Dict())
    selected = Tuple{String,String,Any}[]
    selections isa AbstractDict || (selections = Dict())
    proposed = get(configured, "masks", Dict())
    proposed isa AbstractDict || (proposed = Dict())
    for role in union(keys(selections), keys(proposed))
        original, updated = get(selections, role, nothing), get(proposed, role, nothing)
        if is_fits_mask_selection(original) || is_fits_mask_selection(updated)
            original == updated || throw(ArgumentError("FITS mask selections require regenerated optical graphs and bindings"))
        end
    end
    for (role, selection) in selections
        # Application-local schemas may use their own editable mask settings.
        # Only the explicit shared FITS selection requests physical bindings.
        is_fits_mask_selection(selection) || continue
        role in ("apodizer", "focal_plane", "lyot") || throw(ArgumentError("unknown optical mask role $role"))
        fields(selection, ("kind", "mask"), ("kind", "mask"), "simulation $role FITS mask")
        name = _declaration_identifier(selection["mask"], "selected optical mask")
        masks = get(instrument, "optical_masks", Dict())
        haskey(masks, name) || throw(ArgumentError("unknown selected optical mask $name"))
        ports = if role == "lyot"
            paths = get(instrument, "optical_paths", Dict())
            all(mode -> haskey(paths, mode), path_names) ||
                throw(ArgumentError("sampled Lyot masks require a physical optical path for each simulation graph"))
            unique([paths[mode]["lyot_stop_port"] for mode in path_names])
        else
            ("transmitted",)
        end
        for port in ports
            responses = masks[name]
            haskey(responses, port) || throw(ArgumentError("selected optical mask $name has no $port response"))
            response = responses[port]
            if haskey(response, "wavelength_m")
                if haskey(configured, "spectra")
                    validate_optical_spectra(configured, instrument)
                    for path in path_names
                        role == "lyot" && instrument["optical_paths"][path]["lyot_stop_port"] != port && continue
                        spectrum = configured["spectra"][path]
                        spectrum["fractional_bandwidth"] == 0 ||
                            throw(ArgumentError("selected optical mask $name has one measured wavelength and cannot cover a finite band on $path"))
                        isapprox(response["wavelength_m"], spectrum["wavelength_um"] * 1e-6; rtol=1e-12, atol=0) ||
                            throw(ArgumentError("selected optical mask $name wavelength differs from spectrum $path"))
                    end
                else
                    wavelength_um = get(configured, "wavelength_um", nothing)
                    isfinite_positive(wavelength_um) && isapprox(response["wavelength_m"], wavelength_um * 1e-6; rtol=1e-12, atol=0) ||
                        throw(ArgumentError("selected optical mask $name wavelength differs from simulation wavelength"))
                end
            end
            push!(selected, (role, port, response))
        end
    end
    return selected
end

is_fits_mask_selection(value) = value isa AbstractDict && get(value, "kind", nothing) == "fits"

function expand_optical_mask_bindings!(document, instrument, graphs)
    for (role, port, response) in selected_optical_mask_responses(document, instrument, graphs)
        for field in ("amplitude", "phase")
            haskey(response, field) || continue
            binding = merge(Dict{String,Any}("kind" => "fits"), deepcopy(response[field]))
            add_component_binding!(document["bindings"], role * "_" * port * "_" * field, binding)
        end
    end
    return nothing
end
