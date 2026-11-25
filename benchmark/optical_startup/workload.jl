using PipeWireAORTC, AdaptiveOpticsSimPipeWireHIL
const OpticalOwner = Base.get_extension(AdaptiveOpticsSimPipeWireHIL, :PipeWireAORTCExt)
const ExternalPupil = AdaptiveOpticsSimPipeWireHIL.ExternalPupil

function measure(f, phase)
    println("begin ", phase)
    flush(stdout)
    timing = @timed f()
    println("end ", phase, " wall=", timing.time, " compile=", timing.compile_time)
    flush(stdout)
    return timing.value
end

function optical_workload(config)
    options = merge(OpticalOwner.Configuration.configuration(config), (; owner_check=Returns(nothing)))
    options.backend === :cpu || error("workload requires CPU")
    OpticalOwner.Configuration.verify_external_pupil_declaration(options)
    mode = Val(options.version)
    clocked = mode === Val(6)
    mode isa OpticalOwner.OpticalMode || error("expected managed optical configuration")
    science = measure("prepare optical model") do
        OpticalOwner.prepare_optics(options, mode)
    end
    execution = ExternalPupil.prepare(science; clocked,
        command_count=clocked ? options.command_count : 0,
        command_limit=clocked ? options.command_limit : Inf,
        pacing_period_ns=clocked ? options.pacing_period_ns : 0)
    measure("warm up optical model") do
        ExternalPupil.warmup!(execution; check=options.owner_check)
    end
    @assert ExternalPupil.snapshot(execution).sequence == 0
    return nothing
end
