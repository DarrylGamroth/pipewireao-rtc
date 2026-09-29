use pipewireao_rtc::{
    ConfigurationInput, LifecycleEvent, LifecycleState, LiveGraphAdapter, NdArrayParameterValue,
    Runner, ScalarValue, ScientificDiagnostic,
};
use std::cell::RefCell;
use std::collections::{BTreeMap, VecDeque};
use std::path::PathBuf;
use std::rc::Rc;
use std::time::{Duration, Instant};

struct Arguments {
    config: PathBuf,
    remote: String,
    hold: bool,
}

#[derive(Debug)]
enum ControlInput {
    Line(String),
    End,
    Failed(String),
}

fn main() {
    if let Err(error) = run() {
        eprintln!("pipewireao-rtc: {error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn std::error::Error>> {
    let arguments = parse_arguments()?;
    let adapter = LiveGraphAdapter::connect(arguments.remote)?;
    let mut runner = Runner::new(adapter);

    require_state(
        &mut runner,
        LifecycleEvent::Load(ConfigurationInput::File(arguments.config)),
        LifecycleState::Ready,
    )?;
    println!("READY {:?}", runner.executor().status());

    require_state(&mut runner, LifecycleEvent::Start, LifecycleState::Running)?;
    println!("RUNNING {:?}", runner.executor().status());
    let control_result = if arguments.hold {
        control_session(&mut runner)
    } else {
        Ok(())
    };

    let stop_result = if runner.state() == LifecycleState::Running {
        let result = require_state(&mut runner, LifecycleEvent::Stop, LifecycleState::Ready);
        if result.is_ok() {
            println!("READY {:?}", runner.executor().status());
        }
        result
    } else {
        Ok(())
    };
    let unload_result = if runner.state() == LifecycleState::Offline {
        Ok(())
    } else {
        let result = require_state(&mut runner, LifecycleEvent::Unload, LifecycleState::Offline);
        if result.is_ok() {
            println!("OFFLINE {:?}", runner.executor().status());
        }
        result
    };

    unload_result?;
    stop_result?;
    control_result?;
    Ok(())
}

#[allow(clippy::too_many_lines)]
fn control_session(runner: &mut Runner<LiveGraphAdapter>) -> Result<(), ScientificDiagnostic> {
    println!(
        "Commands: groups, status, properties GRAPH, property-generation GRAPH NODE, \
         parameter-generation GRAPH NODE, stop GROUP, start GROUP, session-stop, \
         session-start, source-ended, reset, properties-set GRAPH \
         NODE:PROPERTY TYPE VALUE [NODE:PROPERTY TYPE VALUE ...], \
         property GRAPH NODE:PROPERTY TYPE VALUE, \
         parameter GRAPH PORT ELEMENT_TYPE DIMS SCHEMA PATH, quit"
    );
    let main_loop = runner.executor().main_loop();
    let inputs = Rc::new(RefCell::new(VecDeque::new()));
    let queued_inputs = Rc::clone(&inputs);
    let (sender, receiver) = pipewire::channel::channel();
    // Dispatch outside this callback: runner effects may synchronize with the
    // core and dispatch this loop again while the channel lock is held.
    let _receiver = receiver.attach(main_loop.loop_(), move |input| {
        queued_inputs.borrow_mut().push_back(input);
    });
    std::thread::spawn(move || loop {
        let mut input = String::new();
        match std::io::stdin().read_line(&mut input) {
            Ok(0) => {
                let _ = sender.send(ControlInput::End);
                return;
            }
            Ok(_) => {
                if sender.send(ControlInput::Line(input)).is_err() {
                    return;
                }
            }
            Err(error) => {
                let _ = sender.send(ControlInput::Failed(error.to_string()));
                return;
            }
        }
    });
    print_prompt()?;
    let mut monitor_deadline = Instant::now() + Duration::from_millis(100);
    loop {
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
        let input = match input {
            Some(ControlInput::Line(input)) => input,
            Some(ControlInput::End) => return Ok(()),
            Some(ControlInput::Failed(error)) => {
                return Err(ScientificDiagnostic::new(
                    "command",
                    format!("cannot read control command: {error}"),
                ));
            }
            None => continue,
        };
        let fields = input.split_whitespace().collect::<Vec<_>>();
        match fields.as_slice() {
            [] => {}
            ["quit" | "exit"] => return Ok(()),
            ["groups"] => println!("{:?}", runner.execution_group_states()),
            ["status"] => {
                let counters = runner.executor_mut().observe_discarded_buffers()?;
                println!("{:?} discarded={counters:?}", runner.executor().status());
            }
            ["properties", graph] => println!(
                "PROPERTIES {graph} {:?}",
                runner.executor().observe_properties(graph)?
            ),
            ["property-generation", graph, node] => println!(
                "PROPERTY_GENERATION {graph} {node} {:?}",
                runner.executor().observe_property_generation(graph, node)?
            ),
            ["parameter-generation", graph, node] => println!(
                "PARAMETER_GENERATION {graph} {node} {:?}",
                runner
                    .executor()
                    .observe_parameter_generation(graph, node)?
            ),
            ["stop", name] => dispatch_group(
                runner,
                LifecycleEvent::StopExecutionGroup((*name).to_owned()),
            )?,
            ["start", name] => dispatch_group(
                runner,
                LifecycleEvent::StartExecutionGroup((*name).to_owned()),
            )?,
            ["session-stop"] => {
                dispatch_state_control(runner, LifecycleEvent::Stop, LifecycleState::Ready)?;
            }
            ["session-start"] => {
                dispatch_state_control(runner, LifecycleEvent::Start, LifecycleState::Running)?;
            }
            ["source-ended"] => {
                dispatch_ready_control(runner, LifecycleEvent::FiniteSourceCompleted)?;
            }
            ["reset"] => dispatch_ready_control(runner, LifecycleEvent::Reset)?,
            ["property", graph, name, value_type, value] => dispatch_control(
                runner,
                LifecycleEvent::UpdateProperties {
                    graph: (*graph).to_owned(),
                    values: BTreeMap::from([(
                        (*name).to_owned(),
                        parse_scalar(value_type, value)?,
                    )]),
                },
            )?,
            ["properties-set", graph, values @ ..]
                if !values.is_empty() && values.len() % 3 == 0 =>
            {
                let mut properties = BTreeMap::new();
                for fields in values.chunks_exact(3) {
                    if properties
                        .insert(fields[0].to_owned(), parse_scalar(fields[1], fields[2])?)
                        .is_some()
                    {
                        return Err(ScientificDiagnostic::new(
                            "command properties-set",
                            format!("duplicate property {:?}", fields[0]),
                        ));
                    }
                }
                dispatch_control(
                    runner,
                    LifecycleEvent::UpdateProperties {
                        graph: (*graph).to_owned(),
                        values: properties,
                    },
                )?;
            }
            ["parameter", graph, parameter, element_type, dimensions, schema, path] => {
                let bytes = std::fs::read(path).map_err(|error| {
                    ScientificDiagnostic::new(
                        "command parameter payload",
                        format!("cannot read {path:?}: {error}"),
                    )
                })?;
                dispatch_control(
                    runner,
                    LifecycleEvent::UpdateParameter {
                        graph: (*graph).to_owned(),
                        parameter: (*parameter).to_owned(),
                        value: NdArrayParameterValue {
                            element_type: (*element_type).to_owned(),
                            shape: parse_dimensions(dimensions)?,
                            schema: (*schema).to_owned(),
                            bytes,
                        },
                    },
                )?;
            }
            _ => eprintln!(
                "expected groups, status, properties GRAPH, property-generation GRAPH NODE, \
                 parameter-generation GRAPH NODE, stop GROUP, start GROUP, session-stop, \
                 session-start, source-ended, reset, properties-set GRAPH \
                 NODE:PROPERTY TYPE VALUE [NODE:PROPERTY TYPE VALUE ...], \
                 property GRAPH NODE:PROPERTY TYPE VALUE, \
                 parameter GRAPH PORT ELEMENT_TYPE DIMS SCHEMA PATH, or quit"
            ),
        }
        print_prompt()?;
    }
}

/// Pumps owner-thread callbacks, then monitors and takes one queued command.
/// No queue borrow spans monitoring or command execution, which can roundtrip.
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
        let error = std::io::Error::from_raw_os_error(-result);
        if error.kind() != std::io::ErrorKind::Interrupted {
            return Err(ScientificDiagnostic::new(
                "PipeWire main loop",
                format!("iteration failed: {error}"),
            ));
        }
    }
    // Check the deadline even during a command flood. MainLoop::quit() from
    // a synchronization callback must not skip queued commands or monitoring.
    if Instant::now() >= *monitor_deadline {
        monitor()?;
        *monitor_deadline = Instant::now() + Duration::from_millis(100);
    }
    Ok(inputs.borrow_mut().pop_front())
}

