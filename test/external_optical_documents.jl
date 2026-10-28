# Authored temporary declarations shared by cold and optional CPU tests.
function external_optical_documents()
    physical = Dict{String,Any}("schema_version" => 1, "id" => "external-optical-test",
        "deformable_mirrors" => Dict(),
        "optical_input" => Dict("plane" => "upstream_of_apodizer",
            "diameter_m" => 0.012, "curvature" => "collimated", "registration" => "declared"),
        "wavefront_sensors" => Dict(name => Dict{String,Any}("kind" => name,
            "detector" => Dict{String,Any}("name" => detector))
            for (name,detector) in (("scc","SAPHIRA"),("llowfs","CRED2"))))
    reference(key) = Dict("\$ref" => key)
    config = Dict{String,Any}("resolution" => reference("/settings/resolution"),
        "pupil_resolution" => reference("/settings/pupil_resolution"),
        "diameter_m" => reference("/instrument/optical_input/diameter_m"),
        "wavelength_um" => reference("/settings/wavelength_um"),
        "steps" => [Dict("op" => "multiply", "amplitude" => 0.5)],
        "pupil_opd_schema" => "example.pupil-opd/1",
        "pupil_amplitude_schema" => "example.pupil-amplitude/1", "output_schema" => "example.intensity/1")
    graph = Dict{String,Any}("schema_version" => 1, "name" => "external_optical_test",
        "nodes" => [Dict("name" => "optics")],
        "inputs" => [Dict("name" => "pupil_opd", "binding" => "pupil_opd", "destination" => "optics.pupil_opd"),
            Dict("name" => "pupil_amplitude", "binding" => "pupil_amplitude", "destination" => "optics.pupil_amplitude")],
        "outputs" => [Dict("name" => "intensity", "source" => "optics.output")])
    simulation = Dict{String,Any}("schema_version" => 1, "id" => "external-optical-test",
        "instrument" => "../instrument.yaml", "frame_period_s" => 0.002,
        "defaults" => Dict("profile" => "reference", "resolution" => 8, "pupil_resolution" => 4, "wavelength_um" => 1.55),
        "settings_schema" => Dict("type" => "object", "properties" => Dict(
            "profile" => Dict("type" => "string", "enum" => ["reference"]),
            "resolution" => Dict("type" => "integer", "minimum" => 4, "maximum" => 64),
            "pupil_resolution" => Dict("type" => "integer", "minimum" => 1, "maximum" => 32),
            "wavelength_um" => Dict("type" => "number", "exclusiveMinimum" => 0))),
        "graphs" => Dict("scc" => deepcopy(graph), "llowfs" => deepcopy(graph)),
        "profiles" => Dict("reference" => Dict("nodes" => Any[], "parameters" => Any[])),
        "components" => Dict("optics" => Dict("template" => "proper_optical_train_f64", "config" => config)),
        "bindings" => Dict(name => Dict("kind" => "zeros", "type" => "Float64",
            "shape" => ["pupil_resolution", "pupil_resolution"]) for name in ("pupil_opd", "pupil_amplitude")),
        "settings_bindings" => Any[])
    return physical, simulation
end

function write_external_optical_documents(directory, physical, simulation)
    mkpath(joinpath(directory, "simulation"))
    PipeWireAORTC.Common.write_yaml(joinpath(directory, "instrument.yaml"), physical)
    path = joinpath(directory, "simulation", "definition.yaml")
    PipeWireAORTC.Common.write_yaml(path, simulation)
    return path
end

function authored_response!(directory, physical, simulation; mtf=false)
    detector = "low_order_detector"
    config = Dict{String,Any}("rows"=>8, "columns"=>8, "pixel_sampling_m"=>[1e-3,1e-3],
        "spectral_channel"=>"h_band", "exposure_duration_s"=>0.002, "quantum_efficiency"=>0.8,
        "rng_seed"=>1, "photon_rate_schema"=>"example.photons-per-second/1", "frame_schema"=>"example.electrons/1")
    simulation["components"][detector] = Dict("template"=>"ingaas", "sensor"=>"llowfs", "config"=>config)
    simulation["bindings"]["photon_rate"] = Dict("kind"=>"zeros", "type"=>"Float32", "shape"=>[8,8])
    physical["wavefront_sensors"]["llowfs"]["acquisition"] = Dict("exposure_duration_s"=>0.002)
    graph = Dict{String,Any}("schema_version"=>1,"name"=>"low_order_response",
        "nodes"=>Any[Dict("name"=>detector)],
        "inputs"=>[Dict("name"=>"photon_rate","binding"=>"photon_rate","destination"=>detector*".photon_rate")],
        "outputs"=>[Dict("name"=>"frame","source"=>detector*".frame")])
    if mtf
        transfer_path = joinpath(directory, "mtf.fits")
        IC.FITSIO.FITS(transfer_path,"w") do file
            write(file, ones(Float32,8,8))
        end
        simulation["bindings"]["mtf_transfer"] = Dict("kind"=>"fits", "path"=>"mtf.fits", "hdu"=>1,
            "axes"=>[1,2], "type"=>"Float32", "shape"=>[8,8],
            "sha256"=>PipeWireAORTC.Common.sha256_file(transfer_path))
        simulation["components"]["mtf"] = Dict("template"=>"pixel_mtf",
            "bindings"=>Dict("transfer"=>"mtf_transfer"), "config"=>Dict("input_shape"=>[8,8],
                "padding"=>0,"input_schema"=>config["photon_rate_schema"],
                "output_schema"=>config["photon_rate_schema"]))
        pushfirst!(graph["nodes"],Dict("name"=>"mtf"))
        only(graph["inputs"])["destination"] = "mtf.input"
        graph["links"] = [Dict("source"=>"mtf.output","destination"=>detector*".photon_rate")]
    end
    PipeWireAORTC.Common.write_yaml(joinpath(directory,"simulation","low_order_response.yaml"),graph)
    simulation["observations"] = Dict("low_order"=>Dict("graph"=>"simulation/low_order_response.yaml",
        "detector"=>detector,"normalized_to_photon_rate"=>100.0))
    return graph
end
