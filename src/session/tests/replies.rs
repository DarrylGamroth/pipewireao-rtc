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
fn reply_cases() -> Vec<(Operation, LifecycleState, ExecutionResult)> {
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
    for (operation, state, result) in reply_cases() {
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
    for (operation, _, _) in reply_cases() {
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
    for (operation, state, result) in reply_cases() {
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
                    validate_completion_capacity(&header, LifecycleState::Ready, &result).is_err()
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
            decode_rejection(&envelope::encode_rejection(&negative, &payload).unwrap()).is_err()
        );
    }
}
