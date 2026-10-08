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
        let command = Command::PropertiesSet("g".into(), BTreeMap::from([("n:p".into(), value)]));
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
        assert!(decode_request(&envelope::encode_request(&header(13), &fields).unwrap()).is_err());
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
    let lengths = (0..33).chain((envelope::REQUEST_BOUND - 512)..(envelope::REQUEST_BOUND + 16));
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
