# Opt-in CPU transport, independent WFS summary oracle, exact replay and reset.
module ClassicWFSSummary
using Test, Libdl, LinearAlgebra
using PipeWireAORTC, PipeWireAO, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL
using AdaptiveOpticsSim.AlgorithmGraphs
using FilterGraphIsland, JuliaFilterGraph
include("classic_managed_replay.jl")
include("classic_fft_oracle.jl")
const M = ClassicManagedReplay
const R = PipeWireAORTC.SessionRuntime
const C = PipeWireAORTC.Common
const COUNT = 32
const NAMES = (:detector, :demanded, :slopes, :flux, :validity, :summary)
const SUMMARY = (name="summary", node="rtc-wfs-summary-queue-output", media="wfs-summary",
    type=Float32, wire=NdArray.F32_LE, shape=(8,),
    schema="pipewireao/shack-hartmann-summary-f32/1", rate=nothing)
const STREAMS = (map(NAMES[1:5]) do name
    only(filter(spec -> spec.name == string(name), M.CLASSIC_OBSERVATION_STREAMS))
end..., SUMMARY)

function capture(handle, stage, prefix)
    mkpath(stage)
    _, initial = M.source_snapshot(M.dump_graph(handle, stage, prefix, "graph-ready"))
    @test !initial["running"] && initial["sequence"] == 0
    records = Any[]
    factory = capture -> begin
        record = M.PrefixCapture(capture, COUNT)
        push!(records, record)
        record
    end
    observation = M.observe_classic(R._ledger(handle)["remote"]; timeout=140,
        stream_specs=STREAMS, selected_streams=string.(NAMES), drive_interval=0.005,
        expected_generation=UInt64(initial["generation"]), process_capture=factory,
        valid_payload=c -> c.schema == SUMMARY.schema ?
            all(x -> isfinite(x) || isnan(x), c.values) : c.finite,
        on_ready=() -> M.request(handle, stage, "start", ["session-start"]),
        finished=_ -> length(records) == length(NAMES) && all(record -> all(record.seen), records))
    @test M.request(handle, stage, "stop", ["session-stop"])["state"] == "Ready"
    _, snapshot = M.source_snapshot(M.dump_graph(handle, stage, prefix, "graph-stopped"))
    @test snapshot["completed"] && !snapshot["running"] && snapshot["sequence"] == COUNT
    @test snapshot["generation"] == initial["generation"]
    @test length(records) == length(NAMES)
    named = NamedTuple{NAMES}(Tuple(records))
    hashes = Dict{String,String}()
    provenance = Dict{String,Any}()
    for (name, record) in pairs(named)
        @test all(record.seen)
        path = joinpath(stage, string(name)*".bin")
        write(path, record.values)
        hashes[string(name)] = C.sha256_file(path)
        provenance[string(name)] = Dict("seen"=>record.seen,
            "identities"=>M._classic_identity_record.(record.identities),
            "pts_ns"=>[header === nothing ? nothing : header.pts for header in record.headers])
    end
    observation["payload_sha256"] = hashes
    C.write_json(joinpath(stage, "observation.json"), observation)
    C.write_json(joinpath(stage, "prefix-identities.json"), provenance)
    return named, snapshot
end

# This oracle consumes the captured row-major payloads, never the production
# summary helper. Float64 reductions precede each final Float32 conversion.
function summary_oracle(slopes, flux, validity)
    n = length(validity)
    length(slopes) == 2n && length(flux) == n || throw(DimensionMismatch("WFS products"))
    all(value -> value in (0, 1), validity) || error("noncanonical validity")
    selected = findall(==(1), validity)
    count = length(selected)
    result = fill(NaN32, 8)
    result[1:2] = Float32[n, count]
    count == 0 && return result
    x = [Float64(slopes[2i-1]) for i in selected]
    y = [Float64(slopes[2i]) for i in selected]
    f = Float64.(flux[selected])
    all(isfinite, x) && all(isfinite, y) && all(isfinite, f) || return result
    total(values) = foldl(+, values; init=0.0)
    rms_x = sqrt(total(abs2.(x)) / count)
    rms_y = sqrt(total(abs2.(y)) / count)
    result[3:8] = Float32[total(f)/count, rms_x, rms_y, hypot(rms_x, rms_y),
        total(x)/count, total(y)/count]
    return result
end

function check_cohort(records, generation)
    for index in 1:COUNT
        identity = something(records.detector.identities[index])
        @test identity.sequence == index && identity.generation == generation
        pts = something(records.detector.headers[index]).pts
        for record in values(records)
            @test something(record.identities[index]) == identity
            @test something(record.headers[index]).sequence == index
            @test something(record.headers[index]).pts == pts
        end
        expected = summary_oracle(@view(records.slopes.values[:,index]),
            @view(records.flux.values[:,index]), @view(records.validity.values[:,index]))
        @test reinterpret(UInt32, expected) == reinterpret(UInt32, @view(records.summary.values[:,index]))
    end
