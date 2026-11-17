include(joinpath(@__DIR__, "..", "spiders-scc-error-20261117", "summarize.jl"))

for seed in (17, 73)
    summarize(only(ARGS), seed; replay_biased_baseline=false, require_command_receipt=false)
end
