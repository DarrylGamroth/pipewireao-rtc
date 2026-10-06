//! Diagnostic private-core checks; synthetic mailbox identity is not authority proof.

use super::*;
use crate::native_runner_mailbox::Admission;
use pipewireao_rtc::{ConfigurationInput, LifecycleEvent};
use std::path::PathBuf;

#[test]
fn native_remote_requires_actual_socket_without_following_or_replacing_final_symlink() {
    use std::os::unix::fs::{symlink, PermissionsExt};
    use std::os::unix::net::UnixListener;
    let directory = tempfile::tempdir().unwrap();
    std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
    let path = directory.path().join("native-core");
    assert!(validate_remote(path.to_str().unwrap()).is_err());
    assert!(!path.exists());
    std::fs::write(&path, b"preserved").unwrap();
    assert!(validate_remote(path.to_str().unwrap()).is_err());
    assert_eq!(std::fs::read(&path).unwrap(), b"preserved");
    std::fs::remove_file(&path).unwrap();
    let listener = UnixListener::bind(&path).unwrap();
    assert_eq!(
        validate_remote(path.to_str().unwrap()).unwrap(),
        path.to_str().unwrap()
    );
    let alias = directory.path().join("alias");
    symlink(&path, &alias).unwrap();
    assert!(validate_remote(alias.to_str().unwrap()).is_err());
    assert!(std::fs::symlink_metadata(&alias)
        .unwrap()
        .file_type()
        .is_symlink());
    std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o750)).unwrap();
    assert!(validate_remote(path.to_str().unwrap()).is_err());
    std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
    drop(listener);
}

#[test]
#[ignore = "requires the native runner pending-preparation monitor fixture"]
fn pending_preparation_is_fenced_by_required_object_loss() {
    required_object_loss(false);
}

#[test]
#[ignore = "requires the native runner queued-request monitor fixture"]
fn queued_request_is_fenced_by_required_object_loss() {
    required_object_loss(true);
}

