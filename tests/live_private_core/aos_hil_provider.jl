using AdaptiveOpticsSim
using AdaptiveOpticsSim.AlgorithmGraphs
using AdaptiveOpticsSimPipeWireHIL
using LinearAlgebra
using PipeWireAO
using Printf

length(ARGS) == 4 || error(
    "expected CORE_NAME CONTROL_DIRECTORY GRAPH_CONFIGURATION FGN_BUNDLE",
)
core_name, control_directory, graph_configuration, fgn_bundle = ARGS
phase_1_request = joinpath(control_directory, "aos-hil-phase-1")
phase_2_request = joinpath(control_directory, "aos-hil-phase-2")
stop_file = joinpath(control_directory, "stop-aos-hil")

include(joinpath(
    pkgdir(AdaptiveOpticsSim),
    "examples",
    "support",
    "hil_reference_systems.jl",
))
using .HILReferenceSystems

function fgn_slopes(frame)
    origins = subaperture_origins()
    slopes = Vector{Float32}(undef, 2 * length(origins))
    for (subaperture, (row_origin, column_origin)) in enumerate(origins)
        x_moment = 0.0f0
        y_moment = 0.0f0
        flux = 0.0f0
        for row in 0:7, column in 0:7
            # The HIL adapter stages the logical Julia array into row-major
            # transport order before publication. This indexing reproduces
            # the FGN view of that staged frame.
            value = frame[row_origin + row + 1, column_origin + column + 1]
            x_moment += value * Float32(column - 3.5)
            y_moment += value * Float32(row - 3.5)
            flux += value
        end
        isfinite(flux) && flux > 0.0f0 || error(
            "FGN calibration subaperture $subaperture has invalid flux $flux",
        )
        slopes[2 * subaperture - 1] = x_moment / flux
        slopes[2 * subaperture] = y_moment / flux
    end
    return slopes
end

function calibrate_reference!(prepared; poke=2.0f-8)
    graph = prepared.graph
    boundary = prepared.boundary
    sequence = step_hil_frame!(boundary)
    aos_flat_signal = copy(graph_output(graph, Val(:wfs_signal)))
    flat_signal = fgn_slopes(hil_frame_buffer(boundary))
    interaction_matrix = Matrix{Float32}(
        undef,
        length(flat_signal),
        HILReferenceSystems.actuator_count(),
    )
    positive_signal = similar(flat_signal)

    for command_index in axes(interaction_matrix, 2)
        fill!(hil_command_buffer(boundary), 0.0f0)
        hil_command_buffer(boundary)[command_index] = poke
        adopt_hil_command!(boundary, sequence)
        sequence = step_hil_frame!(boundary)
        copyto!(positive_signal, fgn_slopes(hil_frame_buffer(boundary)))

        fill!(hil_command_buffer(boundary), 0.0f0)
        hil_command_buffer(boundary)[command_index] = -poke
        adopt_hil_command!(boundary, sequence)
        sequence = step_hil_frame!(boundary)
        negative_signal = fgn_slopes(hil_frame_buffer(boundary))
        @views @. interaction_matrix[:, command_index] =
            (positive_signal - negative_signal) / (2 * poke)
    end

    fill!(hil_command_buffer(boundary), 0.0f0)
    adopt_hil_command!(boundary, sequence)
    reset_hil_boundary!(boundary)
    return aos_flat_signal, flat_signal, interaction_matrix
end

function spa_float(value::Real)
    isfinite(value) || error("FGN calibration contains a non-finite value")
    return @sprintf("%.9g", Float64(value))
end

function spa_vector(values)
    return "[ " * join((spa_float(value) for value in values), " ") * " ]"
end

function subaperture_origins()
    lenslet_count = 8
    pixels_per_lenslet = 8
    order = HILReferenceSystems.shack_hartmann_lenslet_order()
    return [
        (
            rem(Int(index) - 1, lenslet_count) * pixels_per_lenslet,
            div(Int(index) - 1, lenslet_count) * pixels_per_lenslet,
        ) for index in order
    ]
end

