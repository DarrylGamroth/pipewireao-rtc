//! Typed session completion and rejection encoding.
//! Native results preserve domain types and scalar bits; no JSON conversion occurs.

use crate::control::envelope::{self as envelope, ReplyHeader, ReplyKind};
use crate::control::{ControlError, ExecutionResult, Outcome, PropertyGenerationObservation};
use crate::session::requests::Operation;
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
#[path = "tests/replies.rs"]
mod tests;
