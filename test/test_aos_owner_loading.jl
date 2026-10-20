# Optional regression: execute in a fresh process whose application environment
# directly depends on RTC, AOS, HIL and CUDA. Only RTC is loaded before _main.
# ARGS optionally selects cpu (default) or cuda; run each in its own process.
using Test
using PipeWireAORTC

const LoadingOwner = PipeWireAORTC.AOSOwner
length(ARGS) <= 2 || error("expected [cpu|cuda] [graph|instrument]")
const LoadingBackend = isempty(ARGS) ? "cpu" : first(ARGS)
const LoadingRoute = length(ARGS) < 2 ? "graph" : ARGS[2]
LoadingRoute in ("graph", "instrument") || error("expected graph or instrument")
LoadingBackend in ("cpu", "cuda") || error("expected cpu or cuda")
loaded(name) = any(id -> id.name == name, keys(Base.loaded_modules))

println("AOS_DEFAULT_LOADING julia=$(VERSION) rtc=$(pkgversion(PipeWireAORTC)) source=$(pathof(PipeWireAORTC)) backend=$LoadingBackend route=$LoadingRoute")

@testset "AOS actual default loaders after bootstrap ($LoadingBackend)" begin
    @test !loaded("AdaptiveOpticsSim")
    @test !loaded("AdaptiveOpticsSimPipeWireHIL")
    @test !loaded("CUDA")
    @test !loaded("REVOLTClassicSim")
    mktempdir() do directory
        write(joinpath(directory, "simulation.toml"), "schema_version = 1\nname = \"loading_regression\"\n")
        config = joinpath(directory, "simulation.conf")
        write(config, """
            {"version":1,"graph":"simulation.toml","command_input":"command",
             "frame_output":"frame","command_count":3,"frame_shape":[2,3],
             "rate":500,"exposure_ns":1896000,"wall_rate":10,
             "backend":"$LoadingBackend","device":0,"artifacts":[]}
            """)
        if LoadingRoute == "instrument"
            write(config, """
                {"version":2,"plant":{"package":"REVOLTClassicSim","settings":{"profile":"grid_gaussian"}},
                 "command_input":"pdm_command","frame_output":"shwfs_frame",
                 "command_count":277,"frame_shape":[352,352],
                 "rate":500,"exposure_ns":1896000,"wall_rate":10,
                 "backend":"$LoadingBackend","device":0,"frame_encoding":"uint16",
                 "frame_schema":"org.calculon.ao.raw-detector-pixels/1",
                 "command_schema":"org.calculon.ao.demanded-pdm-command/1","command_scale":0.000001}
                """)
        end
        args = ["--config", config, "--remote", "/tmp/aos-loading-private",
            "--control-node", "simulator-wfs", "--bootstrap-node", "rtc.bootstrap.aos",
            "--bootstrap-instance", "7"]
        events = Symbol[]
        checks = Ref(0)
        with_owner = function (f, options)
            # This stands in for the existing bootstrap runtime, and establishes
            # that optional imports have not happened before publication.
            @test !loaded("AdaptiveOpticsSim")
            @test !loaded("AdaptiveOpticsSimPipeWireHIL")
            @test !loaded("CUDA")
            @test !loaded("REVOLTClassicSim")
            push!(events, :preparing)
            check = () -> begin
                checks[] += 1
                if checks[] == 1
                    @test !loaded("AdaptiveOpticsSim")
                    @test !loaded("AdaptiveOpticsSimPipeWireHIL")
                else
                    @test loaded("AdaptiveOpticsSim")
                    @test loaded("AdaptiveOpticsSimPipeWireHIL")
                end
                if checks[] < 3 || LoadingBackend == "cpu"
                    @test !loaded("CUDA")
                end
                @test loaded("REVOLTClassicSim") == (LoadingRoute == "instrument" && checks[] >= 4)
                push!(events, :check)
                nothing
            end
            try
                f(merge(options, (; bootstrap_runtime=:published, owner_check=check)))
            finally
                push!(events, :cleanup)
            end
        end
        # Deliberately use both real default loaders. Inject only transport and
        # the final scientific loop so the regression needs no daemon/device.
        @test LoadingOwner._main(args; with_owner, run=options -> begin
            @test options.bootstrap_runtime === :published
            @test loaded("AdaptiveOpticsSim")
            @test loaded("AdaptiveOpticsSimPipeWireHIL")
            @test loaded("CUDA") == (LoadingBackend == "cuda")
            @test loaded("REVOLTClassicSim") == (LoadingRoute == "instrument")
            if LoadingRoute == "instrument"
                @test nameof(options.plant_module) === :REVOLTClassicSim
            end
            @test Base.get_extension(PipeWireAORTC, :PipeWireAORTCAOSExt) !== nothing
            push!(events, :run)
        end) == 0
        expected = LoadingRoute == "instrument" ?
            [:preparing, :check, :check, :check, :check, :run, :cleanup] :
            [:preparing, :check, :check, :check, :run, :cleanup]
        @test events == expected
    end
end
