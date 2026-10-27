include(joinpath(@__DIR__,"native_stream_verification.jl"))
precompile(main, ())
deadline=time()+3600
while !isfile(joinpath(ROOT,"loop-controls-complete"))
 time()<deadline || error("live controls were not verified before observation deadline")
 sleep(0.25)
end
main()
