using Test, JSON, SHA, PipeWireAORTC

const Instrument = PipeWireAORTC.InstrumentDefinition

module InstrumentPlantForTest
const DEFINITION = (;
    schema_version=1, id="test-instrument",
    deformable_mirrors=(; dm=(;
        layout=(; schema_version=1, name="Test mirror", grid_shape=(3, 1),
            axis_labels=("source column", "source row"),
            command_positions=((1, 1), (2, 1), (3, 1)),
            command_order="physical", provenance="test source grid"),
        shape_control=(; bases=(
            (;id="zernike",name="Zernike",units="µm OPD",coefficient_limit=0.05,
                normalization="sampled_peak",provenance="analytic geometry only",
                definition=(;kind="zernike",positions=((-0.5,0.0),(0.0,0.0),(0.5,0.0)),
                    modes=((;n=0,m=0,name="Piston"),))),
            (;id="fourier",name="Fourier",units="µm OPD",coefficient_limit=0.05,
                normalization="sampled_rms",provenance="analytic geometry only",
                definition=(;kind="fourier",positions=((-0.5,0.0),(0.0,0.0),(0.5,0.0)),
                    frequencies=((1,0),),axis_units="cycles / source axis")),
        )),
        pupil_coordinates=((-0.75, 0.0), (0.0, 0.0), (0.75, 0.0)),
    )),
    wavefront_sensors=(; wfs=(; layout=(; detector_shape=(2, 3),
        subaperture_shape=(2, 3), subaperture_origins=((0, 0),),
        provenance="zero-based [row,column]"))),
)
instrument_definition(settings::NamedTuple=NamedTuple()) = merge(DEFINITION,(;selected_settings=settings))
end

function operational_instrument()
    source = InstrumentPlantForTest.instrument_definition()
    document = JSON.parse(JSON.json(source), Dict{String,Any})
    delete!(document,"selected_settings")
    document["calibration_identity"] = "sha256:" * repeat("a", 64)
    document["scientific_identity"] = Instrument.scientific_identity(source)
    dm = document["deformable_mirrors"]["dm"]
    dm["units"] = "µm OPD"
    dm["command_scale_m"] = 1e-6
    dm["limiter"] = Dict("kind" => "amplitude", "lower" => fill(-0.5, 3), "upper" => fill(0.5, 3))
    document["schema_version"] = 2
    document["wavefront_sensors"]["wfs"]["layout"]["expected_schema"] =
        "org.calculon.ao.raw-detector-pixels/1"
    return document
end

