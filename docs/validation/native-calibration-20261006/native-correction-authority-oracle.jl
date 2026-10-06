using Test,PipeWireAODeployment
include(joinpath(@__DIR__,"../../../deployment/qualify_correction_native.jl"))
const RQ=NativeCorrectionQualification
const RL=RQ.L
const RE=PipeWireAODeployment.NativeControlCodec
const HistoricalSource="/home/dgamroth/.cache/rtc-calibration-completion-20261003/run_native_correction_v1.jl"
RQ.require(RQ.C.sha256_file(HistoricalSource) == "cb99c372c01c5466ccdce7257e0232b874a5c52ef79acc5e8715418e3a6da39d",
    "frozen historical correction coordinator changed")
module HistoricalCorrectionWait
    using PipeWireAODeployment
    const C=PipeWireAODeployment.Common
    process_running(::Nothing)=true
end
source=read(HistoricalSource,String)
start=findfirst("function wait_window(",source)
finish=findnext("\ncommand=",source,last(start))
definition=source[first(start):first(finish)-1]
println("historical_source_sha256=",RQ.C.sha256_file(HistoricalSource))
println("historical_wait_sha256=",RQ.C.bytes2hex(RQ.C.sha256(codeunits(definition))))
Core.eval(HistoricalCorrectionWait,Meta.parse(definition))
@testset "Correction must reject a saved complete report after native owner stopped" begin
    mktempdir() do directory
        native_root=joinpath(directory,"native");mkdir(native_root)
        evidence=joinpath(directory,"retained");mkdir(evidence)
        mkdir(joinpath(native_root,"window-1"))
        report=Dict("failure"=>nothing,"completed"=>true,"native_window"=>1,
            "completed_frames"=>256,"completed_commands"=>256,"requested_frames"=>256,
            "sequences"=>collect(1:256),"model_timestamps_ns"=>collect(0:255).*2_000_000,"model_period_ns"=>2_000_000,
            "native_recording_retained"=>true,"native_active"=>nothing,"completed_correct_proof"=>Dict("child_pid"=>1001),
            "time_observation_scope"=>"CLOCK_MONOTONIC application whole-exchange boundaries; no exact callback, native RTC latency, RTT or cadence claim")
        path=joinpath(directory,"simulator-result.json")
        RQ.C.write_json(path,report);RQ.C.write_json(joinpath(native_root,"window-1","owner-report.json"),report)
        Core.eval(HistoricalCorrectionWait,:(native_root=$native_root))
        Core.eval(HistoricalCorrectionWait,:(evidence=$evidence))
        f=(;instrument=RL.Classic,evidence_directory=native_root)
        c=RL.AcquisitionCursor(1,1,256,511_896_000)
        header=RE.ReplyHeader(RE.ControllerIdentity(UInt32(99),UInt64(1),Int64(2)),Int64(7),Int64(1),UInt32(1),Int32(0))
        stopped=RL.Completion(header,RL.Stopped,RL.Snapshot(RL.Classic,c,c,false,true,"restored",false,true,UInt64(1)),"")
        reads=Ref(0)
        read_report=path->(reads[]+=1;RQ.C.read_json(path))
        rejected=try
            if get(ENV,"CORRECTION_AUTHORITY_BEFORE","false") == "true"
                HistoricalCorrectionWait.wait_window(directory,1,nothing)
            else
                RQ.wait_window(nothing,f,nothing,1,path;deadline=RQ.Native.monotonic()+5,check=()->nothing,
                    status=(args...;kwargs...)->stopped,read_report)
            end
            false
        catch error
            error isa ErrorException
        end
        @test rejected
        @test reads[] == 0
    end
end
