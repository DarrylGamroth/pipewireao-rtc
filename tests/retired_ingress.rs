#![cfg(all(feature = "live", unix))]

use std::process::Command;

#[test]
fn direct_session_cli_rejects_missing_uuid_before_accessing_runtime_directory() {
    let output = Command::new(env!("CARGO_BIN_EXE_pipewireao-rtc"))
        .args(["session", "--", "status"])
        .env_remove("XDG_RUNTIME_DIR")
        .output()
        .unwrap();
    assert!(!output.status.success());
    let error = String::from_utf8(output.stderr).unwrap();
    assert!(error.contains("--session UUID"), "{error}");
}

#[test]
fn help_documents_only_direct_session_commands() {
    let output = Command::new(env!("CARGO_BIN_EXE_pipewireao-rtc"))
        .arg("--help")
        .output()
        .unwrap();
    assert!(output.status.success());
    let help = String::from_utf8(output.stdout).unwrap();
    assert!(help.contains("session --list"));
    assert!(help.contains("session --session UUID"));
    assert!(!help.contains("supervisor") && !help.contains("--locator"));
}
