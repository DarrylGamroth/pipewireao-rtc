#!/usr/bin/env julia
# Cold bootstrap publishes Preparing before scientific imports or model work.
include("owner_protocol.jl")
include("native_owner_bootstrap.jl")
function main(arguments=ARGS)
    options = HILOwnerProtocol.parse_options(arguments; native_bootstrap=true)
    HILNativeOwnerBootstrap.with_owner(options) do admitted
        admitted.owner_check()
        include(joinpath(@__DIR__, "simulator_owner.jl"))
        admitted.owner_check()
        Base.invokelatest(run_owner_main, admitted)
    end
end
if abspath(PROGRAM_FILE) == (@__FILE__)
    main()
else
    # Acquisition owners and scientific unit fixtures reuse these definitions.
    # Only the selected ordinary process entry point defers them until Preparing.
    include(joinpath(@__DIR__, "simulator_owner.jl"))
end
