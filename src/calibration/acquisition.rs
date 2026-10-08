//! Completion-driven calibration acquisition outside scientific frame callbacks.
//!
//! This module coordinates prepared probes and measured response batches. It
//! neither computes calibration matrices nor implements an instrument adapter.
//! Endpoint evidence must come from the operational DM/WFS paths (RTC-DEV-029).

use std::fmt;
use std::mem::size_of;
use std::sync::Arc;
use std::time::{Duration, Instant};

const MAX_PROBES: usize = 16_384;
const MAX_FRAMES_PER_PROBE: usize = 4096;
const MAX_RECORD_BYTES: usize = 512 * 1024 * 1024;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SettlingRule {
    Immediate,
    DiscardExposures(u32),
    ModelTime(Duration),
}

#[derive(Clone, Copy, Debug)]
pub struct CalibrationTimeouts {
    pub ownership: Duration,
    pub adoption: Duration,
    pub settling: Duration,
    pub collection: Duration,
    pub restoration: Duration,
}

/// Prepared by the scientific calibration client, in declared DM units/order.
/// The reference figure is included in every supplied absolute probe figure.
#[derive(Debug)]
pub struct CalibrationPlan {
    reference: Arc<[f32]>,
    probes: Vec<Arc<[f32]>>,
    measurements: usize,
    frames_per_probe: usize,
    settling: SettlingRule,
    timeouts: CalibrationTimeouts,
    retained_bytes: usize,
}

impl CalibrationPlan {
    /// Validate finite figures, cardinalities, timeout ranges and retained size.
    ///
    /// # Errors
    /// Returns an error before ownership is requested for an invalid plan.
    pub fn new(
        reference: Arc<[f32]>,
        probes: Vec<Arc<[f32]>>,
        measurements: usize,
        frames_per_probe: usize,
        settling: SettlingRule,
        timeouts: CalibrationTimeouts,
    ) -> Result<Self, CalibrationError> {
        let invalid = || CalibrationError("invalid or oversized calibration plan");
        if reference.is_empty()
            || probes.is_empty()
            || probes.len() > MAX_PROBES
            || measurements == 0
            || !(1..=MAX_FRAMES_PER_PROBE).contains(&frames_per_probe)
        {
            return Err(invalid());
        }
        let commands = reference.len().checked_mul(probes.len() + 1);
        let batch_bytes = measurements
            .checked_mul(size_of::<f32>())
            .and_then(|bytes| {
                frames_per_probe
                    .checked_mul(size_of::<Exposure>())
                    .and_then(|frames| bytes.checked_add(frames))
            });
        // Charge retained capacities and container records, including spare
        // probe slots. Allocator headers/endpoint staging are outside this
        // payload-and-record budget; this is not a process RSS limit.
        let fixed_bytes = commands
            .and_then(|count| count.checked_mul(size_of::<f32>()))
            .and_then(|bytes| {
                probes
                    .capacity()
                    .checked_mul(size_of::<Arc<[f32]>>())
                    .and_then(|slots| bytes.checked_add(slots))
            })
            .and_then(|bytes| {
                probes
                    .len()
                    .checked_mul(size_of::<ResponseBatch>())
                    .and_then(|records| bytes.checked_add(records))
            });
        let retained = fixed_bytes.and_then(|bytes| {
            batch_bytes
                .and_then(|batch| batch.checked_mul(probes.len()))
                .and_then(|responses| bytes.checked_add(responses))
        });
        if retained.map_or(true, |bytes| bytes > MAX_RECORD_BYTES)
            || reference.iter().any(|value| !value.is_finite())
            || probes.iter().any(|probe| {
                probe.len() != reference.len() || probe.iter().any(|value| !value.is_finite())
            })
        {
            return Err(invalid());
        }
        let now = Instant::now();
        for timeout in [
            timeouts.ownership,
            timeouts.adoption,
            timeouts.settling,
            timeouts.collection,
            timeouts.restoration,
        ] {
            if timeout.is_zero() || now.checked_add(timeout).is_none() {
                return Err(CalibrationError(
                    "timeouts must be positive and representable",
                ));
            }
        }
        match settling {
            SettlingRule::DiscardExposures(0) => {
                return Err(CalibrationError("discard count must be positive"));
            }
            SettlingRule::ModelTime(duration)
                if duration.is_zero() || u64::try_from(duration.as_nanos()).is_err() =>
            {
                return Err(CalibrationError(
                    "model settling duration must fit nanoseconds",
                ));
            }
            _ => {}
        }
        Ok(Self {
            reference,
            probes,
            measurements,
            frames_per_probe,
            settling,
            timeouts,
            retained_bytes: fixed_bytes.ok_or_else(invalid)?,
        })
    }
}