@testset "bounded sealed instrument publication" begin
    mktempdir() do root
        package = mkpath(joinpath(root, "application"))
        path = joinpath(package, "instrument.json")
        document = operational_instrument()
        # Keep formatting and Unicode: the property digest covers exact bytes.
        json = " \n" * JSON.json(document) * "\n"
        write(path, json)
        sealed = bytes2hex(sha256(read(path)))
        spec = Dict{String,Any}("instrument" => "instrument.json",
            "artifacts" => Dict("instrument.json" => sealed))
        bindings = Dict("PACKAGE" => package)
        loaded = Instrument.load(path)
        @test loaded.json == json
        @test loaded.sha256 == sealed == Instrument.digest(json)
        @test loaded.document == document
        @test Instrument.publication(spec, bindings) == Dict(
            Instrument.PROPERTY => json, Instrument.HASH_PROPERTY => sealed)
        @test isempty(Instrument.publication(Dict(), Dict()))
        @test_throws ArgumentError Instrument.publication(spec, Dict())
        @test_throws ArgumentError Instrument.publication(spec, Dict("PACKAGE" => "relative"))
        @test_throws ArgumentError Instrument.publication(
            merge(spec, Dict("artifacts" => Dict())), bindings)
        @test_throws ArgumentError Instrument.publication(
            merge(spec, Dict("artifacts" => Dict("instrument.json" => repeat("0", 64)))), bindings)
        write(path, json * " ")
        @test_throws ArgumentError Instrument.publication(spec, bindings)
        write(path, json)

        outside = joinpath(root, "outside.json")
        write(outside, json)
        symlink(outside, joinpath(package, "escape.json"))
        for relative in ("../outside.json", "escape.json", outside, "bad\0path")
            escaped = Dict("instrument" => relative, "artifacts" => Dict(relative => sealed))
            @test_throws PipeWireAORTC.DeploymentConfiguration.DeploymentError Instrument.publication(escaped, bindings)
        end
        @test_throws ArgumentError Instrument.load(joinpath(package, "absent.json"))
        @test_throws Base.IOError Instrument.publication(
            Dict("instrument" => "absent.json"), bindings)
        at_limit = json * repeat(" ", Instrument.MAX_BYTES - ncodeunits(json))
        write(path, at_limit)
        @test ncodeunits(at_limit) == Instrument.MAX_BYTES
        @test Instrument.load(path).json == at_limit
        write(path, repeat(" ", Instrument.MAX_BYTES + 1))
        @test_throws ArgumentError Instrument.load(path)
        write(path, UInt8[0xff, 0xfe])
        @test_throws ArgumentError Instrument.load(path)
        write(path, json * "\0")
        @test_throws ArgumentError Instrument.load(path)
        write(path, "{\"schema_version\":")
        @test_throws ArgumentError Instrument.load(path)

        for mutation in (
            d -> delete!(d, "scientific_identity"),
            d -> (d["schema_version"] = 1),
            d -> (d["schema_version"] = true),
            d -> (d["unknown"] = 1),
            d -> (d["id"] = "Invalid instrument"),
            d -> (d["calibration_identity"] = "unqualified"),
            d -> (d["scientific_identity"] = "sha256:" * repeat("A", 64)),
            d -> (d["deformable_mirrors"] = Dict()),
            d -> (d["deformable_mirrors"]["dm"] = nothing),
            d -> (d["wavefront_sensors"] = Dict("bad name" => Dict())),
        )
            invalid = deepcopy(document)
            mutation(invalid)
            write(path, JSON.json(invalid))
            @test_throws ArgumentError Instrument.load(path)
        end
        @test_throws ArgumentError Instrument.bounded(Dict("value" => Inf))
        @test_throws ArgumentError Instrument.bounded(Dict("value" => :symbol))
        @test_throws ArgumentError Instrument.bounded(Dict("value" => "bad\0text"))
        @test_throws ArgumentError Instrument.bounded(Dict("value" => repeat("µ", 8193)))
        @test_throws ArgumentError Instrument.bounded(Dict(repeat("x", 129) => 1))
        @test_throws ArgumentError Instrument.bounded(zeros(16385))
        @test_throws ArgumentError Instrument.bounded([[0] for _ in 1:10000], Ref(100))
        nested = Dict{String,Any}("value" => 0)
        for _ in 1:17
            nested = Dict{String,Any}("nested" => nested)
        end
        @test_throws ArgumentError Instrument.bounded(nested)
    end
end

