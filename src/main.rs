mod control;
mod control_socket;
#[allow(dead_code)] // Encoder/client entrypoints remain until CLI migration.
mod native_runner_codec;
mod native_runner_endpoint;
mod native_runner_mailbox;
#[allow(dead_code)]
mod native_runner_result;
#[allow(dead_code)] // Public supervisor integration follows this codec foundation.
mod native_supervisor_codec;

use crate::control::{state_name, Command, ControlError, ControlErrorResponse, ControlResponse};
use crate::control_socket::ControlSocketServer;
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
    control_socket: Option<PathBuf>,
    native_control: Option<native_runner_endpoint::Options>,
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
    let socket_mode = arguments.control_socket.is_some() || arguments.native_control.is_some();
    let session_id = session_id();
    let adapter = LiveGraphAdapter::connect(arguments.remote)?;
    let mut runner = Runner::new(adapter);

    require_state(
        &mut runner,
        LifecycleEvent::Load(ConfigurationInput::File(arguments.config)),
        LifecycleState::Ready,
    )?;
    if !socket_mode {
        println!("READY {:?}", runner.executor().status());
    }

    if !arguments.start_paused {
        require_state(&mut runner, LifecycleEvent::Start, LifecycleState::Running)?;
        if !socket_mode {
            println!("RUNNING {:?}", runner.executor().status());
        }
    }

    let mut control_socket = None;
    let control_result = if let Some(options) = &arguments.native_control {
        native_runner_endpoint::run(&mut runner, options)
    } else if arguments.hold || arguments.start_paused || socket_mode {
        control_session(
            &mut runner,
            arguments.control_socket.as_deref(),
            &session_id,
            &mut control_socket,
        )
    } else {
        Ok(())
    };

    if let Some(socket) = &control_socket {
        socket.shutdown();
    }
    let (stop_result, unload_result) =
        runner.with_control_deadline(Instant::now() + Duration::from_secs(5), |runner| {
            let stop_result = if runner.state() == LifecycleState::Running {
                let result = require_state(runner, LifecycleEvent::Stop, LifecycleState::Ready);
                if result.is_ok() && !socket_mode {
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
                if result.is_ok() && !socket_mode {
                    println!("OFFLINE {:?}", runner.executor().status());
                }
                result
            };
            (stop_result, unload_result)
        });

    drop(control_socket);
    unload_result?;
    stop_result?;
    control_result?;
    Ok(())
}

fn run_client() -> Result<(), Box<dyn std::error::Error>> {
    let mut arguments = std::env::args().skip(2);
    let mut socket = None;
    loop {
        match arguments.next().as_deref() {
            Some("--socket") => {
                socket = Some(PathBuf::from(arguments.next().ok_or_else(|| {
                    ScientificDiagnostic::new("command", "control --socket requires a path")
                })?));
            }
            Some("--") => break,
            Some(argument) => {
                return Err(ScientificDiagnostic::new(
                    "command",
                    format!("unexpected control client option {argument:?}"),
                )
                .into())
            }
            None => {
                return Err(ScientificDiagnostic::new(
                    "command",
                    "usage: pipewireao-rtc control --socket PATH -- COMMAND [ARG ...]",
                )
                .into())
            }
        }
    }
    let socket = socket
        .ok_or_else(|| ScientificDiagnostic::new("command", "control --socket PATH is required"))?;
    let argv = arguments.collect::<Vec<_>>();
    let id = session_id();
    let response = control_socket::send_request(&socket, argv, &id)?;
    println!("{}", serde_json::to_string(&response)?);
    if !response.ok {
        return Err(format!("remote control rejected: {:?}", response.error).into());
    }
    Ok(())
}

fn control_session(
    runner: &mut Runner<LiveGraphAdapter>,
    socket_path: Option<&std::path::Path>,
    session: &str,
    socket: &mut Option<ControlSocketServer>,
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

    *socket = match socket_path {
        Some(path) => Some(
            ControlSocketServer::bind(path, sender.clone(), session.to_owned())
                .map_err(|error| ScientificDiagnostic::new("control socket", error.to_string()))?,
        ),
        None => None,
    };
    let stopping = Arc::new(AtomicBool::new(false));
    signal_hook::flag::register(signal_hook::consts::SIGTERM, Arc::clone(&stopping))
        .map_err(|error| ScientificDiagnostic::new("SIGTERM", error.to_string()))?;
    if socket_path.is_none() {
        spawn_console_reader(sender);
    }

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
                // An abandoned or timed-out client must never stall the sole
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
    let mut config = None;
    let mut remote = String::from("pipewire-ao-0");
    let mut hold = false;
    let mut start_paused = false;
    let mut control_socket = None;
    let mut control_name = None;
    let mut control_instance = None;
    let mut arguments = std::env::args().skip(1);
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
            "--control-socket" => {
                control_socket = Some(PathBuf::from(arguments.next().ok_or_else(|| {
                    ScientificDiagnostic::new("command", "--control-socket requires a path")
                })?));
            }
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
            "--help" | "-h" => {
                println!(
                    "Usage: pipewireao-rtc --config PATH [--remote CORE] [--hold] [--start-paused] [--control-socket PATH]\n\
                     Native: --remote PRIVATE_SOCKET --start-paused --control-node NAME --control-instance POSITIVE\n\
                     Loads, starts, stops, and unloads one non-actuating complete-frame session.\n\
                     --start-paused loads to READY without starting; socket mode does not read stdin.\n\
                     Client: pipewireao-rtc control --socket PATH -- COMMAND [ARG ...]"
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
    let native_control = match (control_name, control_instance) {
        (None, None) => None,
        (Some(name), Some(instance)) => {
            if control_socket.is_some()
                || !start_paused
                || name.is_empty()
                || name.len() > 128
                || name.contains('\0')
            {
                return Err(ScientificDiagnostic::new("command", "native ingress needs a bounded node name and --start-paused, and excludes --control-socket"));
            }
            remote = native_runner_endpoint::validate_remote(&remote)?;
            Some(native_runner_endpoint::Options { name, instance })
        }
        _ => {
            return Err(ScientificDiagnostic::new(
                "command",
                "--control-node and --control-instance must be supplied together",
            ))
        }
    };
    Ok(Arguments {
        config: config
            .ok_or_else(|| ScientificDiagnostic::new("command", "--config PATH is required"))?,
        remote,
        hold,
        start_paused,
        control_socket,
        native_control,
    })
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