/// Caller supplies a nonzero run identity unique over the endpoint's lifetime.
/// Request serials are allocated by one coordinator and never reused in a run.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CalibrationRequest {
    pub run: u64,
    pub serial: u64,
}

/// Last consumed exposure and eligibility boundary, all in declared model time.
/// Domain/generation match the endpoint's acquisition identity; sequence zero
/// denotes a held source before its first exposure. `model_ns` is an exposure
/// end or a later settling boundary, never a host receive timestamp.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct AcquisitionCursor {
    pub domain: u64,
    pub generation: u64,
    pub sequence: u64,
    pub model_ns: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Exposure {
    pub domain: u64,
    pub generation: u64,
    pub sequence: u64,
    pub start_model_ns: u64,
    pub duration_ns: u64,
}

/// Averaged deployed WFS measurements and the exact contributing exposures.
/// No frame pixel arrays are copied into the coordinator.
#[derive(Debug)]
pub struct ResponseBatch {
    pub values: Vec<f32>,
    pub exposures: Vec<Exposure>,
    pub valid: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CalibrationPhase {
    Holding,
    Adopting,
    Settling,
    Collecting,
    Restoring,
    Releasing,
    Complete,
    Aborted,
    Fault,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CalibrationFailure {
    Cancelled,
    TimedOut(CalibrationPhase),
    Endpoint,
    InvalidEvidence,
    ProbeClipped,
}

#[derive(Clone, Debug)]
pub enum CalibrationAction {
    /// Establish exclusive commands, hold integration, and quiesce prior work.
    Hold,
    Adopt {
        probe: usize,
        figure: Arc<[f32]>,
    },
    Settle {
        probe: usize,
        after: AcquisitionCursor,
        rule: SettlingRule,
    },
    Collect {
        probe: usize,
        after: AcquisitionCursor,
        measurements: usize,
        frames: usize,
    },
    /// Establish/retain ownership and integration hold even if Hold's outcome
    /// is unknown. Fence/cancel outstanding work, adopt the reference and satisfy
    /// its settling rule before confirming Restored. Submission is insufficient.
    Restore {
        figure: Arc<[f32]>,
        rule: SettlingRule,
    },
    /// Release only after the reference restoration barrier completed.
    Release,
}

#[derive(Clone, Debug)]
pub struct CalibrationEffect {
    pub request: CalibrationRequest,
    pub action: CalibrationAction,
    pub deadline: Instant,
}

#[derive(Debug)]
pub enum CalibrationEvidence {
    Held(AcquisitionCursor),
    Adopted {
        cursor: AcquisitionCursor,
        figure: Arc<[f32]>,
        clipped: bool,
    },
    Settled(AcquisitionCursor),
    Responses(ResponseBatch),
    Restored {
        figure: Arc<[f32]>,
        clipped: bool,
    },
    Released,
}

#[derive(Debug)]
pub struct CalibrationCompletion {
    pub request: CalibrationRequest,
    pub result: Result<CalibrationEvidence, CalibrationFailure>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CalibrationError(pub &'static str);

impl fmt::Display for CalibrationError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.0)
    }
}
impl std::error::Error for CalibrationError {}

struct Pending {
    effect: CalibrationEffect,
    deadline: Instant,
}

/// Single-owner state with at most one pending effect. No endpoint calls, wall
/// sleeps, numerical averaging or matrix inversion occur in state transitions.
pub struct CalibrationCoordinator {
    plan: CalibrationPlan,
    run: u64,
    serial: u64,
    phase: CalibrationPhase,
    pending: Option<Pending>,
    probe: usize,
    cursor: Option<AcquisitionCursor>,
    responses: Vec<ResponseBatch>,
    failure: Option<CalibrationFailure>,
    recovery_failure: Option<CalibrationFailure>,
    restoration_confirmed: bool,
    retained_bytes: usize,
}

impl CalibrationCoordinator {
    /// Begin with a request to establish calibration ownership and integration hold.
    ///
    /// # Errors
    /// Returns an error for a zero run identity or an unrepresentable deadline.
    pub fn begin(
        run: u64,
        plan: CalibrationPlan,
        now: Instant,
    ) -> Result<(Self, CalibrationEffect), CalibrationError> {
        if run == 0 || now.checked_add(plan.timeouts.ownership).is_none() {
            return Err(CalibrationError("invalid run identity or deadline"));
        }
        let capacity = plan.probes.len();
        let retained_bytes = plan.retained_bytes;
        let mut coordinator = Self {
            plan,
            run,
            serial: 0,
            phase: CalibrationPhase::Holding,
            pending: None,
            probe: 0,
            cursor: None,
            responses: Vec::with_capacity(capacity),
            failure: None,
            recovery_failure: None,
            restoration_confirmed: false,
            retained_bytes,
        };
        let effect = coordinator
            .emit(CalibrationAction::Hold, now)
            .ok_or(CalibrationError("invalid ownership deadline"))?;
        Ok((coordinator, effect))
    }

