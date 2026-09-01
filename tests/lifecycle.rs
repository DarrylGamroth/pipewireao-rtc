use pipewireao_rtc::{
    DevelopmentConfig, EffectExecutor, EffectKind, EffectOrigin, EffectTarget, ExecutionGroupState,
    LifecycleDispatcher, LifecycleEffect, LifecycleEffectResult, LifecycleEffectSuccess,
    LifecycleEvent, LifecycleState, Runner, ScientificDiagnostic,
};

const VALID: &str = include_str!("../fixtures/minimal-development.conf");

fn config() -> DevelopmentConfig {
    DevelopmentConfig::parse(VALID).expect("test configuration")
}

fn complete(
    dispatcher: &mut LifecycleDispatcher,
    effect: &LifecycleEffect,
    result: Result<(), ScientificDiagnostic>,
) -> LifecycleState {
    dispatcher
        .dispatch(LifecycleEvent::EffectCompleted(
            LifecycleEffectResult::from_effect(effect, result),
        ))
        .expect("valid effect completion")
        .state
}

fn load_ready(dispatcher: &mut LifecycleDispatcher) {
    let outcome = dispatcher
        .dispatch(LifecycleEvent::Load(config().into()))
        .expect("load accepted");
    assert_eq!(outcome.state, LifecycleState::Configuring);
    complete(dispatcher, &outcome.effect.expect("realize effect"), Ok(()));
    assert_eq!(dispatcher.state(), LifecycleState::Ready);
    assert_eq!(
        dispatcher.execution_group_states().get("main"),
        Some(&ExecutionGroupState::Stopped)
    );
}

fn start_running(dispatcher: &mut LifecycleDispatcher) {
    let outcome = dispatcher
        .dispatch(LifecycleEvent::Start)
        .expect("start accepted");
    complete(dispatcher, &outcome.effect.expect("start effect"), Ok(()));
    assert_eq!(dispatcher.state(), LifecycleState::Running);
    assert_eq!(
        dispatcher.execution_group_states().get("main"),
        Some(&ExecutionGroupState::Running)
    );
}

#[test]
fn every_legal_transition_succeeds() {
    let mut dispatcher = LifecycleDispatcher::new();
    load_ready(&mut dispatcher);
    start_running(&mut dispatcher);

    let group_stop = dispatcher
        .dispatch(LifecycleEvent::StopExecutionGroup("main".to_owned()))
        .expect("execution-group stop");
    assert_eq!(
        group_stop.effect.as_ref().map(LifecycleEffect::kind),
        Some(EffectKind::StopExecutionGroup)
    );
    assert_eq!(
        complete(&mut dispatcher, &group_stop.effect.unwrap(), Ok(())),
        LifecycleState::Running
    );
    assert_eq!(
        dispatcher.execution_group_states()["main"],
        ExecutionGroupState::Stopped
    );
    let group_start = dispatcher
        .dispatch(LifecycleEvent::StartExecutionGroup("main".to_owned()))
        .expect("execution-group start");
    assert_eq!(
        complete(&mut dispatcher, &group_start.effect.unwrap(), Ok(())),
        LifecycleState::Running
    );

    let stop = dispatcher.dispatch(LifecycleEvent::Stop).expect("stop");
    assert_eq!(
        complete(&mut dispatcher, &stop.effect.unwrap(), Ok(())),
        LifecycleState::Ready
    );

    let reload = dispatcher
        .dispatch(LifecycleEvent::Reload(config().into()))
        .expect("reload");
    assert_eq!(reload.state, LifecycleState::Configuring);
    assert_eq!(
        complete(&mut dispatcher, &reload.effect.unwrap(), Ok(())),
        LifecycleState::Ready
    );

    start_running(&mut dispatcher);
    let source_end = dispatcher
        .dispatch(LifecycleEvent::FiniteSourceCompleted)
        .expect("source completion");
    assert_eq!(
        source_end.effect.as_ref().map(LifecycleEffect::origin),
        Some(EffectOrigin::FiniteSourceCompletion)
    );
    assert_eq!(
        complete(&mut dispatcher, &source_end.effect.unwrap(), Ok(())),
        LifecycleState::Ready
    );

    dispatcher
        .dispatch(LifecycleEvent::RequiredObjectFailed(
            ScientificDiagnostic::new("graph", "required object disappeared"),
        ))
        .expect("required failure");
    assert_eq!(dispatcher.state(), LifecycleState::Fault);

    let retry = dispatcher.dispatch(LifecycleEvent::Retry).expect("retry");
    assert_eq!(retry.state, LifecycleState::Configuring);
    assert_eq!(
        complete(&mut dispatcher, &retry.effect.unwrap(), Ok(())),
        LifecycleState::Ready
    );

    let unload = dispatcher.dispatch(LifecycleEvent::Unload).expect("unload");
    assert_eq!(
        complete(&mut dispatcher, &unload.effect.unwrap(), Ok(())),
        LifecycleState::Offline
    );
}

