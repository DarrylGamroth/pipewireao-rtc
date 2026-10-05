//! Cold native control envelope v1, as specified in `docs/NATIVE_CONTROL_ENVELOPE.md`.
//!
//! Payloads are owner-defined native Structs. The envelope checks only their
//! container grammar and bounds; owners must validate operation fields and effects.
//! Envelope and payload metadata are checked before the recursive POD decoder runs.

use pipewire::spa;
use spa::pod::deserialize::PodDeserializer;
use spa::pod::serialize::PodSerializer;
use spa::pod::{Object, Property, Value, ValueArray};
use spa::utils::{Id, SpaTypes};
use std::fmt;
use std::io::Cursor;

pub const VERSION: i32 = 1;
pub const REQUEST_BOUND: usize = 16 * 1024;
pub const LIFECYCLE_REPLY_BOUND: usize = 64 * 1024;
pub const CALIBRATION_REPLY_BOUND: usize = 128 * 1024;
/// Counts the payload's root Struct as level one.
pub const MAX_PAYLOAD_DEPTH: usize = 8;

const REQUEST_HEADER: &str = "pipewireao.rtc.control.request.header";
const REQUEST_PAYLOAD: &str = "pipewireao.rtc.control.request.payload";
const COMPLETION_HEADER: &str = "pipewireao.rtc.control.completion.header";
const COMPLETION_PAYLOAD: &str = "pipewireao.rtc.control.completion.payload";
const REJECTION_HEADER: &str = "pipewireao.rtc.control.rejection.header";
const REJECTION_PAYLOAD: &str = "pipewireao.rtc.control.rejection.payload";