fn parse_dimensions(value: &str) -> Result<Vec<u32>, ScientificDiagnostic> {
    let dimensions = value
        .split('x')
        .map(|dimension| {
            dimension.parse::<u32>().map_err(|error| {
                ScientificDiagnostic::new(
                    "command parameter dimensions",
                    format!("invalid dimension {dimension:?} in {value:?}: {error}"),
                )
            })
        })
        .collect::<Result<Vec<_>, _>>()?;
    if dimensions.is_empty() || dimensions.contains(&0) {
        return Err(ScientificDiagnostic::new(
            "command parameter dimensions",
            format!("expected nonzero dimensions joined by 'x', got {value:?}"),
        ));
    }
    Ok(dimensions)
}

fn parse_scalar(value_type: &str, value: &str) -> Result<ScalarValue, ScientificDiagnostic> {
    let invalid = |message: String| ScientificDiagnostic::new("command property value", message);
    match value_type {
        "bool" => value
            .parse()
            .map(ScalarValue::Bool)
            .map_err(|error| invalid(format!("invalid bool {value:?}: {error}"))),
        "int" => value
            .parse()
            .map(ScalarValue::Int)
            .map_err(|error| invalid(format!("invalid int {value:?}: {error}"))),
        "long" => value
            .parse()
            .map(ScalarValue::Long)
            .map_err(|error| invalid(format!("invalid long {value:?}: {error}"))),
        "float" => value
            .parse()
            .map(ScalarValue::float)
            .map_err(|error| invalid(format!("invalid float {value:?}: {error}"))),
        "double" => value
            .parse()
            .map(ScalarValue::double)
            .map_err(|error| invalid(format!("invalid double {value:?}: {error}"))),
        "id" => value
            .parse()
            .map(ScalarValue::Id)
            .map_err(|error| invalid(format!("invalid id {value:?}: {error}"))),
        "string" => Ok(ScalarValue::String(value.to_owned())),
        _ => Err(ScientificDiagnostic::new(
            "command property type",
            format!("expected bool, int, long, float, double, id, or string; got {value_type:?}"),
        )),
    }
}

