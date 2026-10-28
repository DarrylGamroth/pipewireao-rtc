# Optional cold CPU selector against a built Classic application. It prepares
# graphs and generated temporary FITS artifacts without stepping or device I/O.
using Test, SHA
using PipeWireAORTC, FilterGraphIsland, JuliaFilterGraph
using AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL, AdaptiveOpticsCalibration

const Calibration = PipeWireAORTC.InstrumentCalibration
const Artifacts = PipeWireAORTC.Artifacts
const GraphOwner = PipeWireAORTC.GraphOwner
const Deployment = PipeWireAORTC.DeploymentConfiguration
const application = ENV["PIPEWIREAORTC_CALIBRATION_APPLICATION"]
const frontend_inputs = (raw="pixel-calibration:raw",)
const frontend_outputs = (:slopes, :flux, :validity)

function application_hashes(directory)
    Dict(relpath(joinpath(root, file), directory) =>
        bytes2hex(sha256(read(joinpath(root, file))))
        for (root, _, files) in walkdir(directory) for file in files)
end

project(; parameter_sources=Dict()) = Calibration.calibration_graph(application;
    inputs=frontend_inputs, outputs=frontend_outputs, parameter_sources)

@testset "typed FITS parameter sources preserve regular graph authority" begin
    before = application_hashes(application)
    originals = Calibration.read_parameters(application)
    original_copies = deepcopy(originals)
    original_bindings = GraphOwner.bindings(joinpath(application,"rtc","parameters.conf"))
    base = candidate = changed = nothing
    try
        base = project()
        @test isempty(base.parameter_sources)
        @test Set(keys(base.parameter_sha256)) == Set(keys(base.parameters))
        @test all(base.parameter_sha256[entry.port] == Calibration.digest(entry.source.path)
            for entry in base.bindings)
        mktempdir() do directory
            values = Dict(:background => fill(7.0f0,size(originals[:background])),
                :active => copy(originals[:active]),
                Symbol("reference-slopes") => fill(0.25f0,size(originals[Symbol("reference-slopes")])))
            values[:active][1] = !values[:active][1]
            overrides = Dict{Symbol,Artifacts.FITSArtifact}()
            for (port, data) in values
                path = joinpath(directory,string(port)*".fits")
                # Float64 storage exercises the existing typed conversion to Float32.
                Calibration.write_fits(path, eltype(data) === Float32 ? Float64.(data) : data)
                overrides[port] = Artifacts.FITSArtifact(path;
                    axes=ndims(data) == 1 ? nothing : (2,1))
            end
            candidate = project(parameter_sources=overrides)
            @test candidate.parameter_sources !== overrides
            @test candidate.parameter_sources == overrides
            @test candidate.document == base.document
            @test candidate.source_graph_sha256 == base.source_graph_sha256
            @test Set(keys(candidate.parameters)) == Set(keys(base.parameters))
            for entry in candidate.bindings
                port = entry.port
                if haskey(overrides,port)
                    @test entry.source === overrides[port]
                    @test candidate.parameters[port] == values[port]
                    @test eltype(candidate.parameters[port]) === eltype(originals[port])
                else
                    original = only(filter(binding -> binding.port == port,original_bindings))
                    @test entry.source.path == original.source.path
                    @test entry.source.hdu == original.source.hdu
                    @test entry.source.axes == original.source.axes
                    @test candidate.parameters[port] == originals[port]
                end
                @test candidate.parameter_sha256[port] == Calibration.digest(entry.source.path)
            end
            empty!(overrides)
            @test length(candidate.parameter_sources) == 3
            @test all(base.parameters[port] == data for (port,data) in originals if haskey(base.parameters,port))
            @test all(JuliaFilterGraph.parameter_formats(candidate.graph)[port] == format
                for (port,format) in pairs(JuliaFilterGraph.parameter_formats(base.graph)))

            path = candidate.parameter_sources[:background].path
            old_hash = candidate.parameter_sha256[:background]
            Calibration.write_fits(path,fill(8.0f0,size(values[:background])))
            @test candidate.parameter_sha256[:background] == old_hash
            @test Calibration.digest(path) != old_hash
            @test candidate.parameters[:background] == values[:background]
            changed = project(parameter_sources=candidate.parameter_sources)
            @test changed.parameter_sha256[:background] != old_hash
            @test all(==(8.0f0),changed.parameters[:background])

            source = candidate.parameter_sources[:background]
            @test_throws ArgumentError project(parameter_sources=[:background=>source])
            @test_throws ArgumentError project(parameter_sources=Dict("background"=>source))
            @test_throws ArgumentError project(parameter_sources=Dict(:missing=>source))
            @test_throws ArgumentError project(parameter_sources=Dict(:raw=>source))
            @test_throws ArgumentError project(parameter_sources=Dict(:background=>values[:background]))
            @test_throws ArgumentError project(parameter_sources=Dict(:background=>Artifacts.FITSArtifact(path)))
            @test_throws DimensionMismatch project(parameter_sources=Dict(
                :background=>Artifacts.FITSArtifact(path;axes=(1,))))
            wrong = joinpath(directory,"wrong-shape.fits")
            Calibration.write_fits(wrong,zeros(Float32,2,3))
            @test_throws DimensionMismatch project(parameter_sources=Dict(
                :background=>Artifacts.FITSArtifact(wrong;axes=(2,1))))
            reference = candidate.parameter_sources[Symbol("reference-slopes")]
            @test_throws DimensionMismatch project(parameter_sources=Dict(
                Symbol("reference-slopes")=>Artifacts.FITSArtifact(reference.path;axes=(1,2))))
        end
    finally
        for descriptor in (base,candidate,changed)
            descriptor === nothing || FilterGraphIsland.close_execution(descriptor.graph)
        end
    end
    @test originals == original_copies
    @test Calibration.read_parameters(application) == original_copies
    @test application_hashes(application) == before
    @test !any(id.name in ("CUDA","AMDGPU") for id in keys(Base.loaded_modules))
end
