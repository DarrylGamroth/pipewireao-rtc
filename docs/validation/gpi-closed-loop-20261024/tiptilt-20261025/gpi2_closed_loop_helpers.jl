# Private-array scientific selector; opens no PipeWire core or live device.
# julia --project=<science-env> test/gpi2_closed_loop.jl cpu|cuda SOURCE CALIBRATION REPORT.yaml [all|spillover|probes|weak-probe|noisy|timing] [VALIDATION_STEPS] [TIMING_STEPS] [WARMUP_STEPS]
module GPIClosedLoopValidation
using Test, LinearAlgebra, Statistics, SHA
using PipeWireAORTC, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL
using FilterGraphAlgorithms, JuliaFilterGraph

const IC = PipeWireAORTC.InstrumentConfiguration
const C = PipeWireAORTC.Common
const AG = AdaptiveOpticsSim.AlgorithmGraphs
const B = AdaptiveOpticsSim.Backends
const START_NS = time_ns()
const RUNNER_SHA256 = bytes2hex(sha256(read(@__FILE__)))
function progress(label)
    println("PROGRESS ", round((time_ns() - START_NS) / 1e9; digits=3), "s ", label)
    flush(stdout)
end

const CUDA_MODULE = !isempty(ARGS) && first(ARGS) == "cuda" ? Base.require(@__MODULE__, :CUDA) : nothing

function artifact(calibration, receipt, name, type, shape)
    filename = String(name) * ".fits"
    path = joinpath(calibration, "artifacts", filename)
    bytes2hex(sha256(read(path))) == receipt["artifact_sha256"][filename] ||
        error("calibration artifact hash differs: $filename")
    descriptor = PipeWireAORTC.Artifacts.FITSArtifact(path;
        axes=reverse(ntuple(identity, length(shape))))
    return PipeWireAORTC.Artifacts.prepare(descriptor, type, shape).data
end

function controller(calibration, receipt; tiptilt_limit=nothing)
    progress("controller: decode calibrated graph")
    concrete = PipeWireAORTC.DeploymentConfiguration.decode(joinpath(calibration, "graph.conf"), "/opt/pipewireao")
    props = deepcopy(only(n for n in concrete["filter.graph"]["nodes"] if n["name"] == "closed-loop-correction")["props"])
    if !isnothing(tiptilt_limit)
        only(n for n in concrete["filter.graph"]["nodes"] if n["name"] == "tiptilt-command")["config"]["command_limits"] = [-Float64(tiptilt_limit), Float64(tiptilt_limit)]
    end
    progress("controller: prepare JFG graph")
    graph = mktempdir() do directory
        path = joinpath(directory, "graph.conf")
        PipeWireAORTC.ScienceExport.write_spa_config(path, concrete;
            header="Generated private-array scientific validation graph; do not edit.")
        JuliaFilterGraph.prepare_graph(path; algorithms=FilterGraphAlgorithms.algorithms())
    end
    progress("controller: load parameter FITS")
    parameters = Dict(name => artifact(calibration, receipt, name, format.element_type, format.shape)
        for (name, format) in pairs(JuliaFilterGraph.parameter_formats(graph)))
    JuliaFilterGraph.replace_parameters!(graph, pairs(parameters)...)
    progress("controller: parameters bound")
    inputs = map(f -> zeros(f.element_type, f.shape), JuliaFilterGraph.input_formats(graph))
    outputs = map(f -> zeros(f.element_type, f.shape), JuliaFilterGraph.output_formats(graph))
    @assert eltype(inputs.raw) === UInt16
    return (; graph, parameters, inputs, outputs, props)
end

execution_policy(::B.HostComputeDevice) = AG.StreamGraphExecution()
execution_policy(::B.AcceleratorComputeDevice) = AG.CapturedGraphExecution()

