use pipewireao_rtc::calibration::{
    acquire_calibration, AcquisitionCursor, CalibrationAction, CalibrationCompletion,
    CalibrationCoordinator, CalibrationEffect, CalibrationEndpoint, CalibrationEvidence,
    CalibrationFailure, CalibrationPhase, CalibrationPlan, CalibrationRequest, CalibrationTimeouts,
    Exposure, ResponseBatch, SettlingRule,
};
use std::sync::Arc;
use std::time::{Duration, Instant};

fn timeouts() -> CalibrationTimeouts {
    CalibrationTimeouts {
        ownership: Duration::from_secs(10),
        adoption: Duration::from_secs(20),
        settling: Duration::from_secs(30),
        collection: Duration::from_secs(40),
        restoration: Duration::from_secs(50),
    }
}

fn plan(rule: SettlingRule) -> CalibrationPlan {
    CalibrationPlan::new(
        Arc::from([0.0, 0.0]),
        vec![Arc::from([1.0, 0.0]), Arc::from([0.0, 1.0])],
        2,
        2,
        rule,
        timeouts(),
    )
    .unwrap()
}

fn cursor() -> AcquisitionCursor {
    AcquisitionCursor {
        domain: 7,
        generation: 3,
        sequence: 10,
        model_ns: 100,
    }
}

fn batch(after: AcquisitionCursor, frames: usize) -> ResponseBatch {
    ResponseBatch {
        values: vec![2.0, 3.0],
        exposures: (0..frames)
            .map(|index| Exposure {
                domain: after.domain,
                generation: after.generation,
                sequence: after.sequence + u64::try_from(index).unwrap() + 1,
                start_model_ns: after.model_ns + u64::try_from(index).unwrap() * 10,
                duration_ns: 10,
            })
            .collect(),
        valid: true,
    }
}

fn evidence(effect: &CalibrationEffect, current: &mut AcquisitionCursor) -> CalibrationEvidence {
    match &effect.action {
        CalibrationAction::Hold => CalibrationEvidence::Held(*current),
        CalibrationAction::Adopt { figure, .. } => CalibrationEvidence::Adopted {
            cursor: *current,
            figure: Arc::clone(figure),
            clipped: false,
        },
        CalibrationAction::Settle { after, rule, .. } => {
            *current = *after;
            match rule {
                SettlingRule::Immediate => {}
                SettlingRule::DiscardExposures(count) => {
                    current.sequence += u64::from(*count);
                    current.model_ns += u64::from(*count) * 10;
                }
                SettlingRule::ModelTime(duration) => {
                    current.sequence += 1;
                    current.model_ns += u64::try_from(duration.as_nanos()).unwrap();
                }
            }
            CalibrationEvidence::Settled(*current)
        }
        CalibrationAction::Collect { after, frames, .. } => {
            let response = batch(*after, *frames);
            let last = response.exposures.last().unwrap();
            current.sequence = last.sequence;
            current.model_ns = last.start_model_ns + last.duration_ns;
            CalibrationEvidence::Responses(response)
        }
        CalibrationAction::Restore { figure, .. } => CalibrationEvidence::Restored {
            figure: Arc::clone(figure),
            clipped: false,
        },
        CalibrationAction::Release => CalibrationEvidence::Released,
    }
}

fn complete(
    coordinator: &mut CalibrationCoordinator,
    effect: &CalibrationEffect,
    result: Result<CalibrationEvidence, CalibrationFailure>,
    now: Instant,
) -> Option<CalibrationEffect> {
    coordinator
        .complete(
            CalibrationCompletion {
                request: effect.request,
                result,
            },
            now,
        )
        .unwrap()
}

fn reach(
    phase: CalibrationPhase,
    rule: SettlingRule,
    now: Instant,
) -> (CalibrationCoordinator, CalibrationEffect) {
    let (mut coordinator, mut effect) = CalibrationCoordinator::begin(11, plan(rule), now).unwrap();
    let mut current = cursor();
    while coordinator.phase() != phase {
        let result = evidence(&effect, &mut current);
        effect = complete(&mut coordinator, &effect, Ok(result), now).unwrap();
    }
    (coordinator, effect)
}

