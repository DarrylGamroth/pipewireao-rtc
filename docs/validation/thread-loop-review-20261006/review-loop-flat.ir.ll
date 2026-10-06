; Function Signature: publish_batch(PipeWireAO.Stream{PipeWireAO.CoreConnection{NamedTuple{(:on_info, :on_done, :on_ping, :on_error, :on_remove_id, :on_bound_id, :on_add_memory, :on_remove_memory, :on_bound_properties), NTuple{9, Nothing}}, PipeWireAO.Context{PipeWireAO.ThreadLoop}, PipeWireAO.CoreState{PipeWireAO.ThreadLoop}}, NamedTuple{(:on_state_changed, :on_control_info, :on_io_changed, :on_param_changed, :param_buffer, :on_param_overflow, :on_process, :on_buffer_added, :on_buffer_removed, :on_drained, :on_command, :on_trigger_done), NTuple{12, Nothing}}}, PipeWireAO.PreparedParams{1})
;  @ /tmp/review-loop-codegen-fixture.jl:4 within `publish_batch`
define void @julia_publish_batch_4210(ptr noundef nonnull align 8 dereferenceable(72) %"stream::Stream", ptr nocapture noundef nonnull readonly align 8 dereferenceable(16) %"parameters::PreparedParams") #0 {
top:
  %0 = alloca { ptr, { [1 x [1 x ptr]], ptr } }, align 8
;  @ /tmp/review-loop-codegen-fixture.jl:5 within `publish_batch`
  %1 = getelementptr inbounds i8, ptr %0, i64 8
  %2 = getelementptr inbounds i8, ptr %0, i64 16
  %3 = load atomic ptr, ptr %"parameters::PreparedParams" unordered, align 8
  %4 = getelementptr inbounds i8, ptr %"parameters::PreparedParams", i64 8
  %5 = load atomic ptr, ptr %4 unordered, align 8
; ┌ @ /home/dgamroth/workspaces/codex/pipewire/PipeWireAO-bootstrap-state/src/stream.jl:459 within `main_loop`
; │┌ @ Base_compiler.jl:54 within `getproperty`
    %"stream::Stream.core_ptr" = getelementptr inbounds i8, ptr %"stream::Stream", i64 8
    %"stream::Stream.core" = load atomic ptr, ptr %"stream::Stream.core_ptr" unordered, align 8
; │└
; │ @ /home/dgamroth/workspaces/codex/pipewire/PipeWireAO-bootstrap-state/src/stream.jl:459 within `main_loop` @ /home/dgamroth/workspaces/codex/pipewire/PipeWireAO-bootstrap-state/src/core.jl:798
; │┌ @ Base_compiler.jl:54 within `getproperty`
    %"stream::Stream.core.context_ptr" = getelementptr inbounds i8, ptr %"stream::Stream.core", i64 8
    %"stream::Stream.core.context" = load atomic ptr, ptr %"stream::Stream.core.context_ptr" unordered, align 8
; │└
; │ @ /home/dgamroth/workspaces/codex/pipewire/PipeWireAO-bootstrap-state/src/stream.jl:459 within `main_loop` @ /home/dgamroth/workspaces/codex/pipewire/PipeWireAO-bootstrap-state/src/core.jl:798 @ /home/dgamroth/workspaces/codex/pipewire/PipeWireAO-bootstrap-state/src/core.jl:117
; │┌ @ Base_compiler.jl:54 within `getproperty`
    %"stream::Stream.core.context.loop_ptr" = getelementptr inbounds i8, ptr %"stream::Stream.core.context", i64 8
    %"stream::Stream.core.context.loop" = load atomic ptr, ptr %"stream::Stream.core.context.loop_ptr" unordered, align 8
; └└
  store ptr %"stream::Stream", ptr %0, align 8
  store ptr %3, ptr %1, align 8
  store ptr %5, ptr %2, align 8
  %6 = call nonnull ptr @j_with_thread_loop_lock_4212(ptr nocapture nonnull readonly %0, ptr nonnull %"stream::Stream.core.context.loop")
;  @ /tmp/review-loop-codegen-fixture.jl:8 within `publish_batch`
  ret void
}
