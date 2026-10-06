#![cfg(all(feature = "live", unix))]

use std::process::Command;

#[test]
fn obsolete_socket_cli_rejects_without_connecting_or_creating_socket() {
    let directory = tempfile::tempdir().unwrap();
    let socket = directory.path().join("retired.sock");
    for option in [
        "--control-socket".to_owned(),
        format!("--control-socket={}", socket.display()),
    ] {
        let mut command = Command::new(env!("CARGO_BIN_EXE_pipewireao-rtc"));
        command.args([
            "--config",
            "not-opened.conf",
            "--remote",
            "nonexistent-retirement-core",
            "--hold",
        ]);
        command.arg(&option);
        if option == "--control-socket" {
            command.arg(&socket);
        }
        let output = command.output().unwrap();
        assert!(!output.status.success());
        let error = String::from_utf8(output.stderr).unwrap();
        assert!(
            error.contains("unknown argument") && error.contains("--control-socket"),
            "{error}"
        );
        assert!(!socket.exists());
        assert!(output.stdout.is_empty());
    }
}

#[test]
fn help_does_not_advertise_retired_socket_ingress() {
    let output = Command::new(env!("CARGO_BIN_EXE_pipewireao-rtc"))
        .arg("--help")
        .output()
        .unwrap();
    assert!(output.status.success());
    let help = String::from_utf8(output.stdout).unwrap();
    assert!(!help.contains("--control-socket"));
    assert!(help.contains("--control-node") && help.contains("control --locator"));
}
