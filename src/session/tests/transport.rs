use super::*;
fn status_reply(_name: &str) -> Vec<u8> {
    use crate::control::ExecutionResult;
    use crate::LifecycleState;
    crate::session::replies::encode_completion(
        &ReplyHeader {
            version: 1,
            endpoint_instance: 7,
            controller: ControllerIdentity {
                global_id: 11,
                serial: 13,
                instance: 17,
            },
            token: 19,
            operation: 3,
            result: 0,
        },
        LifecycleState::Ready,
        &ExecutionResult::Status {
            lifecycle_state: LifecycleState::Ready,
            status: crate::LiveGraphStatus {
                owned_links: 3,
                ..Default::default()
            },
        },
    )
    .unwrap()
}
fn observation(bytes: &[u8]) -> Observation {
    let header = session::decode_completion(bytes).unwrap().header;
    Observation {
        binding: Binding::new(
            "/tmp/private/core".into(),
            "owner".into(),
            1,
            header.endpoint_instance,
        )
        .unwrap(),
        marker_name: "marker".into(),
        marker_instance: 1,
        candidates: BTreeMap::new(),
        owner: None,
        identity: Some(header.controller),
        owner_ready: true,
        uuid: Some("11111111-1111-1111-1111-111111111111".into()),
        marker_ready: true,
        capability: None,
        completion_seen: false,
        rejection_seen: false,
        max_token: 0,
        pending: Some(RequestHeader {
            version: envelope::VERSION,
            endpoint_instance: header.endpoint_instance,
            controller: header.controller,
            token: header.token,
            operation: header.operation,
            budget_ns: 1_000_000_000,
        }),
        matched: None,
        last_completion: None,
        failure: None,
        fatal: false,
    }
}
#[test]
fn uuid_is_bounded_canonical_and_nonzero() {
    assert!(validate_uuid("12345678-1234-1234-1234-123456789abc").is_ok());
    for uuid in [
        "00000000-0000-0000-0000-000000000000",
        "12345678-1234-1234-1234-123456789ABC",
        "1234567811234-1234-1234-123456789abc",
        "short",
    ] {
        assert!(validate_uuid(uuid).is_err());
    }
}
#[test]
fn saved_locator_is_bounded_hints_only() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("control.json");
    let hints = serde_json::json!({"version":1,"profile":session::PROFILE,"session_uuid":"11111111-1111-1111-1111-111111111111","remote":"/tmp/private/core","node":"owner","owner_pid":42,"instance":5});
    fs::write(&path, hints.to_string()).unwrap();
    let binding = Binding::from_locator(&path).unwrap();
    assert_eq!(binding.owner_pid, 42);
    assert!(binding.expected_uuid.is_some());
    let symlink = directory.path().join("link");
    std::os::unix::fs::symlink(&path, &symlink).unwrap();
    assert!(Binding::from_locator(&symlink).is_err());
    fs::write(&path, vec![b' '; 4097]).unwrap();
    assert!(Binding::from_locator(&path).is_err());
    let mut extra = hints.clone();
    extra["admitted"] = serde_json::json!(true);
    fs::write(&path, extra.to_string()).unwrap();
    assert!(Binding::from_locator(&path).is_err());
    let mut wrong = hints;
    wrong["profile"] = serde_json::json!(crate::session::requests::PROFILE);
    fs::write(&path, wrong.to_string()).unwrap();
    assert!(Binding::from_locator(&path).is_err());
}
#[test]
fn matching_terminal_precedes_later_retirement() {
    let bytes = status_reply("reply-status-simulator.pod");
    let mut state = observation(&bytes);
    state.observe(&bytes).unwrap();
    let at = state.matched.as_ref().unwrap().at;
    state.fail_at("removed", true, at + Duration::from_millis(1));
    assert!(matches!(
        state.terminal(at + Duration::from_secs(1)),
        Some(Ok(Reply::SessionCompletion(_)))
    ));
    assert!(state.healthy().is_err());
}
#[test]
fn earlier_retirement_fatal_evidence_and_late_terminal_do_not_complete() {
    let bytes = status_reply("reply-status-simulator.pod");
    let mut state = observation(&bytes);
    state.fail("removed", true);
    state.observe(&bytes).unwrap();
    assert!(state.matched.is_none());
    assert!(matches!(
        state.terminal(Instant::now() + Duration::from_secs(1)),
        Some(Err(_))
    ));
    let mut state = observation(&bytes);
    state.observe(&bytes).unwrap();
    state.fail("malformed", false);
    assert!(matches!(
        state.terminal(Instant::now() + Duration::from_secs(1)),
        Some(Err(_))
    ));
    let mut state = observation(&bytes);
    let deadline = Instant::now()
        .checked_sub(Duration::from_millis(1))
        .unwrap();
    state.observe(&bytes).unwrap();
    assert!(state.terminal(deadline).is_none());
}
#[test]
fn malformed_and_conflicting_native_evidence_is_rejected() {
    let bytes = status_reply("reply-status-simulator.pod");
    let mut state = observation(&bytes);
    assert!(state
        .observe(&vec![0; envelope::LIFECYCLE_REPLY_BOUND + 1])
        .is_err());
    let mut malformed = bytes.clone();
    malformed[0] = 0;
    assert!(state.observe(&malformed).is_err());
    let mut state = observation(&bytes);
    state.observe(&bytes).unwrap();
    let mut c = session::decode_completion(&bytes).unwrap();
    // Changing a valid bounded result while retaining its token is fatal.
    if let Ok(crate::control::ExecutionResult::Status { status, .. }) = &mut c.result {
        status.owned_links += 1;
    }
    assert!(state
        .observe(
            &crate::session::replies::encode_completion(
                &c.header,
                c.lifecycle,
                c.result.as_ref().unwrap()
            )
            .unwrap()
        )
        .is_err());
}
#[test]
fn rendering_reports_the_direct_session_only() {
    let reply =
        Reply::SessionCompletion(session::decode_completion(&status_reply("status")).unwrap());
    let value = reply.render(Some("operator"));
    assert_eq!(value["id"], "operator");
    assert_eq!(value["state"], "Ready");
    assert_eq!(value["profile"], session::PROFILE);
    assert_eq!(value["result"]["owned_links"], 3);
    assert!(value.get("supervisor_phase").is_none());
}
