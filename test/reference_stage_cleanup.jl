# Optional science selector: cold projection fault injection only. No core,
# optical samples, source instrument, devices or accelerator are used.
module ReferenceStageCleanupTests

using Test, PipeWireAO, PipeWireAORTC, FilterGraphIsland, FilterGraphPipeWire, JuliaFilterGraph
using AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL, AdaptiveOpticsCalibration

const Ext = Base.get_extension(PipeWireAORTC, :PipeWireAORTCCalibrationExt)
const Calibration = PipeWireAORTC.InstrumentCalibration

struct CleanupApplication
    preparations::Base.RefValue{Int}
    closed::Vector{Symbol}
    failed_close::Symbol
end

struct CleanupGraph
    application::CleanupApplication
    name::Symbol
end

function Calibration.calibration_graph(application::CleanupApplication;
        inputs, outputs, parameter_sources=Dict())
    application.preparations[] += 1
    application.preparations[] == 4 && error("final command projection preparation failed")
    name = (:frontend, :woofer, :tweeter)[application.preparations[]]
    return (; graph=CleanupGraph(application, name))
end

function FilterGraphIsland.close_execution(graph::CleanupGraph)
    push!(graph.application.closed, graph.name)
    graph.name === graph.application.failed_close && error("$(graph.name) projection close failed")
    return nothing
end

@testset "named stage closes every prepared graph and preserves primary errors" begin
    references = (woofer=zeros(Float32, 2), tweeter=zeros(Float32, 3), tiptilt=zeros(Float32, 1))
    commands = map(_ -> (; requested="node:requested", demanded="node:demanded",
        feedback="node:constraint-feedback"), references)
    for failed_close in (:woofer, :tweeter)
        application = CleanupApplication(Ref(0), Symbol[], failed_close)
        observed = try
            Ext.reference_stage(application, "unused-private-core", Dict(), references,
                UInt64(1), UInt64(1), "training", "internal-source",
                (; samples=1, discard=0), 10.0, () -> false, nothing, nothing,
                () -> nothing, (sample, exposure) -> nothing;
                commands, probe_command=:woofer)
            nothing
        catch error
            error
        end
        @test application.preparations[] == 4
        @test application.closed == [:tweeter, :woofer, :frontend]
        @test observed isa CompositeException
        @test length(observed.exceptions) == 2
        @test sprint(showerror, observed.exceptions[1]) == "final command projection preparation failed"
        @test sprint(showerror, observed.exceptions[2]) == "$(failed_close) projection close failed"
    end
    @test !any(id -> id.name in ("CUDA", "AMDGPU"), keys(Base.loaded_modules))
end

end