#[allow(clippy::too_many_lines)]
fn required_object_loss(queued: bool) {
    let remote = std::env::var("PIPEWIREAO_MONITOR_PROOF_REMOTE").unwrap();
    let config = PathBuf::from(std::env::var_os("PIPEWIREAO_MONITOR_PROOF_CONFIG").unwrap());
    let directory = PathBuf::from(std::env::var_os("PIPEWIREAO_MONITOR_PROOF_DIRECTORY").unwrap());
    let mut runner = Runner::new(LiveGraphAdapter::connect(remote).unwrap());
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::Load(ConfigurationInput::File(config)))
            .unwrap(),
        LifecycleState::Ready,
        "fixture load failed: {:?}",
        runner.diagnostic()
    );
    let mut endpoint = Endpoint::new(
        &runner,
        &Options {
            name: "rtc.native.monitor-proof".into(),
            instance: 41,
        },
    )
    .unwrap();
    // This bypasses registry admission only to arrange an outstanding worker
    // result. Actual caller authority is covered by the separate two-core test.
    let controller = ControllerIdentity {
        global_id: 0x7fff_fffe,
        serial: 91,
        instance: 11,
    };
    let header = RequestHeader {
        version: envelope::VERSION,
        endpoint_instance: 41,
        controller,
        token: 1,
        operation: 14,
        budget_ns: 30_000_000_000,
    };
    let command = Command::Parameter {
        graph: "diagnostic.pending".into(),
        parameter: "node:matrix".into(),
        element_type: "F32_LE".into(),
        shape: vec![1],
        schema: String::new(),
        path: "/diagnostic/not-opened".into(),
    };
    let request = crate::native_runner_codec::encode_request(&header, &command).unwrap();
    let (mut current, accepted_deadline) = {
        let mut stage = endpoint.stage.lock().unwrap();
        assert!(stage.add_controller(controller));
        assert_eq!(stage.stage(&request, Instant::now()), Admission::Accepted);
        stage.worker_busy = !queued;
        let deadline = stage.pending.as_ref().unwrap().deadline;
        (if queued { None } else { stage.take_pending() }, deadline)
    };
    std::fs::write(directory.join("monitor-ready"), "").unwrap();
    let barrier_deadline = Instant::now() + Duration::from_secs(15);
    while !directory.join("required-removed").is_file() {
        assert!(
            Instant::now() < barrier_deadline,
            "fixture did not remove required node"
        );
        std::thread::sleep(Duration::from_millis(2));
    }
    runner.executor().progress_until(accepted_deadline).unwrap();
    let failure = monitor_required_objects(&mut runner, &mut endpoint, &mut current).unwrap_err();
    assert!(failure.field().contains("fixture.monitor-frame-sink"));
    assert_eq!(runner.state(), LifecycleState::Fault);
    assert!(current.is_none());
    let terminal = result::decode_completion(&endpoint.completion).unwrap();
    assert_eq!(terminal.header, reply(&header, -libc::ECANCELED));
    assert_eq!(terminal.lifecycle, LifecycleState::Fault);
    assert!(terminal.result.is_err());
    {
        let stage = endpoint.stage.lock().unwrap();
        assert!(stage.occupied.is_none());
        assert!(stage.pending.is_none());
        assert_eq!(stage.worker_busy, !queued);
        assert!(!stage.maintenance);
        assert_eq!(stage.last_token, header.token);
    }
    let retained = endpoint.completion.clone();
    // Exercise the actual late-result dispatch gate. Quit would return true
    // and replace the retained terminal if this stale result were dispatched.
    let shutdown = dispatch_prepared_result(
        &mut runner,
        &mut endpoint,
        &mut current,
        Prepared {
            request: header,
            command: Ok(Command::Quit),
        },
    )
    .unwrap();
    assert!(!shutdown);
    assert_eq!(runner.state(), LifecycleState::Fault);
    assert_eq!(endpoint.completion, retained);
    assert!(current.is_none());
    assert!(!endpoint.stage.lock().unwrap().worker_busy);
    println!("NATIVE_RUNNER_MONITOR required_node_removed=true queued={queued} pending_preparation={} fault=true terminal_failure=true accepted_slot_released=true late_result_dispatched=false synthetic_admission=true file_io=false", !queued);
    drop(endpoint);
    runner.with_control_deadline(Instant::now() + Duration::from_secs(5), |runner| {
        assert_eq!(
            runner.dispatch(LifecycleEvent::Unload).unwrap(),
            LifecycleState::Offline
        );
    });
}

#[test]
#[ignore = "requires the native runner stalled-core budget fixture"]
fn accepted_runner_request_inherits_stalled_core_budget() {
    stalled_core_budget(false, false);
}

#[test]
#[ignore = "requires the native runner queued-request stalled-core budget fixture"]
fn queued_request_bounds_due_monitor() {
    stalled_core_budget(true, false);
}

#[test]
#[ignore = "requires the native runner queued-request stalled-core budget fixture"]
fn arriving_request_bounds_already_running_monitor() {
    stalled_core_budget(true, true);
}

