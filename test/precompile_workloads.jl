# Run with --compiled-modules=no --project=. in a fresh Julia process.
# PrecompileTools' verbose mode runs the package workloads and reports the
# inferred methods. Keep the diagnostic output local to the temporary directory.
using Logging, StyledStrings
using PrecompileTools, TOML, Test

@testset "RTC package-image workloads prepare native controls offline" begin
    Base.JLOptions().use_compiled_modules == 0 || error("use --compiled-modules=no")
    # Limit workload diagnostics to the RTC. Load its ordinary dependencies first.
    for name in keys(TOML.parsefile(Base.active_project())["deps"])
        Base.require(Main, Symbol(name))
    end
    mktempdir() do directory
        runtime = mkdir(joinpath(directory, "runtime"))
        trace = joinpath(directory, "inference.log")
        withenv("XDG_RUNTIME_DIR" => runtime, "PIPEWIREAO_RUNTIME_DIR" => runtime,
                "PIPEWIREAO_REMOTE" => joinpath(runtime, "absent-core")) do
            open(trace, "w") do io
                PrecompileTools.verbose[] = true
                try
                    redirect_stdout(() -> Base.require(Main, :PipeWireAORTC), io)
                finally
                    PrecompileTools.verbose[] = false
                end
            end
        end
        @test isempty(readdir(runtime))
        @test !any(id.name in ("FilterGraphs", "AdaptiveOpticsSimPipeWireHIL", "AMDGPU", "CUDA")
                   for id in keys(Base.loaded_modules))
        required = Set(["ControlClient.bind_owner", "ControlClient.bind_marker",
            "MediaSession.precompile_admission", "MediaSession.prepare_parameter_ndarray!",
            "ParameterSource.precompile_parameter_codecs!"])
        open(trace) do io
            for line in eachline(io)
                method = match(r"^MethodInstance for PipeWireAORTC\.([\w.!]+)\(", line)
                isnothing(method) || delete!(required, only(method.captures))
                isempty(required) && break
            end
        end
        @test isempty(required)
    end
end
