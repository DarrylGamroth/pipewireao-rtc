//! Pure transport state/codec checks; these do not establish live owner authority.
use super::*;
use crate::calibration::AcquisitionCursor;
use pw::spa::pod::serialize::PodSerializer;
use pw::spa::pod::{Object, Property, Value};
use pw::spa::utils::{Id, SpaTypes};
use std::io::Cursor;

fn binding() -> Binding {
    Binding::new("/tmp/private/pw".into(), "owner.actions".into(), 7, 42).unwrap()
}
fn controller() -> ControllerIdentity {
    ControllerIdentity {
        global_id: 21,
        serial: u64::MAX,
        instance: 11,
    }
}
fn observation() -> Observation {
    Observation {
        binding: binding(),
        marker_name: "marker".into(),
        marker_instance: 11,
        candidates: BTreeMap::new(),
        owner: None,
        identity: Some(controller()),
        owner_ready: true,
        marker_ready: true,
        capability: None,
        completion_seen: false,
        rejection_seen: false,
        max_token: 0,
        pending: None,
        matched: None,
        last_completion: None,
        failure: None,
        fatal: false,
    }
}
fn request() -> RequestHeader {
    RequestHeader {
        version: 1,
        endpoint_instance: 42,
        controller: controller(),
        token: 1,
        operation: 1,
        budget_ns: 1_000_000_000,
    }
}
fn reply() -> ReplyHeader {
    let r = request();
    ReplyHeader {
        version: 1,
        endpoint_instance: r.endpoint_instance,
        controller: r.controller,
        token: r.token,
        operation: r.operation,
        result: 0,
    }
}
fn completion(run: u64, serial: u64) -> codec::Completion {
    codec::Completion {
        header: reply(),
        lifecycle: ColdLifecycle::Connected,
        run,
        serial,
        result: Some(ResultValue::Held(AcquisitionCursor {
            domain: u64::MAX,
            generation: 1,
            sequence: 0,
            model_ns: 0,
        })),
        message: String::new(),
    }
}
fn serialize(value: &Value) -> Vec<u8> {
    PodSerializer::serialize(Cursor::new(Vec::new()), value)
        .unwrap()
        .0
        .into_inner()
}
fn capability_value() -> Value {
    let values = [
        ("version", Value::Int(1)),
        ("instance", Value::Long(42)),
        ("owner-pid", Value::Id(Id(7))),
        ("lifecycle", Value::Id(Id(3))),
        ("last-token", Value::Long(i64::MAX)),
        (
            "controllers",
            Value::Struct(vec![Value::Struct(vec![
                Value::Id(Id(21)),
                Value::Long(-1),
                Value::Long(11),
            ])]),
        ),
    ];
    Value::Object(Object {
        type_: SpaTypes::ObjectParamProps.as_raw(),
        id: pw::spa::param::ParamType::Props.as_raw(),
        properties: vec![Property::new(
            pw::spa::sys::SPA_PROP_params,
            Value::Struct(
                values
                    .into_iter()
                    .flat_map(|(name, value)| [Value::String(format!("{CAP_PREFIX}{name}")), value])
                    .collect(),
            ),
        )],
    })
}
#[test]
fn capability_is_bounded_typed_and_preserves_full_serial() {
    let bytes = serialize(&capability_value());
    let values = props(&bytes).unwrap();
    let cap = capability(&bytes, &values, &binding()).unwrap();
    assert_eq!(cap.lifecycle, ColdLifecycle::Connected);
    assert_eq!(cap.last_token, i64::MAX);
    assert_eq!(cap.controllers, vec![controller()]);
    let mut wrong = binding();
    wrong.owner_pid += 1;
    assert!(capability(&bytes, &values, &wrong).is_err());
    wrong = binding();
    wrong.instance += 1;
    assert!(capability(&bytes, &values, &wrong).is_err());
    let mut width = bytes.clone();
    let value = values[3];
    width[value.body - 8..value.body - 4].copy_from_slice(&4_u32.to_ne_bytes());
    assert!(props(&width)
        .and_then(|fields| capability(&width, &fields, &binding()))
        .is_err());
    let mut unknown = bytes.clone();
    unknown[values[7].body..values[7].body + 4].copy_from_slice(&6_u32.to_ne_bytes());
    assert!(capability(&unknown, &values, &binding()).is_err());
    let mut malformed = bytes.clone();
    malformed[4..8].copy_from_slice(&pw::spa::sys::SPA_TYPE_Struct.to_ne_bytes());
    assert!(props(&malformed).is_err());
    assert!(props(&vec![0; envelope::CALIBRATION_REPLY_BOUND + 1]).is_err());
}
#[test]
fn malformed_capability_containers_reject_before_value_decoding() {
    let Value::Object(mut object) = capability_value() else {
        unreachable!()
    };
    let Value::Struct(fields) = &mut object.properties[0].value else {
        unreachable!()
    };
    fields[2] = fields[0].clone();
    let bytes = serialize(&Value::Object(object));
    assert!(capability(&bytes, &props(&bytes).unwrap(), &binding()).is_err());
    let Value::Object(mut object) = capability_value() else {
        unreachable!()
    };
    let Value::Struct(fields) = &mut object.properties[0].value else {
        unreachable!()
    };
    fields[11] = Value::Struct(vec![
        Value::Struct(vec![
            Value::Id(Id(21)),
            Value::Long(-1),
            Value::Long(11)
        ]);
        33
    ]);
    let bytes = serialize(&Value::Object(object));
    assert!(capability(&bytes, &props(&bytes).unwrap(), &binding()).is_err());
    let Value::Object(mut object) = capability_value() else {
        unreachable!()
    };
    let Value::Struct(fields) = &mut object.properties[0].value else {
        unreachable!()
    };
    fields[11] = Value::Struct(vec![
        Value::Struct(vec![
            Value::Id(Id(21)),
            Value::Long(-1),
            Value::Long(11)
        ]);
        2
    ]);
    let bytes = serialize(&Value::Object(object));
    assert!(capability(&bytes, &props(&bytes).unwrap(), &binding()).is_err());
}
fn fake_endpoint(state: Observation) -> NativeCalibrationEndpoint {
    NativeCalibrationEndpoint {
        resources: None,
        observation: Rc::new(RefCell::new(state)),
        pending: Some(CalibrationRequest {
            run: u64::MAX,
            serial: u64::MAX,
        }),
        last_token: 1,
        fault: None,
    }
}
#[test]
fn matching_terminal_before_retirement_preserves_release_style_outcome() {
    let mut state = observation();
    state.pending = Some(request());
    state
        .observe(&codec::encode_completion(&completion(u64::MAX, u64::MAX)).unwrap())
        .unwrap();
    state.fail("later NodeRemoved", true);
    let mut endpoint = fake_endpoint(state);
    let received = endpoint
        .receive(Instant::now() + Duration::from_secs(1))
        .unwrap()
        .unwrap();
    assert_eq!(received.request.run, u64::MAX);
    assert_eq!(received.request.serial, u64::MAX);
    assert!(matches!(received.result, Ok(CalibrationEvidence::Held(_))));
    assert_eq!(endpoint.fault_reason(), None);
}
#[test]
fn prior_loss_late_reply_conflict_or_science_identity_mismatch_retires() {
    let bytes = codec::encode_completion(&completion(u64::MAX, u64::MAX)).unwrap();
    let mut state = observation();
    state.pending = Some(request());
    state.fail("prior loss", true);
    state.observe(&bytes).unwrap();
    assert!(state.matched.is_none());
    let mut endpoint = fake_endpoint(state);
    assert!(endpoint
        .receive(Instant::now() + Duration::from_secs(1))
        .is_err());
    assert!(endpoint.fault_reason().is_some());
    let mut state = observation();
    state.pending = Some(request());
    state.observe(&bytes).unwrap();
    let mut conflicting = completion(u64::MAX, u64::MAX);
    conflicting.result = Some(ResultValue::Failed(FailureReason::Cancelled));
    assert!(state
        .observe(&codec::encode_completion(&conflicting).unwrap())
        .is_err());
    let mut state = observation();
    state.pending = Some(request());
    state
        .observe(&codec::encode_completion(&completion(1, u64::MAX)).unwrap())
        .unwrap();
    let mut endpoint = fake_endpoint(state);
    assert!(endpoint
        .receive(Instant::now() + Duration::from_secs(1))
        .is_err());
    assert!(endpoint.fault_reason().is_some());
    let mut state = observation();
    state.pending = Some(request());
    state.observe(&bytes).unwrap();
    state.matched.as_mut().unwrap().at = Instant::now() + Duration::from_secs(2);
    let mut endpoint = fake_endpoint(state);
    assert!(endpoint.receive(Instant::now()).unwrap().is_none());
    assert!(endpoint.fault_reason().is_some());
}
#[test]
fn typed_failed_action_keeps_correlation_and_known_recovery() {
    let mut state = observation();
    state.pending = Some(request());
    let mut value = completion(u64::MAX, u64::MAX);
    value.result = Some(ResultValue::Failed(FailureReason::InvalidEvidence));
    state
        .observe(&codec::encode_completion(&value).unwrap())
        .unwrap();
    let mut endpoint = fake_endpoint(state);
    let received = endpoint
        .receive(Instant::now() + Duration::from_secs(1))
        .unwrap()
        .unwrap();
    assert!(matches!(
        received.result,
        Err(CalibrationFailure::InvalidEvidence)
    ));
    assert_eq!(endpoint.fault_reason(), None);
    endpoint.fault(CalibrationFailure::Endpoint);
    assert_eq!(endpoint.fault_reason(), Some(CalibrationFailure::Endpoint));
}
#[test]
fn borrowed_figure_capacity_and_rule_conversion_precede_copy() {
    use std::sync::Arc;
    for rule in [
        None,
        Some(Rule::Immediate),
        Some(Rule::DiscardExposures(1)),
        Some(Rule::ModelTime(1)),
    ] {
        let size = codec::preflight_figure_request(&[1.0; 2], rule).unwrap();
        let action = match rule {
            None => Action::Adopt {
                probe: 0,
                figure: vec![1.0; 2],
            },
            Some(rule) => Action::Restore {
                figure: vec![1.0; 2],
                rule,
            },
        };
        let mut header = request();
        header.operation = action.operation();
        assert_eq!(
            size,
            codec::encode_request(
                &header,
                &Command {
                    run: u64::MAX,
                    serial: 1,
                    action
                }
            )
            .unwrap()
            .len()
        );
        assert!(size < envelope::REQUEST_BOUND);
        assert!(codec::preflight_figure_request(&vec![1.0; 4096], rule).is_err());
        assert!(codec::preflight_figure_request(&[f32::NAN], rule).is_err());
    }
    assert!(wire_action(&CalibrationAction::Adopt {
        probe: 0,
        figure: Arc::from(vec![1.0; 4096])
    })
    .is_err());
    assert!(wire_action(&CalibrationAction::Restore {
        figure: Arc::from([1.0, 2.0]),
        rule: SettlingRule::ModelTime(Duration::MAX)
    })
    .is_err());
    assert!(Binding::new("relative".into(), "node".into(), 1, 1).is_err());
    assert!(Binding::new("/tmp/pw".into(), "node".into(), 0, 1).is_err());
    assert!(Binding::new("/tmp/pw".into(), "node".into(), 1, 0).is_err());
}
