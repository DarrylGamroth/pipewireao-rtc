//! Bounded native Props projection of the RTC owner's realization intent.

use crate::ScientificDiagnostic;
use pipewire as pw;
use pw::spa::pod::serialize::PodSerializer;
use pw::spa::pod::{Object, Property, Value};
use pw::spa::utils::{Id, SpaTypes};
use std::io::Cursor;

pub(super) const MAX_LINKS: usize = 32;
const ENCODED_BOUND: usize = 16 * 1024;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct Identity {
    pub global_id: u32,
    pub serial: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct Endpoint {
    pub node: Identity,
    pub port: Identity,
    pub owner: Identity,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct Link {
    pub index: usize,
    pub output: Endpoint,
    pub input: Endpoint,
    pub passive: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u32)]
pub(super) enum Phase {
    Prepared = 0,
    Realize = 1,
    Withdraw = 2,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct Intent {
    pub generation: i64,
    pub runtime: Identity,
    pub manager: Identity,
    pub links: Vec<Link>,
}

fn diagnostic(error: impl std::fmt::Display) -> ScientificDiagnostic {
    ScientificDiagnostic::new("WirePlumber realization intent", error.to_string())
}

fn validate_identity(identity: Identity) -> Result<(), ScientificDiagnostic> {
    if identity.global_id == 0 || identity.global_id == u32::MAX || identity.serial == 0 {
        return Err(diagnostic(
            "identity requires a valid global ID and nonzero serial",
        ));
    }
    Ok(())
}

fn validate(intent: &Intent) -> Result<(), ScientificDiagnostic> {
    if intent.generation <= 0 {
        return Err(diagnostic("generation must be positive"));
    }
    // Validate count before traversal or constructing any recursive POD values.
    // All strings and nesting are fixed, so this bounds the encoding work.
    if intent.links.is_empty() || intent.links.len() > MAX_LINKS {
        return Err(diagnostic("realization requires between 1 and 32 links"));
    }
    validate_identity(intent.runtime)?;
    validate_identity(intent.manager)?;
    for (position, link) in intent.links.iter().enumerate() {
        if i32::try_from(link.index).is_err() {
            return Err(diagnostic("link index exceeds SPA Int capacity"));
        }
        for endpoint in [link.output, link.input] {
            validate_identity(endpoint.node)?;
            validate_identity(endpoint.port)?;
            validate_identity(endpoint.owner)?;
        }
        for previous in &intent.links[..position] {
            if previous.index == link.index {
                return Err(diagnostic("duplicate link index"));
            }
            // One snapshot cannot declare two links between the same global
            // endpoints, including conflicting serials or passive flags.
            if previous.output.node.global_id == link.output.node.global_id
                && previous.output.port.global_id == link.output.port.global_id
                && previous.input.node.global_id == link.input.node.global_id
                && previous.input.port.global_id == link.input.port.global_id
            {
                return Err(diagnostic("duplicate link endpoints"));
            }
        }
    }
    Ok(())
}

fn identity_value(identity: Identity) -> Value {
    Value::Struct(vec![
        Value::Id(Id(identity.global_id)),
        // SPA Long carries the full unsigned serial as an unchanged bit pattern.
        Value::Long(i64::from_ne_bytes(identity.serial.to_ne_bytes())),
    ])
}

fn endpoint_value(endpoint: Endpoint) -> Value {
    Value::Struct(vec![
        identity_value(endpoint.node),
        identity_value(endpoint.port),
        identity_value(endpoint.owner),
    ])
}

pub(super) fn encode(intent: &Intent, phase: Phase) -> Result<Vec<u8>, ScientificDiagnostic> {
    validate(intent)?;
    let links = intent
        .links
        .iter()
        .map(|link| {
            Value::Struct(vec![
                Value::Int(i32::try_from(link.index).expect("validated link index")),
                endpoint_value(link.output),
                endpoint_value(link.input),
                Value::Bool(link.passive),
            ])
        })
        .collect();
    let fields = [
        ("version", Value::Int(1)),
        ("generation", Value::Long(intent.generation)),
        ("phase", Value::Id(Id(phase as u32))),
        ("runtime", identity_value(intent.runtime)),
        ("manager", identity_value(intent.manager)),
        ("links", Value::Struct(links)),
    ];
    let value = Value::Object(Object {
        type_: SpaTypes::ObjectParamProps.as_raw(),
        id: pw::spa::param::ParamType::Props.as_raw(),
        properties: vec![Property::new(
            pw::spa::sys::SPA_PROP_params,
            Value::Struct(
                fields
                    .into_iter()
                    .flat_map(|(name, value)| [Value::String(name.into()), value])
                    .collect(),
            ),
        )],
    });
    let bytes = PodSerializer::serialize(Cursor::new(Vec::new()), &value)
        .map_err(diagnostic)?
        .0
        .into_inner();
    if bytes.len() > ENCODED_BOUND {
        return Err(diagnostic("realization Props exceeds 16 KiB"));
    }
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use pw::spa::pod::deserialize::PodDeserializer;

    fn identity(global_id: u32) -> Identity {
        Identity {
            global_id,
            serial: u64::from(global_id) + 100,
        }
    }

    fn endpoint(base: u32) -> Endpoint {
        Endpoint {
            node: identity(base),
            port: identity(base + 1),
            owner: identity(base + 2),
        }
    }

    fn intent() -> Intent {
        Intent {
            generation: 9,
            runtime: identity(1),
            manager: identity(2),
            links: vec![
                Link {
                    index: 5,
                    output: endpoint(10),
                    input: endpoint(20),
                    passive: true,
                },
                Link {
                    index: 2,
                    output: endpoint(30),
                    input: endpoint(40),
                    passive: false,
                },
            ],
        }
    }

    fn decode(bytes: &[u8]) -> Object {
        let (remaining, value) = PodDeserializer::deserialize_any_from(bytes).unwrap();
        assert!(remaining.is_empty());
        let Value::Object(object) = value else {
            panic!("expected Props object");
        };
        object
    }

    fn fields(object: &Object) -> &[Value] {
        assert_eq!(object.type_, SpaTypes::ObjectParamProps.as_raw());
        assert_eq!(object.id, pw::spa::param::ParamType::Props.as_raw());
        assert_eq!(object.properties.len(), 1);
        assert_eq!(object.properties[0].key, pw::spa::sys::SPA_PROP_params);
        let Value::Struct(fields) = &object.properties[0].value else {
            panic!("expected params Struct");
        };
        fields
    }

    #[test]
    fn exact_native_types_names_order_and_link_rows() {
        let bytes = encode(&intent(), Phase::Realize).unwrap();
        let object = decode(&bytes);
        let id = |global_id: u32| {
            Value::Struct(vec![
                Value::Id(Id(global_id)),
                Value::Long(i64::from(global_id) + 100),
            ])
        };
        let endpoint = |base: u32| Value::Struct(vec![id(base), id(base + 1), id(base + 2)]);
        assert_eq!(
            object,
            Object {
                type_: SpaTypes::ObjectParamProps.as_raw(),
                id: pw::spa::param::ParamType::Props.as_raw(),
                properties: vec![Property::new(
                    pw::spa::sys::SPA_PROP_params,
                    Value::Struct(vec![
                        Value::String("version".into()),
                        Value::Int(1),
                        Value::String("generation".into()),
                        Value::Long(9),
                        Value::String("phase".into()),
                        Value::Id(Id(1)),
                        Value::String("runtime".into()),
                        id(1),
                        Value::String("manager".into()),
                        id(2),
                        Value::String("links".into()),
                        Value::Struct(vec![
                            Value::Struct(vec![
                                Value::Int(5),
                                endpoint(10),
                                endpoint(20),
                                Value::Bool(true),
                            ]),
                            Value::Struct(vec![
                                Value::Int(2),
                                endpoint(30),
                                endpoint(40),
                                Value::Bool(false),
                            ]),
                        ]),
                    ]),
                )],
            }
        );
    }

    #[test]
    fn phase_is_the_only_changing_field() {
        let intent = intent();
        let original = intent.clone();
        let prepared = decode(&encode(&intent, Phase::Prepared).unwrap());
        for (phase, phase_id) in [
            (Phase::Prepared, 0),
            (Phase::Realize, 1),
            (Phase::Withdraw, 2),
        ] {
            let object = decode(&encode(&intent, phase).unwrap());
            assert_eq!(fields(&object)[5], Value::Id(Id(phase_id)));
            let mut expected = prepared.clone();
            let Value::Struct(fields) = &mut expected.properties[0].value else {
                unreachable!();
            };
            fields[5] = Value::Id(Id(phase_id));
            assert_eq!(object, expected);
        }
        assert_eq!(intent, original);
    }

    #[test]
    fn unsigned_serial_bit_patterns_are_preserved() {
        for serial in [1, u64::try_from(i64::MAX).unwrap(), 1_u64 << 63, u64::MAX] {
            let mut intent = intent();
            intent.runtime.serial = serial;
            intent.manager.serial = serial;
            intent.links[0].output.node.serial = serial;
            let object = decode(&encode(&intent, Phase::Prepared).unwrap());
            let fields = fields(&object);
            let Value::Struct(links) = &fields[11] else {
                panic!("links Struct");
            };
            let Value::Struct(link) = &links[0] else {
                panic!("link Struct");
            };
            let Value::Struct(output) = &link[1] else {
                panic!("output Struct");
            };
            for value in [&fields[7], &fields[9], &output[0]] {
                let Value::Struct(identity) = value else {
                    panic!("identity Struct");
                };
                let Value::Long(long) = identity[1] else {
                    panic!("serial Long");
                };
                assert_eq!(u64::from_ne_bytes(long.to_ne_bytes()), serial);
            }
        }
    }

    #[test]
    fn generation_count_and_index_are_bounded() {
        for generation in [0, -1, i64::MIN] {
            let mut intent = intent();
            intent.generation = generation;
            assert!(encode(&intent, Phase::Prepared).is_err());
        }
        let mut intent = intent();
        intent.links.clear();
        assert!(encode(&intent, Phase::Prepared).is_err());
        for index in 0..MAX_LINKS {
            let base = u32::try_from(index).unwrap() * 10;
            intent.links.push(Link {
                index,
                output: endpoint(10 + base),
                input: endpoint(15 + base),
                passive: index % 2 == 0,
            });
        }
        let bytes = encode(&intent, Phase::Prepared).unwrap();
        assert!(bytes.len() <= ENCODED_BOUND);
        let object = decode(&bytes);
        let Value::Struct(links) = &fields(&object)[11] else {
            panic!("links Struct");
        };
        assert_eq!(links.len(), MAX_LINKS);
        intent.links.push(Link {
            index: MAX_LINKS,
            output: endpoint(500),
            input: endpoint(600),
            passive: false,
        });
        assert!(encode(&intent, Phase::Prepared).is_err());
        intent.links.pop();
        intent.links[0].index = usize::try_from(i32::MAX).unwrap();
        assert!(encode(&intent, Phase::Prepared).is_ok());
        intent.links[0].index += 1;
        assert!(encode(&intent, Phase::Prepared).is_err());
    }

    #[test]
    fn duplicate_indices_and_endpoints_are_rejected() {
        let mut duplicate_index = intent();
        duplicate_index.links[1].index = duplicate_index.links[0].index;
        assert!(encode(&duplicate_index, Phase::Prepared).is_err());
        let mut duplicate_endpoints = intent();
        duplicate_endpoints.links[1].output = duplicate_endpoints.links[0].output;
        duplicate_endpoints.links[1].input = duplicate_endpoints.links[0].input;
        assert_ne!(
            duplicate_endpoints.links[1].passive,
            duplicate_endpoints.links[0].passive
        );
        assert!(encode(&duplicate_endpoints, Phase::Prepared).is_err());
        duplicate_endpoints.links[1].output.node.serial += 1;
        assert!(encode(&duplicate_endpoints, Phase::Prepared).is_err());
    }

    #[test]
    fn every_identity_rejects_invalid_global_ids_and_zero_serial() {
        for bad in [
            Identity {
                global_id: 0,
                serial: 1,
            },
            Identity {
                global_id: u32::MAX,
                serial: 1,
            },
            Identity {
                global_id: 1,
                serial: 0,
            },
        ] {
            for position in 0..8 {
                let mut intent = intent();
                let identity = match position {
                    0 => &mut intent.runtime,
                    1 => &mut intent.manager,
                    2 => &mut intent.links[0].output.node,
                    3 => &mut intent.links[0].output.port,
                    4 => &mut intent.links[0].output.owner,
                    5 => &mut intent.links[0].input.node,
                    6 => &mut intent.links[0].input.port,
                    7 => &mut intent.links[0].input.owner,
                    _ => unreachable!(),
                };
                *identity = bad;
                assert!(encode(&intent, Phase::Prepared).is_err());
            }
        }
    }
}
