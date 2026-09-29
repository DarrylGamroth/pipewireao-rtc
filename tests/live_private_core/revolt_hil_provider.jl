using AdaptiveOpticsSim.AlgorithmGraphs
using AdaptiveOpticsSimPipeWireHIL: exchange_frame!, frame_command_timing
using Base.Threads: Atomic
using LinearAlgebra
using PipeWireAO
using Printf
using REVOLTClassicSim
using REVOLTClassicSimPipeWireHIL

length(ARGS) == 4 || error(
    "expected CORE_NAME CONTROL_DIRECTORY NATIVE_GRAPH JULIA_GRAPH",
)
core_name, control_directory, native_graph_path, julia_graph_path = ARGS
native_phase_1 = joinpath(control_directory, "revolt-native-phase-1")
native_phase_2 = joinpath(control_directory, "revolt-native-phase-2")
native_phase_2_continue = joinpath(control_directory, "revolt-native-phase-2-continue")
native_phase_3 = joinpath(control_directory, "revolt-native-phase-3")
native_source_end = joinpath(control_directory, "revolt-native-source-end")
native_after_ready = joinpath(control_directory, "revolt-native-after-ready")
switch_to_julia = joinpath(control_directory, "revolt-switch-to-julia")
julia_phase_1 = joinpath(control_directory, "revolt-julia-phase-1")
julia_phase_2 = joinpath(control_directory, "revolt-julia-phase-2")
julia_phase_2_continue = joinpath(control_directory, "revolt-julia-phase-2-continue")
julia_phase_3 = joinpath(control_directory, "revolt-julia-phase-3")
julia_source_end = joinpath(control_directory, "revolt-julia-source-end")
julia_after_ready = joinpath(control_directory, "revolt-julia-after-ready")
stop_file = joinpath(control_directory, "stop-revolt-hil")
native_latency_phase = joinpath(control_directory, "revolt-native-latency")
julia_latency_phase = joinpath(control_directory, "revolt-julia-latency")

const SUBAPERTURE_SIZE = 22
const CONTROLLER_GAIN = -0.2f0
const CONTROLLER_POLE = 1.0f0
const UPDATED_CONTROLLER_GAIN = -0.1f0
const UPDATED_CONTROLLER_POLE = 0.9f0
const FINAL_CONTROLLER_GAIN = -0.05f0
const FINAL_CONTROLLER_POLE = 0.8f0
const UPDATED_RECONSTRUCTOR_SCALE = 0.5f0
const CONTROL_RTOL = 2.0f-2
const COMMAND_RTOL = 5.0f-4
const COMMAND_ATOL = 5.0f-11

"""
Optional completion-paced latency collection requested by the RTC private-core
fixture. The HIL adapter owns the source Header-PTS and command-receipt
timestamps. This provider only writes the completed, sequence-correlated
observations after the normal controller-equivalence sequence has passed.
"""
function latency_request()
    samples_text = get(ENV, "PIPEWIREAO_RTC_REVOLT_LATENCY_SAMPLES", nothing)
    isnothing(samples_text) && return nothing
    warmup = parse(Int, get(ENV, "PIPEWIREAO_RTC_REVOLT_LATENCY_WARMUP", "100"))
    samples = parse(Int, samples_text)
    warmup >= 0 || error("REVOLT latency warmup must be non-negative")
    samples > 0 || error("REVOLT latency samples must be positive")
    output = get(ENV, "PIPEWIREAO_RTC_REVOLT_LATENCY_CSV", nothing)
    isnothing(output) && error(
        "PIPEWIREAO_RTC_REVOLT_LATENCY_CSV is required when collecting REVOLT latency",
    )
    return (; warmup, samples, output)
end

function initialize_latency_csv!(request)
    parent = dirname(request.output)
    isdir(parent) || mkpath(parent)
    open(request.output, "w") do io
        println(
            io,
            "implementation,phase,observation,sequence,source_published_ns,command_received_ns,latency_ns",
        )
    end
    return nothing
end