    #[must_use]
    pub const fn phase(&self) -> CalibrationPhase {
        self.phase
    }

    #[must_use]
    pub fn pending_effect(&self) -> Option<&CalibrationEffect> {
        self.pending.as_ref().map(|pending| &pending.effect)
    }

    #[must_use]
    pub fn deadline(&self) -> Option<Instant> {
        self.pending.as_ref().map(|pending| pending.deadline)
    }

    /// Valid data becomes available only after restoration and ownership release.
    #[must_use]
    pub fn responses(&self) -> Option<&[ResponseBatch]> {
        (self.phase == CalibrationPhase::Complete).then_some(self.responses.as_slice())
    }

    #[must_use]
    pub const fn failure(&self) -> Option<CalibrationFailure> {
        self.failure
    }

    #[must_use]
    pub const fn recovery_failure(&self) -> Option<CalibrationFailure> {
        self.recovery_failure
    }

    /// True only after matching reference restoration and settling completion.
    /// Remains true if ownership release subsequently fails.
    #[must_use]
    pub const fn restoration_confirmed(&self) -> bool {
        self.restoration_confirmed
    }

    /// False during acquisition or an unresolved recovery. Endpoint adapters must
    /// retain ownership/integration hold or fault the deployment on `Fault`.
    #[must_use]
    pub fn resume_permitted(&self) -> bool {
        matches!(
            self.phase,
            CalibrationPhase::Complete | CalibrationPhase::Aborted
        )
    }

