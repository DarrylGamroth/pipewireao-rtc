# Calibration uses the same physical command domain as the RTC publication.
function bounded_optical_surface(surface, lower, upper)
    lo, hi = Float64.(collect(lower)), Float64.(collect(upper))
    length(lo) == length(hi) && !isempty(lo) &&
        all(isfinite,lo) && all(isfinite,hi) && all(lo .<= hi) ||
        throw(ArgumentError("invalid optical physical-command domain"))
    record = Dict{String,Any}("lower"=>lo,"upper"=>hi,
        "tested_maximum_absolute_command"=>0.0,"tested_commands"=>0)
    checked = command -> begin
        command isa AbstractVector && length(command) == length(lo) ||
            throw(DimensionMismatch("optical command differs from physical mirror domain"))
        all(isfinite,command) && all(values -> values[1] <= values[2] <= values[3],zip(lo,command,hi)) ||
            throw(ArgumentError("optical calibration command exceeds the RTC mirror domain"))
        record["tested_maximum_absolute_command"] = max(record["tested_maximum_absolute_command"],
            maximum(abs,command))
        record["tested_commands"] += 1
        return surface(command)
    end
    return (;surface=checked,record)
end

function optical_native_command_domain(application, mirror, count, surface)
    options = PipeWireAORTC.AOSOwner.configuration(joinpath(application,"simulation.conf"))
    rtc = IC.load_rtc(options.rtc_configuration)
    limiter = rtc.controls["deformable_mirrors"][mirror]["limiter"]
    limiter["kind"] == "amplitude" ||
        throw(ArgumentError("native optical calibration requires an explicit RTC amplitude domain"))
    return bounded_optical_surface(surface,
        IC.limit_values(limiter["lower"],count),IC.limit_values(limiter["upper"],count))
end