function subaperture_origins()
    mask = valid_subapertures()
    origins = Tuple{Int,Int}[]
    for column in axes(mask, 2), row in axes(mask, 1)
        mask[row, column] || continue
        push!(
            origins,
            ((row - 1) * SUBAPERTURE_SIZE, (column - 1) * SUBAPERTURE_SIZE),
        )
    end
    length(origins) == 188 || error(
        "REVOLT Classic valid-subaperture mask selected $(length(origins)); expected 188",
    )
    return origins
end

const SUBAPERTURE_ORIGINS = subaperture_origins()

function controller_slopes(frame)
    slopes = Vector{Float32}(undef, 2 * length(SUBAPERTURE_ORIGINS))
    center = Float32(SUBAPERTURE_SIZE - 1) * 0.5f0
    for (subaperture, (row_origin, column_origin)) in
        enumerate(SUBAPERTURE_ORIGINS)
        x_moment = 0.0f0
        y_moment = 0.0f0
        flux = 0.0f0
        for row in 0:(SUBAPERTURE_SIZE - 1),
            column in 0:(SUBAPERTURE_SIZE - 1)
            value = frame[row_origin + row + 1, column_origin + column + 1]
            x_moment += value * (Float32(column) - center)
            y_moment += value * (Float32(row) - center)
            flux += value
        end
        isfinite(flux) || error(
            "REVOLT Classic subaperture $subaperture has non-finite flux $flux",
        )
        if flux > 0.0f0
            slopes[2 * subaperture - 1] = x_moment / flux
            slopes[2 * subaperture] = y_moment / flux
        else
            # The four lenslets wholly behind the central obstruction are
            # retained by the instrument's 188-entry geometric mask. The FGN
            # declaration reports them invalid and publishes zero slopes.
            slopes[2 * subaperture - 1] = 0.0f0
            slopes[2 * subaperture] = 0.0f0
        end
    end
    return slopes
end

function calibrate_controller()
    calibration = prepare_calibration_system()
    boundary = calibration.boundary
    sequence = step_hil_frame!(boundary)
    flat_slopes = controller_slopes(hil_frame_buffer(boundary))
    interaction = Matrix{Float32}(
        undef,
        length(flat_slopes),
        command_count(),
    )
    positive_slopes = similar(flat_slopes)
    poke = 2.0f-8

    for command_index in axes(interaction, 2)
        fill!(hil_command_buffer(boundary), 0.0f0)
        hil_command_buffer(boundary)[command_index] = poke
        adopt_hil_command!(boundary, sequence)
        sequence = step_hil_frame!(boundary)
        copyto!(positive_slopes, controller_slopes(hil_frame_buffer(boundary)))

        fill!(hil_command_buffer(boundary), 0.0f0)
        hil_command_buffer(boundary)[command_index] = -poke
        adopt_hil_command!(boundary, sequence)
        sequence = step_hil_frame!(boundary)
        negative_slopes = controller_slopes(hil_frame_buffer(boundary))
        @views @. interaction[:, command_index] =
            (positive_slopes - negative_slopes) / (2 * poke)
    end

    all(isfinite, interaction) || error(
        "REVOLT Classic interaction matrix contains a non-finite value",
    )
    singular_values = svdvals(interaction)
    retained_threshold = maximum(singular_values) * CONTROL_RTOL
    retained_rank = count(>(retained_threshold), singular_values)
    retained_rank >= 221 || error(
        "REVOLT Classic interaction matrix retains $retained_rank directions; expected at least 221",
    )
    control_matrix = pinv(interaction; rtol=CONTROL_RTOL)
    size(control_matrix) == (277, 376) || error(
        "REVOLT Classic control matrix has shape $(size(control_matrix)); expected (277, 376)",
    )
    return flat_slopes, control_matrix, retained_rank
end

function spa_float(value::Real)
    isfinite(value) || error("controller configuration contains a non-finite value")
    return @sprintf("%.9g", Float64(value))
end

spa_vector(values) = "[ " * join((spa_float(value) for value in values), " ") * " ]"

function parameter_values(control_matrix)
    return [
        control_matrix[row, column] for row in axes(control_matrix, 1) for
        column in axes(control_matrix, 2)
    ]
end

