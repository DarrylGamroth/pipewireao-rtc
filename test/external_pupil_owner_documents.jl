Base.include(@__MODULE__,joinpath(@__DIR__,"external_optical_documents.jl"))

function external_pupil_owner_documents(directory)
    IC = PipeWireAORTC.InstrumentConfiguration
    C = PipeWireAORTC.Common
    physical, simulation = external_optical_documents()
    physical["optical_paths"] = Dict(name=>Dict("sensor"=>name,
        "lyot_stop_port"=>name=="scc" ? "transmitted" : "reflected") for name in ("scc","llowfs"))
    for (name,sensor) in physical["wavefront_sensors"]
        sensor["acquisition"] = Dict("exposure_duration_s"=>name=="scc" ? 0.004 : 0.002)
    end
    path = write_external_optical_documents(directory,physical,simulation)
    mkpath(joinpath(directory,"rtc"))
    C.write_yaml(joinpath(directory,"rtc/mirror-controls.yaml"),Dict("schema_version"=>1,"deformable_mirrors"=>Dict()))
    rtc = joinpath(directory,"rtc/configuration.yaml")
    C.write_yaml(rtc,Dict("schema_version"=>1,"instrument"=>"../instrument.yaml",
        "mirror_controls"=>"rtc/mirror-controls.yaml","dimensions"=>Dict("cal2_mode_count"=>3),
        "publication"=>"instrument.json","calibration_identity"=>"sha256:"*repeat("a",64)))
    C.write_json(joinpath(directory,"instrument.json"),IC.publication(rtc))
    declaration = IC.load_simulation(path)
    document = Dict{String,Any}("version"=>4,"mode"=>"external-pupil",
        "plant"=>Dict("definition"=>"simulation/definition.yaml","settings"=>Dict()),
        "pupil_node"=>"optical-pupil","sensor_nodes"=>Dict("scc"=>"optical-scc","llowfs"=>"optical-llowfs"),
        "backend"=>"cpu","device"=>0,"instrument"=>"instrument.json",
        "rtc_configuration"=>"rtc/configuration.yaml","calibration_identity"=>"sha256:"*repeat("a",64),
        "prescription_identity"=>IC.prescription_identity(declaration,IC.settings(declaration)))
    config = joinpath(directory,"simulation.conf")
    C.write_json(config,document)
    return (;document,config,path,physical,simulation)
end
