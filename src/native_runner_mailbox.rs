//! Bounded, cold admission state for the native runner endpoint.
//!
//! This module owns no `PipeWire` objects or lifecycle effects. The callback may
//! lock this state briefly to admit an owned request; the runner takes and
//! executes that request after releasing the lock.

use crate::control::{Command, ControlError};
use crate::native_runner_codec;
use pipewireao_rtc::native_control_codec::{
    self as envelope, ControllerIdentity, ReplyHeader, RequestHeader,
};
use std::collections::BTreeMap;
use std::time::{Duration, Instant};

const MAX_CONTROLLERS: usize = 32;
const MAX_BUDGET: Duration = Duration::from_secs(30);

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct Accepted {
    pub header: RequestHeader,
    pub command: Command,
    pub deadline: Instant,
}

impl Accepted {
    pub(crate) fn is_expired(&self, now: Instant) -> bool {
        now >= self.deadline
    }

    fn identity(&self) -> AcceptedIdentity {
        AcceptedIdentity {
            token: self.header.token,
            controller: self.header.controller,
            operation: self.header.operation,
            command: self.command.clone(),
        }
    }
}

/// The budget is intentionally absent: retransmission cannot extend an
/// accepted deadline or replace an already published result.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct AcceptedIdentity {
    token: i64,
    controller: ControllerIdentity,
    operation: u32,
    command: Command,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct AdmissionRejection {
    pub header: ReplyHeader,
    pub error: ControlError,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum Admission {
    Accepted,
    Duplicate,
    Rejected,
}

pub(crate) struct Stage {
    pub instance: i64,
    /// Only verified bound-node identities belong here. A reused global ID
    /// does not replace its old incarnation until removal is observed.
    pub controllers: BTreeMap<u32, ControllerIdentity>,
    pub pending: Option<Accepted>,
    pub occupied: Option<AcceptedIdentity>,
    pub terminal_request: Option<AcceptedIdentity>,
    pub last_token: i64,
    pub rejection: Option<AdmissionRejection>,
    pub dirty: bool,
    pub worker_busy: bool,
    pub maintenance: bool,
}

impl Stage {
    pub(crate) fn new(instance: i64) -> Self {
        assert!(instance > 0, "endpoint instance must be positive");
        Self {
            instance,
            controllers: BTreeMap::new(),
            pending: None,
            occupied: None,
            terminal_request: None,
            last_token: 0,
            rejection: None,
            dirty: true,
            worker_busy: false,
            maintenance: false,
        }
    }

    /// Called only after the owner has verified bound `NodeInfo` against the
    /// registry. Pending markers also consume the endpoint's 32-slot bound.
    pub(crate) fn add_controller(&mut self, identity: ControllerIdentity) -> bool {
        if identity.global_id == 0
            || identity.global_id == u32::MAX
            || identity.serial == 0
            || identity.instance <= 0
        {
            return false;
        }
        if let Some(current) = self.controllers.get(&identity.global_id) {
            return *current == identity;
        }
        if self.controllers.len() >= MAX_CONTROLLERS {
            return false;
        }
        self.controllers.insert(identity.global_id, identity);
        self.dirty = true;
        true
    }

    /// Removal fences queued and running work through `is_live`, without
    /// erasing the accepted identity or its original completion obligation.
    pub(crate) fn remove_controller(&mut self, global_id: u32) {
        if self.controllers.remove(&global_id).is_some() {
            self.dirty = true;
        }
    }

    pub(crate) fn is_live(&self, header: &RequestHeader) -> bool {
        header.endpoint_instance == self.instance
            && self.controllers.get(&header.controller.global_id) == Some(&header.controller)
    }

    /// Admit one exact runner request. Decoding and equality run only over the
    /// common envelope's 16 KiB bound, before any lifecycle or file effect.
    pub(crate) fn stage(&mut self, bytes: &[u8], now: Instant) -> Admission {
        let common = match envelope::decode_request(bytes) {
            Ok(request) => request.header,
            Err(error) => {
                self.reject(
                    None,
                    -libc::EINVAL,
                    ControlError::new("native.runner.request", error.to_string()),
                );
                return Admission::Rejected;
            }
        };
        let (header, command) = match native_runner_codec::decode_request(bytes) {
            Ok(request) => request,
            Err(error) => {
                self.reject(Some(common), -libc::EINVAL, error);
                return Admission::Rejected;
            }
        };
        if header.endpoint_instance != self.instance {
            self.reject(
                Some(header),
                -libc::ESTALE,
                ControlError::new("endpoint_instance", "endpoint incarnation changed"),
            );
            return Admission::Rejected;
        }
        if !self.is_live(&header) {
            self.reject(
                Some(header),
                -libc::ESTALE,
                ControlError::new(
                    "controller",
                    "controller incarnation is not verified and live",
                ),
            );
            return Admission::Rejected;
        }
        // The accepted sequence is global to this endpoint. Check staleness
        // first, including when the old token matches a retained terminal.
        if header.token < self.last_token {
            self.reject(
                Some(header),
                -libc::ESTALE,
                ControlError::new("token", "request token is stale"),
            );
            return Admission::Rejected;
        }
        let identity = AcceptedIdentity {
            token: header.token,
            controller: header.controller,
            operation: header.operation,
            command: command.clone(),
        };
        if header.token == self.last_token {
            if self.occupied.as_ref() == Some(&identity)
                || self.terminal_request.as_ref() == Some(&identity)
            {
                self.dirty = true;
                return Admission::Duplicate;
            }
            self.reject(
                Some(header),
                -libc::EALREADY,
                ControlError::new(
                    "token",
                    "request token was already accepted with different content",
                ),
            );
            return Admission::Rejected;
        }
        if self.occupied.is_some()
            || self.maintenance
            || (matches!(command, Command::Parameter { .. }) && self.worker_busy)
        {
            self.reject(
                Some(header),
                -libc::EBUSY,
                ControlError::new("request", "runner control slot is busy"),
            );
            return Admission::Rejected;
        }
        let budget = Duration::from_nanos(
            u64::try_from(header.budget_ns).expect("positive validated budget"),
        )
        .min(MAX_BUDGET);
        self.pending = Some(Accepted {
            header,
            command,
            deadline: now + budget,
        });
        self.occupied = Some(identity);
        self.last_token = header.token;
        self.dirty = true;
        Admission::Accepted
    }

    pub(crate) fn take_pending(&mut self) -> Option<Accepted> {
        self.pending.take()
    }

    /// Call after terminal publication, including terminal failures. A stale
    /// completion cannot clear a newer operation's occupied slot.
    pub(crate) fn complete(&mut self, request: &Accepted) -> bool {
        let identity = request.identity();
        if self.occupied.as_ref() != Some(&identity) {
            return false;
        }
        self.pending = None;
        self.occupied = None;
        self.terminal_request = Some(identity);
        self.dirty = true;
        true
    }

    /// Record an independent rejection without changing accepted or terminal
    /// state. An undecodable common envelope uses only the defined sentinel.
    pub(crate) fn reject(
        &mut self,
        request: Option<RequestHeader>,
        result: i32,
        error: ControlError,
    ) {
        debug_assert!(result < 0);
        let (controller, token, operation) = request.map_or(
            (
                ControllerIdentity {
                    global_id: 0,
                    serial: 0,
                    instance: 0,
                },
                0,
                0,
            ),
            |header| (header.controller, header.token, header.operation),
        );
        self.rejection = Some(AdmissionRejection {
            header: ReplyHeader {
                version: envelope::VERSION,
                endpoint_instance: self.instance,
                controller,
                token,
                operation,
                result,
            },
            error,
        });
        self.dirty = true;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use pipewire::spa::pod::Value;
    use pipewireao_rtc::ScalarValue;

    fn controller(global_id: u32, serial: u64) -> ControllerIdentity {
        ControllerIdentity {
            global_id,
            serial,
            instance: 11,
        }
    }

    fn header(
        identity: ControllerIdentity,
        token: i64,
        operation: u32,
        budget_ns: i64,
    ) -> RequestHeader {
        RequestHeader {
            version: envelope::VERSION,
            endpoint_instance: 42,
            controller: identity,
            token,
            operation,
            budget_ns,
        }
    }

    fn request(header: &RequestHeader, command: &Command) -> Vec<u8> {
        native_runner_codec::encode_request(header, command).unwrap()
    }

    fn result(stage: &Stage) -> i32 {
        stage.rejection.as_ref().unwrap().header.result
    }

    #[test]
    fn occupied_survives_take_and_rejects_new_work_without_advancing_token() {
        let now = Instant::now();
        let identity = controller(7, 91);
        let mut stage = Stage::new(42);
        assert!(stage.add_controller(identity));
        let first = header(identity, 1, 3, 1_000_000_000);
        assert_eq!(
            stage.stage(&request(&first, &Command::Status), now),
            Admission::Accepted
        );
        let accepted = stage.take_pending().unwrap();
        assert!(stage.pending.is_none());
        assert!(stage.occupied.is_some());
        let second = header(identity, 2, 2, 1_000_000_000);
        assert_eq!(
            stage.stage(&request(&second, &Command::Groups), now),
            Admission::Rejected
        );
        assert_eq!(result(&stage), -libc::EBUSY);
        assert_eq!(stage.last_token, 1);
        assert!(stage.complete(&accepted));
        assert_eq!(
            stage.stage(&request(&second, &Command::Groups), now),
            Admission::Accepted
        );
    }

    #[test]
    fn duplicate_preserves_original_deadline_and_terminal_result() {
        let now = Instant::now();
        let identity = controller(7, 91);
        let mut stage = Stage::new(42);
        assert!(stage.add_controller(identity));
        let first = header(identity, 1, 3, 1_000_000);
        assert_eq!(
            stage.stage(&request(&first, &Command::Status), now),
            Admission::Accepted
        );
        let longer = RequestHeader {
            budget_ns: 30_000_000_000,
            ..first
        };
        assert_eq!(
            stage.stage(&request(&longer, &Command::Status), now),
            Admission::Duplicate
        );
        let accepted = stage.take_pending().unwrap();
        assert_eq!(accepted.deadline, now + Duration::from_millis(1));
        assert!(accepted.is_expired(now + Duration::from_millis(1)));
        assert!(stage.complete(&accepted));
        assert_eq!(
            stage.stage(&request(&longer, &Command::Status), now),
            Admission::Duplicate
        );
        let changed = header(identity, 1, 2, 1_000_000);
        assert_eq!(
            stage.stage(&request(&changed, &Command::Groups), now),
            Admission::Rejected
        );
        assert_eq!(result(&stage), -libc::EALREADY);
        let second = header(identity, 2, 2, 1_000_000);
        assert_eq!(
            stage.stage(&request(&second, &Command::Groups), now),
            Admission::Accepted
        );
        assert_eq!(
            stage.stage(&request(&first, &Command::Status), now),
            Admission::Rejected
        );
        assert_eq!(result(&stage), -libc::ESTALE);
    }

    #[test]
    fn identity_collision_and_removal_fence_old_work() {
        let now = Instant::now();
        let old = controller(7, 91);
        let replacement = controller(7, 92);
        let mut stage = Stage::new(42);
        assert!(stage.add_controller(old));
        assert!(!stage.add_controller(replacement));
        let first = header(old, 1, 3, 1_000_000);
        assert_eq!(
            stage.stage(&request(&first, &Command::Status), now),
            Admission::Accepted
        );
        let accepted = stage.take_pending().unwrap();
        stage.remove_controller(7);
        assert!(!stage.is_live(&first));
        assert!(stage.add_controller(replacement));
        assert!(!stage.is_live(&first));
        assert!(stage.complete(&accepted));
        assert_eq!(
            stage.stage(&request(&first, &Command::Status), now),
            Admission::Rejected
        );
        assert_eq!(result(&stage), -libc::ESTALE);
        let current = header(replacement, 2, 3, 1_000_000);
        assert_eq!(
            stage.stage(&request(&current, &Command::Status), now),
            Admission::Accepted
        );
    }

    #[test]
    fn bound_and_worker_slot_are_independent() {
        let now = Instant::now();
        let mut stage = Stage::new(42);
        for global_id in 1..=32 {
            assert!(stage.add_controller(controller(global_id, u64::from(global_id))));
        }
        assert!(!stage.add_controller(controller(33, 33)));
        assert!(stage.add_controller(controller(1, 1)));
        let identity = controller(1, 1);
        stage.worker_busy = true;
        let parameter = Command::Parameter {
            graph: "g".into(),
            parameter: "p".into(),
            element_type: "F32_LE".into(),
            shape: vec![1],
            schema: String::new(),
            path: "/tmp/parameter".into(),
        };
        let param_header = header(identity, 1, 14, 1_000_000);
        assert_eq!(
            stage.stage(&request(&param_header, &parameter), now),
            Admission::Rejected
        );
        assert_eq!(result(&stage), -libc::EBUSY);
        assert_eq!(stage.last_token, 0);
        let status_header = header(identity, 1, 3, 1_000_000);
        assert_eq!(
            stage.stage(&request(&status_header, &Command::Status), now),
            Admission::Accepted
        );
    }

    #[test]
    fn cap_and_malformed_payload_have_defined_rejections() {
        let now = Instant::now();
        let identity = controller(7, 91);
        let mut stage = Stage::new(42);
        assert!(stage.add_controller(identity));
        let first = header(identity, 1, 3, i64::MAX);
        assert_eq!(
            stage.stage(&request(&first, &Command::Status), now),
            Admission::Accepted
        );
        let accepted = stage.take_pending().unwrap();
        assert_eq!(accepted.deadline, now + MAX_BUDGET);
        assert!(stage.complete(&accepted));

        let bad = header(identity, 2, 3, 1_000_000);
        let extra = envelope::encode_request(&bad, &[Value::Int(7)]).unwrap();
        assert_eq!(stage.stage(&extra, now), Admission::Rejected);
        assert_eq!(stage.rejection.as_ref().unwrap().header.token, 2);
        assert_eq!(stage.last_token, 1);
        let malformed = vec![0; envelope::REQUEST_BOUND + 1];
        assert_eq!(stage.stage(&malformed, now), Admission::Rejected);
        let rejection = stage.rejection.as_ref().unwrap();
        assert_eq!(rejection.header.token, 0);
        assert_eq!(rejection.header.controller.global_id, 0);
        assert_eq!(rejection.header.endpoint_instance, 42);
        assert_eq!(rejection.header.result, -libc::EINVAL);
    }

    #[test]
    fn newer_terminal_keeps_older_terminal_stale_and_caller_collision_is_rejected() {
        let now = Instant::now();
        let first_controller = controller(7, 91);
        let other_controller = controller(8, 92);
        let mut stage = Stage::new(42);
        assert!(stage.add_controller(first_controller));
        assert!(stage.add_controller(other_controller));
        let first = header(first_controller, 1, 3, 1_000_000);
        assert_eq!(
            stage.stage(&request(&first, &Command::Status), now),
            Admission::Accepted
        );
        let accepted = stage.take_pending().unwrap();
        assert!(stage.complete(&accepted));
        let collision = header(other_controller, 1, 3, 1_000_000);
        assert_eq!(
            stage.stage(&request(&collision, &Command::Status), now),
            Admission::Rejected
        );
        assert_eq!(result(&stage), -libc::EALREADY);
        let second = header(first_controller, 2, 2, 1_000_000);
        assert_eq!(
            stage.stage(&request(&second, &Command::Groups), now),
            Admission::Accepted
        );
        // `complete` has the same identity transition for success and failure;
        // the owner publishes the signed terminal result separately.
        let accepted = stage.take_pending().unwrap();
        assert!(stage.complete(&accepted));
        assert_eq!(
            stage.stage(&request(&first, &Command::Status), now),
            Admission::Rejected
        );
        assert_eq!(result(&stage), -libc::ESTALE);
    }

    #[test]
    fn scalar_float_bits_are_part_of_duplicate_identity() {
        let now = Instant::now();
        let controller = controller(7, 91);
        let mut stage = Stage::new(42);
        assert!(stage.add_controller(controller));
        let header = header(controller, 1, 13, 1_000_000);
        let negative_zero = Command::PropertiesSet(
            "graph".into(),
            BTreeMap::from([("node.gain".into(), ScalarValue::float(-0.0))]),
        );
        let positive_zero = Command::PropertiesSet(
            "graph".into(),
            BTreeMap::from([("node.gain".into(), ScalarValue::float(0.0))]),
        );
        assert_eq!(
            stage.stage(&request(&header, &negative_zero), now),
            Admission::Accepted
        );
        assert_eq!(
            stage.stage(&request(&header, &positive_zero), now),
            Admission::Rejected
        );
        assert_eq!(result(&stage), -libc::EALREADY);
        assert_eq!(
            stage.stage(&request(&header, &negative_zero), now),
            Admission::Duplicate
        );
    }
}
