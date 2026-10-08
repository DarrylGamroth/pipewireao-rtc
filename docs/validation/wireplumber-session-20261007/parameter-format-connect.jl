using PipeWireAODeployment
const B=PipeWireAODeployment.NativeOwnerBootstrapClient
const C=PipeWireAODeployment.NativeControlClient
connection=B.connect(ARGS[1],"pipewireao.rtc.bootstrap.parameters",parse(Int,ARGS[2]),11007;deadline=C.monotonic()+45)
try
    println(B.connect_owner!(connection;deadline=C.monotonic()+45))
    flush(stdout)
    sleep(8)
    println(B.quit!(connection;deadline=C.monotonic()+10))
    flush(stdout)
finally
    close(connection)
end