@testset "invalid operational mirror declarations are not published" begin
    mktempdir() do package
        path = joinpath(package, "instrument.json")
        for mutation in (
            dm -> (dm["layout"] = nothing),
            dm -> (dm["layout"]["command_positions"] = []),
            dm -> (dm["command_scale_m"] = 0),
            dm -> (dm["command_scale_m"] = true),
            dm -> (dm["limiter"] = nothing),
            dm -> (dm["limiter"]["kind"] = "unbounded"),
            dm -> (dm["limiter"]["lower"] = -0.5),
            dm -> (dm["limiter"]["lower"] = [-0.5, -0.5]),
            dm -> (dm["limiter"]["lower"][1] = 2.0),
            dm -> (dm["limiter"]["lower"][1] = 0.5),
            dm -> (dm["limiter"]["lower"] = Any[false, -0.5, -0.5]),
        )
            invalid = operational_instrument()
            mutation(invalid["deformable_mirrors"]["dm"])
            write(path, JSON.json(invalid))
            spec = Dict("instrument" => "instrument.json", "artifacts" =>
                Dict("instrument.json" => Instrument.digest(read(path, String))))
            @test_throws ArgumentError Instrument.load(path)
            @test_throws ArgumentError Instrument.publication(spec, Dict("PACKAGE" => package))
        end
        for mutation in (
            dm -> (dm["command_scale_m"] = Inf),
            dm -> (dm["limiter"]["upper"][1] = Inf),
        )
            invalid = operational_instrument()
            mutation(invalid["deformable_mirrors"]["dm"])
            @test_throws ArgumentError Instrument.validate(invalid)
        end
    end
end

@testset "selected scientific plant compatibility" begin
    mktempdir() do root
        path = joinpath(root, "instrument.json")
        document = operational_instrument()
        write(path, JSON.json(document))
        options = (; instrument=path, calibration_identity=document["calibration_identity"],
            command_count=3, frame_shape=(2, 3), command_scale=1f-6,
            frame_schema="org.calculon.ao.raw-detector-pixels/1",plant=(;settings=NamedTuple()))
        @test Instrument.verify_plant(options, InstrumentPlantForTest) === nothing
        @test Instrument.verify_plant((; instrument=nothing), Module(:NoDefinition)) === nothing
        @test_throws ArgumentError Instrument.verify_plant(options, Module(:NoDefinition))
        selected=(;pupil_registration=(;actuator_pitch=0.125))
        selected_document=deepcopy(document)
        selected_document["scientific_identity"]=Instrument.scientific_identity(
            InstrumentPlantForTest.instrument_definition(selected))
        write(path,JSON.json(selected_document))
        @test Instrument.verify_plant(merge(options,(;plant=(;settings=selected))),InstrumentPlantForTest)===nothing
        @test_throws ArgumentError Instrument.verify_plant(options,InstrumentPlantForTest)
        write(path,JSON.json(document))
        for changed in ((; calibration_identity="sha256:" * repeat("b", 64)),
                (; command_scale=1f0), (; frame_schema="org.revolt.classic.shwfs-frame.f32/1"))
            @test_throws ArgumentError Instrument.verify_plant(merge(options, changed), InstrumentPlantForTest)
        end
        for changed in ((; command_count=2), (; frame_shape=(3, 2)))
            @test_throws DimensionMismatch Instrument.verify_plant(merge(options, changed), InstrumentPlantForTest)
        end
        for mutation in (
            d -> (d["scientific_identity"] = "sha256:" * repeat("b", 64)),
            d -> (d["id"] = "other-instrument"),
            d -> (d["deformable_mirrors"]["dm"]["layout"]["command_positions"][1] = [3, 1]),
            d -> (d["deformable_mirrors"]["dm"]["shape_control"]["bases"][1]["definition"]["positions"][1] = [-0.25, 0]),
            d -> (d["deformable_mirrors"]["dm"]["shape_control"]["bases"][2]["definition"]["frequencies"][1] = [2, 0]),
            d -> (d["deformable_mirrors"]["dm"]["pupil_coordinates"][1] = [-0.5, 0]),
            d -> (d["wavefront_sensors"]["wfs"]["layout"]["subaperture_origins"][1] = [1, 0]),
            d -> (d["wavefront_sensors"]["wfs"]["layout"]["expected_schema"] = "org.revolt.classic.shwfs-frame.f32/1"),
            d -> (d["deformable_mirrors"]["extra"] = deepcopy(d["deformable_mirrors"]["dm"])),
        )
            invalid = deepcopy(document)
            mutation(invalid)
            write(path, JSON.json(invalid))
            @test_throws ArgumentError Instrument.verify_plant(options, InstrumentPlantForTest)
        end
    end