#[test]
fn realization_start_stop_and_cleanup_failures_reach_or_remain_in_fault() {
    {
        let mut dispatcher = LifecycleDispatcher::new();
        let effect = dispatcher
            .dispatch(LifecycleEvent::Load(config().into()))
            .unwrap()
            .effect
            .unwrap();
        assert_eq!(
            complete(
                &mut dispatcher,
                &effect,
                Err(ScientificDiagnostic::new("source", "creation failed")),
            ),
            LifecycleState::Fault
        );
    }

    let mut dispatcher = LifecycleDispatcher::new();
    load_ready(&mut dispatcher);
    let start = dispatcher
        .dispatch(LifecycleEvent::Start)
        .unwrap()
        .effect
        .unwrap();
    assert_eq!(
        complete(
            &mut dispatcher,
            &start,
            Err(ScientificDiagnostic::new("graph", "start failed")),
        ),
        LifecycleState::Fault
    );
    let unload = dispatcher
        .dispatch(LifecycleEvent::Unload)
        .unwrap()
        .effect
        .unwrap();
    assert_eq!(
        complete(
            &mut dispatcher,
            &unload,
            Err(ScientificDiagnostic::new("cleanup", "destroy failed")),
        ),
        LifecycleState::Fault
    );

    let mut dispatcher = LifecycleDispatcher::new();
    load_ready(&mut dispatcher);
    start_running(&mut dispatcher);
    let stop = dispatcher
        .dispatch(LifecycleEvent::Stop)
        .unwrap()
        .effect
        .unwrap();
    assert_eq!(
        complete(
            &mut dispatcher,
            &stop,
            Err(ScientificDiagnostic::new("sink", "stop failed")),
        ),
        LifecycleState::Fault
    );
}

#[test]
fn invalid_events_do_not_corrupt_state_or_pending_effect() {
    let mut dispatcher = LifecycleDispatcher::new();
    assert!(dispatcher.dispatch(LifecycleEvent::Start).is_err());
    assert_eq!(dispatcher.state(), LifecycleState::Offline);

    let load = dispatcher
        .dispatch(LifecycleEvent::Load(config().into()))
        .unwrap();
    let pending = load.effect.unwrap();
    assert!(dispatcher.dispatch(LifecycleEvent::Start).is_err());
    assert_eq!(dispatcher.pending_effect(), Some(&pending));
    complete(&mut dispatcher, &pending, Ok(()));
    assert_eq!(dispatcher.state(), LifecycleState::Ready);
}

#[test]
fn managed_accepts_unload_from_every_descendant() {
    for target in [
        LifecycleState::Configuring,
        LifecycleState::Ready,
        LifecycleState::Running,
        LifecycleState::Fault,
    ] {
        let mut dispatcher = LifecycleDispatcher::new();
        let load = dispatcher
            .dispatch(LifecycleEvent::Load(config().into()))
            .unwrap();
        if target != LifecycleState::Configuring {
            complete(&mut dispatcher, &load.effect.unwrap(), Ok(()));
        }
        if target == LifecycleState::Running {
            start_running(&mut dispatcher);
        } else if target == LifecycleState::Fault {
            dispatcher
                .dispatch(LifecycleEvent::RequiredObjectFailed(
                    ScientificDiagnostic::new("graph", "failed"),
                ))
                .unwrap();
        }
        assert_eq!(dispatcher.state(), target);
        let unload = dispatcher.dispatch(LifecycleEvent::Unload).unwrap();
        assert_eq!(
            unload.effect.as_ref().map(LifecycleEffect::kind),
            Some(EffectKind::Cleanup)
        );
        assert_eq!(
            complete(&mut dispatcher, &unload.effect.unwrap(), Ok(())),
            LifecycleState::Offline
        );
    }
}

