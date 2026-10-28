# Authored temporary declarations shared by cold and optional CPU tests.
Base.include(@__MODULE__, joinpath(@__DIR__, "external_optical_documents.jl"))

function zemax_component_documents(directory)
    physical, simulation = external_optical_documents()
    mkpath(joinpath(directory, "optics"))
    mkpath(joinpath(directory, "simulation"))
    prescription = joinpath(directory, "optics", "relay.zmx")
    text = "UNIT MM\nSURF 0\n TYPE STANDARD\nSURF 1\n TYPE STANDARD\n CURV 0\n DISZ 1\n DIAM 10 0\nSURF 2\n TYPE STANDARD\n CURV 0\n DISZ 0\n DIAM 10 0\nMNUM 1 1\n"
    open(prescription, "w") do io
        write(io, UInt8[0xff, 0xfe])
        for unit in transcode(UInt16, text)
            write(io, UInt8(unit & 0xff), UInt8(unit >> 8))
        end
    end
    physical["optical_prescription"] = Dict("format" => "zemax", "path" => "optics/relay.zmx",
        "sha256" => PipeWireAORTC.Common.sha256_file(prescription))
    physical["optical_planes"] = Dict{String,Any}("entrance_pupil" => Dict{String,Any}("diameter_m" => 0.012))
    recipe = Dict("schema_version" => 2, "catalogs" => [],
        "conversion" => Dict("first_surface" => 1, "initial_direction" => 1, "powered_mirrors" => []),
        "branches" => Dict("science_relay" => Dict("configuration_id" => 1, "last_surface" => 2)),
        "assumptions" => ["Synthetic centered free-space component for RTC composition tests."])
    PipeWireAORTC.Common.write_yaml(joinpath(directory, "simulation", "zemax.yaml"), recipe)
    selection = simulation["components"]["optics"]
    selection["template"] = "proper_optical_train_f32"
    selection["preparation"] = Dict{String,Any}("kind" => "zemax", "recipe" => "simulation/zemax.yaml", "branch" => "science_relay")
    config = selection["config"]
    delete!(config, "steps")
    config["temperature_c"] = Dict("\$ref" => "/settings/temperature_c")
    config["diameter_m"] = Dict("\$ref" => "/instrument/optical_planes/entrance_pupil/diameter_m")
    simulation["defaults"]["temperature_c"] = 20.0
    simulation["settings_schema"]["properties"]["temperature_c"] = Dict("type" => "number")
    for binding in values(simulation["bindings"])
        binding["type"] = "Float32"
    end
    for graph in values(simulation["graphs"])
        graph["nodes"] = [Dict{String,Any}(node) for node in graph["nodes"]]
    end
    return physical, simulation
end
