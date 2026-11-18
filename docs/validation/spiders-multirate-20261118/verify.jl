using PipeWireAORTC

const READ_JSON = PipeWireAORTC.Common.read_json
const LAST_TICK = 2550

function read_csv(path)
    lines = readlines(path)
    names = Tuple(Symbol.(split(first(lines), ',')))
    return [NamedTuple{names}(Tuple(split(line, ','))) for line in Iterators.drop(lines, 1)]
end

function verify(directory, fault)
    metrics = READ_JSON(joinpath(directory, "measurement.json"))
    transport = READ_JSON(joinpath(directory, "transport.json"))
    optical = read_csv(joinpath(directory, "optical.csv"))
    native = read_csv(joinpath(directory, "native.csv"))
    commands = read_csv(joinpath(directory, "commands.csv"))
    applied = read_csv(joinpath(directory, "applied-command.csv"))
    published = read_csv(joinpath(directory, "published-camera.csv"))

    @assert transport["clean_stop"] === true
    @assert length(optical) == 2LAST_TICK
    @assert count(row -> row.camera == "scc" && row.chopping == "unfringed" &&
        isfinite(parse(Float64, row.contrast)), optical) == LAST_TICK ÷ 2
    @assert all(row -> parse(Int, row.model_pts_ns) == (parse(Int, row.tick) - 1) * 10_000_000, optical)
    @assert all(row -> row.camera == "llowfs" || mod1(parse(Int, row.tick), 3) == 1, published)
    published_ids = Set((row.domain, row.generation, row.sequence, row.pts_ns) for row in published)
    optical_ids = Set((row.domain, row.generation, row.published_sequence, row.model_pts_ns)
        for row in optical if row.published == "true")
    @assert published_ids == optical_ids && length(published_ids) == length(published)
    lres = filter(row -> row.stream == "llowfs-modal-residual", native)
    @assert length(lres) == LAST_TICK
    @assert Set((row.domain, row.generation, row.sequence, row.pts_ns) for row in lres) ==
        Set((row.domain, row.generation, row.sequence, row.pts_ns) for row in published if row.camera == "llowfs")
    for key in ("unpaired_feedback", "missing_command_feedback", "out_of_bounds_commands", "inconsistent_clamps")
        @assert metrics[key] == 0 (key, metrics[key])
    end
    prime_ticks = fault ? (1, 1201) : (1,)
    paired_scc = filter(row -> row.camera == "scc" && parse(Int, row.tick) ∉ prime_ticks, published)
    pair_status = filter(row -> row.stream == "pair-status", native)
    @assert length(pair_status) == length(paired_scc)
    @assert all(row -> parse(Float64, row.first_value) == 1, pair_status)
    @assert Set((row.domain, row.generation, row.sequence, row.pts_ns) for row in pair_status) ==
        Set((row.domain, row.generation, row.sequence, row.pts_ns) for row in paired_scc)
    @assert Set((row.tick, row.camera_sequence) for row in applied if row.camera == "scc") ==
        Set((row.tick, row.sequence) for row in paired_scc)
    @assert length(commands) == length(applied) == metrics["native_commands"] == transport["commands_consumed"]
    @assert length(commands) == LAST_TICK + (fault ? 798 : 849)
    for (i, (command, application)) in enumerate(zip(commands, applied))
        @assert (command.tick, command.phase, command.domain, command.generation, command.sequence) ==
            (application.tick, application.phase, application.command_domain, application.command_generation, application.command_sequence)
        @assert command.bounded == command.clamp_consistent == "true"
        if i > 1
            @assert parse(Int, command.sequence) == parse(Int, commands[i - 1].sequence) + 1
            @assert isfinite(parse(Float64, command.step_inf_native))
            @assert isfinite(parse(Float64, command.step_rms_native))
        end
    end
    phases = metrics["phases"]
    @assert all(phase -> phase["llowfs_exact_residual_identity_matches"] == phase["llowfs"]["submitted"], values(phases))
    clipped = filter(row -> parse(Int, row.clipped_actuators) > 0, commands)
    recovered = true
    if fault
        @assert phases["dropout"]["scc"]["submitted"] == 0
        @assert parse(Int, first(filter(row -> parse(Int, row.tick) >= 1201, paired_scc)).tick) == 1204
        @assert any(row -> row.camera == "scc" && row.tick == "1201", published)
        @assert phases["saturate"]["clipped_commands"] > 0
        @assert all(row -> abs(parse(Float64, row.witness_demand_native)) == 0.5 &&
            abs(parse(Float64, row.witness_demand_native) + parse(Float64, row.witness_feedback_native)) > 0.5, clipped)
        recovered = metrics["recovery"]["observed"] && metrics["recovery"]["sustained_unclipped_commands"] > 1
        release = filter(row -> row.phase == "release", commands)
        println("Release: $(count(row -> parse(Int, row.clipped_actuators) > 0, release))/$(length(release)) clipped commands, last release tick $(last(release).tick)")
    else
        @assert phases["dropout"]["scc"]["submitted"] == 50
        @assert any(row -> row.tick == "1201", paired_scc)
        @assert isempty(clipped)
    end
    println("Verified $directory: $(length(lres)) LLOWFS residuals, $(length(commands)) consumed native commands, $(length(clipped)) clipped commands")
    return (; recovered)
end

if abspath(PROGRAM_FILE) == @__FILE__
    @assert length(ARGS) == 2 "usage: verify.jl EXPERIMENT NO_FAULT_REFERENCE"
    trial = verify(ARGS[1], true)
    verify(ARGS[2], false)
    @assert trial.recovered "The natural release did not establish sustained unclipped native demand"
end
