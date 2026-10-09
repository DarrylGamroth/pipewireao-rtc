using Test
using JSON3
using AdaptiveOpticsCalibration

include("calibration_client.jl")
using .CalibrationClient

function complete_result(prepared, observations)
    responses = map(enumerate(eachrow(observations))) do (index, row)
        (; values=collect(row), valid=true,
            exposures=[(; domain=1, generation=1, sequence=index, start_model_ns=index * 100,
                duration_ns=100)])
    end
    return (; version=1, run=prepared.plan.run, phase="complete",
        restoration_confirmed=true, resume_permitted=true, failure=nothing,
        recovery_failure=nothing, responses)
end

function basis_specification(; reference=zeros(Float32, 3), amplitudes=fill(0.25f0, 3), basis=nothing)
    specification = (; run=17, reference, amplitudes, measurements=2, frames_per_probe=1,
        settling=(; kind="immediate"), timeouts_ns=(; ownership=1, adoption=1,
            settling=1, collection=1, restoration=1))
    return basis === nothing ? specification : merge(specification, (; probe_basis=basis))
end

function linear_responses(prepared, physical_matrix)
    # Independent declared linear fixture; complete exposure association is
    # supplied by complete_result rather than bypassed by artifact writing.
    relative = prepared.figures .- permutedims(prepared.reference)
    return relative * permutedims(physical_matrix)
end

function artifact_metadata(n)
    return (; command_units="micrometre OPD", actuator_order=collect(1:n),
        measurement_units="detector pixel coordinate", measurement_order=["x", "y"],
        detector_settings=(; fixture=true), settings_identity="fixture-settings",
        numerical_policy_identity="fixture-policy", endpoint_identity="fixture-endpoint",
        model_identity="fixture-model", source_paths=String[], artifact_hashes=(;))
end

@testset "default calibration artifact compatibility" begin
    prepared = prepare_plan(basis_specification())
    @test propertynames(prepared) == (:plan, :figures, :reference, :amplitudes, :measurements, :frames_per_probe)
    @test propertynames(prepared.plan) == (:version, :run, :reference, :probes, :measurements, :frames_per_probe, :settling, :timeouts_ns)
    observed = linear_responses(prepared, Float32[1 2 3; 4 5 6])
    mktempdir() do root
        record = write_artifact(joinpath(root, "default.json"), prepared,
            complete_result(prepared, observed), artifact_metadata(3))
        @test record.probe_basis == "zonal_push_pull"
        @test !hasproperty(record, :coordinate_kind)
        @test !hasproperty(record, :command_basis)
        @test propertynames(record) == (:version, :run, :command_units, :actuator_order,
            :measurement_units, :measurement_order, :probe_basis, :amplitudes, :reference,
            :detector_settings, :settings_identity, :numerical_policy_identity,
            :endpoint_identity, :model_identity, :source_paths, :artifact_hashes,
            :cli_result, :responses, :interaction_matrix)
    end
end

@testset "explicit physical zonal and Hadamard probes" begin
    physical = Float32[2 -1 0.5; -4 3 1]
    for kind in ("zonal", "hadamard")
        prepared = prepare_plan(basis_specification(basis=(; kind)))
        observed = linear_responses(prepared, physical)
        @test estimate_interaction_matrix(prepared, observed) ≈ physical
        @test size(prepared.figures, 2) == 3
        @test prepared.figures[2:2:end, :] == -prepared.figures[1:2:end, :]
        @test CalibrationClient._coordinate_kind(prepared.probe_basis) == "physical_actuator"
        @test prepared.probe_basis.positive_commands == prepared.figures[1:2:end, :]
        if kind == "hadamard"
            @test size(prepared.figures, 1) == 8 # next Sylvester order4 >3
            @test vec(sum(prepared.probe_basis.positive_commands; dims=1)) == zeros(Float32, 3)
        end
        mktempdir() do root
            path = joinpath(root, "physical.json")
            record = write_artifact(path, prepared, complete_result(prepared, observed), artifact_metadata(3))
            @test record.coordinate_kind == "physical_actuator"
            @test record.command_basis == prepared.probe_basis.positive_commands
            @test record.probe_basis == (kind == "zonal" ? "zonal_push_pull" : "hadamard_push_pull")
        end
    end
end

