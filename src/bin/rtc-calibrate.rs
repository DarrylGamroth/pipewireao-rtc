#![cfg(unix)]

use pipewireao_rtc::calibration::{
    acquire_calibration, AcquisitionCursor, CalibrationAction, CalibrationCompletion,
    CalibrationEffect, CalibrationEndpoint, CalibrationEvidence, CalibrationFailure,
    CalibrationPhase, CalibrationPlan, CalibrationTimeouts, SettlingRule,
};
use pipewireao_rtc::native_calibration_action_codec::{self as codec, Rule};
use pipewireao_rtc::native_calibration_endpoint::{Binding, NativeCalibrationEndpoint};
use pipewireao_rtc::native_control_codec::CALIBRATION_REPLY_BOUND;
use serde::Deserialize;
use serde_json::json;
use std::fs::{File, OpenOptions};
use std::io::{self, Read, Write};
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};

const MAX_PLAN_BYTES: usize = 16 * 1024 * 1024;
const MAX_EVIDENCE_BYTES: usize = 64 * 1024 * 1024;
const EVIDENCE_ERROR_RESERVE: usize = 256;
const EVIDENCE_RECORD_CHARGE: usize = 8192;
const EVIDENCE_EXPOSURE_CHARGE: usize = 2048;

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

fn parse_plan(bytes: &[u8]) -> Result<(u64, CalibrationPlan, Duration, usize), String> {
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
    let probe_count = input.probes.len();
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
    Ok((input.run, plan, timeouts.ownership, probe_count))
}