fn recover(coordinator: &mut CalibrationCoordinator, restore: &CalibrationEffect, now: Instant) {
    assert_eq!(coordinator.phase(), CalibrationPhase::Restoring);
    assert!(!coordinator.restoration_confirmed());
    assert!(!coordinator.resume_permitted());
    assert!(coordinator.responses().is_none());
    let restored = evidence(restore, &mut cursor());
    let release = complete(coordinator, restore, Ok(restored), now).unwrap();
    assert!(matches!(release.action, CalibrationAction::Release));
    assert!(coordinator.restoration_confirmed());
    assert!(!coordinator.resume_permitted());
    assert!(coordinator.responses().is_none());
    assert!(complete(
        coordinator,
        &release,
        Ok(CalibrationEvidence::Released),
        now
    )
    .is_none());
    assert_eq!(coordinator.phase(), CalibrationPhase::Aborted);
    assert!(coordinator.resume_permitted());
    assert!(coordinator.responses().is_none());
}

#[test]
fn two_probes_publish_responses_only_after_restoration_and_release() {
    let base = Instant::now();
    let (mut coordinator, mut effect) =
        CalibrationCoordinator::begin(11, plan(SettlingRule::Immediate), base).unwrap();
    let mut current = cursor();
    let mut probes = Vec::new();
    let mut step = 0;
    loop {
        assert!(coordinator.responses().is_none());
        assert!(!coordinator.resume_permitted());
        assert_eq!(
            coordinator.pending_effect().unwrap().request,
            effect.request
        );
        assert_eq!(coordinator.deadline(), Some(effect.deadline));
        if let CalibrationAction::Adopt { probe, figure } = &effect.action {
            probes.push(*probe);
            assert_eq!(figure.len(), 2);
        }
        if matches!(effect.action, CalibrationAction::Release) {
            assert!(coordinator.restoration_confirmed());
        } else {
            assert!(!coordinator.restoration_confirmed());
        }
        step += 1;
        let result = evidence(&effect, &mut current);
        let Some(next) = complete(
            &mut coordinator,
            &effect,
            Ok(result),
            base + Duration::from_millis(step),
        ) else {
            break;
        };
        assert_eq!(next.request.run, 11);
        assert_eq!(next.request.serial, effect.request.serial + 1);
        effect = next;
    }
    assert_eq!(probes, [0, 1]);
    assert_eq!(coordinator.phase(), CalibrationPhase::Complete);
    assert!(coordinator.resume_permitted());
    assert!(coordinator.restoration_confirmed());
    assert!(coordinator.failure().is_none());
    let responses = coordinator.responses().unwrap();
    assert_eq!(responses.len(), 2);
    assert_eq!(responses[0].values, [2.0, 3.0]);
    assert_eq!(responses[0].exposures[0].sequence, 11);
    assert_eq!(responses[1].exposures[0].sequence, 13);
    assert!(coordinator.pending_effect().is_none());
    assert!(coordinator.deadline().is_none());
    assert!(coordinator.cancel(base).is_none());
    assert_eq!(coordinator.phase(), CalibrationPhase::Complete);
    assert!(coordinator.failure().is_none());
    assert!(coordinator
        .complete(
            CalibrationCompletion {
                request: effect.request,
                result: Ok(CalibrationEvidence::Released)
            },
            base
        )
        .is_err());
}

