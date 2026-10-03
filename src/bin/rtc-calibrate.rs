#![cfg(unix)]

use pipewireao_rtc::calibration::{
    acquire_calibration, CalibrationFailure, CalibrationPhase, CalibrationPlan,
    CalibrationTimeouts, SettlingRule,
};
use pipewireao_rtc::calibration_socket::CalibrationSocketEndpoint;
use serde::Deserialize;
use serde_json::json;
use std::fs::File;
use std::io::{self, Read, Write};
use std::os::unix::net::UnixStream;
use std::sync::Arc;
use std::time::Duration;

const MAX_PLAN_BYTES: usize = 16 * 1024 * 1024;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct InputPlan {
    version: u8,
    run: u64,
    reference: Vec<f32>,
    probes: Vec<Vec<f32>>,
    measurements: usize,
    frames_per_probe: usize,
    settling: InputSettling,
    timeouts_ns: InputTimeouts,
}

#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
enum InputSettling {
    Immediate,
    DiscardExposures { frames: u32 },
    ModelTime { duration_ns: u64 },
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct InputTimeouts {
    ownership: u64,
    adoption: u64,
    settling: u64,
    collection: u64,
    restoration: u64,
}

fn read_plan(path: &str) -> Result<Vec<u8>, String> {
    let mut file = File::open(path).map_err(|error| format!("cannot open plan: {error}"))?;
    let mut bytes = Vec::new();
    Read::by_ref(&mut file)
        .take((MAX_PLAN_BYTES + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|error| format!("cannot read plan: {error}"))?;
    if bytes.len() > MAX_PLAN_BYTES {
        return Err("plan exceeds 16 MiB".into());
    }
    Ok(bytes)
}

fn parse_plan(bytes: &[u8]) -> Result<(u64, CalibrationPlan), String> {
    let input: InputPlan =
        serde_json::from_slice(bytes).map_err(|error| format!("invalid plan: {error}"))?;
    if input.version != 1 {
        return Err("unsupported plan version".into());
    }
    if input.run == 0 {
        return Err("run must be positive".into());
    }
    let settling = match input.settling {
        InputSettling::Immediate => SettlingRule::Immediate,
        InputSettling::DiscardExposures { frames } => SettlingRule::DiscardExposures(frames),
        InputSettling::ModelTime { duration_ns } => {
            SettlingRule::ModelTime(Duration::from_nanos(duration_ns))
        }
    };
    let timeouts = CalibrationTimeouts {
        ownership: Duration::from_nanos(input.timeouts_ns.ownership),
        adoption: Duration::from_nanos(input.timeouts_ns.adoption),
        settling: Duration::from_nanos(input.timeouts_ns.settling),
        collection: Duration::from_nanos(input.timeouts_ns.collection),
        restoration: Duration::from_nanos(input.timeouts_ns.restoration),
    };
    let probes = input.probes.into_iter().map(Arc::<[f32]>::from).collect();
    let plan = CalibrationPlan::new(
        Arc::from(input.reference),
        probes,
        input.measurements,
        input.frames_per_probe,
        settling,
        timeouts,
    )
    .map_err(|error| error.to_string())?;
    Ok((input.run, plan))
}

fn args() -> Result<(String, String), String> {
    let mut endpoint = None;
    let mut plan = None;
    let mut values = std::env::args().skip(1);
    while let Some(arg) = values.next() {
        let slot = match arg.as_str() {
            "--endpoint" if endpoint.is_none() => &mut endpoint,
            "--plan" if plan.is_none() => &mut plan,
            "--endpoint" | "--plan" => return Err(format!("duplicate option: {arg}")),
            _ => return Err(format!("unknown argument: {arg}")),
        };
        let value = values
            .next()
            .ok_or_else(|| format!("missing value for {arg}"))?;
        if value.starts_with("--") || value.is_empty() {
            return Err(format!("missing value for {arg}"));
        }
        *slot = Some(value);
    }
    Ok((
        endpoint.ok_or("required option --endpoint is missing")?,
        plan.ok_or("required option --plan is missing")?,
    ))
}

fn phase_name(phase: CalibrationPhase) -> &'static str {
    match phase {
        CalibrationPhase::Complete => "complete",
        CalibrationPhase::Aborted => "aborted",
        _ => "fault",
    }
}

fn output_failure(value: Option<CalibrationFailure>) -> Option<String> {
    value.map(|failure| format!("{failure:?}"))
}

fn emit(
    run: u64,
    coordinator: &pipewireao_rtc::calibration::CalibrationCoordinator,
) -> io::Result<()> {
    let complete = coordinator.phase() == CalibrationPhase::Complete;
    let responses = if complete {
        coordinator.responses().map(|batches| {
            batches
                .iter()
                .map(|batch| {
                    json!({
                        "values": batch.values,
                        "exposures": batch.exposures.iter().map(|e| json!({
                            "domain":e.domain,"generation":e.generation,"sequence":e.sequence,
                            "start_model_ns":e.start_model_ns,"duration_ns":e.duration_ns,
                        })).collect::<Vec<_>>(),
                        "valid": batch.valid,
                    })
                })
                .collect::<Vec<_>>()
        })
    } else {
        None
    };
    let result = json!({
        "version":1,
        "run":run,
        "phase":phase_name(coordinator.phase()),
        "restoration_confirmed":coordinator.restoration_confirmed(),
        "resume_permitted":coordinator.resume_permitted(),
        "failure":output_failure(coordinator.failure()),
        "recovery_failure":output_failure(coordinator.recovery_failure()),
        "responses":responses,
    });
    serde_json::to_writer(io::stdout().lock(), &result)?;
    io::stdout().lock().write_all(b"\n")
}

fn run() -> Result<i32, String> {
    let (endpoint_path, plan_path) = args()?;
    let bytes = read_plan(&plan_path)?;
    let (run, plan) = parse_plan(&bytes)?;
    let stream = UnixStream::connect(endpoint_path)
        .map_err(|error| format!("cannot connect endpoint: {error}"))?;
    let mut endpoint = CalibrationSocketEndpoint::new(stream)
        .map_err(|error| format!("cannot prepare endpoint: {error}"))?;
    let coordinator =
        acquire_calibration(&mut endpoint, run, plan).map_err(|error| error.to_string())?;
    let successful = coordinator.phase() == CalibrationPhase::Complete;
    emit(run, &coordinator).map_err(|error| format!("cannot write result: {error}"))?;
    Ok(i32::from(!successful))
}

fn main() {
    match run() {
        Ok(code) => std::process::exit(code),
        Err(error) => {
            eprintln!("rtc-calibrate: {error}");
            std::process::exit(2);
        }
    }
}