    /// Consume a correlated completion; stale or wrong-kind events preserve state.
    /// Invalid current evidence instead starts reference restoration.
    ///
    /// # Errors
    /// Returns an error for unsolicited, stale, duplicate or wrong-kind completion.
    pub fn complete(
        &mut self,
        completion: CalibrationCompletion,
        now: Instant,
    ) -> Result<Option<CalibrationEffect>, CalibrationError> {
        let pending = self
            .pending
            .as_ref()
            .ok_or(CalibrationError("no pending effect"))?;
        if completion.request != pending.effect.request {
            return Err(CalibrationError(
                "completion does not match the current request",
            ));
        }
        if now >= pending.deadline {
            return Ok(self.fail(CalibrationFailure::TimedOut(self.phase), now));
        }
        let evidence = match completion.result {
            Ok(evidence) => evidence,
            Err(failure) => return Ok(self.fail(failure, now)),
        };
        if !self.evidence_matches(&evidence) {
            return Err(CalibrationError(
                "completion kind does not match the pending effect",
            ));
        }
        let next = match evidence {
            CalibrationEvidence::Held(cursor) => {
                if !Self::valid_cursor(cursor) {
                    return Ok(self.fail(CalibrationFailure::InvalidEvidence, now));
                }
                self.cursor = Some(cursor);
                self.adopt_action()
            }
            CalibrationEvidence::Adopted {
                cursor,
                figure,
                clipped,
            } => {
                if clipped {
                    return Ok(self.fail(CalibrationFailure::ProbeClipped, now));
                }
                if figure.as_ref() != self.plan.probes[self.probe].as_ref()
                    || !self.cursor_follows(cursor)
                {
                    return Ok(self.fail(CalibrationFailure::InvalidEvidence, now));
                }
                self.cursor = Some(cursor);
                CalibrationAction::Settle {
                    probe: self.probe,
                    after: cursor,
                    rule: self.plan.settling,
                }
            }
            CalibrationEvidence::Settled(cursor) => {
                if !self.settling_satisfied(cursor) {
                    return Ok(self.fail(CalibrationFailure::InvalidEvidence, now));
                }
                self.cursor = Some(cursor);
                CalibrationAction::Collect {
                    probe: self.probe,
                    after: cursor,
                    measurements: self.plan.measurements,
                    frames: self.plan.frames_per_probe,
                }
            }
            CalibrationEvidence::Responses(batch) => {
                let Some(cursor) = self.batch_cursor(&batch) else {
                    return Ok(self.fail(CalibrationFailure::InvalidEvidence, now));
                };
                let Some(retained_bytes) = self.batch_retained_bytes(&batch) else {
                    return Ok(self.fail(CalibrationFailure::InvalidEvidence, now));
                };
                self.cursor = Some(cursor);
                self.retained_bytes = retained_bytes;
                self.responses.push(batch);
                self.probe += 1;
                if self.probe == self.plan.probes.len() {
                    CalibrationAction::Restore {
                        figure: Arc::clone(&self.plan.reference),
                        rule: self.plan.settling,
                    }
                } else {
                    self.adopt_action()
                }
            }
            CalibrationEvidence::Restored { figure, clipped } => {
                if clipped || figure.as_ref() != self.plan.reference.as_ref() {
                    return Ok(self.fail(CalibrationFailure::InvalidEvidence, now));
                }
                self.restoration_confirmed = true;
                CalibrationAction::Release
            }
            CalibrationEvidence::Released => {
                self.pending = None;
                self.phase = if self.failure.is_some() {
                    CalibrationPhase::Aborted
                } else {
                    CalibrationPhase::Complete
                };
                return Ok(None);
            }
        };
        Ok(self.emit(next, now))
    }

    /// Expiration starts restoration, or faults an unresolved recovery. The
    /// original deadline is never extended by duplicate or unrelated events.
    pub fn expire(&mut self, now: Instant) -> Option<CalibrationEffect> {
        if self
            .pending
            .as_ref()
            .is_some_and(|pending| now >= pending.deadline)
        {
            self.fail(CalibrationFailure::TimedOut(self.phase), now)
        } else {
            None
        }
    }

    /// Cancellation is idempotent during restoration/release and never releases
    /// the integration hold before successful reference restoration.
    pub fn cancel(&mut self, now: Instant) -> Option<CalibrationEffect> {
        if matches!(
            self.phase,
            CalibrationPhase::Restoring | CalibrationPhase::Releasing
        ) {
            self.failure.get_or_insert(CalibrationFailure::Cancelled);
            return None;
        }
        self.fail(CalibrationFailure::Cancelled, now)
    }

    /// Report an endpoint/protocol failure without retrying the failed effect.
    pub fn fail(&mut self, failure: CalibrationFailure, now: Instant) -> Option<CalibrationEffect> {
        self.pending.as_ref()?;
        if matches!(
            self.phase,
            CalibrationPhase::Restoring | CalibrationPhase::Releasing
        ) {
            self.failure.get_or_insert(failure);
            self.recovery_failure = Some(failure);
            self.pending = None;
            self.phase = CalibrationPhase::Fault;
            return None;
        }
        self.failure.get_or_insert(failure);
        self.emit(
            CalibrationAction::Restore {
                figure: Arc::clone(&self.plan.reference),
                rule: self.plan.settling,
            },
            now,
        )
    }

    fn adopt_action(&self) -> CalibrationAction {
        CalibrationAction::Adopt {
            probe: self.probe,
            figure: Arc::clone(&self.plan.probes[self.probe]),
        }
    }

