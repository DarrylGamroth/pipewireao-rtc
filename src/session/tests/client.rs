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
fn fresh(record: &SessionRecord) -> FreshSessionStatus {
    FreshSessionStatus {
        session_id: record.session_id.clone(),
        owner_pid: record.owner_pid,
        incarnation: record.incarnation,
        remote: record.remote.clone(),
        node_name: record.node_name.clone(),
        global_id: 11,
        object_serial: u64::MAX,
        query_token: 17,
        profile: crate::session::protocol::PROFILE.into(),
        lifecycle: SessionLifecycle::SessionReady,
    }
}
#[test]
fn exact_identity_including_full_unsigned_serial_and_query_token() {
    let record = record();
    assert_eq!(
        verify_session_identity(&record, fresh(&record))
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
            verify_session_identity(&record, observed)
                .unwrap_err()
                .verification,
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
            verify_session_identity(&record, observed)
                .unwrap_err()
                .verification,
            Verification::Inaccessible
        );
    }
    let mut invalid = record.clone();
    invalid.owner_pid = 0;
    assert_eq!(
        verify_session_identity(&invalid, fresh(&invalid))
            .unwrap_err()
            .verification,
        Verification::Malformed
    );
}
#[test]
fn session_lifecycle_uses_direct_authority_states() {
    use crate::control::envelope::{ControllerIdentity, ReplyHeader};
    use crate::control::ExecutionResult;
    for (state, expected) in [
        (LifecycleState::Offline, SessionLifecycle::Offline),
        (LifecycleState::Configuring, SessionLifecycle::Configuring),
        (LifecycleState::Ready, SessionLifecycle::SessionReady),
        (LifecycleState::Running, SessionLifecycle::Running),
        (LifecycleState::Fault, SessionLifecycle::Fault),
    ] {
        let completion = direct::Completion {
            header: ReplyHeader {
                version: 1,
                endpoint_instance: 1,
                controller: ControllerIdentity {
                    global_id: 1,
                    serial: 1,
                    instance: 1,
                },
                token: 1,
                operation: 3,
                result: 0,
            },
            lifecycle: state,
            result: Ok(ExecutionResult::Status {
                lifecycle_state: state,
                status: crate::LiveGraphStatus {
                    running: state == LifecycleState::Running,
                    ..Default::default()
                },
            }),
        };
        assert_eq!(session_lifecycle(&completion), expected);
    }
}