#[test]
fn unrelated_duplicate_and_wrong_kind_events_preserve_pending_deadline() {
    let now = Instant::now();
    for phase in [
        CalibrationPhase::Holding,
        CalibrationPhase::Adopting,
        CalibrationPhase::Settling,
        CalibrationPhase::Collecting,
        CalibrationPhase::Restoring,
        CalibrationPhase::Releasing,
    ] {
        let (mut coordinator, effect) = reach(phase, SettlingRule::Immediate, now);
        let deadline = coordinator.deadline();
        for request in [
            CalibrationRequest {
                run: 12,
                serial: effect.request.serial,
            },
            CalibrationRequest {
                run: 11,
                serial: effect.request.serial + 1,
            },
            CalibrationRequest {
                run: 11,
                serial: effect.request.serial - 1,
            },
        ] {
            let result = evidence(&effect, &mut cursor());
            assert!(coordinator
                .complete(
                    CalibrationCompletion {
                        request,
                        result: Ok(result)
                    },
                    now + Duration::from_millis(1)
                )
                .is_err());
            assert_eq!(coordinator.phase(), phase);
            assert_eq!(coordinator.deadline(), deadline);
            assert_eq!(
                coordinator.pending_effect().unwrap().request,
                effect.request
            );
        }
        let wrong_kind = if phase == CalibrationPhase::Releasing {
            CalibrationEvidence::Held(cursor())
        } else {
            CalibrationEvidence::Released
        };
        assert!(coordinator
            .complete(
                CalibrationCompletion {
                    request: effect.request,
                    result: Ok(wrong_kind)
                },
                now + Duration::from_millis(1)
            )
            .is_err());
        assert_eq!(coordinator.phase(), phase);
        assert_eq!(coordinator.deadline(), deadline);
        assert!(coordinator.failure().is_none());
    }
}

#[test]
fn clipped_wrong_or_unrelated_adoption_requires_reference_restoration() {
    let now = Instant::now();
    for case in 0..6 {
        let (mut coordinator, effect) =
            reach(CalibrationPhase::Adopting, SettlingRule::Immediate, now);
        let mut adopted = cursor();
        let mut figure: Arc<[f32]> = Arc::from([1.0, 0.0]);
        match case {
            1 => figure = Arc::from([9.0, 0.0]),
            2 => adopted.generation += 1,
            3 => adopted.domain += 1,
            4 => adopted.sequence -= 1,
            5 => adopted.model_ns -= 1,
            _ => {}
        }
        let restore = complete(
            &mut coordinator,
            &effect,
            Ok(CalibrationEvidence::Adopted {
                cursor: adopted,
                figure,
                clipped: case == 0,
            }),
            now,
        )
        .unwrap();
        assert_eq!(
            coordinator.failure(),
            Some(if case == 0 {
                CalibrationFailure::ProbeClipped
            } else {
                CalibrationFailure::InvalidEvidence
            })
        );
        recover(&mut coordinator, &restore, now);
    }
}

#[test]
fn response_batches_require_exact_finite_post_settling_exposures() {
    let now = Instant::now();
    for case in 0..14 {
        let (mut coordinator, effect) =
            reach(CalibrationPhase::Collecting, SettlingRule::Immediate, now);
        let mut response = batch(cursor(), 2);
        match case {
            0 => response.valid = false,
            1 => response.values[0] = f32::NAN,
            2 => response.values[0] = f32::INFINITY,
            3 => response.values.clear(),
            4 => response.values.push(4.0),
            5 => response.exposures.truncate(1),
            6 => response.exposures.push(response.exposures[1]),
            7 => response.exposures[0].start_model_ns -= 1,
            8 => response.exposures[0].sequence -= 1,
            9 => response.exposures[1].sequence = response.exposures[0].sequence,
            10 => response.exposures[1].sequence += 1,
            11 => response.exposures[0].generation += 1,
            12 => response.exposures[0].domain += 1,
            13 => response.exposures[0].duration_ns = 0,
            _ => unreachable!(),
        }
        let restore = complete(
            &mut coordinator,
            &effect,
            Ok(CalibrationEvidence::Responses(response)),
            now,
        )
        .unwrap();
        assert_eq!(
            coordinator.failure(),
            Some(CalibrationFailure::InvalidEvidence),
            "case {case}"
        );
        recover(&mut coordinator, &restore, now);
    }
}