function plant(source, receipt, target; calibration)
    recipe = receipt["recipe"]
    progress("plant: load declared simulation and verify prescription")
    declaration = IC.load_simulation(joinpath(source, recipe["simulation"]))
    settings = IC.settings(declaration, get(recipe, "settings", Dict()))
    IC.prescription_identity(declaration, settings) == receipt["source_prescription_identity"] || error("source prescription differs from calibration")
    execution = execution_policy(target)
    progress("plant: prepare optical graph ($execution), calibration=$calibration")
    system = IC.prepare_system(declaration.path; settings, calibration, target, execution)
    eltype(AG.hil_frame_buffer(system.boundary)) === UInt16 || error("camera HIL frame must be UInt16")
    progress("plant: optical graph ready")
    support = IC.binding_values(declaration, settings, Dict("kind" => "pupil_support", "resolution" => "pupil_resolution"))
    xy = IC.binding_values(declaration, settings, Dict("kind" => "pupil_coordinates", "resolution" => "pupil_resolution"))
    valid = findall(vec(support) .!= 0)
    return (; system, declaration, settings, valid, xy)
end

function pupil_rms(opd, valid)
    samples = Float64.(vec(Array(opd))[valid])
    samples .-= mean(samples)
    return sqrt(sum(abs2, samples) / length(samples))
end

commands(system) = map(zero, AG.hil_command_buffer(system.boundary))
function reset!(p, control, command)
    AG.reset_hil_boundary!(p.system.boundary, p.system.driver)
    JuliaFilterGraph.reset!(control.graph)
    foreach(c -> fill!(c, 0f0), command)
    fill!(control.inputs.var"constraint-feedback", 0f0)
    return nothing
end

function frame!(system, command)
    boundary = system.boundary
    sequence = AG.hil_boundary_status(boundary).frame_sequence
    if sequence == 0
        all(c -> all(iszero, c), command) || error("first frame requires initial zero commands")
    else
        for name in keys(command)
            copyto!(getproperty(AG.hil_command_buffer(boundary), name), getproperty(command, name))
        end
        AG.adopt_hil_command!(boundary, sequence)
    end
    AG.step_hil_frame_at!(boundary, system.driver)
    return AG.hil_frame_buffer(boundary)
end

function process!(control, raw)
    eltype(control.inputs.raw) === UInt16 || error("controller camera input must be UInt16")
    copyto!(control.inputs.raw, raw) # Exact conversion of already-rounded ADC codes; rejects fractional values.
    result = JuliaFilterGraph.process!(control.outputs, control.graph, control.inputs)
    all(values(result)) || error("controller rejected frame: $result")
    return nothing
end

function full_step!(system, control, command)
    process!(control, frame!(system, command))
    for name in keys(command)
        copyto!(getproperty(command, name), getproperty(control.outputs, name))
    end
    copyto!(control.inputs.var"constraint-feedback", control.outputs.var"controller-constraint-feedback")
    return nothing
end

function command_projection(control, recipe, coefficients, command)
    for entry in recipe["mirrors"]
        name = entry["name"]
        getproperty(command, Symbol(name)) .= control.parameters[Symbol(name * "-vdm-to-pdm")] *
            (control.parameters[Symbol(name * "-active-to-full")] *
            (control.parameters[Symbol(name * "-selection")] * coefficients))
    end
    stage = recipe["tiptilt"]
    projected = control.parameters[Symbol("controller-to-" * stage["command_input"])] * coefficients
    getproperty(command, Symbol(stage["command_input"])) .= projected
    getproperty(command, Symbol(stage["mirror"])) .-=
        control.parameters[Symbol(stage["command_input"] * "-to-" * stage["mirror"])] * projected
    return command
end

