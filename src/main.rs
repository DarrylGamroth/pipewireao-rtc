use pipewireao_rtc::control;
mod native_path;
use pipewireao_rtc::native_runner_codec;
mod native_runner_endpoint;
mod native_runner_mailbox;
use pipewireao_rtc::native_runner_result;

use crate::control::{state_name, Command, ControlError, ControlErrorResponse, ControlResponse};
use pipewireao_rtc::{
    ConfigurationInput, LifecycleEvent, LifecycleState, LiveGraphAdapter, Runner,
    ScientificDiagnostic,
};
use std::cell::RefCell;
use std::collections::VecDeque;
use std::io::{self, Read, Write};
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

#[derive(Debug)]
pub(crate) enum ControlInput {
    Request {
        id: Option<String>,
        command: Result<Command, ControlError>,
        reply: mpsc::SyncSender<ControlResponse>,
    },
    End,
}

struct Arguments {
    config: PathBuf,
    remote: String,
    hold: bool,
    start_paused: bool,
    native_control: Option<native_runner_endpoint::Options>,
    wireplumber: Option<(u32, u64, String)>,
}

fn main() {
    let result = if std::env::args().nth(1).as_deref() == Some("control") {
        run_client()
    } else {
        run()
    };
    if let Err(error) = result {
        eprintln!("pipewireao-rtc: {error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn std::error::Error>> {
    let arguments = parse_arguments()?;
    let native_mode = arguments.native_control.is_some();
    let session_id = session_id();
    let adapter = match arguments.wireplumber {
        Some((id, serial, name)) => {
            LiveGraphAdapter::connect_with_wireplumber(arguments.remote, id, serial, name)?
        }
        None => LiveGraphAdapter::connect(arguments.remote)?,
    };
    let mut runner = Runner::new(adapter);

    require_state(
        &mut runner,
        LifecycleEvent::Load(ConfigurationInput::File(arguments.config)),
        LifecycleState::Ready,
    )?;
    if !native_mode {
        println!("READY {:?}", runner.executor().status());
    }

    if !arguments.start_paused {
        require_state(&mut runner, LifecycleEvent::Start, LifecycleState::Running)?;
        if !native_mode {
            println!("RUNNING {:?}", runner.executor().status());
        }
    }

    let control_result = if let Some(options) = &arguments.native_control {
        native_runner_endpoint::run(&mut runner, options)
    } else if arguments.hold || arguments.start_paused {
        control_session(&mut runner, &session_id)
    } else {
        Ok(())
    };

    let (stop_result, unload_result) =
        runner.with_control_deadline(Instant::now() + Duration::from_secs(5), |runner| {
            let stop_result = if runner.state() == LifecycleState::Running {
                let result = require_state(runner, LifecycleEvent::Stop, LifecycleState::Ready);
                if result.is_ok() && !native_mode {
                    println!("READY {:?}", runner.executor().status());
                }
                result
            } else {
                Ok(())
            };
            let unload_result = if runner.state() == LifecycleState::Offline {
                Ok(())
            } else {
                let result = require_state(runner, LifecycleEvent::Unload, LifecycleState::Offline);
                if result.is_ok() && !native_mode {
                    println!("OFFLINE {:?}", runner.executor().status());
                }
                result
            };
            (stop_result, unload_result)
        });

    unload_result?;
    stop_result?;
    control_result?;
    Ok(())
}

fn run_client() -> Result<(), Box<dyn std::error::Error>> {
    use pipewireao_rtc::native_supervisor_client::{Binding, Client};
    let mut arguments = std::env::args().skip(2);
    let mut locator = None;
    let mut timeout = 30.0_f64;
    loop {
        match arguments.next().as_deref() {
            Some("--locator" | "--socket") => {
                locator = Some(PathBuf::from(arguments.next().ok_or_else(|| {
                    ScientificDiagnostic::new("command", "control --locator requires a path")
                })?));
            }
            Some("--timeout") => {
                timeout = arguments.next().ok_or("--timeout requires seconds")?.parse()?;
                if !timeout.is_finite() || timeout <= 0.0 || timeout > 30.0 {
                    return Err("control timeout must be finite, positive and at most 30 seconds".into());
                }
            }
            Some("--") => break,
            Some(argument) => return Err(format!("unexpected control client option {argument:?}").into()),
            None => return Err("usage: pipewireao-rtc control --locator PATH [--timeout SECONDS] -- COMMAND [ARG ...]".into()),
        }
    }
    let locator = locator.ok_or("control --locator PATH is required")?;
    let argv = arguments.collect::<Vec<_>>();
    let command =
        control::parse(&argv).map_err(|e| ScientificDiagnostic::new(e.field, e.message))?;
    let deadline = Instant::now() + Duration::from_secs_f64(timeout);
    let binding = Binding::from_locator(&locator)?;
    let pid = binding.owner_pid;
    let mut client = Client::connect(binding, deadline)?;
    let uuid = client.live_uuid();
    // Saved hints never supply admission or scientific state. Query the same
    // exact bound owner before any optional typed mutation, under one deadline.
    let status = client.request(&Command::Status, deadline)?;
    let reply = if command == Command::Status {
        status
    } else {
        client.request(&command, deadline)?
    };
    let mut rendered = reply.render(Some(&session_id()));
    rendered["pid"] = serde_json::json!(pid);
    rendered["deployment_uuid"] = serde_json::json!(uuid);
    println!("{}", serde_json::to_string(&rendered)?);
    if reply.header().result < 0 {
        return Err("native supervisor rejected control".into());
    }
    Ok(())
}

fn control_session(
    runner: &mut Runner<LiveGraphAdapter>,
    session: &str,
) -> Result<(), ScientificDiagnostic> {
    let main_loop = runner.executor().main_loop();
    let inputs = Rc::new(RefCell::new(VecDeque::new()));
    let queued_inputs = Rc::clone(&inputs);
    let (sender, receiver) = pipewire::channel::channel();
    // Dispatch stays outside PipeWire channel callbacks: effects may roundtrip
    // this loop while the same callback queue is being pumped.
    let _receiver = receiver.attach(main_loop.loop_(), move |input| {
        queued_inputs.borrow_mut().push_back(input);
    });

    let stopping = Arc::new(AtomicBool::new(false));
    signal_hook::flag::register(signal_hook::consts::SIGTERM, Arc::clone(&stopping))
        .map_err(|error| ScientificDiagnostic::new("SIGTERM", error.to_string()))?;
    spawn_console_reader(sender);

    let mut monitor_deadline = Instant::now() + Duration::from_millis(100);
    loop {
        if stopping.load(Ordering::Acquire) {
            return Ok(());
        }
        let input = next_control_input(main_loop.loop_(), &inputs, &mut monitor_deadline, || {
            let state = runner.poll_required_objects().map_err(|error| {
                ScientificDiagnostic::new("lifecycle dispatcher", error.to_string())
            })?;
            if state == LifecycleState::Fault {
                return Err(runner.diagnostic().cloned().unwrap_or_else(|| {
                    ScientificDiagnostic::new(
                        "required object",
                        "required-object monitoring reached FAULT",
                    )
                }));
            }
            Ok(())
        })?;
        if stopping.load(Ordering::Acquire) {
            return Ok(());
        }
        let Some(input) = input else {
            continue;
        };
        match input {
            ControlInput::Request { id, command, reply } => {
                let (response, shutdown) = execute_request(runner, id, command, session);
                // An abandoned console reader must never stall the sole
                // lifecycle owner while it returns a response.
                let _ = reply.try_send(response);
                if shutdown {
                    return Ok(());
                }
            }
            ControlInput::End => return Ok(()),
        }
    }
}

fn execute_request(
    runner: &mut Runner<LiveGraphAdapter>,
    id: Option<String>,
    command: Result<Command, ControlError>,
    session: &str,
) -> (ControlResponse, bool) {
    let (ok, result, error, shutdown) = match command {
        Err(error) => (false, None, Some(error), false),
        Ok(command) => match command.execute(runner) {
            Ok(execution) => (
                true,
                Some(execution.result.legacy_json()),
                None,
                execution.shutdown,
            ),
            Err(error) => (false, None, Some(error), false),
        },
    };
    (
        ControlResponse {
            version: 1,
            id,
            session_id: Some(session.to_owned()),
            state: Some(state_name(runner.state()).to_owned()),
            result,
            ok,
            error: error.map(|error| ControlErrorResponse {
                field: error.field,
                message: error.message,
            }),
        },
        shutdown,
    )
}

fn spawn_console_reader(sender: pipewire::channel::Sender<ControlInput>) {
    std::thread::Builder::new()
        .name("rtc-console-reader".to_owned())
        .spawn(move || {
            let stdin = io::stdin();
            let mut input = stdin.lock();
            loop {
                print_prompt();
                let command = match read_console_line(&mut input) {
                    Ok(Some(line)) => {
                        let words = line
                            .split_whitespace()
                            .map(str::to_owned)
                            .collect::<Vec<_>>();
                        control::parse(&words).and_then(control::prepare)
                    }
                    Ok(None) => {
                        let _ = sender.send(ControlInput::End);
                        return;
                    }
                    Err(error) => Err(ControlError::new("command.line", error.to_string())),
                };
                let (reply, response) = mpsc::sync_channel(1);
                if sender
                    .send(ControlInput::Request {
                        id: None,
                        command,
                        reply,
                    })
                    .is_err()
                {
                    return;
                }
                let Ok(response) = response.recv() else {
                    return;
                };
                match serde_json::to_string(&response) {
                    Ok(json) => println!("{json}"),
                    Err(error) => eprintln!("cannot format control response: {error}"),
                }
                if response
                    .result
                    .as_ref()
                    .and_then(|result| result.get("shutdown"))
                    .and_then(serde_json::Value::as_bool)
                    == Some(true)
                {
                    return;
                }
            }
        })
        .expect("spawn console reader");
}

fn print_prompt() {
    print!("pipewireao-rtc> ");
    let _ = io::stdout().flush();
}

fn read_console_line<R: Read>(reader: &mut R) -> io::Result<Option<String>> {
    let mut bytes = Vec::with_capacity(256);
    let mut byte = [0_u8; 1];
    loop {
        match reader.read(&mut byte)? {
            0 if bytes.is_empty() => return Ok(None),
            0 => break,
            _ if byte[0] == b'\n' => break,
            _ if bytes.len() == control::MAX_REQUEST_BYTES - 1 => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "console command exceeds 16384 bytes",
                ));
            }
            _ => bytes.push(byte[0]),
        }
    }
    String::from_utf8(bytes)
        .map(Some)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
}