end

@testset "basis publication rejects malformed and unbounded definitions" begin
    document = operational_instrument()
    bases(d) = d["deformable_mirrors"]["dm"]["shape_control"]["bases"]
    sampled = Dict{String,Any}("id"=>"custom","name"=>"Custom","units"=>"µm OPD",
        "coefficient_limit"=>0.1,"normalization"=>"supplied","provenance"=>"measured modes",
        "definition"=>Dict("kind"=>"sampled","artifact_sha256"=>repeat("b",64),
            "modes"=>[Dict("name"=>"First","values"=>[0.25,-0.5,1.0])]))
    push!(bases(document),sampled)
    @test Instrument.validate(document) === document
    bases(document)[3]["provenance"] = repeat("p",4096)
    @test Instrument.validate(document) === document
    for mutation in (
            d -> (bases(d)[1]["extra"] = true),
            d -> (bases(d)[3]["provenance"] = repeat("p",4097)),
            d -> (bases(d)[2]["id"] = "zernike"),
            d -> (bases(d)[1]["units"] = "m"),
            d -> (bases(d)[1]["coefficient_limit"] = true),
            d -> (bases(d)[1]["normalization"] = "supplied"),
            d -> (bases(d)[1]["definition"]["modes"][1]["n"] = 13),
            d -> (bases(d)[1]["definition"]["modes"][1]["m"] = 1),
            d -> push!(bases(d)[1]["definition"]["modes"],deepcopy(bases(d)[1]["definition"]["modes"][1])),
            d -> (bases(d)[1]["definition"]["positions"][2] = bases(d)[1]["definition"]["positions"][1]),
            d -> (bases(d)[2]["definition"]["frequencies"] = [[0,0]]),
            d -> (bases(d)[2]["definition"]["frequencies"] = [[65,0]]),
            d -> (bases(d)[2]["definition"]["frequencies"] = [[1,0],[1,0]]),
            d -> (bases(d)[2]["definition"]["frequencies"] = fill([1,0],257)),
            d -> (bases(d)[3]["definition"]["artifact_sha256"] = "sha256:"*repeat("b",64)),
            d -> (bases(d)[3]["definition"]["modes"][1]["values"] = [0,0,0]),
            d -> (bases(d)[3]["definition"]["modes"][1]["values"] = [1,2]),
            d -> (bases(d)[3]["definition"]["modes"][1]["values"] = [1,Inf,2]),
            d -> (bases(d)[3]["definition"]["modes"][1]["values"] = [1,1e100,2]),
            d -> (d["deformable_mirrors"]["dm"]["shape_control"]["modes"] = []),
            d -> (d["deformable_mirrors"]["dm"]["shape_control"]["bases"] = fill(sampled,17)),
        )
        invalid = deepcopy(document)
        mutation(invalid)
        @test_throws ArgumentError Instrument.validate(invalid)
    end
    oversized = deepcopy(document)
    expanded = [deepcopy(bases(oversized)[3]) for _ in 1:16]
    for (index,basis) in enumerate(expanded)
        basis["id"] = "sampled-$index"
    end
    oversized["deformable_mirrors"]["dm"]["shape_control"]["bases"] = expanded
    # Preserve provenance, count and structural bounds while exceeding bytes.
    oversized["deformable_mirrors"] = Dict("dm$i"=>deepcopy(oversized["deformable_mirrors"]["dm"]) for i in 1:4)
    @test_throws ArgumentError Instrument.validate(oversized)
end