function spillover!(report, source, calibration, receipt, p)
    # This deliberately clips the stage in the test-owned controller only.
    limit = Float32(receipt["poke_m"]) / 2
    control = controller(calibration, receipt; tiptilt_limit=limit)
    report["controller_props"] = control.props
    report["camera_frame_element_type"] = string(eltype(AG.hil_frame_buffer(p.system.boundary)))
    command = commands(p.system)
    reset!(p, control, command)
    raw = frame!(p.system, command)
    stage = receipt["recipe"]["tiptilt"]
    projection = control.parameters[Symbol("controller-to-" * stage["command_input"])]
    desired = Float32[4limit, -3limit]
    progress("spillover: SVD pseudoinverse of stage projection $(size(projection))")
    modal = pinv(projection) * desired
    progress("spillover: stage projection solved")
    @test projection * modal ≈ desired rtol=1e-6
    # On the first frame the previous-intensity normalization is zero. Set the
    # known reference so the source-owned first integrator output equals modal.
    reference = modal ./ Float32(control.props["gain"])
    JuliaFilterGraph.replace_parameters!(control.graph, Symbol("modal-reference") => reference)
    process!(control, raw)
    for name in keys(command)
        copyto!(getproperty(command, name), getproperty(control.outputs, name))
    end
    actual_stage = getproperty(command, Symbol(stage["command_input"]))
    @test actual_stage ≈ clamp.(desired, -limit, limit) rtol=2e-5 atol=1e-13
    @test maximum(abs, getproperty(command, Symbol(stage["mirror"]))) > 0
    frame!(p.system, command)
    requested = p.xy[:, :, 1] .* desired[1] .+ p.xy[:, :, 2] .* desired[2]
    actual = Array(AG.graph_output(p.system.graph, :pupil_opd))
    ratio = norm(vec(actual - requested)[p.valid]) / norm(vec(requested)[p.valid])
    report["spillover"] = Dict("stage_limit_m" => limit, "requested_coefficients_m" => desired,
        "demanded_coefficients_m" => copy(actual_stage), "relative_pupil_opd_error" => ratio,
        "published_fit_relative_residual" => receipt["tiptilt_fit_relative_residual"])
    @test ratio < 1.2 * receipt["tiptilt_fit_relative_residual"]
    return nothing
end

function representative_modes(control, receipt)
    stage = receipt["recipe"]["tiptilt"]
    stage_projection = control.parameters[Symbol("controller-to-" * stage["command_input"])]
    selected = Pair{String,Int}[]
    for axis in axes(stage_projection, 1)
        columns = findall(!iszero, vec(stage_projection[axis, :]))
        length(columns) == 1 || error("representative stage axis requires one explicitly selected modal coordinate")
        push!(selected, "tiptilt-$axis" => only(columns))
    end
    rms = receipt["mode_rms"]
    for entry in receipt["recipe"]["mirrors"]
        selection = control.parameters[Symbol(entry["name"] * "-selection")]
        columns = findall(i -> any(!iszero, view(selection, :, i)) && all(iszero, view(stage_projection, :, i)), axes(selection, 2))
        isempty(columns) && error("mirror has no non-stage representative coordinate")
        push!(selected, entry["name"] => columns[argmax(rms[columns])])
    end
    return selected
end