fn next_control_input(
    loop_: &pipewire::loop_::Loop,
    inputs: &RefCell<VecDeque<ControlInput>>,
    monitor_deadline: &mut Instant,
    mut monitor: impl FnMut() -> Result<(), ScientificDiagnostic>,
) -> Result<Option<ControlInput>, ScientificDiagnostic> {
    let timeout = if inputs.borrow().is_empty() {
        monitor_deadline.saturating_duration_since(Instant::now())
    } else {
        Duration::ZERO
    };
    let result = loop_.iterate(pipewire::loop_::Timeout::Finite(timeout));
    if result < 0 {
        let error = io::Error::from_raw_os_error(-result);
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(ScientificDiagnostic::new(
                "PipeWire main loop",
                format!("iteration failed: {error}"),
            ));
        }
    }
    if Instant::now() >= *monitor_deadline {
        monitor()?;
        *monitor_deadline = Instant::now() + Duration::from_millis(100);
    }
    Ok(inputs.borrow_mut().pop_front())
}

fn require_state(
    runner: &mut Runner<LiveGraphAdapter>,
    event: LifecycleEvent,
    expected: LifecycleState,
) -> Result<(), ScientificDiagnostic> {
    let state = runner
        .dispatch(event)
        .map_err(|error| ScientificDiagnostic::new("lifecycle dispatcher", error.to_string()))?;
    if state == expected {
        return Ok(());
    }
    let failure = runner.diagnostic().cloned().unwrap_or_else(|| {
        ScientificDiagnostic::new(
            "lifecycle",
            format!("expected {expected:?}, reached {state:?}"),
        )
    });
    if state != LifecycleState::Offline {
        let _ = runner.dispatch(LifecycleEvent::Unload);
    }
    Err(failure)
}