function graph_configuration(plugin, reference_slopes, control_matrix)
    origins = join(
        ("[ $(origin[1]) $(origin[2]) ]" for origin in SUBAPERTURE_ORIGINS),
        " ",
    )
    native_plugin = isnothing(plugin) ? "" : "plugin = \"$plugin\""
    native_rate = isnothing(plugin) ? "" : "rate = [ 500 1 ]"
    return """
    {
        node.name = pipewireao-rtc-revolt-controller
        remote.name = $core_name
        object.linger = false
        pipewireao.run-control = true
        pipewireao.reset-control = true
        filter.graph = {
            nodes = [
                {
                    type = ndarray
                    name = measure
                    $native_plugin
                    label = shack-hartmann-image-f32
                    config = {
                        image_rows = 352
                        image_columns = 352
                        subaperture_rows = 22
                        subaperture_columns = 22
                        subaperture_count = 188
                        image_schema = $REVOLT_CLASSIC_FRAME_SCHEMA
                        initial_subaperture_origins = [ $origins ]
                        coordinate_scale = 1.0
                        pixel_threshold = 0.0
                        flux_threshold = 0.0
                        reference_slopes = $(spa_vector(reference_slopes))
                        active = [ $(join(fill("true", 188), " ")) ]
                        $native_rate
                    }
                }
                {
                    type = ndarray
                    name = reconstruct
                    $native_plugin
                    label = shwfs-reconstructor-f32
                    config = {
                        actuator_count = 277
                        subaperture_count = 188
                        initial_reconstructor = $(spa_vector(parameter_values(control_matrix)))
                        reconstructed_schema = org.revolt.classic.controller-residual-error.f32/1
                        $native_rate
                    }
                }
                {
                    type = ndarray
                    name = integrate
                    $native_plugin
                    label = leaky-integrator-f32
                    config = {
                        extent = 277
                        initial_state = 0.0
                        input_schema = org.revolt.classic.controller-residual-error.f32/1
                        output_schema = $REVOLT_CLASSIC_COMMAND_SCHEMA
                        $native_rate
                    }
                    props = { gain = $CONTROLLER_GAIN pole = $CONTROLLER_POLE }
                }
            ]
            links = [
                { output = "measure:slopes" input = "reconstruct:slopes" }
                { output = "reconstruct:reconstructed" input = "integrate:input" }
            ]
            inputs = [ "measure:image" "reconstruct:reconstructor" ]
            outputs = [ "integrate:output" ]
        }
    }
    """
end

function first_difference(actual, expected; rtol, atol)
    for index in eachindex(actual, expected)
        isapprox(actual[index], expected[index]; rtol, atol) || return index
    end
    return nothing
end

function require_close(field, sequence, actual, expected; rtol, atol)
    isapprox(actual, expected; rtol, atol) && return nothing
    index = first_difference(actual, expected; rtol, atol)
    difference = isnothing(index) ? NaN : abs(actual[index] - expected[index])
    detail = if isnothing(index)
        ""
    else
        "[$index]: actual $(actual[index]), expected $(expected[index]), " *
        "absolute difference $difference"
    end
    error(
        "REVOLT Classic mismatch at sequence $sequence for $field$detail",
    )
end

arrays_close(actual, expected; rtol, atol) =
    all(
        index -> isapprox(actual[index], expected[index]; rtol, atol),
        eachindex(actual, expected),
    )

function prepare_phase(control_matrix)
    plant = prepare_revolt_classic_pipewire_hil(; remote=core_name)
    oracle = prepare_hil_system()
    oracle_sequence = Ref(step_hil_frame!(oracle.boundary))
    direct_state = zeros(Float32, command_count())
    start!(plant.pipewire)
    frame_node_id = PipeWireAO.node_id(plant.pipewire.frame_stream)
    command_node_id = PipeWireAO.node_id(plant.pipewire.command_stream)
    return (; plant, oracle, oracle_sequence, direct_state, frame_node_id, command_node_id)
end

