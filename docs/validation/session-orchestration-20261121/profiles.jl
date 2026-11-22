using Test
using PipeWireAO
using PipeWireAORTC

const RTC = PipeWireAORTC
const D = RTC.DeploymentConfiguration
const E = RTC.InstrumentExport
const PREFIX = String(PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir)
const INSTRUMENTS = realpath(only(ARGS))

function selected_session(instrument, profile_path)
    source = joinpath(INSTRUMENTS, instrument)
    profile = E.load_profile(joinpath(source, profile_path))
    authoring = E.source_application(source, profile)
    mode = E.selected_mode(source, profile)
    spec = E.merge_configuration(authoring, mode["application"])
    session = D.decode(D.relative_asset(source, spec["session"]), PREFIX)
    return E.merge_configuration(session, get(mode, "session", Dict()))
end

function check_session(instrument, profile, count, groups, required_links)
    session = selected_session(instrument, profile)
    links = D.session_links(session)
    @test length(links) == count
    @test isnothing(D.validate_execution_groups(session, links))
    @test Dict(group["name"] => group["nodes"] for group in session["execution-groups"]) == groups
    actual = Set((string(link.output), string(link.input), link.passive) for link in links)
    @test length(actual) == length(links)
    @test required_links ⊆ actual
    corrupted = deepcopy(session)
    first(corrupted["links"])["passive"] = !first(links).passive
    @test_throws D.DeploymentError D.validate_execution_groups(corrupted, D.session_links(corrupted))
end

println("RTC ", pkgversion(RTC), " loaded from ", pathof(RTC))
println("Instrument declarations loaded from ", INSTRUMENTS)

@testset "CAL2 controller topology" begin
    check_session("cal2", "profiles/simulator/cpu.yaml", 10,
        Dict("cal2-llowfs-controller" => ["cal2-llowfs-controller"],
            "cal2-scc-controller" => ["cal2-scc-controller"]),
        Set([
            ("cal2-llowfs:output_1", "cal2-llowfs-controller:image", true),
            ("cal2-scc:output_1", "cal2-scc-controller:image", true),
            ("cal2-llowfs-controller:physical-offset", "cal2-llowfs-physical-offset-queue-input:playback_1", false),
            ("cal2-scc-controller:physical-offset", "cal2-scc-physical-offset-queue-input:playback_1", false),
        ]))
    optical = selected_session("cal2", "profiles/optical-calibration/cpu.yaml")
    @test isempty(D.session_links(optical))
    @test isnothing(D.validate_execution_groups(optical))
end

@testset "SPIDERS fitted dual topology" begin
    check_session("spiders", "profiles/fitted-dual-controller/cpu.yaml", 27,
        Dict("spiders-controller" => ["spiders-controller"], "scc-differential" => ["scc-differential"]),
        Set([
            ("spiders-scc:output_1", "spiders-controller:image", true),
            ("spiders-llowfs:output_1", "spiders-controller:llowfs-image", true),
            ("spiders-shape-offset:output_1", "spiders-controller:shape-offset", true),
            ("spiders-controller:dm-command", "spiders-dm-command:input_1", false),
            ("spiders-scc:output_1", "scc-differential:image", true),
            ("scc-differential:difference", "spiders-scc-differential-queue-input:playback_1", false),
            ("scc-differential:pair-status", "spiders-scc-differential-status-queue-input:playback_1", false),
        ]))
end

@testset "GPI2 integrator topology" begin
    check_session("gpi2", "profiles/simulator/profile.yaml", 32,
        Dict("controller" => ["gpi2-jfg-frame-graph"]),
        Set([
            ("simulator-wfs:output_1", "gpi2-jfg-frame-graph:raw", true),
            ("gpi2-jfg-frame-graph:woofer", "simulator-woofer:input_1", false),
            ("gpi2-jfg-frame-graph:tweeter", "simulator-tweeter:input_1", false),
            ("gpi2-jfg-frame-graph:tiptilt", "simulator-tiptilt:input_1", false),
        ]))
end

@testset "CAL2 upstream composition links" begin
    for (composition, owner) in (("cal2", "julia"), ("cal2-testplant", "simulator"))
        path = joinpath(INSTRUMENTS, "gpi2", "rtc", composition, "composition.yaml")
        document = RTC.Common.read_yaml(path)
        @test document["receiver"]["owner"] == owner
        @test document["roles"]["simulator"] == "cal2-optics"
        @test Set((string(link.output), string(link.input), link.passive)
            for link in D.link_declarations(document["links"])) == Set([
            ("simulator-pupil-output:output_1", "cal2-pupil-input:input_1", false),
            ("cal2-llowfs-controller:physical-offset", "gpi2-cal2-llowfs-offset:input_1", false),
            ("cal2-scc-controller:physical-offset", "gpi2-cal2-scc-offset:input_1", false),
        ])
    end
end
