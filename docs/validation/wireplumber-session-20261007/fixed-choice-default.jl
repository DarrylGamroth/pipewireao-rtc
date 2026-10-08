using PipeWireAODeployment, PipeWireAO
S=PipeWireAO.SPA
choice=Pod(S.Choice(S.CHOICE_RANGE,Int32[5,1,10]))
reinterpret(UInt32,@view(choice.data[9:12]))[1]=UInt32(S.CHOICE_NONE)
words=reinterpret(UInt32,@view(choice.data[9:24]))
@assert Int(words[3]) != length(choice.data)-24
println("OLD_SINGLETON_CHECK_REJECTS_VALID_FIXED_DEFAULT")
format=Pod(S.Object(PipeWireAO.LibPipeWire.SPA_TYPE_OBJECT_Format,S.PARAM_FORMAT,
    S.Property(S.FORMAT_AUDIO_RATE,choice)))
fixed=PipeWireAODeployment.NativeParameterSource._fixed_format(format)
value=only(fixed.object.properties).value
@assert pod_value(Int32,value)==5
@assert length(value.data)==12
@assert length(only(pod_value(S.Parameter,format).object.properties).value.data)==36
println("FIXED_CHOICE_DEFAULT_RETAINED_VALUES_PASS")
range=Pod(S.Choice(S.CHOICE_RANGE,Int32[5,1,10]))
unfixed=Pod(S.Object(PipeWireAO.LibPipeWire.SPA_TYPE_OBJECT_Format,S.PARAM_FORMAT,
    S.Property(S.FORMAT_AUDIO_RATE,range)))
try
 PipeWireAODeployment.NativeParameterSource._fixed_format(unfixed)
 error("unfixed range accepted")
catch e
 e isa ArgumentError || rethrow()
end
println("UNFIXED_CHOICE_REJECTION_PASS")