@testset "AOS instrument selection remains a cold declaration" begin
    mktempdir() do package
        path = joinpath(package, "simulation.conf")
        instrument = operational_instrument()
        write(joinpath(package, "instrument.json"), JSON.json(instrument))
        document = Dict{String,Any}("version" => 2, "plant" => Dict(
                "package" => "InstrumentPlantForTest", "settings" => Dict()),
            "command_input" => "pdm_command", "frame_output" => "detector_frame",
            "command_count" => 3, "frame_shape" => [2, 3], "rate" => 500,
            "exposure_ns" => 1_896_000, "wall_rate" => 10, "backend" => "cpu", "device" => 0,
            "frame_encoding" => "uint16", "frame_schema" => "org.calculon.ao.raw-detector-pixels/1",
            "command_schema" => "org.calculon.ao.demanded-pdm-command/1", "command_scale" => 1e-6,
            "calibration_identity" => instrument["calibration_identity"], "instrument" => "instrument.json")
        write(path, JSON.json(document))
        selected = PipeWireAORTC.AOSOwner.configuration(path)
        @test selected.instrument == joinpath(package, "instrument.json")
        @test selected.plant.package === :InstrumentPlantForTest
        @test Instrument.verify_plant(selected, InstrumentPlantForTest) === nothing
        argv = ["--config", path, "--remote", "/tmp/instrument-test", "--control-node", "simulator-wfs",
            "--bootstrap-node", "rtc.bootstrap.aos", "--bootstrap-instance", "7"]
        with_owner = (f, admitted) -> f(merge(admitted, (; owner_check=() -> nothing)))
        ran = Ref(false)
        run = admitted -> begin
            @test admitted.plant_module === InstrumentPlantForTest
            ran[] = true
        end
        @test PipeWireAORTC.AOSOwner._main(argv; with_owner, load_science=() -> nothing,
            load_plant=package -> InstrumentPlantForTest, run) == 0
        @test ran[]
        ran[] = false
        incompatible = deepcopy(instrument)
        incompatible["scientific_identity"] = "sha256:" * repeat("b", 64)
        write(joinpath(package, "instrument.json"), JSON.json(incompatible))
        @test_throws ArgumentError PipeWireAORTC.AOSOwner._main(argv; with_owner,
            load_science=() -> nothing, load_plant=package -> InstrumentPlantForTest, run)
        @test !ran[]
        write(joinpath(package, "instrument.json"), JSON.json(instrument))
        delete!(document, "instrument")
        write(path, JSON.json(document))
        @test PipeWireAORTC.AOSOwner.configuration(path).instrument === nothing
        document["instrument"] = "instrument.json"
        delete!(document, "calibration_identity")
        write(path, JSON.json(document))
        @test_throws ArgumentError PipeWireAORTC.AOSOwner.configuration(path)
        document["calibration_identity"] = instrument["calibration_identity"]
        document["instrument"] = joinpath(package, "instrument.json")
        write(path, JSON.json(document))
        @test_throws PipeWireAORTC.DeploymentConfiguration.DeploymentError PipeWireAORTC.AOSOwner.configuration(path)
    end
end

