using Test, JSON3, SHA, PipeWireAORTC

const Instrument = PipeWireAORTC.InstrumentDefinition

module InstrumentPlantForTest
const DEFINITION = (;
    schema_version=1, id="test-instrument",
    deformable_mirrors=(; dm=(;
        layout=(; schema_version=1, name="Test mirror", grid_shape=(3, 1),
            axis_labels=("source column", "source row"),
            command_positions=((1, 1), (2, 1), (3, 1)),
            command_order="physical", provenance="test source grid"),
        zernike=(; positions=((-0.5, 0.0), (0.0, 0.0), (0.5, 0.0)),
            modes=((; n=0, m=0, name="Piston"),)),
        fourier=(; positions=((-0.5, 0.0), (0.0, 0.0), (0.5, 0.0)),
            frequencies=((1, 0),), axis_units="cycles / source axis"),
        provenance="analytic geometry only",
        pupil_coordinates=((-0.75, 0.0), (0.0, 0.0), (0.75, 0.0)),
    )),
    wavefront_sensors=(; wfs=(; layout=(; detector_shape=(2, 3),
        subaperture_shape=(2, 3), subaperture_origins=((0, 0),),
        provenance="zero-based [row,column]"))),
)
instrument_definition() = DEFINITION
end

function operational_instrument()
    source = InstrumentPlantForTest.instrument_definition()
    document = JSON3.read(JSON3.write(source), Dict{String,Any})
    document["calibration_identity"] = "sha256:" * repeat("a", 64)
    document["scientific_identity"] = Instrument.scientific_identity(source)
    dm = document["deformable_mirrors"]["dm"]
    dm["units"] = "µm OPD"
    dm["command_scale_m"] = 1e-6
    dm["limiter"] = Dict("kind" => "amplitude", "lower" => fill(-0.5, 3), "upper" => fill(0.5, 3))
    dm["shape_control"] = Dict("coefficient_limit" => 0.05, "modes" => [],
        "zernike" => pop!(dm, "zernike"), "fourier" => pop!(dm, "fourier"),
        "provenance" => pop!(dm, "provenance"))
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
        json = " \n" * JSON3.write(document) * "\n"
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
            d -> (d["schema_version"] = 2),
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
            write(path, JSON3.write(invalid))
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
            write(path, JSON3.write(invalid))
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
        write(path, JSON3.write(document))
        options = (; instrument=path, calibration_identity=document["calibration_identity"],
            command_count=3, frame_shape=(2, 3), command_scale=1f-6,
            frame_schema="org.calculon.ao.raw-detector-pixels/1")
        @test Instrument.verify_plant(options, InstrumentPlantForTest) === nothing
        @test Instrument.verify_plant((; instrument=nothing), Module(:NoDefinition)) === nothing
        @test_throws ArgumentError Instrument.verify_plant(options, Module(:NoDefinition))
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
            d -> (d["deformable_mirrors"]["dm"]["shape_control"]["zernike"]["positions"][1] = [-0.25, 0]),
            d -> (d["deformable_mirrors"]["dm"]["shape_control"]["fourier"]["frequencies"][1] = [2, 0]),
            d -> (d["deformable_mirrors"]["dm"]["pupil_coordinates"][1] = [-0.5, 0]),
            d -> (d["wavefront_sensors"]["wfs"]["layout"]["subaperture_origins"][1] = [1, 0]),
            d -> (d["wavefront_sensors"]["wfs"]["layout"]["expected_schema"] = "org.revolt.classic.shwfs-frame.f32/1"),
            d -> (d["deformable_mirrors"]["extra"] = deepcopy(d["deformable_mirrors"]["dm"])),
        )
            invalid = deepcopy(document)
            mutation(invalid)
            write(path, JSON3.write(invalid))
            @test_throws ArgumentError Instrument.verify_plant(options, InstrumentPlantForTest)
        end
    end
end

@testset "AOS instrument selection remains a cold declaration" begin
    mktempdir() do package
        path = joinpath(package, "simulation.conf")
        instrument = operational_instrument()
        write(joinpath(package, "instrument.json"), JSON3.write(instrument))
        document = Dict{String,Any}("version" => 2, "plant" => Dict(
                "package" => "InstrumentPlantForTest", "settings" => Dict()),
            "command_input" => "pdm_command", "frame_output" => "detector_frame",
            "command_count" => 3, "frame_shape" => [2, 3], "rate" => 500,
            "exposure_ns" => 1_896_000, "wall_rate" => 10, "backend" => "cpu", "device" => 0,
            "frame_encoding" => "uint16", "frame_schema" => "org.calculon.ao.raw-detector-pixels/1",
            "command_schema" => "org.calculon.ao.demanded-pdm-command/1", "command_scale" => 1e-6,
            "calibration_identity" => instrument["calibration_identity"], "instrument" => "instrument.json")
        write(path, JSON3.write(document))
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
        write(joinpath(package, "instrument.json"), JSON3.write(incompatible))
        @test_throws ArgumentError PipeWireAORTC.AOSOwner._main(argv; with_owner,
            load_science=() -> nothing, load_plant=package -> InstrumentPlantForTest, run)
        @test !ran[]
        write(joinpath(package, "instrument.json"), JSON3.write(instrument))
        delete!(document, "instrument")
        write(path, JSON3.write(document))
        @test PipeWireAORTC.AOSOwner.configuration(path).instrument === nothing
        document["instrument"] = "instrument.json"
        delete!(document, "calibration_identity")
        write(path, JSON3.write(document))
        @test_throws ArgumentError PipeWireAORTC.AOSOwner.configuration(path)
        document["calibration_identity"] = instrument["calibration_identity"]
        document["instrument"] = joinpath(package, "instrument.json")
        write(path, JSON3.write(document))
        @test_throws PipeWireAORTC.DeploymentConfiguration.DeploymentError PipeWireAORTC.AOSOwner.configuration(path)
    end
end

@testset "instrument properties belong to the public session endpoint" begin
    mktempdir() do package
        json = JSON3.write(operational_instrument()) * "\n"
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