function require_stable_provider_nodes(phase, implementation, sequence)
    frame_id = PipeWireAO.node_id(phase.plant.pipewire.frame_stream)
    command_id = PipeWireAO.node_id(phase.plant.pipewire.command_stream)
    frame_id == phase.frame_node_id || error(
        "$implementation WFS node changed identity at sequence $sequence: " *
        "$(phase.frame_node_id) → $frame_id",
    )
    command_id == phase.command_node_id || error(
        "$implementation HSDM277 command node changed identity at sequence $sequence: " *
        "$(phase.command_node_id) → $command_id",
    )
    return nothing
end

function require_plant_oracle_frame!(phase, sequence)
    plant_graph = phase.plant.graph
    oracle_graph = phase.oracle.graph
    require_close(
        "shwfs_frame",
        sequence,
        hil_frame_buffer(phase.plant.boundary),
        hil_frame_buffer(phase.oracle.boundary);
        rtol=1.0f-6,
        atol=1.0f-7,
    )
    for field in (:atmosphere_opd, :pdm_surface_opd, :pupil_opd)
        require_close(
            String(field),
            sequence,
            graph_output(plant_graph, Val(field)),
            graph_output(oracle_graph, Val(field));
            rtol=1.0f-6,
            atol=1.0f-15,
        )
    end
    return nothing
end

function source_end_snapshot(phase)
    graph = phase.plant.graph
    return (
        plant_sequence=graph_step_sequence(graph),
        oracle_sequence=graph_step_sequence(phase.oracle.graph),
        frame=copy(hil_frame_buffer(phase.plant.boundary)),
        command=copy(hil_command_buffer(phase.plant.boundary)),
        atmosphere=copy(graph_output(graph, Val(:atmosphere_opd))),
        pdm=copy(graph_output(graph, Val(:pdm_surface_opd))),
        pupil=copy(graph_output(graph, Val(:pupil_opd))),
    )
end

function require_source_end_unchanged(phase, snapshot, implementation)
    require_stable_provider_nodes(phase, implementation, UInt64(10))
    current = source_end_snapshot(phase)
    isequal(current, snapshot) || error(
        "$implementation plant or command state changed after finite source completion",
    )
    PipeWireAO.stream_state(phase.plant.pipewire.frame_stream)
    PipeWireAO.stream_state(phase.plant.pipewire.command_stream)
    return nothing
end

