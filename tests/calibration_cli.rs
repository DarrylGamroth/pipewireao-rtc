#![cfg(all(feature = "live", unix))]

use serde_json::{json, Value};
use std::path::Path;
use std::process::{Command, Output};
use tempfile::tempdir;

fn plan() -> Value {
    json!({
        "version":1,"run":42,"reference":[0.0],"probes":[[0.1],[0.2]],
        "measurements":1,"frames_per_probe":1,"settling":{"kind":"immediate"},
        "timeouts_ns":{"ownership":2_000_000_000_u64,"adoption":2_000_000_000_u64,
            "settling":2_000_000_000_u64,"collection":2_000_000_000_u64,"restoration":2_000_000_000_u64}
    })
}

fn invoke(remote: &Path, plan_path: &Path) -> Output {
    Command::new(env!("CARGO_BIN_EXE_rtc-calibrate"))
        .args([
            "--remote",
            remote.to_str().unwrap(),
            "--node",
            "test.calibration",
            "--owner-pid",
            "1",
            "--owner-instance",
            "1",
            "--plan",
            plan_path.to_str().unwrap(),
        ])
        .output()
        .unwrap()
}

#[test]
fn invalid_saved_plan_is_rejected_before_native_connect() {
    let dir = tempdir().unwrap();
    let remote = dir.path().join("no-listener");
    let plan_path = dir.path().join("plan.json");
    let mut input = plan();
    input["unexpected"] = json!(true);
    std::fs::write(&plan_path, input.to_string()).unwrap();
    let output = invoke(&remote, &plan_path);
    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("invalid plan"), "{stderr}");
    assert!(!stderr.contains("cannot prove native endpoint"));
    assert!(output.stdout.is_empty());
    assert!(!remote.exists());
}

#[test]
fn oversized_saved_plan_is_rejected_before_native_connect() {
    let dir = tempdir().unwrap();
    let remote = dir.path().join("no-listener");
    let plan_path = dir.path().join("large.json");
    std::fs::write(&plan_path, vec![b' '; 16 * 1024 * 1024 + 1]).unwrap();
    let output = invoke(&remote, &plan_path);
    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("exceeds 16 MiB"), "{stderr}");
    assert!(!stderr.contains("cannot prove native endpoint"));
    assert!(output.stdout.is_empty());
    assert!(!remote.exists());
}

#[test]
fn retired_endpoint_argument_is_rejected_before_plan_read_or_connection() {
    let dir = tempdir().unwrap();
    let path = dir.path().join("retired.sock");
    let output = Command::new(env!("CARGO_BIN_EXE_rtc-calibrate"))
        .args([
            "--endpoint",
            path.to_str().unwrap(),
            "--plan",
            "not-opened.json",
        ])
        .output()
        .unwrap();
    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("unknown argument: --endpoint"), "{stderr}");
    assert!(
        !stderr.contains("cannot prove native endpoint") && !stderr.contains("cannot open plan")
    );
    assert!(output.stdout.is_empty());
    assert!(!path.exists());
}
