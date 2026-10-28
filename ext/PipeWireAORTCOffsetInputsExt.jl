module PipeWireAORTCOffsetInputsExt

using PipeWireAO
import PipeWireAORTC
import AdaptiveOpticsSimPipeWireHIL as HIL
const Offsets=PipeWireAORTC.PhysicalOffsets

mutable struct NativeInputs{P,T}
    prepared::P
    transport::T
    initial::BitVector
    rejected::Vector{UInt64}
    applied_command::Int
end

function Offsets.with_receiver(f,prepared::Offsets.PreparedReceiver;remote,applied_command=nothing)
    (;names,calibrations)=prepared.inputs
    options=map(eachindex(names)) do i
        row=prepared.inputs.declaration["branches"][string(names[i])]
        HIL.PipeWireArrayStreamOptions(;node_name=row["node_name"],media_name=string(names[i])*" physical offset",
            acquisition_version=get(row,"acquisition_version",2),schema=calibrations[i].schema,
            format=NdArrayFormat(NdArray.F32_LE,(length(prepared.inputs.total),);layout=NdArray.ROW_MAJOR))
    end
    streams=applied_command===nothing ? Tuple(options) : (options...,applied_command)
    HIL.with_array_streams(streams;remote,input=ntuple(i->i<=length(names),length(streams))) do transport
        inputs=NativeInputs(prepared.inputs,transport,trues(length(names)),zeros(UInt64,length(names)),
            applied_command===nothing ? 0 : length(streams))
        try
            return f(inputs)
        finally
            Offsets.disarm!(prepared.inputs.receiver;reason=:quit)
            fill!(prepared.inputs.total,0)
        end
    end
end

function Offsets.reset_inputs!(inputs::NativeInputs)
    (;receiver,names,total)=inputs.prepared
    Offsets.disarm!(receiver;reason=:reset)
    receiver.clock_identity=nothing
    receiver.clock_end_ns=0
    fill!(total,0)
    fill!(inputs.initial,true)
    for i in eachindex(names)
        HIL.reset_pipewire_array!(inputs.transport,i)
        inputs.rejected[i]=0
    end
    return nothing
end

# Called only by the source task. Native callbacks own bounded staging buffers;
# they never write receiver contributions, the command, or the scientific graph.
function Offsets.poll!(inputs::NativeInputs;now_ns::UInt64=time_ns())
    (;receiver,names,calibrations,buffers,total,declaration)=inputs.prepared
    for i in eachindex(names)
        name=names[i]
        wire_status=HIL.array_stream_status(inputs.transport,i)
        state=if wire_status.failed
            nothing
        else
            try
                HIL.with_array_stream(inputs.transport,i) do stream
                    stream_state(stream)
                end
            catch error
                error isa PipeWireAO.PipeWireError || rethrow()
                nothing
            end
        end
        if state===nothing || wire_status.failed || wire_status.rejected!=inputs.rejected[i] ||
                (receiver.branches[name].present && state!=PipeWireAO.LibPipeWire.PW_STREAM_STATE_STREAMING)
            Offsets.disarm!(receiver,name;reason=:transport)
            inputs.initial[i]=false
        end
        inputs.rejected[i]=wire_status.rejected
        receipt=HIL.drain_pipewire_array!(buffers[i],inputs.transport,i)
        receipt===nothing && continue
        if inputs.initial[i] && receiver.clock_identity!==nothing
            identity=receipt.identity
            previous=receiver.branches[name].identity
            if previous!==nothing && identity.domain==previous.domain && identity.generation<=previous.generation
                continue
            end
            Offsets.arm!(receiver,name,AcquisitionIdentity(identity.domain,identity.generation,0))
            inputs.initial[i]=false
        end
        Offsets.accept!(receiver,name,buffers[i],receipt.identity,receipt.pts,receipt.duration;
            now_ns,schema=calibrations[i].schema,calibration_identity=declaration["calibration_identity"],
            command_order=declaration["command_order"])
    end
    Offsets.expire!(receiver,now_ns)
    return Offsets.total!(total,receiver)
end

end
