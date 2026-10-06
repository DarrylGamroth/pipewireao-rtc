//! Exact cold runner completion and rejection profile.
//! Native results preserve domain types and scalar bits; no JSON conversion occurs.

use crate::control::{ControlError, ExecutionResult, Outcome, PropertyGenerationObservation};
use crate::native_control_codec::{self as envelope, ReplyHeader, ReplyKind};
use crate::native_runner_codec::Operation;
use crate::{
    ExecutionGroupState, LifecycleState, LiveGraphStatus, ParameterGeneration, PropertyGeneration,
    ScalarValue,
};
use pipewire::spa::pod::Value;
use pipewire::spa::utils::Id;
use std::collections::{BTreeMap, BTreeSet};

const BOUND: usize = envelope::LIFECYCLE_REPLY_BOUND;
// Every catalog row has a Struct header, a nonempty String and two or more
// scalar headers/bodies, or one scalar and its body: at least forty bytes.
const MIN_ROW_BYTES: usize = 40;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Completion {
    pub header: ReplyHeader,
    pub lifecycle: LifecycleState,
    pub result: Result<ExecutionResult, ControlError>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Rejection {
    pub header: ReplyHeader,
    pub lifecycle: LifecycleState,
    pub error: ControlError,
}

fn invalid(message: impl Into<String>) -> ControlError {
    ControlError::new("native.runner.result", message)
}

#[must_use]
pub fn lifecycle_id(state: LifecycleState) -> u32 {
    match state {
        LifecycleState::Offline => 1,
        LifecycleState::Configuring => 2,
        LifecycleState::Ready => 3,
        LifecycleState::Running => 4,
        LifecycleState::Fault => 5,
    }
}

fn lifecycle(value: u32) -> Result<LifecycleState, ControlError> {
    match value {
        1 => Ok(LifecycleState::Offline),
        2 => Ok(LifecycleState::Configuring),
        3 => Ok(LifecycleState::Ready),
        4 => Ok(LifecycleState::Running),
        5 => Ok(LifecycleState::Fault),
        _ => Err(invalid("unknown lifecycle Id")),
    }
}

fn outcome_id(outcome: Outcome) -> u32 {
    match outcome {
        Outcome::Accepted => 1,
        Outcome::Observed => 2,
        Outcome::Requested => 3,
        Outcome::Completed => 4,
        Outcome::Active => 5,
        Outcome::Submitted => 6,
    }
}

fn outcome(value: u32) -> Result<Outcome, ControlError> {
    match value {
        1 => Ok(Outcome::Accepted),
        2 => Ok(Outcome::Observed),
        3 => Ok(Outcome::Requested),
        4 => Ok(Outcome::Completed),
        5 => Ok(Outcome::Active),
        6 => Ok(Outcome::Submitted),
        _ => Err(invalid("unknown outcome Id")),
    }
}

fn group_id(state: ExecutionGroupState) -> u32 {
    match state {
        ExecutionGroupState::Stopped => 1,
        ExecutionGroupState::Running => 2,
    }
}

fn group(value: u32) -> Result<ExecutionGroupState, ControlError> {
    match value {
        1 => Ok(ExecutionGroupState::Stopped),
        2 => Ok(ExecutionGroupState::Running),
        _ => Err(invalid("unknown group state Id")),
    }
}

fn check_header(header: &ReplyHeader, kind: ReplyKind) -> Result<(), ControlError> {
    header.validate(kind).map_err(|e| invalid(e.to_string()))?;
    if kind == ReplyKind::Completion {
        Operation::try_from(header.operation)?;
        if header.token == 0 {
            return Err(invalid("initial completion is not a fresh runner reply"));
        }
    }
    Ok(())
}

fn result_operation(result: &ExecutionResult) -> Operation {
    use ExecutionResult as R;
    match result {
        R::Quit => Operation::Quit,
        R::Groups { .. } => Operation::Groups,
        R::Status { .. } => Operation::Status,
        R::Properties { .. } => Operation::Properties,
        R::PropertyGeneration { .. } => Operation::PropertyGeneration,
        R::ParameterGeneration { .. } => Operation::ParameterGeneration,
        R::GroupState { requested, .. } => match requested {
            ExecutionGroupState::Stopped => Operation::StopGroup,
            ExecutionGroupState::Running => Operation::StartGroup,
        },
        R::SessionStop { .. } => Operation::SessionStop,
        R::SessionStart { .. } => Operation::SessionStart,
        R::SourceEnded { .. } => Operation::SourceEnded,
        R::Reset { .. } => Operation::Reset,
        R::PropertiesSet { .. } => Operation::PropertiesSet,
        R::Parameter { .. } => Operation::Parameter,
    }
}

fn check_result(
    header: &ReplyHeader,
    state: LifecycleState,
    result: &ExecutionResult,
) -> Result<(), ControlError> {
    check_header(header, ReplyKind::Completion)?;
    if header.result != 0 || header.operation != result_operation(result) as u32 {
        return Err(invalid("successful result does not match its header"));
    }
    match result {
        ExecutionResult::Status {
            lifecycle_state, ..
        } if *lifecycle_state != state => Err(invalid("status lifecycle differs from completion")),
        ExecutionResult::SessionStart { state: completed } => {
            if *completed != LifecycleState::Running || *completed != state {
                return Err(invalid("start completion must reach Running"));
            }
            Ok(())
        }
        ExecutionResult::SessionStop { state: completed }
        | ExecutionResult::SourceEnded { state: completed }
        | ExecutionResult::Reset { state: completed } => {
            if *completed != LifecycleState::Ready || *completed != state {
                return Err(invalid("stop/reset/source completion must reach Ready"));
            }
            Ok(())
        }
        ExecutionResult::PropertiesSet {
            generations,
            active_adoption_observed: true,
            ..
        } => {
            check_rows(generations.len())?;
            // These conditions follow from the existing owner adoption predicate.
            // Previous-generation advancement remains the owner's proof.
            if state != LifecycleState::Running
                || generations.is_empty()
                || !generations.iter().all(|observation| {
                    observation
                        .generation
                        .is_some_and(|generation| generation.active == Some(generation.requested))
                })
            {
                return Err(invalid(
                    "active property reply lacks adopted observations while Running",
                ));
            }
            Ok(())
        }
        _ => Ok(()),
    }
}

fn add(a: usize, b: usize) -> Result<usize, ControlError> {
    let size = a
        .checked_add(b)
        .ok_or_else(|| invalid("reply size overflow"))?;
    if size > BOUND {
        return Err(invalid("runner reply exceeds 64 KiB"));
    }
    Ok(size)
}

fn pod_size(body: usize) -> Result<usize, ControlError> {
    let size = body
        .checked_add(15)
        .ok_or_else(|| invalid("reply size overflow"))?
        & !7;
    add(0, size)
}

fn string_size(text: &str) -> Result<usize, ControlError> {
    // Reject oversized borrowed input before scanning or copying its bytes.
    let size = pod_size(add(text.len(), 1)?)?;
    if text.contains('\0') {
        return Err(invalid("native strings must contain no NUL"));
    }
    Ok(size)
}

fn name_size(text: &str) -> Result<usize, ControlError> {
    let size = string_size(text)?;
    if text.is_empty() {
        return Err(invalid("catalog and target names must be nonempty"));
    }
    Ok(size)
}

fn name(text: &str) -> Result<String, ControlError> {
    name_size(text)?;
    Ok(text.to_owned())
}

fn check_rows(count: usize) -> Result<(), ControlError> {
    // Count first: malformed/unbounded borrowed collections do not get walked.
    if count > BOUND / MIN_ROW_BYTES {
        return Err(invalid("catalog cannot fit the reply envelope"));
    }
    Ok(())
}

fn usize_bits(value: usize) -> Result<i64, ControlError> {
    u64::try_from(value)
        .map(envelope::serial_to_long)
        .map_err(|_| invalid("owned object count exceeds UInt64"))
}

fn scalar_size(value: &ScalarValue) -> Result<usize, ControlError> {
    match value {
        ScalarValue::String(value) => string_size(value),
        _ => Ok(16),
    }
}

fn generation_size(generation: Option<PropertyGeneration>) -> usize {
    generation.map_or(16, |value| if value.active.is_some() { 32 } else { 24 })
}

fn details_size(result: &ExecutionResult) -> Result<usize, ControlError> {
    use ExecutionResult as R;
    match result {
        R::Quit
        | R::SessionStop { .. }
        | R::SessionStart { .. }
        | R::SourceEnded { .. }
        | R::Reset { .. } => Ok(16),
        R::Groups { groups } => {
            check_rows(groups.len())?;
            let mut rows = 0;
            for name in groups.keys() {
                rows = add(rows, pod_size(add(name_size(name)?, 16)?)?)?;
            }
            pod_size(rows)
        }
        R::Status { status, .. } => {
            usize_bits(status.owned_nodes)?;
            usize_bits(status.owned_links)?;
            check_rows(status.discarded_by_sink.len())?;
            let mut rows = 0;
            for name in status.discarded_by_sink.keys() {
                rows = add(rows, pod_size(add(name_size(name)?, 16)?)?)?;
            }
            add(64, pod_size(rows)?)
        }
        R::Properties { graph, properties } => {
            check_rows(properties.len())?;
            let graph_size = name_size(graph)?;
            let mut rows = 0;
            for (qualified, value) in properties {
                rows = add(
                    rows,
                    pod_size(add(name_size(qualified)?, scalar_size(value)?)?)?,
                )?;
            }
            add(graph_size, pod_size(rows)?)
        }
        R::PropertyGeneration {
            graph,
            node,
            generation,
        } => add(
            add(name_size(graph)?, name_size(node)?)?,
            generation_size(Some(*generation)),
        ),
        R::ParameterGeneration { graph, node, .. } => {
            add(add(name_size(graph)?, name_size(node)?)?, 32)
        }
        R::GroupState {
            group, observed, ..
        } => add(name_size(group)?, if observed.is_some() { 32 } else { 24 }),
        R::PropertiesSet {
            graph, generations, ..
        } => {
            check_rows(generations.len())?;
            let graph_size = name_size(graph)?;
            let mut rows = 0;
            let mut names = BTreeSet::new();
            for observation in generations {
                let node_size = name_size(&observation.node)?;
                if !names.insert(observation.node.as_str()) {
                    return Err(invalid("duplicate generation node"));
                }
                rows = add(
                    rows,
                    pod_size(add(node_size, generation_size(observation.generation))?)?,
                )?;
            }
            add(add(graph_size, pod_size(rows)?)?, 16)
        }
        R::Parameter {
            graph,
            parameter,
            generation,
        } => add(
            add(name_size(graph)?, name_size(parameter)?)?,
            if generation.is_some() { 56 } else { 24 },
        ),
    }
}

fn base_size(header: &ReplyHeader, kind: ReplyKind) -> Result<usize, ControlError> {
    envelope::encode_reply(kind, header, &[], envelope::ReplyBound::Lifecycle)
        .map(|bytes| bytes.len())
        .map_err(|e| invalid(e.to_string()))
}

/// Checks or encodes the bounded closed runner result.
/// # Errors
/// Rejects invalid headers, result semantics or replies exceeding 64 KiB.
pub fn completion_size(
    header: &ReplyHeader,
    state: LifecycleState,
    result: &ExecutionResult,
) -> Result<usize, ControlError> {
    check_result(header, state, result)?;
    let details = details_size(result)?;
    add(
        base_size(header, ReplyKind::Completion)?,
        add(32, pod_size(details)?)?,
    )
}

/// Checks borrowed result fields before any variable payload is cloned.
/// Checks or encodes the bounded closed runner result.
/// # Errors
/// Rejects invalid headers, result semantics or replies exceeding 64 KiB.
pub fn validate_completion_capacity(
    header: &ReplyHeader,
    state: LifecycleState,
    result: &ExecutionResult,
) -> Result<(), ControlError> {
    completion_size(header, state, result).map(|_| ())
}

fn scalar_pod(value: &ScalarValue) -> Value {
    match value {
        ScalarValue::Bool(value) => Value::Bool(*value),
        ScalarValue::Int(value) => Value::Int(*value),
        ScalarValue::Long(value) => Value::Long(*value),
        ScalarValue::Float(bits) => Value::Float(f32::from_bits(*bits)),
        ScalarValue::Double(bits) => Value::Double(f64::from_bits(*bits)),
        ScalarValue::Id(value) => Value::Id(Id(*value)),
        ScalarValue::String(value) => Value::String(value.clone()),
    }
}

fn optional_long(value: Option<i64>) -> Value {
    value.map_or(Value::None, Value::Long)
}

// Keep the closed operation schemas in one exhaustive match, paired with decoding.
#[allow(clippy::too_many_lines)]
fn details(result: &ExecutionResult) -> Result<Vec<Value>, ControlError> {
    use ExecutionResult as R;
    Ok(match result {
        R::Quit => vec![Value::Bool(true)],
        R::Groups { groups } => vec![Value::Struct(
            groups
                .iter()
                .map(|(name, state)| {
                    Value::Struct(vec![
                        Value::String(name.clone()),
                        Value::Id(Id(group_id(*state))),
                    ])
                })
                .collect(),
        )],
        R::Status { status, .. } => vec![
            Value::Bool(status.running),
            Value::Long(usize_bits(status.owned_nodes)?),
            Value::Long(usize_bits(status.owned_links)?),
            Value::Long(envelope::serial_to_long(status.discarded_buffers)),
            Value::Struct(
                status
                    .discarded_by_sink
                    .iter()
                    .map(|(name, count)| {
                        Value::Struct(vec![
                            Value::String(name.clone()),
                            Value::Long(envelope::serial_to_long(*count)),
                        ])
                    })
                    .collect(),
            ),
        ],
        R::Properties { graph, properties } => vec![
            Value::String(graph.clone()),
            Value::Struct(
                properties
                    .iter()
                    .map(|(name, value)| {
                        Value::Struct(vec![Value::String(name.clone()), scalar_pod(value)])
                    })
                    .collect(),
            ),
        ],
        R::PropertyGeneration {
            graph,
            node,
            generation,
        } => vec![
            Value::String(graph.clone()),
            Value::String(node.clone()),
            Value::Long(generation.requested),
            optional_long(generation.active),
        ],
        R::ParameterGeneration {
            graph,
            node,
            generation,
        } => vec![
            Value::String(graph.clone()),
            Value::String(node.clone()),
            Value::Long(generation.requested),
            Value::Long(generation.active),
        ],
        R::GroupState {
            group,
            requested,
            observed,
        } => vec![
            Value::String(group.clone()),
            Value::Id(Id(group_id(*requested))),
            observed.map_or(Value::None, |state| Value::Id(Id(group_id(state)))),
        ],
        R::SessionStop { state }
        | R::SessionStart { state }
        | R::SourceEnded { state }
        | R::Reset { state } => vec![Value::Id(Id(lifecycle_id(*state)))],
        R::PropertiesSet {
            graph,
            generations,
            active_adoption_observed,
        } => vec![
            Value::String(graph.clone()),
            Value::Struct(
                generations
                    .iter()
                    .map(|observation| {
                        Value::Struct(vec![
                            Value::String(observation.node.clone()),
                            optional_long(observation.generation.map(|g| g.requested)),
                            optional_long(observation.generation.and_then(|g| g.active)),
                        ])
                    })
                    .collect(),
            ),
            Value::Bool(*active_adoption_observed),
        ],
        R::Parameter {
            graph,
            parameter,
            generation,
        } => vec![
            Value::String(graph.clone()),
            Value::String(parameter.clone()),
            generation.map_or(Value::None, |g| {
                Value::Struct(vec![Value::Long(g.requested), Value::Long(g.active)])
            }),
            Value::Bool(false),
        ],
    })
}

/// Checks or encodes the bounded closed runner result.
/// # Errors
/// Rejects invalid headers, result semantics or replies exceeding 64 KiB.
pub fn encode_completion(
    header: &ReplyHeader,
    state: LifecycleState,
    result: &ExecutionResult,
) -> Result<Vec<u8>, ControlError> {
    validate_completion_capacity(header, state, result)?;
    envelope::encode_completion(
        header,
        &[
            Value::Id(Id(lifecycle_id(state))),
            Value::Id(Id(outcome_id(result.outcome()))),
            Value::Struct(details(result)?),
        ],
    )
    .map_err(|e| invalid(e.to_string()))
}

fn error_size(
    header: &ReplyHeader,
    kind: ReplyKind,
    error: &ControlError,
) -> Result<(), ControlError> {
    check_header(header, kind)?;
    if header.result >= 0 {
        return Err(invalid(
            "failed completion/rejection requires a negative result",
        ));
    }
    let body = add(
        add(string_size(&error.field)?, string_size(&error.message)?)?,
        16,
    )?;
    add(base_size(header, kind)?, body)?;
    Ok(())
}

fn encode_error(
    header: &ReplyHeader,
    kind: ReplyKind,
    state: LifecycleState,
    error: &ControlError,
) -> Result<Vec<u8>, ControlError> {
    error_size(header, kind, error)?;
    envelope::encode_reply(
        kind,
        header,
        &[
            Value::String(error.field.clone()),
            Value::String(error.message.clone()),
            Value::Id(Id(lifecycle_id(state))),
        ],
        envelope::ReplyBound::Lifecycle,
    )
    .map_err(|e| invalid(e.to_string()))
}

/// Checks or encodes the bounded closed runner result.
/// # Errors
/// Rejects invalid headers, result semantics or replies exceeding 64 KiB.
pub fn encode_failed_completion(
    header: &ReplyHeader,
    state: LifecycleState,
    error: &ControlError,
) -> Result<Vec<u8>, ControlError> {
    encode_error(header, ReplyKind::Completion, state, error)
}

/// Checks or encodes the bounded closed runner result.
/// # Errors
/// Rejects invalid headers, result semantics or replies exceeding 64 KiB.
pub fn encode_rejection(
    header: &ReplyHeader,
    state: LifecycleState,
    error: &ControlError,
) -> Result<Vec<u8>, ControlError> {
    encode_error(header, ReplyKind::Rejection, state, error)
}

fn scalar(value: &Value) -> Result<ScalarValue, ControlError> {
    Ok(match value {
        Value::Bool(value) => ScalarValue::Bool(*value),
        Value::Int(value) => ScalarValue::Int(*value),
        Value::Long(value) => ScalarValue::Long(*value),
        Value::Float(value) => ScalarValue::Float(value.to_bits()),
        Value::Double(value) => ScalarValue::Double(value.to_bits()),
        Value::Id(Id(value)) => ScalarValue::Id(*value),
        Value::String(value) => {
            string_size(value)?;
            ScalarValue::String(value.clone())
        }
        _ => return Err(invalid("snapshot property must be a native scalar")),
    })
}

fn optional_i64(value: &Value) -> Result<Option<i64>, ControlError> {
    match value {
        Value::None => Ok(None),
        Value::Long(value) => Ok(Some(*value)),
        _ => Err(invalid("optional generation must be Long or None")),
    }
}

fn usize_count(value: i64) -> Result<usize, ControlError> {
    usize::try_from(envelope::serial_from_long(value))
        .map_err(|_| invalid("owned object count exceeds usize"))
}

// Decode only the closed operation-specific schema. The common decoder has
// already bounded bytes, nesting, native strings and owned-tree construction.
#[allow(clippy::too_many_lines)]
fn decode_details(
    operation: Operation,
    fields: &[Value],
    state: LifecycleState,
) -> Result<ExecutionResult, ControlError> {
    use Operation as O;
    Ok(match (operation, fields) {
        (O::Quit, [Value::Bool(true)]) => ExecutionResult::Quit,
        (O::Groups, [Value::Struct(rows)]) => {
            check_rows(rows.len())?;
            let mut groups = BTreeMap::new();
            for row in rows {
                let Value::Struct(fields) = row else {
                    return Err(invalid("group row must be Struct"));
                };
                let [Value::String(key), Value::Id(Id(value))] = fields.as_slice() else {
                    return Err(invalid("invalid group row"));
                };
                if groups.insert(name(key)?, group(*value)?).is_some() {
                    return Err(invalid("duplicate group"));
                }
            }
            ExecutionResult::Groups { groups }
        }
        (
            O::Status,
            [Value::Bool(running), Value::Long(nodes), Value::Long(links), Value::Long(discard), Value::Struct(rows)],
        ) => {
            check_rows(rows.len())?;
            let mut discarded_by_sink = BTreeMap::new();
            for row in rows {
                let Value::Struct(fields) = row else {
                    return Err(invalid("sink row must be Struct"));
                };
                let [Value::String(key), Value::Long(value)] = fields.as_slice() else {
                    return Err(invalid("invalid sink row"));
                };
                if discarded_by_sink
                    .insert(name(key)?, envelope::serial_from_long(*value))
                    .is_some()
                {
                    return Err(invalid("duplicate sink"));
                }
            }
            ExecutionResult::Status {
                lifecycle_state: state,
                status: LiveGraphStatus {
                    running: *running,
                    owned_nodes: usize_count(*nodes)?,
                    owned_links: usize_count(*links)?,
                    discarded_buffers: envelope::serial_from_long(*discard),
                    discarded_by_sink,
                },
            }
        }
        (O::Properties, [Value::String(graph), Value::Struct(rows)]) => {
            check_rows(rows.len())?;
            let mut properties = BTreeMap::new();
            for row in rows {
                let Value::Struct(fields) = row else {
                    return Err(invalid("property row must be Struct"));
                };
                let [Value::String(key), value] = fields.as_slice() else {
                    return Err(invalid("invalid property row"));
                };
                if properties.insert(name(key)?, scalar(value)?).is_some() {
                    return Err(invalid("duplicate property"));
                }
            }
            ExecutionResult::Properties {
                graph: name(graph)?,
                properties,
            }
        }
        (
            O::PropertyGeneration,
            [Value::String(graph), Value::String(node), Value::Long(requested), active],
        ) => ExecutionResult::PropertyGeneration {
            graph: name(graph)?,
            node: name(node)?,
            generation: PropertyGeneration {
                requested: *requested,
                active: optional_i64(active)?,
            },
        },
        (
            O::ParameterGeneration,
            [Value::String(graph), Value::String(node), Value::Long(requested), Value::Long(active)],
        ) => ExecutionResult::ParameterGeneration {
            graph: name(graph)?,
            node: name(node)?,
            generation: ParameterGeneration {
                requested: *requested,
                active: *active,
            },
        },
        (
            O::StopGroup | O::StartGroup,
            [Value::String(key), Value::Id(Id(requested)), observed],
        ) => {
            let observed = match observed {
                Value::None => None,
                Value::Id(Id(value)) => Some(group(*value)?),
                _ => return Err(invalid("observed group must be Id or None")),
            };
            ExecutionResult::GroupState {
                group: name(key)?,
                requested: group(*requested)?,
                observed,
            }
        }
        (O::SessionStop, [Value::Id(Id(value))]) => ExecutionResult::SessionStop {
            state: lifecycle(*value)?,
        },
        (O::SessionStart, [Value::Id(Id(value))]) => ExecutionResult::SessionStart {
            state: lifecycle(*value)?,
        },
        (O::SourceEnded, [Value::Id(Id(value))]) => ExecutionResult::SourceEnded {
            state: lifecycle(*value)?,
        },
        (O::Reset, [Value::Id(Id(value))]) => ExecutionResult::Reset {
            state: lifecycle(*value)?,
        },
        (
            O::PropertiesSet,
            [Value::String(graph), Value::Struct(rows), Value::Bool(active_adoption_observed)],
        ) => {
            check_rows(rows.len())?;
            let mut names = BTreeSet::new();
            let mut generations = Vec::with_capacity(rows.len());
            for row in rows {
                let Value::Struct(fields) = row else {
                    return Err(invalid("generation row must be Struct"));
                };
                let [Value::String(node), requested, active] = fields.as_slice() else {
                    return Err(invalid("invalid generation row"));
                };
                if !names.insert(node.as_str()) {
                    return Err(invalid("duplicate generation node"));
                }
                let generation = match (optional_i64(requested)?, optional_i64(active)?) {
                    (None, None) => None,
                    (Some(requested), active) => Some(PropertyGeneration { requested, active }),
                    (None, Some(_)) => return Err(invalid("partial absent generation")),
                };
                generations.push(PropertyGenerationObservation {
                    node: name(node)?,
                    generation,
                });
            }
            ExecutionResult::PropertiesSet {
                graph: name(graph)?,
                generations,
                active_adoption_observed: *active_adoption_observed,
            }
        }
        (
            O::Parameter,
            [Value::String(graph), Value::String(parameter), generation, Value::Bool(false)],
        ) => {
            let generation = match generation {
                Value::None => None,
                Value::Struct(fields) => {
                    let [Value::Long(requested), Value::Long(active)] = fields.as_slice() else {
                        return Err(invalid("invalid parameter observation"));
                    };
                    Some(ParameterGeneration {
                        requested: *requested,
                        active: *active,
                    })
                }
                _ => return Err(invalid("parameter observation must be Struct or None")),
            };
            ExecutionResult::Parameter {
                graph: name(graph)?,
                parameter: name(parameter)?,
                generation,
            }
        }
        _ => return Err(invalid("operation details have wrong arity/types/values")),
    })
}

fn decode_error(fields: &[Value]) -> Result<(LifecycleState, ControlError), ControlError> {
    let [Value::String(field), Value::String(message), Value::Id(Id(value))] = fields else {
        return Err(invalid(
            "error payload requires field, message and lifecycle",
        ));
    };
    string_size(field)?;
    string_size(message)?;
    Ok((
        lifecycle(*value)?,
        ControlError::new(field.clone(), message.clone()),
    ))
}

/// Checks or encodes the bounded closed runner result.
/// # Errors
/// Rejects invalid headers, result semantics or replies exceeding 64 KiB.
pub fn decode_completion(bytes: &[u8]) -> Result<Completion, ControlError> {
    let reply = envelope::decode_completion(bytes).map_err(|e| invalid(e.to_string()))?;
    check_header(&reply.header, ReplyKind::Completion)?;
    if reply.header.result < 0 {
        let (state, error) = decode_error(&reply.payload)?;
        return Ok(Completion {
            header: reply.header,
            lifecycle: state,
            result: Err(error),
        });
    }
    let [Value::Id(Id(state)), Value::Id(Id(observed_outcome)), Value::Struct(fields)] =
        reply.payload.as_slice()
    else {
        return Err(invalid(
            "success payload requires lifecycle, outcome and details",
        ));
    };
    let state = lifecycle(*state)?;
    let result = decode_details(Operation::try_from(reply.header.operation)?, fields, state)?;
    if result.outcome() != outcome(*observed_outcome)? {
        return Err(invalid("outcome differs from typed result"));
    }
    check_result(&reply.header, state, &result)?;
    Ok(Completion {
        header: reply.header,
        lifecycle: state,
        result: Ok(result),
    })
}

/// Checks or encodes the bounded closed runner result.
/// # Errors
/// Rejects invalid headers, result semantics or replies exceeding 64 KiB.
pub fn decode_rejection(bytes: &[u8]) -> Result<Rejection, ControlError> {
    let reply = envelope::decode_rejection(bytes).map_err(|e| invalid(e.to_string()))?;
    let (state, error) = decode_error(&reply.payload)?;
    Ok(Rejection {
        header: reply.header,
        lifecycle: state,
        error,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use envelope::ControllerIdentity;

    fn header(operation: Operation) -> ReplyHeader {
        ReplyHeader {
            version: 1,
            endpoint_instance: 23,
            controller: ControllerIdentity {
                global_id: 17,
                serial: u64::MAX,
                instance: 3,
            },
            token: 1,
            operation: operation as u32,
            result: 0,
        }
    }

    fn raw(operation: Operation, state: u32, outcome: u32, fields: Vec<Value>) -> Vec<u8> {
        envelope::encode_completion(
            &header(operation),
            &[
                Value::Id(Id(state)),
                Value::Id(Id(outcome)),
                Value::Struct(fields),
            ],
        )
        .unwrap()
    }

    fn properties() -> ExecutionResult {
        ExecutionResult::Properties {
            graph: "g".into(),
            properties: [
                ("n:b".into(), ScalarValue::Bool(false)),
                ("n:i".into(), ScalarValue::Int(i32::MIN)),
                ("n:l".into(), ScalarValue::Long(i64::MIN)),
                ("n:f".into(), ScalarValue::Float(u32::MAX)),
                ("n:d".into(), ScalarValue::Double(u64::MAX)),
                ("n:id".into(), ScalarValue::Id(u32::MAX)),
                ("n:s".into(), ScalarValue::String("λ\n\"\\".into())),
            ]
            .into(),
        }
    }

    fn status(state: LifecycleState) -> ExecutionResult {
        ExecutionResult::Status {
            lifecycle_state: state,
            status: LiveGraphStatus {
                running: true,
                owned_nodes: usize::MAX,
                owned_links: usize::MAX,
                discarded_buffers: u64::MAX,
                discarded_by_sink: [("a".into(), u64::MAX), ("b".into(), 1_u64 << 63)].into(),
            },
        }
    }

    // Keep the complete closed operation table together for exhaustive tests.
    #[allow(clippy::too_many_lines)]
    fn fixtures() -> Vec<(Operation, LifecycleState, ExecutionResult)> {
        use ExecutionResult as R;
        use LifecycleState::{Ready, Running};
        use Operation as O;
        vec![
            (O::Quit, Ready, R::Quit),
            (
                O::Groups,
                Ready,
                R::Groups {
                    groups: [
                        ("a".into(), ExecutionGroupState::Stopped),
                        ("b".into(), ExecutionGroupState::Running),
                    ]
                    .into(),
                },
            ),
            (O::Status, Running, status(Running)),
            (O::Properties, Ready, properties()),
            (
                O::PropertyGeneration,
                Ready,
                R::PropertyGeneration {
                    graph: "g".into(),
                    node: "n".into(),
                    generation: PropertyGeneration {
                        requested: i64::MAX,
                        active: None,
                    },
                },
            ),
            (
                O::ParameterGeneration,
                Ready,
                R::ParameterGeneration {
                    graph: "g".into(),
                    node: "n".into(),
                    generation: ParameterGeneration {
                        requested: i64::MIN,
                        active: i64::MAX,
                    },
                },
            ),
            (
                O::StopGroup,
                Running,
                R::GroupState {
                    group: "g".into(),
                    requested: ExecutionGroupState::Stopped,
                    observed: None,
                },
            ),
            (
                O::StartGroup,
                Running,
                R::GroupState {
                    group: "g".into(),
                    requested: ExecutionGroupState::Running,
                    observed: Some(ExecutionGroupState::Stopped),
                },
            ),
            (O::SessionStop, Ready, R::SessionStop { state: Ready }),
            (O::SessionStart, Running, R::SessionStart { state: Running }),
            (O::SourceEnded, Ready, R::SourceEnded { state: Ready }),
            (O::Reset, Ready, R::Reset { state: Ready }),
            (
                O::PropertiesSet,
                Ready,
                R::PropertiesSet {
                    graph: "g".into(),
                    generations: vec![
                        PropertyGenerationObservation {
                            node: "a".into(),
                            generation: None,
                        },
                        PropertyGenerationObservation {
                            node: "b".into(),
                            generation: Some(PropertyGeneration {
                                requested: i64::MAX,
                                active: None,
                            }),
                        },
                        PropertyGenerationObservation {
                            node: "c".into(),
                            generation: Some(PropertyGeneration {
                                requested: 10,
                                active: Some(9),
                            }),
                        },
                    ],
                    active_adoption_observed: false,
                },
            ),
            (
                O::Parameter,
                Ready,
                R::Parameter {
                    graph: "g".into(),
                    parameter: "n:p".into(),
                    generation: None,
                },
            ),
        ]
    }

    fn roundtrip(operation: Operation, state: LifecycleState, result: ExecutionResult) {
        let header = header(operation);
        let size = completion_size(&header, state, &result).unwrap();
        validate_completion_capacity(&header, state, &result).unwrap();
        let bytes = encode_completion(&header, state, &result).unwrap();
        assert_eq!(bytes.len(), size);
        assert_eq!(
            decode_completion(&bytes).unwrap(),
            Completion {
                header,
                lifecycle: state,
                result: Ok(result)
            }
        );
    }

    #[test]
    fn every_successful_operation_round_trips_exact_typed_results() {
        for (operation, state, result) in fixtures() {
            roundtrip(operation, state, result);
        }
    }

    #[test]
    fn optional_generation_shapes_round_trip() {
        use ExecutionResult as R;
        let state = LifecycleState::Running;
        for active in [None, Some(i64::MIN)] {
            roundtrip(
                Operation::PropertyGeneration,
                state,
                R::PropertyGeneration {
                    graph: "g".into(),
                    node: "n".into(),
                    generation: PropertyGeneration {
                        requested: i64::MAX,
                        active,
                    },
                },
            );
        }
        for requested in [ExecutionGroupState::Stopped, ExecutionGroupState::Running] {
            let operation = if requested == ExecutionGroupState::Stopped {
                Operation::StopGroup
            } else {
                Operation::StartGroup
            };
            for observed in [
                None,
                Some(ExecutionGroupState::Stopped),
                Some(ExecutionGroupState::Running),
            ] {
                roundtrip(
                    operation,
                    state,
                    R::GroupState {
                        group: "g".into(),
                        requested,
                        observed,
                    },
                );
            }
        }
        for generation in [
            None,
            Some(ParameterGeneration {
                requested: i64::MIN,
                active: i64::MAX,
            }),
        ] {
            roundtrip(
                Operation::Parameter,
                state,
                R::Parameter {
                    graph: "g".into(),
                    parameter: "n:p".into(),
                    generation,
                },
            );
        }
        for active in [false, true] {
            roundtrip(
                Operation::PropertiesSet,
                state,
                R::PropertiesSet {
                    graph: "g".into(),
                    generations: vec![PropertyGenerationObservation {
                        node: "n".into(),
                        generation: Some(PropertyGeneration {
                            requested: 9,
                            active: Some(9),
                        }),
                    }],
                    active_adoption_observed: active,
                },
            );
        }
    }

    #[test]
    fn empty_catalog_shapes_round_trip() {
        use ExecutionResult as R;
        let state = LifecycleState::Running;
        for (op, result) in [
            (
                Operation::Groups,
                R::Groups {
                    groups: BTreeMap::new(),
                },
            ),
            (
                Operation::Status,
                R::Status {
                    lifecycle_state: state,
                    status: LiveGraphStatus::default(),
                },
            ),
            (
                Operation::Properties,
                R::Properties {
                    graph: "g".into(),
                    properties: BTreeMap::new(),
                },
            ),
            (
                Operation::PropertiesSet,
                R::PropertiesSet {
                    graph: "g".into(),
                    generations: vec![],
                    active_adoption_observed: false,
                },
            ),
        ] {
            roundtrip(op, state, result);
        }
    }

    #[test]
    fn active_property_reply_requires_the_existing_producer_conditions() {
        let coherent = PropertyGenerationObservation {
            node: "n".into(),
            generation: Some(PropertyGeneration {
                requested: 9,
                active: Some(9),
            }),
        };
        for (state, generations) in [
            (LifecycleState::Ready, vec![coherent.clone()]),
            (LifecycleState::Running, vec![]),
            (
                LifecycleState::Running,
                vec![PropertyGenerationObservation {
                    node: "n".into(),
                    generation: None,
                }],
            ),
            (
                LifecycleState::Running,
                vec![PropertyGenerationObservation {
                    node: "n".into(),
                    generation: Some(PropertyGeneration {
                        requested: 9,
                        active: None,
                    }),
                }],
            ),
            (
                LifecycleState::Running,
                vec![PropertyGenerationObservation {
                    node: "n".into(),
                    generation: Some(PropertyGeneration {
                        requested: 9,
                        active: Some(8),
                    }),
                }],
            ),
        ] {
            let result = ExecutionResult::PropertiesSet {
                graph: "g".into(),
                generations,
                active_adoption_observed: true,
            };
            assert!(encode_completion(&header(Operation::PropertiesSet), state, &result).is_err());
            assert!(decode_completion(&raw(
                Operation::PropertiesSet,
                lifecycle_id(state),
                5,
                details(&result).unwrap()
            ))
            .is_err());
        }
        roundtrip(
            Operation::PropertiesSet,
            LifecycleState::Ready,
            ExecutionResult::PropertiesSet {
                graph: "g".into(),
                generations: vec![coherent],
                active_adoption_observed: false,
            },
        );
    }

    #[test]
    fn snapshots_preserve_all_float_and_double_bits_including_nan() {
        for bits in [
            0,
            1,
            (-0.0_f32).to_bits(),
            f32::INFINITY.to_bits(),
            f32::NEG_INFINITY.to_bits(),
            0x7fc0_1234,
            0x7f80_0001,
            u32::MAX,
        ] {
            roundtrip(
                Operation::Properties,
                LifecycleState::Ready,
                ExecutionResult::Properties {
                    graph: "g".into(),
                    properties: [("n:f".into(), ScalarValue::Float(bits))].into(),
                },
            );
        }
        for bits in [
            0,
            1,
            (-0.0_f64).to_bits(),
            f64::INFINITY.to_bits(),
            f64::NEG_INFINITY.to_bits(),
            0x7ff8_0000_0000_1234,
            0x7ff0_0000_0000_0001,
            u64::MAX,
        ] {
            roundtrip(
                Operation::Properties,
                LifecycleState::Ready,
                ExecutionResult::Properties {
                    graph: "g".into(),
                    properties: [("n:d".into(), ScalarValue::Double(bits))].into(),
                },
            );
        }
    }

    #[test]
    fn every_lifecycle_and_unsigned_counter_boundary_round_trips() {
        for state in [
            LifecycleState::Offline,
            LifecycleState::Configuring,
            LifecycleState::Ready,
            LifecycleState::Running,
            LifecycleState::Fault,
        ] {
            roundtrip(Operation::Status, state, status(state));
        }
        for count in [0, i64::MAX as u64, 1_u64 << 63, u64::MAX] {
            roundtrip(
                Operation::Status,
                LifecycleState::Ready,
                ExecutionResult::Status {
                    lifecycle_state: LifecycleState::Ready,
                    status: LiveGraphStatus {
                        discarded_buffers: count,
                        discarded_by_sink: [("sink".into(), count)].into(),
                        ..LiveGraphStatus::default()
                    },
                },
            );
        }
        if usize::BITS < 64 {
            assert!(usize_count(-1).is_err());
        } else {
            assert_eq!(usize_count(-1).unwrap(), usize::MAX);
        }
    }

    #[test]
    fn failed_terminal_completion_and_admission_rejection_remain_distinct() {
        let error = ControlError::new("lifecycle.dispatch", "unknown outcome\nλ");
        for (operation, _, _) in fixtures() {
            let header = ReplyHeader {
                result: -22,
                ..header(operation)
            };
            let bytes = encode_failed_completion(&header, LifecycleState::Fault, &error).unwrap();
            assert_eq!(
                decode_completion(&bytes).unwrap(),
                Completion {
                    header,
                    lifecycle: LifecycleState::Fault,
                    result: Err(error.clone())
                }
            );
            assert!(decode_rejection(&bytes).is_err());
            let bytes = encode_rejection(&header, LifecycleState::Ready, &error).unwrap();
            assert_eq!(
                decode_rejection(&bytes).unwrap(),
                Rejection {
                    header,
                    lifecycle: LifecycleState::Ready,
                    error: error.clone()
                }
            );
            assert!(decode_completion(&bytes).is_err());
        }
        let header = ReplyHeader {
            operation: 99,
            result: -22,
            ..header(Operation::Quit)
        };
        assert!(encode_failed_completion(&header, LifecycleState::Ready, &error).is_err());
        assert_eq!(
            decode_rejection(&encode_rejection(&header, LifecycleState::Ready, &error).unwrap())
                .unwrap()
                .header
                .operation,
            99
        );
        let sentinel = ReplyHeader {
            controller: ControllerIdentity {
                global_id: 0,
                serial: 0,
                instance: 0,
            },
            token: 0,
            operation: 0,
            result: -22,
            ..header
        };
        assert!(encode_rejection(&sentinel, LifecycleState::Ready, &error).is_ok());
        assert!(encode_failed_completion(&sentinel, LifecycleState::Ready, &error).is_err());
        for result in [0, 1] {
            let invalid = ReplyHeader { result, ..header };
            assert!(encode_rejection(&invalid, LifecycleState::Ready, &error).is_err());
            assert!(encode_failed_completion(&invalid, LifecycleState::Ready, &error).is_err());
        }
    }

    #[test]
    fn exact_operation_outcome_lifecycle_and_arity_are_required() {
        for (operation, state, result) in fixtures() {
            let fields = details(&result).unwrap();
            let state_id = lifecycle_id(state);
            let outcome = outcome_id(result.outcome());
            for bad in [0, 6, u32::MAX] {
                assert!(decode_completion(&raw(operation, bad, outcome, fields.clone())).is_err());
            }
            for bad in [0, 7, u32::MAX] {
                assert!(decode_completion(&raw(operation, state_id, bad, fields.clone())).is_err());
            }
            let wrong = if outcome == 1 { 2 } else { 1 };
            assert!(decode_completion(&raw(operation, state_id, wrong, fields.clone())).is_err());
            let mut extra = fields.clone();
            extra.push(Value::None);
            assert!(decode_completion(&raw(operation, state_id, outcome, extra)).is_err());
            let mut missing = fields.clone();
            missing.pop();
            assert!(decode_completion(&raw(operation, state_id, outcome, missing)).is_err());
            for i in 0..fields.len() {
                let mut wrong_type = fields.clone();
                wrong_type[i] = Value::Bytes(vec![]);
                assert!(decode_completion(&raw(operation, state_id, outcome, wrong_type)).is_err());
            }
            let wrong_header = ReplyHeader {
                operation: if operation == Operation::Quit { 2 } else { 1 },
                ..header(operation)
            };
            assert!(encode_completion(&wrong_header, state, &result).is_err());
            assert!(encode_completion(
                &ReplyHeader {
                    result: -22,
                    ..header(operation)
                },
                state,
                &result
            )
            .is_err());
        }
        assert!(decode_completion(&raw(Operation::Quit, 3, 1, vec![Value::Bool(false)])).is_err());
        assert!(decode_completion(&raw(
            Operation::StopGroup,
            4,
            3,
            vec![Value::String("g".into()), Value::Id(Id(2)), Value::None]
        ))
        .is_err());
        assert!(decode_completion(&raw(
            Operation::StartGroup,
            4,
            3,
            vec![
                Value::String("g".into()),
                Value::Id(Id(2)),
                Value::Id(Id(3))
            ]
        ))
        .is_err());
        assert!(
            decode_completion(&raw(Operation::SessionStart, 3, 4, vec![Value::Id(Id(3))])).is_err()
        );
        assert!(decode_completion(&raw(Operation::Reset, 3, 4, vec![Value::Id(Id(4))])).is_err());
        assert!(encode_completion(
            &header(Operation::Status),
            LifecycleState::Ready,
            &status(LifecycleState::Running)
        )
        .is_err());
    }

    #[test]
    fn duplicate_catalogs_and_invalid_scalar_rows_are_rejected() {
        let group_row = Value::Struct(vec![Value::String("g".into()), Value::Id(Id(1))]);
        assert!(decode_completion(&raw(
            Operation::Groups,
            3,
            2,
            vec![Value::Struct(vec![group_row.clone(), group_row])]
        ))
        .is_err());
        let sink_row = Value::Struct(vec![Value::String("sink".into()), Value::Long(-1)]);
        assert!(decode_completion(&raw(
            Operation::Status,
            3,
            2,
            vec![
                Value::Bool(false),
                Value::Long(0),
                Value::Long(0),
                Value::Long(0),
                Value::Struct(vec![sink_row.clone(), sink_row])
            ]
        ))
        .is_err());
        let property_row = Value::Struct(vec![Value::String("n:p".into()), Value::Int(1)]);
        assert!(decode_completion(&raw(
            Operation::Properties,
            3,
            2,
            vec![
                Value::String("g".into()),
                Value::Struct(vec![property_row.clone(), property_row])
            ]
        ))
        .is_err());
        for value in [Value::None, Value::Bytes(vec![]), Value::Struct(vec![])] {
            assert!(decode_completion(&raw(
                Operation::Properties,
                3,
                2,
                vec![
                    Value::String("g".into()),
                    Value::Struct(vec![Value::Struct(vec![
                        Value::String("n:p".into()),
                        value
                    ])])
                ]
            ))
            .is_err());
        }
    }

    #[test]
    fn partial_generations_and_duplicate_observations_are_rejected() {
        for (requested, active) in [
            (Value::None, Value::Long(1)),
            (Value::Int(1), Value::None),
            (Value::Long(1), Value::Bool(false)),
        ] {
            assert!(decode_completion(&raw(
                Operation::PropertiesSet,
                3,
                6,
                vec![
                    Value::String("g".into()),
                    Value::Struct(vec![Value::Struct(vec![
                        Value::String("n".into()),
                        requested,
                        active
                    ])]),
                    Value::Bool(false)
                ]
            ))
            .is_err());
        }
        let observation = Value::Struct(vec![Value::String("n".into()), Value::None, Value::None]);
        assert!(decode_completion(&raw(
            Operation::PropertiesSet,
            3,
            6,
            vec![
                Value::String("g".into()),
                Value::Struct(vec![observation.clone(), observation]),
                Value::Bool(false)
            ]
        ))
        .is_err());
        let duplicate = PropertyGenerationObservation {
            node: "n".into(),
            generation: None,
        };
        assert!(validate_completion_capacity(
            &header(Operation::PropertiesSet),
            LifecycleState::Ready,
            &ExecutionResult::PropertiesSet {
                graph: "g".into(),
                generations: vec![duplicate.clone(), duplicate],
                active_adoption_observed: false
            }
        )
        .is_err());
        for observation in [
            Value::Long(1),
            Value::Struct(vec![Value::Long(1), Value::None]),
            Value::Struct(vec![Value::Long(1), Value::Long(1), Value::None]),
        ] {
            assert!(decode_completion(&raw(
                Operation::Parameter,
                3,
                6,
                vec![
                    Value::String("g".into()),
                    Value::String("n:p".into()),
                    observation,
                    Value::Bool(false)
                ]
            ))
            .is_err());
        }
        assert!(decode_completion(&raw(
            Operation::Parameter,
            3,
            6,
            vec![
                Value::String("g".into()),
                Value::String("n:p".into()),
                Value::None,
                Value::Bool(true)
            ]
        ))
        .is_err());
    }

    #[test]
    fn exact_borrowed_capacity_matches_common_encoder_at_padding_boundary() {
        let header = header(Operation::Properties);
        let base = base_size(&header, ReplyKind::Completion).unwrap();
        let mut largest = None;
        let mut rejected = false;
        for length in (BOUND - base - 120)..=(BOUND - base - 72) {
            let result = ExecutionResult::Properties {
                graph: "g".into(),
                properties: [("n:s".into(), ScalarValue::String("x".repeat(length)))].into(),
            };
            let expected = envelope::encode_completion(
                &header,
                &[
                    Value::Id(Id(3)),
                    Value::Id(Id(2)),
                    Value::Struct(details(&result).unwrap()),
                ],
            );
            match (
                encode_completion(&header, LifecycleState::Ready, &result),
                expected,
            ) {
                (Ok(actual), Ok(expected)) => {
                    assert_eq!(actual, expected);
                    assert_eq!(
                        actual.len(),
                        completion_size(&header, LifecycleState::Ready, &result).unwrap()
                    );
                    largest = Some(actual.len());
                }
                (Err(_), Err(_)) => {
                    assert!(
                        validate_completion_capacity(&header, LifecycleState::Ready, &result)
                            .is_err()
                    );
                    rejected = true;
                }
                _ => panic!("borrowed size differs from public serializer at length {length}"),
            }
        }
        assert_eq!(largest, Some(BOUND));
        assert!(rejected);
    }

    #[test]
    fn oversized_borrowed_data_is_rejected_before_payload_construction() {
        let result = ExecutionResult::Properties {
            graph: "g".into(),
            properties: [("n:s".into(), ScalarValue::String("x".repeat(1024 * 1024)))].into(),
        };
        assert!(validate_completion_capacity(
            &header(Operation::Properties),
            LifecycleState::Ready,
            &result
        )
        .is_err());
        let result = ExecutionResult::PropertiesSet {
            graph: "g".into(),
            generations: vec![
                PropertyGenerationObservation {
                    node: String::new(),
                    generation: None
                };
                BOUND / MIN_ROW_BYTES + 1
            ],
            active_adoption_observed: false,
        };
        assert_eq!(
            validate_completion_capacity(
                &header(Operation::PropertiesSet),
                LifecycleState::Ready,
                &result
            )
            .unwrap_err()
            .message,
            "catalog cannot fit the reply envelope"
        );
        let result = ExecutionResult::Properties {
            graph: "g".into(),
            properties: [("n:s".into(), ScalarValue::String("a\0b".into()))].into(),
        };
        assert!(encode_completion(
            &header(Operation::Properties),
            LifecycleState::Ready,
            &result
        )
        .is_err());
        let error = ControlError::new("field", "x".repeat(1024 * 1024));
        let negative = ReplyHeader {
            result: -22,
            ..header(Operation::Quit)
        };
        assert!(encode_failed_completion(&negative, LifecycleState::Ready, &error).is_err());
        assert!(encode_rejection(&negative, LifecycleState::Ready, &error).is_err());
        assert!(add(usize::MAX, 1).is_err());
        assert!(pod_size(usize::MAX).is_err());
    }

    #[test]
    fn header_sentinel_truncation_trailing_bytes_and_wrong_error_shapes_reject() {
        let good = encode_completion(
            &header(Operation::Quit),
            LifecycleState::Ready,
            &ExecutionResult::Quit,
        )
        .unwrap();
        for length in 0..good.len() {
            assert!(
                decode_completion(&good[..length]).is_err(),
                "prefix {length}"
            );
        }
        let mut extra = good;
        extra.extend_from_slice(&[0; 8]);
        assert!(decode_completion(&extra).is_err());
        let sentinel = ReplyHeader {
            controller: ControllerIdentity {
                global_id: 0,
                serial: 0,
                instance: 0,
            },
            token: 0,
            operation: 0,
            ..header(Operation::Quit)
        };
        let initial = envelope::encode_completion(
            &sentinel,
            &[
                Value::Id(Id(3)),
                Value::Id(Id(1)),
                Value::Struct(vec![Value::Bool(true)]),
            ],
        )
        .unwrap();
        assert!(decode_completion(&initial).is_err());
        let negative = ReplyHeader {
            result: -22,
            ..header(Operation::Quit)
        };
        let wrong = envelope::encode_completion(
            &negative,
            &[
                Value::Id(Id(3)),
                Value::Id(Id(1)),
                Value::Struct(vec![Value::Bool(true)]),
            ],
        )
        .unwrap();
        assert!(decode_completion(&wrong).is_err());
        for payload in [
            vec![Value::String("f".into()), Value::String("m".into())],
            vec![
                Value::String("f".into()),
                Value::String("m".into()),
                Value::Id(Id(0)),
            ],
            vec![Value::String("f".into()), Value::Int(1), Value::Id(Id(3))],
        ] {
            assert!(
                decode_rejection(&envelope::encode_rejection(&negative, &payload).unwrap())
                    .is_err()
            );
        }
    }
}
