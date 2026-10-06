using Test, TOML, PipeWireAODeployment
const Export = PipeWireAODeployment.HeartCalibrationExport
const Common = PipeWireAODeployment.Common

@testset "native HEART calibration exports the action server adapter" begin
    @test "native_calibration_actions.jl" in Export.HELPERS
    @test all(name -> isfile(joinpath(PipeWireAODeployment.resource_root(), "hil", name)),
        Export.HELPERS)
end

@testset "HEART calibration session has exact relay links" begin
    session = Export.calibration_session(500)
    @test session["execution"] == "external-rtc"
    @test length(session["sources"]) == 3 && length(session["sinks"]) == 3
    @test session["graphs"] == []
    @test [(link["output"], link["input"]) for link in session["links"]] == [
        ("simulator-wfs:output_1", "heart-wfs-sink:frame"),
        ("heart-dm-source:command", "heart-calibration-command:input_1"),
        ("heart-calibration-probe:output_1", "simulator-command:input_1")]
    for nodes in (session["sources"], session["sinks"]), node in nodes
        port = only(node["ports"])
        @test port["rate"] == "500/1"
        @test node["ownership"] == "external"
    end
end

@testset "full rate native telemetry and immutable owner arguments" begin
    sections = Dict("CB"=>Dict{String,Any}("CAPACITY"=>[Dict("tagName"=>"cbHoGrad#", "capacity"=>16)],
        "TELEMETRY_SOCKET_STREAMS"=>[]))
    Export.full_rate_telemetry!(sections)
    records = sections["CB"]["TELEMETRY_FILE_STREAMS"]
    @test Tuple(record["tagName"] for record in records) == Export.TELEMETRY_TAGS
    @test all(record -> record["decimate"] == 0 && record["pollPeriod"] == 0.001, records)
    @test !haskey(sections["CB"], "TELEMETRY_SOCKET_STREAMS")
    @test sections["CB"]["CAPACITY"] == [Dict("tagName"=>"cbHoGrad#", "capacity"=>16)]
    argv = ["julia", "@PACKAGE@/hil/simulator.jl", "--transport", "heart"]
    result = Export.owner_arguments(argv; stage="nativepilot", illumination="lamp", capture_max_bytes=100000, telemetry_max_bytes=64000, evidence_directory="/fresh/persistent-owner-evidence")
    @test argv[2] == "@PACKAGE@/hil/simulator.jl"
    @test result[2] == "@PACKAGE@/hil/heart_calibration_owner.jl"
    @test result[findfirst(==("--heart-native-runtime"), result) + 1] == "@RUNTIME@/heart/native"
    @test result[findfirst(==("--heart-probe-directory"), result) + 1] == "/fresh/persistent-owner-evidence"
    @test result[findfirst(==("--capture-directory"), result) + 1] == "@RUNTIME@/captured"
    @test_throws ArgumentError Export.owner_arguments(String[]; stage="x", illumination="lamp", capture_max_bytes=1, telemetry_max_bytes=1, evidence_directory="/fresh/evidence")
end

@testset "pilot keeps normal detector algorithms and freezes only seed" begin
    mktempdir() do directory
        path = joinpath(directory, "plant.toml")
        graph = Dict("nodes"=>[
            Dict("name"=>"pwfs", "type"=>"pyramid_wavefront_sensor_f32", "config"=>Dict("source_magnitude"=>0.752574989159953)),
            Dict("name"=>"detector", "type"=>"emccd_detector_acquisition_f32", "config"=>Dict("photon_noise"=>true,
                "readout_noise"=>true, "rng_seed"=>522, "bits"=>14, "gain"=>1.0))])
        open(io -> TOML.print(io, graph), path, "w")
        record = Export.freeze_detector!(path)
        @test record["original_detector_seed"] == 522 && record["detector_seed"] == 700
        expected = deepcopy(graph); expected["nodes"][2]["config"]["rng_seed"] = 700
        @test TOML.parsefile(path) == expected
        @test record["graph_sha256"] == Common.sha256_file(path)
        expected["nodes"][2]["config"]["photon_noise"] = false
        open(io -> TOML.print(io, expected), path, "w")
        @test_throws ArgumentError Export.freeze_detector!(path)
    end
end

