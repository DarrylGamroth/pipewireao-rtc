use super::*;

fn request_header() -> RequestHeader {
    RequestHeader {
        version: VERSION,
        endpoint_instance: 23,
        controller: ControllerIdentity {
            global_id: 42,
            serial: 7,
            instance: 3,
        },
        token: 11,
        operation: 2,
        budget_ns: 5_000_000_000,
    }
}

fn reply_header() -> ReplyHeader {
    let request = request_header();
    ReplyHeader {
        version: request.version,
        endpoint_instance: request.endpoint_instance,
        controller: request.controller,
        token: request.token,
        operation: request.operation,
        result: 0,
    }
}

fn payload() -> NativeStruct {
    vec![
        Value::Bool(true),
        Value::Int(-3),
        Value::Long(i64::MIN),
        Value::Float(1.25),
        Value::Double(-2.5),
        Value::Id(Id(9)),
        Value::String("manifest.fits".into()),
        Value::Bytes(vec![0, 1, 255]),
        Value::Struct(vec![Value::Long(2)]),
        Value::ValueArray(ValueArray::Float(vec![0.25, 1.5, -4.0])),
    ]
}

fn raw_fields(record: Record, header: NativeStruct, payload: Value) -> Vec<u8> {
    let names = record.names();
    let value = Value::Object(Object {
        type_: SpaTypes::ObjectParamProps.as_raw(),
        id: spa::param::ParamType::Props.as_raw(),
        properties: vec![Property::new(
            spa::sys::SPA_PROP_params,
            Value::Struct(vec![
                Value::String(names.0.into()),
                Value::Struct(header),
                Value::String(names.1.into()),
                payload,
            ]),
        )],
    });
    PodSerializer::serialize(Cursor::new(Vec::new()), &value)
        .unwrap()
        .0
        .into_inner()
}

fn raw_request(header: RequestHeader, payload: Value) -> Vec<u8> {
    raw_fields(
        Record::Request,
        header_values(
            header.version,
            header.endpoint_instance,
            header.controller,
            header.token,
            header.operation,
            Value::Long(header.budget_ns),
        ),
        payload,
    )
}

fn outer_fields(bytes: &[u8]) -> [Span; 4] {
    let object = span(bytes, 0, bytes.len()).unwrap();
    children(bytes, span(bytes, object.body + 16, object.end).unwrap()).unwrap()
}

fn put_u32(bytes: &mut [u8], offset: usize, value: u32) {
    bytes[offset..offset + 4].copy_from_slice(&value.to_ne_bytes());
}

#[test]
fn request_and_reply_owned_roundtrip() {
    let header = request_header();
    let expected = payload();
    let mut bytes = encode_request(&header, &expected).unwrap();
    let request = decode_request(&bytes).unwrap();
    bytes.fill(0);
    assert_eq!(
        request,
        Request {
            header,
            payload: expected
        }
    );
    for kind in [ReplyKind::Completion, ReplyKind::Rejection] {
        let mut header = reply_header();
        header.result = if kind == ReplyKind::Completion {
            0
        } else {
            -22
        };
        let expected = payload();
        let bytes = encode_reply(kind, &header, &expected, ReplyBound::default()).unwrap();
        let reply = decode_reply(&bytes, kind, ReplyBound::default()).unwrap();
        assert_eq!(
            reply,
            Reply {
                kind,
                header,
                payload: expected
            }
        );
        let other = if kind == ReplyKind::Completion {
            ReplyKind::Rejection
        } else {
            ReplyKind::Completion
        };
        assert!(decode_reply(&bytes, other, ReplyBound::default()).is_err());
    }
}

#[test]
fn all_six_scalar_array_kinds_roundtrip_with_empty_arrays() {
    let arrays = vec![
        ValueArray::Bool(vec![false, true]),
        ValueArray::Id(vec![Id(0), Id(u32::MAX)]),
        ValueArray::Int(vec![i32::MIN, i32::MAX]),
        ValueArray::Long(vec![i64::MIN, i64::MAX]),
        ValueArray::Float(vec![-1.5, 2.25]),
        ValueArray::Double(vec![-1.5, 2.25]),
        ValueArray::Bool(vec![]),
        ValueArray::Id(vec![]),
        ValueArray::Int(vec![]),
        ValueArray::Long(vec![]),
        ValueArray::Float(vec![]),
        ValueArray::Double(vec![]),
    ];
    let payload: NativeStruct = arrays.into_iter().map(Value::ValueArray).collect();
    let bytes = encode_request(&request_header(), &payload).unwrap();
    assert_eq!(decode_request(&bytes).unwrap().payload, payload);
    assert_eq!(
        encode_request(
            &request_header(),
            &[Value::ValueArray(ValueArray::None(vec![]))]
        ),
        Err(CodecError::UnsupportedPayload)
    );
}