end

# Preserve byte equality, including signed zero and Float32 NaN representation.
bitwise_equal(a, b) = size(a) == size(b) &&
    reinterpret(UInt8, vec(a)) == reinterpret(UInt8, vec(b))
row_major(values::AbstractVector) = values
row_major(values::AbstractMatrix) = vec(permutedims(values))

function controller_storage(application)
    graph = M.ClassicReplay.prepare_controller(application)
    raw = zeros(UInt16, 352, 352)
    feedback = zeros(Float32, getproperty(graph.input_formats, M.ClassicReplay.FEEDBACK_IN).shape)
    inputs = NamedTuple{(:raw, M.ClassicReplay.FEEDBACK_IN)}((raw, feedback))
    outputs = map(format -> zeros(format.element_type, format.shape), graph.output_formats)
    return (;graph, raw, feedback, inputs, outputs)
end

function warm_controller!(storage, records)
    M.ClassicReplay.load_frame!(storage.raw, records.detector.values, 1)
    JuliaFilterGraph.process!(storage.outputs, storage.graph, storage.inputs)
    JuliaFilterGraph.reset!(storage.graph)
    fill!(storage.feedback, 0)
end

process_allocations(storage) = @allocated JuliaFilterGraph.process!(storage.outputs, storage.graph, storage.inputs)

function replay_controller(application, records; baseline_application=nothing)
    # Keep the established controller oracle as an independent exact demand check.
    adopted = records.demanded.values .* M.ClassicReplay.SCALE
    @test bitwise_equal(M.ClassicReplay.replay(application, records.detector.values, adopted), adopted)
    current = controller_storage(application)
    baseline = nothing
    allocations = Int[]
    baseline_allocations = Int[]
    try
        baseline = baseline_application === nothing ? nothing : controller_storage(baseline_application)
        warm_controller!(current, records)
        baseline === nothing || warm_controller!(baseline, records)
        # Compile the measurement wrapper, then reset the mutated controller.
        process_allocations(current)
        JuliaFilterGraph.reset!(current.graph); fill!(current.feedback, 0)
        if baseline !== nothing
            process_allocations(baseline)
            JuliaFilterGraph.reset!(baseline.graph); fill!(baseline.feedback, 0)
            @test all(name -> hasproperty(current.outputs, name), keys(baseline.outputs))
        end
        for index in 1:COUNT
            M.ClassicReplay.load_frame!(current.raw, records.detector.values, index)
            push!(allocations, process_allocations(current))
            @test allocations[end] == 0
            for name in NAMES[2:6]
                expected = row_major(getproperty(current.outputs, name))
                @test bitwise_equal(expected, @view(getproperty(records, name).values[:,index]))
            end
            if baseline !== nothing
                M.ClassicReplay.load_frame!(baseline.raw, records.detector.values, index)
                push!(baseline_allocations, process_allocations(baseline))
                @test baseline_allocations[end] == 0
                for name in keys(baseline.outputs)
                    @test bitwise_equal(getproperty(current.outputs, name), getproperty(baseline.outputs, name))
                end
                copyto!(baseline.feedback, getproperty(baseline.outputs, M.ClassicReplay.FEEDBACK_OUT))
            end
            copyto!(current.feedback, getproperty(current.outputs, M.ClassicReplay.FEEDBACK_OUT))
        end
    finally
        baseline === nothing || FilterGraphIsland.close_execution(baseline.graph)
        FilterGraphIsland.close_execution(current.graph)
    end
    return Dict("exact_demanded_replay"=>true, "exact_wfs_product_replay"=>true,
        "warmed_process_allocations_bytes"=>allocations,
        "baseline_compared"=>baseline_application !== nothing,
        "baseline_warmed_process_allocations_bytes"=>baseline_allocations)
end

function prepare_plant(application)
    base = PipeWireAORTC.AOSOwner.configuration(joinpath(application, "simulation.conf"))
    instrument = PipeWireAORTC.AOSOwner.load_instrument(base.plant.package)
    options = merge(base, (;plant_module=instrument, remote="/tmp/unused-wfs-summary-replay", control_node="simulator-wfs"))
    return PipeWireAORTC.AOSOwner.prepare_science(options)
end