fn parse_arguments() -> Result<Arguments, ScientificDiagnostic> {
    parse_arguments_from(std::env::args().skip(1))
}

fn parse_arguments_from(
    mut arguments: impl Iterator<Item = String>,
) -> Result<Arguments, ScientificDiagnostic> {
    let mut config = None;
    let mut remote = String::from("pipewire-ao-0");
    let mut hold = false;
    let mut start_paused = false;
    let mut control_name = None;
    let mut control_instance = None;
    let mut manager = None;
    let mut realization_name = None;
    while let Some(argument) = arguments.next() {
        match argument.as_str() {
            "--config" => {
                config = Some(PathBuf::from(arguments.next().ok_or_else(|| {
                    ScientificDiagnostic::new("command", "--config requires a path")
                })?));
            }
            "--remote" => {
                remote = arguments.next().ok_or_else(|| {
                    ScientificDiagnostic::new("command", "--remote requires a core name")
                })?;
            }
            "--hold" => hold = true,
            "--start-paused" => start_paused = true,
            "--control-node" => {
                control_name = Some(arguments.next().ok_or_else(|| {
                    ScientificDiagnostic::new("command", "--control-node requires a name")
                })?);
            }
            "--control-instance" => {
                let value = arguments.next().ok_or_else(|| {
                    ScientificDiagnostic::new(
                        "command",
                        "--control-instance requires a positive integer",
                    )
                })?;
                control_instance = Some(
                    value
                        .parse::<i64>()
                        .ok()
                        .filter(|value| *value > 0)
                        .ok_or_else(|| {
                            ScientificDiagnostic::new(
                                "command",
                                "--control-instance requires a positive Int64",
                            )
                        })?,
                );
            }
            "--wireplumber-client" => {
                if manager.is_some() {
                    return Err(ScientificDiagnostic::new(
                        "command",
                        "duplicate --wireplumber-client",
                    ));
                }
                manager = Some(parse_manager_client(&mut arguments)?);
            }
            "--realization-node" => {
                if realization_name.is_some() {
                    return Err(ScientificDiagnostic::new(
                        "command",
                        "duplicate --realization-node",
                    ));
                }
                realization_name = Some(arguments.next().ok_or_else(|| {
                    ScientificDiagnostic::new("command", "--realization-node requires a name")
                })?);
            }
            "--help" | "-h" => {
                println!(
                    "Usage: pipewireao-rtc --config PATH [--remote CORE] [--hold] [--start-paused]\n\
                     Native: --remote PRIVATE_SOCKET --start-paused --control-node NAME --control-instance POSITIVE\n\
                     Loads, starts, stops, and unloads one non-actuating complete-frame session.\n\
                     --start-paused loads to READY without starting; native mode does not read stdin.\n\
                     WirePlumber: --wireplumber-client ID SERIAL --realization-node NAME (requires native mode)\n\
                     Client: pipewireao-rtc control --locator PATH -- COMMAND [ARG ...]"
                );
                std::process::exit(0);
            }
            _ => {
                return Err(ScientificDiagnostic::new(
                    "command",
                    format!("unknown argument {argument:?}"),
                ));
            }
        }
    }
    let native_control = native_options(control_name, control_instance, start_paused, &mut remote)?;
    let wireplumber = manager_selection(manager, realization_name, native_control.is_some())?;
    Ok(Arguments {
        config: config
            .ok_or_else(|| ScientificDiagnostic::new("command", "--config PATH is required"))?,
        remote,
        hold,
        start_paused,
        native_control,
        wireplumber,
    })
}

