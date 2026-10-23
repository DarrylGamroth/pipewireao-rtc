using Test, PipeWireAORTC, JSON

const E = PipeWireAORTC.InstrumentExport
const C = PipeWireAORTC.Common
const D = PipeWireAORTC.DeploymentConfiguration

function export_profile()
    placement() = Dict("cpus" => [2, 3], "leader-cpu" => 3,
        "rt-priority" => 0, "locked-bytes" => 0, "threads" => [])
    Dict("placement" => Dict(role => placement() for role in ("core", "rtc", "session", "julia")),
        "bindings" => Dict{String,Any}("CORE_CPU" => 2, "OBSERVER_CPU" => 3,
            "JULIA_CPU" => 2, "RT_PRIORITY" => 0))
end

function application_spec()
    Dict("owners" => [Dict("role" => "julia", "environment" => Dict())],
        "session-runtime" => Dict("environment" => Dict()),
        "analysis" => [Dict("name" => "wfs", "config" => "analysis/analysis.conf", "cpus" => [2])])
end

@testset "instrument exporter profile bindings" begin
    profile = export_profile()
    bindings = E.profile_bindings(profile, "/julia/bin/julia")
    @test E.substitute("@JULIA@ --cpu @CORE_CPU@ @REMOTE@", bindings) ==
        "/julia/bin/julia --cpu 2 @REMOTE@"
    @test E.substitute("@BOOTSTRAP_INSTANCE_JULIA@", bindings) == "@BOOTSTRAP_INSTANCE_JULIA@"
    @test_throws ArgumentError E.substitute("@UNDECLARED@", bindings)
    @test E.substitute(Dict("argv" => ["@JULIA@", "@PACKAGE@"]), bindings) ==
        Dict("argv" => ["/julia/bin/julia", "@PACKAGE@"])
    for key in ("CORE_CPU", "OBSERVER_CPU", "JULIA_CPU", "RT_PRIORITY")
        missing = deepcopy(profile)
        delete!(missing["bindings"], key)
        @test_throws ArgumentError E.profile_bindings(missing, "julia")
    end
    for (key, value) in (("CORE_CPU", 1), ("RT_PRIORITY", 100), ("CORE_CPU", true),
            ("PREFIX", "/wrong"), ("JULIA", "/wrong"), ("BOOTSTRAP_INSTANCE_JULIA", "wrong"),
            ("OTHER", 1.5), ("other", "bad"))
        invalid = deepcopy(profile)
        invalid["bindings"][key] = value
        @test_throws ArgumentError E.profile_bindings(invalid, "julia")
    end
    @test E.profile!(application_spec(), profile, bindings)["placement"] == profile["placement"]
    for invalid in (merge(profile, Dict("unknown" => true)),
            merge(profile, Dict("placement" => Dict("missing" => Dict()))),
            merge(profile, Dict("environment" => Dict("missing" => Dict("A" => "B")))),
            merge(profile, Dict("analysis" => Dict("missing" => [2]))))
        @test_throws ArgumentError E.profile!(application_spec(), invalid, bindings)
    end
    valid = deepcopy(profile)
    valid["environment"] = Dict("julia" => Dict("TEST_ENV" => "ok"), "session" => Dict("TEST_SESSION" => "yes"))
    valid["analysis"] = Dict("wfs" => [3])
    authoring = application_spec()
    delete!(authoring["analysis"][1], "cpus")
    prepared = E.profile!(E.substitute(authoring, bindings), valid, bindings)
    @test prepared["owners"][1]["environment"]["TEST_ENV"] == "ok"
    @test prepared["session-runtime"]["environment"]["TEST_SESSION"] == "yes"
    @test prepared["analysis"][1]["cpus"] == [3]
end

