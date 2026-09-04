use pipewire as pw;
use pw::spa::param::ParamType;
use pw::spa::pod::deserialize::PodDeserializer;
use pw::spa::pod::serialize::PodSerializer;
use pw::spa::pod::{Object, Pod, Property, Value};
use pw::spa::utils::SpaTypes;
use std::io::Cursor;

const VERSION: i32 = 1;
const VERSION_KEY: &str = "pipewireao.run-control.version";
const REQUEST_TOKEN_KEY: &str = "pipewireao.run-control.request-token";
const REQUESTED_STATE_KEY: &str = "pipewireao.run-control.requested-state";
const COMPLETED_TOKEN_KEY: &str = "pipewireao.run-control.completed-token";
const RESULT_KEY: &str = "pipewireao.run-control.result";
const ACTUAL_STATE_KEY: &str = "pipewireao.run-control.actual-state";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum RunState {
    Unknown,
    Stopped,
    Running,
}

impl RunState {
    fn wire_name(self) -> &'static str {
        match self {
            Self::Unknown => "unknown",
            Self::Stopped => "stopped",
            Self::Running => "running",
        }
    }

    fn parse(value: &str) -> Result<Self, String> {
        match value {
            "unknown" => Ok(Self::Unknown),
            "stopped" => Ok(Self::Stopped),
            "running" => Ok(Self::Running),
            _ => Err(format!(
                "actual-state {value:?} is not defined by Version 1"
            )),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct RunControlStatus {
    pub(crate) completed_token: i64,
    pub(crate) result: i32,
    pub(crate) actual_state: RunState,
}

pub(crate) fn build_request(token: i64, state: RunState) -> Result<Vec<u8>, String> {
    if token <= 0 {
        return Err(format!("request-token must be positive, got {token}"));
    }
    if state == RunState::Unknown {
        return Err("requested-state must be stopped or running".to_owned());
    }
    encode(&Value::Object(Object {
        type_: SpaTypes::ObjectParamProps.as_raw(),
        id: ParamType::Props.as_raw(),
        properties: vec![Property::new(
            pw::spa::sys::SPA_PROP_params,
            Value::Struct(vec![
                Value::String(VERSION_KEY.to_owned()),
                Value::Int(VERSION),
                Value::String(REQUEST_TOKEN_KEY.to_owned()),
                Value::Long(token),
                Value::String(REQUESTED_STATE_KEY.to_owned()),
                Value::String(state.wire_name().to_owned()),
            ]),
        )],
    }))
}

fn encode(value: &Value) -> Result<Vec<u8>, String> {
    PodSerializer::serialize(Cursor::new(Vec::new()), value)
        .map(|result| result.0.into_inner())
        .map_err(|error| format!("cannot encode SPA_PARAM_Props: {error:?}"))
}

pub(crate) fn parse_status(pod: &Pod) -> Result<Option<RunControlStatus>, String> {
    let (_, value) = PodDeserializer::deserialize_from::<Value>(pod.as_bytes())
        .map_err(|error| format!("cannot decode SPA_PARAM_Props: {error:?}"))?;
    let Value::Object(object) = value else {
        return Err("Props is not an object".to_owned());
    };
    if object.type_ != SpaTypes::ObjectParamProps.as_raw() || object.id != ParamType::Props.as_raw()
    {
        return Err("Props has the wrong object type or parameter id".to_owned());
    }
    let mut parameters = object
        .properties
        .into_iter()
        .filter(|property| property.key == pw::spa::sys::SPA_PROP_params);
    let Some(property) = parameters.next() else {
        return Ok(None);
    };
    if parameters.next().is_some() {
        return Err("Props declares params more than once".to_owned());
    }
    let Value::Struct(fields) = property.value else {
        return Err("Props params is not a Struct".to_owned());
    };
    let mentions_run_control = fields.iter().step_by(2).any(
        |field| matches!(field, Value::String(key) if key.starts_with("pipewireao.run-control.")),
    );
    if !mentions_run_control {
        return Ok(None);
    }
    if fields.len() != 8 {
        return Err(format!(
            "status must contain four key/value pairs, observed {} fields",
            fields.len()
        ));
    }
    let version = pair_int(&fields, 0, VERSION_KEY)?;
    if version != VERSION {
        return Err(format!("version {version} is unsupported"));
    }
    let completed_token = pair_long(&fields, 2, COMPLETED_TOKEN_KEY)?;
    if completed_token < 0 {
        return Err(format!(
            "completed-token must be nonnegative, got {completed_token}"
        ));
    }
    let result = pair_int(&fields, 4, RESULT_KEY)?;
    let actual_state = RunState::parse(pair_string(&fields, 6, ACTUAL_STATE_KEY)?)?;
    Ok(Some(RunControlStatus {
        completed_token,
        result,
        actual_state,
    }))
}

fn pair_int(fields: &[Value], index: usize, expected: &str) -> Result<i32, String> {
    match (fields.get(index), fields.get(index + 1)) {
        (Some(Value::String(key)), Some(Value::Int(value))) if key == expected => Ok(*value),
        _ => Err(format!("{expected} is missing, duplicated, or not an Int")),
    }
}

fn pair_long(fields: &[Value], index: usize, expected: &str) -> Result<i64, String> {
    match (fields.get(index), fields.get(index + 1)) {
        (Some(Value::String(key)), Some(Value::Long(value))) if key == expected => Ok(*value),
        _ => Err(format!("{expected} is missing, duplicated, or not a Long")),
    }
}

fn pair_string<'a>(fields: &'a [Value], index: usize, expected: &str) -> Result<&'a str, String> {
    match (fields.get(index), fields.get(index + 1)) {
        (Some(Value::String(key)), Some(Value::String(value))) if key == expected => Ok(value),
        _ => Err(format!(
            "{expected} is missing, duplicated, or not a String"
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_uses_the_versioned_props_contract() {
        let bytes = build_request(23, RunState::Running).expect("request");
        let pod = Pod::from_bytes(&bytes).expect("request POD");
        let (_, value) =
            PodDeserializer::deserialize_from::<Value>(pod.as_bytes()).expect("decode request");
        let Value::Object(object) = value else {
            panic!("request is not an object");
        };
        assert_eq!(object.type_, SpaTypes::ObjectParamProps.as_raw());
        assert_eq!(object.id, ParamType::Props.as_raw());
        assert!(build_request(0, RunState::Stopped).is_err());
        assert!(build_request(1, RunState::Unknown).is_err());
    }

    #[test]
    fn status_validation_distinguishes_scientific_props_and_protocol_errors() {
        let status = status_pod(VERSION, 23, 0, "stopped");
        assert_eq!(
            parse_status(Pod::from_bytes(&status).expect("status POD")),
            Ok(Some(RunControlStatus {
                completed_token: 23,
                result: 0,
                actual_state: RunState::Stopped,
            }))
        );

        let scientific = encode(&Value::Object(Object {
            type_: SpaTypes::ObjectParamProps.as_raw(),
            id: ParamType::Props.as_raw(),
            properties: vec![Property::new(
                pw::spa::sys::SPA_PROP_params,
                Value::Struct(vec![Value::String("gain".to_owned()), Value::Float(0.5)]),
            )],
        }))
        .expect("scientific Props");
        assert_eq!(
            parse_status(Pod::from_bytes(&scientific).expect("scientific POD")),
            Ok(None)
        );

        let wrong_version = status_pod(2, 23, 0, "stopped");
        assert!(
            parse_status(Pod::from_bytes(&wrong_version).expect("status POD"))
                .expect_err("unsupported version")
                .contains("unsupported")
        );
        let negative_token = status_pod(VERSION, -1, 0, "stopped");
        assert!(
            parse_status(Pod::from_bytes(&negative_token).expect("status POD"))
                .expect_err("negative token")
                .contains("nonnegative")
        );
        let wrong_state = status_pod(VERSION, 23, 0, "paused");
        assert!(
            parse_status(Pod::from_bytes(&wrong_state).expect("status POD"))
                .expect_err("unknown state")
                .contains("not defined")
        );
    }

    fn status_pod(version: i32, token: i64, result: i32, state: &str) -> Vec<u8> {
        encode(&Value::Object(Object {
            type_: SpaTypes::ObjectParamProps.as_raw(),
            id: ParamType::Props.as_raw(),
            properties: vec![Property::new(
                pw::spa::sys::SPA_PROP_params,
                Value::Struct(vec![
                    Value::String(VERSION_KEY.to_owned()),
                    Value::Int(version),
                    Value::String(COMPLETED_TOKEN_KEY.to_owned()),
                    Value::Long(token),
                    Value::String(RESULT_KEY.to_owned()),
                    Value::Int(result),
                    Value::String(ACTUAL_STATE_KEY.to_owned()),
                    Value::String(state.to_owned()),
                ]),
            )],
        }))
        .expect("status")
    }
}
