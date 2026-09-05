use pipewireao_rtc::{
    ConfigurationInput, LifecycleEvent, LifecycleState, LiveGraphAdapter, NdArrayParameterValue,
    Runner, ScalarValue, ScientificDiagnostic,
};
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::mpsc::{self, RecvTimeoutError};
use std::time::Duration;

struct Arguments {
    config: PathBuf,
    remote: String,
    hold: bool,
}

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
        "Commands: groups, status, stop GROUP, start GROUP, reset, \
         property GRAPH NODE:PROPERTY TYPE VALUE, \
         parameter GRAPH PORT ELEMENT_TYPE DIMS SCHEMA PATH, quit"
    );
    let (sender, receiver) = mpsc::channel();
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
    loop {
        let input = match receiver.recv_timeout(Duration::from_millis(100)) {
            Ok(ControlInput::Line(input)) => input,
            Ok(ControlInput::End) | Err(RecvTimeoutError::Disconnected) => return Ok(()),
            Ok(ControlInput::Failed(error)) => {
                return Err(ScientificDiagnostic::new(
                    "command",
                    format!("cannot read control command: {error}"),
                ));
            }
            Err(RecvTimeoutError::Timeout) => {
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
                continue;
            }
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
            ["stop", name] => dispatch_group(
                runner,
                LifecycleEvent::StopExecutionGroup((*name).to_owned()),
            )?,
            ["start", name] => dispatch_group(
                runner,
                LifecycleEvent::StartExecutionGroup((*name).to_owned()),
            )?,
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
                "expected groups, status, stop GROUP, start GROUP, reset, \
                 property GRAPH NODE:PROPERTY TYPE VALUE, \
                 parameter GRAPH PORT ELEMENT_TYPE DIMS SCHEMA PATH, or quit"
            ),
        }
        print_prompt()?;
    }
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
    match runner.dispatch(event) {
        Ok(LifecycleState::Ready) => {
            println!("READY {:?}", runner.executor().status());
            Ok(())
        }
        Ok(state) => Err(runner.diagnostic().cloned().unwrap_or_else(|| {
            ScientificDiagnostic::new(
                "runtime control",
                format!("expected Ready, reached {state:?}"),
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

    #[test]
    fn parameter_dimensions_use_explicit_scientific_shape_order() {
        assert_eq!(parse_dimensions("277x376").unwrap(), [277, 376]);
        assert!(parse_dimensions("277x0").is_err());
        assert!(parse_dimensions("277,376").is_err());
        assert!(parse_dimensions("").is_err());
    }
}
