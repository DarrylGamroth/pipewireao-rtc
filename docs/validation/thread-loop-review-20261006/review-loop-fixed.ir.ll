; Function Signature: publish_batch(PipeWireAO.Stream{PipeWireAO.CoreConnection{NamedTuple{(:on_info, :on_done, :on_ping, :on_error, :on_remove_id, :on_bound_id, :on_add_memory, :on_remove_memory, :on_bound_properties), NTuple{9, Nothing}}, PipeWireAO.Context{PipeWireAO.ThreadLoop}, PipeWireAO.CoreState{PipeWireAO.ThreadLoop}}, NamedTuple{(:on_state_changed, :on_control_info, :on_io_changed, :on_param_changed, :param_buffer, :on_param_overflow, :on_process, :on_buffer_added, :on_buffer_removed, :on_drained, :on_command, :on_trigger_done), NTuple{12, Nothing}}}, PipeWireAO.PreparedParams{1})
;  @ /tmp/review-loop-codegen-fixture.jl:4 within `publish_batch`
define void @julia_publish_batch_4770(ptr noundef nonnull align 8 dereferenceable(72) %"stream::Stream", ptr nocapture noundef nonnull readonly align 8 dereferenceable(16) %"parameters::PreparedParams") #0 {
top:
  %gcframe1 = alloca [7 x ptr], align 16
  call void @llvm.memset.p0.i64(ptr align 16 %gcframe1, i8 0, i64 56, i1 true)
  %0 = getelementptr inbounds ptr, ptr %gcframe1, i64 2
  %thread_ptr = call ptr asm "movq %fs:0, $0", "=r"() #9
  %tls_ppgcstack = getelementptr inbounds i8, ptr %thread_ptr, i64 -8
  %tls_pgcstack = load ptr, ptr %tls_ppgcstack, align 8
  store i64 20, ptr %gcframe1, align 8
  %frame.prev = getelementptr inbounds ptr, ptr %gcframe1, i64 1
  %task.gcstack = load ptr, ptr %tls_pgcstack, align 8
  store ptr %task.gcstack, ptr %frame.prev, align 8
  store ptr %gcframe1, ptr %tls_pgcstack, align 8
;  @ /tmp/review-loop-codegen-fixture.jl:5 within `publish_batch`
  %1 = getelementptr inbounds ptr, ptr %gcframe1, i64 3
  %2 = getelementptr inbounds ptr, ptr %gcframe1, i64 4
  %3 = getelementptr inbounds ptr, ptr %gcframe1, i64 5
  %4 = load atomic ptr, ptr %"parameters::PreparedParams" unordered, align 8
  %5 = getelementptr inbounds i8, ptr %"parameters::PreparedParams", i64 8
  %6 = load atomic ptr, ptr %5 unordered, align 8
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
    %gc_slot_addr_4 = getelementptr inbounds ptr, ptr %gcframe1, i64 6
    store ptr %"stream::Stream.core.context.loop", ptr %gc_slot_addr_4, align 8
; └└
; ┌ @ /home/dgamroth/workspaces/codex/pipewire/PipeWireAO-bootstrap-state/src/thread_loop.jl:118 within `with_thread_loop_lock`
; │┌ @ c.jl:166 within `disable_sigint`
; ││┌ @ c.jl:145 within `sigatomic_begin`
     %ptls_field = getelementptr inbounds i8, ptr %tls_pgcstack, i64 16
     %ptls_load = load ptr, ptr %ptls_field, align 8
     %defer_signal_ptr = getelementptr inbounds i8, ptr %ptls_load, i64 3904
     %defer_signal = load i32, ptr %defer_signal_ptr, align 4
     %defer_signal_inc = add i32 %defer_signal, 1
     store i32 %defer_signal_inc, ptr %defer_signal_ptr, align 4
     fence syncscope("singlethread") seq_cst
; ││└
; ││ @ c.jl:167 within `disable_sigint`
    store ptr %"stream::Stream", ptr %0, align 8
    store ptr %4, ptr %1, align 8
    store ptr %6, ptr %2, align 8
    store ptr %"stream::Stream.core.context.loop", ptr %3, align 8
    store ptr null, ptr %gc_slot_addr_4, align 8
    %7 = call nonnull ptr @"j_#with_thread_loop_lock##0_4772"(ptr nocapture nonnull readonly %0)
; ││ @ c.jl:169 within `disable_sigint`
; ││┌ @ c.jl:146 within `sigatomic_end`
     %ptls_load3 = load ptr, ptr %ptls_field, align 8
     %defer_signal_ptr4 = getelementptr inbounds i8, ptr %ptls_load3, i64 3904
     %defer_signal5 = load i32, ptr %defer_signal_ptr4, align 4
     fence syncscope("singlethread") seq_cst
     %.not = icmp eq i32 %defer_signal5, 0
     br i1 %.not, label %fail, label %pass

fail:                                             ; preds = %top
     call void @ijl_error(ptr nonnull @"_j_str_sigatomic_end called in n...#1")
     unreachable

pass:                                             ; preds = %top
     %defer_signal_dec = add i32 %defer_signal5, -1
     store i32 %defer_signal_dec, ptr %defer_signal_ptr4, align 4
     %deferred.not = icmp eq i32 %defer_signal_dec, 0
     br i1 %deferred.not, label %check, label %cont

check:                                            ; preds = %pass
     %ptls_load8 = load ptr, ptr %ptls_field, align 8
     %8 = getelementptr inbounds i8, ptr %ptls_load8, i64 16
     %safepoint = load ptr, ptr %8, align 8
     %9 = getelementptr inbounds i8, ptr %safepoint, i64 -8
     %signal_page_load = load volatile i64, ptr %9, align 8
     br label %cont

cont:                                             ; preds = %check, %pass
     %frame.prev14 = load ptr, ptr %frame.prev, align 8
     store ptr %frame.prev14, ptr %tls_pgcstack, align 8
; └└└
;  @ /tmp/review-loop-codegen-fixture.jl:8 within `publish_batch`
  ret void
}