#[test]
fn stale_duplicate_wrong_kind_and_wrong_origin_completions_are_rejected() {
    let mut dispatcher = LifecycleDispatcher::new();
    let effect = dispatcher
        .dispatch(LifecycleEvent::Load(config().into()))
        .unwrap()
        .effect
        .unwrap();

    let mut other = LifecycleDispatcher::new();
    let other_effect = other
        .dispatch(LifecycleEvent::Load(config().into()))
        .unwrap()
        .effect
        .unwrap();
    let unload = other
        .dispatch(LifecycleEvent::Unload)
        .unwrap()
        .effect
        .unwrap();

    let mut wrong_token = LifecycleEffectResult::from_effect(&effect, Ok(()));
    wrong_token.token = unload.token();
    assert!(dispatcher
        .dispatch(LifecycleEvent::EffectCompleted(wrong_token))
        .is_err());

    let mut wrong_kind = LifecycleEffectResult::from_effect(&effect, Ok(()));
    wrong_kind.kind = EffectKind::Start;
    assert!(dispatcher
        .dispatch(LifecycleEvent::EffectCompleted(wrong_kind))
        .is_err());

    let mut wrong_origin = LifecycleEffectResult::from_effect(&effect, Ok(()));
    wrong_origin.origin = EffectOrigin::FaultRetry;
    assert!(dispatcher
        .dispatch(LifecycleEvent::EffectCompleted(wrong_origin))
        .is_err());

    complete(&mut dispatcher, &effect, Ok(()));
    assert!(dispatcher
        .dispatch(LifecycleEvent::EffectCompleted(
            LifecycleEffectResult::from_effect(&effect, Ok(())),
        ))
        .is_err());
    assert_eq!(dispatcher.state(), LifecycleState::Ready);
    assert_eq!(other_effect.kind(), EffectKind::Realize);
}

#[test]
fn group_completion_identity_and_invalid_requests_are_rejected_without_corruption() {
    let mut dispatcher = LifecycleDispatcher::new();
    assert!(dispatcher
        .dispatch(LifecycleEvent::StartExecutionGroup("main".to_owned()))
        .is_err());
    load_ready(&mut dispatcher);
    assert!(dispatcher
        .dispatch(LifecycleEvent::StartExecutionGroup("main".to_owned()))
        .is_err());
    start_running(&mut dispatcher);
    assert!(dispatcher
        .dispatch(LifecycleEvent::StopExecutionGroup("unknown".to_owned()))
        .is_err());
    assert_eq!(dispatcher.state(), LifecycleState::Running);

    let stop = dispatcher
        .dispatch(LifecycleEvent::StopExecutionGroup("main".to_owned()))
        .unwrap()
        .effect
        .unwrap();
    assert_eq!(stop.origin(), EffectOrigin::RunningExecutionGroupStop);
    assert_eq!(
        stop.target(),
        EffectTarget::ExecutionGroup("main".to_owned())
    );
    assert!(dispatcher
        .dispatch(LifecycleEvent::StopExecutionGroup("main".to_owned()))
        .is_err());

    let mut wrong_group = LifecycleEffectResult::from_effect(&stop, Ok(()));
    wrong_group.target = EffectTarget::ExecutionGroup("other".to_owned());
    assert!(dispatcher
        .dispatch(LifecycleEvent::EffectCompleted(wrong_group))
        .is_err());
    assert_eq!(dispatcher.pending_effect(), Some(&stop));
    complete(&mut dispatcher, &stop, Ok(()));
    assert_eq!(dispatcher.state(), LifecycleState::Running);
    assert_eq!(
        dispatcher.execution_group_states()["main"],
        ExecutionGroupState::Stopped
    );
    assert!(dispatcher
        .dispatch(LifecycleEvent::StopExecutionGroup("main".to_owned()))
        .is_err());
}

#[test]
fn group_failures_fault_and_retry_restores_stopped_groups() {
    for start_failure in [false, true] {
        let mut dispatcher = LifecycleDispatcher::new();
        load_ready(&mut dispatcher);
        start_running(&mut dispatcher);
        let stop = dispatcher
            .dispatch(LifecycleEvent::StopExecutionGroup("main".to_owned()))
            .unwrap()
            .effect
            .unwrap();
        if start_failure {
            complete(&mut dispatcher, &stop, Ok(()));
            let start = dispatcher
                .dispatch(LifecycleEvent::StartExecutionGroup("main".to_owned()))
                .unwrap()
                .effect
                .unwrap();
            assert_eq!(
                complete(
                    &mut dispatcher,
                    &start,
                    Err(ScientificDiagnostic::new(
                        "execution-group main",
                        "start failed"
                    )),
                ),
                LifecycleState::Fault
            );
        } else {
            assert_eq!(
                complete(
                    &mut dispatcher,
                    &stop,
                    Err(ScientificDiagnostic::new(
                        "execution-group main",
                        "stop failed"
                    )),
                ),
                LifecycleState::Fault
            );
        }
        let retry = dispatcher.dispatch(LifecycleEvent::Retry).unwrap();
        complete(&mut dispatcher, &retry.effect.unwrap(), Ok(()));
        assert_eq!(dispatcher.state(), LifecycleState::Ready);
        assert_eq!(
            dispatcher.execution_group_states()["main"],
            ExecutionGroupState::Stopped
        );
    }
}

