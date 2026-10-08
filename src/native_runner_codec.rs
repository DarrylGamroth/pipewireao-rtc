//! Exact cold runner request profile; see `docs/NATIVE_RUNNER_CONTROL.md`.
//!
//! Decoding does not admit a caller, open artifacts, or execute a lifecycle effect.
//! The production endpoint must establish those boundaries separately.

use crate::control::{expected_parameter_bytes, Command, ControlError, MAX_PARAMETER_BYTES};
pub use crate::control_dto::Operation;
use crate::native_control_codec::{self as envelope, RequestHeader};
use crate::ScalarValue;
use pipewire::spa::pod::{Value, ValueArray};
use pipewire::spa::utils::Id;
use std::collections::BTreeMap;
use std::path::PathBuf;

pub const PROFILE: &str = "pipewireao.rtc.runner/1";
// The existing CLI admits 128 fields: command, graph and three per property.
const MAX_PROPERTIES: usize = (crate::control::MAX_ARGUMENTS - 2) / 3;

fn invalid(message: impl Into<String>) -> ControlError {
    ControlError::new("native.runner.request", message)
}

fn name(value: &str) -> Result<&str, ControlError> {
    if value.is_empty() || value.len() > envelope::REQUEST_BOUND || value.contains('\0') {
        return Err(invalid("target name must be nonempty and contain no NUL"));
    }
    Ok(value)
}

fn scalar(value: &Value) -> Result<ScalarValue, ControlError> {
    Ok(match value {
        Value::Bool(value) => ScalarValue::Bool(*value),
        Value::Int(value) => ScalarValue::Int(*value),
        Value::Long(value) => ScalarValue::Long(*value),
        Value::Float(value) if value.is_finite() => ScalarValue::float(*value),
        Value::Double(value) if value.is_finite() => ScalarValue::double(*value),
        Value::Id(Id(value)) => ScalarValue::Id(*value),
        Value::String(value) if !value.contains('\0') => ScalarValue::String(value.clone()),
        _ => {
            return Err(invalid(
                "property must be an admitted scalar; floats must be finite",
            ))
        }
    })
}

fn scalar_pod(value: &ScalarValue) -> Result<Value, ControlError> {
    let result = match value {
        ScalarValue::Bool(value) => Value::Bool(*value),
        ScalarValue::Int(value) => Value::Int(*value),
        ScalarValue::Long(value) => Value::Long(*value),
        ScalarValue::Float(bits) => Value::Float(f32::from_bits(*bits)),
        ScalarValue::Double(bits) => Value::Double(f64::from_bits(*bits)),
        ScalarValue::Id(value) => Value::Id(Id(*value)),
        ScalarValue::String(value) => Value::String(value.clone()),
    };
    scalar(&result)?;
    Ok(result)
}

fn parameter_extent(element_type: &str, shape: &[u32]) -> Result<(), ControlError> {
    if shape.len() > envelope::REQUEST_BOUND / 4 {
        return Err(invalid(
            "parameter dimensions cannot fit the request envelope",
        ));
    }
    if shape.is_empty() || shape.contains(&0) {
        return Err(invalid(
            "parameter dimensions must be nonempty and positive",
        ));
    }
    let bytes = expected_parameter_bytes(element_type, shape)?;
    if bytes > MAX_PARAMETER_BYTES {
        return Err(invalid(
            "parameter exceeds the existing preparation byte bound",
        ));
    }
    Ok(())
}

fn add_size(total: usize, added: usize) -> Result<usize, ControlError> {
    let result = total
        .checked_add(added)
        .ok_or_else(|| invalid("request size overflow"))?;
    if result > envelope::REQUEST_BOUND {
        return Err(invalid("runner request exceeds 16 KiB"));
    }
    Ok(result)
}

fn pod_size(body: usize) -> Result<usize, ControlError> {
    let size = body
        .checked_add(15)
        .ok_or_else(|| invalid("request size overflow"))?
        & !7;
    add_size(0, size)
}

