//! Public deployment supervisor codec foundation. No lifecycle effects occur here.
//! The profile is distinct from the internal runner; typed commands/results are reused.
use crate::control::{Command, ControlError, ExecutionResult};
use crate::native_control_codec::{self as envelope, ReplyHeader, RequestHeader};
use crate::LifecycleState;
use crate::{native_runner_codec as runner, native_runner_result as result};
use pipewire::spa::pod::Value;
use pipewire::spa::utils::Id;
use std::collections::BTreeSet;

pub const PROFILE: &str = "pipewireao.rtc.deployment-supervisor/1";
const MAX_PROCESSES: usize = 32;
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum Phase {
    Preparing = 1,
    Admitted = 2,
    Failed = 3,
    Stopping = 4,
    Stopped = 5,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum ColdLifecycle {
    Preparing = 1,
    Prepared = 2,
    Connected = 3,
    Fault = 4,
    Stopped = 5,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum Instrument {
    Classic = 1,
    Copper = 2,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum HeartLifecycle {
    Preparing = 1,
    Ready = 2,
    Fault = 3,
    Stopped = 4,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum Ingress {
    Streaming = 1,
    Deferred = 2,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Binding {
    pub name: String,
    pub profile: String,
    pub pid: u32,
    pub global_id: u32,
    pub serial: u64,
    pub instance: i64,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OwnedProcess {
    pub role: String,
    pub pid: u32,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RunnerRecord {
    pub lifecycle: LifecycleState,
    pub result: ExecutionResult,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RunnerObservation {
    pub binding: Binding,
    pub token: i64,
    pub session_id: String,
    pub status: RunnerRecord,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SimulatorSnapshot {
    pub version: i32,
    pub instance: i64,
    pub kind: i32,
    pub token: i64,
    pub result: i32,
    pub generation: i64,
    pub sequence: i64,
    pub running: bool,
    pub completed: bool,
    pub report_generation: i64,
    pub report_sequence: i64,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Cursor {
    pub domain: u64,
    pub generation: u64,
    pub sequence: u64,
    pub model_ns: u64,
}
#[derive(Clone, Debug, Eq, PartialEq)]
#[allow(clippy::struct_excessive_bools)] // Mirrors the existing acquisition wire fields.
pub struct AcquisitionSnapshot {
    pub instrument: Instrument,
    pub cursor: Option<Cursor>,
    pub report_cursor: Option<Cursor>,
    pub running: bool,
    pub completed: bool,
    pub phase: String,
    pub held: bool,
    pub restored: bool,
    pub window: Option<u64>,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum SourceSnapshot {
    Simulator(SimulatorSnapshot),
    Calibration {
        lifecycle: ColdLifecycle,
        snapshot: AcquisitionSnapshot,
    },
    Correction {
        lifecycle: ColdLifecycle,
        snapshot: AcquisitionSnapshot,
    },
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SourceObservation {
    pub binding: Binding,
    pub token: i64,
    pub snapshot: SourceSnapshot,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HeartSnapshot {
    pub generation: i64,
    pub child_pid: Option<u32>,
    pub child_returncode: Option<i32>,
    pub alive: bool,
    pub ingress: Ingress,
    pub placement_validated: bool,
    pub diagnostics_disabled: bool,
    pub report_path: String,
    pub report_sha256: String,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HeartObservation {
    pub binding: Binding,
    pub token: i64,
    pub lifecycle: HeartLifecycle,
    pub snapshot: HeartSnapshot,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Snapshot {
    pub processes: Vec<OwnedProcess>,
    pub runner: Option<RunnerObservation>,
    pub source: Option<SourceObservation>,
    pub heart: Option<HeartObservation>,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Completion {
    pub header: ReplyHeader,
    pub lifecycle: Phase,
    pub admitted: bool,
    pub snapshot: Option<Snapshot>,
    pub result: Option<RunnerRecord>,
    pub error: Option<ControlError>,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Rejection {
    pub header: ReplyHeader,
    pub lifecycle: Phase,
    pub admitted: bool,
    pub error: ControlError,
}
fn bad(message: &str) -> ControlError {
    ControlError::new("native.supervisor", message)
}
fn check(condition: bool, message: &str) -> Result<(), ControlError> {
    if condition {
        Ok(())
    } else {
        Err(bad(message))
    }
}
fn string(value: &str, empty: bool, limit: usize) -> Result<(), ControlError> {
    check(
        (empty || !value.is_empty()) && value.len() <= limit && !value.contains('\0'),
        "invalid supervisor string",
    )
}
fn text(value: &Value, empty: bool, limit: usize) -> Result<String, ControlError> {
    if let Value::String(value) = value {
        string(value, empty, limit)?;
        Ok(value.clone())
    } else {
        Err(bad("expected String"))
    }
}
fn fields(value: &Value, count: usize) -> Result<&[Value], ControlError> {
    if let Value::Struct(fields) = value {
        check(fields.len() == count, "wrong supervisor Struct arity")?;
        Ok(fields)
    } else {
        Err(bad("expected Struct"))
    }
}
fn id(value: &Value) -> Result<u32, ControlError> {
    if let Value::Id(Id(value)) = value {
        Ok(*value)
    } else {
        Err(bad("expected Id"))
    }
}
fn long(value: &Value) -> Result<i64, ControlError> {
    if let Value::Long(value) = value {
        Ok(*value)
    } else {
        Err(bad("expected Long"))
    }
}
fn int(value: &Value) -> Result<i32, ControlError> {
    if let Value::Int(value) = value {
        Ok(*value)
    } else {
        Err(bad("expected Int"))
    }
}
fn boolean(value: &Value) -> Result<bool, ControlError> {
    if let Value::Bool(value) = value {
        Ok(*value)
    } else {
        Err(bad("expected Bool"))
    }
}
fn phase(value: &Value) -> Result<Phase, ControlError> {
    match id(value)? {
        1 => Ok(Phase::Preparing),
        2 => Ok(Phase::Admitted),
        3 => Ok(Phase::Failed),
        4 => Ok(Phase::Stopping),
        5 => Ok(Phase::Stopped),
        _ => Err(bad("unknown supervisor phase")),
    }
}
fn cold_lifecycle(v: &Value) -> Result<ColdLifecycle, ControlError> {
    match id(v)? {
        1 => Ok(ColdLifecycle::Preparing),
        2 => Ok(ColdLifecycle::Prepared),
        3 => Ok(ColdLifecycle::Connected),
        4 => Ok(ColdLifecycle::Fault),
        5 => Ok(ColdLifecycle::Stopped),
        _ => Err(bad("unknown acquisition lifecycle")),
    }
}
fn instrument(v: &Value) -> Result<Instrument, ControlError> {
    match id(v)? {
        1 => Ok(Instrument::Classic),
        2 => Ok(Instrument::Copper),
        _ => Err(bad("unknown instrument")),
    }
}
fn heart_lifecycle(v: &Value) -> Result<HeartLifecycle, ControlError> {
    match id(v)? {
        1 => Ok(HeartLifecycle::Preparing),
        2 => Ok(HeartLifecycle::Ready),
        3 => Ok(HeartLifecycle::Fault),
        4 => Ok(HeartLifecycle::Stopped),
        _ => Err(bad("unknown HEART lifecycle")),
    }
}
fn ingress(v: &Value) -> Result<Ingress, ControlError> {
    match id(v)? {
        1 => Ok(Ingress::Streaming),
        2 => Ok(Ingress::Deferred),
        _ => Err(bad("unknown HEART ingress")),
    }
}
fn phase_check(phase: Phase, admitted: bool) -> Result<(), ControlError> {
    check(
        admitted == (phase == Phase::Admitted),
        "supervisor phase/admitted mismatch",
    )
}
fn optional<T>(
    value: &Value,
    decode: impl FnOnce(&Value) -> Result<T, ControlError>,
) -> Result<Option<T>, ControlError> {
    if *value == Value::None {
        Ok(None)
    } else {
        decode(value).map(Some)
    }
}
fn binding(binding: &Binding, profile: Option<&str>) -> Result<(), ControlError> {
    string(&binding.name, false, 128)?;
    string(&binding.profile, false, 128)?;
    check(
        profile.map_or(true, |profile| profile == binding.profile),
        "binding profile mismatch",
    )?;
    check(
        binding.pid > 0
            && binding.global_id > 0
            && binding.global_id < u32::MAX
            && binding.serial > 0
            && binding.instance > 0,
        "binding requires positive PID/serial/incarnation",
    )
}
fn binding_value(binding_: &Binding) -> Result<Value, ControlError> {
    binding(binding_, None)?;
    Ok(Value::Struct(vec![
        Value::String(binding_.name.clone()),
        Value::String(binding_.profile.clone()),
        Value::Id(Id(binding_.pid)),
        Value::Id(Id(binding_.global_id)),
        Value::Long(envelope::serial_to_long(binding_.serial)),
        Value::Long(binding_.instance),
    ]))
}
fn decode_binding(value: &Value) -> Result<Binding, ControlError> {
    let f = fields(value, 6)?;
    let b = Binding {
        name: text(&f[0], false, 128)?,
        profile: text(&f[1], false, 128)?,
        pid: id(&f[2])?,
        global_id: id(&f[3])?,
        serial: envelope::serial_from_long(long(&f[4])?),
        instance: long(&f[5])?,
    };
    binding(&b, None)?;
    Ok(b)
}
fn record_value(header: &ReplyHeader, record: &RunnerRecord) -> Result<Value, ControlError> {
    let mut inner_header = *header;
    inner_header.result = 0;
    let bytes = result::encode_completion(&inner_header, record.lifecycle, &record.result)?;
    let decoded = envelope::decode_completion(&bytes).map_err(|e| bad(&e.to_string()))?;
    Ok(Value::Struct(decoded.payload))
}
fn decode_record(header: &ReplyHeader, value: &Value) -> Result<RunnerRecord, ControlError> {
    let f = fields(value, 3)?;
    let mut inner_header = *header;
    inner_header.result = 0;
    let bytes = envelope::encode_completion(&inner_header, f).map_err(|e| bad(&e.to_string()))?;
    let completion = result::decode_completion(&bytes)?;
    Ok(RunnerRecord {
        lifecycle: completion.lifecycle,
        result: completion.result?,
    })
}
fn runner_value(
    header: &ReplyHeader,
    observation: &RunnerObservation,
) -> Result<Value, ControlError> {
    binding(&observation.binding, Some(runner::PROFILE))?;
    check(observation.token > 0, "runner Status must have fresh token")?;
    string(&observation.session_id, false, 128)?;
    check(
        observation.session_id
            == format!("native-runner-instance:{}", observation.binding.instance),
        "runner session/incarnation mismatch",
    )?;
    let mut status_header = *header;
    status_header.operation = 3;
    Ok(Value::Struct(vec![
        binding_value(&observation.binding)?,
        Value::Long(observation.token),
        Value::String(observation.session_id.clone()),
        record_value(&status_header, &observation.status)?,
    ]))
}
fn decode_runner(header: &ReplyHeader, value: &Value) -> Result<RunnerObservation, ControlError> {
    let f = fields(value, 4)?;
    let mut status_header = *header;
    status_header.operation = 3;
    let r = RunnerObservation {
        binding: decode_binding(&f[0])?,
        token: long(&f[1])?,
        session_id: text(&f[2], false, 128)?,
        status: decode_record(&status_header, &f[3])?,
    };
    runner_value(header, &r)?;
    Ok(r)
}
fn cursor_value(c: &Cursor) -> Value {
    Value::Struct(vec![
        Value::Long(envelope::serial_to_long(c.domain)),
        Value::Long(envelope::serial_to_long(c.generation)),
        Value::Long(envelope::serial_to_long(c.sequence)),
        Value::Long(envelope::serial_to_long(c.model_ns)),
    ])
}
fn decode_cursor(value: &Value) -> Result<Cursor, ControlError> {
    let f = fields(value, 4)?;
    Ok(Cursor {
        domain: envelope::serial_from_long(long(&f[0])?),
        generation: envelope::serial_from_long(long(&f[1])?),
        sequence: envelope::serial_from_long(long(&f[2])?),
        model_ns: envelope::serial_from_long(long(&f[3])?),
    })
}
fn acquisition_value(
    kind: u32,
    lifecycle: ColdLifecycle,
    s: &AcquisitionSnapshot,
) -> Result<Value, ControlError> {
    check(!(s.running && s.completed), "invalid acquisition snapshot")?;
    string(&s.phase, false, 64)?;
    check(s.phase.is_ascii(), "acquisition phase must be ASCII")?;
    let phases: &[&str] = if kind == 2 {
        &[
            "initial",
            "held",
            "adopted",
            "settled",
            "collected",
            "restoring",
            "restored",
            "released",
            "fault",
        ]
    } else {
        &[
            "initial",
            "startup_run",
            "correcting",
            "restore_run",
            "restored",
            "fault",
        ]
    };
    check(
        phases.contains(&s.phase.as_str()),
        "acquisition phase/profile mismatch",
    )?;
    check(
        lifecycle != ColdLifecycle::Connected
            || s.cursor.as_ref().is_some_and(|c| c.generation > 0),
        "Connected requires acquisition cursor",
    )?;
    check(
        if kind == 2 {
            s.window.is_none()
        } else {
            lifecycle != ColdLifecycle::Connected || s.window.is_some_and(|w| w > 0)
        },
        "invalid acquisition window",
    )?;
    Ok(Value::Struct(vec![
        Value::Id(Id(s.instrument as u32)),
        s.cursor.as_ref().map_or(Value::None, cursor_value),
        s.report_cursor.as_ref().map_or(Value::None, cursor_value),
        Value::Bool(s.running),
        Value::Bool(s.completed),
        Value::String(s.phase.clone()),
        Value::Bool(s.held),
        Value::Bool(s.restored),
        s.window
            .map_or(Value::None, |w| Value::Long(envelope::serial_to_long(w))),
    ]))
}
fn decode_acquisition(
    kind: u32,
    lifecycle: ColdLifecycle,
    value: &Value,
) -> Result<AcquisitionSnapshot, ControlError> {
    let f = fields(value, 9)?;
    let s = AcquisitionSnapshot {
        instrument: instrument(&f[0])?,
        cursor: optional(&f[1], decode_cursor)?,
        report_cursor: optional(&f[2], decode_cursor)?,
        running: boolean(&f[3])?,
        completed: boolean(&f[4])?,
        phase: text(&f[5], false, 64)?,
        held: boolean(&f[6])?,
        restored: boolean(&f[7])?,
        window: optional(&f[8], |v| long(v).map(envelope::serial_from_long))?,
    };
    acquisition_value(kind, lifecycle, &s)?;
    Ok(s)
}
fn source_value(o: &SourceObservation) -> Result<Value, ControlError> {
    binding(&o.binding, None)?;
    check(o.token > 0, "source Status requires fresh token")?;
    let (kind, profile, body) = match &o.snapshot {
        SourceSnapshot::Simulator(s) => {
            check(
                s.version == 1
                    && s.instance == o.binding.instance
                    && s.kind == 3
                    && s.token == o.token
                    && s.result == 0,
                "source is not a matched fresh query",
            )?;
            check(
                s.generation >= 1
                    && s.sequence >= 0
                    && s.report_generation >= 1
                    && s.report_sequence >= 0
                    && s.report_generation <= s.generation
                    && (s.report_generation != s.generation || s.report_sequence <= s.sequence)
                    && !(s.running && s.completed),
                "invalid simulator snapshot",
            )?;
            check(
                !s.completed
                    || (s.report_generation == s.generation && s.report_sequence == s.sequence),
                "completed source report cursor is not current",
            )?;
            (
                1,
                "pipewireao.source-control/1",
                Value::Struct(vec![
                    Value::Int(s.version),
                    Value::Long(s.instance),
                    Value::Int(s.kind),
                    Value::Long(s.token),
                    Value::Int(s.result),
                    Value::Long(s.generation),
                    Value::Long(s.sequence),
                    Value::Bool(s.running),
                    Value::Bool(s.completed),
                    Value::Long(s.report_generation),
                    Value::Long(s.report_sequence),
                ]),
            )
        }
        SourceSnapshot::Calibration {
            lifecycle,
            snapshot,
        } => (
            2,
            "pipewireao.rtc.calibration-lifecycle/1",
            Value::Struct(vec![
                Value::Id(Id(*lifecycle as u32)),
                acquisition_value(2, *lifecycle, snapshot)?,
            ]),
        ),
        SourceSnapshot::Correction {
            lifecycle,
            snapshot,
        } => (
            3,
            "pipewireao.rtc.correction-lifecycle/1",
            Value::Struct(vec![
                Value::Id(Id(*lifecycle as u32)),
                acquisition_value(3, *lifecycle, snapshot)?,
            ]),
        ),
    };
    binding(&o.binding, Some(profile))?;
    Ok(Value::Struct(vec![
        binding_value(&o.binding)?,
        Value::Long(o.token),
        Value::Id(Id(kind)),
        body,
    ]))
}
fn decode_source(value: &Value) -> Result<SourceObservation, ControlError> {
    let f = fields(value, 4)?;
    let kind = id(&f[2])?;
    let snapshot = match kind {
        1 => {
            let s = fields(&f[3], 11)?;
            SourceSnapshot::Simulator(SimulatorSnapshot {
                version: int(&s[0])?,
                instance: long(&s[1])?,
                kind: int(&s[2])?,
                token: long(&s[3])?,
                result: int(&s[4])?,
                generation: long(&s[5])?,
                sequence: long(&s[6])?,
                running: boolean(&s[7])?,
                completed: boolean(&s[8])?,
                report_generation: long(&s[9])?,
                report_sequence: long(&s[10])?,
            })
        }
        2 | 3 => {
            let s = fields(&f[3], 2)?;
            let lifecycle = cold_lifecycle(&s[0])?;
            let snapshot = decode_acquisition(kind, lifecycle, &s[1])?;
            if kind == 2 {
                SourceSnapshot::Calibration {
                    lifecycle,
                    snapshot,
                }
            } else {
                SourceSnapshot::Correction {
                    lifecycle,
                    snapshot,
                }
            }
        }
        _ => return Err(bad("unknown supervisor source kind")),
    };
    let o = SourceObservation {
        binding: decode_binding(&f[0])?,
        token: long(&f[1])?,
        snapshot,
    };
    source_value(&o)?;
    Ok(o)
}
fn heart_value(o: &HeartObservation) -> Result<Value, ControlError> {
    binding(&o.binding, Some("pipewireao.rtc.heart/1"))?;
    check(o.token > 0, "HEART Status requires fresh token")?;
    let s = &o.snapshot;
    check(
        s.generation >= 0 && s.child_pid.map_or(true, |p| p > 0),
        "invalid HEART snapshot",
    )?;
    string(&s.report_path, true, 4096)?;
    string(&s.report_sha256, true, 64)?;
    check(
        s.report_sha256.is_empty()
            || (s.report_sha256.len() == 64
                && s.report_sha256
                    .bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))),
        "invalid HEART digest",
    )?;
    check(
        o.lifecycle != HeartLifecycle::Ready
            || (s.generation >= 1
                && s.alive
                && s.child_pid.is_some()
                && s.child_returncode.is_none()
                && !s.report_path.is_empty()
                && !s.report_sha256.is_empty()),
        "invalid Ready HEART snapshot",
    )?;
    Ok(Value::Struct(vec![
        binding_value(&o.binding)?,
        Value::Long(o.token),
        Value::Id(Id(o.lifecycle as u32)),
        Value::Struct(vec![
            Value::Long(s.generation),
            s.child_pid.map_or(Value::None, |p| Value::Id(Id(p))),
            s.child_returncode.map_or(Value::None, Value::Int),
            Value::Bool(s.alive),
            Value::Id(Id(s.ingress as u32)),
            Value::Bool(s.placement_validated),
            Value::Bool(s.diagnostics_disabled),
            Value::String(s.report_path.clone()),
            Value::String(s.report_sha256.clone()),
        ]),
    ]))
}
fn decode_heart(value: &Value) -> Result<HeartObservation, ControlError> {
    let f = fields(value, 4)?;
    let s = fields(&f[3], 9)?;
    let o = HeartObservation {
        binding: decode_binding(&f[0])?,
        token: long(&f[1])?,
        lifecycle: heart_lifecycle(&f[2])?,
        snapshot: HeartSnapshot {
            generation: long(&s[0])?,
            child_pid: optional(&s[1], id)?,
            child_returncode: optional(&s[2], int)?,
            alive: boolean(&s[3])?,
            ingress: ingress(&s[4])?,
            placement_validated: boolean(&s[5])?,
            diagnostics_disabled: boolean(&s[6])?,
            report_path: text(&s[7], true, 4096)?,
            report_sha256: text(&s[8], true, 64)?,
        },
    };
    heart_value(&o)?;
    Ok(o)
}
fn snapshot_value(
    header: &ReplyHeader,
    phase: Phase,
    admitted: bool,
    s: &Snapshot,
) -> Result<Value, ControlError> {
    phase_check(phase, admitted)?;
    check(
        s.processes.len() <= MAX_PROCESSES,
        "too many owned processes",
    )?;
    let mut roles = BTreeSet::new();
    let mut pids = BTreeSet::new();
    for p in &s.processes {
        string(&p.role, false, 128)?;
        check(p.pid > 0, "invalid owned PID")?;
        check(
            roles.insert(&p.role) && pids.insert(p.pid),
            "duplicate owned role/PID",
        )?;
    }
    check(
        phase != Phase::Preparing
            || (roles.is_empty() && s.runner.is_none() && s.source.is_none() && s.heart.is_none()),
        "Preparing cannot report admitted owners",
    )?;
    check(
        !admitted || s.runner.is_some(),
        "Admitted requires fresh runner Status",
    )?;
    for b in [
        s.runner.as_ref().map(|o| &o.binding),
        s.source.as_ref().map(|o| &o.binding),
        s.heart.as_ref().map(|o| &o.binding),
    ]
    .into_iter()
    .flatten()
    {
        check(pids.contains(&b.pid), "binding PID is not currently owned")?;
    }
    let mut processes = s.processes.iter().collect::<Vec<_>>();
    processes.sort_by(|a, b| a.role.cmp(&b.role));
    let rows = processes
        .into_iter()
        .map(|p| Value::Struct(vec![Value::String(p.role.clone()), Value::Id(Id(p.pid))]))
        .collect();
    Ok(Value::Struct(vec![
        Value::Struct(rows),
        s.runner
            .as_ref()
            .map_or(Ok(Value::None), |o| runner_value(header, o))?,
        s.source.as_ref().map_or(Ok(Value::None), source_value)?,
        s.heart.as_ref().map_or(Ok(Value::None), heart_value)?,
    ]))
}
fn decode_snapshot(header: &ReplyHeader, value: &Value) -> Result<Snapshot, ControlError> {
    let f = fields(value, 4)?;
    let Value::Struct(rows) = &f[0] else {
        return Err(bad("expected process catalog"));
    };
    check(rows.len() <= MAX_PROCESSES, "too many owned processes")?;
    let processes = rows
        .iter()
        .map(|r| {
            let f = fields(r, 2)?;
            Ok(OwnedProcess {
                role: text(&f[0], false, 128)?,
                pid: id(&f[1])?,
            })
        })
        .collect::<Result<Vec<_>, ControlError>>()?;
    Ok(Snapshot {
        processes,
        runner: optional(&f[1], |v| decode_runner(header, v))?,
        source: optional(&f[2], decode_source)?,
        heart: optional(&f[3], decode_heart)?,
    })
}
/// Checks or converts the closed public supervisor profile.
/// # Errors
/// Rejects invalid identity, admission, typed fields, grammar or wire capacity.
pub fn encode_request(header: &RequestHeader, command: &Command) -> Result<Vec<u8>, ControlError> {
    runner::encode_request(header, command)
}
/// Checks or converts the closed public supervisor profile.
/// # Errors
/// Rejects invalid identity, admission, typed fields, grammar or wire capacity.
pub fn decode_request(bytes: &[u8]) -> Result<(RequestHeader, Command), ControlError> {
    runner::decode_request(bytes)
}
/// Preparing and retired endpoints admit only fresh Status without owner effects.
/// Checks or converts the closed public supervisor profile.
/// # Errors
/// Rejects invalid identity, admission, typed fields, grammar or wire capacity.
pub fn validate_admission(phase: Phase, command: &Command) -> Result<(), ControlError> {
    check(
        phase == Phase::Admitted || matches!(command, Command::Status),
        "supervisor has not coherently admitted this operation",
    )
}
fn completion_payload(c: &Completion) -> Result<Vec<Value>, ControlError> {
    phase_check(c.lifecycle, c.admitted)?;
    runner::Operation::try_from(c.header.operation)?;
    check(
        c.header.token > 0,
        "sentinel is not a fresh supervisor completion",
    )?;
    if c.header.result < 0 {
        check(
            c.result.is_none() || c.lifecycle == Phase::Admitted,
            "partial inner result requires admitted phase",
        )?;
        let error = c
            .error
            .as_ref()
            .ok_or_else(|| bad("failure requires typed error"))?;
        string(&error.field, true, 8192)?;
        string(&error.message, true, 8192)?;
        return Ok(vec![
            Value::Id(Id(c.lifecycle as u32)),
            Value::Bool(c.admitted),
            c.snapshot.as_ref().map_or(Ok(Value::None), |snapshot| {
                snapshot_value(&c.header, c.lifecycle, c.admitted, snapshot)
            })?,
            Value::Struct(vec![
                Value::String(error.field.clone()),
                Value::String(error.message.clone()),
                c.result
                    .as_ref()
                    .map_or(Ok(Value::None), |record| record_value(&c.header, record))?,
            ]),
        ]);
    }
    check(c.error.is_none(), "success cannot contain error")?;
    let s = c
        .snapshot
        .as_ref()
        .ok_or_else(|| bad("success requires supervisor snapshot"))?;
    if c.header.operation == 3 {
        check(
            c.result.is_none(),
            "Status result is the runner observation",
        )?;
    } else {
        check(
            c.lifecycle == Phase::Admitted && c.result.is_some(),
            "non-Status requires admitted runner result",
        )?;
    }
    Ok(vec![
        Value::Id(Id(c.lifecycle as u32)),
        Value::Bool(c.admitted),
        snapshot_value(&c.header, c.lifecycle, c.admitted, s)?,
        c.result
            .as_ref()
            .map_or(Ok(Value::None), |r| record_value(&c.header, r))?,
    ])
}
fn size_add(a: usize, b: usize) -> Result<usize, ControlError> {
    let total = a.checked_add(b).ok_or_else(|| bad("reply size overflow"))?;
    check(
        total <= envelope::LIFECYCLE_REPLY_BOUND,
        "supervisor reply exceeds 64 KiB",
    )?;
    Ok(total)
}
fn struct_size(sizes: &[usize]) -> Result<usize, ControlError> {
    sizes.iter().try_fold(8, |a, b| size_add(a, *b))
}
fn string_size(s: &str, empty: bool, limit: usize) -> Result<usize, ControlError> {
    string(s, empty, limit)?;
    Ok((s.len() + 16) & !7)
}
fn binding_size(b: &Binding) -> Result<usize, ControlError> {
    binding(b, None)?;
    struct_size(&[
        string_size(&b.name, false, 128)?,
        string_size(&b.profile, false, 128)?,
        16,
        16,
        16,
        16,
    ])
}
fn record_size(header: &ReplyHeader, r: &RunnerRecord) -> Result<usize, ControlError> {
    let base = envelope::encode_completion(header, &[])
        .map_err(|e| bad(&e.to_string()))?
        .len();
    let mut inner_header = *header;
    inner_header.result = 0;
    Ok(result::completion_size(&inner_header, r.lifecycle, &r.result)? - base + 8)
}
fn runner_size(header: &ReplyHeader, r: &RunnerObservation) -> Result<usize, ControlError> {
    binding(&r.binding, Some(runner::PROFILE))?;
    check(
        r.token > 0 && r.session_id == format!("native-runner-instance:{}", r.binding.instance),
        "runner Status identity mismatch",
    )?;
    let mut header = *header;
    header.operation = 3;
    struct_size(&[
        binding_size(&r.binding)?,
        16,
        string_size(&r.session_id, false, 128)?,
        record_size(&header, &r.status)?,
    ])
}
// Source/HEART values have fixed field counts and bounded small strings; the
// variable runner catalogs are measured by their borrowed typed result first.
fn value_size(v: &Value) -> Result<usize, ControlError> {
    match v {
        Value::None => Ok(8),
        Value::String(s) => string_size(s, true, envelope::LIFECYCLE_REPLY_BOUND),
        Value::Struct(fields) => fields
            .iter()
            .try_fold(8, |a, v| size_add(a, value_size(v)?)),
        Value::Bool(_) | Value::Id(_) | Value::Int(_) | Value::Long(_) => Ok(16),
        _ => Err(bad("unexpected supervisor observation scalar")),
    }
}
fn snapshot_size(header: &ReplyHeader, s: &Snapshot) -> Result<usize, ControlError> {
    check(
        s.processes.len() <= MAX_PROCESSES,
        "too many owned processes",
    )?;
    let rows = s.processes.iter().try_fold(8, |a, p| {
        size_add(a, struct_size(&[string_size(&p.role, false, 128)?, 16])?)
    })?;
    struct_size(&[
        rows,
        s.runner
            .as_ref()
            .map_or(Ok(8), |r| runner_size(header, r))?,
        s.source
            .as_ref()
            .map_or(Ok(8), |o| value_size(&source_value(o)?))?,
        s.heart
            .as_ref()
            .map_or(Ok(8), |o| value_size(&heart_value(o)?))?,
    ])
}
fn validate_snapshot_shape(phase: Phase, snapshot: &Snapshot) -> Result<(), ControlError> {
    check(
        snapshot.processes.len() <= MAX_PROCESSES,
        "too many owned processes",
    )?;
    check(
        phase != Phase::Preparing
            || (snapshot.processes.is_empty()
                && snapshot.runner.is_none()
                && snapshot.source.is_none()
                && snapshot.heart.is_none()),
        "Preparing cannot report admitted owners",
    )?;
    check(
        phase != Phase::Admitted || snapshot.runner.is_some(),
        "Admitted requires fresh runner Status",
    )?;
    let mut roles = BTreeSet::new();
    let mut pids = BTreeSet::new();
    for p in &snapshot.processes {
        check(
            p.pid > 0 && roles.insert(&p.role) && pids.insert(p.pid),
            "invalid/duplicate owned role or PID",
        )?;
    }
    for b in [
        snapshot.runner.as_ref().map(|o| &o.binding),
        snapshot.source.as_ref().map(|o| &o.binding),
        snapshot.heart.as_ref().map(|o| &o.binding),
    ]
    .into_iter()
    .flatten()
    {
        check(pids.contains(&b.pid), "binding PID is not currently owned")?;
    }
    Ok(())
}
/// Reserve the combined mutation result before effects. An explicit future
/// snapshot bound must cover any layout/string growth introduced by the effect.
/// Checks or converts the closed public supervisor profile.
/// # Errors
/// Rejects invalid identity, admission, typed fields, grammar or wire capacity.
pub fn preflight_mutation_reply(
    command: &Command,
    snapshot: &Snapshot,
    snapshot_bound: Option<usize>,
) -> Result<usize, ControlError> {
    use Command as C;
    let op = match command {
        C::Quit => 1,
        C::StopGroup(_) => 7,
        C::StartGroup(_) => 8,
        C::SessionStop => 9,
        C::SessionStart => 10,
        C::SourceEnded => 11,
        C::Reset => 12,
        C::PropertiesSet(..) => 13,
        C::Parameter { .. } => 14,
        _ => return Err(bad("query/internal command has no mutation reservation")),
    };
    let header = ReplyHeader {
        version: 1,
        endpoint_instance: 1,
        controller: envelope::ControllerIdentity {
            global_id: 1,
            serial: 1,
            instance: 1,
        },
        token: 1,
        operation: op,
        result: 0,
    };
    let request_header = RequestHeader {
        version: 1,
        endpoint_instance: 1,
        controller: header.controller,
        token: 1,
        operation: op,
        budget_ns: 1,
    };
    runner::preflight(&request_header, command)?;
    validate_snapshot_shape(Phase::Admitted, snapshot)?;
    let present = snapshot_size(&header, snapshot)?;
    let bound = snapshot_bound.unwrap_or(present);
    check(
        present <= bound && bound <= envelope::LIFECYCLE_REPLY_BOUND,
        "future snapshot bound too small or oversized",
    )?;
    let details = match command {
        C::Quit | C::SessionStop | C::SessionStart | C::SourceEnded | C::Reset => 16,
        C::StartGroup(name) | C::StopGroup(name) => {
            struct_size(&[string_size(name, false, 16 * 1024)?, 16, 16])? - 8
        }
        C::PropertiesSet(graph, properties) => {
            let mut nodes = BTreeSet::new();
            for qualified in properties.keys() {
                let (node, property) = qualified
                    .split_once(':')
                    .ok_or_else(|| bad("property must be node:property"))?;
                check(
                    !node.is_empty() && !property.is_empty(),
                    "property must be node:property",
                )?;
                nodes.insert(node);
            }
            let rows = nodes.into_iter().try_fold(8, |a, node| {
                size_add(
                    a,
                    struct_size(&[string_size(node, false, 16 * 1024)?, 16, 16])?,
                )
            })?;
            struct_size(&[string_size(graph, false, 16 * 1024)?, rows, 16])? - 8
        }
        C::Parameter {
            graph, parameter, ..
        } => {
            struct_size(&[
                string_size(graph, false, 16 * 1024)?,
                string_size(parameter, false, 16 * 1024)?,
                40,
                16,
            ])? - 8
        }
        _ => unreachable!("operation was checked above"),
    };
    let record = struct_size(&[16, 16, size_add(8, details)?])?;
    let success = struct_size(&[16, 16, bound, record])?;
    let failure = struct_size(&[
        16,
        16,
        bound,
        struct_size(&[((8192 + 16) & !7), ((8192 + 16) & !7), record])?,
    ])?;
    let base = envelope::encode_completion(&header, &[])
        .map_err(|e| bad(&e.to_string()))?
        .len();
    Ok(size_add(base, success - 8)?.max(size_add(base, failure - 8)?))
}
/// Exact capacity preflight before cloning variable runner catalogs or encoding.
/// Checks or converts the closed public supervisor profile.
/// # Errors
/// Rejects invalid identity, admission, typed fields, grammar or wire capacity.
pub fn completion_size(c: &Completion) -> Result<usize, ControlError> {
    phase_check(c.lifecycle, c.admitted)?;
    runner::Operation::try_from(c.header.operation)?;
    let payload = if c.header.result < 0 {
        check(
            c.result.is_none() || c.lifecycle == Phase::Admitted,
            "partial inner result requires admitted phase",
        )?;
        let e = c
            .error
            .as_ref()
            .ok_or_else(|| bad("failure requires typed error"))?;
        struct_size(&[
            16,
            16,
            c.snapshot.as_ref().map_or(Ok(8), |snapshot| {
                validate_snapshot_shape(c.lifecycle, snapshot)?;
                snapshot_size(&c.header, snapshot)
            })?,
            struct_size(&[
                string_size(&e.field, true, 8192)?,
                string_size(&e.message, true, 8192)?,
                c.result
                    .as_ref()
                    .map_or(Ok(8), |record| record_size(&c.header, record))?,
            ])?,
        ])?
    } else {
        let s = c
            .snapshot
            .as_ref()
            .ok_or_else(|| bad("success requires snapshot"))?;
        struct_size(&[
            16,
            16,
            snapshot_size(&c.header, s)?,
            c.result
                .as_ref()
                .map_or(Ok(8), |r| record_size(&c.header, r))?,
        ])?
    };
    let base = envelope::encode_completion(&c.header, &[])
        .map_err(|e| bad(&e.to_string()))?
        .len();
    size_add(base, payload - 8)
}
/// Checks or converts the closed public supervisor profile.
/// # Errors
/// Rejects invalid identity, admission, typed fields, grammar or wire capacity.
pub fn encode_completion(c: &Completion) -> Result<Vec<u8>, ControlError> {
    completion_size(c)?;
    envelope::encode_completion(&c.header, &completion_payload(c)?).map_err(|e| bad(&e.to_string()))
}
/// Checks or converts the closed public supervisor profile.
/// # Errors
/// Rejects invalid identity, admission, typed fields, grammar or wire capacity.
pub fn decode_completion(bytes: &[u8]) -> Result<Completion, ControlError> {
    let r = envelope::decode_completion(bytes).map_err(|e| bad(&e.to_string()))?;
    let f = fields(&Value::Struct(r.payload.clone()), 4)?.to_vec();
    let lifecycle = phase(&f[0])?;
    let admitted = boolean(&f[1])?;
    phase_check(lifecycle, admitted)?;
    let c = if r.header.result < 0 {
        let failure = fields(&f[3], 3)?;
        Completion {
            header: r.header,
            lifecycle,
            admitted,
            snapshot: optional(&f[2], |value| decode_snapshot(&r.header, value))?,
            result: optional(&failure[2], |value| decode_record(&r.header, value))?,
            error: Some(ControlError::new(
                text(&failure[0], true, 8192)?,
                text(&failure[1], true, 8192)?,
            )),
        }
    } else {
        Completion {
            header: r.header,
            lifecycle,
            admitted,
            snapshot: Some(decode_snapshot(&r.header, &f[2])?),
            result: optional(&f[3], |v| decode_record(&r.header, v))?,
            error: None,
        }
    };
    completion_payload(&c)?;
    Ok(c)
}
/// Checks or converts the closed public supervisor profile.
/// # Errors
/// Rejects invalid identity, admission, typed fields, grammar or wire capacity.
pub fn encode_rejection(r: &Rejection) -> Result<Vec<u8>, ControlError> {
    phase_check(r.lifecycle, r.admitted)?;
    string(&r.error.field, true, 8192)?;
    string(&r.error.message, true, 8192)?;
    envelope::encode_rejection(
        &r.header,
        &[
            Value::Id(Id(r.lifecycle as u32)),
            Value::Bool(r.admitted),
            Value::String(r.error.field.clone()),
            Value::String(r.error.message.clone()),
        ],
    )
    .map_err(|e| bad(&e.to_string()))
}
/// Checks or converts the closed public supervisor profile.
/// # Errors
/// Rejects invalid identity, admission, typed fields, grammar or wire capacity.
pub fn decode_rejection(bytes: &[u8]) -> Result<Rejection, ControlError> {
    let r = envelope::decode_rejection(bytes).map_err(|e| bad(&e.to_string()))?;
    let f = fields(&Value::Struct(r.payload.clone()), 4)?.to_vec();
    let reject = Rejection {
        header: r.header,
        lifecycle: phase(&f[0])?,
        admitted: boolean(&f[1])?,
        error: ControlError::new(text(&f[2], true, 8192)?, text(&f[3], true, 8192)?),
    };
    encode_rejection(&reject)?;
    Ok(reject)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn shared_julia_fixtures_roundtrip_and_reject() {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("tests/fixtures/native-supervisor");
        let mut checked = 0;
        for item in std::fs::read_dir(path).unwrap() {
            let path = item.unwrap().path();
            if path.extension().and_then(|s| s.to_str()) != Some("pod") {
                continue;
            }
            let name = path.file_stem().unwrap().to_str().unwrap();
            let bytes = std::fs::read(&path).unwrap();
            if name.starts_with("bad-request-") {
                assert!(decode_request(&bytes).is_err(), "{name}");
            } else if name.starts_with("bad-reply-") {
                assert!(decode_completion(&bytes).is_err(), "{name}");
            } else if name.starts_with("request-") {
                let (header, command) = decode_request(&bytes).unwrap();
                assert_eq!(encode_request(&header, &command).unwrap(), bytes, "{name}");
            } else if name.starts_with("reply-") {
                let decoded = decode_completion(&bytes).unwrap_or_else(|e| panic!("{name}: {e:?}"));
                assert_eq!(completion_size(&decoded).unwrap(), bytes.len(), "{name}");
                assert_eq!(encode_completion(&decoded).unwrap(), bytes, "{name}");
            } else if name.starts_with("rejection") {
                let decoded = decode_rejection(&bytes).unwrap();
                assert_eq!(encode_rejection(&decoded).unwrap(), bytes, "{name}");
            } else {
                panic!("unclassified fixture {name}");
            }
            checked += 1;
        }
        assert_eq!(checked, 48);
    }
    #[test]
    fn all_mutation_variants_reserve_exact_capacity_before_effects() {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("tests/fixtures/native-supervisor");
        let status =
            decode_completion(&std::fs::read(path.join("reply-status-simulator.pod")).unwrap())
                .unwrap();
        let snapshot = status.snapshot.unwrap();
        for op in 1..=14 {
            let (_, mut command) =
                decode_request(&std::fs::read(path.join(format!("request-{op}.pod"))).unwrap())
                    .unwrap();
            if let Command::PropertiesSet(_, ref mut properties) = command {
                *properties = std::mem::take(properties)
                    .into_iter()
                    .map(|(name, v)| (name.replacen('.', ":", 1), v))
                    .collect();
            }
            if matches!(op, 2..=6) {
                assert!(preflight_mutation_reply(&command, &snapshot, None).is_err());
            } else {
                assert!(preflight_mutation_reply(&command, &snapshot, None).unwrap() <= 65536);
                let bound = 65536 - 24576;
                let reserved = preflight_mutation_reply(&command, &snapshot, Some(bound)).unwrap();
                let maximum = 65536 - (reserved - bound);
                assert_eq!(
                    preflight_mutation_reply(&command, &snapshot, Some(maximum)).unwrap(),
                    65536
                );
                assert!(preflight_mutation_reply(&command, &snapshot, Some(maximum + 1)).is_err());
                assert!(preflight_mutation_reply(&command, &snapshot, Some(1)).is_err());
            }
            assert_eq!(
                validate_admission(Phase::Preparing, &command).is_ok(),
                op == 3
            );
            assert!(validate_admission(Phase::Admitted, &command).is_ok());
        }
        let empty = Snapshot {
            processes: vec![],
            runner: None,
            source: None,
            heart: None,
        };
        assert!(preflight_mutation_reply(&Command::Quit, &empty, None).is_err());
    }
}
