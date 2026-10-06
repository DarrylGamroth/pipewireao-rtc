//! Pure calibration action codec foundation for RTC-DEV-030.
//! No caller admission, owner effects, artifact access, or retries occur here.
use crate::calibration::{AcquisitionCursor, Exposure};
use crate::native_control_codec::{
    self as envelope, CodecError, ReplyBound, ReplyHeader, ReplyKind, RequestHeader,
};
use pipewire::spa::pod::{Value, ValueArray};
use pipewire::spa::utils::Id;

pub const PROFILE: &str = "pipewireao.rtc.calibration-actions/1";
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u32)]
pub enum ColdLifecycle {
    Preparing = 1,
    Prepared = 2,
    Connected = 3,
    Fault = 4,
    Stopped = 5,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Rule {
    Immediate,
    DiscardExposures(u32),
    ModelTime(u64),
}
#[derive(Clone, Debug, PartialEq)]
pub enum Action {
    Hold,
    Adopt {
        probe: u32,
        figure: Vec<f32>,
    },
    Settle {
        probe: u32,
        after: AcquisitionCursor,
        rule: Rule,
    },
    Collect {
        probe: u32,
        after: AcquisitionCursor,
        measurements: u32,
        frames: u32,
    },
    Capture {
        probe: u32,
        after: AcquisitionCursor,
        frames: u32,
    },
    Restore {
        figure: Vec<f32>,
        rule: Rule,
    },
    Release,
}
impl Action {
    #[must_use]
    pub const fn operation(&self) -> u32 {
        match self {
            Self::Hold => 1,
            Self::Adopt { .. } => 2,
            Self::Settle { .. } => 3,
            Self::Collect { .. } => 4,
            Self::Capture { .. } => 5,
            Self::Restore { .. } => 6,
            Self::Release => 7,
        }
    }
}
#[derive(Clone, Debug, PartialEq)]
pub struct Command {
    pub run: u64,
    pub serial: u64,
    pub action: Action,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u32)]