fn string_size(value: &str) -> Result<usize, ControlError> {
    let size = pod_size(add_size(value.len(), 1)?)?;
    if value.contains('\0') {
        return Err(invalid("native strings must contain no NUL"));
    }
    Ok(size)
}

// Inspect borrowed fields before cloning any variable-size input. Every nested
// Struct contributes its eight-byte POD header; array child metadata adds eight.
/// Checks borrowed request fields before allocation.
/// # Errors
/// Rejects invalid headers, operation fields, types, extents or request capacity.
pub fn preflight(header: &RequestHeader, command: &Command) -> Result<(), ControlError> {
    use Command as C;
    header
        .validate()
        .map_err(|error| invalid(error.to_string()))?;
    let (operation, size) = match command {
        C::Quit => (Operation::Quit, 0),
        C::Groups => (Operation::Groups, 0),
        C::Status => (Operation::Status, 0),
        C::SessionStop => (Operation::SessionStop, 0),
        C::SessionStart => (Operation::SessionStart, 0),
        C::SourceEnded => (Operation::SourceEnded, 0),
        C::Reset => (Operation::Reset, 0),
        C::Properties(graph) => (Operation::Properties, string_size(name(graph)?)?),
        C::StopGroup(group) => (Operation::StopGroup, string_size(name(group)?)?),
        C::StartGroup(group) => (Operation::StartGroup, string_size(name(group)?)?),
        C::PropertyGeneration(graph, node) => (
            Operation::PropertyGeneration,
            add_size(string_size(name(graph)?)?, string_size(name(node)?)?)?,
        ),
        C::ParameterGeneration(graph, node) => (
            Operation::ParameterGeneration,
            add_size(string_size(name(graph)?)?, string_size(name(node)?)?)?,
        ),
        C::PropertiesSet(graph, values) => {
            if values.is_empty() || values.len() > MAX_PROPERTIES {
                return Err(invalid(
                    "property transaction requires 1 through 42 records",
                ));
            }
            let mut records_size = 0;
            for (qualified, value) in values {
                let value_size = match value {
                    ScalarValue::String(value) => string_size(value)?,
                    ScalarValue::Float(bits) if !f32::from_bits(*bits).is_finite() => {
                        return Err(invalid("property float must be finite"))
                    }
                    ScalarValue::Double(bits) if !f64::from_bits(*bits).is_finite() => {
                        return Err(invalid("property double must be finite"))
                    }
                    _ => 16,
                };
                records_size = add_size(
                    records_size,
                    pod_size(add_size(string_size(name(qualified)?)?, value_size)?)?,
                )?;
            }
            (
                Operation::PropertiesSet,
                add_size(string_size(name(graph)?)?, pod_size(records_size)?)?,
            )
        }
        C::Parameter {
            graph,
            parameter,
            element_type,
            shape,
            schema,
            path,
        } => {
            if path.as_os_str().len() > envelope::REQUEST_BOUND {
                return Err(invalid("artifact path cannot fit the request envelope"));
            }
            let path = path
                .to_str()
                .ok_or_else(|| invalid("artifact path must be UTF-8"))?;
            let shape_bytes = shape
                .len()
                .checked_mul(4)
                .ok_or_else(|| invalid("shape size overflow"))?;
            let mut size = pod_size(add_size(8, shape_bytes)?)?;
            for value in [
                name(graph)?,
                name(parameter)?,
                element_type.as_str(),
                schema.as_str(),
                name(path)?,
            ] {
                size = add_size(size, string_size(value)?)?;
            }
            parameter_extent(element_type, shape)?;
            (Operation::Parameter, size)
        }
        C::PreparedParameter { .. } => {
            return Err(invalid("prepared parameters are internal commands"))
        }
    };
    if header.operation != operation as u32 {
        return Err(invalid("header operation differs from command"));
    }
    // Empty-payload envelope is fixed and small; constructing it copies no
    // command data. All children are aligned, so appending them adds exactly size.
    let base = envelope::encode_request(header, &[])
        .map_err(|error| invalid(error.to_string()))?
        .len();
    add_size(base, size)?;
    Ok(())
}