fn native_options(
    control_name: Option<String>,
    control_instance: Option<i64>,
    start_paused: bool,
    remote: &mut String,
) -> Result<Option<native_runner_endpoint::Options>, ScientificDiagnostic> {
    Ok(match (control_name, control_instance) {
        (None, None) => None,
        (Some(name), Some(instance)) => {
            if !start_paused || name.is_empty() || name.len() > 128 || name.contains('\0') {
                return Err(ScientificDiagnostic::new(
                    "command",
                    "native ingress needs a bounded node name and --start-paused",
                ));
            }
            *remote = native_runner_endpoint::validate_remote(remote)?;
            Some(native_runner_endpoint::Options { name, instance })
        }
        _ => {
            return Err(ScientificDiagnostic::new(
                "command",
                "--control-node and --control-instance must be supplied together",
            ))
        }
    })
}

fn parse_manager_client(
    arguments: &mut impl Iterator<Item = String>,
) -> Result<(u32, u64), ScientificDiagnostic> {
    let id = arguments
        .next()
        .and_then(|v| v.parse::<u32>().ok())
        .filter(|id| *id > 0 && *id < u32::MAX)
        .ok_or_else(|| {
            ScientificDiagnostic::new(
                "command",
                "--wireplumber-client requires a valid client ID and serial",
            )
        })?;
    let serial = arguments
        .next()
        .and_then(|v| v.parse::<u64>().ok())
        .filter(|serial| *serial > 0)
        .ok_or_else(|| {
            ScientificDiagnostic::new(
                "command",
                "--wireplumber-client requires a nonzero UInt64 serial",
            )
        })?;
    Ok((id, serial))
}

