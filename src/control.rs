use pipewireao_rtc::{
    ExecutionGroupState, LifecycleEvent, LifecycleState, LiveGraphAdapter, NdArrayParameterValue,
    PropertyGeneration, Runner, ScalarValue, ScientificDiagnostic,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};
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

    fn from_diagnostic(diagnostic: &ScientificDiagnostic) -> Self {
        Self::new(diagnostic.field(), diagnostic.message())
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, Eq, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct SocketRequest {
    pub version: u8,
    pub id: String,
    pub argv: Vec<String>,
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
    pub result: Value,
    pub shutdown: bool,
}

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

fn property_adoption_observed(
    running: bool,
    baseline: &[Option<PropertyGeneration>],
    observed: &[Option<PropertyGeneration>],
) -> bool {
    running
        && !observed.is_empty()
        && baseline.len() == observed.len()
        && baseline.iter().zip(observed).all(|(before, after)| {
            matches!((before, after), (Some(before), Some(after))
                if after.requested > before.requested && after.active == Some(after.requested))
        })
}

impl Command {
    // Keep the complete typed command surface in one exhaustive owner dispatch.
    #[allow(clippy::too_many_lines)]
    pub fn execute(self, runner: &mut Runner<LiveGraphAdapter>) -> Result<Execution, ControlError> {
        use Command as C;
        let (outcome, result, shutdown) = match self {
            C::Quit => (
                "accepted",
                json!({"message":"shutdown requested","shutdown":true}),
                true,
            ),
            C::Groups => (
                "observed",
                json!({"groups": runner.execution_group_states().iter().map(|(name,state)| (name, group_state(*state))).collect::<BTreeMap<_,_>>() }),
                false,
            ),
            C::Status => {
                let discarded = runner
                    .executor_mut()
                    .observe_discarded_buffers()
                    .map_err(|diagnostic| ControlError::from_diagnostic(&diagnostic))?;
                let status = runner.executor().status();
                (
                    "observed",
                    json!({
                        "lifecycle_state":state_name(runner.state()),
                        "running": status.running,
                        "owned_nodes": status.owned_nodes,
                        "owned_links": status.owned_links,
                        "discarded_buffers": status.discarded_buffers,
                        "discarded_by_sink": discarded,
                    }),
                    false,
                )
            }
            C::Properties(graph) => {
                let values = runner
                    .executor()
                    .observe_properties(&graph)
                    .map_err(|diagnostic| ControlError::from_diagnostic(&diagnostic))?;
                (
                    "observed",
                    json!({"graph":graph,"properties":values.iter().map(|(name,value)| (name, scalar_json(value))).collect::<BTreeMap<_,_>>() }),
                    false,
                )
            }
            C::PropertyGeneration(graph, node) => {
                let generation = runner
                    .executor()
                    .observe_property_generation(&graph, &node)
                    .map_err(|diagnostic| ControlError::from_diagnostic(&diagnostic))?;
                (
                    "observed",
                    json!({"graph":graph,"node":node,"requested":generation.requested,"active":generation.active}),
                    false,
                )
            }
            C::ParameterGeneration(graph, node) => {
                let generation = runner
                    .executor()
                    .observe_parameter_generation(&graph, &node)
                    .map_err(|diagnostic| ControlError::from_diagnostic(&diagnostic))?;
                (
                    "observed",
                    json!({"graph":graph,"node":node,"requested":generation.requested,"active":generation.active}),
                    false,
                )
            }
            C::StopGroup(name) => {
                dispatch_preserving_state(
                    runner,
                    LifecycleEvent::StopExecutionGroup(name.clone()),
                )?;
                let state = runner.execution_group_states().get(&name).copied();
                (
                    "requested",
                    json!({"group":name,"requested":"stopped","observed":state.map(group_state)}),
                    false,
                )
            }
            C::StartGroup(name) => {
                dispatch_preserving_state(
                    runner,
                    LifecycleEvent::StartExecutionGroup(name.clone()),
                )?;
                let state = runner.execution_group_states().get(&name).copied();
                (
                    "requested",
                    json!({"group":name,"requested":"running","observed":state.map(group_state)}),
                    false,
                )
            }
            C::SessionStop => {
                dispatch_expected(runner, LifecycleEvent::Stop, LifecycleState::Ready)?;
                ("completed", json!({"session_state":"READY"}), false)
            }
            C::SessionStart => {
                dispatch_expected(runner, LifecycleEvent::Start, LifecycleState::Running)?;
                ("completed", json!({"session_state":"RUNNING"}), false)
            }
            C::SourceEnded => {
                dispatch_expected(
                    runner,
                    LifecycleEvent::FiniteSourceCompleted,
                    LifecycleState::Ready,
                )?;
                (
                    "completed",
                    json!({"session_state":state_name(runner.state())}),
                    false,
                )
            }
            C::Reset => {
                dispatch_expected(runner, LifecycleEvent::Reset, LifecycleState::Ready)?;
                (
                    "completed",
                    json!({"session_state":state_name(runner.state())}),
                    false,
                )
            }
            C::PropertiesSet(graph, values) => {
                runner
                    .executor()
                    .validate_property_update(&graph, &values)
                    .map_err(|diagnostic| ControlError::from_diagnostic(&diagnostic))?;
                let nodes = values
                    .keys()
                    .filter_map(|qualified| {
                        qualified.split_once(':').map(|(node, _)| node.to_owned())
                    })
                    .collect::<BTreeSet<_>>();
                let running = runner.state() == LifecycleState::Running;
                let baseline = nodes
                    .iter()
                    .map(|node| {
                        runner
                            .executor()
                            .observe_property_generation(&graph, node)
                            .ok()
                    })
                    .collect::<Vec<_>>();
                dispatch_preserving_state(
                    runner,
                    LifecycleEvent::UpdateProperties {
                        graph: graph.clone(),
                        values,
                    },
                )?;
                let observed = nodes
                    .iter()
                    .map(|node| {
                        runner
                            .executor()
                            .observe_property_generation(&graph, node)
                            .ok()
                    })
                    .collect::<Vec<_>>();
                let active = property_adoption_observed(running, &baseline, &observed);
                let observations = nodes
                    .iter()
                    .zip(&observed)
                    .map(|(node, generation)| {
                        json!({"node":node,"requested":generation.map(|value| value.requested),
                        "active":generation.and_then(|value| value.active)})
                    })
                    .collect::<Vec<_>>();
                (
                    if active { "active" } else { "submitted" },
                    json!({"graph":graph,"property_generations":observations,"active_adoption_observed":active}),
                    false,
                )
            }
            C::Parameter {
                graph, parameter, ..
            } => {
                return Err(ControlError::new(
                    "command.parameter",
                    format!("parameter {graph}.{parameter} was not prepared"),
                ));
            }
            C::PreparedParameter {
                graph,
                parameter,
                value,
            } => {
                runner
                    .executor()
                    .validate_parameter_update(&graph, &parameter, &value)
                    .map_err(|diagnostic| ControlError::from_diagnostic(&diagnostic))?;
                let source_node = parameter.split(':').next().unwrap_or(&parameter).to_owned();
                dispatch_preserving_state(
                    runner,
                    LifecycleEvent::UpdateParameter {
                        graph: graph.clone(),
                        parameter: parameter.clone(),
                        value,
                    },
                )?;
                let observed = runner
                    .executor()
                    .observe_parameter_generation(&graph, &source_node)
                    .ok();
                (
                    "submitted",
                    json!({"graph":graph,"parameter":parameter,"active_adoption_observed":false, "parameter_generations":observed.map(|generation| json!({"requested":generation.requested,"active":generation.active}))}),
                    false,
                )
            }
        };
        Ok(Execution {
            result: {
                let mut result = result;
                if let Some(object) = result.as_object_mut() {
                    object.insert("outcome".to_owned(), json!(outcome));
                }
                result
            },
            shutdown,
        })
    }
}

fn dispatch_preserving_state(
    runner: &mut Runner<LiveGraphAdapter>,
    event: LifecycleEvent,
) -> Result<(), ControlError> {
    let expected = runner.state();
    let observed = runner
        .dispatch(event)
        .map_err(|error| ControlError::new("lifecycle.dispatch", error.to_string()))?;
    if observed != expected {
        return Err(ControlError::new(
            "lifecycle.dispatch",
            format!("expected lifecycle to remain {expected:?}, observed {observed:?}"),
        ));
    }
    Ok(())
}

fn dispatch_expected(
    runner: &mut Runner<LiveGraphAdapter>,
    event: LifecycleEvent,
    expected: LifecycleState,
) -> Result<(), ControlError> {
    let observed = runner
        .dispatch(event)
        .map_err(|error| ControlError::new("lifecycle.dispatch", error.to_string()))?;
    if observed != expected {
        return Err(ControlError::new(
            "lifecycle.dispatch",
            format!("expected lifecycle {expected:?}, observed {observed:?}"),
        ));
    }
    Ok(())
}

fn group_state(state: ExecutionGroupState) -> &'static str {
    match state {
        ExecutionGroupState::Stopped => "stopped",
        ExecutionGroupState::Running => "running",
    }
}