function exchange_range!(
    phase,
    sequences,
    reference_slopes,
    control_matrix,
    native_commands,
    implementation,
    gain=CONTROLLER_GAIN,
    reset_state=false,
    alternate_control_matrix=nothing,
    parameter_adopted=Ref(false),
    compare_implementations=true;
    pole=CONTROLLER_POLE,
)
    reset_state && fill!(phase.direct_state, 0.0f0)
    # The parameter may become active at any frame boundary in this window.
    # Keep an independent reference state for each monotone adoption history.
    candidate_states = isnothing(alternate_control_matrix) ? nothing :
                       [(copy(phase.direct_state), false)]
    for expected_sequence in sequences
        require_stable_provider_nodes(phase, implementation, expected_sequence)
        println("REVOLT_HIL_FRAME_BEGIN implementation=$implementation sequence=$expected_sequence")
        flush(stdout)
        completed_sequence = exchange_frame!(phase.plant.pipewire)
        require_stable_provider_nodes(phase, implementation, expected_sequence)
        println("REVOLT_HIL_FRAME_EXCHANGED implementation=$implementation sequence=$expected_sequence")
        flush(stdout)
        completed_sequence == expected_sequence || error(
            "$implementation expected sequence $expected_sequence, received $completed_sequence",
        )
        phase.oracle_sequence[] == expected_sequence || error(
            "$implementation oracle expected sequence $(phase.oracle_sequence[]), received $expected_sequence",
        )

        plant_graph = phase.plant.graph
        require_plant_oracle_frame!(phase, expected_sequence)

        slopes = controller_slopes(hil_frame_buffer(phase.plant.boundary))
        transported_command = hil_command_buffer(phase.plant.boundary)
        residual_command = control_matrix * (slopes - reference_slopes)
        if isnothing(alternate_control_matrix)
            updated_state = @. pole * phase.direct_state + gain * residual_command
            copyto!(phase.direct_state, updated_state)
        else
            alternate_residual = alternate_control_matrix * (slopes - reference_slopes)
            next_states = Tuple{Vector{Float32},Bool}[]
            for (state, adopted) in candidate_states
                updated_state = @. pole * state + gain * residual_command
                if arrays_close(
                    transported_command,
                    updated_state;
                    rtol=COMMAND_RTOL,
                    atol=COMMAND_ATOL,
                )
                    push!(next_states, (updated_state, true))
                end
                if !adopted
                    alternate_state = @. pole * state + gain * alternate_residual
                    if arrays_close(
                        transported_command,
                        alternate_state;
                        rtol=COMMAND_RTOL,
                        atol=COMMAND_ATOL,
                    )
                        push!(next_states, (alternate_state, false))
                    end
                end
            end
            isempty(next_states) && error(
                "$implementation command at sequence $expected_sequence matches no monotone reconstructor-adoption history",
            )
            candidate_states = next_states
            parameter_adopted[] = all(last, candidate_states)
        end
        if isnothing(alternate_control_matrix)
            require_close(
                "hsdm277_command",
                expected_sequence,
                transported_command,
                phase.direct_state;
                rtol=COMMAND_RTOL,
                atol=COMMAND_ATOL,
            )
        end

        if implementation === :native
            push!(native_commands, copy(transported_command))
        elseif compare_implementations
            require_close(
                "native_julia_command_equivalence",
                expected_sequence,
                transported_command,
                native_commands[Int(expected_sequence)];
                rtol=COMMAND_RTOL,
                atol=COMMAND_ATOL,
            )
        end

        if expected_sequence == UInt64(1)
            all(iszero, graph_output(plant_graph, Val(:pdm_surface_opd))) || error(
                "$implementation command 1 affected frame 1",
            )
            norm(transported_command) > 0.0f0 || error(
                "$implementation command 1 is zero and cannot prove causality",
            )
        elseif expected_sequence == UInt64(2)
            norm(graph_output(plant_graph, Val(:pdm_surface_opd))) > 0.0f0 || error(
                "$implementation command 1 did not affect frame 2",
            )
            println(
                "REVOLT_HIL_CAUSALITY implementation=$implementation command_sequence=1 frame_sequence=2",
            )
            flush(stdout)
        end

        copyto!(
            hil_command_buffer(phase.oracle.boundary),
            transported_command,
        )
        adopt_hil_command!(phase.oracle.boundary, phase.oracle_sequence[])
        expected_sequence < UInt64(10) &&
            (phase.oracle_sequence[] = step_hil_frame!(phase.oracle.boundary))
    end
    if !isnothing(alternate_control_matrix)
        # This fixture needs to identify the adoption boundary to carry one
        # independent controller state into the following frames.
        length(candidate_states) == 1 || error(
            "$implementation reconstructor adoption remains ambiguous across $(length(candidate_states)) reference histories",
        )
        copyto!(phase.direct_state, only(candidate_states)[1])
    end
end