@testset "instrument properties belong to the public session endpoint" begin
    mktempdir() do package
        json = JSON.json(operational_instrument()) * "\n"
        write(joinpath(package, "instrument.json"), json)
        spec = Dict("name" => "instrument-test", "source-owner" => "simulator",
            "instrument" => "instrument.json", "artifacts" => Dict("instrument.json" => Instrument.digest(json)),
            "owners" => [Dict("role" => "simulator", "control-protocol" => "pipewireao.source-control/1",
                "control-node" => "simulator-wfs")])
        session = Dict("sources" => [Dict("node.name" => "simulator-wfs")],
            "sinks" => [Dict("node.name" => "core-sink")], "graphs" => [])
        bindings = Dict("PACKAGE" => package, "RUNTIME" => "/tmp/instrument-test",
            "REMOTE" => "instrument-test", "SESSION_UUID" => "00000000-0000-0000-0000-000000000001",
            "SESSION_SCRIPT" => "/sealed/rtc/scripts/ao/session.lua", "SESSION_CONTROL_INSTANCE" => "21",
            "SESSION_CONTROLLER_INSTANCE" => "22", "ADMISSION_CONTROLLER_INSTANCE" => "23")
        records = Dict(role => Dict{String,Any}("role" => role, "pid" => pid, "state" => "running",
            "start-ticks" => 1, "invocation" => role * "-invocation", "cgroup" => "/owners/" * role)
            for (role, pid) in (("simulator", 42), ("core", 43)))
        records["simulator"]["control-instance"] = "24"
        configuration = PipeWireAORTC.SessionConfiguration.session_configuration(spec, session, bindings, records;
            node_owners=Dict("simulator-wfs" => "simulator", "core-sink" => "core"),
            configuration_store_root=nothing)
        components = configuration["wireplumber.components"]
        endpoint = only(filter(c -> c["provides"] == "ao.session-control", components))
        @test endpoint["arguments"]["profile"] == "pipewireao.rtc.session/1"
        @test endpoint["arguments"]["node.name"] == "pipewireao.rtc.session.instrument-test"
        @test endpoint["arguments"]["properties"] == Dict(
            "pipewireao.rtc.session.session-uuid" => bindings["SESSION_UUID"],
            Instrument.PROPERTY => json, Instrument.HASH_PROPERTY => Instrument.digest(json))
        for component in components
            component === endpoint && continue
            properties = get(get(component, "arguments", Dict()), "properties", Dict())
            @test !haskey(properties, Instrument.PROPERTY)
            @test !haskey(properties, Instrument.HASH_PROPERTY)
        end
    end
end

@testset "simulated mirror uses the device NodeInfo description" begin
    mktempdir() do root
        instrument_path=joinpath(root,"instrument.json")
        mirror_path=joinpath(root,"mirror.json")
        operational=operational_instrument()
        write(instrument_path,JSON.json(operational))
        description=Dict("schema_version"=>1,"id"=>"test-mirror","manufacturer"=>"Test",
            "model"=>"Three actuators","layout"=>operational["deformable_mirrors"]["dm"]["layout"])
        json="\n"*JSON.json(description)*"\n"
        write(mirror_path,json)
        options=(;instrument=instrument_path,mirror_description=mirror_path,command_count=3)
        @test Instrument.mirror_properties(options)==Dict("device.mirror.description"=>json)
        @test isempty(Instrument.mirror_properties((;mirror_description=nothing)))
        mechanical=merge(description,Dict("actuator_pitch_m"=>0.0015,
            "actuator_pitch_provenance"=>"nominal synthetic model specification"))
        mechanical_json="\n"*JSON.json(mechanical)*"\n"
        write(mirror_path,mechanical_json)
        @test Instrument.mirror_properties(options)==Dict("device.mirror.description"=>mechanical_json)
        @test Instrument.mirror_description_json(mirror_path) == mechanical_json
        for extension in (".yaml", ".yml")
            yaml_path = joinpath(root, "mirror" * extension)
            PipeWireAORTC.Common.write_yaml(yaml_path, mechanical)
            yaml_options = merge(options, (;mirror_description=yaml_path))
            published = Instrument.mirror_properties(yaml_options)[Instrument.MIRROR_PROPERTY]
            @test Instrument.read_object(published) == mechanical
            @test startswith(published, "{")
            @test Instrument.mirror_description_json(yaml_path) == published
            @test_throws ArgumentError Instrument.mirror_properties(
                merge(yaml_options, (;command_count=2)))
            write(yaml_path, read(yaml_path, String) * "model: duplicate\n")
            @test_throws ArgumentError Instrument.mirror_properties(yaml_options)
        end
        # A JSON transport path never falls back to YAML authoring.
        PipeWireAORTC.Common.write_yaml(mirror_path, mechanical)
        @test_throws ArgumentError Instrument.mirror_properties(options)
        write(mirror_path, replace(mechanical_json, "{" => "{\"schema_version\":1,"; count=1))
        @test_throws ArgumentError Instrument.mirror_properties(options)
        for key in ("actuator_pitch_m", "actuator_pitch_provenance")
            invalid=deepcopy(mechanical); delete!(invalid,key)
            write(mirror_path,JSON.json(invalid))
            @test_throws ArgumentError Instrument.mirror_properties(options)
        end
        write(mirror_path,json)
        @test Instrument.mirror_properties(merge(options,(;instrument=nothing)))==Dict("device.mirror.description"=>json)
        @test_throws ArgumentError Instrument.mirror_properties(merge(options,(;instrument=nothing,command_count=2)))
        for change in (d->(d["layout"]["grid_shape"]=Any[true,1]),
                d->(d["layout"]["command_positions"][1]=Any[1.0,1]),
                d->(d["layout"]["command_positions"][1]=[0,1]),
                d->(d["layout"]["command_positions"][1]=[4,1]),
                d->(d["layout"]["command_positions"][1]=[2,1]))
            invalid=deepcopy(description); change(invalid)
            write(mirror_path,JSON.json(invalid))
            @test_throws ArgumentError Instrument.mirror_properties(merge(options,(;instrument=nothing)))
        end
        write(mirror_path,json)
        for suffix in ("junk"," {}","\n{}")
            write(mirror_path,json*suffix)
            @test_throws ArgumentError Instrument.mirror_properties(options)
        end
        write(mirror_path,json)
        for mutation in (d->(d["pupil_registration"]=Dict("actuator_pitch"=>0.125)),
                d->(d["schema_version"]=true),d->(d["manufacturer"]=""),
                d->(d["layout"]["command_positions"][1]=[2,1]))
            invalid=deepcopy(description)
            mutation(invalid)
            write(mirror_path,JSON.json(invalid))
            @test_throws ArgumentError Instrument.mirror_properties(options)
        end
        write(mirror_path,zeros(UInt8,64*1024+1))
        @test_throws ArgumentError Instrument.mirror_properties(options)
        write(mirror_path,UInt8[0xff])
        @test_throws ArgumentError Instrument.mirror_properties(options)
    end
