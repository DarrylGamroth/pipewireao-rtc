//! Diagnostic fixed-envelope exchange. It does not authenticate controllers,
//! run a scientific graph, or implement production lifecycle operations.

#[cfg(feature = "live")]
mod proof {
    use pipewire as pw;
    use pipewireao_rtc::native_control_codec as codec;
    use pw::properties::properties;
    use pw::spa::pod::serialize::PodSerializer;
    use pw::spa::pod::{Object, Pod, Property, Value};
    use pw::spa::utils::SpaTypes;
    use std::error::Error;
    use std::io::Cursor;
    use std::path::PathBuf;
    use std::sync::{Arc, Mutex};
    use std::time::{Duration, Instant};

    const INSTANCE: i64 = 23;
    const APPLY: u32 = 1;
    const QUERY: u32 = 2;

    // Owned encoded native payload is Send; public Value includes pointer
    // variants and cannot be retained in a Send callback's mailbox.
    struct Request {
        header: codec::RequestHeader,
        payload: Vec<u8>,
    }

    struct Pending {
        request: Request,
        deadline: Instant,
    }

    #[derive(Default)]
    struct Stage {
        pending: Option<Pending>,
        committed: Option<Request>,
        rejection: Option<codec::ReplyHeader>,
        callbacks: usize,
    }

    fn reply_header(request: &Request, result: i32) -> codec::ReplyHeader {
        codec::ReplyHeader {
            version: request.header.version,
            endpoint_instance: INSTANCE,
            controller: request.header.controller,
            token: request.header.token,
            operation: request.header.operation,
            result,
        }
    }

    fn sentinel(result: i32) -> codec::ReplyHeader {
        codec::ReplyHeader {
            version: codec::VERSION,
            endpoint_instance: INSTANCE,
            controller: codec::ControllerIdentity {
                global_id: 0,
                serial: 0,
                instance: 0,
            },
            token: 0,
            operation: 0,
            result,
        }
    }

    // A changed remaining budget must not cause a second effect or extend the
    // original accepted deadline. All actual command identity/payload fields match.
    fn same_request(left: &Request, right: &Request) -> bool {
        left.header.version == right.header.version
            && left.header.endpoint_instance == right.header.endpoint_instance
            && left.header.controller == right.header.controller
            && left.header.token == right.header.token
            && left.header.operation == right.header.operation
            && left.payload == right.payload
    }

    fn stage_request(mailbox: &Arc<Mutex<Stage>>, id: u32, pod: Option<&Pod>) {
        if id != pw::spa::param::ParamType::Props.as_raw() {
            return;
        }
        let Ok(mut state) = mailbox.lock() else {
            return;
        };
        state.callbacks += 1;
        let request = pod.and_then(|pod| codec::decode_request(pod.as_bytes()).ok());
        let Some(decoded) = request else {
            state.rejection = Some(sentinel(-22));
            return;
        };
        let header = decoded.header;
        let payload = if let Ok((buffer, _)) =
            PodSerializer::serialize(Cursor::new(Vec::new()), &Value::Struct(decoded.payload))
        {
            buffer.into_inner()
        } else {
            state.rejection = Some(sentinel(-22));
            return;
        };
        let request = Request { header, payload };
        if request.header.endpoint_instance != INSTANCE {
            // Do not fabricate a completion in another owner's incarnation.
            state.rejection = Some(sentinel(-116));
            return;
        }
        if let Some(pending) = &state.pending {
            if !same_request(&request, &pending.request) {
                state.rejection = Some(reply_header(
                    &request,
                    if request.header.token == pending.request.header.token {
                        -114
                    } else {
                        -16
                    },
                ));
            }
            return;
        }
        if let Some(committed) = &state.committed {
            if same_request(&request, committed) {
                return;
            }
            if request.header.token <= committed.header.token {
                state.rejection = Some(reply_header(
                    &request,
                    if request.header.token == committed.header.token {
                        -114
                    } else {
                        -116
                    },
                ));
                return;
            }
        }
        if !matches!(request.header.operation, APPLY | QUERY) {
            state.rejection = Some(reply_header(&request, -22));
            return;
        }
        let budget = Duration::from_nanos(
            u64::try_from(request.header.budget_ns).expect("validated positive budget"),
        );
        let Some(deadline) = Instant::now().checked_add(budget) else {
            state.rejection = Some(reply_header(&request, -22));
            return;
        };
        state.pending = Some(Pending { request, deadline });
    }

    fn pod(bytes: &[u8]) -> Result<&Pod, Box<dyn Error>> {
        Pod::from_bytes(bytes).ok_or_else(|| "incomplete serialized proof POD".into())
    }

    fn capability() -> Result<Vec<u8>, Box<dyn Error>> {
        let value = Value::Object(Object {
            type_: SpaTypes::ObjectParamProps.as_raw(),
            id: pw::spa::param::ParamType::Props.as_raw(),
            properties: vec![Property::new(
                pw::spa::sys::SPA_PROP_params,
                Value::Struct(vec![
                    Value::String("test.filter.cap.version".into()),
                    Value::Int(codec::VERSION),
                    Value::String("test.filter.cap.instance".into()),
                    Value::Long(INSTANCE),
                ]),
            )],
        });
        Ok(PodSerializer::serialize(Cursor::new(Vec::new()), &value)?
            .0
            .into_inner())
    }