@testset "modal directional responses and actual Float32 commands" begin
    # Repeated dependent directions are valid directional calibration inputs;
    # they cannot recover a three-coordinate physical matrix.
    positive = Float64[0.25 0.0 -0.25; 0.5 0.0 -0.5]
    mode_amplitudes = Float32[0.25, 0.5]
    basis = (; kind="modal", positive_commands=positive, mode_amplitudes)
    prepared = prepare_plan(basis_specification(basis=basis))
    physical = Float32[2 -1 0.5; -4 3 1]
    observed = linear_responses(prepared, physical)
    expected = physical * permutedims(Float32[1 0 -1; 1 0 -1])
    @test estimate_interaction_matrix(prepared, observed) ≈ expected
    @test size(estimate_interaction_matrix(prepared, observed)) == (2, 2)
    @test CalibrationClient._coordinate_kind(prepared.probe_basis) == "mode_direction"
    @test prepared.probe_basis.positive_commands == Float32.(positive)
    @test eltype(prepared.probe_basis.positive_commands) === Float32
    @test prepare_plan(basis_specification(basis=merge(basis,
        (; positive_commands=@view positive[:, :])))).figures == prepared.figures
    # JSON nested rows use the same row/coordinate convention.
    json_basis = merge(basis, (; positive_commands=[collect(row) for row in eachrow(positive)]))
    parsed = JSON3.read(JSON3.write(basis_specification(basis=json_basis)))
    @test prepare_plan(parsed).figures == prepared.figures
    mktempdir() do root
        path = joinpath(root, "modal.json")
        record = write_artifact(path, prepared,
            complete_result(prepared, observed), artifact_metadata(3))
        @test record.probe_basis == "modal_push_pull"
        @test record.coordinate_kind == "mode_direction"
        @test record.amplitudes == mode_amplitudes
        @test record.command_basis == Float32.(positive)
        @test record.command_basis_shape == (2, 3)
        @test record.command_basis_layout == "column_major"
        @test size(record.interaction_matrix) == (2, 2)
        serialized = JSON3.read(read(path, String))
        @test collect(serialized.command_basis) == vec(Float32.(positive))
        @test Tuple(serialized.command_basis_shape) == (2, 3)
        @test serialized.command_basis_layout == "column_major"
    end
    rounded = merge(basis, (; positive_commands=Float64[1/3 0 -1/3; 0.5 0 -0.5]))
    rounded_prepared = prepare_plan(basis_specification(basis=rounded))
    @test rounded_prepared.probe_basis.positive_commands[1,1] === Float32(1/3)
    @test_throws ArgumentError prepare_plan(basis_specification(reference=Float32[1f20,0,0], basis=basis))
end

@testset "spatial sine/cosine directional calibration" begin
    positions = Float64[0 0; 0.25 0; 0.125 0]
    frequencies = Float64[1 0]
    basis = (; kind="spatial_sine", actuator_positions=positions,
        spatial_frequencies=frequencies, mode_amplitudes=Float32[0.25,0.5],
        normalization="peak", minimum_sampled_peak=1e-5)
    prepared = prepare_plan(basis_specification(basis=basis))
    @test size(prepared.figures) == (4, 3)
    @test prepared.figures[1,1] == 0 && prepared.figures[1,2] == 0.25f0
    @test prepared.figures[3,1] == 0.5f0 && prepared.figures[3,2] == 0
    @test prepared.figures[2,:] == -prepared.figures[1,:]
    @test prepared.figures[4,:] == -prepared.figures[3,:]
    physical = Float32[2 -1 0.5; -4 3 1]
    observed = linear_responses(prepared, physical)
    directions = prepared.probe_basis.positive_commands ./ basis.mode_amplitudes
    @test estimate_interaction_matrix(prepared, observed) ≈ physical * permutedims(directions)
    json_basis = merge(basis, (; actuator_positions=[collect(row) for row in eachrow(positions)],
        spatial_frequencies=[collect(row) for row in eachrow(frequencies)]))
    @test prepare_plan(JSON3.read(JSON3.write(basis_specification(basis=json_basis)))).figures == prepared.figures
    description = prepared.probe_basis.description
    @test description.actuator_positions == positions
    @test description.spatial_frequencies == frequencies
    @test description.normalization == "peak"
    @test description.sampled_peak == [1.0,1.0]
    @test description.planned_basis_shape == (2, 3)
    @test description.planned_basis_layout == "column_major"
    @test eltype(prepared.probe_basis.positive_commands) === Float32
end

@testset "basis contract rejection" begin
    positive = Float32[0.25 0 -0.25]
    modal = (; kind="modal", positive_commands=positive, mode_amplitudes=Float32[0.25])
    spatial = (; kind="spatial_sine", actuator_positions=Float64[0 0;0.25 0;0.125 0],
        spatial_frequencies=Float64[1 0], mode_amplitudes=Float32[0.25,0.5], normalization="none", minimum_sampled_peak=1e-5)
    for kind in ("zonal", "hadamard")
        for amplitudes in (Float32[0,0.25,0.25],Float32[-0.25,0.25,0.25],Float32[NaN,0.25,0.25])
            @test_throws ArgumentError prepare_plan(basis_specification(; amplitudes,basis=(; kind)))
        end
    end
    for basis in (merge(modal,(; mode_amplitudes=Float32[0])), merge(modal,(; mode_amplitudes=Float32[-1])),
            merge(modal,(; mode_amplitudes=Float32[NaN])),merge(modal,(; positive_commands=zeros(Float32,1,3))),
            merge(modal,(; positive_commands=Float32[NaN 0 0])), merge(modal,(; positive_commands=Float64[1e-50 0 0])),
            merge(spatial,(; spatial_frequencies=zeros(1,2))),merge(spatial,(; normalization="rms")),
            merge(spatial,(; minimum_sampled_peak=0.0)),merge(spatial,(; actuator_positions=Float64[NaN 0;0.25 0;0.125 0])),
            merge(spatial,(; spatial_frequencies=Float64[Inf 0])),(; kind="unknown"))
        @test_throws ArgumentError prepare_plan(basis_specification(basis=basis))
    end
    for basis in (merge(modal,(; mode_amplitudes=Float32[0.25,0.5])),
            merge(modal,(; positive_commands=Float32[0.25 0])),
            merge(spatial,(; mode_amplitudes=Float32[0.25])),merge(spatial,(; actuator_positions=zeros(3,3))),
            merge(spatial,(; spatial_frequencies=zeros(1,3))))
        @test_throws DimensionMismatch prepare_plan(basis_specification(basis=basis))
    end
    @test_throws DimensionMismatch prepare_plan(basis_specification(basis=(; kind="modal",positive_commands=[[1,2],[1]],mode_amplitudes=[1,1])))