function write_fgn_graph(path, plugin, remote, reference_slopes, reconstructor)
    origins = join(
        ("[ $(origin[1]) $(origin[2]) ]" for origin in subaperture_origins()),
        " ",
    )
    row_major_reconstructor = [
        reconstructor[row, column] for row in axes(reconstructor, 1) for
        column in axes(reconstructor, 2)
    ]
    configuration = """
    {
        remote.name = "$remote"
        node.name = "pipewireao-rtc-aos-controller"
        object.linger = false
        filter.graph = {
            nodes = [
                {
                    type = ndarray
                    name = measure
                    plugin = "$plugin"
                    label = shack-hartmann-image-f32
                    config = {
                        image_rows = 64
                        image_columns = 64
                        subaperture_rows = 8
                        subaperture_columns = 8
                        subaperture_count = 52
                        image_schema = org.adaptiveopticssim.hil-reference.shack-hartmann-frame.f32/1
                        initial_subaperture_origins = [ $origins ]
                        coordinate_scale = 1.0
                        pixel_threshold = 0.0
                        flux_threshold = 0.0
                        reference_slopes = $(spa_vector(reference_slopes))
                        rate = [ 1000 1 ]
                    }
                }
                {
                    type = ndarray
                    name = reconstruct
                    plugin = "$plugin"
                    label = shwfs-reconstructor-f32
                    config = {
                        actuator_count = 25
                        subaperture_count = 52
                        initial_reconstructor = $(spa_vector(row_major_reconstructor))
                        reconstructed_schema = org.pipewireao.rtc.aos-hil.residual-command.f32/1
                        rate = [ 1000 1 ]
                    }
                }
                {
                    type = ndarray
                    name = integrate
                    plugin = "$plugin"
                    label = leaky-integrator-f32
                    config = {
                        extent = 25
                        initial_state = 0.0
                        input_schema = org.pipewireao.rtc.aos-hil.residual-command.f32/1
                        output_schema = org.adaptiveopticssim.hil-reference.dm-command-surface-opd-m.f32/1
                        rate = [ 1000 1 ]
                    }
                    props = { gain = -0.4 pole = 1.0 }
                }
            ]
            links = [
                { output = "measure:slopes" input = "reconstruct:slopes" }
                { output = "reconstruct:reconstructed" input = "integrate:input" }
            ]
            inputs = [ "measure:image" ]
            outputs = [ "integrate:output" ]
        }
    }
    """
    write(path, configuration)
end

prepared_reference = HILReferenceSystems.prepare_hil_reference_system(
    :shack_hartmann,
)
aos_flat_signal, flat_signal, interaction_matrix =
    calibrate_reference!(prepared_reference)
control_matrix = pinv(interaction_matrix; rtol=1.0f-4)
write_fgn_graph(
    graph_configuration,
    fgn_bundle,
    core_name,
    flat_signal,
    control_matrix,
)

disturbance_command = zeros(Float32, HILReferenceSystems.actuator_count())
disturbance_command[8] = 3.0f-8
disturbance_command[12] = -2.0f-8
disturbance_command[14] = 2.0f-8
disturbance_command[18] = -3.0f-8

sequence = step_hil_frame!(prepared_reference.boundary)
copyto!(hil_command_buffer(prepared_reference.boundary), disturbance_command)
adopt_hil_command!(prepared_reference.boundary, sequence)
sequence = step_hil_frame!(prepared_reference.boundary)
disturbance_opd = copy(graph_output(
    prepared_reference.graph,
    Val(:dm_surface_opd),
))
fill!(hil_command_buffer(prepared_reference.boundary), 0.0f0)
adopt_hil_command!(prepared_reference.boundary, sequence)
reset_hil_boundary!(prepared_reference.boundary)
copyto!(prepared_reference.uncompensated_opd, disturbance_opd)
sequence = step_hil_frame!(prepared_reference.boundary)
direct_reconstruction = control_matrix *
    (fgn_slopes(hil_frame_buffer(prepared_reference.boundary)) - flat_signal)
isapprox(
    direct_reconstruction,
    disturbance_command;
    rtol=5.0f-3,
    atol=5.0f-11,
) || error("prepared FGN calibration does not reconstruct the disturbance")
fill!(hil_command_buffer(prepared_reference.boundary), 0.0f0)
adopt_hil_command!(prepared_reference.boundary, sequence)
reset_hil_boundary!(prepared_reference.boundary)

configuration = PipeWireHILConfiguration(
    remote=core_name,
    frame_node_name="pipewireao-aos-hil-wfs",
    command_node_name="pipewireao-aos-hil-command",
    frame_schema="org.adaptiveopticssim.hil-reference.shack-hartmann-frame.f32/1",
    command_schema="org.adaptiveopticssim.hil-reference.dm-command-surface-opd-m.f32/1",
    rate=SPA.Fraction(1_000, 1),
    exposure_duration_ns=1_000_000,
)

