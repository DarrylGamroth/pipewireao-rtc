//! Diagnostic Julia→Rust no-port Filter proof; this is not a production schema.
//! Run with `--features live` and the private-core Julia fixture in the evidence directory.

#[cfg(feature = "live")]
mod proof {
    use pipewire as pw;
    use pw::properties::properties;
    use pw::spa::pod::deserialize::PodDeserializer;
    use pw::spa::pod::serialize::PodSerializer;
    use pw::spa::pod::{Object, Pod, Property, Value};
    use pw::spa::utils::SpaTypes;
    use std::error::Error;
    use std::io::Cursor;
    use std::path::PathBuf;
    use std::sync::{Arc, Mutex};
    use std::time::{Duration, Instant};

    const VERSION: i32 = 1;
    const INSTANCE: i64 = 23;
    const APPLY: i32 = 1;
    const QUERY: i32 = 2;
    const MAX_REQUEST_BYTES: usize = 2048;

    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    struct Request {
        kind: i32,
        token: i64,
    }

    #[derive(Default)]
    struct Stage {
        pending: Option<Request>,
        callbacks: usize,
        error: Option<String>,
    }

    fn parse_request(bytes: &[u8]) -> Result<Request, String> {
        let (remaining, value) = PodDeserializer::deserialize_any_from(bytes)
            .map_err(|error| format!("invalid request POD: {error:?}"))?;
        if !remaining.is_empty() {
            return Err("request has trailing data".into());
        }
        let Value::Object(object) = value else {
            return Err("request is not an object".into());
        };
        if object.type_ != SpaTypes::ObjectParamProps.as_raw()
            || object.id != pw::spa::param::ParamType::Props.as_raw()
            || object.properties.len() != 1
        {
            return Err("request is not exact Props".into());
        }
        let property = &object.properties[0];
        if property.key != pw::spa::sys::SPA_PROP_params || !property.flags.is_empty() {
            return Err("request has wrong property".into());
        }
        let Value::Struct(fields) = &property.value else {
            return Err("request params is not a Struct".into());
        };
        if fields.len() != 8 {
            return Err("request has wrong field count".into());
        }
        let (mut version, mut instance, mut kind, mut token) = (None, None, None, None);
        for pair in fields.chunks_exact(2) {
            match (&pair[0], &pair[1]) {
                (Value::String(name), Value::Int(value))
                    if name == "test.filter.request.version" && version.is_none() =>
                {
                    version = Some(*value);
                }
                (Value::String(name), Value::Long(value))
                    if name == "test.filter.request.instance" && instance.is_none() =>
                {
                    instance = Some(*value);
                }
                (Value::String(name), Value::Int(value))
                    if name == "test.filter.request.kind" && kind.is_none() =>
                {
                    kind = Some(*value);
                }
                (Value::String(name), Value::Long(value))
                    if name == "test.filter.request.token" && token.is_none() =>
                {
                    token = Some(*value);
                }
                _ => return Err("request has duplicate/wrong name or scalar type".into()),
            }
        }
        match (version, instance, kind, token) {
            (Some(VERSION), Some(INSTANCE), Some(kind @ (APPLY | QUERY)), Some(token))
                if token > 0 =>
            {
                Ok(Request { kind, token })
            }
            _ => Err("request has wrong incarnation/kind/token".into()),
        }
    }

    fn props(fields: &[(&str, Value)]) -> Result<Vec<u8>, Box<dyn Error>> {
        let mut values = Vec::with_capacity(fields.len() * 2);
        for (name, value) in fields {
            values.push(Value::String((*name).into()));
            values.push(value.clone());
        }
        let object = Value::Object(Object {
            type_: SpaTypes::ObjectParamProps.as_raw(),
            id: pw::spa::param::ParamType::Props.as_raw(),
            properties: vec![Property::new(
                pw::spa::sys::SPA_PROP_params,
                Value::Struct(values),
            )],
        });
        PodSerializer::serialize(Cursor::new(Vec::new()), &object)
            .map(|result| result.0.into_inner())
            .map_err(|error| format!("cannot serialize proof Props: {error:?}").into())
    }

    fn snapshot(kind: i32, token: i64, adoptions: i64) -> Result<Vec<u8>, Box<dyn Error>> {
        props(&[
            ("test.filter.snapshot.version", Value::Int(VERSION)),
            ("test.filter.snapshot.instance", Value::Long(INSTANCE)),
            ("test.filter.snapshot.kind", Value::Int(kind)),
            ("test.filter.snapshot.token", Value::Long(token)),
            ("test.filter.snapshot.adoptions", Value::Long(adoptions)),
            ("test.filter.snapshot.applied", Value::Bool(adoptions > 0)),
        ])
    }

