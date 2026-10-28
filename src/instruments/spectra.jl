# Physical filters contain measured intensity transmission. Numerical spectral
# quadrature and interpolation remain in AOS; this boundary validates metadata.
function _validate_optical_filters(value)
    filters = _declaration_object(value, "optical filters")
    length(filters) <= 64 || throw(ArgumentError("instrument allows at most 64 optical filters"))
    for (name, value) in filters
        _declaration_identifier(name, "optical filter identifier")
        name != "none" || throw(ArgumentError("none is reserved for an unfiltered optical path"))
        filter = fields(value, ("wavelength_m", "transmission"), ("wavelength_m", "transmission"), "optical filter $name")
        wavelengths = _declaration_array(filter["wavelength_m"], "optical filter $name wavelength_m")
        transmission = _declaration_array(filter["transmission"], "optical filter $name transmission")
        2 <= length(wavelengths) <= 4096 && length(wavelengths) == length(transmission) ||
            throw(ArgumentError("optical filter $name requires 2:4096 paired samples"))
        all(isfinite_positive, wavelengths) && all(i -> wavelengths[i] > wavelengths[i-1], 2:length(wavelengths)) ||
            throw(ArgumentError("optical filter $name wavelengths must be positive, finite and strictly increasing"))
        all(value -> isfinite_real(value) && 0 <= value <= 1, transmission) ||
            throw(ArgumentError("optical filter $name transmission must be finite in [0,1]"))
    end
    return nothing
end

"Validate per-path spectral settings independently of any executable graph."
function validate_optical_spectra(configured, instrument)
    haskey(configured, "spectra") || return nothing
    haskey(configured, "wavelength_um") && throw(ArgumentError("spectra replaces the root wavelength_um setting"))
    spectra = _declaration_object(configured["spectra"], "simulation spectra")
    paths = _declaration_object(get(instrument, "optical_paths", Dict()), "physical optical paths")
    !isempty(paths) && Set(keys(spectra)) == Set(keys(paths)) ||
        throw(ArgumentError("simulation spectra must cover every physical optical path exactly"))
    for (name, value) in spectra
        spectrum = fields(value, ("wavelength_um", "fractional_bandwidth", "samples", "filter"),
            ("wavelength_um", "fractional_bandwidth", "samples", "filter"), "spectrum $name")
        isfinite_positive(spectrum["wavelength_um"]) || throw(ArgumentError("spectrum $name wavelength_um must be positive and finite"))
        width = spectrum["fractional_bandwidth"]
        isfinite_real(width) && 0 <= width < 2 || throw(ArgumentError("spectrum $name fractional_bandwidth must be in [0,2)"))
        samples = spectrum["samples"]
        ispositive_integer(samples) && samples <= 64 || throw(ArgumentError("spectrum $name samples must be in 1:64"))
        (width == 0 ? samples == 1 : samples >= 2) ||
            throw(ArgumentError("spectrum $name requires one sample for zero bandwidth and at least two for a finite band"))
        filter = _declaration_text(spectrum["filter"], "spectrum $name filter")
        installed = get(paths[name], "filters", [])
        allowed = isempty(installed) ? ("none",) : installed
        filter in allowed || throw(ArgumentError("spectrum $name selects a filter not installed in that optical path"))
    end
    return nothing
end

"Resolve the shared optical settings form against declared paths and defaults."
function resolve_optical_settings_schema!(document, instrument; editable=false)
    defaults = document["defaults"]
    validate_optical_spectra(defaults, instrument)
    haskey(defaults, "spectra") || return nothing
    schema = document["settings_schema"]
    properties = schema["properties"]
    delete!(properties, "wavelength_um")
    required = get!(schema, "required", collect(keys(properties)))
    filter!(name -> name != "wavelength_um", required)
    "spectra" in required || push!(required, "spectra")
    paths = instrument["optical_paths"]
    spectra = Dict{String,Any}()
    for name in sort!(collect(keys(paths)))
        installed = get(paths[name], "filters", [])
        filters = isempty(installed) ? ["none"] : copy(installed)
        spectra[name] = Dict("type" => "object", "title" => name,
            "additionalProperties" => false,
            "required" => ["wavelength_um", "fractional_bandwidth", "samples", "filter"],
            "properties" => Dict(
                "wavelength_um" => Dict("type" => "number", "title" => "Central wavelength (micrometres)", "exclusiveMinimum" => 0),
                "fractional_bandwidth" => Dict("type" => "number", "title" => "Fractional bandwidth", "minimum" => 0, "exclusiveMaximum" => 2),
                "samples" => Dict("type" => "integer", "title" => "Spectral samples", "minimum" => 1, "maximum" => 64),
                "filter" => Dict("type" => "string", "title" => "Optical filter", "enum" => filters)))
    end
    properties["spectra"] = Dict("type" => "object", "title" => "Optical spectra",
        "readOnly" => !editable, "additionalProperties" => false,
        "required" => sort!(collect(keys(paths))), "properties" => spectra)
    validate_settings_schema(schema)
    return nothing
end