@testset "finite pilot retains final report and telemetry before shutdown" begin
    mktempdir() do directory
        instance = joinpath(directory, "instance"); mkdir(instance)
        mkpath(joinpath(instance, "heart/native")); mkpath(joinpath(instance, "heart-probes"))
        immutable = joinpath(directory, "immutable-config"); mkdir(immutable)
        symlink(immutable, joinpath(instance, "heart/native/config"))
        write(joinpath(instance, "heart/native/cbHoGrad0_RUN.tel"), "native fixture")
        write(joinpath(instance, "heart-probes/native-evidence.jsonl"), "{}\n")
        Common.write_json(joinpath(instance, "simulator-result.json"), Dict("completed"=>true, "sequence"=>7))
        output = joinpath(directory, "evidence"); mkdir(output)
        @test Export.retain_pilot(instance, output, UInt64(1024)) > 0
        @test Common.read_json(joinpath(output, "simulator-result.json"))["completed"]
        @test read(joinpath(output, "heart/native/cbHoGrad0_RUN.tel"), String) == "native fixture"
        @test !ispath(joinpath(output, "heart/native/config"))
        other = joinpath(directory, "small"); mkdir(other)
        @test_throws ArgumentError Export.retain_pilot(instance, other, UInt64(1))
        @test_throws ArgumentError Export.run_pilot("/unused", joinpath(directory, "pilot"); frames=1)
    end
end

@testset "native processing diagnostics are explicit and off by default" begin
    options = (; executable="/native/scaoTemplate", runtime="/runtime")
    owner = PipeWireAODeployment.HeartOwner
    @test owner.child_arguments(options) == ["/native/scaoTemplate", "-shm", "-config", "/runtime/config/heart.yaml"]
    enabled = owner.child_arguments(merge(options, (; native_wfs_proc_debug=true)))
    @test enabled[end-3:end] == ["-moduleDebug", "hrtWfsProcBlock_debugLevel", "-moduleDebugLevel", "4"]
    @test owner.child_arguments(merge(options, (; native_wfs_proc_debug=false))) == owner.child_arguments(options)
    wrapped = owner.child_arguments(merge(options, (; native_wfs_proc_debug=true, native_debug_stdio_wrapper="/usr/bin/stdbuf")))
    @test wrapped[1:3] == ["/usr/bin/stdbuf", "-oL", "-eL"]
    @test wrapped[4:end] == enabled
end

function native_plan(; batches=554, frames=16)
    return Dict("version"=>1, "run"=>1, "reference"=>zeros(277), "probes"=>[zeros(277) for _ in 1:batches],
        "measurements"=>3600, "frames_per_probe"=>frames, "settling"=>Dict("kind"=>"discard_exposures", "frames"=>1),
        "timeouts_ns"=>Dict(name=>30_000_000_000 for name in ("ownership", "adoption", "settling", "collection", "restoration")))
end

@testset "frozen native full plans derive exact physical counts and bounds" begin
    plan = native_plan()
    original = deepcopy(plan)
    limits = Export.plan_limits(plan)
    @test plan == original
    @test limits["native_dm_records"] == 555
    @test limits["completed_exposures"] == 9419
    @test limits["accepted_frames"] == 8864
    @test limits["capture_max_payload_bytes"] == 8864 * 22596
    @test limits["native_file_bytes"]["cbHoPixelsCalib0"] == 1024 + 9419 * 16448
    @test limits["telemetry_max_bytes_per_file"] >= maximum(values(limits["native_file_bytes"]))
    @test limits["result_max_output_bytes"] > 128 * 1024
    @test Export.plan_limits(native_plan(batches=512))["native_dm_records"] == 513
    @test Export.plan_limits(native_plan(batches=12))["completed_exposures"] == 205
    for change in (p->p["reference"]=zeros(253), p->p["probes"][1][1]=NaN,
        p->p["frames_per_probe"]=true, p->p["measurements"]=376,
        p->p["settling"]=Dict("kind"=>"model_time", "duration_ns"=>100),
        p->p["timeouts_ns"]["collection"]=30_000_000_001)
        bad = deepcopy(plan); change(bad)
        @test_throws ArgumentError Export.plan_limits(bad)
    end
end

