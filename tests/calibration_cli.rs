#![cfg(unix)]

use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::process::Command;
use std::thread;
use tempfile::tempdir;

fn plan() -> Value {
    json!({
        "version":1,"run":42,"reference":[0.0],"probes":[[0.1],[0.2]],
        "measurements":1,"frames_per_probe":1,"settling":{"kind":"immediate"},
        "timeouts_ns":{"ownership":2_000_000_000_u64,"adoption":2_000_000_000_u64,
            "settling":2_000_000_000_u64,"collection":2_000_000_000_u64,"restoration":2_000_000_000_u64}
    })
}

fn server(
    path: &std::path::Path,
    clip: bool,
    fail_release: bool,
) -> thread::JoinHandle<Vec<String>> {
    let listener = UnixListener::bind(path).unwrap();
    thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream);
        let mut actions = Vec::new();
        let mut sequence = 0_u64;
        loop {
            let mut line = String::new();
            if reader.read_line(&mut line).unwrap() == 0 {
                break;
            }
            let request: Value = serde_json::from_str(&line).unwrap();
            let kind = request["action"]["kind"].as_str().unwrap().to_owned();
            actions.push(kind.clone());
            sequence += 1;
            let cursor =
                json!({"domain":7,"generation":1,"sequence":sequence,"model_ns":sequence*10});
            let result = match kind.as_str() {
                "hold" => json!({"kind":"held","cursor":cursor}),
                "adopt" => {
                    json!({"kind":"adopted","cursor":cursor,"figure":request["action"]["figure"],"clipped":clip})
                }
                "settle" => json!({"kind":"settled","cursor":cursor}),
                "collect" => {
                    json!({"kind":"responses","values":[0.25],"valid":true,"exposures":[{"domain":7,"generation":1,"sequence":sequence,"start_model_ns":sequence*10,"duration_ns":10}]})
                }
                "restore" => {
                    json!({"kind":"restored","figure":request["action"]["figure"],"clipped":false})
                }
                "release" if fail_release => break,
                "release" => json!({"kind":"released"}),
                _ => panic!("unexpected action {kind}"),
            };
            let reply = json!({"version":1,"run":request["run"],"serial":request["serial"],"result":result});
            writeln!(reader.get_mut(), "{reply}").unwrap();
            if kind == "release" {
                break;
            }
        }
        actions
    })
}

fn invoke(endpoint: &std::path::Path, plan_path: &std::path::Path) -> std::process::Output {
    Command::new(env!("CARGO_BIN_EXE_rtc-calibrate"))
        .args([
            "--endpoint",
            endpoint.to_str().unwrap(),
            "--plan",
            plan_path.to_str().unwrap(),
        ])
        .output()
        .unwrap()
}

#[test]
fn complete_session_exports_two_probe_responses() {
    let dir = tempdir().unwrap();
    let socket = dir.path().join("endpoint.sock");
    let plan_path = dir.path().join("plan.json");
    std::fs::write(&plan_path, plan().to_string()).unwrap();
    let peer = server(&socket, false, false);
    let output = invoke(&socket, &plan_path);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let value: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(value["version"], 1);
    assert_eq!(value["run"], 42);
    assert_eq!(value["phase"], "complete");
    assert_eq!(value["restoration_confirmed"], true);
    assert_eq!(value["resume_permitted"], true);
    assert_eq!(value["responses"].as_array().unwrap().len(), 2);
    assert_eq!(peer.join().unwrap().last().unwrap(), "release");
}

#[test]
fn clipping_restores_and_exports_no_partial_responses() {
    let dir = tempdir().unwrap();
    let socket = dir.path().join("endpoint.sock");
    let plan_path = dir.path().join("plan.json");
    std::fs::write(&plan_path, plan().to_string()).unwrap();
    let peer = server(&socket, true, false);
    let output = invoke(&socket, &plan_path);
    assert!(!output.status.success());
    let value: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(value["phase"], "aborted");
    assert_eq!(value["failure"], "ProbeClipped");
    assert_eq!(value["restoration_confirmed"], true);
    assert_eq!(value["responses"], Value::Null);
    let actions = peer.join().unwrap();
    assert_eq!(actions, ["hold", "adopt", "restore", "release"]);
}

#[test]
fn invalid_plan_is_rejected_before_socket_connect() {
    let dir = tempdir().unwrap();
    let socket = dir.path().join("no-listener.sock");
    let plan_path = dir.path().join("plan.json");
    let mut input = plan();
    input["unexpected"] = json!(true);
    std::fs::write(&plan_path, input.to_string()).unwrap();
    let output = invoke(&socket, &plan_path);
    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("invalid plan"));
    assert!(!stderr.contains("cannot connect endpoint"));
}

#[test]
fn malformed_arguments_and_oversized_plan_are_rejected() {
    let missing = Command::new(env!("CARGO_BIN_EXE_rtc-calibrate"))
        .arg("--endpoint")
        .output()
        .unwrap();
    assert!(!missing.status.success());
    let duplicate = Command::new(env!("CARGO_BIN_EXE_rtc-calibrate"))
        .args(["--endpoint", "a", "--endpoint", "b", "--plan", "c"])
        .output()
        .unwrap();
    assert!(String::from_utf8_lossy(&duplicate.stderr).contains("duplicate option"));

    let dir = tempdir().unwrap();
    let plan_path = dir.path().join("large.json");
    std::fs::write(&plan_path, vec![b' '; 16 * 1024 * 1024 + 1]).unwrap();
    let output = invoke(&dir.path().join("no.sock"), &plan_path);
    assert!(String::from_utf8_lossy(&output.stderr).contains("exceeds 16 MiB"));
}

#[test]
fn missing_release_ack_faults_without_exporting_responses() {
    let dir = tempdir().unwrap();
    let socket = dir.path().join("endpoint.sock");
    let plan_path = dir.path().join("plan.json");
    std::fs::write(&plan_path, plan().to_string()).unwrap();
    let peer = server(&socket, false, true);
    let output = invoke(&socket, &plan_path);
    assert!(!output.status.success());
    let value: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(value["phase"], "fault");
    assert_eq!(value["restoration_confirmed"], true);
    assert_eq!(value["resume_permitted"], false);
    assert_eq!(value["responses"], Value::Null);
    assert!(value["recovery_failure"].is_string());
    assert_eq!(peer.join().unwrap().last().unwrap(), "release");
}