end

@testset "operational calibration client" begin
    specification = (; run=7, reference=Float32[0.1, -0.2],
        amplitudes=Float32[0.25, 0.5], measurements=3, frames_per_probe=1,
        settling=(; kind="immediate"), timeouts_ns=(; ownership=1, adoption=1,
            settling=1, collection=1, restoration=1))
    prepared = prepare_plan(specification)
    @test prepared.figures == Float32[0.35 -0.2;  -0.15 -0.2; 0.1 0.3; 0.1 -0.7]
    @test prepared.plan.probes == [collect(row) for row in eachrow(prepared.figures)]

    expected = Float32[2 -1; 0.5 3; -4 1.25]
    baseline = Float32[11, -2, 0.75]
    observations = Matrix{Float32}(undef, 4, 3)
    for output in 1:3
        observations[1, output] = baseline[output] + prepared.amplitudes[1] * expected[output, 1]
        observations[2, output] = baseline[output] - prepared.amplitudes[1] * expected[output, 1]
        observations[3, output] = baseline[output] + prepared.amplitudes[2] * expected[output, 2]
        observations[4, output] = baseline[output] - prepared.amplitudes[2] * expected[output, 2]
    end
    result = complete_result(prepared, observations)
    measured = validate_result(result, prepared)
    @test measured == observations
    @test estimate_interaction_matrix(prepared, measured) ≈ expected
    @test_throws ArgumentError estimate_interaction_matrix(prepared, fill(1e100, 4, 3))
    @test_throws ArgumentError estimate_interaction_matrix(prepared, fill(1e-50, 4, 3))
    overflow_responses = Float32[1f38 1f38 1f38; -1f38 -1f38 -1f38;
        0 0 0; 0 0 0]
    @test_throws ArgumentError estimate_interaction_matrix(prepared, overflow_responses)
    @test_throws ArgumentError prepare_plan(merge(specification, (; amplitudes=Float64[1e-50, 0.5])))
    @test_throws ArgumentError prepare_plan(merge(specification, (; amplitudes=Float64[1e100, 0.5])))
    @test_throws ArgumentError prepare_plan(merge(specification, (; reference=Float32[1f20, 0],
        amplitudes=Float32[1, 0.5])))

    duplicate_exposure = (; domain=1, generation=1, sequence=1,
        start_model_ns=100, duration_ns=100)
    duplicate_batch = merge(result.responses[2], (; exposures=[duplicate_exposure]))
    duplicate_result = merge(result, (; responses=vcat(result.responses[1:1], [duplicate_batch], result.responses[3:end])))
    for bad in (
        merge(result, (; phase="aborted")),
        merge(result, (; restoration_confirmed=false)),
        merge(result, (; resume_permitted=false)),
        merge(result, (; failure="ProbeClipped")),
        merge(result, (; responses=result.responses[1:end-1])),
        merge(result, (; responses=vcat([merge(result.responses[1], (; valid=false))], result.responses[2:end]))),
        merge(result, (; responses=vcat([merge(result.responses[1], (; values=Float32[1, 2]))], result.responses[2:end]))),
        merge(result, (; responses=vcat([merge(result.responses[1], (; values=Float32[1, NaN, 3]))], result.responses[2:end]))),
        merge(result, (; responses=vcat([merge(result.responses[1], (; values=[1e-50, 2, 3]))], result.responses[2:end]))),
        merge(result, (; responses=vcat([merge(result.responses[1], (; values=[1e100, 2, 3]))], result.responses[2:end]))),
        duplicate_result,
        merge(result, (; responses=vcat(result.responses[1:1],
            [merge(result.responses[2], (; exposures=[(; domain=1, generation=1, sequence=2,
                start_model_ns=150, duration_ns=100)]))], result.responses[3:end]))),
        merge(result, (; responses=vcat(result.responses[1:1],
            [merge(result.responses[2], (; exposures=[(; domain=1, generation=1, sequence=2,
                start_model_ns=typemax(UInt64), duration_ns=UInt64(1))]))], result.responses[3:end]))),
    )
        @test_throws ArgumentError validate_result(bad, prepared)
    end
    @test_throws DimensionMismatch estimate_interaction_matrix(prepared, observations[1:3, :])
end
