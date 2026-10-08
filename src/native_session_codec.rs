//! Direct `WirePlumber` session profile using the established typed command grammar.
//!
//! The profile name is distinct from the internal runner. The v1 operation IDs,
//! request payloads, lifecycle IDs, outcomes, completion and rejection grammar
//! are reused without a supervisor snapshot wrapper.

pub const PROFILE: &str = "pipewireao.rtc.session/1";
pub const SESSION_UUID_PROPERTY: &str = "pipewireao.rtc.session.session-uuid";

pub use crate::control_dto::LifecycleState as Lifecycle;
pub use crate::control_dto::Operation;
pub use crate::native_runner_codec::{decode_request, encode_request};
pub use crate::native_runner_result::{decode_completion, decode_rejection, Completion, Rejection};

use crate::control::ControlError;
use crate::native_control_codec::{self as envelope, ReplyBound, ReplyHeader, ReplyKind};
use pipewire::spa::pod::Value;
use pipewire::spa::utils::Id;

/// Retained completion for private one-shot preparation and admission commands.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AdministrativeCompletion {
    pub header: ReplyHeader,
    pub lifecycle: Lifecycle,
    pub warmed: Option<bool>,
    pub error: Option<ControlError>,
}

fn administrative_lifecycle(id: u32) -> Result<Lifecycle, String> {
    match id {
        1 => Ok(Lifecycle::Offline),
        2 => Ok(Lifecycle::Configuring),
        3 => Ok(Lifecycle::Ready),
        4 => Ok(Lifecycle::Running),
        5 => Ok(Lifecycle::Fault),
        _ => Err("unknown administrative lifecycle Id".into()),
    }
}

/// Decode exact retained operation 15/16 responses without extending runner IDs.
///
/// # Errors
/// Rejects malformed envelopes, correlation fields, lifecycle values, and operation payloads.
pub fn decode_administrative_completion(bytes: &[u8]) -> Result<AdministrativeCompletion, String> {
    let reply = envelope::decode_reply(bytes, ReplyKind::Completion, ReplyBound::Lifecycle)
        .map_err(|e| e.to_string())?;
    let header = reply.header;
    if header.token <= 0 || !matches!(header.operation, 15 | 16) {
        return Err("invalid administrative completion identity".into());
    }
    match header.result.cmp(&0) {
        std::cmp::Ordering::Equal => {
            let [Value::Id(Id(state)), Value::Bool(warmed)] = reply.payload.as_slice() else {
                return Err("administrative completion needs lifecycle Id and warmed Bool".into());
            };
            let lifecycle = administrative_lifecycle(*state)?;
            if header.operation == 16 && (lifecycle != Lifecycle::Ready || !warmed) {
                return Err("admission completion must prove warmed Ready".into());
            }
            if header.operation == 15 && lifecycle != Lifecycle::Configuring {
                return Err("warmup completion must retain Configuring".into());
            }
            Ok(AdministrativeCompletion {
                header,
                lifecycle,
                warmed: Some(*warmed),
                error: None,
            })
        }
        std::cmp::Ordering::Less => {
            let [Value::String(field), Value::String(message), Value::Id(Id(state))] =
                reply.payload.as_slice()
            else {
                return Err("failed administrative completion needs exact error grammar".into());
            };
            if field.contains('\0') || message.contains('\0') {
                return Err("administrative error strings must contain no NUL".into());
            }
            Ok(AdministrativeCompletion {
                header,
                lifecycle: administrative_lifecycle(*state)?,
                warmed: None,
                error: Some(ControlError::new(field.clone(), message.clone())),
            })
        }
        std::cmp::Ordering::Greater => Err("invalid administrative completion result".into()),
    }
}