function replay_detector!(science, records, generation)
    expected = zeros(UInt16, 352, 352)
    for index in 1:COUNT
        stamp = step_hil_frame_at!(science.boundary, science.driver)
        @test stamp.sequence == index
        M.ClassicReplay.load_frame!(expected, records.detector.values, index)
        @test expected == round.(UInt16, hil_frame_buffer(science.boundary))
        @test something(records.detector.identities[index]).generation == generation
        copyto!(hil_command_buffer(science.boundary), @view(records.demanded.values[:,index]) .* M.ClassicReplay.SCALE)
        adopt_hil_command!(science.boundary, stamp.sequence)
    end
    return true
end

function gpu_audit()
    @test !any(id -> id.name in ("CUDA", "AMDGPU", "GPUCompiler"), keys(Base.loaded_modules))
    @test isempty(filter(path -> occursin(r"(?i)(libcuda|libcudart|libcublas|libcufft|libamdhip|libhsa-runtime)", path), Libdl.dllist()))
end

function check_cleanup(handle, stage)
    final = R.final_record(stage)
    @test final["cleanup_complete"] && isempty(get(final, "cleanup_errors", []))
    @test !PipeWireAORTC.SystemdOwners.old_process_exists(handle.main_pid, handle.start_ticks)
    @test PipeWireAORTC.SystemdOwners.cgroup_empty(handle.cgroup)
    for owner in values(final["owners"])
        @test !PipeWireAORTC.SystemdOwners.old_process_exists(owner["pid"], UInt64(owner["start-ticks"]))
        @test PipeWireAORTC.SystemdOwners.cgroup_empty(owner["cgroup"])
    end
end

function main(application, stage, prefix; baseline_application=nothing)
    options = PipeWireAORTC.AOSOwner.configuration(joinpath(application, "simulation.conf"))
    @assert options.backend === :cpu && options.total_exchanges == COUNT && options.pacing_rate_hz == 2
    isfile(joinpath(application, "classic_fft_oracle.jl")) || throw(ArgumentError("prepare an isolated sealed application with the Classic FFT witness first"))
    BLAS.set_num_threads(1)
    AdaptiveOpticsSim.Backends.set_fft_provider_threads!(1)
    reports = Any[]
    @testset "Managed CPU WFS summary and reset" begin
        handle = R.start!(application, stage; prefix, deadline=R.monotonic()+1030)
        try
            M.gpu_audit(handle, stage)
            fft_directory = joinpath(R._ledger(handle)["runtime"], "fft-oracle")
            fft_contract = ClassicFFTOracle.restore!(fft_directory)
            science = Base.invokelatest(prepare_plant, application)
            @test ClassicFFTOracle.verify(science, fft_contract)
            cp(fft_directory, joinpath(stage, "fft-oracle"))
            previous = nothing
            for generation in 1:2
                directory = joinpath(stage, "generation-$generation")
                records, snapshot = capture(handle, directory, prefix)
                previous === nothing || @test snapshot["generation"] != previous
                check_cohort(records, snapshot["generation"])
                report = replay_controller(application, records; baseline_application)
                report["exact_detector_replay"] = replay_detector!(science, records, snapshot["generation"])
                report["generation"] = snapshot["generation"]
                report["frames_per_stream"] = Dict(string(name)=>count(record.seen) for (name, record) in pairs(records))
                report["shared_acquisition_identity_and_pts"] = true
                C.write_json(joinpath(directory, "wfs-summary-replay.json"), report)
                push!(reports, report)
                previous = snapshot["generation"]
                if generation == 1
                    M.request(handle, stage, "reset", ["reset"])
                    reset_hil_boundary!(science.boundary, science.driver)
                end
            end
            gpu_audit()
            M.gpu_audit(handle, stage)
        finally
            try
                R.shutdown!(handle; deadline=R.monotonic()+320)
            finally
                check_cleanup(handle, stage)
            end
        end
    end
    C.write_json(joinpath(stage, "wfs-summary-result.json"), Dict("complete"=>true, "backend"=>"cpu",
        "generations"=>reports, "reset_and_restart"=>true, "cleanup_complete"=>true,
        "summary_schema"=>SUMMARY.schema, "calibration_identity"=>options.calibration_identity,
        "manifest_sha256"=>C.sha256_file(joinpath(application, "Manifest.toml")),
        "test_sha256"=>C.sha256_file(@__FILE__),
        "fft_execution_contract"=>C.read_json(joinpath(stage, "fft-oracle", "plans.json")),
        "scope"=>"Two finite 32-frame CPU generations; exact six-stream identity, summary oracle, controller and detector replay, reset and cleanup; no cadence or hardware qualification"))
end
main(application, stage, prefix, baseline_application) = main(application, stage, prefix; baseline_application)
abspath(PROGRAM_FILE) == (@__FILE__) && main(ARGS...)
end