#[test]
fn overlapping_overflowing_and_oversized_capacity_batches_are_rejected() {
    let now = Instant::now();
    for case in 0..3 {
        let (mut coordinator, effect) =
            reach(CalibrationPhase::Collecting, SettlingRule::Immediate, now);
        let mut response = batch(cursor(), 2);
        match case {
            0 => response.exposures[1].start_model_ns -= 1,
            1 => response.exposures[1].start_model_ns = u64::MAX,
            2 => {
                let mut values =
                    Vec::with_capacity(512 * 1024 * 1024 / std::mem::size_of::<f32>() + 1);
                values.extend_from_slice(&response.values);
                response.values = values;
            }
            _ => unreachable!(),
        }
        let restore = complete(
            &mut coordinator,
            &effect,
            Ok(CalibrationEvidence::Responses(response)),
            now,
        )
        .unwrap();
        assert_eq!(
            coordinator.failure(),
            Some(CalibrationFailure::InvalidEvidence)
        );
        recover(&mut coordinator, &restore, now);
    }
}

#[test]
fn settling_uses_declared_model_time_or_exact_discard_count() {
    let now = Instant::now();
    for rule in [
        SettlingRule::Immediate,
        SettlingRule::DiscardExposures(2),
        SettlingRule::DiscardExposures(u32::MAX),
        SettlingRule::ModelTime(Duration::from_nanos(20)),
    ] {
        let (mut coordinator, effect) = reach(CalibrationPhase::Settling, rule, now);
        let settled = evidence(&effect, &mut cursor());
        let collect = complete(&mut coordinator, &effect, Ok(settled), now).unwrap();
        assert!(matches!(collect.action, CalibrationAction::Collect { .. }));
    }
    for rule in [
        SettlingRule::DiscardExposures(2),
        SettlingRule::ModelTime(Duration::from_nanos(20)),
    ] {
        for extra in [false, true] {
            let (mut coordinator, effect) = reach(CalibrationPhase::Settling, rule, now);
            let mut settled = cursor();
            match rule {
                SettlingRule::DiscardExposures(_) => settled.sequence += if extra { 3 } else { 1 },
                SettlingRule::ModelTime(_) => {
                    settled.model_ns += 19;
                    if extra {
                        settled.generation += 1;
                    }
                }
                SettlingRule::Immediate => unreachable!(),
            }
            let restore = complete(
                &mut coordinator,
                &effect,
                Ok(CalibrationEvidence::Settled(settled)),
                now,
            )
            .unwrap();
            assert!(matches!(restore.action, CalibrationAction::Restore { .. }));
            assert_eq!(
                coordinator.failure(),
                Some(CalibrationFailure::InvalidEvidence)
            );
        }
    }
}

#[test]
fn acquisition_deadlines_restore_and_recovery_deadlines_fault() {
    let now = Instant::now();
    for phase in [
        CalibrationPhase::Holding,
        CalibrationPhase::Adopting,
        CalibrationPhase::Settling,
        CalibrationPhase::Collecting,
    ] {
        let (mut coordinator, _) = reach(phase, SettlingRule::Immediate, now);
        let deadline = coordinator.deadline().unwrap();
        assert!(coordinator
            .expire(deadline.checked_sub(Duration::from_nanos(1)).unwrap())
            .is_none());
        let restore = coordinator.expire(deadline).unwrap();
        assert_eq!(
            coordinator.failure(),
            Some(CalibrationFailure::TimedOut(phase))
        );
        recover(&mut coordinator, &restore, deadline);
    }
    for phase in [CalibrationPhase::Restoring, CalibrationPhase::Releasing] {
        let (mut coordinator, _) = reach(phase, SettlingRule::Immediate, now);
        assert!(coordinator
            .expire(coordinator.deadline().unwrap())
            .is_none());
        assert_eq!(coordinator.phase(), CalibrationPhase::Fault);
        assert_eq!(
            coordinator.recovery_failure(),
            Some(CalibrationFailure::TimedOut(phase))
        );
        assert_eq!(
            coordinator.restoration_confirmed(),
            phase == CalibrationPhase::Releasing
        );
        assert!(!coordinator.resume_permitted());
        assert!(coordinator.pending_effect().is_none());
        assert!(coordinator.responses().is_none());
    }
}