@testset "instrument application seal and contained paths" begin
    mktempdir() do directory
        source = joinpath(directory, "source")
        mkpath(joinpath(source, "nested"))
        write(joinpath(source, "nested", "data.json"), "{\"data\":1}\n")
        C.write_json(joinpath(source, "deployment.conf"), Dict("version" => 1))
        E.seal!(source)
        sealed = C.read_json(joinpath(source, "deployment.conf"))
        @test Set(keys(sealed["artifacts"])) == Set(["nested/data.json"])
        @test sealed["artifacts"]["nested/data.json"] == C.sha256_file(joinpath(source, "nested", "data.json"))
        write(joinpath(source, "nested", "data.json"), "{\"data\":2}\n")
        @test sealed["artifacts"]["nested/data.json"] != C.sha256_file(joinpath(source, "nested", "data.json"))
        @test_throws ArgumentError E.prepare(source, joinpath(source, "output"); profile=export_profile())
        @test_throws ArgumentError E.prepare(source, directory; profile=export_profile())
        @test !ispath(joinpath(source, "output"))
        linked = joinpath(directory, "linked")
        symlink(source, linked)
        @test_throws ArgumentError E.prepare(linked, joinpath(directory, "output"); profile=export_profile())
        @test_throws ArgumentError E.prepare(source, joinpath(linked, "output"); profile=export_profile())
        symlink(joinpath(source, "nested"), joinpath(source, "linked-data"))
        @test_throws ArgumentError E.seal!(source)
        @test_throws ArgumentError E.prepare(source, joinpath(directory, "output"); profile=export_profile())
    end
end

@testset "simulation profile changes only deployment fields" begin
    mktempdir() do directory
        path = joinpath(directory, "simulation.conf")
        simulation = Dict("backend" => "cuda", "device" => 0, "wall_rate" => 500,
            "rate" => 500, "plant" => Dict("settings" => Dict("seed" => 17)))
        C.write_json(path, simulation)
        E.simulation_override!(directory, Dict("simulation" => Dict("backend" => "cpu", "wall_rate" => 10)))
        prepared = C.read_json(path)
        @test prepared["backend"] == "cpu"
        @test prepared["wall_rate"] == 10
        @test prepared["plant"] == simulation["plant"]
        for overrides in (Dict("rate" => 10), Dict("plant" => Dict()), Dict("backend" => "unknown"),
                Dict("device" => -1), Dict("device" => true), Dict("wall_rate" => 501))
            before = read(path)
            @test_throws ArgumentError E.simulation_override!(directory, Dict("simulation" => overrides))
            @test read(path) == before
        end
    end
end

@testset "shared instrument templates" begin
    prefix = get(ENV, "PIPEWIREAO_PREFIX", "/opt/pipewireao")
    bindings = E.profile_bindings(export_profile(), "julia")
    mktempdir() do directory
        mkpath(joinpath(directory, "rtc"))
        C.write_json(joinpath(directory, "rtc", "core.conf"), Dict("context.modules" =>
            [Dict("name" => "libpipewire-module-queue", "args" => Dict("node.name" => "test-data-queue"))]))
        E.render_templates!(directory, bindings, prefix)
        core = D.decode(joinpath(directory, "shared-runtime", "core.conf.in"), prefix)
        @test count(module_ -> module_["name"] == "libpipewire-module-queue", core["context.modules"]) == 1
        @test length(core["context.objects"]) == 3
        @test core["context.properties"]["core.name"] == "@REMOTE@"
        @test core["context.properties"]["context.data-loops"][1]["thread.affinity"] == [2]
        @test core["context.properties"]["context.data-loops"][2]["thread.affinity"] == [3]
        @test_throws ArgumentError E.render_templates!(directory, bindings, prefix)
    end
end

@testset "offline exports require the complete native placement contract" begin
    profile = export_profile()
    for mutate in (
        value -> delete!(value["placement"]["core"], "rt-priority"),
        value -> (value["placement"]["core"]["locked-bytes"] = -1),
        value -> (value["placement"]["core"]["threads"] = [Dict(
            "cpus" => [4], "policy" => "other", "priority" => 0, "count" => 1)]),
    )
        invalid = deepcopy(profile)
        mutate(invalid)
        bindings = E.profile_bindings(invalid, "/julia/bin/julia")
        @test_throws D.DeploymentError E.profile!(application_spec(), invalid, bindings)
    end
end