/// Decodes one exact typed runner request.
/// # Errors
/// Rejects malformed, excessive or semantically invalid native requests.
pub fn decode_request(bytes: &[u8]) -> Result<(RequestHeader, Command), ControlError> {
    let request = envelope::decode_request(bytes).map_err(|error| invalid(error.to_string()))?;
    let operation = Operation::try_from(request.header.operation)?;
    let command = decode_payload(operation, &request.payload)?;
    Ok((request.header, command))
}

fn decode_payload(operation: Operation, fields: &[Value]) -> Result<Command, ControlError> {
    use Operation as O;
    Ok(match (operation, fields) {
        (O::Quit, []) => Command::Quit,
        (O::Groups, []) => Command::Groups,
        (O::Status, []) => Command::Status,
        (O::SessionStop, []) => Command::SessionStop,
        (O::SessionStart, []) => Command::SessionStart,
        (O::SourceEnded, []) => Command::SourceEnded,
        (O::Reset, []) => Command::Reset,
        (O::Properties, [Value::String(graph)]) => Command::Properties(name(graph)?.to_owned()),
        (O::StopGroup, [Value::String(group)]) => Command::StopGroup(name(group)?.to_owned()),
        (O::StartGroup, [Value::String(group)]) => Command::StartGroup(name(group)?.to_owned()),
        (O::PropertyGeneration, [Value::String(graph), Value::String(node)]) => {
            Command::PropertyGeneration(name(graph)?.to_owned(), name(node)?.to_owned())
        }
        (O::ParameterGeneration, [Value::String(graph), Value::String(node)]) => {
            Command::ParameterGeneration(name(graph)?.to_owned(), name(node)?.to_owned())
        }
        (O::PropertiesSet, [Value::String(graph), Value::Struct(records)]) => {
            name(graph)?;
            if records.is_empty() || records.len() > MAX_PROPERTIES {
                return Err(invalid(
                    "property transaction requires 1 through 42 records",
                ));
            }
            let mut values = BTreeMap::new();
            for record in records {
                let Value::Struct(fields) = record else {
                    return Err(invalid("property record must be a Struct"));
                };
                let [Value::String(qualified), value] = fields.as_slice() else {
                    return Err(invalid(
                        "property record must contain exactly name and scalar",
                    ));
                };
                if values
                    .insert(name(qualified)?.to_owned(), scalar(value)?)
                    .is_some()
                {
                    return Err(invalid("duplicate property name"));
                }
            }
            Command::PropertiesSet(graph.clone(), values)
        }
        (
            O::Parameter,
            [Value::String(graph), Value::String(parameter), Value::String(element_type), Value::ValueArray(ValueArray::Id(shape)), Value::String(schema), Value::String(path)],
        ) => {
            name(graph)?;
            name(parameter)?;
            name(path)?;
            let shape = shape.iter().map(|Id(value)| *value).collect::<Vec<_>>();
            parameter_extent(element_type, &shape)?;
            Command::Parameter {
                graph: graph.clone(),
                parameter: parameter.clone(),
                element_type: element_type.clone(),
                shape,
                schema: schema.clone(),
                path: PathBuf::from(path),
            }
        }
        _ => return Err(invalid("wrong runner payload arity or field types")),
    })
}