fn manager_selection(
    manager: Option<(u32, u64)>,
    name: Option<String>,
    native: bool,
) -> Result<Option<(u32, u64, String)>, ScientificDiagnostic> {
    match (manager, name) {
        (None, None) => Ok(None),
        (Some((id, serial)), Some(name)) if native && !name.is_empty() && name.len() <= 128
            && name.bytes().all(|b| b.is_ascii_alphanumeric() || b"_.-".contains(&b)) => Ok(Some((id, serial, name))),
        _ => Err(ScientificDiagnostic::new("command", "WirePlumber selection requires native mode, exact client ID/serial and a bounded realization name")),
    }
}

fn session_id() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |duration| duration.as_nanos());
    format!("{}-{nanos:032x}", std::process::id())
}

#[cfg(test)]
mod tests {
    use super::next_control_input;
    use crate::{Command, ControlInput, ControlResponse};
    use std::cell::{Cell, RefCell};
    use std::collections::VecDeque;
    use std::rc::Rc;
    use std::sync::mpsc;
    use std::time::{Duration, Instant};

    #[test]
    fn wireplumber_requires_exact_native_binding() {
        use std::os::unix::fs::PermissionsExt;
        let directory = tempfile::tempdir().unwrap();
        std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        let socket = directory.path().join("core.sock");
        let _listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
        let base = vec![
            "--config".to_owned(),
            "session.conf".to_owned(),
            "--remote".to_owned(),
            socket.to_str().unwrap().to_owned(),
            "--start-paused".to_owned(),
            "--control-node".to_owned(),
            "test".to_owned(),
            "--control-instance".to_owned(),
            "1".to_owned(),
        ];
        let options = [
            "--wireplumber-client",
            "17",
            "18446744073709551615",
            "--realization-node",
            "test.realization",
        ];
        let parsed =
            super::parse_arguments_from(base.iter().cloned().chain(options.map(str::to_owned)))
                .unwrap();
        assert_eq!(
            parsed.wireplumber,
            Some((17, u64::MAX, "test.realization".into()))
        );
        for options in [
            vec![
                "--wireplumber-client",
                "0",
                "2",
                "--realization-node",
                "test",
            ],
            vec![
                "--wireplumber-client",
                "17",
                "0",
                "--realization-node",
                "test",
            ],
            vec!["--wireplumber-client", "17", "2"],
            vec!["--realization-node", "test"],
            vec![
                "--wireplumber-client",
                "17",
                "2",
                "--realization-node",
                "bad/name",
            ],
            vec![
                "--wireplumber-client",
                "17",
                "2",
                "--wireplumber-client",
                "17",
                "2",
                "--realization-node",
                "test",
            ],
        ] {
            assert!(super::parse_arguments_from(
                base.iter()
                    .cloned()
                    .chain(options.into_iter().map(str::to_owned))
            )
            .is_err());
        }
        assert!(super::parse_arguments_from(
            [
                "--config",
                "session.conf",
                "--wireplumber-client",
                "17",
                "2",
                "--realization-node",
                "test"
            ]
            .map(str::to_owned)
            .into_iter()
        )
        .is_err());
    }

