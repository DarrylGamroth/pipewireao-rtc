use super::*;
use envelope::ControllerIdentity;
fn request(op: u32) -> RequestHeader {
    RequestHeader {
        version: 1,
        endpoint_instance: 42,
        controller: ControllerIdentity {
            global_id: 7,
            serial: u64::MAX,
            instance: 11,
        },
        token: i64::from(op),
        operation: op,
        budget_ns: i64::MAX,
    }
}
fn reply(op: u32) -> ReplyHeader {
    ReplyHeader {
        version: 1,
        endpoint_instance: 42,
        controller: request(op).controller,
        token: i64::from(op),
        operation: op,
        result: 0,
    }
}
fn cur() -> AcquisitionCursor {
    AcquisitionCursor {
        domain: u64::MAX,
        generation: 1 << 63,
        sequence: u64::MAX,
        model_ns: i64::MAX as u64,
    }
}
fn exp() -> Exposure {
    Exposure {
        domain: u64::MAX,
        generation: 1 << 63,
        sequence: u64::MAX,
        start_model_ns: 1 << 63,
        duration_ns: i64::MAX as u64,
    }
}
fn completion(op: u32, result: ResultValue) -> Completion {
    Completion {
        header: reply(op),
        lifecycle: ColdLifecycle::Connected,
        run: u64::MAX,
        serial: 1 << 63,
        result: Some(result),
        message: String::new(),
    }
}
fn protocol_records() -> Vec<(String, Vec<u8>)> {
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/data/native-calibration-actions");
    std::fs::read_dir(dir)
        .unwrap()
        .map(|e| {
            let e = e.unwrap();
            (
                e.file_name().into_string().unwrap(),
                std::fs::read(e.path()).unwrap(),
            )
        })
        .filter(|(n, _)| {
            std::path::Path::new(n)
                .extension()
                .is_some_and(|ext| ext == "pod")
        })
        .collect()
}
#[test]
fn shared_julia_records_roundtrip_and_reject() {
    let mut good = 0;
    let mut bad_count = 0;
    for (name, bytes) in protocol_records() {
        if name.starts_with("request-") {
            let (h, c) = decode_request(&bytes).unwrap();
            assert_eq!(c.run, u64::MAX);
            assert_eq!(c.serial, 1 << 63);
            assert_eq!(encode_request(&h, &c).unwrap(), bytes);
            good += 1;
        } else if name.starts_with("reply-") {
            let c = decode_completion(&bytes).unwrap();
            assert_eq!(c.run, u64::MAX);
            assert_eq!(c.serial, 1 << 63);
            assert_eq!(encode_completion(&c).unwrap(), bytes);
            good += 1;
        } else if name == "rejection.pod" {
            let r = decode_rejection(&bytes).unwrap();
            assert_eq!(encode_rejection(&r).unwrap(), bytes);
            good += 1;
        } else if name.starts_with("bad-request-") {
            assert!(decode_request(&bytes).is_err(), "{name}");
            bad_count += 1;
        } else if name.starts_with("bad-reply-") {
            assert!(decode_completion(&bytes).is_err(), "{name}");
            bad_count += 1;
        } else {
            panic!("unclassified record {name}")
        }
    }
    assert_eq!(good, 22);
    assert_eq!(bad_count, 21);
}
#[test]
fn request_validates_before_encoding_and_preserves_unsigned_bits() {
    for n in [1, (1 << 63) - 1, 1 << 63, u64::MAX] {
        let c = Command {
            run: n,
            serial: n,
            action: Action::Hold,
        };
        assert_eq!(
            decode_request(&encode_request(&request(1), &c).unwrap())
                .unwrap()
                .1,
            c
        );
    }
    for c in [
        Command {
            run: 0,
            serial: 1,
            action: Action::Hold,
        },
        Command {
            run: 1,
            serial: 0,
            action: Action::Hold,
        },
        Command {
            run: 1,
            serial: 1,
            action: Action::Adopt {
                probe: 0,
                figure: vec![0.; 4096],
            },
        },
    ] {
        assert!(encode_request(&request(c.action.operation()), &c).is_err());
    }
    let c = Command {
        run: 1,
        serial: 1,
        action: Action::Release,
    };
    assert!(encode_request(&request(1), &c).is_err());
    let maximum = (1..=4096)
        .take_while(|n| {
            base(false).unwrap() + 32 + 24 + array_size(*n, 4).unwrap() <= envelope::REQUEST_BOUND
        })
        .last()
        .unwrap();
    let full = Command {
        run: 1,
        serial: 1,
        action: Action::Adopt {
            probe: 0,
            figure: vec![0.; maximum],
        },
    };
    let bytes = encode_request(&request(2), &full).unwrap();
    assert_eq!(bytes.len(), envelope::REQUEST_BOUND);
    assert_eq!(decode_request(&bytes).unwrap().1, full);
    assert!(encode_request(
        &request(2),
        &Command {
            run: 1,
            serial: 1,
            action: Action::Adopt {
                probe: 0,
                figure: vec![0.; maximum + 1]
            }
        }
    )
    .is_err());
    assert!(decode_request(&vec![0; envelope::REQUEST_BOUND + 1]).is_err());
}
#[test]
fn exact_collect_capacity_matches_serialization_at_boundary() {
    for (m, n, msg) in [(1, 1, 0), (376, 409, 0), (3600, 100, 8192), (32000, 1, 1)] {
        let mut c = completion(
            4,
            ResultValue::Responses {
                values: vec![0.; m],
                exposures: vec![exp(); n],
                valid: true,
            },
        );
        c.message = "x".repeat(msg);
        assert_eq!(
            encode_completion(&c).unwrap().len(),
            preflight_collect_reply(m, n, msg).unwrap()
        );
    }
    let maximum = (1..=131_072)
        .take_while(|m| collect_reply_size(*m, 1, 0).unwrap() <= 131_072)
        .last()
        .unwrap();
    assert_eq!(preflight_collect_reply(maximum, 1, 0).unwrap(), 131_072);
    assert!(preflight_collect_reply(maximum + 1, 1, 0).is_err());
    assert!(encode_completion(&completion(
        4,
        ResultValue::Responses {
            values: vec![0.; maximum + 1],
            exposures: vec![exp()],
            valid: true
        }
    ))
    .is_err());
    assert!(preflight_collect_reply(1, 4096, 0).is_err());
    assert!(preflight_collect_reply(131_072, 4096, 0).is_err());
    for (m, n) in [
        (0, 1),
        (131_073, 1),
        (1, 0),
        (1, 4097),
        (usize::MAX, usize::MAX),
    ] {
        assert!(preflight_collect_reply(m, n, 0).is_err());
    }
    assert!(preflight_collect_reply(1, 1, 8193).is_err());
    assert!(decode_completion(&vec![0; 131_073]).is_err());
}
#[test]
fn cursor_and_exposure_domains_and_times_are_distinct() {
    let mut c = cur();
    c.model_ns = 1 << 63;
    assert!(cursor(c).is_err());
    for c in [
        AcquisitionCursor { domain: 0, ..cur() },
        AcquisitionCursor {
            generation: 0,
            ..cur()
        },
    ] {
        assert!(cursor(c).is_err());
    }
    for e in [
        Exposure { domain: 0, ..exp() },
        Exposure {
            generation: 0,
            ..exp()
        },
        Exposure {
            duration_ns: 0,
            ..exp()
        },
        Exposure {
            start_model_ns: u64::MAX,
            duration_ns: 1,
            ..exp()
        },
    ] {
        assert!(exposure(&e).is_err());
    }
    assert!(exposure(&Exposure {
        start_model_ns: 0,
        duration_ns: u64::MAX,
        ..exp()
    })
    .is_ok());
}
#[test]
fn typed_failure_negative_transport_and_rejection_stay_distinct() {
    for reason in [
        FailureReason::Cancelled,
        FailureReason::Endpoint,
        FailureReason::InvalidEvidence,
        FailureReason::ProbeClipped,
    ] {
        let c = completion(1, ResultValue::Failed(reason));
        assert_eq!(
            decode_completion(&encode_completion(&c).unwrap()).unwrap(),
            c
        );
    }
    let mut c = completion(1, ResultValue::Released);
    assert!(encode_completion(&c).is_err());
    c.result = None;
    assert!(encode_completion(&c).is_err());
    c.header.result = -22;
    assert_eq!(
        decode_completion(&encode_completion(&c).unwrap()).unwrap(),
        c
    );
    let r = Rejection {
        header: c.header,
        lifecycle: ColdLifecycle::Fault,
        message: "rejected".into(),
    };
    let bytes = encode_rejection(&r).unwrap();
    assert_eq!(decode_rejection(&bytes).unwrap(), r);
    assert!(decode_completion(&bytes).is_err());
    c.header.operation = 8;
    assert!(encode_completion(&c).is_err());
}
#[test]
fn capture_paths_hashes_counts_and_strings_are_bounded() {
    for path in ["/absolute", "../escape", "a/../escape", "a//b", "a\\b", ""] {
        assert!(manifest(path).is_err());
    }
    assert!(manifest(&"x".repeat(513)).is_err());
    assert!(sha(&"A".repeat(64)).is_err());
    assert!(sha(&"a".repeat(63)).is_err());
    let mut c = completion(1, ResultValue::Held(cur()));
    c.message = "x".repeat(8193);
    assert!(encode_completion(&c).is_err());
    c.message = "a\0b".into();
    assert!(encode_completion(&c).is_err());
    assert!(rule(Rule::ModelTime(0)).is_err());
    assert!(rule(Rule::ModelTime(1 << 63)).is_err());
    assert!(rule(Rule::DiscardExposures(4097)).is_err());
}