fn dispatch_ready_control(
    runner: &mut Runner<LiveGraphAdapter>,
    event: LifecycleEvent,
) -> Result<(), ScientificDiagnostic> {
    dispatch_state_control(runner, event, LifecycleState::Ready)
}

fn dispatch_state_control(
    runner: &mut Runner<LiveGraphAdapter>,
    event: LifecycleEvent,
    expected: LifecycleState,
) -> Result<(), ScientificDiagnostic> {
    match runner.dispatch(event) {
        Ok(state) if state == expected => {
            let label = match state {
                LifecycleState::Ready => "READY",
                LifecycleState::Running => "RUNNING",
                _ => unreachable!("session control expects READY or RUNNING"),
            };
            println!("{label} {:?}", runner.executor().status());
            Ok(())
        }
        Ok(state) => Err(runner.diagnostic().cloned().unwrap_or_else(|| {
            ScientificDiagnostic::new(
                "runtime control",
                format!("expected {expected:?}, reached {state:?}"),
            )
        })),
        Err(error) => {
            eprintln!("runtime control rejected: {error}");
            Ok(())
        }
    }
}

fn dispatch_control(
    runner: &mut Runner<LiveGraphAdapter>,
    event: LifecycleEvent,
) -> Result<(), ScientificDiagnostic> {
    let before = runner.state();
    match runner.dispatch(event) {
        Ok(state) if state == before => {
            println!("{state:?} {:?}", runner.executor().status());
            Ok(())
        }
        Ok(state) => Err(runner.diagnostic().cloned().unwrap_or_else(|| {
            ScientificDiagnostic::new(
                "runtime control",
                format!("expected {before:?}, reached {state:?}"),
            )
        })),
        Err(error) => {
            eprintln!("runtime control rejected: {error}");
            Ok(())
        }
    }
}

fn print_prompt() -> Result<(), ScientificDiagnostic> {
    print!("pipewireao-rtc> ");
    std::io::Write::flush(&mut std::io::stdout()).map_err(|error| {
        ScientificDiagnostic::new("command", format!("cannot flush prompt: {error}"))
    })
}

