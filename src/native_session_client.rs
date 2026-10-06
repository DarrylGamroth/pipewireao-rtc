//! Explicit session selection followed by control on that exact retained client.
use crate::control::Command;
use crate::native_session_discovery::{DiscoveryEntry, SessionRecord, Verification};
use crate::native_supervisor_client::{Binding, Client, ClientError, Reply};
use crate::native_supervisor_codec::{Completion, Phase};
use crate::LifecycleState;
use std::time::Instant;

/// Lifecycle from a fresh native supervisor/runner Status, never listing metadata.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SessionLifecycle {
    /// Supervisor preparing or runner configuring.
    Preparing,
    /// Admitted runner actively running.
    Ready,
    /// Live supervisor with stopped/ready/offline runner, or stopping supervisor.
    Stopped,
    /// Owner reports a fault.
    Fault,
}

/// Actual identity and token observed by selection's one fresh Status query.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FreshSupervisorStatus {
    /// Immutable native endpoint UUID.
    pub session_id: String,
    /// Actual bound supervisor PID.
    pub owner_pid: u32,
    /// Actual endpoint incarnation.
    pub incarnation: i64,
    /// Exact remote used for this connection.
    pub remote: String,
    /// Actual bound supervisor node name.
    pub node_name: String,
    /// Actual registry global ID.
    pub global_id: u32,
    /// Full unsigned actual object serial.
    pub object_serial: u64,
    /// Positive token of the freshly completed Status query.
    pub query_token: i64,
    /// Native deployment supervisor authority profile.
    pub profile: String,
    /// Lifecycle independently derived from fresh status.
    pub lifecycle: SessionLifecycle,
}

/// Selected record and freshly matched native endpoint identity.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SelectedSession {
    /// Hint that was explicitly selected.
    pub record: SessionRecord,
    /// Actual freshly verified facts.
    pub status: FreshSupervisorStatus,
}

/// Retains the exact client that proved selection; there is no reconnect policy.
pub struct Connection {
    /// Immutable selection identity.
    pub selected: SelectedSession,
    /// Fresh successful Status completion from selection.
    pub initial_status: Completion,
    client: Client,
}

impl Connection {
    /// Send an explicit command on the retained connection, with no retry/rebind.
    ///
    /// # Errors
    /// Preserves `BeforeSend` versus permanently retired `UnknownOutcome` failures.
    pub fn request(&mut self, command: &Command, deadline: Instant) -> Result<Reply, ClientError> {
        self.client.request(command, deadline)
    }
}

/// Derive the discovery lifecycle from native status semantics.
///
/// # Errors
/// Rejects failed/non-Status replies or incoherent admitted runner observations.
pub fn lifecycle(completion: &Completion) -> Result<SessionLifecycle, String> {
    if completion.header.result != 0 || completion.header.operation != 3 {
        return Err("session selection requires successful fresh Status".into());
    }
    match completion.lifecycle {
        Phase::Preparing => Ok(SessionLifecycle::Preparing),
        Phase::Failed => Ok(SessionLifecycle::Fault),
        Phase::Stopping | Phase::Stopped => Ok(SessionLifecycle::Stopped),
        Phase::Admitted => {
            let runner = completion
                .snapshot
                .as_ref()
                .and_then(|s| s.runner.as_ref())
                .filter(|_| completion.admitted)
                .ok_or("admitted Status has no runner")?;
            Ok(match runner.status.lifecycle {
                LifecycleState::Fault => SessionLifecycle::Fault,
                LifecycleState::Ready | LifecycleState::Offline => SessionLifecycle::Stopped,
                LifecycleState::Running => SessionLifecycle::Ready,
                LifecycleState::Configuring => SessionLifecycle::Preparing,
            })
        }
    }
}

/// Check a fresh identity against the exact selected hint without rebinding.
///
/// # Errors
/// A valid but different identity is Replaced; invalid fresh evidence is Inaccessible.
#[allow(clippy::result_large_err)] // Cold bounded record retained for explicit failed selection.
pub fn verify_identity(
    record: &SessionRecord,
    fresh: FreshSupervisorStatus,
) -> Result<SelectedSession, DiscoveryEntry> {
    record.validate().map_err(|detail| {
        DiscoveryEntry::new(Some(record.clone()), Verification::Malformed, &detail)
    })?;
    if fresh.global_id == 0
        || fresh.global_id == u32::MAX
        || fresh.object_serial == 0
        || fresh.query_token <= 0
    {
        return Err(DiscoveryEntry::new(
            Some(record.clone()),
            Verification::Inaccessible,
            "invalid fresh native binding or Status token",
        ));
    }
    if fresh.session_id != record.session_id
        || fresh.owner_pid != record.owner_pid
        || fresh.incarnation != record.incarnation
        || fresh.remote != record.remote
        || fresh.node_name != record.node_name
        || fresh.profile != crate::native_supervisor_codec::PROFILE
    {
        return Err(DiscoveryEntry::new(
            Some(record.clone()),
            Verification::Replaced,
            "fresh native identity differs from selected supervisor",
        ));
    }
    Ok(SelectedSession {
        record: record.clone(),
        status: fresh,
    })
}

