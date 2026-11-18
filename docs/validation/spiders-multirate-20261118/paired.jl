using Printf
using Statistics

function read_rows(f, path)
    open(path) do io
        names = Tuple(Symbol.(split(readline(io), ',')))
        for line in eachline(io)
            isempty(line) && continue
            f(NamedTuple{names}(Tuple(split(line, ','; keepempty=true))))
        end
    end
end

function load_trace(dir)
    phases = Dict{Int,String}()
    contrast = Dict{Int,Float64}()
    low_order = Dict{Int,Float64}()
    steps = Dict{Int,Float64}()
    peak = Dict{Int,Float64}()
    read_rows(joinpath(dir, "optical.csv")) do row
        i = parse(Int, row.tick)
        phases[i] = row.phase
        if row.camera == "scc" && row.chopping == "unfringed"
            @assert !haskey(contrast, i)
            contrast[i] = parse(Float64, row.contrast)
        end
    end
    read_rows(joinpath(dir, "native.csv")) do row
        if row.stream == "llowfs-modal-residual"
            i = parse(Int, row.tick)
            @assert !haskey(low_order, i)
            low_order[i] = 1e9 * parse(Float64, row.llowfs_norm_m)
        end
    end
    read_rows(joinpath(dir, "commands.csv")) do row
        i = parse(Int, row.tick)
        if !isempty(row.step_inf_native)
            steps[i] = max(get(steps, i, 0.0), parse(Float64, row.step_inf_native))
        end
        peak[i] = max(get(peak, i, 0.0), parse(Float64, row.peak_native))
    end
    return (; phases, contrast, low_order, steps, peak)
end

function values_in(d, ticks)
    return [d[i] for i in ticks if haskey(d, i)]
end

function summarize(trace, ticks)
    dark = values_in(trace.contrast, ticks)
    residual = values_in(trace.low_order, ticks)
    return (; n=length(dark), contrast=mean(dark), residual_nm=sqrt(mean(abs2, residual)),
        peak=maximum(values_in(trace.peak, ticks)), step=maximum(values_in(trace.steps, ticks)))
end

function compare(fault_dir, control_dir, output, protective_dir=nothing)
    fault, control = load_trace.((fault_dir, control_dir))
    @assert keys(fault.phases) == keys(control.phases)
    @assert keys(fault.contrast) == keys(control.contrast)
    @assert keys(fault.low_order) == keys(control.low_order)
    ticks = sort!(collect(keys(fault.phases)))
    @assert ticks == collect(1:last(ticks))
    open(joinpath(output, "paired-phases.csv"), "w") do io
        println(io, "phase,window,tick_first,tick_last,unfringed,contrast,control_contrast,contrast_change_pct,llowfs_rms_nm,control_llowfs_rms_nm,peak_demand,max_step,control_max_step")
        for phase in unique(fault.phases[i] for i in ticks)
            range = filter(i -> fault.phases[i] == phase, ticks)
            for (name, window) in (("full", range), ("late", range[cld(length(range),2)+1:end]))
                isempty(window) && continue
                a, b = summarize(fault, window), summarize(control, window)
                @printf(io, "%s,%s,%d,%d,%d,%.10g,%.10g,%+.5f,%.7g,%.7g,%.8g,%.8g,%.8g\n",
                    phase, name, first(window), last(window), a.n, a.contrast, b.contrast,
                    100*(a.contrast/b.contrast-1), a.residual_nm, b.residual_nm, a.peak, a.step, b.step)
            end
        end
    end
    first_release = first(i for i in ticks if fault.phases[i] == "release")
    open(joinpath(output, "recovery-windows.csv"), "w") do io
        println(io, "tick_first,tick_last,model_s_since_restore,contrast,control_contrast,contrast_change_pct,llowfs_rms_nm,control_llowfs_rms_nm,max_step,control_max_step")
        for start in first_release:100:last(ticks)
            window = start:min(start + 99, last(ticks))
            a, b = summarize(fault, window), summarize(control, window)
            @printf(io, "%d,%d,%.2f,%.10g,%.10g,%+.5f,%.7g,%.7g,%.8g,%.8g\n",
                first(window), last(window), (start-first_release)/100, a.contrast, b.contrast,
                100*(a.contrast/b.contrast-1), a.residual_nm, b.residual_nm, a.step, b.step)
        end
    end
    if protective_dir !== nothing
        protected = load_trace(protective_dir)
        @assert keys(protected.contrast) == keys(control.contrast)
        open(joinpath(output, "protective-timeline.csv"), "w") do io
            println(io, "model_s,contrast,llowfs_rms_nm,max_step")
            for start in 1:10:last(ticks)
                window = start:min(start + 9,last(ticks))
                a = summarize(protected, window)
                @printf(io,"%.3f,%.10g,%.7g,%.8g\n",
                    (mean(window)-1)/100, a.contrast, a.residual_nm, a.step)
            end
        end
        open(joinpath(output, "protective-windows.csv"), "w") do io
            println(io, "tick_first,tick_last,contrast,control_contrast,llowfs_rms_nm,control_llowfs_rms_nm,max_step,control_max_step")
            for window in (1653:1800, 1801:1804, 1805:1904, 1905:2004, 2102:2550, 2451:2550)
                a, b = summarize(protected, window), summarize(control, window)
                @printf(io, "%d,%d,%.10g,%.10g,%.7g,%.7g,%.8g,%.8g\n",
                    first(window), last(window), a.contrast, b.contrast, a.residual_nm,
                    b.residual_nm, a.step, b.step)
            end
        end
    end
    open(joinpath(output, "timeline.csv"), "w") do io
        println(io, "model_s,phase,contrast,control_contrast,llowfs_rms_nm,control_llowfs_rms_nm,peak_demand,max_step,control_max_step")
        for start in 1:10:last(ticks)
            window = start:min(start+9,last(ticks))
            a, b = summarize(fault, window), summarize(control, window)
            @printf(io,"%.3f,%s,%.10g,%.10g,%.7g,%.7g,%.8g,%.8g,%.8g\n",
                (mean(window)-1)/100, fault.phases[start], a.contrast, b.contrast,
                a.residual_nm, b.residual_nm, a.peak, a.step, b.step)
        end
    end
end

compare(ARGS...)