pub fn state_name(state: LifecycleState) -> &'static str {
    match state {
        LifecycleState::Offline => "Offline",
        LifecycleState::Configuring => "Configuring",
        LifecycleState::Ready => "Ready",
        LifecycleState::Running => "Running",
        LifecycleState::Fault => "Fault",
    }
}

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

fn expected_parameter_bytes(element_type: &str, shape: &[u32]) -> Result<u64, ControlError> {
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
    use super::{parse, prepare, Command, MAX_ARGUMENTS, MAX_PARAMETER_BYTES};
    use std::fs;

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
                [("node:gain".into(), pipewireao_rtc::ScalarValue::float(0.5))].into()
            )
        );
        assert!(parse(&words("properties-set g n:v int 1 n:v int 2")).is_err());
        assert!(parse(&words("properties-set g n:v int 1 m:v double 2.0")).is_ok());
    }

    fn assert_property_rejections(
        runner: &mut pipewireao_rtc::Runner<pipewireao_rtc::LiveGraphAdapter>,
        graph: &str,
        node: &str,
    ) {
        use pipewireao_rtc::ScalarValue;
        use std::collections::BTreeMap;
        let expected = runner.state();
        let generation = runner
            .executor()
            .observe_property_generation(graph, node)
            .unwrap();
        let properties = runner.executor().observe_properties(graph).unwrap();
        for (target, values) in [
            (
                "unknown-graph".to_owned(),
                BTreeMap::from([(format!("{node}:gain"), ScalarValue::float(0.2))]),
            ),
            (
                graph.to_owned(),
                BTreeMap::from([(format!("{node}:unknown"), ScalarValue::float(0.2))]),
            ),
            (
                graph.to_owned(),
                BTreeMap::from([(format!("{node}:gain"), ScalarValue::Int(1))]),
            ),
            (
                graph.to_owned(),
                BTreeMap::from([(
                    format!("{node}:gain"),
                    ScalarValue::Double(0.2_f64.to_bits()),
                )]),
            ),
            (
                graph.to_owned(),
                BTreeMap::from([
                    (format!("{node}:gain"), ScalarValue::float(0.2)),
                    (format!("{node}:unknown"), ScalarValue::float(0.3)),
                ]),
            ),
        ] {
            assert!(Command::PropertiesSet(target, values)
                .execute(runner)
                .is_err());
            assert_eq!(
                runner.state(),
                expected,
                "invalid request faulted: {:?}",
                runner.diagnostic()
            );
            assert!(runner.diagnostic().is_none());
            assert_eq!(
                runner
                    .executor()
                    .observe_property_generation(graph, node)
                    .unwrap(),
                generation
            );
            assert_eq!(
                runner.executor().observe_properties(graph).unwrap(),
                properties
            );
        }
    }

    #[test]
    #[ignore = "requires a private core and a looping native scientific deployment fixture"]
    #[allow(clippy::too_many_lines)]
    fn property_rejections_preserve_ready_and_running_sessions() {
        use pipewireao_rtc::{
            ConfigurationInput, DevelopmentConfig, LifecycleEvent, LifecycleState,
            LiveGraphAdapter, Runner, ScalarValue,
        };
        use std::collections::BTreeMap;
        use std::path::PathBuf;

        let remote = std::env::var("PIPEWIREAO_RTC_CONTROL_TEST_REMOTE").unwrap();
        let config = PathBuf::from(std::env::var_os("PIPEWIREAO_RTC_CONTROL_TEST_CONFIG").unwrap());
        let graph = std::env::var("PIPEWIREAO_RTC_CONTROL_TEST_GRAPH").unwrap();
        let node = std::env::var("PIPEWIREAO_RTC_CONTROL_TEST_NODE").unwrap();
        let configuration = DevelopmentConfig::load(&config).unwrap();
        let mut runner = Runner::new(LiveGraphAdapter::connect(remote).unwrap());
        assert_eq!(
            runner
                .dispatch(LifecycleEvent::Load(ConfigurationInput::File(config)))
                .unwrap(),
            LifecycleState::Ready,
            "load diagnostic: {:?}",
            runner.diagnostic()
        );
        let graph_spec = configuration
            .graphs
            .iter()
            .find(|item| item.node_name == graph)
            .unwrap();
        let parameter = graph_spec.ports.iter().find(|port| port.parameter).unwrap();
        let configured_path = &configuration.parameters[&format!("{graph}:{}", parameter.name)];
        let payload = configured_path
            .strip_prefix("${")
            .and_then(|path| path.strip_suffix('}'))
            .map_or_else(
                || PathBuf::from(configured_path),
                |name| PathBuf::from(std::env::var_os(name).unwrap()),
            );
        let replacement = prepare(Command::Parameter {
            graph: graph.clone(),
            parameter: parameter.name.clone(),
            element_type: parameter.element_type.clone(),
            shape: parameter.shape.clone(),
            schema: parameter.schema.clone(),
            path: payload,
        })
        .unwrap();
        let Err(error) = replacement.execute(&mut runner) else {
            panic!("pending initial reconstructor replacement was accepted");
        };
        assert!(error.message.contains("already pending"));
        assert_eq!(runner.state(), LifecycleState::Ready);
        assert!(runner.diagnostic().is_none());
        assert_eq!(
            Command::Status.execute(&mut runner).unwrap().result["discarded_buffers"],
            0
        );
        for expected in [LifecycleState::Ready, LifecycleState::Running] {
            if expected == LifecycleState::Running {
                assert_eq!(runner.dispatch(LifecycleEvent::Start).unwrap(), expected);
            }
            assert_property_rejections(&mut runner, &graph, &node);
            let result = Command::PropertiesSet(
                graph.clone(),
                BTreeMap::from([
                    (format!("{node}:gain"), ScalarValue::float(-0.3)),
                    (format!("{node}:pole"), ScalarValue::float(0.99)),
                ]),
            )
            .execute(&mut runner)
            .expect("valid property transaction");
            assert_eq!(runner.state(), expected);
            assert!(runner.diagnostic().is_none());
            assert_eq!(
                result.result["outcome"],
                if expected == LifecycleState::Running {
                    "active"
                } else {
                    "submitted"
                }
            );
        }
        let group = runner
            .execution_group_states()
            .keys()
            .next()
            .unwrap()
            .clone();
        Command::StopGroup(group.clone())
            .execute(&mut runner)
            .unwrap();
        assert_eq!(runner.state(), LifecycleState::Running);
        let paused =
            Command::Status.execute(&mut runner).unwrap().result["discarded_buffers"].clone();
        std::thread::sleep(std::time::Duration::from_millis(200));
        assert_eq!(
            Command::Status.execute(&mut runner).unwrap().result["discarded_buffers"],
            paused
        );
        Command::StartGroup(group).execute(&mut runner).unwrap();
        assert_eq!(runner.state(), LifecycleState::Running);
        assert!(Command::Reset.execute(&mut runner).is_err());
        assert_eq!(runner.state(), LifecycleState::Running);
        assert!(runner.diagnostic().is_none());
        Command::SessionStop.execute(&mut runner).unwrap();
        Command::Reset.execute(&mut runner).unwrap();
        assert_eq!(runner.state(), LifecycleState::Ready);
        let before = runner
            .executor()
            .observe_property_generation(&graph, &node)
            .unwrap();
        let values = BTreeMap::from([
            (format!("{node}:gain"), ScalarValue::float(-0.2)),
            (format!("{node}:pole"), ScalarValue::float(0.98)),
        ]);
        let submitted = Command::PropertiesSet(graph.clone(), values.clone())
            .execute(&mut runner)
            .unwrap();
        assert_eq!(submitted.result["outcome"], "submitted");
        Command::SessionStart.execute(&mut runner).unwrap();
        let after = runner
            .executor()
            .observe_property_generation(&graph, &node)
            .unwrap();
        assert!(after.requested > before.requested);
        assert_eq!(after.active, Some(after.requested));
        let snapshot = runner.executor().observe_properties(&graph).unwrap();
        for (name, value) in values {
            assert_eq!(snapshot.get(&name), Some(&value));
        }
        assert_eq!(
            runner.dispatch(LifecycleEvent::Stop).unwrap(),
            LifecycleState::Ready
        );
        assert_eq!(
            runner.dispatch(LifecycleEvent::Unload).unwrap(),
            LifecycleState::Offline
        );
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
    fn property_adoption_requires_running_and_advancement_of_this_mutation() {
        use pipewireao_rtc::PropertyGeneration;
        let previous = Some(PropertyGeneration {
            requested: 9,
            active: Some(9),
        });
        let adopted = Some(PropertyGeneration {
            requested: 10,
            active: Some(10),
        });
        assert!(!super::property_adoption_observed(
            false,
            &[previous],
            &[previous]
        ));
        assert!(!super::property_adoption_observed(
            false,
            &[previous],
            &[adopted]
        ));
        assert!(!super::property_adoption_observed(
            true,
            &[previous],
            &[previous]
        ));
        assert!(!super::property_adoption_observed(true, &[None], &[None]));
        assert!(!super::property_adoption_observed(
            true,
            &[previous],
            &[Some(PropertyGeneration {
                requested: 10,
                active: None
            })]
        ));
        assert!(super::property_adoption_observed(
            true,
            &[previous],
            &[adopted]
        ));
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