fn parse_args(
    mut values: impl Iterator<Item = String>,
) -> Result<(Binding, String, Option<String>), String> {
    let mut remote = None;
    let mut node = None;
    let mut owner_pid = None;
    let mut owner_instance = None;
    let mut plan = None;
    let mut evidence = None;
    while let Some(arg) = values.next() {
        let slot = match arg.as_str() {
            "--remote" => &mut remote,
            "--node" => &mut node,
            "--owner-pid" => &mut owner_pid,
            "--owner-instance" => &mut owner_instance,
            "--plan" => &mut plan,
            "--evidence" => &mut evidence,
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
    Ok((
        binding,
        plan.ok_or("required option --plan is missing")?,
        evidence,
    ))
}
fn args() -> Result<(Binding, String, Option<String>), String> {
    parse_args(std::env::args().skip(1))
}

fn cursor_json(cursor: AcquisitionCursor) -> serde_json::Value {
    json!({"domain":cursor.domain,"generation":cursor.generation,
        "sequence":cursor.sequence,"model_ns":cursor.model_ns})
}

fn action_json(action: &CalibrationAction) -> serde_json::Value {
    match action {
        CalibrationAction::Hold => json!({"kind":"hold"}),
        CalibrationAction::Adopt { probe, figure } => {
            json!({"kind":"adopt","probe":probe,"figure":figure.as_ref()})
        }
        CalibrationAction::Settle { probe, after, rule } => {
            json!({"kind":"settle","probe":probe,"after":cursor_json(*after),"rule":format!("{rule:?}")})
        }
        CalibrationAction::Collect {
            probe,
            after,
            measurements,
            frames,
        } => json!({"kind":"collect","probe":probe,"after":cursor_json(*after),
                "measurements":measurements,"frames":frames}),
        CalibrationAction::Restore { figure, rule } => {
            json!({"kind":"restore","figure":figure.as_ref(),"rule":format!("{rule:?}")})
        }
        CalibrationAction::Release => json!({"kind":"release"}),
    }
}

fn completion_json(completion: &CalibrationCompletion) -> serde_json::Value {
    match &completion.result {
        Err(failure) => json!({"kind":"failure","failure":format!("{failure:?}")}),
        Ok(CalibrationEvidence::Held(cursor)) => {
            json!({"kind":"held","cursor":cursor_json(*cursor)})
        }
        Ok(CalibrationEvidence::Adopted {
            cursor,
            figure,
            clipped,
        }) => {
            json!({"kind":"adopted","cursor":cursor_json(*cursor),"figure":figure.as_ref(),"clipped":clipped})
        }
        Ok(CalibrationEvidence::Settled(cursor)) => {
            json!({"kind":"settled","cursor":cursor_json(*cursor)})
        }
        Ok(CalibrationEvidence::Responses(batch)) => json!({"kind":"responses","valid":batch.valid,
            "values":batch.values,"exposures":batch.exposures.iter().map(|e| json!({
                "domain":e.domain,"generation":e.generation,"sequence":e.sequence,
                "start_model_ns":e.start_model_ns,"duration_ns":e.duration_ns,
            })).collect::<Vec<_>>()}),
        Ok(CalibrationEvidence::Restored { figure, clipped }) => {
            json!({"kind":"restored","figure":figure.as_ref(),"clipped":clipped})
        }
        Ok(CalibrationEvidence::Released) => json!({"kind":"released"}),
    }
}

fn action_charge(action: &CalibrationAction) -> usize {
    let figure = match action {
        CalibrationAction::Adopt { figure, .. } | CalibrationAction::Restore { figure, .. } => {
            figure.len()
        }
        _ => 0,
    };
    EVIDENCE_RECORD_CHARGE + figure * 64
}

fn completion_charge(completion: &CalibrationCompletion) -> usize {
    let (values, exposures) = match &completion.result {
        Ok(CalibrationEvidence::Responses(batch)) => (batch.values.len(), batch.exposures.len()),
        Ok(
            CalibrationEvidence::Adopted { figure, .. }
            | CalibrationEvidence::Restored { figure, .. },
        ) => (figure.len(), 0),
        _ => (0, 0),
    };
    EVIDENCE_RECORD_CHARGE
        .saturating_add(values.saturating_mul(64))
        .saturating_add(exposures.saturating_mul(EVIDENCE_EXPOSURE_CHARGE))
}

/// Cold-side memory journal, written to JSONL after acquisition. The native
/// endpoint has at most one terminal per submission; the coordinator bounds
/// the number of submissions.
struct EvidenceEndpoint<E> {
    inner: E,
    journal: EvidenceJournal,
    last_cursor: Option<AcquisitionCursor>,
}

struct EvidenceJournal {
    file: File,
    limit: usize,
    retained: usize,
    records: Vec<serde_json::Value>,
    error: Option<String>,
}

impl EvidenceJournal {
    fn create(path: &Path, probes: usize) -> Result<Self, String> {
        let actions = probes
            .checked_mul(3)
            .and_then(|n| n.checked_add(3))
            .ok_or("evidence action count overflow")?;
        // JSON expands Float32 numbers and names beyond their binary POD size.
        // The ceiling also prevents an enormous valid plan filling a volume.
        let limit = actions
            .checked_mul(65)
            .and_then(|n| n.checked_mul(CALIBRATION_REPLY_BOUND))
            .and_then(|n| n.checked_mul(8))
            .ok_or("evidence size overflow")?
            .min(MAX_EVIDENCE_BYTES);
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(path)
            .map_err(|e| format!("cannot create evidence file: {e}"))?;
        let header = format!(
            "{{\"event\":\"header\",\"version\":1,\"probe_count\":{probes},\"max_charged_bytes\":{limit}}}\n"
        );
        file.write_all(header.as_bytes())
            .and_then(|()| file.flush())
            .map_err(|e| format!("cannot preflight evidence file: {e}"))?;
        Ok(Self {
            file,
            limit,
            retained: header.len(),
            records: Vec::new(),
            error: None,
        })
    }

    fn record(&mut self, charge: usize, value: impl FnOnce() -> serde_json::Value) {
        if self.error.is_some() {
            return;
        }
        // Charge nested JSON objects and construction temporaries before
        // retaining records. This is a conservative budget, not measured RSS
        // or an allocator-independent heap limit. No file I/O occurs here.
        if let Some(next) = self
            .retained
            .checked_add(charge)
            .filter(|n| *n <= self.limit - EVIDENCE_ERROR_RESERVE)
        {
            self.retained = next;
            self.records.push(value());
        } else {
            self.error = Some("evidence size limit exceeded".into());
        }
    }

    fn finish(mut self) -> Result<(), String> {
        for record in self.records {
            serde_json::to_writer(&mut self.file, &record)
                .map_err(|e| format!("cannot write evidence: {e}"))?;
            self.file
                .write_all(b"\n")
                .map_err(|e| format!("cannot write evidence: {e}"))?;
        }
        if let Some(error) = &self.error {
            serde_json::to_writer(
                &mut self.file,
                &json!({"event":"evidence_error","reason":error}),
            )
            .map_err(|e| format!("cannot write evidence error: {e}"))?;
            self.file
                .write_all(b"\n")
                .map_err(|e| format!("cannot write evidence error: {e}"))?;
        }
        self.file
            .flush()
            .map_err(|e| format!("cannot flush evidence: {e}"))?;
        self.file
            .sync_all()
            .map_err(|e| format!("cannot sync evidence: {e}"))?;
        if let Some(error) = self.error {
            return Err(error);
        }
        Ok(())
    }
}

impl<E: CalibrationEndpoint> CalibrationEndpoint for EvidenceEndpoint<E> {
    fn submit(&mut self, effect: &CalibrationEffect) -> Result<(), CalibrationFailure> {
        let result = self.inner.submit(effect);
        let prior_received_cursor = self.last_cursor.map(cursor_json);
        self.journal.record(action_charge(&effect.action), || {
            json!({"event":"submit","run":effect.request.run,
            "serial":effect.request.serial,"action":action_json(&effect.action),
            "prior_received_cursor":prior_received_cursor,"accepted":result.is_ok(),
            "failure":result.err().map(|e| format!("{e:?}"))})
        });
        result
    }

    fn receive(
        &mut self,
        deadline: Instant,
    ) -> Result<Option<CalibrationCompletion>, CalibrationFailure> {
        let result = self.inner.receive(deadline);
        if let Ok(Some(completion)) = &result {
            self.journal.record(completion_charge(completion), || {
                json!({"event":"completion","run":completion.request.run,
                "serial":completion.request.serial,"result":completion_json(completion)})
            });
            self.last_cursor = match &completion.result {
                Ok(CalibrationEvidence::Held(c) | CalibrationEvidence::Settled(c)) => Some(*c),
                Ok(CalibrationEvidence::Adopted { cursor, .. }) => Some(*cursor),
                Ok(CalibrationEvidence::Responses(batch)) => batch.exposures.last().and_then(|e| {
                    e.start_model_ns
                        .checked_add(e.duration_ns)
                        .map(|model_ns| AcquisitionCursor {
                            domain: e.domain,
                            generation: e.generation,
                            sequence: e.sequence,
                            model_ns,
                        })
                }),
                _ => self.last_cursor,
            };
        } else if let Err(failure) = &result {
            self.journal.record(
                EVIDENCE_RECORD_CHARGE,
                || json!({"event":"receive_failure","failure":format!("{failure:?}")}),
            );
        } else {
            self.journal.record(
                EVIDENCE_RECORD_CHARGE,
                || json!({"event":"receive_timeout"}),
            );
        }
        result
    }

    fn fault(&mut self, failure: CalibrationFailure) {
        self.journal.record(
            EVIDENCE_RECORD_CHARGE,
            || json!({"event":"fault","failure":format!("{failure:?}")}),
        );
        self.inner.fault(failure);
    }
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
    let (binding, plan_path, evidence_path) = args()?;
    let bytes = read_plan(&plan_path)?;
    let (run, plan, connection_timeout, probes) = parse_plan(&bytes)?;
    // Create and prove writable before connecting or requesting a hold.
    let evidence_file = evidence_path
        .as_deref()
        .map(|path| EvidenceJournal::create(Path::new(path), probes))
        .transpose()?;
    let deadline = Instant::now()
        .checked_add(connection_timeout)
        .ok_or("connection deadline overflow")?;
    let mut endpoint = NativeCalibrationEndpoint::connect(binding, deadline)
        .map_err(|error| format!("cannot prove native endpoint: {error}"))?;
    let (coordinator, evidence_error) = if let Some(journal) = evidence_file {
        let mut endpoint = EvidenceEndpoint {
            inner: endpoint,
            journal,
            last_cursor: None,
        };
        let coordinator =
            acquire_calibration(&mut endpoint, run, plan).map_err(|error| error.to_string())?;
        endpoint.journal.record(EVIDENCE_RECORD_CHARGE, || {
            json!({"event":"coordinator","run":run,"phase":phase_name(coordinator.phase()),
                "failure":output_failure(coordinator.failure()),
                "recovery_failure":output_failure(coordinator.recovery_failure()),
                "restoration_confirmed":coordinator.restoration_confirmed(),
                "resume_permitted":coordinator.resume_permitted()})
        });
        (coordinator, endpoint.journal.finish().err())
    } else {
        (
            acquire_calibration(&mut endpoint, run, plan).map_err(|error| error.to_string())?,
            None,
        )
    };
    let successful = coordinator.phase() == CalibrationPhase::Complete;
    emit(run, &coordinator).map_err(|error| format!("cannot write result: {error}"))?;
    if let Some(error) = evidence_error {
        return Err(error);
    }
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
    use pipewireao_rtc::calibration::{Exposure, ResponseBatch};
    use tempfile::tempdir;
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
        let (binding, plan, evidence) = parse_args(values().into_iter()).unwrap();
        assert_eq!(binding.remote, "/tmp/private/pw");
        assert_eq!(binding.owner_pid, 7);
        assert_eq!(binding.instance, 42);
        assert_eq!(plan, "plan.json");
        assert!(evidence.is_none());
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

    #[test]
    fn evidence_charges_nested_objects_and_exposure_temporaries() {
        let after = AcquisitionCursor {
            domain: 1,
            generation: 1,
            sequence: 1,
            model_ns: 1,
        };
        let action = CalibrationAction::Settle {
            probe: 0,
            after,
            rule: SettlingRule::Immediate,
        };
        assert_eq!(action_charge(&action), 8192);
        let completion = CalibrationCompletion {
            request: pipewireao_rtc::calibration::CalibrationRequest { run: 1, serial: 1 },
            result: Ok(CalibrationEvidence::Responses(ResponseBatch {
                values: vec![1.0],
                exposures: vec![Exposure {
                    domain: 1,
                    generation: 1,
                    sequence: 2,
                    start_model_ns: 1,
                    duration_ns: 1,
                }],
                valid: true,
            })),
        };
        assert_eq!(completion_charge(&completion), 8192 + 64 + 2048);
    }

    #[test]
    fn evidence_preflight_preserves_existing_file_and_overflow_is_reported() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("evidence.jsonl");
        std::fs::write(&path, "existing").unwrap();
        assert!(EvidenceJournal::create(&path, 1).is_err());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "existing");

        let fresh = dir.path().join("fresh.jsonl");
        let mut journal = EvidenceJournal::create(&fresh, 1).unwrap();
        journal.limit = journal.retained + 1024 + EVIDENCE_ERROR_RESERVE;
        journal.record(1024, || json!({"event":"first"}));
        journal.record(1024, || panic!("must not build a dropped record"));
        assert!(journal
            .finish()
            .unwrap_err()
            .contains("size limit exceeded"));
        let text = std::fs::read_to_string(&fresh).unwrap();
        assert!(text.contains("\"event\":\"header\""));
        assert!(text.contains("\"event\":\"first\""));
        assert!(text.contains("\"event\":\"evidence_error\""));
    }

    struct InvalidAt {
        action: Option<CalibrationEffect>,
        second_adopt: bool,
    }

    impl CalibrationEndpoint for InvalidAt {
        fn submit(&mut self, effect: &CalibrationEffect) -> Result<(), CalibrationFailure> {
            self.action = Some(effect.clone());
            Ok(())
        }

        fn receive(
            &mut self,
            _deadline: Instant,
        ) -> Result<Option<CalibrationCompletion>, CalibrationFailure> {
            let effect = self.action.take().unwrap();
            let zero = AcquisitionCursor {
                domain: 1,
                generation: 1,
                sequence: 0,
                model_ns: 0,
            };
            let result = match effect.action {
                CalibrationAction::Hold => CalibrationEvidence::Held(zero),
                CalibrationAction::Adopt { probe, figure } => CalibrationEvidence::Adopted {
                    cursor: if probe == 1 && self.second_adopt {
                        zero
                    } else if probe == 1 {
                        AcquisitionCursor {
                            sequence: 1,
                            model_ns: 1,
                            ..zero
                        }
                    } else {
                        zero
                    },
                    figure,
                    clipped: false,
                },
                CalibrationAction::Settle { after, .. } => CalibrationEvidence::Settled(after),
                CalibrationAction::Collect { .. } => {
                    CalibrationEvidence::Responses(ResponseBatch {
                        values: vec![0.25, 0.5],
                        exposures: vec![Exposure {
                            domain: 1,
                            generation: 1,
                            sequence: 1,
                            start_model_ns: 0,
                            duration_ns: 1,
                        }],
                        valid: self.second_adopt,
                    })
                }
                CalibrationAction::Restore { figure, .. } => CalibrationEvidence::Restored {
                    figure,
                    clipped: false,
                },
                CalibrationAction::Release => CalibrationEvidence::Released,
            };
            Ok(Some(CalibrationCompletion {
                request: effect.request,
                result: Ok(result),
            }))
        }

        fn fault(&mut self, _failure: CalibrationFailure) {}
    }

    #[test]
    fn aborted_journal_identifies_first_collect_or_second_adopt() {
        for second_adopt in [false, true] {
            let dir = tempdir().unwrap();
            let path = dir.path().join("evidence.jsonl");
            let mut input = plan();
            input["probes"] = json!([[1, 2], [2, 1]]);
            let (run, plan, _, probes) = parse_plan(&serde_json::to_vec(&input).unwrap()).unwrap();
            let mut endpoint = EvidenceEndpoint {
                inner: InvalidAt {
                    action: None,
                    second_adopt,
                },
                journal: EvidenceJournal::create(&path, probes).unwrap(),
                last_cursor: None,
            };
            let result = acquire_calibration(&mut endpoint, run, plan).unwrap();
            assert_eq!(result.phase(), CalibrationPhase::Aborted);
            assert_eq!(result.failure(), Some(CalibrationFailure::InvalidEvidence));
            assert!(result.responses().is_none());
            endpoint.journal.finish().unwrap();
            let records: Vec<serde_json::Value> = std::fs::read_to_string(&path)
                .unwrap()
                .lines()
                .map(|line| serde_json::from_str(line).unwrap())
                .collect();
            let submits: Vec<_> = records.iter().filter(|r| r["event"] == "submit").collect();
            let completions: Vec<_> = records
                .iter()
                .filter(|r| r["event"] == "completion")
                .collect();
            assert_eq!(submits.len(), completions.len());
            for (submit, completion) in submits.iter().zip(completions.iter()) {
                assert_eq!(submit["run"], completion["run"]);
                assert_eq!(submit["serial"], completion["serial"]);
            }
            let collect = records
                .iter()
                .find(|r| r["result"]["kind"] == "responses")
                .unwrap();
            assert_eq!(collect["result"]["values"], json!([0.25, 0.5]));
            assert_eq!(collect["result"]["exposures"][0]["sequence"], 1);
            if second_adopt {
                assert_eq!(collect["result"]["valid"], true);
                let rejected = records
                    .iter()
                    .find(|r| r["event"] == "completion" && r["serial"] == 5)
                    .unwrap();
                assert_eq!(rejected["result"]["kind"], "adopted");
                assert_eq!(rejected["result"]["cursor"]["sequence"], 0);
                assert_eq!(submits[4]["action"]["kind"], "adopt");
                assert_eq!(submits[4]["action"]["probe"], 1);
                assert_eq!(submits[4]["prior_received_cursor"]["sequence"], 1);
            } else {
                assert_eq!(collect["result"]["valid"], false);
                assert_eq!(collect["serial"], 4);
                assert_eq!(submits[3]["action"]["kind"], "collect");
                assert_eq!(submits[3]["action"]["probe"], 0);
                assert_eq!(submits[3]["action"]["after"]["sequence"], 0);
            }
            assert_eq!(submits.last().unwrap()["action"]["kind"], "release");
        }
    }
}