#[test]
fn serial_bit_patterns_and_required_positive_identity() {
    for serial in [0, (1_u64 << 63) - 1, 1_u64 << 63, u64::MAX] {
        assert_eq!(serial_from_long(serial_to_long(serial)), serial);
        let mut header = request_header();
        header.controller.serial = serial;
        if serial == 0 {
            assert_eq!(encode_request(&header, &[]), Err(CodecError::InvalidHeader));
            assert_eq!(
                decode_request(&raw_request(header, Value::Struct(vec![]))),
                Err(CodecError::InvalidHeader)
            );
        } else {
            let bytes = encode_request(&header, &[]).unwrap();
            assert_eq!(
                decode_request(&bytes).unwrap().header.controller.serial,
                serial
            );
        }
    }
    assert_eq!(serial_to_long(1_u64 << 63), i64::MIN);
    assert_eq!(serial_to_long(u64::MAX), -1);
    let original = request_header();
    let mut bad = Vec::new();
    let mut header = original;
    header.version = 0;
    bad.push(header);
    let mut header = original;
    header.version = 2;
    bad.push(header);
    let mut header = original;
    header.endpoint_instance = 0;
    bad.push(header);
    let mut header = original;
    header.endpoint_instance = -1;
    bad.push(header);
    let mut header = original;
    header.controller.global_id = 0;
    bad.push(header);
    let mut header = original;
    header.controller.global_id = u32::MAX;
    bad.push(header);
    let mut header = original;
    header.controller.instance = 0;
    bad.push(header);
    let mut header = original;
    header.controller.instance = -1;
    bad.push(header);
    let mut header = original;
    header.token = 0;
    bad.push(header);
    let mut header = original;
    header.token = -1;
    bad.push(header);
    let mut header = original;
    header.operation = 0;
    bad.push(header);
    let mut header = original;
    header.budget_ns = 0;
    bad.push(header);
    let mut header = original;
    header.budget_ns = -1;
    bad.push(header);
    for header in bad {
        assert_eq!(encode_request(&header, &[]), Err(CodecError::InvalidHeader));
        assert_eq!(
            decode_request(&raw_request(header, Value::Struct(vec![]))),
            Err(CodecError::InvalidHeader)
        );
    }
}

#[test]
fn completion_and_rejection_sentinels_are_exact() {
    let initial = ReplyHeader {
        controller: ControllerIdentity {
            global_id: 0,
            serial: 0,
            instance: 0,
        },
        token: 0,
        operation: 0,
        ..reply_header()
    };
    assert_eq!(
        decode_completion(&encode_completion(&initial, &[]).unwrap())
            .unwrap()
            .header,
        initial
    );
    assert!(encode_rejection(&initial, &[]).is_err());
    let uncorrelated = ReplyHeader {
        result: -22,
        ..initial
    };
    assert_eq!(
        decode_rejection(&encode_rejection(&uncorrelated, &[]).unwrap())
            .unwrap()
            .header,
        uncorrelated
    );
    assert!(encode_completion(&uncorrelated, &[]).is_err());
    let mut partial = Vec::new();
    let mut header = initial;
    header.controller.global_id = 42;
    partial.push(header);
    let mut header = initial;
    header.controller.serial = 7;
    partial.push(header);
    let mut header = initial;
    header.controller.instance = 3;
    partial.push(header);
    let mut header = initial;
    header.token = 11;
    partial.push(header);
    let mut header = initial;
    header.operation = 2;
    partial.push(header);
    for mut header in partial {
        assert!(encode_completion(&header, &[]).is_err());
        let raw = raw_fields(
            Record::Reply(ReplyKind::Completion),
            header_values(
                header.version,
                header.endpoint_instance,
                header.controller,
                header.token,
                header.operation,
                Value::Int(header.result),
            ),
            Value::Struct(vec![]),
        );
        assert!(decode_completion(&raw).is_err());
        header.result = -22;
        assert!(encode_rejection(&header, &[]).is_err());
        let raw = raw_fields(
            Record::Reply(ReplyKind::Rejection),
            header_values(
                header.version,
                header.endpoint_instance,
                header.controller,
                header.token,
                header.operation,
                Value::Int(header.result),
            ),
            Value::Struct(vec![]),
        );
        assert!(decode_rejection(&raw).is_err());
    }
    let mut header = reply_header();
    header.result = -1;
    assert!(encode_completion(&header, &[]).is_ok());
    header.result = 1;
    assert!(encode_completion(&header, &[]).is_err());
    assert!(encode_rejection(&header, &[]).is_err());
}