    #[test]
    fn retired_socket_argument_is_rejected_before_native_or_console_selection() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("retired.sock");
        for extra in [
            vec![],
            vec!["--hold"],
            vec![
                "--start-paused",
                "--control-node",
                "test",
                "--control-instance",
                "1",
            ],
        ] {
            let mut arguments = vec!["--config".to_owned(), "not-opened.conf".to_owned()];
            arguments.extend(extra.into_iter().map(str::to_owned));
            arguments.extend([
                "--control-socket".to_owned(),
                path.to_str().unwrap().to_owned(),
            ]);
            let error = super::parse_arguments_from(arguments.into_iter())
                .err()
                .unwrap();
            assert!(error
                .message()
                .contains("unknown argument \"--control-socket\""));
            assert!(!path.exists());
        }
        let error = super::parse_arguments_from(
            vec![format!("--control-socket={}", path.display())].into_iter(),
        )
        .err()
        .unwrap();
        assert!(error.message().contains("unknown argument"));
        assert!(!path.exists());
    }

    #[test]
    fn console_selection_and_line_bounds_remain_available() {
        let parsed = super::parse_arguments_from(
            ["--config", "console.conf", "--hold"]
                .map(str::to_owned)
                .into_iter(),
        )
        .unwrap();
        assert!(parsed.hold);
        assert!(parsed.native_control.is_none());
        let mut line = std::io::Cursor::new(b"status\n".to_vec());
        assert_eq!(
            super::read_console_line(&mut line).unwrap().unwrap(),
            "status"
        );
        let mut oversized = std::io::Cursor::new(vec![b'a'; crate::control::MAX_REQUEST_BYTES]);
        assert_eq!(
            super::read_console_line(&mut oversized).unwrap_err().kind(),
            std::io::ErrorKind::InvalidData
        );
    }

    #[test]
    fn owner_loop_services_timer_without_control_input_and_monitors_deadline() {
        let main_loop = pipewire::main_loop::MainLoopRc::new(None).unwrap();
        let ticks = Rc::new(Cell::new(0));
        let timer_ticks = Rc::clone(&ticks);
        let timer = main_loop.loop_().add_timer(move |_| {
            timer_ticks.set(timer_ticks.get() + 1);
        });
        timer
            .update_timer(
                Some(Duration::from_millis(2)),
                Some(Duration::from_millis(2)),
            )
            .into_result()
            .unwrap();
        let inputs = RefCell::new(VecDeque::new());
        let mut deadline = Instant::now() + Duration::from_millis(20);
        let mut monitors = 0;
        while monitors == 0 {
            assert!(
                next_control_input(main_loop.loop_(), &inputs, &mut deadline, || {
                    monitors += 1;
                    Ok(())
                })
                .unwrap()
                .is_none()
            );
        }
        assert!(ticks.get() > 0);
        assert_eq!(monitors, 1);
    }

    #[test]
    fn owner_loop_control_channel_wakes_before_monitor_timeout() {
        let main_loop = pipewire::main_loop::MainLoopRc::new(None).unwrap();
        let inputs = Rc::new(RefCell::new(VecDeque::new()));
        let queued = Rc::clone(&inputs);
        let (sender, receiver) = pipewire::channel::channel();
        let _receiver = receiver.attach(main_loop.loop_(), move |input| {
            queued.borrow_mut().push_back(input);
        });
        let worker = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(10));
            sender.send(ControlInput::End).unwrap();
        });
        let mut deadline = Instant::now() + Duration::from_secs(2);
        let start = Instant::now();
        let input = next_control_input(main_loop.loop_(), &inputs, &mut deadline, || {
            panic!("control channel did not wake before monitor deadline")
        })
        .unwrap();
        assert!(matches!(input, Some(ControlInput::End)));
        assert!(start.elapsed() < Duration::from_secs(1));
        worker.join().unwrap();
    }

    #[test]
    fn owner_loop_checks_monitor_during_queued_command_flood() {
        let main_loop = pipewire::main_loop::MainLoopRc::new(None).unwrap();
        let inputs = RefCell::new(VecDeque::from([
            ControlInput::End,
            ControlInput::End,
            ControlInput::End,
        ]));
        let mut deadline = Instant::now();
        let mut monitors = 0;
        for remaining in (0..3).rev() {
            deadline = deadline.min(Instant::now());
            assert!(
                next_control_input(main_loop.loop_(), &inputs, &mut deadline, || {
                    monitors += 1;
                    Ok(())
                })
                .unwrap()
                .is_some()
            );
            assert_eq!(inputs.borrow().len(), remaining);
        }
        assert_eq!(monitors, 3);
    }

    #[test]
    fn owner_monitor_roundtrips_without_reentrant_command_dispatch() {
        let main_loop = pipewire::main_loop::MainLoopRc::new(None).unwrap();
        let inputs = Rc::new(RefCell::new(VecDeque::new()));
        let queued = Rc::clone(&inputs);
        let in_callback = Rc::new(Cell::new(false));
        let callback_active = Rc::clone(&in_callback);
        let callback_loop = main_loop.clone();
        let (sender, receiver) = pipewire::channel::channel();
        let _receiver = receiver.attach(main_loop.loop_(), move |input| {
            callback_active.set(true);
            queued.borrow_mut().push_back(input);
            callback_loop.quit();
            callback_active.set(false);
        });
        sender.send(ControlInput::End).unwrap();
        let mut deadline = Instant::now();
        assert!(
            next_control_input(main_loop.loop_(), &inputs, &mut deadline, || {
                assert!(!in_callback.get());
                sender.send(ControlInput::End).unwrap();
                main_loop.loop_().iterate(pipewire::loop_::Timeout::None);
                Ok(())
            })
            .unwrap()
            .is_some()
        );
        assert_eq!(inputs.borrow().len(), 1);
        assert!(
            next_control_input(main_loop.loop_(), &inputs, &mut deadline, || Ok(()))
                .unwrap()
                .is_some()
        );
    }

    #[test]
    fn request_queue_roundtrip_never_dispatches_in_pipewire_callback() {
        let main_loop = pipewire::main_loop::MainLoopRc::new(None).unwrap();
        let inputs = Rc::new(RefCell::new(VecDeque::new()));
        let queued = Rc::clone(&inputs);
        let (reply, _receiver) = mpsc::sync_channel::<ControlResponse>(1);
        let (sender, receiver) = pipewire::channel::channel();
        let _attached = receiver.attach(main_loop.loop_(), move |input| {
            queued.borrow_mut().push_back(input);
        });
        sender
            .send(ControlInput::Request {
                id: Some("one".to_owned()),
                command: Ok(Command::Status),
                reply,
            })
            .unwrap();
        let mut deadline = Instant::now();
        let input =
            next_control_input(main_loop.loop_(), &inputs, &mut deadline, || Ok(())).unwrap();
        assert!(matches!(input, Some(ControlInput::Request { id: Some(id), .. }) if id == "one"));
    }
}