pipewire_hil = prepare_pipewire_hil(prepared_reference.boundary, configuration)
causality_reference = HILReferenceSystems.prepare_hil_reference_system(
    :shack_hartmann,
)
causality_sequence = Ref(step_hil_frame!(causality_reference.boundary))
residual_norms = Float32[]
fgn_residual_norms = Float32[]

function exchange_range!(pipewire_hil, sequences)
    for expected_sequence in sequences
        completed_sequence = exchange_frame!(pipewire_hil)
        completed_sequence == expected_sequence || error(
            "expected SCAO sequence $expected_sequence, received $completed_sequence",
        )
        causality_sequence[] == expected_sequence || error(
            "causality oracle expected sequence $(causality_sequence[]), received $expected_sequence",
        )
        dm_surface_opd = graph_output(
            prepared_reference.graph,
            Val(:dm_surface_opd),
        )
        oracle_surface_opd = graph_output(
            causality_reference.graph,
            Val(:dm_surface_opd),
        )
        isapprox(
            dm_surface_opd,
            oracle_surface_opd;
            rtol=1.0f-6,
            atol=1.0f-15,
        ) || error(
            "command/frame causality mismatch at frame $expected_sequence",
        )
        command = hil_command_buffer(prepared_reference.boundary)
        if expected_sequence == UInt64(1)
            all(iszero, dm_surface_opd) || error(
                "command 1 affected frame 1 instead of frame 2",
            )
            norm(command) > 0.0f0 || error(
                "command 1 is zero and cannot prove next-frame causality",
            )
        elseif expected_sequence == UInt64(2)
            norm(dm_surface_opd) > 0.0f0 || error(
                "command 1 did not affect frame 2",
            )
            println("AOS_HIL_CAUSALITY_DONE command_sequence=1 frame_sequence=2")
            flush(stdout)
        end
        copyto!(hil_command_buffer(causality_reference.boundary), command)
        adopt_hil_command!(causality_reference.boundary, causality_sequence[])
        if expected_sequence < UInt64(15)
            causality_sequence[] = step_hil_frame!(causality_reference.boundary)
        end
        residual_signal = graph_output(
            prepared_reference.graph,
            Val(:wfs_signal),
        )
        push!(residual_norms, norm(residual_signal - aos_flat_signal))
        fgn_residual = fgn_slopes(
            hil_frame_buffer(prepared_reference.boundary),
        ) - flat_signal
        push!(fgn_residual_norms, norm(fgn_residual))
    end
end

try
    start!(pipewire_hil)
    println("AOS_HIL_READY")
    flush(stdout)
    phase_1_done = Ref(false)
    phase_2_done = Ref(false)
    while !isfile(stop_file)
        if !phase_1_done[] && isfile(phase_1_request)
            exchange_range!(pipewire_hil, UInt64(1):UInt64(7))
            println("AOS_HIL_PHASE_1_DONE sequence=7")
            flush(stdout)
            phase_1_done[] = true
        elseif phase_1_done[] && !phase_2_done[] && isfile(phase_2_request)
            exchange_range!(pipewire_hil, UInt64(8):UInt64(15))
            all(isfinite, residual_norms) || error(
                "SCAO residual history contains a non-finite value",
            )
            all(isfinite, fgn_residual_norms) || error(
                "FGN residual history contains a non-finite value",
            )
            last(residual_norms) < first(residual_norms) * 1.0f-2 || error(
                "SCAO residual did not converge: $(first(residual_norms)) -> $(last(residual_norms))",
            )
            last(fgn_residual_norms) < first(fgn_residual_norms) * 1.0f-2 || error(
                "FGN residual did not converge: $(first(fgn_residual_norms)) -> $(last(fgn_residual_norms))",
            )
            command = hil_command_buffer(prepared_reference.boundary)
            isapprox(
                command,
                -disturbance_command;
                rtol=5.0f-2,
                atol=5.0f-10,
            ) || error("SCAO command does not cancel the declared disturbance")
            @printf(
                "AOS_HIL_CLOSED_LOOP_DONE sequence=15 residual_ratio=%.9g\n",
                last(residual_norms) / first(residual_norms),
            )
            flush(stdout)
            phase_2_done[] = true
        end
        sleep(0.01)
    end
finally
    close(pipewire_hil)
end