end

@testset "mirror input is relocated with its application" begin
    mktempdir() do application
        filename="mirror.json"
        write(joinpath(application,filename),"{}")
        declared=Dict("package"=>"TestPlant","settings"=>Dict("mirror_description"=>filename))
        plant=PipeWireAORTC.AOSOwner.plant_declaration(declared;directory=application)
        @test plant.settings.mirror_description==joinpath(application,filename)
        @test declared["settings"]["mirror_description"]==filename
        @test PipeWireAORTC.AOSOwner.plant_declaration(declared).settings.mirror_description==filename
        for path in ("../outside.json",joinpath(application,filename),"missing.json")
            invalid=deepcopy(declared)
            invalid["settings"]["mirror_description"]=path
            @test_throws Exception PipeWireAORTC.AOSOwner.plant_declaration(invalid;directory=application)
        end
    end
end

@testset "measured influence-function input is relocated with its application" begin
    mktempdir() do application
        filename = "influence-functions.fits"
        write(joinpath(application, filename), "fits")
        declared = Dict("package"=>"TestPlant", "settings"=>Dict(
            "influence_functions"=>Dict("path"=>filename, "wavelength_nm"=>650.0)))
        plant = PipeWireAORTC.AOSOwner.plant_declaration(declared; directory=application)
        @test plant.settings.influence_functions.path == joinpath(application, filename)
        @test plant.settings.influence_functions.wavelength_nm == 650.0
        @test declared["settings"]["influence_functions"]["path"] == filename
        for path in ("../outside.fits", joinpath(application, filename), "missing.fits")
            invalid = deepcopy(declared)
            invalid["settings"]["influence_functions"]["path"] = path
            @test_throws Exception PipeWireAORTC.AOSOwner.plant_declaration(invalid; directory=application)
        end
    end
end