function exchange_latency_range!(
    phase,
    request,
    reference_slopes,
    control_matrix,
    implementation,
)
    total = request.warmup + request.samples
    # The established ten-frame equivalence fixture intentionally leaves the
    # oracle at frame ten after adopting command ten. Advance it only for
    # the optional collection phase so the normal fixture has identical state
    # transitions.
    phase.oracle_sequence[] = step_hil_frame!(phase.oracle.boundary)
    first_sequence = phase.oracle_sequence[]
    observations = Vector{NamedTuple{
        (:phase, :observation, :sequence, :source, :received, :latency),
        Tuple{String,Int,UInt64,Int64,Int64,UInt64},
    }}(undef, total)

    for observation in 1:total
        expected_sequence = first_sequence + UInt64(observation - 1)
        completed_sequence = exchange_frame!(phase.plant.pipewire)
        completed_sequence == expected_sequence || error(
            "$implementation latency expected sequence $expected_sequence, received $completed_sequence",
        )
        timing = frame_command_timing(phase.plant.pipewire)
        isnothing(timing) && error(
            "$implementation latency sequence $expected_sequence has no completed timing observation",
        )
        timing.sequence == expected_sequence || error(
            "$implementation latency timing sequence $(timing.sequence) does not match $expected_sequence",
        )
        timing.command_received_nanoseconds >= timing.source_published_nanoseconds || error(
            "$implementation latency command receipt precedes source publication for sequence $expected_sequence",
        )

        # Keep the established numerical oracle active through the timed
        # collection. Its work is deliberately after command receipt, outside
        # the Header-PTS-to-receipt timing boundary, but makes each recorded
        # command a checked controller result rather than merely a callback.
        slopes = controller_slopes(hil_frame_buffer(phase.plant.boundary))
        residual_command = control_matrix * (slopes - reference_slopes)
        expected_command =
            @. FINAL_CONTROLLER_POLE * phase.direct_state + FINAL_CONTROLLER_GAIN * residual_command
        require_close(
            "latency_hsdm277_command",
            expected_sequence,
            hil_command_buffer(phase.plant.boundary),
            expected_command;
            rtol=COMMAND_RTOL,
            atol=COMMAND_ATOL,
        )
        copyto!(phase.direct_state, expected_command)
        copyto!(hil_command_buffer(phase.oracle.boundary), expected_command)
        adopt_hil_command!(phase.oracle.boundary, phase.oracle_sequence[])
        phase.oracle_sequence[] = step_hil_frame!(phase.oracle.boundary)

        phase_name = observation <= request.warmup ? "warmup" : "measurement"
        observations[observation] = (
            phase_name,
            observation,
            expected_sequence,
            timing.source_published_nanoseconds,
            timing.command_received_nanoseconds,
            timing.end_to_end_latency_nanoseconds,
        )
    end

    open(request.output, "a") do io
        for observation in observations
            println(
                io,
                implementation,
                ',',
                observation.phase,
                ',',
                observation.observation,
                ',',
                observation.sequence,
                ',',
                observation.source,
                ',',
                observation.received,
                ',',
                observation.latency,
            )
        end
    end
    return nothing
end

