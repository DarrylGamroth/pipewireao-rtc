use super::{
    parse, prepare, Command, ExecutionResult, Outcome, PropertyGenerationObservation,
    MAX_ARGUMENTS, MAX_PARAMETER_BYTES,
};
use crate::{
    ExecutionGroupState, LifecycleState, LiveGraphStatus, ParameterGeneration, PropertyGeneration,
    ScalarValue,
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
