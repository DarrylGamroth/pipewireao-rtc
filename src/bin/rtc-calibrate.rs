#![cfg(unix)]

use pipewireao_rtc::calibration::{
    acquire_calibration, CalibrationFailure, CalibrationPhase, CalibrationPlan,
    CalibrationTimeouts, SettlingRule,
};
use pipewireao_rtc::native_calibration_action_codec::{self as codec, Rule};
use pipewireao_rtc::native_calibration_endpoint::{Binding, NativeCalibrationEndpoint};
use serde::Deserialize;
use serde_json::json;
use std::fs::File;
use std::io::{self, Read, Write};
use std::sync::Arc;
use std::time::{Duration, Instant};

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

fn parse_plan(bytes: &[u8]) -> Result<(u64, CalibrationPlan, Duration), String> {
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
    let wire_rule = match settling {
        SettlingRule::Immediate => Rule::Immediate,
        SettlingRule::DiscardExposures(frames) => Rule::DiscardExposures(frames),
        SettlingRule::ModelTime(duration) => Rule::ModelTime(
            u64::try_from(duration.as_nanos()).map_err(|_| "settling duration exceeds UInt64")?,
        ),
    };
    codec::preflight_figure_request(&input.reference, Some(wire_rule))
        .map_err(|e| e.to_string())?;
    for figure in &input.probes {
        codec::preflight_figure_request(figure, None).map_err(|e| e.to_string())?;
    }
    codec::preflight_collect_reply(input.measurements, input.frames_per_probe, 0)
        .map_err(|e| e.to_string())?;
    for timeout in [
        timeouts.ownership,
        timeouts.adoption,
        timeouts.settling,
        timeouts.collection,
        timeouts.restoration,
    ] {
        if timeout.as_nanos() > i64::MAX as u128 {
            return Err("request timeout exceeds Int64 nanoseconds".into());
        }
    }
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
    Ok((input.run, plan, timeouts.ownership))
}

fn parse_args(mut values: impl Iterator<Item = String>) -> Result<(Binding, String), String> {
    let mut remote = None;
    let mut node = None;
    let mut owner_pid = None;
    let mut owner_instance = None;
    let mut plan = None;
    while let Some(arg) = values.next() {
        let slot = match arg.as_str() {
            "--remote" => &mut remote,
            "--node" => &mut node,
            "--owner-pid" => &mut owner_pid,
            "--owner-instance" => &mut owner_instance,
            "--plan" => &mut plan,
            _ => return Err(format!("unknown argument: {arg}")),
        };
        if slot.is_some() {
            return Err(format!("duplicate option: {arg}"));
        }
        let value = values
            .next()
            .ok_or_else(|| format!("missing value for {arg}"))?;
        if value.starts_with("--") || value.is_empty() {
            return Err(format!("missing value for {arg}"));
        }
        *slot = Some(value);
    }
    let pid = owner_pid
        .ok_or("required option --owner-pid is missing")?
        .parse::<u32>()
        .map_err(|_| "invalid owner PID")?;
    let instance = owner_instance
        .ok_or("required option --owner-instance is missing")?
        .parse::<i64>()
        .map_err(|_| "invalid owner incarnation")?;
    let binding = Binding::new(
        remote.ok_or("required option --remote is missing")?,
        node.ok_or("required option --node is missing")?,
        pid,
        instance,
    )?;
    Ok((binding, plan.ok_or("required option --plan is missing")?))
}
fn args() -> Result<(Binding, String), String> {
    parse_args(std::env::args().skip(1))
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
    let (binding, plan_path) = args()?;
    let bytes = read_plan(&plan_path)?;
    let (run, plan, connection_timeout) = parse_plan(&bytes)?;
    let deadline = Instant::now()
        .checked_add(connection_timeout)
        .ok_or("connection deadline overflow")?;
    let mut endpoint = NativeCalibrationEndpoint::connect(binding, deadline)
        .map_err(|error| format!("cannot prove native endpoint: {error}"))?;
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

#[cfg(test)]
mod tests {
    use super::*;
    fn values() -> Vec<String> {
        [
            "--remote",
            "/tmp/private/pw",
            "--node",
            "owner.actions",
            "--owner-pid",
            "7",
            "--owner-instance",
            "42",
            "--plan",
            "plan.json",
        ]
        .map(str::to_owned)
        .to_vec()
    }
    #[test]
    fn explicit_binding_is_required_and_legacy_endpoint_has_no_fallback() {
        let (binding, plan) = parse_args(values().into_iter()).unwrap();
        assert_eq!(binding.remote, "/tmp/private/pw");
        assert_eq!(binding.owner_pid, 7);
        assert_eq!(binding.instance, 42);
        assert_eq!(plan, "plan.json");
        for args in [
            vec!["--endpoint", "/tmp/calibration.sock", "--plan", "plan.json"],
            vec!["--remote"],
            vec!["--plan", "plan.json"],
        ] {
            assert!(parse_args(args.into_iter().map(str::to_owned)).is_err());
        }
        let mut duplicate = values();
        duplicate.extend(["--node".into(), "other".into()]);
        assert!(parse_args(duplicate.into_iter()).is_err());
        for (index, value) in [
            (1, "relative"),
            (5, "0"),
            (7, "0"),
            (7, "18446744073709551615"),
        ] {
            let mut args = values();
            args[index] = value.into();
            assert!(parse_args(args.into_iter()).is_err());
        }
    }
    fn plan() -> serde_json::Value {
        json!({"version":1,"run":u64::MAX,"reference":[0,0],"probes":[[1,2]],"measurements":2,
            "frames_per_probe":1,"settling":{"kind":"immediate"},
            "timeouts_ns":{"ownership":5_000_000_000_u64,"adoption":5_000_000_000_u64,
                "settling":5_000_000_000_u64,"collection":5_000_000_000_u64,"restoration":5_000_000_000_u64}})
    }
    #[test]
    fn complete_native_wire_plan_preflight_precedes_connection_and_hold() {
        let valid = plan();
        assert_eq!(
            parse_plan(&serde_json::to_vec(&valid).unwrap()).unwrap().0,
            u64::MAX
        );
        let mut oversized = valid.clone();
        oversized["reference"] = json!(vec![1_f32; 4096]);
        oversized["probes"] = json!([vec![1_f32; 4096]]);
        assert!(parse_plan(&serde_json::to_vec(&oversized).unwrap()).is_err());
        let mut reply = valid.clone();
        reply["measurements"] = json!(131_072);
        assert!(parse_plan(&serde_json::to_vec(&reply).unwrap()).is_err());
        let mut rule = valid.clone();
        rule["settling"] = json!({"kind":"model_time","duration_ns":u64::MAX});
        assert!(parse_plan(&serde_json::to_vec(&rule).unwrap()).is_err());
        let mut budget = valid;
        budget["timeouts_ns"]["ownership"] = json!(u64::MAX);
        assert!(parse_plan(&serde_json::to_vec(&budget).unwrap()).is_err());
    }
}