    fn arguments() -> Result<(String, PathBuf), Box<dyn Error>> {
        let mut args = std::env::args().skip(1);
        let remote = args.next().ok_or("missing absolute private remote")?;
        let directory = PathBuf::from(args.next().ok_or("missing fixture directory")?);
        if args.next().is_some() || !PathBuf::from(&remote).is_absolute() {
            return Err("expected absolute remote and fixture directory".into());
        }
        Ok((remote, directory))
    }

    fn iterate(
        mainloop: &pw::main_loop::MainLoopRc,
        deadline: Instant,
    ) -> Result<(), Box<dyn Error>> {
        if mainloop.loop_().iterate(pw::loop_::Timeout::Finite(
            deadline
                .saturating_duration_since(Instant::now())
                .min(Duration::from_millis(10)),
        )) < 0
        {
            return Err("proof owner loop iteration failed".into());
        }
        Ok(())
    }

    pub fn run() -> Result<(), Box<dyn Error>> {
        let (remote, directory) = arguments()?;
        let deadline = Instant::now() + Duration::from_secs(45);
        pw::init();
        let mainloop = pw::main_loop::MainLoopRc::new(None)?;
        let context = pw::context::ContextRc::new(&mainloop, None)?;
        let core = context.connect_rc(Some(properties! { "remote.name" => remote }))?;
        let filter = pw::filter::FilterRc::new(
            core,
            "proof.control.filter",
            properties! {
                "node.name" => "proof.control.filter", "media.class" => "Control",
                "test.control.version" => "1", "test.control.instance" => INSTANCE.to_string(),
                "test.control.owner-pid" => std::process::id().to_string(),
                "test.control.profile" => "diagnostic.rtc-envelope/1",
            },
        )?;
        let mailbox = Arc::new(Mutex::new(Stage::default()));
        let callback_stage = Arc::clone(&mailbox);
        let listener = filter
            .add_local_listener::<()>()
            .param_changed(move |_, (), port, id, param| {
                if port.is_none() {
                    stage_request(&callback_stage, id, param);
                }
            })
            .register()?;
        let mut retained =
            codec::encode_completion(&sentinel(0), &[Value::Long(0), Value::Bool(false)])?;
        let cap = capability()?;
        let mut rejection = codec::encode_rejection(&sentinel(-22), &[])?;
        filter.connect(
            pw::filter::FilterFlags::INACTIVE,
            &mut [pod(&retained)?, pod(&cap)?, pod(&rejection)?],
        )?;
        std::fs::write(
            directory.join("owner-ready"),
            std::process::id().to_string(),
        )?;
        let mut adoptions: i64 = 0;
        let mut staged_marker = false;
        while !directory.join("owner-quit").is_file() {
            if Instant::now() >= deadline {
                return Err("proof owner overall deadline expired".into());
            }
            iterate(&mainloop, deadline)?;
            // No effects in callbacks. Keep the pending slot occupied until
            // native publication succeeds; rejections preserve the terminal ACK.
            let mut state = mailbox.lock().map_err(|_| "proof stage mutex poisoned")?;
            if let Some(header) = state.rejection.take() {
                rejection = codec::encode_rejection(&header, &[])?;
                filter.update_params(&mut [pod(&retained)?, pod(&cap)?, pod(&rejection)?])?;
            }
            if let Some(pending) = &state.pending {
                let expired = Instant::now() >= pending.deadline;
                let (_, payload) =
                    pw::spa::pod::deserialize::PodDeserializer::deserialize_any_from(
                        &pending.request.payload,
                    )
                    .map_err(|_| "invalid owned diagnostic payload")?;
                let valid_payload = match (pending.request.header.operation, payload) {
                    (APPLY, Value::Struct(fields)) => fields == [Value::Int(7)],
                    (QUERY, Value::Struct(fields)) => fields.is_empty(),
                    _ => false,
                };
                if pending.request.header.operation == APPLY && !staged_marker {
                    std::fs::write(directory.join("request-staged"), "")?;
                    staged_marker = true;
                }
                if expired
                    || !valid_payload
                    || pending.request.header.operation == QUERY
                    || directory.join("allow-adoption").is_file()
                {
                    let result = if expired {
                        -110
                    } else if !valid_payload {
                        -22
                    } else {
                        0
                    };
                    if result == 0 && pending.request.header.operation == APPLY {
                        adoptions += 1;
                    }
                    retained = codec::encode_completion(
                        &reply_header(&pending.request, result),
                        &[Value::Long(adoptions), Value::Bool(adoptions > 0)],
                    )?;
                    filter.update_params(&mut [pod(&retained)?, pod(&cap)?, pod(&rejection)?])?;
                    state.committed = state.pending.take().map(|pending| pending.request);
                }
            }
        }
        let callbacks = mailbox
            .lock()
            .map_err(|_| "proof stage mutex poisoned")?
            .callbacks;
        println!("ENVELOPE_PROOF callbacks={callbacks} adoptions={adoptions} ports=0 process_callback=none frames=none");
        drop(listener);
        filter.disconnect()?;
        Ok(())
    }
}

#[cfg(feature = "live")]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    proof::run()
}

#[cfg(not(feature = "live"))]
fn main() {
    eprintln!("native_control_envelope_proof requires --features live");
    std::process::exit(2);
}