    fn emit(&mut self, action: CalibrationAction, now: Instant) -> Option<CalibrationEffect> {
        // Plan bounds guarantee fewer than 4 * MAX_PROBES + 4 effects per run.
        self.serial += 1;
        let (phase, timeout) = match action {
            CalibrationAction::Hold | CalibrationAction::Release => (
                if matches!(action, CalibrationAction::Hold) {
                    CalibrationPhase::Holding
                } else {
                    CalibrationPhase::Releasing
                },
                self.plan.timeouts.ownership,
            ),
            CalibrationAction::Adopt { .. } => {
                (CalibrationPhase::Adopting, self.plan.timeouts.adoption)
            }
            CalibrationAction::Settle { .. } => {
                (CalibrationPhase::Settling, self.plan.timeouts.settling)
            }
            CalibrationAction::Collect { .. } => {
                (CalibrationPhase::Collecting, self.plan.timeouts.collection)
            }
            CalibrationAction::Restore { .. } => {
                (CalibrationPhase::Restoring, self.plan.timeouts.restoration)
            }
        };
        self.phase = phase;
        let Some(deadline) = now.checked_add(timeout) else {
            self.failure
                .get_or_insert(CalibrationFailure::InvalidEvidence);
            self.recovery_failure = Some(CalibrationFailure::InvalidEvidence);
            self.phase = CalibrationPhase::Fault;
            self.pending = None;
            return None;
        };
        let effect = CalibrationEffect {
            request: CalibrationRequest {
                run: self.run,
                serial: self.serial,
            },
            action,
            deadline,
        };
        self.pending = Some(Pending {
            effect: effect.clone(),
            deadline,
        });
        Some(effect)
    }

    fn evidence_matches(&self, evidence: &CalibrationEvidence) -> bool {
        matches!(
            (self.phase, evidence),
            (CalibrationPhase::Holding, CalibrationEvidence::Held(_))
                | (
                    CalibrationPhase::Adopting,
                    CalibrationEvidence::Adopted { .. }
                )
                | (CalibrationPhase::Settling, CalibrationEvidence::Settled(_))
                | (
                    CalibrationPhase::Collecting,
                    CalibrationEvidence::Responses(_)
                )
                | (
                    CalibrationPhase::Restoring,
                    CalibrationEvidence::Restored { .. }
                )
                | (CalibrationPhase::Releasing, CalibrationEvidence::Released)
        )
    }

    fn valid_cursor(cursor: AcquisitionCursor) -> bool {
        cursor.sequence < u64::MAX
    }

    fn cursor_follows(&self, cursor: AcquisitionCursor) -> bool {
        let previous = self
            .cursor
            .expect("cursor is established by Hold completion");
        Self::valid_cursor(cursor)
            && cursor.domain == previous.domain
            && cursor.generation == previous.generation
            && cursor.sequence >= previous.sequence
            && cursor.model_ns >= previous.model_ns
    }

    fn settling_satisfied(&self, cursor: AcquisitionCursor) -> bool {
        if !self.cursor_follows(cursor) {
            return false;
        }
        let adopted = self.cursor.expect("adoption precedes settling");
        match self.plan.settling {
            SettlingRule::Immediate => true,
            SettlingRule::DiscardExposures(count) => {
                adopted.sequence.checked_add(u64::from(count)) == Some(cursor.sequence)
            }
            SettlingRule::ModelTime(duration) => adopted
                .model_ns
                .checked_add(u64::try_from(duration.as_nanos()).expect("duration validated"))
                .is_some_and(|boundary| cursor.model_ns >= boundary),
        }
    }

    fn batch_retained_bytes(&self, batch: &ResponseBatch) -> Option<usize> {
        let values = batch.values.capacity().checked_mul(size_of::<f32>())?;
        let exposures = batch
            .exposures
            .capacity()
            .checked_mul(size_of::<Exposure>())?;
        let retained = self
            .retained_bytes
            .checked_add(values)?
            .checked_add(exposures)?;
        (retained <= MAX_RECORD_BYTES).then_some(retained)
    }