    fn pod(bytes: &[u8]) -> Result<&Pod, Box<dyn Error>> {
        Pod::from_bytes(bytes).ok_or_else(|| "serialized proof POD is incomplete".into())
    }

    fn stage_request(stage: &Mutex<Stage>, port_present: bool, id: u32, param: Option<&Pod>) {
        let mut stage = stage.lock().expect("proof stage mutex poisoned");
        if port_present {
            stage.error = Some("control endpoint unexpectedly has a port".into());
            return;
        }
        if id != pw::spa::param::ParamType::Props.as_raw() {
            return;
        }
        let Some(param) = param else { return };
        if param.as_bytes().len() > MAX_REQUEST_BYTES {
            stage.error = Some("request exceeds diagnostic capacity".into());
            return;
        }
        // Public callback POD is borrowed. Copy before decoding; only the
        // immutable scalar request is retained after the callback returns.
        let owned = param.as_bytes().to_vec();
        match parse_request(&owned) {
            Ok(request) if stage.pending.is_none() => {
                stage.pending = Some(request);
                stage.callbacks += 1;
            }
            Ok(_) => stage.error = Some("proof stage slot busy".into()),
            Err(error) => stage.error = Some(error),
        }
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
                "node.name" => "proof.control.filter",
                "media.class" => "Control",
                "test.control.version" => VERSION.to_string(),
                "test.control.instance" => INSTANCE.to_string(),
                "test.control.owner-pid" => std::process::id().to_string(),
            },
        )?;
        let stage = Arc::new(Mutex::new(Stage::default()));
        let callback_stage = Arc::clone(&stage);
        let listener = filter
            .add_local_listener::<()>()
            .param_changed(move |_, (), port, id, param| {
                stage_request(&callback_stage, port.is_some(), id, param);
            })
            .register()?;
        let mut retained = snapshot(0, 0, 0)?;
        let capability = props(&[
            ("test.filter.cap.version", Value::Int(VERSION)),
            ("test.filter.cap.instance", Value::Long(INSTANCE)),
        ])?;
        let rejection = props(&[
            ("test.filter.reject.token", Value::Long(0)),
            ("test.filter.reject.result", Value::Int(0)),
        ])?;
        // No ports, process listener, links, driver flag or frame transport.
        filter.connect(
            pw::filter::FilterFlags::INACTIVE,
            &mut [pod(&retained)?, pod(&capability)?, pod(&rejection)?],
        )?;
        std::fs::write(
            directory.join("owner-ready"),
            std::process::id().to_string(),
        )?;
        let mut adoptions = 0;
        let mut staged_marker = false;
        while !directory.join("owner-quit").is_file() {
            if Instant::now() >= deadline {
                return Err("proof owner overall deadline expired".into());
            }
            let timeout = deadline
                .saturating_duration_since(Instant::now())
                .min(Duration::from_millis(10));
            if mainloop
                .loop_()
                .iterate(pw::loop_::Timeout::Finite(timeout))
                < 0
            {
                return Err("proof owner loop iteration failed".into());
            }
            // iterate has returned: effects run on this serialized owner,
            // outside callback dispatch. There is one fixture request in flight.
            let request = {
                let mut stage = stage.lock().map_err(|_| "proof stage mutex poisoned")?;
                if let Some(error) = stage.error.take() {
                    return Err(error.into());
                }
                stage.pending
            };
            if let Some(request) = request {
                if request.kind == APPLY && !staged_marker {
                    std::fs::write(directory.join("request-staged"), "")?;
                    staged_marker = true;
                }
                if request.kind == QUERY || directory.join("allow-adoption").is_file() {
                    if request.kind == APPLY {
                        adoptions += 1;
                    }
                    retained = snapshot(request.kind, request.token, adoptions)?;
                    filter.update_params(&mut [
                        pod(&retained)?,
                        pod(&capability)?,
                        pod(&rejection)?,
                    ])?;
                    stage
                        .lock()
                        .map_err(|_| "proof stage mutex poisoned")?
                        .pending = None;
                }
            }
        }
        let callbacks = stage
            .lock()
            .map_err(|_| "proof stage mutex poisoned")?
            .callbacks;
        println!("OWNER_PROOF language=rust callbacks={callbacks} adoptions={adoptions} ports=0 process_callback=none frames=none");
        drop(listener);
        filter.disconnect()?;
        drop(filter);
        Ok(())
    }
}

#[cfg(feature = "live")]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    proof::run()
}

#[cfg(not(feature = "live"))]
fn main() {
    eprintln!("native_filter_proof requires --features live");
    std::process::exit(2);
}
