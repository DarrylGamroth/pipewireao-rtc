//! One-shot CLI for selecting and controlling a direct `WirePlumber` session.
//!
//! This module is a client only. `WirePlumber` owns lifecycle and admission.
use crate::control::{self, Command};
use crate::native_session_client::{self, Connection, InitialStatus};
use crate::native_session_discovery::{self, SessionRecord};
use crate::native_session_transport::{ClientError, Reply};
use serde_json::{json, Value};
use std::path::PathBuf;
use std::time::{Duration, Instant};

#[derive(Debug, Eq, PartialEq)]
struct Options {
    list: bool,
    session: Option<String>,
    timeout: Duration,
    command: Vec<String>,
}

fn parse_options(arguments: &[String]) -> Result<Options, String> {
    let mut list = false;
    let mut session = None;
    let mut timeout = Duration::from_secs(30);
    let mut index = 0;
    while index < arguments.len() {
        match arguments[index].as_str() {
            "--" => {
                index += 1;
                break;
            }
            "--list" => {
                list = true;
                index += 1;
            }
            "--session" => {
                index += 1;
                session = Some(
                    arguments
                        .get(index)
                        .ok_or("--session requires a UUID")?
                        .clone(),
                );
                index += 1;
            }
            "--timeout" => {
                index += 1;
                let seconds: f64 = arguments
                    .get(index)
                    .ok_or("--timeout requires seconds")?
                    .parse()
                    .map_err(|_| "invalid --timeout seconds")?;
                if !seconds.is_finite() || seconds <= 0.0 || seconds > 30.0 {
                    return Err("--timeout must be finite, positive and at most 30 seconds".into());
                }
                timeout = Duration::from_secs_f64(seconds);
                index += 1;
            }
            option => return Err(format!("unexpected session client option {option:?}")),
        }
    }
    let command = arguments[index..].to_vec();
    if list {
        if session.is_some() || !command.is_empty() {
            return Err("--list cannot be combined with --session or a command".into());
        }
    } else if session.is_none() || command.is_empty() {
        return Err("usage: pipewireao-rtc session [--timeout SECONDS] --session UUID -- COMMAND [ARG ...], or session --list".into());
    }
    Ok(Options {
        list,
        session,
        timeout,
        command,
    })
}

fn runtime_dir() -> Result<PathBuf, String> {
    std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .ok_or_else(|| "XDG_RUNTIME_DIR is required for session discovery".into())
}

fn record_json(record: &SessionRecord) -> Value {
    json!({
        "label": record.label,
        "session_uuid": record.session_id,
        "owner_pid": record.owner_pid,
        "incarnation": record.incarnation,
        "remote": record.remote,
        "node": record.node_name,
    })
}

fn select(runtime: &std::path::Path, uuid: &str, deadline: Instant) -> Result<Connection, String> {
    let entries = native_session_discovery::list_sessions(runtime)?;
    let record = entries
        .into_iter()
        .filter_map(|entry| entry.record)
        .find(|record| record.session_id == uuid)
        .ok_or_else(|| format!("no session locator found for UUID {uuid}"))?;
    native_session_client::select_direct_session(&record, deadline).map_err(|entry| {
        format!(
            "session selection {:?}: {}",
            entry.verification, entry.detail
        )
    })
}

fn run_control(
    mut connection: Connection,
    command: &Command,
    deadline: Instant,
) -> Result<Value, String> {
    // Selection itself made and retained a fresh direct Status query. Its state
    // is included as evidence, while the exact same deadline bounds the request.
    let session_uuid = connection.selected.record.session_id.clone();
    let label = connection.selected.record.label.clone();
    let owner_pid = connection.selected.status.owner_pid;
    let initial_state = match &connection.initial_status {
        InitialStatus::Session(status) => format!(
            "{:?}",
            crate::native_session_client::session_lifecycle(status)
        ),
    };
    let reply = connection
        .request(command, deadline)
        .map_err(|error: ClientError| error.to_string())?;
    if matches!(reply, Reply::SessionAdministrativeCompletion(_)) {
        return Err(
            "unexpected private administrative completion for public session command".into(),
        );
    }
    let header = reply.header();
    let mut rendered = reply.render(None);
    rendered["session_id"] = json!(session_uuid);
    rendered["label"] = json!(label);
    rendered["owner_pid"] = json!(owner_pid);
    rendered["initial_state"] = json!(initial_state);
    rendered["native_token"] = json!(header.token);
    Ok(rendered)
}

/// Run the direct-session list or control command using bounded native clients.
///
/// Arguments omit the leading `session` subcommand. Saved locator records are
/// candidate hints only; selection proves the exact endpoint with fresh Status.
///
/// # Errors
/// Returns parse, discovery, connection, transport, or server rejection errors.
pub fn run(arguments: &[String]) -> Result<(), String> {
    let options = parse_options(arguments)?;
    let runtime = runtime_dir()?;
    if options.list {
        let entries = native_session_discovery::list_sessions(&runtime)?;
        let result = entries
            .into_iter()
            .map(|entry| match entry.record {
                Some(record) => json!({"record":record_json(&record), "verification":"unverified", "detail":entry.detail}),
                None => json!({"record":null, "verification":"malformed", "detail":entry.detail}),
            })
            .collect::<Vec<_>>();
        println!(
            "{}",
            serde_json::to_string(&json!({"sessions":result})).map_err(|e| e.to_string())?
        );
        return Ok(());
    }
    let command = control::parse(&options.command)
        .map_err(|error| format!("{}: {}", error.field, error.message))?;
    let deadline = Instant::now() + options.timeout;
    let connection = select(
        &runtime,
        options
            .session
            .as_deref()
            .ok_or("--session UUID is required")?,
        deadline,
    )?;
    let result = run_control(connection, &command, deadline)?;
    println!(
        "{}",
        serde_json::to_string(&result).map_err(|e| e.to_string())?
    );
    if result.get("ok").and_then(Value::as_bool) != Some(true) {
        return Err("native session rejected control".into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn direct_session_cli_requires_explicit_selection_and_command() {
        assert!(parse_options(&[]).is_err());
        assert!(parse_options(&["--session".into(), "uuid".into()]).is_err());
        assert!(parse_options(&["--list".into(), "--".into(), "status".into()]).is_err());
        let parsed = parse_options(&[
            "--timeout".into(),
            "2.5".into(),
            "--session".into(),
            "uuid".into(),
            "--".into(),
            "status".into(),
        ])
        .unwrap();
        assert_eq!(parsed.command, vec!["status"]);
        assert_eq!(parsed.session.as_deref(), Some("uuid"));
        assert_eq!(parsed.timeout, Duration::from_millis(2500));
    }
}