/// Owned native values, never borrowed callback storage or a JSON/map encoding.
pub type NativeStruct = Vec<Value>;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ControllerIdentity {
    pub global_id: u32,
    pub serial: u64,
    pub instance: i64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RequestHeader {
    pub version: i32,
    pub endpoint_instance: i64,
    pub controller: ControllerIdentity,
    pub token: i64,
    pub operation: u32,
    pub budget_ns: i64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ReplyHeader {
    pub version: i32,
    pub endpoint_instance: i64,
    pub controller: ControllerIdentity,
    pub token: i64,
    pub operation: u32,
    pub result: i32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Request {
    pub header: RequestHeader,
    pub payload: NativeStruct,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Reply {
    pub kind: ReplyKind,
    pub header: ReplyHeader,
    pub payload: NativeStruct,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ReplyKind {
    Completion,
    Rejection,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum ReplyBound {
    #[default]
    Lifecycle,
    Calibration,
}

impl ReplyBound {
    #[must_use]
    pub const fn bytes(self) -> usize {
        match self {
            Self::Lifecycle => LIFECYCLE_REPLY_BOUND,
            Self::Calibration => CALIBRATION_REPLY_BOUND,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CodecError {
    Oversize { limit: usize, actual: usize },
    Malformed(&'static str),
    InvalidHeader,
    UnsupportedPayload,
    PayloadDepth,
    Serialization,
    Deserialization,
}

impl fmt::Display for CodecError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Oversize { limit, actual } => {
                write!(f, "native envelope size {actual} exceeds {limit}")
            }
            Self::Malformed(reason) => write!(f, "malformed native envelope: {reason}"),
            Self::InvalidHeader => f.write_str("invalid native control header"),
            Self::UnsupportedPayload => f.write_str("unsupported native payload container"),
            Self::PayloadDepth => f.write_str("native payload exceeds eight Struct levels"),
            Self::Serialization => f.write_str("native POD serialization failed"),
            Self::Deserialization => f.write_str("native POD deserialization failed"),
        }
    }
}

impl std::error::Error for CodecError {}

/// Preserve every `u64` bit pattern, including serials above `i64::MAX`.
#[must_use]
pub const fn serial_to_long(serial: u64) -> i64 {
    i64::from_ne_bytes(serial.to_ne_bytes())
}

#[must_use]
pub const fn serial_from_long(value: i64) -> u64 {
    u64::from_ne_bytes(value.to_ne_bytes())
}

fn correlated(controller: ControllerIdentity, token: i64, operation: u32) -> bool {
    controller.global_id != 0
        && controller.global_id != u32::MAX
        && controller.serial > 0
        && controller.instance > 0
        && token > 0
        && operation > 0
}

fn sentinel(controller: ControllerIdentity, token: i64, operation: u32) -> bool {
    controller.global_id == 0
        && controller.serial == 0
        && controller.instance == 0
        && token == 0
        && operation == 0
}

impl RequestHeader {
    /// Validate the fixed header; the owner validates the operation and controller incarnation.
    ///
    /// # Errors
    /// Rejects wrong versions, zero/invalid identity fields, or nonpositive signed fields.
    pub fn validate(self) -> Result<(), CodecError> {
        if self.version == VERSION
            && self.endpoint_instance > 0
            && self.budget_ns > 0
            && correlated(self.controller, self.token, self.operation)
        {
            Ok(())
        } else {
            Err(CodecError::InvalidHeader)
        }
    }
}

impl ReplyHeader {
    /// Validate a correlated reply or the exact initial/uncorrelated sentinel.
    ///
    /// # Errors
    /// Rejects partial zero identities, invalid versions/instances, or invalid results.
    pub fn validate(self, kind: ReplyKind) -> Result<(), CodecError> {
        let identity_ok = correlated(self.controller, self.token, self.operation)
            || (sentinel(self.controller, self.token, self.operation)
                && (kind == ReplyKind::Rejection || self.result == 0));
        let result_ok = match kind {
            ReplyKind::Completion => self.result <= 0,
            ReplyKind::Rejection => self.result < 0,
        };
        if self.version == VERSION && self.endpoint_instance > 0 && identity_ok && result_ok {
            Ok(())
        } else {
            Err(CodecError::InvalidHeader)
        }
    }
}

#[derive(Clone, Copy)]
enum Record {
    Request,
    Reply(ReplyKind),
}

impl Record {
    fn names(self) -> (&'static str, &'static str) {
        match self {
            Self::Request => (REQUEST_HEADER, REQUEST_PAYLOAD),
            Self::Reply(ReplyKind::Completion) => (COMPLETION_HEADER, COMPLETION_PAYLOAD),
            Self::Reply(ReplyKind::Rejection) => (REJECTION_HEADER, REJECTION_PAYLOAD),
        }
    }
}

fn checked_add(a: usize, b: usize) -> Result<usize, CodecError> {
    a.checked_add(b)
        .ok_or(CodecError::Malformed("size overflow"))
}

fn aligned(size: usize) -> Result<usize, CodecError> {
    Ok(checked_add(size, 7)? & !7)
}

fn pod_size(body: usize) -> Result<usize, CodecError> {
    aligned(checked_add(8, body)?)
}

fn check_bound(actual: usize, limit: usize) -> Result<(), CodecError> {
    if actual > limit {
        Err(CodecError::Oversize { limit, actual })
    } else {
        Ok(())
    }
}

fn read_u32(bytes: &[u8], offset: usize) -> Result<u32, CodecError> {
    let end = checked_add(offset, 4)?;
    let value = bytes
        .get(offset..end)
        .ok_or(CodecError::Malformed("truncated metadata"))?;
    let value = value
        .try_into()
        .map_err(|_| CodecError::Malformed("metadata width"))?;
    Ok(u32::from_ne_bytes(value))
}

#[derive(Clone, Copy, Default)]
struct Span {
    body: usize,
    end: usize,
    next: usize,
    type_: u32,
}

fn span(bytes: &[u8], start: usize, limit: usize) -> Result<Span, CodecError> {
    let body = checked_add(start, 8)?;
    if body > limit || limit > bytes.len() {
        return Err(CodecError::Malformed("truncated POD header"));
    }
    let size =
        usize::try_from(read_u32(bytes, start)?).map_err(|_| CodecError::Malformed("POD size"))?;
    let end = checked_add(body, size)?;
    let next = aligned(end)?;
    if end > limit || next > limit {
        return Err(CodecError::Malformed("POD exceeds enclosing body"));
    }
    Ok(Span {
        body,
        end,
        next,
        type_: read_u32(bytes, checked_add(start, 4)?)?,
    })
}

fn children<const N: usize>(bytes: &[u8], parent: Span) -> Result<[Span; N], CodecError> {
    if parent.type_ != spa::sys::SPA_TYPE_Struct {
        return Err(CodecError::Malformed("expected Struct"));
    }
    let mut result = [Span::default(); N];
    let mut offset = parent.body;
    for child in &mut result {
        *child = span(bytes, offset, parent.end)?;
        offset = child.next;
    }
    if offset != parent.end {
        return Err(CodecError::Malformed("wrong Struct arity"));
    }
    Ok(result)
}

fn scalar_size(type_: u32) -> Option<usize> {
    match type_ {
        spa::sys::SPA_TYPE_None => Some(0),
        spa::sys::SPA_TYPE_Bool
        | spa::sys::SPA_TYPE_Id
        | spa::sys::SPA_TYPE_Int
        | spa::sys::SPA_TYPE_Float => Some(4),
        spa::sys::SPA_TYPE_Long | spa::sys::SPA_TYPE_Double => Some(8),
        _ => None,
    }
}

fn array_scalar_size(type_: u32) -> Option<usize> {
    match type_ {
        spa::sys::SPA_TYPE_Bool
        | spa::sys::SPA_TYPE_Id
        | spa::sys::SPA_TYPE_Int
        | spa::sys::SPA_TYPE_Float => Some(4),
        spa::sys::SPA_TYPE_Long | spa::sys::SPA_TYPE_Double => Some(8),
        _ => None,
    }
}

fn string_body(bytes: &[u8], value: Span) -> Result<&[u8], CodecError> {
    if value.type_ != spa::sys::SPA_TYPE_String {
        return Err(CodecError::Malformed("expected String"));
    }
    let body = bytes
        .get(value.body..value.end)
        .ok_or(CodecError::Malformed("truncated String"))?;
    let Some((&0, text)) = body.split_last() else {
        return Err(CodecError::Malformed("String lacks terminator"));
    };
    if text.contains(&0) || std::str::from_utf8(text).is_err() {
        return Err(CodecError::Malformed("invalid String"));
    }
    Ok(text)
}

fn guard_payload(bytes: &[u8], value: Span, depth: usize) -> Result<(), CodecError> {
    if let Some(size) = scalar_size(value.type_) {
        if value.end - value.body != size {
            return Err(CodecError::Malformed("scalar width"));
        }
        return Ok(());
    }
    match value.type_ {
        spa::sys::SPA_TYPE_Struct => {
            if depth > MAX_PAYLOAD_DEPTH {
                return Err(CodecError::PayloadDepth);
            }
            let mut offset = value.body;
            while offset < value.end {
                let child = span(bytes, offset, value.end)?;
                guard_payload(bytes, child, depth + 1)?;
                offset = child.next;
            }
            Ok(())
        }
        spa::sys::SPA_TYPE_String => string_body(bytes, value).map(|_| ()),
        spa::sys::SPA_TYPE_Bytes => Ok(()),
        spa::sys::SPA_TYPE_Array => {
            if value.end - value.body < 8 {
                return Err(CodecError::Malformed("truncated Array child"));
            }
            let size = usize::try_from(read_u32(bytes, value.body)?)
                .map_err(|_| CodecError::Malformed("Array child size"))?;
            let type_ = read_u32(bytes, checked_add(value.body, 4)?)?;
            if size == 0 || array_scalar_size(type_) != Some(size) {
                return Err(CodecError::UnsupportedPayload);
            }
            if (value.end - value.body - 8) % size != 0 {
                return Err(CodecError::Malformed("partial Array element"));
            }
            Ok(())
        }
        _ => Err(CodecError::UnsupportedPayload),
    }
}

// Inspection only: never serializes bytes or casts native pointers. This avoids
// length underflow/recursive allocation in the pinned public Value decoder.
fn preflight(bytes: &[u8], record: Record, limit: usize) -> Result<(), CodecError> {
    check_bound(bytes.len(), limit)?;
    let object = span(bytes, 0, bytes.len())?;
    if object.end != bytes.len()
        || object.next != bytes.len()
        || object.type_ != spa::sys::SPA_TYPE_Object
        || object.end - object.body < 16
        || read_u32(bytes, object.body)? != SpaTypes::ObjectParamProps.as_raw()
        || read_u32(bytes, object.body + 4)? != spa::param::ParamType::Props.as_raw()
        || read_u32(bytes, object.body + 8)? != spa::sys::SPA_PROP_params
        || read_u32(bytes, object.body + 12)? != 0
    {
        return Err(CodecError::Malformed(
            "exact Props object/property required",
        ));
    }
    let outer = span(bytes, object.body + 16, object.end)?;
    if outer.next != object.end {
        return Err(CodecError::Malformed("extra Props property"));
    }
    let fields = children::<4>(bytes, outer)?;
    let names = record.names();
    if string_body(bytes, fields[0])? != names.0.as_bytes()
        || string_body(bytes, fields[2])? != names.1.as_bytes()
    {
        return Err(CodecError::Malformed("record names/order"));
    }
    let header = children::<8>(bytes, fields[1])?;
    let last_type = match record {
        Record::Request => spa::sys::SPA_TYPE_Long,
        Record::Reply(_) => spa::sys::SPA_TYPE_Int,
    };
    let types = [
        spa::sys::SPA_TYPE_Int,
        spa::sys::SPA_TYPE_Long,
        spa::sys::SPA_TYPE_Id,
        spa::sys::SPA_TYPE_Long,
        spa::sys::SPA_TYPE_Long,
        spa::sys::SPA_TYPE_Long,
        spa::sys::SPA_TYPE_Id,
        last_type,
    ];
    for (field, type_) in header.iter().zip(types) {
        if field.type_ != type_ || scalar_size(type_) != Some(field.end - field.body) {
            return Err(CodecError::Malformed("fixed header type/width"));
        }
    }
    if fields[3].type_ != spa::sys::SPA_TYPE_Struct {
        return Err(CodecError::Malformed("payload is not Struct"));
    }
    guard_payload(bytes, fields[3], 1)
}

fn array_size(value: &ValueArray) -> Result<usize, CodecError> {
    let (count, width) = match value {
        ValueArray::Bool(v) => (v.len(), 4),
        ValueArray::Id(v) => (v.len(), 4),
        ValueArray::Int(v) => (v.len(), 4),
        ValueArray::Float(v) => (v.len(), 4),
        ValueArray::Long(v) => (v.len(), 8),
        ValueArray::Double(v) => (v.len(), 8),
        _ => return Err(CodecError::UnsupportedPayload),
    };
    let data = count
        .checked_mul(width)
        .ok_or(CodecError::Malformed("Array size overflow"))?;
    checked_add(8, data)
}

fn value_size(value: &Value, depth: usize, limit: usize) -> Result<usize, CodecError> {
    check_bound(8, limit)?;
    let size = match value {
        Value::None => 0,
        Value::Bool(_) | Value::Id(_) | Value::Int(_) | Value::Float(_) => 4,
        Value::Long(_) | Value::Double(_) => 8,
        Value::String(text) => {
            check_bound(pod_size(checked_add(text.len(), 1)?)?, limit)?;
            if text.as_bytes().contains(&0) {
                return Err(CodecError::Malformed("String contains nul"));
            }
            checked_add(text.len(), 1)?
        }
        Value::Bytes(data) => data.len(),
        Value::ValueArray(array) => array_size(array)?,
        Value::Struct(fields) => struct_body_size(fields, depth, limit - 8)?,
        _ => return Err(CodecError::UnsupportedPayload),
    };
    let size = pod_size(size)?;
    check_bound(size, limit)?;
    Ok(size)
}

fn struct_body_size(fields: &[Value], depth: usize, limit: usize) -> Result<usize, CodecError> {
    if depth > MAX_PAYLOAD_DEPTH {
        return Err(CodecError::PayloadDepth);
    }
    fields.iter().try_fold(0, |sum, field| {
        checked_add(sum, value_size(field, depth + 1, limit - sum)?)
    })
}

fn encode(
    record: Record,
    header: NativeStruct,
    payload: &[Value],
    limit: usize,
) -> Result<Vec<u8>, CodecError> {
    let names = record.names();
    // Object header/body, one property, outer Struct header, fixed header Struct.
    let fixed_size = checked_add(
        32 + 136 + 8,
        checked_add(pod_size(names.0.len() + 1)?, pod_size(names.1.len() + 1)?)?,
    )?;
    check_bound(fixed_size, limit)?;
    let size = checked_add(
        fixed_size,
        struct_body_size(payload, 1, limit - fixed_size)?,
    )?;
    check_bound(size, limit)?;
    let value = Value::Object(Object {
        type_: SpaTypes::ObjectParamProps.as_raw(),
        id: spa::param::ParamType::Props.as_raw(),
        properties: vec![Property::new(
            spa::sys::SPA_PROP_params,
            Value::Struct(vec![
                Value::String(names.0.into()),
                Value::Struct(header),
                Value::String(names.1.into()),
                Value::Struct(payload.to_vec()),
            ]),
        )],
    });
    let bytes = PodSerializer::serialize(Cursor::new(Vec::with_capacity(size)), &value)
        .map_err(|_| CodecError::Serialization)?
        .0
        .into_inner();
    preflight(&bytes, record, limit)?;
    Ok(bytes)
}

fn header_values(
    version: i32,
    endpoint: i64,
    controller: ControllerIdentity,
    token: i64,
    operation: u32,
    last: Value,
) -> NativeStruct {
    vec![
        Value::Int(version),
        Value::Long(endpoint),
        Value::Id(Id(controller.global_id)),
        Value::Long(serial_to_long(controller.serial)),
        Value::Long(controller.instance),
        Value::Long(token),
        Value::Id(Id(operation)),
        last,
    ]
}

/// Encode a request within the 16 KiB envelope bound.
///
/// # Errors
/// Rejects invalid headers, unsupported payloads, excessive size/depth or native serialization failure.
pub fn encode_request(header: &RequestHeader, payload: &[Value]) -> Result<Vec<u8>, CodecError> {
    header.validate()?;
    encode(
        Record::Request,
        header_values(
            header.version,
            header.endpoint_instance,
            header.controller,
            header.token,
            header.operation,
            Value::Long(header.budget_ns),
        ),
        payload,
        REQUEST_BOUND,
    )
}

/// Encode a reply with an explicit lifecycle or calibration capacity.
///
/// # Errors
/// Rejects invalid headers, unsupported payloads, excessive size/depth or native serialization failure.
pub fn encode_reply(
    kind: ReplyKind,
    header: &ReplyHeader,
    payload: &[Value],
    bound: ReplyBound,
) -> Result<Vec<u8>, CodecError> {
    header.validate(kind)?;
    encode(
        Record::Reply(kind),
        header_values(
            header.version,
            header.endpoint_instance,
            header.controller,
            header.token,
            header.operation,
            Value::Int(header.result),
        ),
        payload,
        bound.bytes(),
    )
}

fn decode(
    bytes: &[u8],
    record: Record,
    limit: usize,
) -> Result<(NativeStruct, NativeStruct), CodecError> {
    preflight(bytes, record, limit)?;
    let (remaining, value) =
        PodDeserializer::deserialize_any_from(bytes).map_err(|_| CodecError::Deserialization)?;
    if !remaining.is_empty() {
        return Err(CodecError::Malformed("trailing bytes"));
    }
    let Value::Object(object) = value else {
        return Err(CodecError::Deserialization);
    };
    let mut properties = object.properties.into_iter();
    let property = properties.next().ok_or(CodecError::Deserialization)?;
    let Value::Struct(mut fields) = property.value else {
        return Err(CodecError::Deserialization);
    };
    if fields.len() != 4 {
        return Err(CodecError::Deserialization);
    }
    let Value::Struct(header) = fields.remove(1) else {
        return Err(CodecError::Deserialization);
    };
    let Some(Value::Struct(payload)) = fields.pop() else {
        return Err(CodecError::Deserialization);
    };
    Ok((header, payload))
}

fn common_header(fields: &[Value]) -> Result<(i32, i64, ControllerIdentity, i64, u32), CodecError> {
    let [Value::Int(version), Value::Long(endpoint), Value::Id(Id(global_id)), Value::Long(serial), Value::Long(instance), Value::Long(token), Value::Id(Id(operation)), _] =
        fields
    else {
        return Err(CodecError::Deserialization);
    };
    Ok((
        *version,
        *endpoint,
        ControllerIdentity {
            global_id: *global_id,
            serial: serial_from_long(*serial),
            instance: *instance,
        },
        *token,
        *operation,
    ))
}

/// Decode an exact request into owned values after bounded byte preflight.
///
/// # Errors
/// Rejects malformed envelopes, invalid headers, unsupported payloads or excessive size/depth.
pub fn decode_request(bytes: &[u8]) -> Result<Request, CodecError> {
    let (fields, payload) = decode(bytes, Record::Request, REQUEST_BOUND)?;
    let (version, endpoint_instance, controller, token, operation) = common_header(&fields)?;
    let Some(Value::Long(budget_ns)) = fields.last() else {
        return Err(CodecError::Deserialization);
    };
    let header = RequestHeader {
        version,
        endpoint_instance,
        controller,
        token,
        operation,
        budget_ns: *budget_ns,
    };
    header.validate()?;
    Ok(Request { header, payload })
}

/// Decode an exact reply with an explicit lifecycle or calibration capacity.
///
/// # Errors
/// Rejects malformed envelopes, invalid headers, unsupported payloads or excessive size/depth.
pub fn decode_reply(bytes: &[u8], kind: ReplyKind, bound: ReplyBound) -> Result<Reply, CodecError> {
    let (fields, payload) = decode(bytes, Record::Reply(kind), bound.bytes())?;
    let (version, endpoint_instance, controller, token, operation) = common_header(&fields)?;
    let Some(Value::Int(result)) = fields.last() else {
        return Err(CodecError::Deserialization);
    };
    let header = ReplyHeader {
        version,
        endpoint_instance,
        controller,
        token,
        operation,
        result: *result,
    };
    header.validate(kind)?;
    Ok(Reply {
        kind,
        header,
        payload,
    })
}

/// Encode a completion with the default 64 KiB lifecycle bound.
///
/// # Errors
/// Returns the validation and capacity errors described by [`encode_reply`].
pub fn encode_completion(header: &ReplyHeader, payload: &[Value]) -> Result<Vec<u8>, CodecError> {
    encode_reply(
        ReplyKind::Completion,
        header,
        payload,
        ReplyBound::default(),
    )
}

/// Decode a completion with the default 64 KiB lifecycle bound.
///
/// # Errors
/// Returns the envelope and capacity errors described by [`decode_reply`].
pub fn decode_completion(bytes: &[u8]) -> Result<Reply, CodecError> {
    decode_reply(bytes, ReplyKind::Completion, ReplyBound::default())
}

/// Encode a rejection with the default 64 KiB lifecycle bound.
///
/// # Errors
/// Returns the validation and capacity errors described by [`encode_reply`].
pub fn encode_rejection(header: &ReplyHeader, payload: &[Value]) -> Result<Vec<u8>, CodecError> {
    encode_reply(ReplyKind::Rejection, header, payload, ReplyBound::default())
}

/// Decode a rejection with the default 64 KiB lifecycle bound.
///
/// # Errors
/// Returns the envelope and capacity errors described by [`decode_reply`].
pub fn decode_rejection(bytes: &[u8]) -> Result<Reply, CodecError> {
    decode_reply(bytes, ReplyKind::Rejection, ReplyBound::default())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request_header() -> RequestHeader {
        RequestHeader {
            version: VERSION,
            endpoint_instance: 23,
            controller: ControllerIdentity {
                global_id: 42,
                serial: 7,
                instance: 3,
            },
            token: 11,
            operation: 2,
            budget_ns: 5_000_000_000,
        }
    }

    fn reply_header() -> ReplyHeader {
        let request = request_header();
        ReplyHeader {
            version: request.version,
            endpoint_instance: request.endpoint_instance,
            controller: request.controller,
            token: request.token,
            operation: request.operation,
            result: 0,
        }
    }

    fn payload() -> NativeStruct {
        vec![
            Value::Bool(true),
            Value::Int(-3),
            Value::Long(i64::MIN),
            Value::Float(1.25),
            Value::Double(-2.5),
            Value::Id(Id(9)),
            Value::String("manifest.fits".into()),
            Value::Bytes(vec![0, 1, 255]),
            Value::Struct(vec![Value::Long(2)]),
            Value::ValueArray(ValueArray::Float(vec![0.25, 1.5, -4.0])),
        ]
    }

    fn raw_fields(record: Record, header: NativeStruct, payload: Value) -> Vec<u8> {
        let names = record.names();
        let value = Value::Object(Object {
            type_: SpaTypes::ObjectParamProps.as_raw(),
            id: spa::param::ParamType::Props.as_raw(),
            properties: vec![Property::new(
                spa::sys::SPA_PROP_params,
                Value::Struct(vec![
                    Value::String(names.0.into()),
                    Value::Struct(header),
                    Value::String(names.1.into()),
                    payload,
                ]),
            )],
        });
        PodSerializer::serialize(Cursor::new(Vec::new()), &value)
            .unwrap()
            .0
            .into_inner()
    }

    fn raw_request(header: RequestHeader, payload: Value) -> Vec<u8> {
        raw_fields(
            Record::Request,
            header_values(
                header.version,
                header.endpoint_instance,
                header.controller,
                header.token,
                header.operation,
                Value::Long(header.budget_ns),
            ),
            payload,
        )
    }

    fn outer_fields(bytes: &[u8]) -> [Span; 4] {
        let object = span(bytes, 0, bytes.len()).unwrap();
        children(bytes, span(bytes, object.body + 16, object.end).unwrap()).unwrap()
    }

    fn put_u32(bytes: &mut [u8], offset: usize, value: u32) {
        bytes[offset..offset + 4].copy_from_slice(&value.to_ne_bytes());
    }

    #[test]
    fn request_and_reply_owned_roundtrip() {
        let header = request_header();
        let expected = payload();
        let mut bytes = encode_request(&header, &expected).unwrap();
        let request = decode_request(&bytes).unwrap();
        bytes.fill(0);
        assert_eq!(
            request,
            Request {
                header,
                payload: expected
            }
        );
        for kind in [ReplyKind::Completion, ReplyKind::Rejection] {
            let mut header = reply_header();
            header.result = if kind == ReplyKind::Completion {
                0
            } else {
                -22
            };
            let expected = payload();
            let bytes = encode_reply(kind, &header, &expected, ReplyBound::default()).unwrap();
            let reply = decode_reply(&bytes, kind, ReplyBound::default()).unwrap();
            assert_eq!(
                reply,
                Reply {
                    kind,
                    header,
                    payload: expected
                }
            );
            let other = if kind == ReplyKind::Completion {
                ReplyKind::Rejection
            } else {
                ReplyKind::Completion
            };
            assert!(decode_reply(&bytes, other, ReplyBound::default()).is_err());
        }
    }

    #[test]
    fn all_six_scalar_array_kinds_roundtrip_with_empty_arrays() {
        let arrays = vec![
            ValueArray::Bool(vec![false, true]),
            ValueArray::Id(vec![Id(0), Id(u32::MAX)]),
            ValueArray::Int(vec![i32::MIN, i32::MAX]),
            ValueArray::Long(vec![i64::MIN, i64::MAX]),
            ValueArray::Float(vec![-1.5, 2.25]),
            ValueArray::Double(vec![-1.5, 2.25]),
            ValueArray::Bool(vec![]),
            ValueArray::Id(vec![]),
            ValueArray::Int(vec![]),
            ValueArray::Long(vec![]),
            ValueArray::Float(vec![]),
            ValueArray::Double(vec![]),
        ];
        let payload: NativeStruct = arrays.into_iter().map(Value::ValueArray).collect();
        let bytes = encode_request(&request_header(), &payload).unwrap();
        assert_eq!(decode_request(&bytes).unwrap().payload, payload);
        assert_eq!(
            encode_request(
                &request_header(),
                &[Value::ValueArray(ValueArray::None(vec![]))]
            ),
            Err(CodecError::UnsupportedPayload)
        );
    }

    #[test]
    fn serial_bit_patterns_and_required_positive_identity() {
        for serial in [0, (1_u64 << 63) - 1, 1_u64 << 63, u64::MAX] {
            assert_eq!(serial_from_long(serial_to_long(serial)), serial);
            let mut header = request_header();
            header.controller.serial = serial;
            if serial == 0 {
                assert_eq!(encode_request(&header, &[]), Err(CodecError::InvalidHeader));
                assert_eq!(
                    decode_request(&raw_request(header, Value::Struct(vec![]))),
                    Err(CodecError::InvalidHeader)
                );
            } else {
                let bytes = encode_request(&header, &[]).unwrap();
                assert_eq!(
                    decode_request(&bytes).unwrap().header.controller.serial,
                    serial
                );
            }
        }
        assert_eq!(serial_to_long(1_u64 << 63), i64::MIN);
        assert_eq!(serial_to_long(u64::MAX), -1);
        let original = request_header();
        let mut bad = Vec::new();
        let mut header = original;
        header.version = 0;
        bad.push(header);
        let mut header = original;
        header.version = 2;
        bad.push(header);
        let mut header = original;
        header.endpoint_instance = 0;
        bad.push(header);
        let mut header = original;
        header.endpoint_instance = -1;
        bad.push(header);
        let mut header = original;
        header.controller.global_id = 0;
        bad.push(header);
        let mut header = original;
        header.controller.global_id = u32::MAX;
        bad.push(header);
        let mut header = original;
        header.controller.instance = 0;
        bad.push(header);
        let mut header = original;
        header.controller.instance = -1;
        bad.push(header);
        let mut header = original;
        header.token = 0;
        bad.push(header);
        let mut header = original;
        header.token = -1;
        bad.push(header);
        let mut header = original;
        header.operation = 0;
        bad.push(header);
        let mut header = original;
        header.budget_ns = 0;
        bad.push(header);
        let mut header = original;
        header.budget_ns = -1;
        bad.push(header);
        for header in bad {
            assert_eq!(encode_request(&header, &[]), Err(CodecError::InvalidHeader));
            assert_eq!(
                decode_request(&raw_request(header, Value::Struct(vec![]))),
                Err(CodecError::InvalidHeader)
            );
        }
    }

    #[test]
    fn completion_and_rejection_sentinels_are_exact() {
        let initial = ReplyHeader {
            controller: ControllerIdentity {
                global_id: 0,
                serial: 0,
                instance: 0,
            },
            token: 0,
            operation: 0,
            ..reply_header()
        };
        assert_eq!(
            decode_completion(&encode_completion(&initial, &[]).unwrap())
                .unwrap()
                .header,
            initial
        );
        assert!(encode_rejection(&initial, &[]).is_err());
        let uncorrelated = ReplyHeader {
            result: -22,
            ..initial
        };
        assert_eq!(
            decode_rejection(&encode_rejection(&uncorrelated, &[]).unwrap())
                .unwrap()
                .header,
            uncorrelated
        );
        assert!(encode_completion(&uncorrelated, &[]).is_err());
        let mut partial = Vec::new();
        let mut header = initial;
        header.controller.global_id = 42;
        partial.push(header);
        let mut header = initial;
        header.controller.serial = 7;
        partial.push(header);
        let mut header = initial;
        header.controller.instance = 3;
        partial.push(header);
        let mut header = initial;
        header.token = 11;
        partial.push(header);
        let mut header = initial;
        header.operation = 2;
        partial.push(header);
        for mut header in partial {
            assert!(encode_completion(&header, &[]).is_err());
            let raw = raw_fields(
                Record::Reply(ReplyKind::Completion),
                header_values(
                    header.version,
                    header.endpoint_instance,
                    header.controller,
                    header.token,
                    header.operation,
                    Value::Int(header.result),
                ),
                Value::Struct(vec![]),
            );
            assert!(decode_completion(&raw).is_err());
            header.result = -22;
            assert!(encode_rejection(&header, &[]).is_err());
            let raw = raw_fields(
                Record::Reply(ReplyKind::Rejection),
                header_values(
                    header.version,
                    header.endpoint_instance,
                    header.controller,
                    header.token,
                    header.operation,
                    Value::Int(header.result),
                ),
                Value::Struct(vec![]),
            );
            assert!(decode_rejection(&raw).is_err());
        }
        let mut header = reply_header();
        header.result = -1;
        assert!(encode_completion(&header, &[]).is_ok());
        header.result = 1;
        assert!(encode_completion(&header, &[]).is_err());
        assert!(encode_rejection(&header, &[]).is_err());
    }

    #[test]
    fn bounds_include_the_entire_pod_and_require_explicit_calibration() {
        let header = request_header();
        let empty_size = encode_request(&header, &[]).unwrap().len();
        let count = REQUEST_BOUND - empty_size - 8;
        let full = encode_request(&header, &[Value::Bytes(vec![0; count])]).unwrap();
        assert_eq!(full.len(), REQUEST_BOUND);
        assert!(decode_request(&full).is_ok());
        assert!(matches!(
            encode_request(&header, &[Value::Bytes(vec![0; count + 1])]),
            Err(CodecError::Oversize { .. })
        ));
        assert!(matches!(
            encode_request(
                &header,
                &[Value::ValueArray(ValueArray::Float(vec![
                    0.0;
                    REQUEST_BOUND
                ]))]
            ),
            Err(CodecError::Oversize { .. })
        ));
        assert!(matches!(
            encode_request(&header, &vec![Value::None; REQUEST_BOUND]),
            Err(CodecError::Oversize { .. })
        ));
        let large = vec![Value::Bytes(vec![0; 70_000])];
        assert!(matches!(
            encode_completion(&reply_header(), &large),
            Err(CodecError::Oversize { .. })
        ));
        let bytes = encode_reply(
            ReplyKind::Completion,
            &reply_header(),
            &large,
            ReplyBound::Calibration,
        )
        .unwrap();
        assert!(matches!(
            decode_completion(&bytes),
            Err(CodecError::Oversize {
                limit: LIFECYCLE_REPLY_BOUND,
                ..
            })
        ));
        assert_eq!(
            decode_reply(&bytes, ReplyKind::Completion, ReplyBound::Calibration)
                .unwrap()
                .payload,
            large
        );
        assert!(matches!(
            decode_request(&vec![0; REQUEST_BOUND + 1]),
            Err(CodecError::Oversize {
                limit: REQUEST_BOUND,
                ..
            })
        ));
        assert!(matches!(
            decode_reply(
                &vec![0; CALIBRATION_REPLY_BOUND + 1],
                ReplyKind::Completion,
                ReplyBound::Calibration
            ),
            Err(CodecError::Oversize { .. })
        ));
    }

    #[test]
    fn malformed_lengths_truncation_flags_names_and_scalar_widths() {
        let valid = encode_request(&request_header(), &[Value::Int(4)]).unwrap();
        for end in 0..valid.len() {
            assert!(
                decode_request(&valid[..end]).is_err(),
                "accepted truncation {end}"
            );
        }
        let fields = outer_fields(&valid);
        let header = children::<8>(&valid, fields[1]).unwrap();
        for (offset, value) in [
            (0, 0),
            (0, u32::MAX),
            (4, spa::sys::SPA_TYPE_Struct),
            (8, SpaTypes::ObjectParamFormat.as_raw()),
            (12, spa::param::ParamType::Format.as_raw()),
            (16, 0),
            (20, 1),
            (20, 0x8000_0000),
            (fields[0].body - 8, 0),
            (fields[0].body - 4, spa::sys::SPA_TYPE_Bytes),
            (header[0].body - 8, 8),
            (header[1].body - 8, 4),
            (header[2].body - 4, spa::sys::SPA_TYPE_Int),
            (header[7].body - 4, spa::sys::SPA_TYPE_Int),
            (fields[3].body - 8, 8),
            (fields[3].body - 4, spa::sys::SPA_TYPE_Object),
        ] {
            let mut bytes = valid.clone();
            put_u32(&mut bytes, offset, value);
            assert!(
                decode_request(&bytes).is_err(),
                "accepted metadata mutation at {offset}"
            );
        }
        let mut bytes = valid.clone();
        bytes[fields[0].body] = b'x';
        assert!(decode_request(&bytes).is_err());
        let mut bytes = valid.clone();
        bytes[fields[0].end - 1] = b'x';
        assert!(decode_request(&bytes).is_err());
        for extra in [1, 7, 8, 16] {
            let mut bytes = valid.clone();
            bytes.resize(bytes.len() + extra, 0);
            assert!(decode_request(&bytes).is_err());
        }
        let mut bytes = valid.clone();
        let outer = span(&valid, 24, valid.len()).unwrap();
        put_u32(&mut bytes, outer.body - 8, 4);
        assert!(decode_request(&bytes).is_err());
    }

    #[test]
    fn exact_header_arity_order_and_payload_container() {
        let header = request_header();
        let fields = header_values(
            header.version,
            header.endpoint_instance,
            header.controller,
            header.token,
            header.operation,
            Value::Long(header.budget_ns),
        );
        for altered in [
            fields[..7].to_vec(),
            [fields.clone(), vec![Value::Int(0)]].concat(),
        ] {
            assert!(
                decode_request(&raw_fields(Record::Request, altered, Value::Struct(vec![])))
                    .is_err()
            );
        }
        let mut altered = fields.clone();
        altered.swap(0, 1);
        assert!(
            decode_request(&raw_fields(Record::Request, altered, Value::Struct(vec![]))).is_err()
        );
        for payload in [Value::Bool(false), Value::Bytes(vec![])] {
            assert!(decode_request(&raw_fields(Record::Request, fields.clone(), payload)).is_err());
        }
        let valid = raw_fields(Record::Request, fields, Value::Struct(vec![]));
        let Value::Object(mut object) = PodDeserializer::deserialize_any_from(&valid).unwrap().1
        else {
            panic!("object")
        };
        object.properties.push(object.properties[0].clone());
        let bytes = PodSerializer::serialize(Cursor::new(Vec::new()), &Value::Object(object))
            .unwrap()
            .0
            .into_inner();
        assert!(decode_request(&bytes).is_err());
    }

    #[test]
    fn outer_children_and_reply_result_types_are_exact() {
        let valid = encode_request(&request_header(), &[]).unwrap();
        let Value::Object(object) = PodDeserializer::deserialize_any_from(&valid).unwrap().1 else {
            panic!("object");
        };
        let Value::Struct(fields) = &object.properties[0].value else {
            panic!("Struct");
        };
        let mut extra = fields.clone();
        extra.push(Value::Int(0));
        let mut reordered = fields.clone();
        reordered.swap(0, 2);
        let mut renamed = fields.clone();
        renamed[2] = Value::String(REQUEST_HEADER.into());
        for altered in [fields[..3].to_vec(), extra, reordered, renamed] {
            let mut altered_object = object.clone();
            altered_object.properties[0].value = Value::Struct(altered);
            let bytes =
                PodSerializer::serialize(Cursor::new(Vec::new()), &Value::Object(altered_object))
                    .unwrap()
                    .0
                    .into_inner();
            assert!(decode_request(&bytes).is_err());
        }
        let valid = encode_completion(&reply_header(), &[]).unwrap();
        let header = children::<8>(&valid, outer_fields(&valid)[1]).unwrap();
        for (offset, value) in [
            (header[7].body - 8, 8),
            (header[7].body - 4, spa::sys::SPA_TYPE_Long),
        ] {
            let mut bytes = valid.clone();
            put_u32(&mut bytes, offset, value);
            assert!(decode_completion(&bytes).is_err());
        }
    }

    #[test]
    fn payload_depth_is_checked_before_recursive_decode_or_encode() {
        let mut payload = vec![Value::Int(4)];
        for _ in 1..MAX_PAYLOAD_DEPTH {
            payload = vec![Value::Struct(payload)];
        }
        let bytes = encode_request(&request_header(), &payload).unwrap();
        assert_eq!(decode_request(&bytes).unwrap().payload, payload);
        payload = vec![Value::Struct(payload)];
        assert_eq!(
            encode_request(&request_header(), &payload),
            Err(CodecError::PayloadDepth)
        );
        let bytes = raw_request(request_header(), Value::Struct(payload));
        assert_eq!(decode_request(&bytes), Err(CodecError::PayloadDepth));
        let payload = vec![Value::Object(Object {
            type_: 0,
            id: 0,
            properties: vec![],
        })];
        assert_eq!(
            encode_request(&request_header(), &payload),
            Err(CodecError::UnsupportedPayload)
        );
        assert_eq!(
            decode_request(&raw_request(request_header(), Value::Struct(payload))),
            Err(CodecError::UnsupportedPayload)
        );
    }

    #[test]
    fn payload_array_and_string_preflight_prevents_decoder_panics() {
        let valid = encode_request(
            &request_header(),
            &[Value::ValueArray(ValueArray::Float(vec![1.0]))],
        )
        .unwrap();
        let payload = outer_fields(&valid)[3];
        let array = span(&valid, payload.body, payload.end).unwrap();
        for (offset, value) in [
            (array.body - 8, 4),
            (array.body, 0),
            (array.body, 8),
            (array.body + 4, spa::sys::SPA_TYPE_None),
            (array.body + 4, spa::sys::SPA_TYPE_Fd),
            (array.body + 4, spa::sys::SPA_TYPE_Rectangle),
            (array.body + 4, spa::sys::SPA_TYPE_Struct),
            (array.body - 4, spa::sys::SPA_TYPE_Pointer),
        ] {
            let mut bytes = valid.clone();
            put_u32(&mut bytes, offset, value);
            assert!(decode_request(&bytes).is_err());
        }
        let mut bytes = valid.clone();
        put_u32(&mut bytes, array.body - 8, 11);
        assert!(decode_request(&bytes).is_err());
        assert!(encode_request(&request_header(), &[Value::String("a\0b".into())]).is_err());
        let valid = encode_request(&request_header(), &[Value::String("abc".into())]).unwrap();
        let payload = outer_fields(&valid)[3];
        let text = span(&valid, payload.body, payload.end).unwrap();
        for bad in [0, 255] {
            let mut bytes = valid.clone();
            bytes[text.body + 1] = bad;
            assert!(decode_request(&bytes).is_err());
        }
    }
}
