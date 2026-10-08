use crate::{
    ExecutionGroupState, LifecycleState, LiveGraphStatus, NdArrayParameterValue,
    ParameterGeneration, PropertyGeneration, ScalarValue,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::fs::{self, File, Metadata, OpenOptions};
use std::io::Read;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;

pub const MAX_REQUEST_BYTES: usize = 16 * 1024;
pub const MAX_ARGUMENTS: usize = 128;
pub const MAX_PARAMETER_BYTES: u64 = 512 * 1024 * 1024;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Command {
    Quit,
    Groups,
    Status,
    Properties(String),
    PropertyGeneration(String, String),
    ParameterGeneration(String, String),
    StopGroup(String),
    StartGroup(String),
    SessionStop,
    SessionStart,
    SourceEnded,
    Reset,
    PropertiesSet(String, BTreeMap<String, ScalarValue>),
    Parameter {
        graph: String,
        parameter: String,
        element_type: String,
        shape: Vec<u32>,
        schema: String,
        path: PathBuf,
    },
    PreparedParameter {
        graph: String,
        parameter: String,
        value: NdArrayParameterValue,
    },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ControlError {
    pub field: String,
    pub message: String,
}

impl ControlError {
    #[must_use]
    pub fn new(field: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            field: field.into(),
            message: message.into(),
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct ControlResponse {
    pub version: u8,
    pub id: Option<String>,
    pub session_id: Option<String>,
    pub state: Option<String>,
    pub result: Option<Value>,
    pub ok: bool,
    pub error: Option<ControlErrorResponse>,
}

#[derive(Clone, Debug, Serialize, Deserialize, Eq, PartialEq)]
pub struct ControlErrorResponse {
    pub field: String,
    pub message: String,
}

pub struct Execution {
    pub result: ExecutionResult,
    pub shutdown: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Outcome {
    Accepted,
    Observed,
    Requested,
    Completed,
    Active,
    Submitted,
}

impl Outcome {
    const fn legacy_name(self) -> &'static str {
        match self {
            Self::Accepted => "accepted",
            Self::Observed => "observed",
            Self::Requested => "requested",
            Self::Completed => "completed",
            Self::Active => "active",
            Self::Submitted => "submitted",
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PropertyGenerationObservation {
    pub node: String,
    pub generation: Option<PropertyGeneration>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ExecutionResult {
    Quit,
    Groups {
        groups: BTreeMap<String, ExecutionGroupState>,
    },
    Status {
        lifecycle_state: LifecycleState,
        status: LiveGraphStatus,
    },
    Properties {
        graph: String,
        properties: BTreeMap<String, ScalarValue>,
    },
    PropertyGeneration {
        graph: String,
        node: String,
        generation: PropertyGeneration,
    },
    ParameterGeneration {
        graph: String,
        node: String,
        generation: ParameterGeneration,
    },
    GroupState {
        group: String,
        requested: ExecutionGroupState,
        observed: Option<ExecutionGroupState>,
    },
    SessionStop {
        state: LifecycleState,
    },
    SessionStart {
        state: LifecycleState,
    },
    SourceEnded {
        state: LifecycleState,
    },
    Reset {
        state: LifecycleState,
    },
    PropertiesSet {
        graph: String,
        generations: Vec<PropertyGenerationObservation>,
        active_adoption_observed: bool,
    },
    Parameter {
        graph: String,
        parameter: String,
        generation: Option<ParameterGeneration>,
    },
}

impl ExecutionResult {
    #[must_use]
    pub const fn outcome(&self) -> Outcome {
        match self {
            Self::Quit => Outcome::Accepted,
            Self::Groups { .. }
            | Self::Status { .. }
            | Self::Properties { .. }
            | Self::PropertyGeneration { .. }
            | Self::ParameterGeneration { .. } => Outcome::Observed,
            Self::GroupState { .. } => Outcome::Requested,
            Self::SessionStop { .. }
            | Self::SessionStart { .. }
            | Self::SourceEnded { .. }
            | Self::Reset { .. } => Outcome::Completed,
            Self::PropertiesSet {
                active_adoption_observed: true,
                ..
            } => Outcome::Active,
            Self::PropertiesSet {
                active_adoption_observed: false,
                ..
            }
            | Self::Parameter { .. } => Outcome::Submitted,
        }
    }

    /// Renders the existing console/socket result after typed owner execution.
    #[must_use]
    pub fn legacy_json(&self) -> Value {
        let outcome = self.outcome().legacy_name();
        match self {
            Self::Quit => json!({
                "outcome":outcome,"message":"shutdown requested","shutdown":true,
            }),
            Self::Groups { groups } => json!({
                "outcome":outcome,
                "groups":groups.iter().map(|(name,state)| (name,group_state(*state))).collect::<BTreeMap<_,_>>(),
            }),
            Self::Status {
                lifecycle_state,
                status,
            } => json!({
                "outcome":outcome,"lifecycle_state":state_name(*lifecycle_state),
                "running":status.running,"owned_nodes":status.owned_nodes,
                "owned_links":status.owned_links,"discarded_buffers":status.discarded_buffers,
                "discarded_by_sink":status.discarded_by_sink,
            }),
            Self::Properties { graph, properties } => json!({
                "outcome":outcome,"graph":graph,
                "properties":properties.iter().map(|(name,value)| (name,scalar_json(value))).collect::<BTreeMap<_,_>>(),
            }),
            Self::PropertyGeneration {
                graph,
                node,
                generation,
            } => json!({
                "outcome":outcome,"graph":graph,"node":node,
                "requested":generation.requested,"active":generation.active,
            }),
            Self::ParameterGeneration {
                graph,
                node,
                generation,
            } => json!({
                "outcome":outcome,"graph":graph,"node":node,
                "requested":generation.requested,"active":generation.active,
            }),
            Self::GroupState {
                group,
                requested,
                observed,
            } => json!({
                "outcome":outcome,"group":group,"requested":group_state(*requested),
                "observed":observed.map(group_state),
            }),
            Self::SessionStop { state } | Self::SessionStart { state } => json!({
                "outcome":outcome,"session_state":state_name(*state).to_ascii_uppercase(),
            }),
            Self::SourceEnded { state } | Self::Reset { state } => json!({
                "outcome":outcome,"session_state":state_name(*state),
            }),
            Self::PropertiesSet {
                graph,
                generations,
                active_adoption_observed,
            } => json!({
                "outcome":outcome,"graph":graph,"active_adoption_observed":active_adoption_observed,
                "property_generations":generations.iter().map(|observation| json!({
                    "node":observation.node,
                    "requested":observation.generation.map(|generation| generation.requested),
                    "active":observation.generation.and_then(|generation| generation.active),
                })).collect::<Vec<_>>(),
            }),
            Self::Parameter {
                graph,
                parameter,
                generation,
            } => json!({
                "outcome":outcome,"graph":graph,"parameter":parameter,
                "active_adoption_observed":false,
                "parameter_generations":generation.map(|generation| json!({
                    "requested":generation.requested,"active":generation.active,
                })),
            }),
        }
    }
}

/// Parses the existing operator syntax into one typed command.
/// # Errors
/// Rejects unknown syntax, invalid scalar values, shapes or request bounds.
pub fn parse(arguments: &[String]) -> Result<Command, ControlError> {
    if arguments.len() > MAX_ARGUMENTS {
        return Err(ControlError::new(
            "command.arguments",
            format!("at most {MAX_ARGUMENTS} command fields are allowed"),
        ));
    }
    let fields = arguments.iter().map(String::as_str).collect::<Vec<_>>();
    match fields.as_slice() {
        ["quit" | "exit"] => Ok(Command::Quit),
        ["groups"] => Ok(Command::Groups),
        ["status"] => Ok(Command::Status),
        ["properties", graph] => Ok(Command::Properties((*graph).to_owned())),
        ["property-generation", graph, node] => Ok(Command::PropertyGeneration(
            (*graph).to_owned(),
            (*node).to_owned(),
        )),
        ["parameter-generation", graph, node] => Ok(Command::ParameterGeneration(
            (*graph).to_owned(),
            (*node).to_owned(),
        )),
        ["stop", name] => Ok(Command::StopGroup((*name).to_owned())),
        ["start", name] => Ok(Command::StartGroup((*name).to_owned())),
        ["session-stop"] => Ok(Command::SessionStop),
        ["session-start"] => Ok(Command::SessionStart),
        ["source-ended"] => Ok(Command::SourceEnded),
        ["reset"] => Ok(Command::Reset),
        ["property", graph, qualified, value_type, value] => {
            let mut properties = BTreeMap::new();
            properties.insert(
                (*qualified).to_owned(),
                parse_scalar(value_type, value)?,
            );
            Ok(Command::PropertiesSet((*graph).to_owned(), properties))
        }
        ["properties-set", graph, values @ ..]
            if !values.is_empty() && values.len() % 3 == 0 =>
        {
            let mut properties = BTreeMap::new();
            for triple in values.chunks_exact(3) {
                if properties
                    .insert(
                        triple[0].to_owned(),
                        parse_scalar(triple[1], triple[2])?,
                    )
                    .is_some()
                {
                    return Err(ControlError::new(
                        "command.properties-set",
                        format!("duplicate property {:?}", triple[0]),
                    ));
                }
            }
            Ok(Command::PropertiesSet((*graph).to_owned(), properties))
        }
        ["parameter", graph, parameter, element_type, dimensions, schema, path] => {
            let shape = parse_dimensions(dimensions)?;
            let expected = expected_parameter_bytes(element_type, &shape)?;
            if expected > MAX_PARAMETER_BYTES {
                return Err(ControlError::new(
                    "command.parameter.payload",
                    format!("declared parameter exceeds {MAX_PARAMETER_BYTES} bytes"),
                ));
            }
            Ok(Command::Parameter {
                graph: (*graph).to_owned(),
                parameter: (*parameter).to_owned(),
                element_type: (*element_type).to_owned(),
                shape,
                schema: (*schema).to_owned(),
                path: PathBuf::from(path),
            })
        }
        _ => Err(ControlError::new(
            "command",
            "unknown or malformed command; use status, groups, properties, generation queries, start/stop, reset, property/properties-set, parameter, source-ended, or quit",
        )),
    }
}

/// Prepares the bounded parameter artifact for the existing owner.
/// # Errors
/// Rejects invalid paths, file identity, extent, schema or parameter values.
pub fn prepare(command: Command) -> Result<Command, ControlError> {
    let Command::Parameter {
        graph,
        parameter,
        element_type,
        shape,
        schema,
        path,
    } = command
    else {
        return Ok(command);
    };

    let metadata = fs::symlink_metadata(&path).map_err(|error| {
        ControlError::new(
            "command.parameter.payload",
            format!("cannot inspect {}: {error}", path.display()),
        )
    })?;
    if !metadata.file_type().is_file() {
        return Err(ControlError::new(
            "command.parameter.payload",
            "parameter payload path must name a regular file, not a symlink or special file",
        ));
    }
    let expected = expected_parameter_bytes(&element_type, &shape)?;
    if metadata.len() > MAX_PARAMETER_BYTES {
        return Err(ControlError::new(
            "command.parameter.payload",
            format!("parameter file exceeds {MAX_PARAMETER_BYTES} bytes"),
        ));
    }
    if metadata.len() != expected {
        return Err(ControlError::new(
            "command.parameter.payload",
            format!(
                "expected {expected} payload bytes, file contains {}",
                metadata.len()
            ),
        ));
    }
    let mut file = open_payload(&path, &metadata, expected)?;
    let capacity = usize::try_from(expected).map_err(|_| {
        ControlError::new(
            "command.parameter.payload",
            "parameter payload is too large",
        )
    })?;
    let mut bytes = Vec::with_capacity(capacity);
    file.by_ref()
        .take(expected)
        .read_to_end(&mut bytes)
        .map_err(|error| {
            ControlError::new(
                "command.parameter.payload",
                format!("cannot read {}: {error}", path.display()),
            )
        })?;
    if bytes.len() as u64 != expected {
        return Err(ControlError::new(
            "command.parameter.payload",
            format!("expected {expected} payload bytes, got {}", bytes.len()),
        ));
    }
    let mut extra = [0_u8; 1];
    if file.read(&mut extra).map_err(|error| {
        ControlError::new(
            "command.parameter.payload",
            format!("cannot inspect payload end: {error}"),
        )
    })? != 0
    {
        return Err(ControlError::new(
            "command.parameter.payload",
            "payload grew beyond the declared extent during preparation",
        ));
    }
    Ok(Command::PreparedParameter {
        graph,
        parameter,
        value: NdArrayParameterValue {
            element_type,
            shape,
            schema,
            bytes: Arc::new(bytes),
        },
    })
}

fn open_payload(path: &Path, metadata: &Metadata, expected: u64) -> Result<File, ControlError> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        .map_err(|error| {
            ControlError::new(
                "command.parameter.payload",
                format!("cannot open {}: {error}", path.display()),
            )
        })?;
    let opened = file
        .metadata()
        .map_err(|error| ControlError::new("command.parameter.payload", error.to_string()))?;
    if !opened.is_file()
        || opened.dev() != metadata.dev()
        || opened.ino() != metadata.ino()
        || opened.len() != expected
    {
        return Err(ControlError::new(
            "command.parameter.payload",
            "parameter payload changed during preparation or is not a regular file of the declared extent",
        ));
    }
    Ok(file)
}

fn group_state(state: ExecutionGroupState) -> &'static str {
    match state {
        ExecutionGroupState::Stopped => "stopped",
        ExecutionGroupState::Running => "running",
    }
}

#[must_use]
pub fn state_name(state: LifecycleState) -> &'static str {
    match state {
        LifecycleState::Offline => "Offline",
        LifecycleState::Configuring => "Configuring",
        LifecycleState::Ready => "Ready",
        LifecycleState::Running => "Running",
        LifecycleState::Fault => "Fault",
    }
}

#[must_use]
pub fn scalar_json(value: &ScalarValue) -> Value {
    match value {
        ScalarValue::Bool(value) => json!({"type":"bool","value":value}),
        ScalarValue::Int(value) => json!({"type":"int","value":value}),
        ScalarValue::Long(value) => json!({"type":"long","value":value}),
        ScalarValue::Float(bits) => json!({"type":"float","bits":bits}),
        ScalarValue::Double(bits) => json!({"type":"double","bits":bits}),
        ScalarValue::Id(value) => json!({"type":"id","value":value}),
        ScalarValue::String(value) => json!({"type":"string","value":value}),
    }
}

fn parse_dimensions(value: &str) -> Result<Vec<u32>, ControlError> {
    let dimensions = value
        .split('x')
        .map(|dimension| {
            dimension.parse::<u32>().map_err(|error| {
                ControlError::new(
                    "command.parameter.dimensions",
                    format!("invalid dimension {dimension:?} in {value:?}: {error}"),
                )
            })
        })
        .collect::<Result<Vec<_>, _>>()?;
    if dimensions.is_empty() || dimensions.contains(&0) {
        return Err(ControlError::new(
            "command.parameter.dimensions",
            format!("expected nonzero dimensions joined by 'x', got {value:?}"),
        ));
    }
    Ok(dimensions)
}

pub(crate) fn expected_parameter_bytes(
    element_type: &str,
    shape: &[u32],
) -> Result<u64, ControlError> {
    if element_type != "F32_LE" {
        return Err(ControlError::new(
            "command.parameter.element_type",
            format!("runtime ndarray parameters require F32_LE; got {element_type:?}"),
        ));
    }
    shape
        .iter()
        .try_fold(4_u64, |bytes, dimension| {
            bytes.checked_mul(u64::from(*dimension))
        })
        .ok_or_else(|| {
            ControlError::new(
                "command.parameter.dimensions",
                "declared parameter byte count overflows",
            )
        })
}

fn parse_scalar(value_type: &str, value: &str) -> Result<ScalarValue, ControlError> {
    let invalid = |message: String| ControlError::new("command.property.value", message);
    match value_type {
        "bool" => value
            .parse()
            .map(ScalarValue::Bool)
            .map_err(|error| invalid(format!("invalid bool {value:?}: {error}"))),
        "int" => value
            .parse()
            .map(ScalarValue::Int)
            .map_err(|error| invalid(format!("invalid int {value:?}: {error}"))),
        "long" => value
            .parse()
            .map(ScalarValue::Long)
            .map_err(|error| invalid(format!("invalid long {value:?}: {error}"))),
        "float" => value
            .parse()
            .map(ScalarValue::float)
            .map_err(|error| invalid(format!("invalid float {value:?}: {error}"))),
        "double" => value
            .parse()
            .map(ScalarValue::double)
            .map_err(|error| invalid(format!("invalid double {value:?}: {error}"))),
        "id" => value
            .parse()
            .map(ScalarValue::Id)
            .map_err(|error| invalid(format!("invalid id {value:?}: {error}"))),
        "string" => Ok(ScalarValue::String(value.to_owned())),
        _ => Err(ControlError::new(
            "command.property.type",
            format!("expected bool, int, long, float, double, id, or string; got {value_type:?}"),
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::{
        parse, prepare, Command, ExecutionResult, Outcome, PropertyGenerationObservation,
        MAX_ARGUMENTS, MAX_PARAMETER_BYTES,
    };
    use crate::{
        ExecutionGroupState, LifecycleState, LiveGraphStatus, ParameterGeneration,
        PropertyGeneration, ScalarValue,
    };
    use std::collections::BTreeMap;
    use std::fs;

    fn assert_legacy(result: &ExecutionResult, outcome: Outcome, expected: &str) {
        assert_eq!(result.outcome(), outcome);
        assert_eq!(
            result.legacy_json(),
            serde_json::from_str::<serde_json::Value>(expected).unwrap()
        );
    }

    #[test]
    fn legacy_shutdown_and_group_snapshots_match_golden_json() {
        assert_legacy(
            &ExecutionResult::Quit,
            Outcome::Accepted,
            r#"{"outcome":"accepted","message":"shutdown requested","shutdown":true}"#,
        );
        assert_legacy(
            &ExecutionResult::Groups {
                groups: [
                    ("a".into(), ExecutionGroupState::Stopped),
                    ("b".into(), ExecutionGroupState::Running),
                ]
                .into(),
            },
            Outcome::Observed,
            r#"{"outcome":"observed","groups":{"a":"stopped","b":"running"}}"#,
        );
        assert_legacy(
            &ExecutionResult::Groups {
                groups: BTreeMap::default(),
            },
            Outcome::Observed,
            r#"{"outcome":"observed","groups":{}}"#,
        );
    }

    #[test]
    fn legacy_status_preserves_lifecycle_names_and_unsigned_counters() {
        for (state, name) in [
            (LifecycleState::Offline, "Offline"),
            (LifecycleState::Configuring, "Configuring"),
            (LifecycleState::Ready, "Ready"),
            (LifecycleState::Running, "Running"),
            (LifecycleState::Fault, "Fault"),
        ] {
            assert_legacy(
                &ExecutionResult::Status {
                    lifecycle_state: state,
                    status: LiveGraphStatus {
                        running: true,
                        owned_nodes: 2,
                        owned_links: 3,
                        discarded_buffers: u64::MAX,
                        discarded_by_sink: [("sink".into(), u64::MAX)].into(),
                    },
                },
                Outcome::Observed,
                &format!(
                    r#"{{"outcome":"observed","lifecycle_state":"{name}","running":true,"owned_nodes":2,"owned_links":3,"discarded_buffers":18446744073709551615,"discarded_by_sink":{{"sink":18446744073709551615}}}}"#
                ),
            );
        }
        assert_legacy(
            &ExecutionResult::Status {
                lifecycle_state: LifecycleState::Ready,
                status: LiveGraphStatus::default(),
            },
            Outcome::Observed,
            r#"{"outcome":"observed","lifecycle_state":"Ready","running":false,"owned_nodes":0,"owned_links":0,"discarded_buffers":0,"discarded_by_sink":{}}"#,
        );
    }

    #[test]
    fn legacy_properties_preserve_all_seven_scalar_variants_and_bits() {
        assert_legacy(
            &ExecutionResult::Properties {
                graph: "graph".into(),
                properties: [
                    ("n:bool".into(), ScalarValue::Bool(false)),
                    ("n:int".into(), ScalarValue::Int(i32::MIN)),
                    ("n:long".into(), ScalarValue::Long(i64::MIN)),
                    ("n:float".into(), ScalarValue::Float((-0.0_f32).to_bits())),
                    ("n:double".into(), ScalarValue::Double(u64::MAX)),
                    ("n:id".into(), ScalarValue::Id(u32::MAX)),
                    ("n:string".into(), ScalarValue::String("λ\n\0\"\\".into())),
                ]
                .into(),
            },
            Outcome::Observed,
            r#"{"outcome":"observed","graph":"graph","properties":{"n:bool":{"type":"bool","value":false},"n:int":{"type":"int","value":-2147483648},"n:long":{"type":"long","value":-9223372036854775808},"n:float":{"type":"float","bits":2147483648},"n:double":{"type":"double","bits":18446744073709551615},"n:id":{"type":"id","value":4294967295},"n:string":{"type":"string","value":"λ\n\u0000\"\\"}}}"#,
        );
        assert_legacy(
            &ExecutionResult::Properties {
                graph: "g".into(),
                properties: [
                    ("n:f".into(), ScalarValue::Float(u32::MAX)),
                    ("n:d".into(), ScalarValue::Double((-0.0_f64).to_bits())),
                ]
                .into(),
            },
            Outcome::Observed,
            r#"{"outcome":"observed","graph":"g","properties":{"n:f":{"type":"float","bits":4294967295},"n:d":{"type":"double","bits":9223372036854775808}}}"#,
        );
        assert_legacy(
            &ExecutionResult::Properties {
                graph: "g".into(),
                properties: BTreeMap::default(),
            },
            Outcome::Observed,
            r#"{"outcome":"observed","graph":"g","properties":{}}"#,
        );
    }

    #[test]
    fn legacy_generation_queries_preserve_optional_active_and_signed_values() {
        for (active, expected) in [
            (
                Some(i64::MIN),
                r#"{"outcome":"observed","graph":"g","node":"n","requested":9223372036854775807,"active":-9223372036854775808}"#,
            ),
            (
                None,
                r#"{"outcome":"observed","graph":"g","node":"n","requested":9223372036854775807,"active":null}"#,
            ),
        ] {
            assert_legacy(
                &ExecutionResult::PropertyGeneration {
                    graph: "g".into(),
                    node: "n".into(),
                    generation: PropertyGeneration {
                        requested: i64::MAX,
                        active,
                    },
                },
                Outcome::Observed,
                expected,
            );
        }
        assert_legacy(
            &ExecutionResult::ParameterGeneration {
                graph: "g".into(),
                node: "n".into(),
                generation: ParameterGeneration {
                    requested: i64::MIN,
                    active: i64::MAX,
                },
            },
            Outcome::Observed,
            r#"{"outcome":"observed","graph":"g","node":"n","requested":-9223372036854775808,"active":9223372036854775807}"#,
        );
    }

    #[test]
    fn legacy_group_requests_preserve_requested_and_optional_observed_state() {
        for (requested, requested_name) in [
            (ExecutionGroupState::Stopped, "stopped"),
            (ExecutionGroupState::Running, "running"),
        ] {
            for (observed, observed_json) in [
                (None, "null"),
                (Some(ExecutionGroupState::Stopped), r#""stopped""#),
                (Some(ExecutionGroupState::Running), r#""running""#),
            ] {
                assert_legacy(
                    &ExecutionResult::GroupState {
                        group: "group".into(),
                        requested,
                        observed,
                    },
                    Outcome::Requested,
                    &format!(
                        r#"{{"outcome":"requested","group":"group","requested":"{requested_name}","observed":{observed_json}}}"#
                    ),
                );
            }
        }
    }

    #[test]
    fn legacy_session_completions_retain_command_specific_capitalization() {
        for (result, expected) in [
            (
                ExecutionResult::SessionStop {
                    state: LifecycleState::Ready,
                },
                r#"{"outcome":"completed","session_state":"READY"}"#,
            ),
            (
                ExecutionResult::SessionStart {
                    state: LifecycleState::Running,
                },
                r#"{"outcome":"completed","session_state":"RUNNING"}"#,
            ),
            (
                ExecutionResult::SourceEnded {
                    state: LifecycleState::Ready,
                },
                r#"{"outcome":"completed","session_state":"Ready"}"#,
            ),
            (
                ExecutionResult::Reset {
                    state: LifecycleState::Ready,
                },
                r#"{"outcome":"completed","session_state":"Ready"}"#,
            ),
        ] {
            assert_legacy(&result, Outcome::Completed, expected);
        }
    }

    #[test]
    fn legacy_property_updates_retain_null_observations_and_adoption_outcomes() {
        let observations = vec![
            PropertyGenerationObservation {
                node: "a".into(),
                generation: None,
            },
            PropertyGenerationObservation {
                node: "b".into(),
                generation: Some(PropertyGeneration {
                    requested: 10,
                    active: None,
                }),
            },
            PropertyGenerationObservation {
                node: "c".into(),
                generation: Some(PropertyGeneration {
                    requested: 11,
                    active: Some(10),
                }),
            },
        ];
        assert_legacy(
            &ExecutionResult::PropertiesSet {
                graph: "g".into(),
                generations: observations,
                active_adoption_observed: false,
            },
            Outcome::Submitted,
            r#"{"outcome":"submitted","graph":"g","active_adoption_observed":false,"property_generations":[{"node":"a","requested":null,"active":null},{"node":"b","requested":10,"active":null},{"node":"c","requested":11,"active":10}]}"#,
        );
        assert_legacy(
            &ExecutionResult::PropertiesSet {
                graph: "g".into(),
                generations: vec![PropertyGenerationObservation {
                    node: "n".into(),
                    generation: Some(PropertyGeneration {
                        requested: 12,
                        active: Some(12),
                    }),
                }],
                active_adoption_observed: true,
            },
            Outcome::Active,
            r#"{"outcome":"active","graph":"g","active_adoption_observed":true,"property_generations":[{"node":"n","requested":12,"active":12}]}"#,
        );
        assert_legacy(
            &ExecutionResult::PropertiesSet {
                graph: "g".into(),
                generations: Vec::new(),
                active_adoption_observed: false,
            },
            Outcome::Submitted,
            r#"{"outcome":"submitted","graph":"g","active_adoption_observed":false,"property_generations":[]}"#,
        );
    }

    #[test]
    fn legacy_parameter_submission_is_submitted_with_or_without_observation() {
        for (generation, expected) in [
            (
                None,
                r#"{"outcome":"submitted","graph":"g","parameter":"n:p","active_adoption_observed":false,"parameter_generations":null}"#,
            ),
            (
                Some(ParameterGeneration {
                    requested: 9,
                    active: 9,
                }),
                r#"{"outcome":"submitted","graph":"g","parameter":"n:p","active_adoption_observed":false,"parameter_generations":{"requested":9,"active":9}}"#,
            ),
        ] {
            assert_legacy(
                &ExecutionResult::Parameter {
                    graph: "g".into(),
                    parameter: "n:p".into(),
                    generation,
                },
                Outcome::Submitted,
                expected,
            );
        }
    }

    fn words(line: &str) -> Vec<String> {
        line.split_whitespace().map(str::to_owned).collect()
    }

    #[test]
    fn parser_accepts_existing_commands_and_property_transactions() {
        assert_eq!(
            parse(&words("session-start")).unwrap(),
            Command::SessionStart
        );
        assert_eq!(
            parse(&words("property graph node:gain float 0.5")).unwrap(),
            Command::PropertiesSet(
                "graph".into(),
                [("node:gain".into(), crate::ScalarValue::float(0.5))].into()
            )
        );
        assert!(parse(&words("properties-set g n:v int 1 n:v int 2")).is_err());
        assert!(parse(&words("properties-set g n:v int 1 m:v double 2.0")).is_ok());
    }

    #[test]
    fn parser_bounds_argument_count_and_checked_parameter_shapes() {
        let many = vec!["unused".to_owned(); MAX_ARGUMENTS + 1];
        assert!(parse(&many).unwrap_err().message.contains("at most"));
        assert!(parse(&words("parameter g p U16_LE 4x4 schema file")).is_err());
        assert!(parse(&words(
            "parameter g p F32_LE 4294967295x4294967295 schema file"
        ))
        .is_err());
        assert!(parse(&words("parameter g p F32_LE 16384x8192 schema file")).is_ok());
        assert_eq!(MAX_PARAMETER_BYTES, 512 * 1024 * 1024);
    }

    #[test]
    fn payload_replacement_between_inspection_and_open_is_rejected() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("payload");
        let original = directory.path().join("original");
        fs::write(&path, [0_u8; 4]).unwrap();
        let metadata = fs::symlink_metadata(&path).unwrap();
        fs::rename(&path, &original).unwrap();
        fs::write(&path, [1_u8; 4]).unwrap();
        assert!(super::open_payload(&path, &metadata, 4).is_err());
        fs::remove_file(&path).unwrap();
        std::os::unix::fs::symlink(&original, &path).unwrap();
        assert!(super::open_payload(&path, &metadata, 4).is_err());
        fs::remove_file(&path).unwrap();
        assert!(std::process::Command::new("mkfifo")
            .arg(&path)
            .status()
            .unwrap()
            .success());
        let start = std::time::Instant::now();
        assert!(super::open_payload(&path, &metadata, 4).is_err());
        assert!(start.elapsed() < std::time::Duration::from_secs(1));
    }

    #[test]
    fn parameter_preparation_requires_regular_exact_sized_payload() {
        let directory = tempfile::tempdir().unwrap();
        let payload = directory.path().join("payload");
        fs::write(&payload, [1_u8, 2, 3, 4]).unwrap();
        let command = parse(&words(&format!(
            "parameter g p F32_LE 1 schema {}",
            payload.display()
        )))
        .unwrap();
        let Command::PreparedParameter { value, .. } = prepare(command).unwrap() else {
            panic!("expected prepared parameter")
        };
        assert_eq!(value.bytes.as_slice(), [1, 2, 3, 4]);
        fs::write(&payload, [1_u8, 2, 3]).unwrap();
        let command = parse(&words(&format!(
            "parameter g p F32_LE 1 schema {}",
            payload.display()
        )))
        .unwrap();
        assert!(prepare(command)
            .unwrap_err()
            .message
            .contains("expected 4 payload bytes"));
        let symlink = directory.path().join("link");
        #[cfg(unix)]
        std::os::unix::fs::symlink(&payload, &symlink).unwrap();
        let command = parse(&words(&format!(
            "parameter g p F32_LE 1 schema {}",
            symlink.display()
        )))
        .unwrap();
        assert!(prepare(command)
            .unwrap_err()
            .message
            .contains("regular file"));
    }
}