#[test]
fn current_completion_at_deadline_cannot_complete_acquisition() {
    let now = Instant::now();
    let (mut coordinator, effect) =
        reach(CalibrationPhase::Collecting, SettlingRule::Immediate, now);
    let deadline = coordinator.deadline().unwrap();
    let restore = complete(
        &mut coordinator,
        &effect,
        Ok(CalibrationEvidence::Responses(batch(cursor(), 2))),
        deadline,
    )
    .unwrap();
    assert!(matches!(restore.action, CalibrationAction::Restore { .. }));
    assert_eq!(
        coordinator.failure(),
        Some(CalibrationFailure::TimedOut(CalibrationPhase::Collecting))
    );
}

#[test]
fn cancellation_is_idempotent_and_preserves_recovery_barriers() {
    let now = Instant::now();
    let (mut coordinator, _) = reach(CalibrationPhase::Collecting, SettlingRule::Immediate, now);
    let restore = coordinator.cancel(now).unwrap();
    let deadline = coordinator.deadline();
    assert!(coordinator.cancel(now + Duration::from_millis(1)).is_none());
    assert_eq!(coordinator.deadline(), deadline);
    assert_eq!(
        coordinator.pending_effect().unwrap().request,
        restore.request
    );
    let restored = evidence(&restore, &mut cursor());
    let release = complete(&mut coordinator, &restore, Ok(restored), now).unwrap();
    let deadline = coordinator.deadline();
    assert!(coordinator.cancel(now + Duration::from_millis(2)).is_none());
    assert_eq!(coordinator.deadline(), deadline);
    assert_eq!(
        coordinator.pending_effect().unwrap().request,
        release.request
    );
    assert!(!coordinator.resume_permitted());
    assert!(complete(
        &mut coordinator,
        &release,
        Ok(CalibrationEvidence::Released),
        now
    )
    .is_none());
    assert_eq!(coordinator.phase(), CalibrationPhase::Aborted);
    assert_eq!(coordinator.failure(), Some(CalibrationFailure::Cancelled));
    assert!(coordinator.restoration_confirmed());
    assert!(coordinator.resume_permitted());
}

#[test]
fn cancellation_before_settling_preserves_the_declared_restoration_rule() {
    let now = Instant::now();
    for phase in [CalibrationPhase::Holding, CalibrationPhase::Adopting] {
        for rule in [
            SettlingRule::Immediate,
            SettlingRule::DiscardExposures(2),
            SettlingRule::ModelTime(Duration::from_nanos(20)),
        ] {
            let (mut coordinator, pending) = reach(phase, rule, now);
            assert!(matches!(
                pending.action,
                CalibrationAction::Hold | CalibrationAction::Adopt { .. }
            ));
            let restore = coordinator.cancel(now).unwrap();
            let CalibrationAction::Restore {
                figure,
                rule: restoration_rule,
            } = &restore.action
            else {
                panic!("cancellation must request restoration");
            };
            assert_eq!(*restoration_rule, rule);
            assert_eq!(figure.as_ref(), [0.0, 0.0]);
            assert_eq!(restore.deadline, now + timeouts().restoration);
            assert_eq!(coordinator.failure(), Some(CalibrationFailure::Cancelled));
            recover(&mut coordinator, &restore, now);
        }
    }
}