#[allow(clippy::too_many_lines)]
fn stalled_core_budget(queued_monitor: bool, arriving: bool) {
    let remote = std::env::var("PIPEWIREAO_MONITOR_PROOF_REMOTE").unwrap();
    let config = PathBuf::from(std::env::var_os("PIPEWIREAO_MONITOR_PROOF_CONFIG").unwrap());
    let directory = PathBuf::from(std::env::var_os("PIPEWIREAO_MONITOR_PROOF_DIRECTORY").unwrap());
    let mut runner = Runner::new(LiveGraphAdapter::connect(remote).unwrap());
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::Load(ConfigurationInput::File(config)))
            .unwrap(),
        LifecycleState::Ready,
        "fixture load failed: {:?}",
        runner.diagnostic()
    );
    let mut endpoint = Endpoint::new(
        &runner,
        &Options {
            name: "rtc.native.budget-proof".into(),
            instance: 42,
        },
    )
    .unwrap();
    runner.executor().progress().unwrap();
    let controller = ControllerIdentity {
        global_id: 0x7fff_fffe,
        serial: 92,
        instance: 12,
    };
    assert!(endpoint.stage.lock().unwrap().add_controller(controller));
    std::fs::write(directory.join("budget-ready"), "").unwrap();
    let barrier_deadline = Instant::now() + Duration::from_secs(15);
    while !directory.join("go-budget").is_file() {
        assert!(
            Instant::now() < barrier_deadline,
            "fixture did not stop its daemon"
        );
        std::thread::sleep(Duration::from_millis(2));
    }
    let header = RequestHeader {
        version: envelope::VERSION,
        endpoint_instance: 42,
        controller,
        token: 1,
        operation: 10,
        budget_ns: 250_000_000,
    };
    let request =
        crate::native_runner_codec::encode_request(&header, &Command::SessionStart).unwrap();
    let accepted = if arriving {
        None
    } else {
        let mut stage = endpoint.stage.lock().unwrap();
        assert_eq!(stage.stage(&request, Instant::now()), Admission::Accepted);
        if queued_monitor {
            None
        } else {
            stage.take_pending()
        }
    };
    // A timer runs on the sole owner main loop while monitoring is already
    // inside its stalled roundtrip. Use the same callback admission helper.
    let main_loop = runner.executor().main_loop();
    let timer = arriving.then(|| {
        let stage = Arc::clone(&endpoint.stage);
        let limit = runner.executor().control_deadline_limiter();
        main_loop.loop_().add_timer(move |_| {
            assert!(stage.lock().unwrap().maintenance);
            stage_request(&stage, &limit, &request, Instant::now());
        })
    });
    if let Some(timer) = &timer {
        timer
            .update_timer(Some(Duration::from_millis(40)), None)
            .into_result()
            .unwrap();
    }
    let started = Instant::now();
    let expected_state = if queued_monitor {
        let monitored = monitor_required_objects(&mut runner, &mut endpoint, &mut None);
        assert_eq!(
            runner.state(),
            LifecycleState::Ready,
            "a short accepted budget must not fault a healthy session: {monitored:?}"
        );
        monitored.unwrap();
        LifecycleState::Ready
    } else {
        assert!(!execute(
            &mut runner,
            &mut endpoint,
            &accepted.unwrap(),
            Command::SessionStart
        )
        .unwrap());
        LifecycleState::Ready
    };
    let elapsed = started.elapsed();
    assert!(
        elapsed >= Duration::from_millis(200),
        "wait ended unexpectedly early: {elapsed:?}"
    );
    assert!(
        elapsed < Duration::from_secs(1),
        "request restarted a local sync budget: {elapsed:?}"
    );
    assert_eq!(runner.state(), expected_state);
    let terminal = result::decode_completion(&endpoint.completion).unwrap();
    assert_eq!(terminal.header, reply(&header, -libc::ETIMEDOUT));
    assert_eq!(terminal.lifecycle, expected_state);
    assert!(terminal.result.is_err());
    assert!(endpoint.stage.lock().unwrap().occupied.is_none());
    assert!(endpoint.stage.lock().unwrap().pending.is_none());
    assert!(!endpoint.stage.lock().unwrap().maintenance);
    assert_eq!(endpoint.stage.lock().unwrap().last_token, 1);
    std::fs::write(
        directory.join("budget-elapsed-ns"),
        elapsed.as_nanos().to_string(),
    )
    .unwrap();
    std::fs::write(directory.join("budget-observed"), "").unwrap();
    let release_deadline = Instant::now() + Duration::from_secs(15);
    while !directory.join("budget-release").is_file() {
        assert!(
            Instant::now() < release_deadline,
            "fixture did not resume its daemon"
        );
        std::thread::sleep(Duration::from_millis(2));
    }
    println!("NATIVE_RUNNER_BUDGET elapsed_ns={} queued_monitor={queued_monitor} arriving_during_monitor={arriving} timeout=true lifecycle={expected_state:?} session_start_effects=false local_negative_publication=true synthetic_admission=true remote_observation=false", elapsed.as_nanos());
    drop(endpoint);
    runner.with_control_deadline(Instant::now() + Duration::from_secs(5), |runner| {
        assert_eq!(
            runner.dispatch(LifecycleEvent::Unload).unwrap(),
            LifecycleState::Offline
        );
    });
}