function probes!(report, source, calibration, receipt, p; steps, mode_names=nothing,
        amplitudes=Float32[10e-9, 20e-9, 40e-9], checkpoint=()->nothing)
    control = controller(calibration, receipt)
    command = commands(p.system)
    n = length(control.parameters[Symbol("modal-reference")])
    interaction = artifact(calibration, receipt, "interaction-matrix", Float32,
        reverse(size(control.parameters[:reconstructor])))
    base_reference = copy(control.parameters[Symbol("modal-reference")])
    cases = Dict{String,Any}()
    report["probes"] = cases
    reset!(p, control, command)
    flat_history = Float64[]
    progress("probes: measure zero-disturbance quantized closed-loop settling")
    for _ in 1:steps
        full_step!(p.system, control, command)
        push!(flat_history, pupil_rms(AG.graph_output(p.system.graph, :pupil_opd), p.valid))
    end
    report["quantized_flat_loop"] = Dict("steps" => steps, "history_rms_m" => flat_history,
        "trailing_mean_rms_m" => mean(flat_history[end-7:end]))
    checkpoint()
    selected = representative_modes(control, receipt)
    if !isnothing(mode_names)
        all(name -> name in first.(selected), mode_names) || error("unknown representative probe mode")
        filter!(pair -> first(pair) in mode_names, selected)
    end
    for (name, mode) in selected
        samples = Dict{String,Any}()
        cases[name] = Dict("controller_index_one_based" => mode, "samples" => samples)
        for amplitude in amplitudes
            progress("probe $name: $(amplitude * 1e9) nm, held +/- exposures")
            reset!(p, control, command)
            frame!(p.system, command)
            sides = map((1f0, -1f0)) do sign
                coefficients = zeros(Float32, n); coefficients[mode] = sign * amplitude
                command_projection(control, receipt["recipe"], coefficients, command)
                raw = frame!(p.system, command)
                JuliaFilterGraph.reset!(control.graph)
                fill!(control.inputs.var"constraint-feedback", 0f0)
                process!(control, raw); process!(control, raw)
                vec(permutedims(control.outputs.var"reconstruction-pixels"))
            end
            derivative = (sides[1] - sides[2]) / (2amplitude)
            reference = view(interaction, :, mode)
            difference = norm(derivative - reference) / norm(reference)
            # Test optical convergence separately, using this mode's actual AOS
            # wavefront as the known injected disturbance, with quantized frames.
            reset!(p, control, command)
            frame!(p.system, command)
            coefficients = zeros(Float32, n); coefficients[mode] = amplitude
            command_projection(control, receipt["recipe"], coefficients, command)
            frame!(p.system, command)
            disturbance = Array(AG.graph_output(p.system.graph, :pupil_opd))
            before = pupil_rms(disturbance, p.valid)
            reset!(p, control, command)
            JuliaFilterGraph.replace_parameters!(control.graph, Symbol("modal-reference") => base_reference)
            copyto!(AG.graph_input(p.system.graph, :uncompensated_opd), disturbance)
            history = Float64[]
            progress("probe $name: $steps closed-loop steps")
            for _ in 1:steps
                full_step!(p.system, control, command)
                push!(history, pupil_rms(AG.graph_output(p.system.graph, :pupil_opd), p.valid))
            end
            ratio = mean(history[end-7:end]) / before
            samples[string(round(Int, amplitude * 1e9)) * "nm"] = Dict(
                "amplitude_m" => amplitude, "interaction_relative_difference_from_20nm" => difference,
                "initial_rms_m" => before, "residual_ratio" => ratio,
                "trailing_mean_residual_rms_m" => mean(history[end-7:end]),
                "history_rms_m" => history)
            checkpoint()
            println("PROBE $name $amplitude derivative_difference=$difference residual_ratio=$ratio"); flush(stdout)
            @test all(isfinite, derivative)
            @test difference < 0.25
            @test ratio < 0.8
            fill!(AG.graph_input(p.system.graph, :uncompensated_opd), 0f0)
        end
    end
    return nothing
end