/// Encodes one exact typed runner request.
/// # Errors
/// Rejects invalid headers, operation fields or requests exceeding 16 KiB.
pub fn encode_request(header: &RequestHeader, command: &Command) -> Result<Vec<u8>, ControlError> {
    use Command as C;
    preflight(header, command)?;
    let (operation, fields) = match command {
        C::Quit => (Operation::Quit, vec![]),
        C::Groups => (Operation::Groups, vec![]),
        C::Status => (Operation::Status, vec![]),
        C::SessionStop => (Operation::SessionStop, vec![]),
        C::SessionStart => (Operation::SessionStart, vec![]),
        C::SourceEnded => (Operation::SourceEnded, vec![]),
        C::Reset => (Operation::Reset, vec![]),
        C::Properties(graph) => (Operation::Properties, vec![Value::String(graph.clone())]),
        C::StopGroup(group) => (Operation::StopGroup, vec![Value::String(group.clone())]),
        C::StartGroup(group) => (Operation::StartGroup, vec![Value::String(group.clone())]),
        C::PropertyGeneration(graph, node) => (
            Operation::PropertyGeneration,
            vec![Value::String(graph.clone()), Value::String(node.clone())],
        ),
        C::ParameterGeneration(graph, node) => (
            Operation::ParameterGeneration,
            vec![Value::String(graph.clone()), Value::String(node.clone())],
        ),
        C::PropertiesSet(graph, values) => {
            if values.is_empty() || values.len() > MAX_PROPERTIES {
                return Err(invalid(
                    "property transaction requires 1 through 42 records",
                ));
            }
            let records = values
                .iter()
                .map(|(qualified, value)| {
                    Ok(Value::Struct(vec![
                        Value::String(qualified.clone()),
                        scalar_pod(value)?,
                    ]))
                })
                .collect::<Result<Vec<_>, ControlError>>()?;
            (
                Operation::PropertiesSet,
                vec![Value::String(graph.clone()), Value::Struct(records)],
            )
        }
        C::Parameter {
            graph,
            parameter,
            element_type,
            shape,
            schema,
            path,
        } => {
            parameter_extent(element_type, shape)?;
            let path = path
                .to_str()
                .ok_or_else(|| invalid("artifact path must be UTF-8"))?;
            (
                Operation::Parameter,
                vec![
                    Value::String(graph.clone()),
                    Value::String(parameter.clone()),
                    Value::String(element_type.clone()),
                    Value::ValueArray(ValueArray::Id(
                        shape.iter().map(|value| Id(*value)).collect(),
                    )),
                    Value::String(schema.clone()),
                    Value::String(path.to_owned()),
                ],
            )
        }
        C::PreparedParameter { .. } => {
            return Err(invalid("prepared parameters are internal commands"))
        }
    };
    if header.operation != operation as u32 {
        return Err(invalid("header operation differs from command"));
    }
    // Apply the same semantic checks on both encoding and decoding.
    decode_payload(operation, &fields)?;
    envelope::encode_request(header, &fields).map_err(|error| invalid(error.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use envelope::ControllerIdentity;

    fn header(operation: u32) -> RequestHeader {
        RequestHeader {
            version: 1,
            endpoint_instance: 7,
            controller: ControllerIdentity {
                global_id: 42,
                serial: u64::MAX,
                instance: 13,
            },
            token: 11,
            operation,
            budget_ns: 1_000_000_000,
        }
    }

    fn parameter(shape: Vec<u32>) -> Command {
        Command::Parameter {
            graph: "g".into(),
            parameter: "n:matrix".into(),
            element_type: "F32_LE".into(),
            shape,
            schema: String::new(),
            path: PathBuf::from("/path/not/opened/by/codec"),
        }
    }

    #[test]
    fn every_command_round_trips_exactly_without_artifact_io() {
        let commands = [
            Command::Quit,
            Command::Groups,
            Command::Status,
            Command::Properties("g".into()),
            Command::PropertyGeneration("g".into(), "n".into()),
            Command::ParameterGeneration("g".into(), "n".into()),
            Command::StopGroup("x".into()),
            Command::StartGroup("x".into()),
            Command::SessionStop,
            Command::SessionStart,
            Command::SourceEnded,
            Command::Reset,
            Command::PropertiesSet(
                "g".into(),
                BTreeMap::from([("n:gain".into(), ScalarValue::float(-0.0))]),
            ),
            parameter(vec![277, 221]),
        ];
        for (index, command) in commands.iter().enumerate() {
            let header = header(u32::try_from(index + 1).unwrap());
            let bytes = encode_request(&header, command).unwrap();
            assert_eq!(decode_request(&bytes).unwrap(), (header, command.clone()));
        }
        assert_eq!(PROFILE, "pipewireao.rtc.runner/1");
    }

    #[test]
    fn scalar_pods_preserve_all_seven_types_and_numeric_bits() {
        let values = [
            ScalarValue::Bool(true),
            ScalarValue::Int(i32::MIN),
            ScalarValue::Long(i64::MIN),
            ScalarValue::float(-0.0),
            ScalarValue::double(-0.0),
            ScalarValue::Id(u32::MAX),
            ScalarValue::String(String::new()),
        ];
        for value in values {
            let command =
                Command::PropertiesSet("g".into(), BTreeMap::from([("n:p".into(), value)]));
            assert_eq!(
                decode_request(&encode_request(&header(13), &command).unwrap())
                    .unwrap()
                    .1,
                command
            );
        }
    }

    #[test]
    fn exact_operation_arity_types_and_names_are_required() {
        for (operation, fields) in [
            (15, vec![]),
            (3, vec![Value::Bool(true)]),
            (4, vec![]),
            (4, vec![Value::Int(1)]),
            (4, vec![Value::String(String::new())]),
            (5, vec![Value::String("g".into())]),
            (13, vec![Value::String("g".into()), Value::Struct(vec![])]),
            (
                13,
                vec![
                    Value::String("g".into()),
                    Value::Struct(vec![Value::Bool(true)]),
                ],
            ),
        ] {
            let bytes = envelope::encode_request(&header(operation), &fields).unwrap();
            assert!(decode_request(&bytes).is_err());
        }
        assert!(encode_request(&header(3), &Command::Quit).is_err());
    }

    #[test]
    fn nonfinite_and_duplicate_properties_are_rejected() {
        for value in [
            Value::Float(f32::NAN),
            Value::Float(f32::INFINITY),
            Value::Double(f64::NEG_INFINITY),
            Value::ValueArray(ValueArray::Int(vec![1])),
        ] {
            let fields = vec![
                Value::String("g".into()),
                Value::Struct(vec![Value::Struct(vec![
                    Value::String("n:p".into()),
                    value,
                ])]),
            ];
            assert!(
                decode_request(&envelope::encode_request(&header(13), &fields).unwrap()).is_err()
            );
        }
        let record = Value::Struct(vec![Value::String("n:p".into()), Value::Int(1)]);
        let fields = vec![
            Value::String("g".into()),
            Value::Struct(vec![record.clone(), record]),
        ];
        assert!(decode_request(&envelope::encode_request(&header(13), &fields).unwrap()).is_err());
    }

    #[test]
    fn property_transactions_are_canonical_and_bounded() {
        let fields = vec![
            Value::String("g".into()),
            Value::Struct(vec![
                Value::Struct(vec![Value::String("n:z".into()), Value::Long(2)]),
                Value::Struct(vec![Value::String("n:a".into()), Value::Long(1)]),
            ]),
        ];
        let bytes = envelope::encode_request(&header(13), &fields).unwrap();
        let (header, command) = decode_request(&bytes).unwrap();
        let canonical = encode_request(&header, &command).unwrap();
        assert_ne!(canonical, bytes);
        assert_eq!(
            encode_request(&header, &decode_request(&canonical).unwrap().1).unwrap(),
            canonical
        );
        for count in [42, 43] {
            let properties = (0..count)
                .map(|i| (format!("n:p{i}"), ScalarValue::Int(i)))
                .collect();
            let result = encode_request(&header, &Command::PropertiesSet("g".into(), properties));
            assert_eq!(result.is_ok(), count == 42);
        }
    }

    #[test]
    fn parameter_extent_and_native_envelope_bounds_are_enforced() {
        for shape in [
            vec![],
            vec![0],
            vec![u32::MAX, u32::MAX, u32::MAX],
            vec![134_217_729],
        ] {
            assert!(encode_request(&header(14), &parameter(shape)).is_err());
        }
        assert!(encode_request(&header(14), &parameter(vec![134_217_728])).is_ok());
        let mut wrong_type = parameter(vec![1]);
        if let Command::Parameter { element_type, .. } = &mut wrong_type {
            *element_type = "F64_LE".into();
        }
        assert!(encode_request(&header(14), &wrong_type).is_err());
        let oversized = Command::PropertiesSet(
            "g".into(),
            BTreeMap::from([(
                "n:p".into(),
                ScalarValue::String("x".repeat(envelope::REQUEST_BOUND)),
            )]),
        );
        assert!(encode_request(&header(13), &oversized).is_err());
        let bytes = encode_request(&header(3), &Command::Status).unwrap();
        for length in 0..bytes.len() {
            assert!(decode_request(&bytes[..length]).is_err());
        }
    }

    #[test]
    fn borrowed_preflight_matches_native_padding_at_the_byte_limit() {
        let lengths =
            (0..33).chain((envelope::REQUEST_BOUND - 512)..(envelope::REQUEST_BOUND + 16));
        for length in lengths {
            let value = "x".repeat(length);
            let fields = vec![
                Value::String("g".into()),
                Value::Struct(vec![Value::Struct(vec![
                    Value::String("n:p".into()),
                    Value::String(value.clone()),
                ])]),
            ];
            let native = envelope::encode_request(&header(13), &fields);
            let command = Command::PropertiesSet(
                "g".into(),
                BTreeMap::from([("n:p".into(), ScalarValue::String(value))]),
            );
            let bounded = encode_request(&header(13), &command);
            assert_eq!(bounded.is_ok(), native.is_ok(), "string length {length}");
            if let (Ok(bounded), Ok(native)) = (bounded, native) {
                assert_eq!(bounded, native);
            }
        }
        for rank in [1, 2, 3, 4, 5, 31, 32, 33, 4000, 4096, 4097] {
            let shape = vec![1; rank];
            let fields = vec![
                Value::String("g".into()),
                Value::String("n:matrix".into()),
                Value::String("F32_LE".into()),
                Value::ValueArray(ValueArray::Id(vec![Id(1); rank])),
                Value::String(String::new()),
                Value::String("/path/not/opened/by/codec".into()),
            ];
            assert_eq!(
                encode_request(&header(14), &parameter(shape)).is_ok(),
                envelope::encode_request(&header(14), &fields).is_ok(),
                "rank {rank}"
            );
        }
    }

    #[test]
    fn oversized_parameter_descriptors_fail_before_variable_input_diagnostics() {
        let mut oversized_type = parameter(vec![1]);
        if let Command::Parameter { element_type, .. } = &mut oversized_type {
            *element_type = "x".repeat(envelope::REQUEST_BOUND + 1);
        }
        let error = encode_request(&header(14), &oversized_type).unwrap_err();
        assert!(error.message.len() < 100);
        let mut oversized_path = parameter(vec![1]);
        if let Command::Parameter { path, .. } = &mut oversized_path {
            *path = PathBuf::from("x".repeat(envelope::REQUEST_BOUND + 1));
        }
        assert!(encode_request(&header(14), &oversized_path).is_err());
        assert!(encode_request(&header(14), &parameter(vec![1; 1_000_000])).is_err());
        // The ordinary small unsupported type retains the existing diagnostic.
        let mut wrong_type = parameter(vec![1]);
        if let Command::Parameter { element_type, .. } = &mut wrong_type {
            *element_type = "F64_LE".into();
        }
        assert!(encode_request(&header(14), &wrong_type)
            .unwrap_err()
            .message
            .contains("F64_LE"));
    }
}