@testset "native export verifies selected backend provenance, owner and CUDA UUID" begin
    mktempdir() do directory
        mkpath(joinpath(directory, "hil"))
        write(joinpath(directory, "hil/Project.toml"), "[deps]\nCUDA = \"052768ef-5323-5732-b1bb-66c8b64840ba\"\n")
        spec = Dict("source-owner"=>"simulator", "owners"=>[Dict("role"=>"simulator", "argv"=>["julia", "--backend", "cuda"])])
        prov = Dict("hil"=>Dict("backend"=>"cuda"))
        validate = PipeWireAODeployment.CalibrationCampaign.validate_simulator_backend
        @test validate(directory, spec, prov; allowed_backends=("cuda",)) == "cuda"
        @test_throws ArgumentError validate(directory, spec, prov)
        mismatch = deepcopy(spec); mismatch["owners"][1]["argv"][3] = "cpu"
        @test_throws ArgumentError validate(directory, mismatch, prov; allowed_backends=("cuda",))
        write(joinpath(directory, "hil/Project.toml"), "[deps]\nCUDA = \"00000000-0000-0000-0000-000000000000\"\n")
        @test_throws ArgumentError validate(directory, spec, prov; allowed_backends=("cuda",))
    end
end

@testset "native calibration export keeps its Copper profile guard" begin
    mktempdir() do directory
        Common.write_json(joinpath(directory, "provenance.json"), Dict("profile"=>"classic"))
        @test_throws ArgumentError Export.export_package((; base_package=directory))
        Common.write_json(joinpath(directory, "provenance.json"), Dict("profile"=>"unknown"))
        @test_throws ArgumentError Export.export_package((; base_package=directory))
    end
end

@testset "frozen native method binds seed, recipe and prepared source identity" begin
    mktempdir() do directory
        input = joinpath(directory, "method"); mkdir(input)
        plan = native_plan()
        recipe = Dict("seeds"=>Dict("interaction"=>531), "frames_per_probe"=>16,
            "settling"=>Dict("kind"=>"discard_exposures", "frames"=>1), "lamp_magnitude"=>0.752574989159953)
        for name in Export.METHOD_INPUT_FILES
            value = name == "recipe.json" ? recipe : name == "interaction-plan.json" ? plan : Dict("fixture"=>name)
            Common.write_json(joinpath(input, name), value)
        end
        files = Dict(name=>Common.sha256_file(joinpath(input, name)) for name in Export.METHOD_INPUT_FILES)
        Common.write_json(joinpath(input, "prepared-identity.json"), Dict("files"=>files,
            "package_files"=>Dict("hil/packages/AdaptiveOpticsCalibration/Project.toml"=>"a"^64, "hil/calibration_client.jl"=>"b"^64)))
        path = joinpath(input, "interaction-plan.json")
        bound = Export.frozen_method_inputs(input, path, 531)
        @test bound["interaction_seed"] == 531
        @test bound["files"] == files
        @test length(bound["aoc_package_files"]) == 2
        @test_throws ArgumentError Export.frozen_method_inputs(input, path, 700)
        @test_throws ArgumentError Export.frozen_method_inputs(input, nothing, 531)
        for (frames, settling, accepted) in ((64, Dict("kind"=>"discard_exposures", "frames"=>1), true),
            (16, Dict("kind"=>"discard_exposures", "frames"=>2), false),
            (2, Dict("kind"=>"discard_exposures", "frames"=>1), false))
            recipe["frames_per_probe"] = frames; recipe["settling"] = settling
            plan["frames_per_probe"] = 64
            Common.write_json(joinpath(input, "recipe.json"), recipe)
            Common.write_json(path, plan)
            files["recipe.json"] = Common.sha256_file(joinpath(input, "recipe.json"))
            files["interaction-plan.json"] = Common.sha256_file(path)
            Common.write_json(joinpath(input, "prepared-identity.json"), Dict("files"=>files,
                "package_files"=>Dict("hil/packages/AdaptiveOpticsCalibration/Project.toml"=>"a"^64, "hil/calibration_client.jl"=>"b"^64)))
            if accepted
                @test Export.frozen_method_inputs(input, path, 531)["interaction_seed"] == 531
            else
                @test_throws ArgumentError Export.frozen_method_inputs(input, path, 531)
            end
        end
        Common.write_json(joinpath(input, "method.json"), Dict("fixture"=>"mutated"))
        @test_throws ArgumentError Export.frozen_method_inputs(input, path, 531)
    end
end