#[test]
fn held_sequence_zero_is_valid_but_unadvanceable_or_overflowing_cursors_restore() {
    let now = Instant::now();
    for sequence in [0, u64::MAX] {
        let (mut coordinator, ownership) =
            CalibrationCoordinator::begin(11, plan(SettlingRule::Immediate), now).unwrap();
        let held = AcquisitionCursor {
            sequence,
            ..cursor()
        };
        let next = complete(
            &mut coordinator,
            &ownership,
            Ok(CalibrationEvidence::Held(held)),
            now,
        )
        .unwrap();
        if sequence == 0 {
            assert!(matches!(next.action, CalibrationAction::Adopt { .. }));
            assert!(coordinator.failure().is_none());
        } else {
            assert!(matches!(next.action, CalibrationAction::Restore { .. }));
            assert_eq!(
                coordinator.failure(),
                Some(CalibrationFailure::InvalidEvidence)
            );
        }
    }

    for model_overflow in [false, true] {
        let rule = if model_overflow {
            SettlingRule::ModelTime(Duration::from_nanos(20))
        } else {
            SettlingRule::Immediate
        };
        let (mut coordinator, mut effect) =
            CalibrationCoordinator::begin(11, plan(rule), now).unwrap();
        let mut current = if model_overflow {
            AcquisitionCursor {
                model_ns: u64::MAX - 10,
                ..cursor()
            }
        } else {
            AcquisitionCursor {
                sequence: u64::MAX - 2,
                ..cursor()
            }
        };
        for _ in 0..2 {
            let result = evidence(&effect, &mut current);
            effect = complete(&mut coordinator, &effect, Ok(result), now).unwrap();
        }
        let restore = if model_overflow {
            let settled = AcquisitionCursor {
                model_ns: u64::MAX,
                ..current
            };
            complete(
                &mut coordinator,
                &effect,
                Ok(CalibrationEvidence::Settled(settled)),
                now,
            )
            .unwrap()
        } else {
            effect = complete(
                &mut coordinator,
                &effect,
                Ok(CalibrationEvidence::Settled(current)),
                now,
            )
            .unwrap();
            complete(
                &mut coordinator,
                &effect,
                Ok(CalibrationEvidence::Responses(batch(current, 2))),
                now,
            )
            .unwrap()
        };
        assert!(matches!(restore.action, CalibrationAction::Restore { .. }));
        assert_eq!(
            coordinator.failure(),
            Some(CalibrationFailure::InvalidEvidence)
        );
        assert!(!coordinator.resume_permitted());
    }
}

#[test]
fn incorrect_or_clipped_reference_restoration_faults_without_release() {
    let now = Instant::now();
    for clipped in [false, true] {
        let (mut coordinator, effect) =
            reach(CalibrationPhase::Restoring, SettlingRule::Immediate, now);
        let figure = if clipped {
            Arc::from([0.0, 0.0])
        } else {
            Arc::from([1.0, 0.0])
        };
        assert!(complete(
            &mut coordinator,
            &effect,
            Ok(CalibrationEvidence::Restored { figure, clipped }),
            now
        )
        .is_none());
        assert_eq!(coordinator.phase(), CalibrationPhase::Fault);
        assert!(!coordinator.restoration_confirmed());
        assert!(!coordinator.resume_permitted());
        assert!(coordinator.pending_effect().is_none());
    }
}

fn kind(action: &CalibrationAction) -> &'static str {
    match action {
        CalibrationAction::Hold => "hold",
        CalibrationAction::Adopt { .. } => "adopt",
        CalibrationAction::Settle { .. } => "settle",
        CalibrationAction::Collect { .. } => "collect",
        CalibrationAction::Restore { .. } => "restore",
        CalibrationAction::Release => "release",
    }
}

struct SyntheticEndpoint {
    current: AcquisitionCursor,
    pending: Option<CalibrationEffect>,
    submitted: Vec<&'static str>,
    deadlines: Vec<Instant>,
    faults: Vec<CalibrationFailure>,
    submit_error: Option<&'static str>,
    receive_error: Option<&'static str>,
    early_none: bool,
    unrelated: u32,
}

impl SyntheticEndpoint {
    fn new() -> Self {
        Self {
            current: cursor(),
            pending: None,
            submitted: Vec::new(),
            deadlines: Vec::new(),
            faults: Vec::new(),
            submit_error: None,
            receive_error: None,
            early_none: false,
            unrelated: 0,
        }
    }
}

impl CalibrationEndpoint for SyntheticEndpoint {
    fn submit(&mut self, effect: &CalibrationEffect) -> Result<(), CalibrationFailure> {
        let name = kind(&effect.action);
        self.submitted.push(name);
        self.deadlines.push(effect.deadline);
        if self.submit_error == Some(name) {
            self.submit_error = None;
            return Err(CalibrationFailure::Endpoint);
        }
        self.pending = Some(effect.clone());
        Ok(())
    }

