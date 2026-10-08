//! Operator command parsing, parameter preparation and result reporting.

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
#[path = "tests/commands.rs"]
mod tests;
