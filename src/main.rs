use pipewireao_rtc::{
    ConfigurationInput, LifecycleEvent, LifecycleState, LiveGraphAdapter, Runner,
    ScientificDiagnostic,
};
use std::path::PathBuf;

struct Arguments {
    config: PathBuf,
    remote: String,
    hold: bool,
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

fn control_session(runner: &mut Runner<LiveGraphAdapter>) -> Result<(), ScientificDiagnostic> {
    println!("Commands: groups, status, stop GROUP, start GROUP, quit");
    loop {
        print!("pipewireao-rtc> ");
        std::io::Write::flush(&mut std::io::stdout()).map_err(|error| {
            ScientificDiagnostic::new("command", format!("cannot flush prompt: {error}"))
        })?;
        let mut input = String::new();
        let bytes = std::io::stdin().read_line(&mut input).map_err(|error| {
            ScientificDiagnostic::new("command", format!("cannot read control command: {error}"))
        })?;
        if bytes == 0 {
            return Ok(());
        }
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
            _ => eprintln!("expected groups, status, stop GROUP, start GROUP, or quit"),
        }
    }
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