    fn receive(
        &mut self,
        deadline: Instant,
    ) -> Result<Option<CalibrationCompletion>, CalibrationFailure> {
        let effect = self.pending.as_ref().unwrap();
        assert_eq!(deadline, effect.deadline);
        if self.receive_error == Some(kind(&effect.action)) {
            self.receive_error = None;
            return Err(CalibrationFailure::Endpoint);
        }
        if self.early_none {
            self.early_none = false;
            return Ok(None);
        }
        if self.unrelated > 0 {
            self.unrelated -= 1;
            return Ok(Some(CalibrationCompletion {
                request: CalibrationRequest {
                    run: effect.request.run + 1,
                    serial: effect.request.serial,
                },
                result: Ok(CalibrationEvidence::Held(self.current)),
            }));
        }
        let effect = self.pending.take().unwrap();
        Ok(Some(CalibrationCompletion {
            request: effect.request,
            result: Ok(evidence(&effect, &mut self.current)),
        }))
    }

    fn fault(&mut self, failure: CalibrationFailure) {
        self.faults.push(failure);
    }
}

#[test]
fn synchronous_driver_uses_typed_completions_without_sleep_or_poll_success() {
    let mut endpoint = SyntheticEndpoint::new();
    let coordinator =
        acquire_calibration(&mut endpoint, 11, plan(SettlingRule::Immediate)).unwrap();
    assert_eq!(coordinator.phase(), CalibrationPhase::Complete);
    assert_eq!(coordinator.responses().unwrap().len(), 2);
    assert_eq!(
        endpoint.submitted,
        [
            "hold", "adopt", "settle", "collect", "adopt", "settle", "collect", "restore",
            "release"
        ]
    );
    assert!(endpoint.faults.is_empty());
}

#[test]
fn synchronous_submit_and_receive_errors_restore_without_retrying_work() {
    for operation in ["hold", "adopt", "settle", "collect"] {
        for submitting in [false, true] {
            let mut endpoint = SyntheticEndpoint::new();
            if submitting {
                endpoint.submit_error = Some(operation);
            } else {
                endpoint.receive_error = Some(operation);
            }
            let coordinator =
                acquire_calibration(&mut endpoint, 11, plan(SettlingRule::Immediate)).unwrap();
            assert_eq!(coordinator.phase(), CalibrationPhase::Aborted);
            assert_eq!(coordinator.failure(), Some(CalibrationFailure::Endpoint));
            assert!(coordinator.restoration_confirmed());
            assert!(coordinator.resume_permitted());
            assert!(coordinator.responses().is_none());
            assert_eq!(
                endpoint
                    .submitted
                    .iter()
                    .filter(|name| **name == operation)
                    .count(),
                1
            );
            assert_eq!(
                &endpoint.submitted[endpoint.submitted.len() - 2..],
                ["restore", "release"]
            );
            assert!(endpoint.faults.is_empty());
        }
    }
}

#[test]
fn synchronous_recovery_errors_fault_before_returning_and_keep_hold() {
    for operation in ["restore", "release"] {
        for submitting in [false, true] {
            let mut endpoint = SyntheticEndpoint::new();
            if submitting {
                endpoint.submit_error = Some(operation);
            } else {
                endpoint.receive_error = Some(operation);
            }
            let coordinator =
                acquire_calibration(&mut endpoint, 11, plan(SettlingRule::Immediate)).unwrap();
            assert_eq!(coordinator.phase(), CalibrationPhase::Fault);
            assert_eq!(coordinator.restoration_confirmed(), operation == "release");
            assert_eq!(
                coordinator.recovery_failure(),
                Some(CalibrationFailure::Endpoint)
            );
            assert!(!coordinator.resume_permitted());
            assert!(coordinator.responses().is_none());
            assert_eq!(endpoint.faults, [CalibrationFailure::Endpoint]);
            if operation == "restore" {
                assert!(!endpoint.submitted.contains(&"release"));
            }
        }
    }
}

#[test]
fn synchronous_early_expiration_or_bounded_unrelated_events_require_recovery() {
    for early_none in [false, true] {
        let mut endpoint = SyntheticEndpoint::new();
        endpoint.early_none = early_none;
        endpoint.unrelated = if early_none { 0 } else { 64 };
        let coordinator =
            acquire_calibration(&mut endpoint, 11, plan(SettlingRule::Immediate)).unwrap();
        assert_eq!(coordinator.phase(), CalibrationPhase::Aborted);
        assert_eq!(
            coordinator.failure(),
            Some(CalibrationFailure::InvalidEvidence)
        );
        assert_eq!(endpoint.submitted, ["hold", "restore", "release"]);
        assert!(endpoint.faults.is_empty());
    }
}