#[test]
fn maintenance_accepts_one_pending_request_without_changing_its_deadline() {
    let controller = ControllerIdentity {
        global_id: 7,
        serial: 91,
        instance: 11,
    };
    let header = RequestHeader {
        version: envelope::VERSION,
        endpoint_instance: 41,
        controller,
        token: 1,
        operation: 3,
        budget_ns: 1_000_000_000,
    };
    let request = crate::native_runner_codec::encode_request(&header, &Command::Status).unwrap();
    let mut stage = Stage::new(41);
    assert!(stage.add_controller(controller));
    stage.maintenance = true;
    let now = Instant::now();
    assert_eq!(stage.stage(&request, now), Admission::Accepted);
    assert_eq!(
        stage.pending.as_ref().unwrap().deadline,
        now + Duration::from_secs(1)
    );
    assert_eq!(stage.last_token, 1);
    let accepted = stage.take_pending().unwrap();
    stage.maintenance = true;
    assert_eq!(stage.stage(&request, Instant::now()), Admission::Duplicate);
    assert_eq!(stage.last_token, 1);
    let newer = crate::native_runner_codec::encode_request(
        &RequestHeader { token: 2, ..header },
        &Command::Status,
    )
    .unwrap();
    assert_eq!(stage.stage(&newer, Instant::now()), Admission::Rejected);
    assert_eq!(
        stage.rejection.as_ref().unwrap().header.result,
        -libc::EBUSY
    );
    assert_eq!(stage.last_token, 1);
    assert!(stage.complete(&accepted));
    assert_eq!(stage.stage(&request, Instant::now()), Admission::Duplicate);
    stage.maintenance = false;
    assert_eq!(stage.stage(&newer, Instant::now()), Admission::Accepted);
    stage.maintenance = true;
    assert_eq!(stage.stage(&request, Instant::now()), Admission::Rejected);
    assert_eq!(
        stage.rejection.as_ref().unwrap().header.result,
        -libc::ESTALE
    );
    assert_eq!(stage.last_token, 2);
}

#[test]
fn only_new_admission_during_maintenance_limits_the_wait() {
    let controller = ControllerIdentity {
        global_id: 7,
        serial: 91,
        instance: 11,
    };
    let header = RequestHeader {
        version: envelope::VERSION,
        endpoint_instance: 41,
        controller,
        token: 1,
        operation: 3,
        budget_ns: 1_000_000_000,
    };
    let stage = Mutex::new(Stage::new(41));
    assert!(stage.lock().unwrap().add_controller(controller));
    stage.lock().unwrap().maintenance = true;
    let observed = Cell::new(None);
    let limit = |deadline| observed.set(Some(deadline));
    let now = Instant::now();
    let request = crate::native_runner_codec::encode_request(&header, &Command::Status).unwrap();
    stage_request(&stage, &limit, &request, now);
    assert_eq!(observed.get(), Some(now + Duration::from_secs(1)));
    let duplicate = crate::native_runner_codec::encode_request(
        &RequestHeader {
            budget_ns: 1,
            ..header
        },
        &Command::Status,
    )
    .unwrap();
    stage_request(&stage, &limit, &duplicate, now + Duration::from_millis(10));
    assert_eq!(observed.get(), Some(now + Duration::from_secs(1)));
    let collision = crate::native_runner_codec::encode_request(
        &RequestHeader { token: 2, ..header },
        &Command::Status,
    )
    .unwrap();
    stage_request(&stage, &limit, &collision, now + Duration::from_millis(20));
    assert_eq!(observed.get(), Some(now + Duration::from_secs(1)));
    let accepted = stage.lock().unwrap().take_pending().unwrap();
    assert!(stage.lock().unwrap().complete(&accepted));
    stage.lock().unwrap().maintenance = false;
    observed.set(None);
    stage_request(&stage, &limit, &collision, now);
    assert_eq!(observed.get(), None);
    assert_eq!(stage.lock().unwrap().last_token, 2);
}
