"""One-shot interaction acquisition; JSON files are plans and saved evidence only."""
module CalibrationCLI
using JSON3
import ..Common
import ..CalibrationAcquisition
import ..NativeCalibrationActionClient
import ..NativeCalibrationActionCodec
const Acquisition = CalibrationAcquisition
const Native = NativeCalibrationActionClient
const Codec = NativeCalibrationActionCodec

const MAX_EVIDENCE_BYTES = 64 * 1024 * 1024
mutable struct Journal{F}
    file::F
    retained::Int
    records::Vector{Any}
    error::Union{Nothing,String}
end
function Journal(path, probes)
    # Never truncate old evidence or follow an existing symlink.
    flags = Base.Filesystem.JL_O_WRONLY | Base.Filesystem.JL_O_CREAT | Base.Filesystem.JL_O_EXCL
    file = Base.Filesystem.open(path, flags, 0o600)
    try
        header = JSON3.write(Dict("event"=>"header", "version"=>2,
            "probe_count"=>probes, "max_charged_bytes"=>MAX_EVIDENCE_BYTES)) * "\n"
        write(file, header)
        return Journal(file, ncodeunits(header), Any[], nothing)
    catch
        close(file)
        rethrow()
    end
end
_figure_charge(::Codec.Action) = 0
_figure_charge(a::Union{Codec.Adopt,Codec.Restore}) = 64 * length(a.figure)
_result_charge(::Codec.Result) = 0
_result_charge(r::Union{Codec.Adopted,Codec.Restored}) = 64 * length(r.figure)
_result_charge(r::Codec.Responses) = 64 * length(r.values) + 2048 * length(r.exposures)
function record!(journal::Journal, charge, build)
    journal.error === nothing || return nothing
    next = BigInt(journal.retained) + charge
    if next <= MAX_EVIDENCE_BYTES - 256
        journal.retained = Int(next)
        push!(journal.records, build())
    else
        journal.error = "evidence size limit exceeded"
    end
    return nothing
end
function observe!(journal::Journal, action, result, run, serial)
    record!(journal, 8192 + _figure_charge(action) + _result_charge(result)) do
        Dict("event"=>"completion", "run"=>run, "serial"=>serial,
            "action"=>Native._action_document(action), "result"=>Native.document(result))
    end
end
# do-block function goes first.
record!(build, journal::Journal, charge) = record!(journal, charge, build)
function finish!(journal::Journal, result)
    try
        record!(journal, 8192) do
            Dict("event"=>"acquisition", "result"=>Dict(k=>v for (k,v) in result if k != "responses"))
        end
        for record in journal.records
            write(journal.file, JSON3.write(record), '\n')
        end
        if journal.error !== nothing
            write(journal.file, JSON3.write(Dict("event"=>"evidence_error", "reason"=>journal.error)), '\n')
        end
    finally
        close(journal.file)
    end
    journal.error === nothing || throw(ArgumentError(journal.error))
    return nothing
end

function run(argv=ARGS; acquire=Acquisition.acquire)
    args = Common.cli_arguments(argv; required=["remote", "node", "owner-pid", "owner-instance", "plan"],
        allowed=["evidence"])
    binding = Native.Binding(args.remote, args.node, parse(UInt32, args.owner_pid), parse(Int64, args.owner_instance))
    plan = Acquisition.read_plan(args.plan)
    journal = hasproperty(args, :evidence) ? Journal(args.evidence, length(plan.probes)) : nothing
    result = nothing
    try
        acquired = if journal === nothing
            acquire(binding, plan)
        else
            acquire(binding, plan; observe=(a,r,s)->observe!(journal,a,r,plan.run,s))
        end
        result = Acquisition.document(acquired)
        # Emit the report even when evidence finalization later fails.
        println(JSON3.write(result))
        journal === nothing || finish!(journal, result)
        journal = nothing
        return result["phase"] == "complete" ? 0 : 1
    finally
        journal === nothing || isopen(journal.file) && close(journal.file)
    end
end
function main(argv=ARGS; kwargs...)
    try
        return run(argv; kwargs...)
    catch error
        println(stderr, "rtc-calibrate: ", sprint(showerror, error))
        return 2
    end
end
end # module CalibrationCLI