#[test]
fn bounds_include_the_entire_pod_and_require_explicit_calibration() {
    let header = request_header();
    let empty_size = encode_request(&header, &[]).unwrap().len();
    let count = REQUEST_BOUND - empty_size - 8;
    let full = encode_request(&header, &[Value::Bytes(vec![0; count])]).unwrap();
    assert_eq!(full.len(), REQUEST_BOUND);
    assert!(decode_request(&full).is_ok());
    assert!(matches!(
        encode_request(&header, &[Value::Bytes(vec![0; count + 1])]),
        Err(CodecError::Oversize { .. })
    ));
    assert!(matches!(
        encode_request(
            &header,
            &[Value::ValueArray(ValueArray::Float(vec![
                0.0;
                REQUEST_BOUND
            ]))]
        ),
        Err(CodecError::Oversize { .. })
    ));
    assert!(matches!(
        encode_request(&header, &vec![Value::None; REQUEST_BOUND]),
        Err(CodecError::Oversize { .. })
    ));
    let large = vec![Value::Bytes(vec![0; 70_000])];
    assert!(matches!(
        encode_completion(&reply_header(), &large),
        Err(CodecError::Oversize { .. })
    ));
    let bytes = encode_reply(
        ReplyKind::Completion,
        &reply_header(),
        &large,
        ReplyBound::Calibration,
    )
    .unwrap();
    assert!(matches!(
        decode_completion(&bytes),
        Err(CodecError::Oversize {
            limit: LIFECYCLE_REPLY_BOUND,
            ..
        })
    ));
    assert_eq!(
        decode_reply(&bytes, ReplyKind::Completion, ReplyBound::Calibration)
            .unwrap()
            .payload,
        large
    );
    assert!(matches!(
        decode_request(&vec![0; REQUEST_BOUND + 1]),
        Err(CodecError::Oversize {
            limit: REQUEST_BOUND,
            ..
        })
    ));
    assert!(matches!(
        decode_reply(
            &vec![0; CALIBRATION_REPLY_BOUND + 1],
            ReplyKind::Completion,
            ReplyBound::Calibration
        ),
        Err(CodecError::Oversize { .. })
    ));
}

#[test]
fn malformed_lengths_truncation_flags_names_and_scalar_widths() {
    let valid = encode_request(&request_header(), &[Value::Int(4)]).unwrap();
    for end in 0..valid.len() {
        assert!(
            decode_request(&valid[..end]).is_err(),
            "accepted truncation {end}"
        );
    }
    let fields = outer_fields(&valid);
    let header = children::<8>(&valid, fields[1]).unwrap();
    for (offset, value) in [
        (0, 0),
        (0, u32::MAX),
        (4, spa::sys::SPA_TYPE_Struct),
        (8, SpaTypes::ObjectParamFormat.as_raw()),
        (12, spa::param::ParamType::Format.as_raw()),
        (16, 0),
        (20, 1),
        (20, 0x8000_0000),
        (fields[0].body - 8, 0),
        (fields[0].body - 4, spa::sys::SPA_TYPE_Bytes),
        (header[0].body - 8, 8),
        (header[1].body - 8, 4),
        (header[2].body - 4, spa::sys::SPA_TYPE_Int),
        (header[7].body - 4, spa::sys::SPA_TYPE_Int),
        (fields[3].body - 8, 8),
        (fields[3].body - 4, spa::sys::SPA_TYPE_Object),
    ] {
        let mut bytes = valid.clone();
        put_u32(&mut bytes, offset, value);
        assert!(
            decode_request(&bytes).is_err(),
            "accepted metadata mutation at {offset}"
        );
    }
    let mut bytes = valid.clone();
    bytes[fields[0].body] = b'x';
    assert!(decode_request(&bytes).is_err());
    let mut bytes = valid.clone();
    bytes[fields[0].end - 1] = b'x';
    assert!(decode_request(&bytes).is_err());
    for extra in [1, 7, 8, 16] {
        let mut bytes = valid.clone();
        bytes.resize(bytes.len() + extra, 0);
        assert!(decode_request(&bytes).is_err());
    }
    let mut bytes = valid.clone();
    let outer = span(&valid, 24, valid.len()).unwrap();
    put_u32(&mut bytes, outer.body - 8, 4);
    assert!(decode_request(&bytes).is_err());
}

#[test]
fn exact_header_arity_order_and_payload_container() {
    let header = request_header();
    let fields = header_values(
        header.version,
        header.endpoint_instance,
        header.controller,
        header.token,
        header.operation,
        Value::Long(header.budget_ns),
    );
    for altered in [
        fields[..7].to_vec(),
        [fields.clone(), vec![Value::Int(0)]].concat(),
    ] {
        assert!(
            decode_request(&raw_fields(Record::Request, altered, Value::Struct(vec![]))).is_err()
        );
    }
    let mut altered = fields.clone();
    altered.swap(0, 1);
    assert!(decode_request(&raw_fields(Record::Request, altered, Value::Struct(vec![]))).is_err());
    for payload in [Value::Bool(false), Value::Bytes(vec![])] {
        assert!(decode_request(&raw_fields(Record::Request, fields.clone(), payload)).is_err());
    }
    let valid = raw_fields(Record::Request, fields, Value::Struct(vec![]));
    let Value::Object(mut object) = PodDeserializer::deserialize_any_from(&valid).unwrap().1 else {
        panic!("object")
    };
    object.properties.push(object.properties[0].clone());
    let bytes = PodSerializer::serialize(Cursor::new(Vec::new()), &Value::Object(object))
        .unwrap()
        .0
        .into_inner();
    assert!(decode_request(&bytes).is_err());
}