function main()
    latency = latency_request()
    !isnothing(latency) && initialize_latency_csv!(latency)
    reference_slopes, control_matrix, retained_rank = calibrate_controller()
    open(ENV["PIPEWIREAO_RTC_PARAMETER_REVOLT"], "w") do io
        write(io, parameter_values(control_matrix))
    end
    write(
        native_graph_path,
        graph_configuration(
            ENV["PIPEWIREAO_RTC_FGN_BUNDLE"],
            reference_slopes,
            control_matrix,
        ),
    )
    write(
        julia_graph_path,
        graph_configuration(nothing, reference_slopes, control_matrix),
    )
    println("REVOLT_HIL_CALIBRATED retained_rank=$retained_rank")
    flush(stdout)

    native_commands = Vector{Vector{Float32}}()
    phase = prepare_phase(control_matrix)
    println("REVOLT_HIL_NATIVE_READY")
    flush(stdout)
    native_first_done = false
    native_second_first_done = false
    native_second_done = false
    native_third_done = false
    native_end_done = false
    native_ready_checked = false
    native_snapshot = nothing
    native_latency_done = isnothing(latency)

    try
        while !isfile(stop_file) && !isfile(switch_to_julia)
            if !native_first_done && isfile(native_phase_1)
                exchange_range!(
                    phase,
                    UInt64(1):UInt64(4),
                    reference_slopes,
                    control_matrix,
                    native_commands,
                    :native,
                )
                println("REVOLT_HIL_NATIVE_PHASE_1_DONE sequence=4")
                flush(stdout)
                native_first_done = true
            elseif native_first_done && !native_second_first_done && isfile(native_phase_2)
                exchange_range!(
                    phase,
                    UInt64(5):UInt64(5),
                    reference_slopes,
                    control_matrix,
                    native_commands,
                    :native,
                    UPDATED_CONTROLLER_GAIN,
                    true;
                    pole=UPDATED_CONTROLLER_POLE,
                )
                println("REVOLT_HIL_NATIVE_PHASE_2_FIRST_DONE sequence=5")
                flush(stdout)
                native_second_first_done = true
            elseif native_second_first_done && !native_second_done &&
                   isfile(native_phase_2_continue)
                parameter_adopted = Ref(false)
                exchange_range!(
                    phase,
                    UInt64(6):UInt64(8),
                    reference_slopes,
                    UPDATED_RECONSTRUCTOR_SCALE .* control_matrix,
                    native_commands,
                    :native,
                    UPDATED_CONTROLLER_GAIN,
                    false,
                    control_matrix,
                    parameter_adopted,
                    false;
                    pole=UPDATED_CONTROLLER_POLE,
                )
                parameter_adopted[] || error(
                    "native reconstructor parameter was not adopted by sequence 8",
                )
                println("REVOLT_HIL_NATIVE_PARAMETER_DONE sequence=8")
                flush(stdout)
                native_second_done = true
            elseif native_second_done && !native_third_done && isfile(native_phase_3)
                exchange_range!(
                    phase,
                    UInt64(9):UInt64(10),
                    reference_slopes,
                    UPDATED_RECONSTRUCTOR_SCALE .* control_matrix,
                    native_commands,
                    :native,
                    FINAL_CONTROLLER_GAIN,
                    false,
                    nothing,
                    Ref(false),
                    false;
                    pole=FINAL_CONTROLLER_POLE,
                )
                println("REVOLT_HIL_NATIVE_DONE sequence=10")
                flush(stdout)
                native_third_done = true
                if !isnothing(latency)
                    println(
                        "REVOLT_HIL_NATIVE_LATENCY_READY warmup=$(latency.warmup) samples=$(latency.samples)",
                    )
                    flush(stdout)
                end
            elseif native_third_done && !native_latency_done && isfile(native_latency_phase)
                exchange_latency_range!(
                    phase,
                    latency,
                    reference_slopes,
                    UPDATED_RECONSTRUCTOR_SCALE .* control_matrix,
                    :native,
                )
                println("REVOLT_HIL_NATIVE_LATENCY_DONE samples=$(latency.samples)")
                flush(stdout)
                native_latency_done = true
            elseif native_third_done && native_latency_done && !native_end_done &&
                   isfile(native_source_end)
                isnothing(latency) || error("finite source-end check requires no latency extension")
                length(native_commands) == 10 || error("native finite source ended with $(length(native_commands)) commands")
                graph_step_sequence(phase.plant.graph) == UInt64(10) || error("native plant advanced past final frame")
                graph_step_sequence(phase.oracle.graph) == UInt64(10) || error("native oracle advanced past final frame")
                require_close(
                    "native_final_controller_state", UInt64(10),
                    hil_command_buffer(phase.plant.boundary), phase.direct_state;
                    rtol=COMMAND_RTOL, atol=COMMAND_ATOL,
                )
                println("REVOLT_HIL_NATIVE_SOURCE_END sequence=10 commands=10")
                flush(stdout)
                native_snapshot = source_end_snapshot(phase)
                native_end_done = true
            elseif native_end_done && !native_ready_checked && isfile(native_after_ready)
                require_source_end_unchanged(phase, native_snapshot, :native)
                println("REVOLT_HIL_NATIVE_READY_END_CHECK sequence=10")
                flush(stdout)
                native_ready_checked = true
            end
            sleep(0.01)
        end

        isfile(stop_file) && exit()
        native_third_done && native_latency_done || error(
            "cannot switch to Julia before the native REVOLT sequence completes",
        )
        close(phase.plant.pipewire)
        phase = prepare_phase(control_matrix)
        println("REVOLT_HIL_JULIA_READY")
        flush(stdout)
        julia_first_done = false
        julia_second_first_done = false
        julia_second_done = false
        julia_third_done = false
        julia_end_done = false
        julia_ready_checked = false
        julia_snapshot = nothing
        julia_latency_done = isnothing(latency)

        while !isfile(stop_file)
            if !julia_first_done && isfile(julia_phase_1)
                exchange_range!(
                    phase,
                    UInt64(1):UInt64(4),
                    reference_slopes,
                    control_matrix,
                    native_commands,
                    :julia,
                )
                println("REVOLT_HIL_JULIA_PHASE_1_DONE sequence=4")
                flush(stdout)
                julia_first_done = true
            elseif julia_first_done && !julia_second_first_done && isfile(julia_phase_2)
                exchange_range!(
                    phase,
                    UInt64(5):UInt64(5),
                    reference_slopes,
                    control_matrix,
                    native_commands,
                    :julia,
                    UPDATED_CONTROLLER_GAIN,
                    true;
                    pole=UPDATED_CONTROLLER_POLE,
                )
                println("REVOLT_HIL_JULIA_PHASE_2_FIRST_DONE sequence=5")
                flush(stdout)
                julia_second_first_done = true
            elseif julia_second_first_done && !julia_second_done &&
                   isfile(julia_phase_2_continue)
                parameter_adopted = Ref(false)
                exchange_range!(
                    phase,
                    UInt64(6):UInt64(8),
                    reference_slopes,
                    UPDATED_RECONSTRUCTOR_SCALE .* control_matrix,
                    native_commands,
                    :julia,
                    UPDATED_CONTROLLER_GAIN,
                    false,
                    control_matrix,
                    parameter_adopted,
                    false;
                    pole=UPDATED_CONTROLLER_POLE,
                )
                parameter_adopted[] || error(
                    "Julia reconstructor parameter was not adopted by sequence 8",
                )
                println("REVOLT_HIL_JULIA_PARAMETER_DONE sequence=8")
                flush(stdout)
                julia_second_done = true
            elseif julia_second_done && !julia_third_done && isfile(julia_phase_3)
                exchange_range!(
                    phase,
                    UInt64(9):UInt64(10),
                    reference_slopes,
                    UPDATED_RECONSTRUCTOR_SCALE .* control_matrix,
                    native_commands,
                    :julia,
                    FINAL_CONTROLLER_GAIN,
                    false,
                    nothing,
                    Ref(false),
                    false;
                    pole=FINAL_CONTROLLER_POLE,
                )
                println("REVOLT_HIL_JULIA_DONE sequence=10")
                flush(stdout)
                julia_third_done = true
                if !isnothing(latency)
                    println(
                        "REVOLT_HIL_JULIA_LATENCY_READY warmup=$(latency.warmup) samples=$(latency.samples)",
                    )
                    flush(stdout)
                end
            elseif julia_third_done && !julia_latency_done && isfile(julia_latency_phase)
                exchange_latency_range!(
                    phase,
                    latency,
                    reference_slopes,
                    UPDATED_RECONSTRUCTOR_SCALE .* control_matrix,
                    :julia,
                )
                println("REVOLT_HIL_JULIA_LATENCY_DONE samples=$(latency.samples)")
                flush(stdout)
                julia_latency_done = true
            elseif julia_third_done && julia_latency_done && !julia_end_done &&
                   isfile(julia_source_end)
                isnothing(latency) || error("finite source-end check requires no latency extension")
                graph_step_sequence(phase.plant.graph) == UInt64(10) || error("Julia plant advanced past final frame")
                graph_step_sequence(phase.oracle.graph) == UInt64(10) || error("Julia oracle advanced past final frame")
                require_close(
                    "julia_final_controller_state", UInt64(10),
                    hil_command_buffer(phase.plant.boundary), phase.direct_state;
                    rtol=COMMAND_RTOL, atol=COMMAND_ATOL,
                )
                println("REVOLT_HIL_JULIA_SOURCE_END sequence=10 commands=10")
                flush(stdout)
                julia_snapshot = source_end_snapshot(phase)
                julia_end_done = true
            elseif julia_end_done && !julia_ready_checked && isfile(julia_after_ready)
                require_source_end_unchanged(phase, julia_snapshot, :julia)
                println("REVOLT_HIL_JULIA_READY_END_CHECK sequence=10")
                flush(stdout)
                julia_ready_checked = true
            end
            sleep(0.01)
        end
    finally
        try
            stop!(phase.plant.pipewire)
        catch
        end
        close(phase.plant.pipewire)
    end
end

main()