    fn batch_cursor(&self, batch: &ResponseBatch) -> Option<AcquisitionCursor> {
        if !batch.valid
            || batch.values.len() != self.plan.measurements
            || batch.exposures.len() != self.plan.frames_per_probe
            || batch.values.iter().any(|value| !value.is_finite())
        {
            return None;
        }
        let mut cursor = self.cursor?;
        for exposure in &batch.exposures {
            if exposure.domain != cursor.domain
                || exposure.generation != cursor.generation
                || exposure.sequence != cursor.sequence.checked_add(1)?
                || exposure.start_model_ns < cursor.model_ns
                || exposure.duration_ns == 0
            {
                return None;
            }
            cursor.sequence = exposure.sequence;
            cursor.model_ns = exposure.start_model_ns.checked_add(exposure.duration_ns)?;
        }
        Self::valid_cursor(cursor).then_some(cursor)
    }
}

/// Operational adapter executed on the calibration control context, never a
/// frame callback. `submit` accepts work; only evidence confirms completion.
/// The endpoint must serialize/fence commands and keep event serving independent
/// of a blocked synchronous caller. It must honor the receive deadline and must
/// fault/retain ownership if recovery cannot be confirmed.
pub trait CalibrationEndpoint {
    /// # Errors
    /// Enqueue promptly without blocking on execution, queue space or I/O.
    /// A full queue is an immediate error. Respect the effect's deadline;
    /// acceptance does not confirm adoption. Endpoint work completes separately.
    /// Returns failure to submit; the outcome may be unknown, so no retry occurs.
    fn submit(&mut self, effect: &CalibrationEffect) -> Result<(), CalibrationFailure>;

    /// Await one completed operation. `None` denotes expiration of the supplied
    /// monotonic deadline. Cancellation may be returned as a matching failure.
    /// # Errors
    /// Returns an endpoint failure, with its outcome treated as unknown.
    fn receive(
        &mut self,
        deadline: Instant,
    ) -> Result<Option<CalibrationCompletion>, CalibrationFailure>;

    /// Promptly revoke ordinary operation on unrecoverable recovery; enqueue
    /// any longer cleanup independently. Called before the synchronous driver
    /// returns Fault. Must retain the hold or fault the deployment; must not
    /// resume normal operation. No blocking I/O or wait for queue space here.
    fn fault(&mut self, failure: CalibrationFailure);
}

/// Synchronously await the same coordinator events, with no arbitrary sleeps.
/// Returns acquisition state/evidence rather than installing calibration data.
/// A faulted result requires the adapter's deployment fault handling.
///
/// # Errors
/// Returns an error only before requesting ownership (invalid run/deadline).
pub fn acquire_calibration<E: CalibrationEndpoint>(
    endpoint: &mut E,
    run: u64,
    plan: CalibrationPlan,
) -> Result<CalibrationCoordinator, CalibrationError> {
    let (mut coordinator, first) = CalibrationCoordinator::begin(run, plan, Instant::now())?;
    let mut effect = Some(first);
    let mut rejected = 0_u32;
    loop {
        if coordinator.phase == CalibrationPhase::Fault {
            endpoint.fault(
                coordinator
                    .recovery_failure
                    .or(coordinator.failure)
                    .unwrap_or(CalibrationFailure::InvalidEvidence),
            );
            return Ok(coordinator);
        }
        if let Some(request) = effect.take() {
            rejected = 0;
            let now = Instant::now();
            if now >= request.deadline {
                effect = coordinator.expire(now);
                continue;
            }
            if let Err(failure) = endpoint.submit(&request) {
                effect = coordinator.fail(failure, Instant::now());
                continue;
            }
        }
        let Some(deadline) = coordinator.deadline() else {
            return Ok(coordinator);
        };
        if Instant::now() >= deadline {
            effect = coordinator.expire(Instant::now());
            continue;
        }
        match endpoint.receive(deadline) {
            Ok(Some(completion)) => {
                if let Ok(next) = coordinator.complete(completion, Instant::now()) {
                    effect = next;
                } else {
                    rejected += 1;
                    // Bound diagnostic/control interference from unrelated events.
                    if rejected == 64 {
                        effect =
                            coordinator.fail(CalibrationFailure::InvalidEvidence, Instant::now());
                    }
                }
            }
            Ok(None) => {
                let now = Instant::now();
                effect = if now >= deadline {
                    coordinator.expire(now)
                } else {
                    coordinator.fail(CalibrationFailure::InvalidEvidence, now)
                };
            }
            Err(failure) => effect = coordinator.fail(failure, Instant::now()),
        }
    }
}