#[test]
fn outer_children_and_reply_result_types_are_exact() {
    let valid = encode_request(&request_header(), &[]).unwrap();
    let Value::Object(object) = PodDeserializer::deserialize_any_from(&valid).unwrap().1 else {
        panic!("object");
    };
    let Value::Struct(fields) = &object.properties[0].value else {
        panic!("Struct");
    };
    let mut extra = fields.clone();
    extra.push(Value::Int(0));
    let mut reordered = fields.clone();
    reordered.swap(0, 2);
    let mut renamed = fields.clone();
    renamed[2] = Value::String(REQUEST_HEADER.into());
    for altered in [fields[..3].to_vec(), extra, reordered, renamed] {
        let mut altered_object = object.clone();
        altered_object.properties[0].value = Value::Struct(altered);
        let bytes =
            PodSerializer::serialize(Cursor::new(Vec::new()), &Value::Object(altered_object))
                .unwrap()
                .0
                .into_inner();
        assert!(decode_request(&bytes).is_err());
    }
    let valid = encode_completion(&reply_header(), &[]).unwrap();
    let header = children::<8>(&valid, outer_fields(&valid)[1]).unwrap();
    for (offset, value) in [
        (header[7].body - 8, 8),
        (header[7].body - 4, spa::sys::SPA_TYPE_Long),
    ] {
        let mut bytes = valid.clone();
        put_u32(&mut bytes, offset, value);
        assert!(decode_completion(&bytes).is_err());
    }
}

#[test]
fn payload_depth_is_checked_before_recursive_decode_or_encode() {
    let mut payload = vec![Value::Int(4)];
    for _ in 1..MAX_PAYLOAD_DEPTH {
        payload = vec![Value::Struct(payload)];
    }
    let bytes = encode_request(&request_header(), &payload).unwrap();
    assert_eq!(decode_request(&bytes).unwrap().payload, payload);
    payload = vec![Value::Struct(payload)];
    assert_eq!(
        encode_request(&request_header(), &payload),
        Err(CodecError::PayloadDepth)
    );
    let bytes = raw_request(request_header(), Value::Struct(payload));
    assert_eq!(decode_request(&bytes), Err(CodecError::PayloadDepth));
    let payload = vec![Value::Object(Object {
        type_: 0,
        id: 0,
        properties: vec![],
    })];
    assert_eq!(
        encode_request(&request_header(), &payload),
        Err(CodecError::UnsupportedPayload)
    );
    assert_eq!(
        decode_request(&raw_request(request_header(), Value::Struct(payload))),
        Err(CodecError::UnsupportedPayload)
    );
}

#[test]
fn payload_array_and_string_preflight_prevents_decoder_panics() {
    let valid = encode_request(
        &request_header(),
        &[Value::ValueArray(ValueArray::Float(vec![1.0]))],
    )
    .unwrap();
    let payload = outer_fields(&valid)[3];
    let array = span(&valid, payload.body, payload.end).unwrap();
    for (offset, value) in [
        (array.body - 8, 4),
        (array.body, 0),
        (array.body, 8),
        (array.body + 4, spa::sys::SPA_TYPE_None),
        (array.body + 4, spa::sys::SPA_TYPE_Fd),
        (array.body + 4, spa::sys::SPA_TYPE_Rectangle),
        (array.body + 4, spa::sys::SPA_TYPE_Struct),
        (array.body - 4, spa::sys::SPA_TYPE_Pointer),
    ] {
        let mut bytes = valid.clone();
        put_u32(&mut bytes, offset, value);
        assert!(decode_request(&bytes).is_err());
    }
    let mut bytes = valid.clone();
    put_u32(&mut bytes, array.body - 8, 11);
    assert!(decode_request(&bytes).is_err());
    assert!(encode_request(&request_header(), &[Value::String("a\0b".into())]).is_err());
    let valid = encode_request(&request_header(), &[Value::String("abc".into())]).unwrap();
    let payload = outer_fields(&valid)[3];
    let text = span(&valid, payload.body, payload.end).unwrap();
    for bad in [0, 255] {
        let mut bytes = valid.clone();
        bytes[text.body + 1] = bad;
        assert!(decode_request(&bytes).is_err());
    }
}