pub enum FailureReason {
    Cancelled = 1,
    Endpoint = 2,
    InvalidEvidence = 3,
    ProbeClipped = 4,
}
#[derive(Clone, Debug, PartialEq)]
pub enum ResultValue {
    Held(AcquisitionCursor),
    Adopted {
        cursor: AcquisitionCursor,
        figure: Vec<f32>,
        clipped: bool,
    },
    Settled(AcquisitionCursor),
    Responses {
        values: Vec<f32>,
        exposures: Vec<Exposure>,
        valid: bool,
    },
    Captured {
        cursor: AcquisitionCursor,
        manifest: String,
        sha256: String,
        frames: u32,
        bytes: u64,
        metadata_bytes: u64,
    },
    Restored {
        figure: Vec<f32>,
        clipped: bool,
    },
    Released,
    Failed(FailureReason),
}
impl ResultValue {
    const fn tag(&self) -> u32 {
        match self {
            Self::Held(_) => 1,
            Self::Adopted { .. } => 2,
            Self::Settled(_) => 3,
            Self::Responses { .. } => 4,
            Self::Captured { .. } => 5,
            Self::Restored { .. } => 6,
            Self::Released => 7,
            Self::Failed(_) => 8,
        }
    }
}
#[derive(Clone, Debug, PartialEq)]
pub struct Completion {
    pub header: ReplyHeader,
    pub lifecycle: ColdLifecycle,
    pub run: u64,
    pub serial: u64,
    pub result: Option<ResultValue>,
    pub message: String,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Rejection {
    pub header: ReplyHeader,
    pub lifecycle: ColdLifecycle,
    pub message: String,
}
fn bad(message: &'static str) -> CodecError {
    CodecError::Malformed(message)
}
fn check(ok: bool, message: &'static str) -> Result<(), CodecError> {
    if ok {
        Ok(())
    } else {
        Err(bad(message))
    }
}
fn identity(run: u64, serial: u64) -> Result<(), CodecError> {
    check(run > 0 && serial > 0, "run and serial must be positive")
}
fn probe(v: u32) -> Result<(), CodecError> {
    check(v <= 16383, "probe exceeds 16383")
}
fn frames(v: usize) -> Result<(), CodecError> {
    check((1..=4096).contains(&v), "invalid frame count")
}
fn measurements(v: usize) -> Result<(), CodecError> {
    check((1..=131_072).contains(&v), "invalid measurement count")
}
fn cursor(c: AcquisitionCursor) -> Result<(), CodecError> {
    check(
        c.domain > 0 && c.generation > 0 && i64::try_from(c.model_ns).is_ok(),
        "invalid action cursor",
    )
}
fn floats(v: &[f32], max: usize) -> Result<(), CodecError> {
    check(
        !v.is_empty() && v.len() <= max && v.iter().all(|v| v.is_finite()),
        "invalid Float32 vector",
    )
}
fn rule(r: Rule) -> Result<(), CodecError> {
    match r {
        Rule::Immediate => Ok(()),
        Rule::DiscardExposures(n) => frames(n as usize),
        Rule::ModelTime(n) => check(n > 0 && i64::try_from(n).is_ok(), "invalid model duration"),
    }
}
fn exposure(e: &Exposure) -> Result<(), CodecError> {
    check(
        e.domain > 0
            && e.generation > 0
            && e.duration_ns > 0
            && e.start_model_ns.checked_add(e.duration_ns).is_some(),
        "invalid exposure identity or end",
    )
}
fn exposures(v: &[Exposure]) -> Result<(), CodecError> {
    frames(v.len())?;
    v.iter().try_for_each(exposure)
}
fn text(v: &str, max: usize) -> Result<(), CodecError> {
    check(
        v.len() <= max && !v.contains('\0'),
        "invalid or oversized string",
    )
}
fn manifest(v: &str) -> Result<(), CodecError> {
    text(v, 512)?;
    check(
        !v.is_empty()
            && !v.starts_with('/')
            && !v.contains('\\')
            && v.split('/').all(|p| !p.is_empty() && p != "." && p != ".."),
        "manifest must be relative without traversal",
    )
}
fn sha(v: &str) -> Result<(), CodecError> {
    check(
        v.len() == 64
            && v.bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)),
        "invalid SHA256",
    )
}
fn add(a: usize, b: usize) -> Result<usize, CodecError> {
    a.checked_add(b).ok_or_else(|| bad("size overflow"))
}
fn mul(a: usize, b: usize) -> Result<usize, CodecError> {
    a.checked_mul(b).ok_or_else(|| bad("size overflow"))
}
fn pod_size(body: usize) -> Result<usize, CodecError> {
    Ok(add(body, 15)? & !7)
}
fn array_size(n: usize, width: usize) -> Result<usize, CodecError> {
    pod_size(add(8, mul(n, width)?)?)
}
fn string_size(n: usize) -> Result<usize, CodecError> {
    pod_size(add(n, 1)?)
}
fn base(completion: bool) -> Result<usize, CodecError> {
    let (header, payload) = if completion {
        (
            "pipewireao.rtc.control.completion.header",
            "pipewireao.rtc.control.completion.payload",
        )
    } else {
        (
            "pipewireao.rtc.control.request.header",
            "pipewireao.rtc.control.request.payload",
        )
    };
    add(
        176,
        add(string_size(header.len())?, string_size(payload.len())?)?,
    )
}
fn bound(size: usize, limit: usize) -> Result<usize, CodecError> {
    if size > limit {
        Err(CodecError::Oversize {
            actual: size,
            limit,
        })
    } else {
        Ok(size)
    }
}
fn rule_size(r: Rule) -> usize {
    if r == Rule::Immediate {
        24
    } else {
        40
    }
}
fn args_size(a: &Action) -> Result<usize, CodecError> {
    Ok(match a {
        Action::Hold | Action::Release => 8,
        Action::Adopt { probe: p, figure } => {
            probe(*p)?;
            floats(figure, 4096)?;
            add(24, array_size(figure.len(), 4)?)?
        }
        Action::Settle {
            probe: p,
            after,
            rule: r,
        } => {
            probe(*p)?;
            cursor(*after)?;
            rule(*r)?;
            96 + rule_size(*r)
        }
        Action::Collect {
            probe: p,
            after,
            measurements: m,
            frames: n,
        } => {
            probe(*p)?;
            cursor(*after)?;
            measurements(*m as usize)?;
            frames(*n as usize)?;
            128
        }
        Action::Capture {
            probe: p,
            after,
            frames: n,
        } => {
            probe(*p)?;
            cursor(*after)?;
            frames(*n as usize)?;
            112
        }
        Action::Restore { figure, rule: r } => {
            floats(figure, 4096)?;
            rule(*r)?;
            add(8, add(array_size(figure.len(), 4)?, rule_size(*r))?)?
        }
    })
}
fn id(v: u32) -> Value {
    Value::Id(Id(v))
}
fn long(v: u64) -> Value {
    Value::Long(envelope::serial_to_long(v))
}
fn cursor_value(c: AcquisitionCursor) -> Value {
    Value::Struct(vec![
        long(c.domain),
        long(c.generation),
        long(c.sequence),
        long(c.model_ns),
    ])
}
fn float_value(v: &[f32]) -> Value {
    Value::ValueArray(ValueArray::Float(v.to_vec()))
}
fn rule_value(r: Rule) -> Value {
    Value::Struct(match r {
        Rule::Immediate => vec![id(1)],
        Rule::DiscardExposures(n) => vec![id(2), id(n)],
        Rule::ModelTime(n) => vec![id(3), long(n)],
    })
}
fn args(a: &Action) -> Value {
    Value::Struct(match a {
        Action::Hold | Action::Release => vec![],
        Action::Adopt { probe, figure } => vec![id(*probe), float_value(figure)],
        Action::Settle { probe, after, rule } => {
            vec![id(*probe), cursor_value(*after), rule_value(*rule)]
        }
        Action::Collect {
            probe,
            after,
            measurements,
            frames,
        } => vec![
            id(*probe),
            cursor_value(*after),
            id(*measurements),
            id(*frames),
        ],
        Action::Capture {
            probe,
            after,
            frames,
        } => vec![id(*probe), cursor_value(*after), id(*frames)],
        Action::Restore { figure, rule } => vec![float_value(figure), rule_value(*rule)],
    })
}
/// Encode only after validating borrowed data and exact request extent.
/// # Errors
/// Rejects malformed actions, identity mismatch, or excess capacity.
pub fn encode_request(header: &RequestHeader, command: &Command) -> Result<Vec<u8>, CodecError> {
    header.validate()?;
    identity(command.run, command.serial)?;
    check(
        header.operation == command.action.operation(),
        "header/action operation mismatch",
    )?;
    bound(
        add(base(false)?, add(32, args_size(&command.action)?)?)?,
        envelope::REQUEST_BOUND,
    )?;
    envelope::encode_request(
        header,
        &[
            long(command.run),
            long(command.serial),
            args(&command.action),
        ],
    )
}
fn fields(v: &Value, n: usize) -> Result<&[Value], CodecError> {
    let Value::Struct(f) = v else {
        return Err(bad("expected Struct"));
    };
    check(f.len() == n, "wrong field arity")?;
    Ok(f)
}
fn any_fields(v: &Value) -> Result<&[Value], CodecError> {
    let Value::Struct(f) = v else {
        return Err(bad("expected Struct"));
    };
    check(!f.is_empty(), "empty tagged Struct")?;
    Ok(f)
}
fn read_id(v: &Value) -> Result<u32, CodecError> {
    if let Value::Id(Id(v)) = v {
        Ok(*v)
    } else {
        Err(bad("expected Id"))
    }
}
fn read_long(v: &Value) -> Result<u64, CodecError> {
    if let Value::Long(v) = v {
        Ok(envelope::serial_from_long(*v))
    } else {
        Err(bad("expected Long"))
    }
}
fn read_bool(v: &Value) -> Result<bool, CodecError> {
    if let Value::Bool(v) = v {
        Ok(*v)
    } else {
        Err(bad("expected Bool"))
    }
}
fn read_text(v: &Value, max: usize) -> Result<String, CodecError> {
    if let Value::String(v) = v {
        text(v, max)?;
        Ok(v.clone())
    } else {
        Err(bad("expected String"))
    }
}
fn read_float(v: &Value, max: usize) -> Result<Vec<f32>, CodecError> {
    if let Value::ValueArray(ValueArray::Float(v)) = v {
        floats(v, max)?;
        Ok(v.clone())
    } else {
        Err(bad("expected Float Array"))
    }
}
fn read_cursor(v: &Value) -> Result<AcquisitionCursor, CodecError> {
    let f = fields(v, 4)?;
    let c = AcquisitionCursor {
        domain: read_long(&f[0])?,
        generation: read_long(&f[1])?,
        sequence: read_long(&f[2])?,
        model_ns: read_long(&f[3])?,
    };
    cursor(c)?;
    Ok(c)
}
fn read_rule(v: &Value) -> Result<Rule, CodecError> {
    let f = any_fields(v)?;
    let r = match read_id(&f[0])? {
        1 => {
            fields(v, 1)?;
            Rule::Immediate
        }
        2 => {
            fields(v, 2)?;
            Rule::DiscardExposures(read_id(&f[1])?)
        }
        3 => {
            fields(v, 2)?;
            Rule::ModelTime(read_long(&f[1])?)
        }
        _ => return Err(bad("unknown rule")),
    };
    rule(r)?;
    Ok(r)
}
fn read_action(op: u32, v: &Value) -> Result<Action, CodecError> {
    Ok(match op {
        1 => {
            fields(v, 0)?;
            Action::Hold
        }
        2 => {
            let f = fields(v, 2)?;
            Action::Adopt {
                probe: read_id(&f[0])?,
                figure: read_float(&f[1], 4096)?,
            }
        }
        3 => {
            let f = fields(v, 3)?;
            Action::Settle {
                probe: read_id(&f[0])?,
                after: read_cursor(&f[1])?,
                rule: read_rule(&f[2])?,
            }
        }
        4 => {
            let f = fields(v, 4)?;
            Action::Collect {
                probe: read_id(&f[0])?,
                after: read_cursor(&f[1])?,
                measurements: read_id(&f[2])?,
                frames: read_id(&f[3])?,
            }
        }
        5 => {
            let f = fields(v, 3)?;
            Action::Capture {
                probe: read_id(&f[0])?,
                after: read_cursor(&f[1])?,
                frames: read_id(&f[2])?,
            }
        }
        6 => {
            let f = fields(v, 2)?;
            Action::Restore {
                figure: read_float(&f[0], 4096)?,
                rule: read_rule(&f[1])?,
            }
        }
        7 => {
            fields(v, 0)?;
            Action::Release
        }
        _ => return Err(bad("unknown calibration operation")),
    })
}
/// Decode an owned command through the strict shared envelope grammar.
/// # Errors
/// Rejects malformed envelope, fields, or unsupported operation.
pub fn decode_request(bytes: &[u8]) -> Result<(RequestHeader, Command), CodecError> {
    let r = envelope::decode_request(bytes)?;
    check(r.payload.len() == 3, "wrong request arity")?;
    let c = Command {
        run: read_long(&r.payload[0])?,
        serial: read_long(&r.payload[1])?,
        action: read_action(r.header.operation, &r.payload[2])?,
    };
    identity(c.run, c.serial)?;
    args_size(&c.action)?;
    Ok((r.header, c))
}
fn result_size(r: &ResultValue) -> Result<usize, CodecError> {
    Ok(match r {
        ResultValue::Held(c) | ResultValue::Settled(c) => {
            cursor(*c)?;
            96
        }
        ResultValue::Adopted {
            cursor: c, figure, ..
        } => {
            cursor(*c)?;
            floats(figure, 4096)?;
            add(112, array_size(figure.len(), 4)?)?
        }
        ResultValue::Responses {
            values,
            exposures: e,
            ..
        } => {
            floats(values, 131_072)?;
            exposures(e)?;
            add(
                40,
                add(array_size(values.len(), 4)?, array_size(e.len(), 40)?)?,
            )?
        }
        ResultValue::Captured {
            cursor: c,
            manifest: m,
            sha256,
            frames: n,
            ..
        } => {
            cursor(*c)?;
            manifest(m)?;
            sha(sha256)?;
            frames(*n as usize)?;
            add(144, add(string_size(m.len())?, string_size(64)?)?)?
        }
        ResultValue::Restored { figure, .. } => {
            floats(figure, 4096)?;
            add(40, array_size(figure.len(), 4)?)?
        }
        ResultValue::Released => 24,
        ResultValue::Failed(_) => 40,
    })
}
fn completion_size(result_size: usize, message_bytes: usize) -> Result<usize, CodecError> {
    check(message_bytes <= 8192, "invalid message length")?;
    add(
        base(true)?,
        add(48, add(result_size, string_size(message_bytes)?)?)?,
    )
}
/// Exact successful Collect extent, without allocating dummy arrays.
/// # Errors
/// Rejects invalid counts or arithmetic overflow. Capacity is checked separately.
pub fn collect_reply_size(
    measurements_count: usize,
    frame_count: usize,
    message_bytes: usize,
) -> Result<usize, CodecError> {
    measurements(measurements_count)?;
    frames(frame_count)?;
    completion_size(
        add(
            40,
            add(
                array_size(measurements_count, 4)?,
                array_size(frame_count, 40)?,
            )?,
        )?,
        message_bytes,
    )
}
/// Check exact serialized capacity before any Collect effects.
/// # Errors
/// Rejects invalid counts, message length, or completion exceeding 128 KiB.
pub fn preflight_collect_reply(
    measurements_count: usize,
    frame_count: usize,
    message_bytes: usize,
) -> Result<usize, CodecError> {
    bound(
        collect_reply_size(measurements_count, frame_count, message_bytes)?,
        envelope::CALIBRATION_REPLY_BOUND,
    )
}
fn result_value(r: &ResultValue) -> Value {
    let mut f = vec![id(r.tag())];
    match r {
        ResultValue::Held(c) | ResultValue::Settled(c) => f.push(cursor_value(*c)),
        ResultValue::Adopted {
            cursor,
            figure,
            clipped,
        } => f.extend([
            cursor_value(*cursor),
            float_value(figure),
            Value::Bool(*clipped),
        ]),
        ResultValue::Responses {
            values,
            exposures,
            valid,
        } => {
            let flat = exposures
                .iter()
                .flat_map(|e| {
                    [
                        e.domain,
                        e.generation,
                        e.sequence,
                        e.start_model_ns,
                        e.duration_ns,
                    ]
                })
                .map(envelope::serial_to_long)
                .collect();
            f.extend([
                float_value(values),
                Value::ValueArray(ValueArray::Long(flat)),
                Value::Bool(*valid),
            ]);
        }
        ResultValue::Captured {
            cursor,
            manifest,
            sha256,
            frames,
            bytes,
            metadata_bytes,
        } => f.extend([
            cursor_value(*cursor),
            Value::String(manifest.clone()),
            Value::String(sha256.clone()),
            id(*frames),
            long(*bytes),
            long(*metadata_bytes),
        ]),
        ResultValue::Restored { figure, clipped } => {
            f.extend([float_value(figure), Value::Bool(*clipped)]);
        }
        ResultValue::Released => {}
        ResultValue::Failed(reason) => f.push(id(*reason as u32)),
    }
    Value::Struct(f)
}
fn read_exposures(v: &Value) -> Result<Vec<Exposure>, CodecError> {
    let Value::ValueArray(ValueArray::Long(flat)) = v else {
        return Err(bad("expected Long Array"));
    };
    check(
        flat.len() % 5 == 0,
        "exposures require five Longs per record",
    )?;
    frames(flat.len() / 5)?;
    let result = flat
        .chunks_exact(5)
        .map(|f| Exposure {
            domain: envelope::serial_from_long(f[0]),
            generation: envelope::serial_from_long(f[1]),
            sequence: envelope::serial_from_long(f[2]),
            start_model_ns: envelope::serial_from_long(f[3]),
            duration_ns: envelope::serial_from_long(f[4]),
        })
        .collect::<Vec<_>>();
    exposures(&result)?;
    Ok(result)
}
fn read_result(v: &Value) -> Result<ResultValue, CodecError> {
    let f = any_fields(v)?;
    Ok(match read_id(&f[0])? {
        1 => {
            fields(v, 2)?;
            ResultValue::Held(read_cursor(&f[1])?)
        }
        2 => {
            fields(v, 4)?;
            ResultValue::Adopted {
                cursor: read_cursor(&f[1])?,
                figure: read_float(&f[2], 4096)?,
                clipped: read_bool(&f[3])?,
            }
        }
        3 => {
            fields(v, 2)?;
            ResultValue::Settled(read_cursor(&f[1])?)
        }
        4 => {
            fields(v, 4)?;
            ResultValue::Responses {
                values: read_float(&f[1], 131_072)?,
                exposures: read_exposures(&f[2])?,
                valid: read_bool(&f[3])?,
            }
        }
        5 => {
            fields(v, 7)?;
            ResultValue::Captured {
                cursor: read_cursor(&f[1])?,
                manifest: read_text(&f[2], 512)?,
                sha256: read_text(&f[3], 64)?,
                frames: read_id(&f[4])?,
                bytes: read_long(&f[5])?,
                metadata_bytes: read_long(&f[6])?,
            }
        }
        6 => {
            fields(v, 3)?;
            ResultValue::Restored {
                figure: read_float(&f[1], 4096)?,
                clipped: read_bool(&f[2])?,
            }
        }
        7 => {
            fields(v, 1)?;
            ResultValue::Released
        }
        8 => {
            fields(v, 2)?;
            ResultValue::Failed(match read_id(&f[1])? {
                1 => FailureReason::Cancelled,
                2 => FailureReason::Endpoint,
                3 => FailureReason::InvalidEvidence,
                4 => FailureReason::ProbeClipped,
                _ => return Err(bad("unknown failure reason")),
            })
        }
        _ => return Err(bad("unknown result tag")),
    })
}
fn lifecycle(v: &Value) -> Result<ColdLifecycle, CodecError> {
    Ok(match read_id(v)? {
        1 => ColdLifecycle::Preparing,
        2 => ColdLifecycle::Prepared,
        3 => ColdLifecycle::Connected,
        4 => ColdLifecycle::Fault,
        5 => ColdLifecycle::Stopped,
        _ => return Err(bad("unknown cold lifecycle")),
    })
}
fn validate_completion(c: &Completion) -> Result<(), CodecError> {
    c.header.validate(ReplyKind::Completion)?;
    identity(c.run, c.serial)?;
    check(
        c.header.controller.global_id != 0 && (1..=7).contains(&c.header.operation),
        "invalid action completion correlation",
    )?;
    text(&c.message, 8192)?;
    match &c.result {
        None => check(c.header.result < 0, "successful completion requires result"),
        Some(r) => {
            check(
                r.tag() == 8 || r.tag() == c.header.operation,
                "operation/result mismatch",
            )?;
            result_size(r)?;
            Ok(())
        }
    }
}
/// Encode completion after checking borrowed results and exact capacity.
/// # Errors
/// Rejects invalid results, identity, operation mismatch, or excess capacity.
pub fn encode_completion(c: &Completion) -> Result<Vec<u8>, CodecError> {
    validate_completion(c)?;
    bound(
        completion_size(
            c.result.as_ref().map_or(Ok(8), result_size)?,
            c.message.len(),
        )?,
        envelope::CALIBRATION_REPLY_BOUND,
    )?;
    envelope::encode_reply(
        ReplyKind::Completion,
        &c.header,
        &[
            id(c.lifecycle as u32),
            long(c.run),
            long(c.serial),
            c.result.as_ref().map_or(Value::None, result_value),
            Value::String(c.message.clone()),
        ],
        ReplyBound::Calibration,
    )
}
/// Decode a typed completion.
/// # Errors
/// Rejects malformed envelope and inconsistent or unsupported action evidence.
pub fn decode_completion(bytes: &[u8]) -> Result<Completion, CodecError> {
    let r = envelope::decode_reply(bytes, ReplyKind::Completion, ReplyBound::Calibration)?;
    check(r.payload.len() == 5, "wrong completion arity")?;
    let c = Completion {
        header: r.header,
        lifecycle: lifecycle(&r.payload[0])?,
        run: read_long(&r.payload[1])?,
        serial: read_long(&r.payload[2])?,
        result: if r.payload[3] == Value::None {
            None
        } else {
            Some(read_result(&r.payload[3])?)
        },
        message: read_text(&r.payload[4], 8192)?,
    };
    validate_completion(&c)?;
    Ok(c)
}
/// Encode a separate transport rejection (no action result).
/// # Errors
/// Rejects invalid rejection header or message.
pub fn encode_rejection(r: &Rejection) -> Result<Vec<u8>, CodecError> {
    text(&r.message, 8192)?;
    envelope::encode_reply(
        ReplyKind::Rejection,
        &r.header,
        &[id(r.lifecycle as u32), Value::String(r.message.clone())],
        ReplyBound::Calibration,
    )
}
/// Decode a separate transport rejection.
/// # Errors
/// Rejects malformed rejection fields or unknown lifecycle.
pub fn decode_rejection(bytes: &[u8]) -> Result<Rejection, CodecError> {
    let r = envelope::decode_reply(bytes, ReplyKind::Rejection, ReplyBound::Calibration)?;
    check(r.payload.len() == 2, "wrong rejection arity")?;
    Ok(Rejection {
        header: r.header,
        lifecycle: lifecycle(&r.payload[0])?,
        message: read_text(&r.payload[1], 8192)?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use envelope::ControllerIdentity;
    fn request(op: u32) -> RequestHeader {
        RequestHeader {
            version: 1,
            endpoint_instance: 42,
            controller: ControllerIdentity {
                global_id: 7,
                serial: u64::MAX,
                instance: 11,
            },
            token: i64::from(op),
            operation: op,
            budget_ns: i64::MAX,
        }
    }
    fn reply(op: u32) -> ReplyHeader {
        ReplyHeader {
            version: 1,
            endpoint_instance: 42,
            controller: request(op).controller,
            token: i64::from(op),
            operation: op,
            result: 0,
        }
    }
    fn cur() -> AcquisitionCursor {
        AcquisitionCursor {
            domain: u64::MAX,
            generation: 1 << 63,
            sequence: u64::MAX,
            model_ns: i64::MAX as u64,
        }
    }
    fn exp() -> Exposure {
        Exposure {
            domain: u64::MAX,
            generation: 1 << 63,
            sequence: u64::MAX,
            start_model_ns: 1 << 63,
            duration_ns: i64::MAX as u64,
        }
    }
    fn completion(op: u32, result: ResultValue) -> Completion {
        Completion {
            header: reply(op),
            lifecycle: ColdLifecycle::Connected,
            run: u64::MAX,
            serial: 1 << 63,
            result: Some(result),
            message: String::new(),
        }
    }
    fn fixtures() -> Vec<(String, Vec<u8>)> {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("tests/fixtures/native-calibration-actions");
        std::fs::read_dir(dir)
            .unwrap()
            .map(|e| {
                let e = e.unwrap();
                (
                    e.file_name().into_string().unwrap(),
                    std::fs::read(e.path()).unwrap(),
                )
            })
            .filter(|(n, _)| {
                std::path::Path::new(n)
                    .extension()
                    .is_some_and(|ext| ext == "pod")
            })
            .collect()
    }
    #[test]
    fn shared_julia_fixtures_roundtrip_and_reject() {
        let mut good = 0;
        let mut bad_count = 0;
        for (name, bytes) in fixtures() {
            if name.starts_with("request-") {
                let (h, c) = decode_request(&bytes).unwrap();
                assert_eq!(c.run, u64::MAX);
                assert_eq!(c.serial, 1 << 63);
                assert_eq!(encode_request(&h, &c).unwrap(), bytes);
                good += 1;
            } else if name.starts_with("reply-") {
                let c = decode_completion(&bytes).unwrap();
                assert_eq!(c.run, u64::MAX);
                assert_eq!(c.serial, 1 << 63);
                assert_eq!(encode_completion(&c).unwrap(), bytes);
                good += 1;
            } else if name == "rejection.pod" {
                let r = decode_rejection(&bytes).unwrap();
                assert_eq!(encode_rejection(&r).unwrap(), bytes);
                good += 1;
            } else if name.starts_with("bad-request-") {
                assert!(decode_request(&bytes).is_err(), "{name}");
                bad_count += 1;
            } else if name.starts_with("bad-reply-") {
                assert!(decode_completion(&bytes).is_err(), "{name}");
                bad_count += 1;
            } else {
                panic!("unclassified fixture {name}")
            }
        }
        assert_eq!(good, 22);
        assert_eq!(bad_count, 21);
    }
    #[test]
    fn request_validates_before_encoding_and_preserves_unsigned_bits() {
        for n in [1, (1 << 63) - 1, 1 << 63, u64::MAX] {
            let c = Command {
                run: n,
                serial: n,
                action: Action::Hold,
            };
            assert_eq!(
                decode_request(&encode_request(&request(1), &c).unwrap())
                    .unwrap()
                    .1,
                c
            );
        }
        for c in [
            Command {
                run: 0,
                serial: 1,
                action: Action::Hold,
            },
            Command {
                run: 1,
                serial: 0,
                action: Action::Hold,
            },
            Command {
                run: 1,
                serial: 1,
                action: Action::Adopt {
                    probe: 0,
                    figure: vec![0.; 4096],
                },
            },
        ] {
            assert!(encode_request(&request(c.action.operation()), &c).is_err());
        }
        let c = Command {
            run: 1,
            serial: 1,
            action: Action::Release,
        };
        assert!(encode_request(&request(1), &c).is_err());
        let maximum = (1..=4096)
            .take_while(|n| {
                base(false).unwrap() + 32 + 24 + array_size(*n, 4).unwrap()
                    <= envelope::REQUEST_BOUND
            })
            .last()
            .unwrap();
        let full = Command {
            run: 1,
            serial: 1,
            action: Action::Adopt {
                probe: 0,
                figure: vec![0.; maximum],
            },
        };
        let bytes = encode_request(&request(2), &full).unwrap();
        assert_eq!(bytes.len(), envelope::REQUEST_BOUND);
        assert_eq!(decode_request(&bytes).unwrap().1, full);
        assert!(encode_request(
            &request(2),
            &Command {
                run: 1,
                serial: 1,
                action: Action::Adopt {
                    probe: 0,
                    figure: vec![0.; maximum + 1]
                }
            }
        )
        .is_err());
        assert!(decode_request(&vec![0; envelope::REQUEST_BOUND + 1]).is_err());
    }
    #[test]
    fn exact_collect_capacity_matches_serialization_at_boundary() {
        for (m, n, msg) in [(1, 1, 0), (376, 409, 0), (3600, 100, 8192), (32000, 1, 1)] {
            let mut c = completion(
                4,
                ResultValue::Responses {
                    values: vec![0.; m],
                    exposures: vec![exp(); n],
                    valid: true,
                },
            );
            c.message = "x".repeat(msg);
            assert_eq!(
                encode_completion(&c).unwrap().len(),
                preflight_collect_reply(m, n, msg).unwrap()
            );
        }
        let maximum = (1..=131_072)
            .take_while(|m| collect_reply_size(*m, 1, 0).unwrap() <= 131_072)
            .last()
            .unwrap();
        assert_eq!(preflight_collect_reply(maximum, 1, 0).unwrap(), 131_072);
        assert!(preflight_collect_reply(maximum + 1, 1, 0).is_err());
        assert!(encode_completion(&completion(
            4,
            ResultValue::Responses {
                values: vec![0.; maximum + 1],
                exposures: vec![exp()],
                valid: true
            }
        ))
        .is_err());
        assert!(preflight_collect_reply(1, 4096, 0).is_err());
        assert!(preflight_collect_reply(131_072, 4096, 0).is_err());
        for (m, n) in [
            (0, 1),
            (131_073, 1),
            (1, 0),
            (1, 4097),
            (usize::MAX, usize::MAX),
        ] {
            assert!(preflight_collect_reply(m, n, 0).is_err());
        }
        assert!(preflight_collect_reply(1, 1, 8193).is_err());
        assert!(decode_completion(&vec![0; 131_073]).is_err());
    }
    #[test]
    fn cursor_and_exposure_domains_and_times_are_distinct() {
        let mut c = cur();
        c.model_ns = 1 << 63;
        assert!(cursor(c).is_err());
        for c in [
            AcquisitionCursor { domain: 0, ..cur() },
            AcquisitionCursor {
                generation: 0,
                ..cur()
            },
        ] {
            assert!(cursor(c).is_err());
        }
        for e in [
            Exposure { domain: 0, ..exp() },
            Exposure {
                generation: 0,
                ..exp()
            },
            Exposure {
                duration_ns: 0,
                ..exp()
            },
            Exposure {
                start_model_ns: u64::MAX,
                duration_ns: 1,
                ..exp()
            },
        ] {
            assert!(exposure(&e).is_err());
        }
        assert!(exposure(&Exposure {
            start_model_ns: 0,
            duration_ns: u64::MAX,
            ..exp()
        })
        .is_ok());
    }
    #[test]
    fn typed_failure_negative_transport_and_rejection_stay_distinct() {
        for reason in [
            FailureReason::Cancelled,
            FailureReason::Endpoint,
            FailureReason::InvalidEvidence,
            FailureReason::ProbeClipped,
        ] {
            let c = completion(1, ResultValue::Failed(reason));
            assert_eq!(
                decode_completion(&encode_completion(&c).unwrap()).unwrap(),
                c
            );
        }
        let mut c = completion(1, ResultValue::Released);
        assert!(encode_completion(&c).is_err());
        c.result = None;
        assert!(encode_completion(&c).is_err());
        c.header.result = -22;
        assert_eq!(
            decode_completion(&encode_completion(&c).unwrap()).unwrap(),
            c
        );
        let r = Rejection {
            header: c.header,
            lifecycle: ColdLifecycle::Fault,
            message: "rejected".into(),
        };
        let bytes = encode_rejection(&r).unwrap();
        assert_eq!(decode_rejection(&bytes).unwrap(), r);
        assert!(decode_completion(&bytes).is_err());
        c.header.operation = 8;
        assert!(encode_completion(&c).is_err());
    }
    #[test]
    fn capture_paths_hashes_counts_and_strings_are_bounded() {
        for path in ["/absolute", "../escape", "a/../escape", "a//b", "a\\b", ""] {
            assert!(manifest(path).is_err());
        }
        assert!(manifest(&"x".repeat(513)).is_err());
        assert!(sha(&"A".repeat(64)).is_err());
        assert!(sha(&"a".repeat(63)).is_err());
        let mut c = completion(1, ResultValue::Held(cur()));
        c.message = "x".repeat(8193);
        assert!(encode_completion(&c).is_err());
        c.message = "a\0b".into();
        assert!(encode_completion(&c).is_err());
        assert!(rule(Rule::ModelTime(0)).is_err());
        assert!(rule(Rule::ModelTime(1 << 63)).is_err());
        assert!(rule(Rule::DiscardExposures(4097)).is_err());
    }
}
