//! Explicit session selection followed by control on that exact retained client.
use crate::control::types::LifecycleState;
use crate::control::Command;
use crate::control::ExecutionResult;
use crate::session::discovery::{DiscoveryEntry, SessionRecord, Verification};
use crate::session::protocol as direct;
use crate::session::transport::{Binding, Client, ClientError, Reply};
use std::time::Instant;

/// Lifecycle reported by the selected `WirePlumber` session authority.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SessionLifecycle {
    Offline,
    Configuring,
    SessionReady,
    Running,
    Fault,
}

/// Actual identity and token observed by selection's one fresh Status query.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FreshSessionStatus {
    /// Immutable native endpoint UUID.
    pub session_id: String,
    /// Actual bound session PID.
    pub owner_pid: u32,
    /// Actual endpoint incarnation.
    pub incarnation: i64,
    /// Exact remote used for this connection.
    pub remote: String,
    /// Actual bound session node name.
    pub node_name: String,
    /// Actual registry global ID.
    pub global_id: u32,
    /// Full unsigned actual object serial.
    pub object_serial: u64,
    /// Positive token of the freshly completed Status query.
    pub query_token: i64,
    /// Native session authority profile.
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
    pub status: FreshSessionStatus,
}

/// Retains the exact client that proved selection; there is no reconnect policy.
pub struct Connection {
    /// Immutable selection identity.
    pub selected: SelectedSession,
    /// Fresh successful Status completion from selection.
    pub initial_status: InitialStatus,
    client: Client,
}

/// Fresh Status from the selected native public profile.
#[derive(Clone, Debug)]
pub enum InitialStatus {
    Session(direct::Completion),
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

/// Check fresh identity against the direct `WirePlumber` session profile.
///
/// # Errors
/// A valid but different identity is Replaced; invalid evidence is Inaccessible.
#[allow(clippy::result_large_err)]
pub fn verify_session_identity(
    record: &SessionRecord,
    fresh: FreshSessionStatus,
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
        || fresh.profile != crate::session::protocol::PROFILE
    {
        return Err(DiscoveryEntry::new(
            Some(record.clone()),
            Verification::Replaced,
            "fresh native identity differs from selected session",
        ));
    }
    Ok(SelectedSession {
        record: record.clone(),
        status: fresh,
    })
}

/// Read the direct session lifecycle using its unchanged numeric IDs.
#[must_use]
pub fn session_lifecycle(completion: &crate::session::protocol::Completion) -> SessionLifecycle {
    match completion.lifecycle {
        LifecycleState::Offline => SessionLifecycle::Offline,
        LifecycleState::Configuring => SessionLifecycle::Configuring,
        LifecycleState::Ready => SessionLifecycle::SessionReady,
        LifecycleState::Running => SessionLifecycle::Running,
        LifecycleState::Fault => SessionLifecycle::Fault,
    }
}

fn inaccessible(record: &SessionRecord, detail: impl AsRef<str>) -> DiscoveryEntry {
    DiscoveryEntry::new(
        Some(record.clone()),
        Verification::Inaccessible,
        detail.as_ref(),
    )
}

#[allow(clippy::result_large_err)] // Bounded discovery failure retains the selected record for caller reporting.
fn finish_status(
    record: &SessionRecord,
    mut client: Client,
    deadline: Instant,
) -> Result<Connection, DiscoveryEntry> {
    // Once Status is submitted, no fallback or replay is safe.
    let reply = client
        .request(&Command::Status, deadline)
        .map_err(|e| inaccessible(record, e.to_string()))?;
    let (initial_status, lifecycle, token) = match reply {
        Reply::SessionCompletion(completion) => {
            if completion.header.result != 0
                || completion.header.operation != 3
                || !matches!(&completion.result, Ok(ExecutionResult::Status { .. }))
            {
                return Err(inaccessible(
                    record,
                    "direct session Status was not successful",
                ));
            }
            let state = session_lifecycle(&completion);
            let token = completion.header.token;
            (InitialStatus::Session(completion), state, token)
        }
        _ => {
            return Err(inaccessible(
                record,
                "native Status rejected or changed profile",
            ))
        }
    };
    let binding = client
        .owner_binding()
        .ok_or_else(|| inaccessible(record, "native owner disappeared after Status"))?;
    let uuid = client
        .live_uuid()
        .ok_or_else(|| inaccessible(record, "native owner UUID unavailable after Status"))?;
    let fresh = FreshSessionStatus {
        session_id: uuid,
        owner_pid: binding.pid,
        incarnation: binding.instance,
        remote: record.remote.clone(),
        node_name: binding.name,
        global_id: binding.global_id,
        object_serial: binding.serial,
        query_token: token,
        profile: binding.profile,
        lifecycle,
    };
    let selected = verify_session_identity(record, fresh)?;
    Ok(Connection {
        selected,
        initial_status,
        client,
    })
}

#[allow(clippy::result_large_err)] // Retains the bounded locator for explicit failed-selection reporting.
fn candidate_binding(record: &SessionRecord) -> Result<Binding, DiscoveryEntry> {
    Binding::new(
        record.remote.clone(),
        record.node_name.clone(),
        record.owner_pid,
        record.incarnation,
    )
    .map_err(|e| inaccessible(record, e))
}

/// Connect to the direct `WirePlumber` profile and retain its fresh Status client.
///
/// # Errors
/// Reports bounded Malformed/Inaccessible/Replaced without removing the hint.
#[allow(clippy::result_large_err)]
pub fn select_direct_session(
    record: &SessionRecord,
    deadline: Instant,
) -> Result<Connection, DiscoveryEntry> {
    record
        .validate()
        .map_err(|e| DiscoveryEntry::new(Some(record.clone()), Verification::Malformed, &e))?;
    let binding = candidate_binding(record)?
        .for_session(record.session_id.clone())
        .map_err(|e| inaccessible(record, e))?;
    let client = Client::connect(binding, deadline).map_err(|e| inaccessible(record, e))?;
    finish_status(record, client, deadline)
}

/// Select only the `WirePlumber` authority; no coordinator fallback or rebinding.
///
/// # Errors
/// Returns a bounded discovery result for malformed, inaccessible, or replaced endpoints.
#[allow(clippy::result_large_err)]
pub fn select_session(
    record: &SessionRecord,
    deadline: Instant,
) -> Result<Connection, DiscoveryEntry> {
    select_direct_session(record, deadline)
}

#[cfg(test)]
#[path = "tests/client.rs"]
mod tests;
