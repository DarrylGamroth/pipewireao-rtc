using PipeWireAODeployment
const B=PipeWireAODeployment.NativeOwnerBootstrapClient
const C=PipeWireAODeployment.NativeControlClient
connection=B.connect(ARGS[1],"pipewireao.rtc.bootstrap.parameters",parse(Int,ARGS[2]),11007;deadline=C.monotonic()+45)
try
    println(B.connect_owner!(connection;deadline=C.monotonic()+45))
    flush(stdout)
    sleep(1)
    P=PipeWireAODeployment.NativeParameterSource
    R=PipeWireAODeployment.RunnerCommands
    parameter=C.connect(P.PROFILE,ARGS[1],"pipewireao.rtc.parameters.probe",parse(UInt32,ARGS[2]),Int64(11008);deadline=C.monotonic()+15)
    try
        reply=C.request!(parameter,R.parse(["parameter","revolt-copper-fgn-frame-graph","reconstruct:reconstructor","F32_LE","253x3600","org.calculon.ao.pwfs-reconstructor/1","/tmp/rtc-wireplumber-fgn-20261007-installed/calibration/parameter-reconstructor.f32"]);deadline=C.monotonic()+15)
        println(reply);flush(stdout)
        reply.header.result==0 && reply.submitted && !reply.active_adoption_observed || error("publication was not submitted")
    finally
        close(parameter)
    end
    println(B.quit!(connection;deadline=C.monotonic()+10))
    flush(stdout)
finally
    close(connection)
end