fn dispatch_group(
    runner: &mut Runner<LiveGraphAdapter>,
    event: LifecycleEvent,
) -> Result<(), ScientificDiagnostic> {
    match runner.dispatch(event) {
        Ok(LifecycleState::Running) => {
            println!("RUNNING {:?}", runner.executor().status());
            Ok(())
        }
        Ok(state) => Err(runner.diagnostic().cloned().unwrap_or_else(|| {
            ScientificDiagnostic::new(
                "execution-group control",
                format!("expected Running, reached {state:?}"),
            )
        })),
        Err(error) => {
            eprintln!("execution-group control rejected: {error}");
            Ok(())
        }
    }
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
            "--help" | "-h" => {
                println!(
                    "Usage: pipewireao-rtc --config PATH [--remote CORE] [--hold]\n\
                     Loads, starts, stops, and unloads one non-actuating complete-frame session."
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
    Ok(Arguments {
        config: config
            .ok_or_else(|| ScientificDiagnostic::new("command", "--config PATH is required"))?,
        remote,
        hold,
    })
}

#[cfg(test)]
mod tests {
    use super::parse_dimensions;

    use super::{next_control_input, ControlInput};
    use std::cell::{Cell, RefCell};
    use std::collections::VecDeque;
    use std::rc::Rc;
    use std::time::{Duration, Instant};

    #[test]
    fn owner_loop_services_timer_without_control_input_and_monitors_on_deadline() {
        let main_loop = pipewire::main_loop::MainLoopRc::new(None).unwrap();
        let ticks = Rc::new(Cell::new(0));
        let observed_ticks = Rc::clone(&ticks);
        let timer = main_loop.loop_().add_timer(move |_| {
            observed_ticks.set(observed_ticks.get() + 1);
        });
        timer
            .update_timer(
                Some(Duration::from_millis(2)),
                Some(Duration::from_millis(2)),
            )
            .into_result()
            .unwrap();
        let inputs = RefCell::new(VecDeque::new());
        let mut deadline = Instant::now() + Duration::from_millis(30);
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
        let sender_thread = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(10));
            sender.send(ControlInput::End).unwrap();
        });
        let mut deadline = Instant::now() + Duration::from_secs(2);
        let started = Instant::now();
        let input = next_control_input(main_loop.loop_(), &inputs, &mut deadline, || {
            panic!("control channel did not wake before the monitor deadline")
        })
        .unwrap();
        assert!(matches!(input, Some(ControlInput::End)));
        assert!(started.elapsed() < Duration::from_secs(1));
        sender_thread.join().unwrap();
    }

    #[test]
    fn owner_loop_checks_monitor_during_queued_command_flood() {
        let main_loop = pipewire::main_loop::MainLoopRc::new(None).unwrap();
        let inputs = RefCell::new(VecDeque::from([
            ControlInput::Line("first".to_owned()),
            ControlInput::Line("second".to_owned()),
            ControlInput::Failed("stdin failure".to_owned()),
        ]));
        let mut deadline = Instant::now();
        let mut monitors = 0;
        for expected_remaining in (0..3).rev() {
            deadline = deadline.min(Instant::now());
            let input = next_control_input(main_loop.loop_(), &inputs, &mut deadline, || {
                monitors += 1;
                Ok(())
            })
            .unwrap();
            assert!(input.is_some());
            assert_eq!(inputs.borrow().len(), expected_remaining);
        }
        assert_eq!(monitors, 3);
    }

    #[test]
    fn owner_loop_monitor_can_roundtrip_without_reentrant_command_dispatch() {
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
        sender.send(ControlInput::Line("first".to_owned())).unwrap();
        let mut deadline = Instant::now();
        let first = next_control_input(main_loop.loop_(), &inputs, &mut deadline, || {
            assert!(!in_callback.get());
            // Model a synchronous effect dispatching the same loop again.
            // Sending would deadlock if monitoring ran inside channel callback.
            sender
                .send(ControlInput::Line("second".to_owned()))
                .unwrap();
            main_loop.loop_().iterate(pipewire::loop_::Timeout::None);
            Ok(())
        })
        .unwrap();
        assert!(matches!(first, Some(ControlInput::Line(line)) if line == "first"));
        assert_eq!(inputs.borrow().len(), 1);
        let second =
            next_control_input(main_loop.loop_(), &inputs, &mut deadline, || Ok(())).unwrap();
        assert!(matches!(second, Some(ControlInput::Line(line)) if line == "second"));
    }

    #[test]
    fn parameter_dimensions_use_explicit_scientific_shape_order() {
        assert_eq!(parse_dimensions("277x376").unwrap(), [277, 376]);
        assert!(parse_dimensions("277x0").is_err());
        assert!(parse_dimensions("277,376").is_err());
        assert!(parse_dimensions("").is_err());
    }
}
