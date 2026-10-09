using JSON3
include("heart_classic_calibration_evidence.jl")

function main(arguments=ARGS)
    isempty(arguments) && throw(ArgumentError("verification mode is required"))
    mode = first(arguments)
    output = last(arguments)
    !ispath(output) && !islink(output) || throw(ArgumentError("verification output must be fresh"))
    record = if mode == "counts" && length(arguments) == 6
        _, directory, frames, commands, maximum, _ = arguments
        counts = HeartClassicCalibrationEvidence.verify_classic_counts(directory;
            frames=parse(Int, frames), commands=parse(Int, commands), maximum_bytes=parse(UInt64, maximum))
        (; version=1, counts, qualification="native held-controller record counts; live owner supplies frame association")
    elseif mode == "result" && length(arguments) == 4
        _, plan_path, result_path, _ = arguments
        filesize(plan_path) <= 16 * 1024 * 1024 && filesize(result_path) <= 512 * 1024 * 1024 ||
            throw(ArgumentError("public native result input exceeds its bound"))
        plan = JSON3.read(read(plan_path, String))
        prepared = (; plan, figures=permutedims(hcat(plan.probes...)),
            measurements=Int(plan.measurements), frames_per_probe=Int(plan.frames_per_probe))
        plan.measurements == 376 || throw(ArgumentError("Classic verifier requires376 measurements"))
        responses = Base.invokelatest(HeartClassicCalibrationEvidence.CalibrationClient.validate_result, read(result_path, String), prepared)
        (; version=1, response_shape=size(responses), qualification="public CalibrationClient validated actual native response means and identities")
    else
        throw(ArgumentError("usage: heart_classic_calibration_verify.jl counts TELEMETRY FRAMES COMMANDS MAX_BYTES OUTPUT | result PLAN RESULT OUTPUT"))
    end
    open(output, "w") do io
        JSON3.write(io, record)
        write(io, '\n')
    end
    return 0
end

abspath(PROGRAM_FILE) == (@__FILE__) && main()