function noisy!(report, source, calibration, receipt, target; steps=128, timing_steps=128, warmup_steps=min(steps, 256), measure_timing=true, checkpoint=()->nothing)
    progress("preparing production noisy plant")
    p = plant(source, receipt, target; calibration=false)
    control = controller(calibration, receipt)
    report["controller_props"] = control.props
    report["camera_frame_element_type"] = string(eltype(AG.hil_frame_buffer(p.system.boundary)))
    command = commands(p.system)
    reset!(p, control, command)
    atmosphere = Float64[]; residual = Float64[]
    progress("production: $steps noisy moving-atmosphere steps")
    for _ in 1:steps
        full_step!(p.system, control, command)
        push!(atmosphere, pupil_rms(AG.graph_output(p.system.graph, :atmosphere_opd), p.valid))
        push!(residual, pupil_rms(AG.graph_output(p.system.graph, :pupil_opd), p.valid))
    end
    trailing = max(1, steps ÷ 2):steps
    ratio = mean(residual[trailing]) / mean(atmosphere[trailing])
    report["noisy_atmosphere"] = Dict("steps" => steps, "model_period_s" => p.system.frame_period_s,
        "paired_atmosphere_rms_m" => atmosphere, "paired_residual_rms_m" => residual,
        "trailing_mean_residual_ratio" => ratio,
        "model_sequence" => AG.model_time_sequence(p.system.driver), "settings" => p.settings)
    checkpoint()
    println("NOISY residual_ratio=$ratio initial=$(first(residual)) final=$(last(residual))"); flush(stdout)
    @test AG.model_time_sequence(p.system.driver) == steps
    @test all(isfinite, residual)
    @test maximum(atmosphere) > minimum(atmosphere)
    @test ratio < 1
    if measure_timing
        runs = Vector{UInt64}[]
        gc_deltas = Dict{String,Int64}[]
        load_snapshots = Vector{String}[]
        sequence_windows = Dict{String,UInt64}[]
        # Warm each reset state before sampling completed steps. Observation RMS
        # copies/reductions and receipts remain outside the timed boundary.
        for repetition in 1:3
            progress("timing repetition $repetition: reset and warm $warmup_steps steps")
            reset!(p, control, command)
            for _ in 1:warmup_steps
                full_step!(p.system, control, command)
            end
            progress("timing repetition $repetition: sample $timing_steps completed steps")
            durations = Vector{UInt64}(undef, timing_steps)
            push!(load_snapshots, Sys.islinux() ? readlines(`/bin/ps -eo pid,comm,pcpu,rss`) : ["not collected"])
            start_sequence = AG.model_time_sequence(p.system.driver)
            gc_before = Base.gc_num()
            for i in eachindex(durations)
                started = time_ns()
                full_step!(p.system, control, command)
                durations[i] = time_ns() - started
            end
            gc_delta = Base.GC_Diff(Base.gc_num(), gc_before)
            end_sequence = AG.model_time_sequence(p.system.driver)
            @test end_sequence - start_sequence == timing_steps
            push!(sequence_windows, Dict("start_sequence" => UInt64(start_sequence),
                "end_sequence" => UInt64(end_sequence)))
            push!(gc_deltas, Dict(String(field) => Int64(getfield(gc_delta, field))
                for field in fieldnames(Base.GC_Diff)))
            push!(runs, durations)
        end
        report["warmed_full_step"] = Dict(
            "scope" => "sequential completed AOS model-time plant/HIL frame copy, camera-to-UInt16 input copy, host JFG controller, command and feedback copies; excludes PipeWire/native transport, GUI, observation RMS and wall-clock pacing",
            "warmup_steps_per_repetition" => warmup_steps, "steps_per_repetition" => timing_steps,
            "repetition_reset" => "reset model driver, atmosphere/detector RNG and controller before each warmup",
            "gc_deltas" => gc_deltas,
            "model_sequence_windows" => sequence_windows,
            "concurrent_process_snapshots_pid_comm_lifetime_percent_cpu_rss_kib" => load_snapshots,
            "gc_policy" => "normal automatic collection; no explicit collection between warmup and samples",
            "raw_duration_ns" => runs, "rate_hz" => [1e9 * length(run) / sum(run) for run in runs],
            "median_step_ms" => [median(run) / 1e6 for run in runs],
            "p90_step_ms" => [quantile(run, 0.9) / 1e6 for run in runs],
            "maximum_step_ms" => [maximum(run) / 1e6 for run in runs],
            "fixed_rate_latency_qualified" => false)
        println("TIMING rate_hz=", report["warmed_full_step"]["rate_hz"]); flush(stdout)
    end
    return nothing
end