#[test]
fn session_stop_or_unload_supersedes_pending_group_work() {
    for unload in [false, true] {
        let mut dispatcher = LifecycleDispatcher::new();
        load_ready(&mut dispatcher);
        start_running(&mut dispatcher);
        let group = dispatcher
            .dispatch(LifecycleEvent::StopExecutionGroup("main".to_owned()))
            .unwrap()
            .effect
            .unwrap();
        let superseding = dispatcher
            .dispatch(if unload {
                LifecycleEvent::Unload
            } else {
                LifecycleEvent::Stop
            })
            .unwrap()
            .effect
            .unwrap();
        assert!(dispatcher
            .dispatch(LifecycleEvent::EffectCompleted(
                LifecycleEffectResult::from_effect(&group, Ok(())),
            ))
            .is_err());
        assert_eq!(
            complete(&mut dispatcher, &superseding, Ok(())),
            if unload {
                LifecycleState::Offline
            } else {
                LifecycleState::Ready
            }
        );
    }
}

#[test]
fn required_object_failure_supersedes_pending_group_work() {
    let mut dispatcher = LifecycleDispatcher::new();
    load_ready(&mut dispatcher);
    start_running(&mut dispatcher);
    let group = dispatcher
        .dispatch(LifecycleEvent::StopExecutionGroup("main".to_owned()))
        .unwrap()
        .effect
        .unwrap();

    let outcome = dispatcher
        .dispatch(LifecycleEvent::RequiredObjectFailed(
            ScientificDiagnostic::new("graph minimal", "required object disappeared"),
        ))
        .expect("required-object failure supersedes group work");
    assert_eq!(outcome.state, LifecycleState::Fault);
    assert!(outcome.effect.is_none());
    assert!(dispatcher.pending_effect().is_none());
    assert!(dispatcher
        .dispatch(LifecycleEvent::EffectCompleted(
            LifecycleEffectResult::from_effect(&group, Ok(())),
        ))
        .is_err());
    assert_eq!(dispatcher.state(), LifecycleState::Fault);
}

#[test]
fn unload_invalidates_pending_transition_and_rejects_its_late_completion() {
    let mut dispatcher = LifecycleDispatcher::new();
    let realize = dispatcher
        .dispatch(LifecycleEvent::Load(config().into()))
        .unwrap()
        .effect
        .unwrap();
    let cleanup = dispatcher
        .dispatch(LifecycleEvent::Unload)
        .unwrap()
        .effect
        .unwrap();
    assert_ne!(realize.token(), cleanup.token());
    assert!(dispatcher
        .dispatch(LifecycleEvent::EffectCompleted(
            LifecycleEffectResult::from_effect(&realize, Ok(())),
        ))
        .is_err());
    assert_eq!(dispatcher.state(), LifecycleState::Configuring);
    assert_eq!(
        complete(&mut dispatcher, &cleanup, Ok(())),
        LifecycleState::Offline
    );
}

#[derive(Default)]
struct RecordingExecutor {
    effects: Vec<(EffectKind, u64)>,
}

impl EffectExecutor for RecordingExecutor {
    fn execute(
        &mut self,
        effect: &LifecycleEffect,
    ) -> Result<LifecycleEffectSuccess, ScientificDiagnostic> {
        self.effects.push((effect.kind(), effect.token().value()));
        Ok(LifecycleEffectSuccess::Completed)
    }
}

#[test]
fn blocking_effects_execute_after_handlers_return_and_repeated_cycles_are_clean() {
    let mut runner = Runner::new(RecordingExecutor::default());
    for _ in 0..3 {
        assert_eq!(
            runner
                .dispatch(LifecycleEvent::Load(config().into()))
                .unwrap(),
            LifecycleState::Ready
        );
        assert_eq!(
            runner.dispatch(LifecycleEvent::Start).unwrap(),
            LifecycleState::Running
        );
        assert_eq!(
            runner
                .dispatch(LifecycleEvent::StopExecutionGroup("main".to_owned()))
                .unwrap(),
            LifecycleState::Running
        );
        assert_eq!(
            runner
                .dispatch(LifecycleEvent::StartExecutionGroup("main".to_owned()))
                .unwrap(),
            LifecycleState::Running
        );
        assert_eq!(
            runner.dispatch(LifecycleEvent::Stop).unwrap(),
            LifecycleState::Ready
        );
        assert_eq!(
            runner.dispatch(LifecycleEvent::Unload).unwrap(),
            LifecycleState::Offline
        );
    }
    assert_eq!(runner.executor().effects.len(), 18);
    assert!(runner
        .executor()
        .effects
        .windows(2)
        .all(|pair| pair[0].1 < pair[1].1));
}
