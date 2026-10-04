"""Cold reduction of a sealed native capture through the existing public AOC client."""
module HeartCalibrationMethod

using JSON3, SHA
include("calibration_client.jl")
using .CalibrationClient

const INPUTS = ("recipe.json", "method.json", "prepared-specification.json", "canonical-order.json",
    "canonical-plan.json", "interaction-plan.json", "base-identity.json")
digest(path) = bytes2hex(open(sha256, path))
function document(path; maximum=16 * 1024 * 1024)
    !islink(path) && filesize(path) <= maximum || throw(ArgumentError("method input is linked or exceeds its bound"))
    return JSON3.read(read(path, String))
end

function prepared_method(directory, expected_identity)
    digest(joinpath(directory, "identity.json")) == expected_identity || throw(ArgumentError("native method identity changed"))
    identity = document(joinpath(directory, "identity.json"))
    for name in INPUTS
        digest(joinpath(directory, name)) == identity.files[name] || throw(ArgumentError("native frozen input changed: $name"))
    end
    package = dirname(directory)
    for (name, hash) in pairs(identity.aoc_package_files)
        digest(joinpath(package, String(name))) == hash || throw(ArgumentError("public AOC changed from frozen method"))
    end
    recipe = document(joinpath(directory, "recipe.json"))
    recipe.seeds.interaction == identity.interaction_seed || throw(ArgumentError("frozen detector seed differs"))
    method = document(joinpath(directory, "method.json"))
    canonical = prepare_plan(document(joinpath(directory, "prepared-specification.json")))
    JSON3.write(canonical.plan) * "\n" == read(joinpath(directory, "canonical-plan.json"), String) ||
        throw(ArgumentError("public AOC canonical plan differs from frozen input"))
    count = size(canonical.figures, 1)
    permutation = method.order == "forward" ? collect(1:count) : method.order == "reverse" ? collect(count:-1:1) :
        throw(ArgumentError("unknown frozen method ordering"))
    collect(document(joinpath(directory, "canonical-order.json")).chronology_to_canonical) == permutation ||
        throw(ArgumentError("frozen chronological permutation differs"))
    chronological = merge(canonical, (; figures=canonical.figures[permutation, :],
        plan=merge(canonical.plan, (; probes=canonical.plan.probes[permutation]))))
    JSON3.write(chronological.plan) * "\n" == read(joinpath(directory, "interaction-plan.json"), String) ||
        throw(ArgumentError("public AOC chronological plan differs from frozen input"))
    return (; canonical, chronological, permutation, identity, method)
end

function reduce_method(directory, expected_identity, result_path, output, deployment_sha256, completion_sha256)
    !ispath(output) && !islink(output) && isdir(dirname(output)) || throw(ArgumentError("candidate output must be fresh"))
    ENDIAN_BOM == 0x04030201 || throw(ArgumentError("candidate writer requires a little-endian host"))
    selected = prepared_method(directory, expected_identity)
    document(result_path; maximum=512 * 1024 * 1024)
    values = validate_result(read(result_path, String), selected.chronological)
    responses = values[invperm(selected.permutation), :]
    matrix = estimate_interaction_matrix(selected.canonical, responses)
    mkdir(output; mode=0o700)
    path = joinpath(output, "candidate-response.f32le")
    open(path, "w") do io
        write(io, reinterpret(UInt8, vec(permutedims(matrix))))
    end
    record = (; version=1, status="complete-unaccepted-candidate", engine="heart", profile="copper",
        shape=size(matrix), layout="ROW_MAJOR", element_type="F32_LE", path=basename(path), sha256=digest(path),
        command_units="micrometre OPD", measurement_units="native normalized quadrant-major pixel",
        coordinate_contract="columns follow the sealed public AOC probe basis; native 253-coordinate projection is separate",
        method=selected.method, chronology_to_canonical=selected.permutation,
        frozen_identity_sha256=expected_identity, frozen_inputs=selected.identity.files,
        aoc_package_files=selected.identity.aoc_package_files, deployment_sha256,
        native_completion_sha256=completion_sha256, cli_result_sha256=digest(result_path),
        acceptance="none; no candidate selection, native matrix installation or correction acceptance")
    open(joinpath(output, "candidate-response.json"), "w") do io
        JSON3.write(io, record); write(io, '\n')
    end
    return record
end

function main(arguments=ARGS)
    length(arguments) == 6 || throw(ArgumentError("usage: heart_calibration_method.jl METHOD IDENTITY_SHA RESULT OUTPUT DEPLOYMENT_SHA COMPLETION_SHA"))
    reduce_method(arguments...)
    return 0
end

end
abspath(PROGRAM_FILE) == (@__FILE__) && HeartCalibrationMethod.main()