#[test]
fn invalid_figures_dimensions_cardinalities_and_retained_sizes_reject_plans() {
    let reference: Arc<[f32]> = Arc::from([0.0, 0.0]);
    let probe: Arc<[f32]> = Arc::from([1.0, 0.0]);
    for (reference, probes, measurements, frames) in [
        (Arc::from([]), vec![Arc::clone(&probe)], 2, 2),
        (Arc::clone(&reference), vec![], 2, 2),
        (Arc::from([f32::NAN, 0.0]), vec![Arc::clone(&probe)], 2, 2),
        (
            Arc::from([f32::INFINITY, 0.0]),
            vec![Arc::clone(&probe)],
            2,
            2,
        ),
        (
            Arc::clone(&reference),
            vec![Arc::from([f32::NAN, 0.0])],
            2,
            2,
        ),
        (Arc::clone(&reference), vec![Arc::from([1.0])], 2, 2),
        (Arc::clone(&reference), vec![Arc::clone(&probe)], 0, 2),
        (Arc::clone(&reference), vec![Arc::clone(&probe)], 2, 0),
        (Arc::clone(&reference), vec![Arc::clone(&probe)], 2, 4097),
        (
            Arc::clone(&reference),
            vec![Arc::clone(&probe)],
            usize::MAX,
            2,
        ),
        (
            Arc::clone(&reference),
            vec![Arc::clone(&probe)],
            512 * 1024 * 1024 / 4,
            2,
        ),
        (
            Arc::clone(&reference),
            vec![Arc::clone(&probe); 16_385],
            2,
            2,
        ),
    ] {
        assert!(CalibrationPlan::new(
            reference,
            probes,
            measurements,
            frames,
            SettlingRule::Immediate,
            timeouts()
        )
        .is_err());
    }
}

#[test]
fn oversized_plan_probe_spare_capacity_is_rejected_without_touching_spare_storage() {
    let mut probes = Vec::with_capacity(512 * 1024 * 1024 / std::mem::size_of::<Arc<[f32]>>() + 1);
    probes.push(Arc::from([1.0, 0.0]));
    assert!(CalibrationPlan::new(
        Arc::from([0.0, 0.0]),
        probes,
        2,
        2,
        SettlingRule::Immediate,
        timeouts(),
    )
    .is_err());
}

#[test]
fn invalid_timeouts_settling_ranges_and_run_identity_reject_before_submission() {
    for invalid in [Duration::ZERO, Duration::MAX] {
        for field in 0..5 {
            let mut limits = timeouts();
            match field {
                0 => limits.ownership = invalid,
                1 => limits.adoption = invalid,
                2 => limits.settling = invalid,
                3 => limits.collection = invalid,
                4 => limits.restoration = invalid,
                _ => unreachable!(),
            }
            assert!(CalibrationPlan::new(
                Arc::from([0.0]),
                vec![Arc::from([1.0])],
                1,
                1,
                SettlingRule::Immediate,
                limits
            )
            .is_err());
        }
    }
    for rule in [
        SettlingRule::DiscardExposures(0),
        SettlingRule::ModelTime(Duration::ZERO),
        SettlingRule::ModelTime(Duration::MAX),
    ] {
        assert!(CalibrationPlan::new(
            Arc::from([0.0]),
            vec![Arc::from([1.0])],
            1,
            1,
            rule,
            timeouts()
        )
        .is_err());
    }
    let mut endpoint = SyntheticEndpoint::new();
    assert!(acquire_calibration(&mut endpoint, 0, plan(SettlingRule::Immediate)).is_err());
    assert!(endpoint.submitted.is_empty());
    assert!(
        CalibrationCoordinator::begin(0, plan(SettlingRule::Immediate), Instant::now()).is_err()
    );
}