@testset "native reduction binds the actual stopped runtime and owned instance" begin
    mktempdir() do directory
        identity = Dict("runtime"=>directory, "deployment_sha256"=>"d"^64, "launcher_pid"=>123,
            "instance"=>"run-owned", "ready_session_id"=>"session-owned", "processes"=>Dict("simulator"=>Dict("pid"=>124)), "source_owner"=>"simulator")
        state = Dict("pid"=>123, "instance"=>"run-owned", "ready"=>Dict("session_id"=>"session-owned"),
            "processes"=>Dict("simulator"=>Dict("pid"=>124)), "source-owner"=>"simulator", "source"=>Dict("sequence"=>7),
            "phase"=>"stopped", "admitted"=>false, "error"=>nothing)
        @test Export.validate_stopped_runtime(state,identity,directory,"d"^64,7) === nothing
        @test_throws ArgumentError Export.validate_stopped_runtime(state,nothing,directory,"d"^64,7)
        for change in (s->s["pid"]=456, s->s["instance"]="other", s->s["ready"]["session_id"]="other",
            s->s["processes"]["simulator"]["pid"]=456, s->s["source"]["sequence"]=6,
            s->s["admitted"]=true, s->s["phase"]="running")
            bad=deepcopy(state); change(bad)
            @test_throws ArgumentError Export.validate_stopped_runtime(bad,identity,directory,"d"^64,7)
        end
        mkdir(joinpath(directory,"run-owned"))
        @test_throws ArgumentError Export.validate_stopped_runtime(state,identity,directory,"d"^64,7)
    end
end

@testset "completion native ingress has bounded explicit fixture selection" begin
    owner = PipeWireAODeployment.HeartOwner
    inherited = Dict("HRT_DEFER_WFS_INGRESS"=>"1", "OTHER"=>"unchanged")
    @test owner.child_environment((; runtime="/native"),inherited)["HRT_DEFER_WFS_INGRESS"] == "0"
    @test owner.child_environment((; runtime="/native",native_ingress_mode="deferred"),Dict("HRT_DEFER_WFS_INGRESS"=>"0"))["HRT_DEFER_WFS_INGRESS"] == "1"
    @test inherited["HRT_DEFER_WFS_INGRESS"] == "1"
    @test owner.child_environment((; runtime="/native"),inherited)["OTHER"] == "unchanged"
    @test owner.ingress_setting("streaming") == "0"
    @test owner.ingress_setting("deferred") == "1"
    @test_throws ArgumentError owner.ingress_setting("recent")
    @test owner.ingress_environment("OTHER=x\0HRT_DEFER_WFS_INGRESS=0\0") == "0"
    @test owner.ingress_environment("HRT_DEFER_WFS_INGRESS=1\0") == "1"
    @test_throws ArgumentError owner.ingress_environment("OTHER=x\0")
    @test_throws ArgumentError owner.ingress_environment("HRT_DEFER_WFS_INGRESS=0\0HRT_DEFER_WFS_INGRESS=1\0")
    @test_throws ArgumentError owner.ingress_environment("HRT_DEFER_WFS_INGRESS=2\0")
    @test_throws ArgumentError owner.ingress_environment(repeat("x", 1024*1024+1))
    mktempdir() do directory
        binary = joinpath(directory,"native")
        write(binary, "HRT_DEFER_WFS_INGRESS\0WFS Proc did not snapshot first 32 rows\0HO Recon did not snapshot first 1800 inputs\0")
        properties = Dict{String,Any}("api.heart.std-wfs.width"=>64,"api.heart.std-wfs.height"=>64,
            "api.heart.std-wfs.pixels-per-datagram"=>2048,"api.heart.std-wfs.rows-per-datagram"=>true)
        contract(mode; profile="copper", revision=Export.DEFERRED_SOURCE_REVISION, props=properties) =
            Export.ingress_contract(mode,profile,props,binary;source_revision=revision)
        @test contract("streaming")["environment_value"] == "0"
        deferred = contract("deferred")
        @test deferred["environment_value"] == "1" && deferred["datagrams_per_frame"] == 2
        @test deferred["executable_sha256"] == Common.sha256_file(binary)
        @test_throws ArgumentError contract("deferred";revision=Export.DEFERRED_SOURCE_REVISION*"extra")
        @test_throws ArgumentError contract("deferred";profile="classic")
        for (key,value) in (("api.heart.std-wfs.width",32),("api.heart.std-wfs.height",352),
            ("api.heart.std-wfs.pixels-per-datagram",4096),("api.heart.std-wfs.rows-per-datagram",false))
            changed = copy(properties);changed[key]=value
            @test_throws ArgumentError contract("deferred";props=changed)
        end
        @test_throws ArgumentError contract("unknown")
        write(binary,"HRT_DEFER_WFS_INGRESS")
        @test_throws ArgumentError contract("deferred")
    end
end
