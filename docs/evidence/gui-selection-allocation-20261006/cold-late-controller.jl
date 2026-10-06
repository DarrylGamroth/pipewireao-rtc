using PipeWireAO
include(ARGS[1])
const M=HILNativeOwnerBootstrap
Base.include(M,joinpath(M.SOURCE,"native_owner_bootstrap_client.jl"))
const B=M.NativeOwnerBootstrapClient
const C=M.NativeControlClient
println("READY");flush(stdout)
client=nothing
try
    readline(stdin)=="attach" || error("unexpected phase")
    client=B.connect(ARGS[2],ARGS[3],parse(Int,ARGS[4]),parse(Int64,ARGS[5]);deadline=C.monotonic()+20)
    println("ATTACHED");flush(stdout)
    readline(stdin)=="status" || error("unexpected phase")
    B.status(client;deadline=C.monotonic()+20)
    println("STATUS");flush(stdout)
    readline(stdin)=="remove" || error("unexpected phase")
    close(client);client=nothing
    println("REMOVED");flush(stdout)
finally
    client===nothing || close(client)
end
