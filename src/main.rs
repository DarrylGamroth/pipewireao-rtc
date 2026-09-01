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
    if arguments.hold {
        println!("Press Enter to stop and unload.");
        let mut input = String::new();
        std::io::stdin().read_line(&mut input)?;
    }

    require_state(&mut runner, LifecycleEvent::Stop, LifecycleState::Ready)?;
    println!("READY {:?}", runner.executor().status());
    require_state(&mut runner, LifecycleEvent::Unload, LifecycleState::Offline)?;
    println!("OFFLINE {:?}", runner.executor().status());
    Ok(())
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