/// Connect once, query Status once, and retain that same client for later controls.
///
/// # Errors
/// Reports bounded Malformed/Inaccessible/Replaced without removing the hint.
#[allow(clippy::result_large_err)] // Cold bounded record retained for explicit failed selection.
pub fn select_session(
    record: &SessionRecord,
    deadline: Instant,
) -> Result<Connection, DiscoveryEntry> {
    record
        .validate()
        .map_err(|e| DiscoveryEntry::new(Some(record.clone()), Verification::Malformed, &e))?;
    let inaccessible = |detail: String| {
        DiscoveryEntry::new(Some(record.clone()), Verification::Inaccessible, &detail)
    };
    let binding = Binding::new(
        record.remote.clone(),
        record.node_name.clone(),
        record.owner_pid,
        record.incarnation,
    )
    .map_err(inaccessible)?;
    // Observe actual UUID before matching: a replacement must be reported, never adopted.
    let mut client = Client::connect(binding, deadline).map_err(inaccessible)?;
    let Reply::Completion(completion) = client
        .request(&Command::Status, deadline)
        .map_err(|e| inaccessible(e.to_string()))?
    else {
        return Err(inaccessible("native Status rejected".into()));
    };
    let lifecycle = lifecycle(&completion).map_err(inaccessible)?;
    let binding = client
        .owner_binding()
        .ok_or_else(|| inaccessible("native owner disappeared after Status".into()))?;
    let uuid = client
        .live_uuid()
        .ok_or_else(|| inaccessible("native owner UUID unavailable after Status".into()))?;
    let fresh = FreshSupervisorStatus {
        session_id: uuid,
        owner_pid: binding.pid,
        incarnation: binding.instance,
        remote: record.remote.clone(),
        node_name: binding.name,
        global_id: binding.global_id,
        object_serial: binding.serial,
        query_token: completion.header.token,
        profile: binding.profile,
        lifecycle,
    };
    let selected = verify_identity(record, fresh)?;
    Ok(Connection {
        selected,
        initial_status: completion,
        client,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn record() -> SessionRecord {
        SessionRecord {
            label: "Same label".into(),
            session_id: "12345678-1234-1234-1234-123456789abc".into(),
            owner_pid: 42,
            incarnation: 9,
            remote: "/tmp/private/core".into(),
            node_name: "supervisor".into(),
        }
    }
    fn fresh(record: &SessionRecord) -> FreshSupervisorStatus {
        FreshSupervisorStatus {
            session_id: record.session_id.clone(),
            owner_pid: record.owner_pid,
            incarnation: record.incarnation,
            remote: record.remote.clone(),
            node_name: record.node_name.clone(),
            global_id: 11,
            object_serial: u64::MAX,
            query_token: 17,
            profile: crate::native_supervisor_codec::PROFILE.into(),
            lifecycle: SessionLifecycle::Stopped,
        }
    }
    #[test]
    fn exact_identity_including_full_unsigned_serial_and_query_token() {
        let record = record();
        assert_eq!(
            verify_identity(&record, fresh(&record))
                .unwrap()
                .status
                .object_serial,
            u64::MAX
        );
        for field in 0..6 {
            let mut observed = fresh(&record);
            match field {
                0 => observed.session_id = "87654321-1234-1234-1234-123456789abc".into(),
                1 => observed.owner_pid += 1,
                2 => observed.incarnation += 1,
                3 => observed.remote.push('x'),
                4 => observed.node_name.push('x'),
                _ => observed.profile = "pipewireao.rtc.runner/1".into(),
            }
            assert_eq!(
                verify_identity(&record, observed).unwrap_err().verification,
                Verification::Replaced
            );
        }
        for field in 0..3 {
            let mut observed = fresh(&record);
            match field {
                0 => observed.global_id = u32::MAX,
                1 => observed.object_serial = 0,
                _ => observed.query_token = 0,
            }
            assert_eq!(
                verify_identity(&record, observed).unwrap_err().verification,
                Verification::Inaccessible
            );
        }
        let mut invalid = record.clone();
        invalid.owner_pid = 0;
        assert_eq!(
            verify_identity(&invalid, fresh(&invalid))
                .unwrap_err()
                .verification,
            Verification::Malformed
        );
    }
    #[test]
    fn preparing_has_no_runner_and_lifecycle_never_comes_from_record() {
        let bytes = std::fs::read(
            std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("tests/fixtures/native-supervisor/reply-status-preparing.pod"),
        )
        .unwrap();
        let mut completion = crate::native_supervisor_codec::decode_completion(&bytes).unwrap();
        assert_eq!(lifecycle(&completion).unwrap(), SessionLifecycle::Preparing);
        completion.lifecycle = Phase::Failed;
        assert_eq!(lifecycle(&completion).unwrap(), SessionLifecycle::Fault);
        completion.lifecycle = Phase::Stopped;
        assert_eq!(lifecycle(&completion).unwrap(), SessionLifecycle::Stopped);
        completion.lifecycle = Phase::Admitted;
        completion.admitted = true;
        assert!(lifecycle(&completion).is_err());
        completion.header.result = -1;
        assert!(lifecycle(&completion).is_err());
    }
}