function main(args=ARGS)
    4 <= length(args) <= 8 || error("usage: gpi2_closed_loop.jl cpu|cuda SOURCE CALIBRATION REPORT.yaml [all|spillover|probes|weak-probe|noisy|timing] [VALIDATION_STEPS] [TIMING_STEPS] [WARMUP_STEPS]")
    backend, source, calibration, output = args[1], abspath(args[2]), abspath(args[3]), abspath(args[4])
    backend in ("cpu", "cuda") || error("select cpu or cuda")
    phase = length(args) >= 5 ? args[5] : "all"
    phase in ("all", "spillover", "probes", "weak-probe", "noisy", "timing") || error("unknown validation phase")
    steps = length(args) >= 6 ? parse(Int, args[6]) : 128
    timing_steps = length(args) >= 7 ? parse(Int, args[7]) : 128
    warmup_steps = length(args) >= 8 ? parse(Int, args[8]) : min(steps, 256)
    steps >= 32 && timing_steps >= 32 && warmup_steps >= 32 || error("at least 32 steps required")
    ispath(output) && error("report must be fresh to preserve previous gates")
    backend == "cuda" && CUDA_MODULE.allowscalar(false)
    BLAS.set_num_threads(1); B.set_fft_provider_threads!(1)
    target = backend == "cpu" ? B.HostComputeDevice() : B.AcceleratorComputeDevice(B.CUDABackend(), 0)
    receipt = C.read_yaml(joinpath(calibration, "result.yaml"))
    bytes2hex(sha256(read(joinpath(source, receipt["recipe"]["graph"])))) == receipt["source_graph_sha256"] || error("authored graph differs from calibration")
    bytes2hex(sha256(read(joinpath(calibration, "graph.conf")))) == receipt["graph_sha256"] || error("calibrated graph differs from receipt")
    for (filename, expected) in receipt["artifact_sha256"]
        bytes2hex(sha256(read(joinpath(calibration, "artifacts", filename)))) == expected ||
            error("calibration artifact hash differs: $filename")
    end
    report = Dict{String,Any}("scope" => "private-array provisional GPI model; no native RTC, physical device or deadline qualification",
        "backend" => backend, "julia_version" => string(VERSION), "julia_threads" => Threads.nthreads(),
        "blas_threads" => BLAS.get_num_threads(), "cpu" => first(Sys.cpu_info()).model,
        "calibration_result_sha256" => bytes2hex(sha256(read(joinpath(calibration, "result.yaml")))),
        "source_graph_sha256" => bytes2hex(sha256(read(joinpath(source, receipt["recipe"]["graph"])))),
        "calibrated_graph_sha256" => receipt["graph_sha256"],
        "source_prescription_identity" => receipt["source_prescription_identity"],
        "verified_artifact_sha256" => receipt["artifact_sha256"],
        "phase" => phase, "source" => source, "calibration" => calibration,
        "require_uint16_camera" => true,
        "cuda_package_version" => backend == "cuda" ? string(Base.pkgversion(CUDA_MODULE)) : nothing)
    if backend == "cuda"
        report["gpu"] = Dict("name" => CUDA_MODULE.name(CUDA_MODULE.device()),
            "runtime_version" => string(CUDA_MODULE.runtime_version()),
            "driver_version" => string(CUDA_MODULE.driver_version()))
    end
    report["runner_sha256"] = RUNNER_SHA256
    report["runner_path"] = abspath(@__FILE__)
    report["environment"] = Dict("os" => string(Sys.KERNEL),
        "kernel_release" => Sys.islinux() ? strip(read("/proc/sys/kernel/osrelease", String)) : "not collected",
        "cpus_allowed_list" => Sys.islinux() ? strip(only(filter(line -> startswith(line, "Cpus_allowed_list:"), readlines("/proc/self/status")))) : "not collected",
        "blas_config" => sprint(show, BLAS.get_config()),
        "logical_cpu_count" => Sys.CPU_THREADS,
        "context" => get(ENV, "GPI_BENCHMARK_CONTEXT", "shared workstation; no CPU isolation or fixed-rate load qualification"))
    report["passed"] = false
    checkpoint() = C.write_yaml(output, report; header="Generated finite GPI numerical evidence; preserve failed gates.")
    checkpoint()
    try
        @testset "GPI calibrated quantized optical loop ($backend)" begin
            if phase in ("all", "spillover", "probes", "weak-probe")
                progress("preparing calibration plant ($backend)")
                p = plant(source, receipt, target; calibration=true)
                progress("calibration plant ready; camera=$(eltype(AG.hil_frame_buffer(p.system.boundary)))")
                if phase in ("all", "spillover")
                    spillover!(report, source, calibration, receipt, p)
                    checkpoint()
                end
                if phase in ("all", "probes", "weak-probe")
                    # The bounded follow-up isolates the declared tweeter family's
                    # weakest tested amplitude after a shorter-window gate failed.
                    modes = phase == "weak-probe" ? ["tweeter"] : nothing
                    amplitudes = phase == "weak-probe" ? Float32[10e-9] : Float32[10e-9, 20e-9, 40e-9]
                    probes!(report, source, calibration, receipt, p; steps,
                        mode_names=modes, amplitudes, checkpoint)
                end
            end
            phase in ("all", "noisy", "timing") && noisy!(report, source, calibration, receipt, target;
                steps, timing_steps, warmup_steps, measure_timing=phase in ("all", "timing"), checkpoint)
        end
        report["passed"] = true
    catch error
        report["passed"] = false
        report["error"] = sprint(showerror, error)
        rethrow()
    finally
        C.write_yaml(output, report; header="Generated finite GPI numerical evidence; preserve failed gates.")
    end
    return report
end
end

GPIClosedLoopValidation.progress("modules loaded; entering selector")
