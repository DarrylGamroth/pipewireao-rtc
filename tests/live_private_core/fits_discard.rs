use pipewire as pw;
use pw::properties::PropertiesBox;
use pw::proxy::ProxyT;
use pw::registry::GlobalObject;
use pw::types::ObjectType;
use std::cell::{Cell, RefCell};
use std::collections::BTreeMap;
use std::path::Path;
use std::rc::Rc;
use std::time::Duration;

pub const SOURCE_NAME: &str = "pipewireao-rtc-fits-source";
pub const SINK_NAME: &str = "pipewireao-rtc-fits-discard";

const UNRELATED_NAME: &str = "pipewireao-rtc-unrelated";
const SPA_NODE_FACTORY: &str = "spa-node-factory";
const TEST_SCHEMA: &str = "org.pipewireao.rtc.test.fits-discard/1";
const IMAGE_WIDTH: usize = 4;
const IMAGE_HEIGHT: usize = 3;
const IMAGE_BYTES: u64 = (IMAGE_WIDTH * IMAGE_HEIGHT * size_of::<u16>()) as u64;
const DISCARD_BUFFERS: u32 = 0x0100_0000;
const DISCARD_DATA_BLOCKS: u32 = DISCARD_BUFFERS + 1;
const DISCARD_BYTES: u32 = DISCARD_BUFFERS + 2;
const DISCARD_PROTOCOL_ERRORS: u32 = DISCARD_BUFFERS + 3;
const DISCARD_PROCESS_CALLS: u32 = DISCARD_BUFFERS + 4;
const METRIC_SEQUENCE: i32 = 0x4644;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct DiscardMetrics {
    buffers: u64,
    data_blocks: u64,
    bytes: u64,
    protocol_errors: u64,
    process_calls: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum LinkAdmission {
    Pending(String),
    Active,
    Failed(String),
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct LinkObservation {
    id: Option<u32>,
    admission: LinkAdmission,
}

struct CoreClient {
    globals: Rc<RefCell<BTreeMap<u32, GlobalObject<PropertiesBox>>>>,
    errors: Rc<RefCell<Vec<String>>>,
    _registry_listener: pw::registry::Listener,
    _core_listener: pw::core::Listener,
    _registry: pw::registry::RegistryRc,
    core: pw::core::CoreRc,
    _context: pw::context::ContextRc,
    main_loop: pw::main_loop::MainLoopRc,
}

impl CoreClient {
    fn connect(remote_name: &str) -> Self {
        pw::init();
        let main_loop = pw::main_loop::MainLoopRc::new(None).expect("FITS fixture main loop");
        let context = pw::context::ContextRc::new(&main_loop, None).expect("FITS fixture context");
        let properties = [("remote.name", remote_name.to_owned())]
            .into_iter()
            .collect::<PropertiesBox>();
        let core = context
            .connect_rc(Some(properties))
            .expect("connect FITS fixture to private core");
        let registry = core.get_registry_rc().expect("FITS fixture registry");

        let globals = Rc::new(RefCell::new(BTreeMap::new()));
        let added = Rc::clone(&globals);
        let removed = Rc::clone(&globals);
        let registry_listener = registry
            .add_listener_local()
            .global(move |global| {
                added.borrow_mut().insert(global.id, global.to_owned());
            })
            .global_remove(move |id| {
                removed.borrow_mut().remove(&id);
            })
            .register();

        let errors = Rc::new(RefCell::new(Vec::new()));
        let reported = Rc::clone(&errors);
        let core_listener = core
            .add_listener_local()
            .error(move |id, sequence, result, message| {
                reported.borrow_mut().push(format!(
                    "object {id}, sequence {sequence}, status {result}: {message}"
                ));
            })
            .register();

        let client = Self {
            globals,
            errors,
            _registry_listener: registry_listener,
            _core_listener: core_listener,
            _registry: registry,
            core,
            _context: context,
            main_loop,
        };
        client.roundtrip("initial registry discovery");
        client
    }

    fn roundtrip(&self, operation: &str) {
        let complete = Rc::new(Cell::new(false));
        let observed = Rc::clone(&complete);
        let main_loop = self.main_loop.clone();
        let sequence = self.core.sync(0).expect("private-core synchronization");
        let _listener = self
            .core
            .add_listener_local()
            .done(move |id, done_sequence| {
                if id == pw::core::PW_ID_CORE && done_sequence == sequence {
                    observed.set(true);
                    main_loop.quit();
                }
            })
            .register();
        while !complete.get() {
            self.main_loop.run();
        }
        let errors = std::mem::take(&mut *self.errors.borrow_mut());
        assert!(
            errors.is_empty(),
            "{operation} reported PipeWire errors: {errors:?}"
        );
    }

    fn node_id(&self, name: &str) -> Option<u32> {
        let matches = self
            .globals
            .borrow()
            .values()
            .filter(|global| {
                global.type_ == ObjectType::Node
                    && global
                        .props
                        .as_ref()
                        .and_then(|properties| properties.get("node.name"))
                        == Some(name)
            })
            .map(|global| global.id)
            .collect::<Vec<_>>();
        assert!(matches.len() <= 1, "duplicate node name {name:?}");
        matches.first().copied()
    }

    fn wait_for_node(&self, name: &str) -> u32 {
        for _ in 0..100 {
            self.roundtrip(&format!("node {name:?} discovery"));
            if let Some(id) = self.node_id(name) {
                return id;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        let visible = self
            .globals
            .borrow()
            .values()
            .filter(|global| global.type_ == ObjectType::Node)
            .filter_map(|global| {
                global
                    .props
                    .as_ref()
                    .and_then(|properties| properties.get("node.name"))
                    .map(str::to_owned)
            })
            .collect::<Vec<_>>();
        panic!("node {name:?} did not become inspectable; visible nodes {visible:?}");
    }

    fn port_id(&self, node_id: u32, direction: &str) -> Option<u32> {
        let node_id = node_id.to_string();
        let matches = self
            .globals
            .borrow()
            .values()
            .filter(|global| {
                if global.type_ != ObjectType::Port {
                    return false;
                }
                let Some(properties) = global.props.as_ref() else {
                    return false;
                };
                properties.get("node.id") == Some(node_id.as_str())
                    && properties.get("port.direction") == Some(direction)
            })
            .map(|global| global.id)
            .collect::<Vec<_>>();
        assert!(
            matches.len() <= 1,
            "node {node_id} exposes duplicate {direction} ports"
        );
        matches.first().copied()
    }

    fn wait_for_port(&self, node_id: u32, direction: &str) -> u32 {
        for _ in 0..100 {
            self.roundtrip(&format!("node {node_id} {direction} port discovery"));
            if let Some(id) = self.port_id(node_id, direction) {
                return id;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        panic!("node {node_id} did not expose one {direction} port");
    }

    fn link_factory(&self) -> String {
        self.globals
            .borrow()
            .values()
            .find_map(|global| {
                if global.type_ != ObjectType::Factory {
                    return None;
                }
                let properties = global.props.as_ref()?;
                (properties.get("factory.type.name") == Some(ObjectType::Link.to_str()))
                    .then(|| properties.get("factory.name").map(str::to_owned))
                    .flatten()
            })
            .expect("private core exposes a public link factory")
    }

    fn visible(&self, id: u32) -> bool {
        self.globals.borrow().contains_key(&id)
    }

    fn wait_for_removal(&self, ids: &[u32]) {
        for _ in 0..100 {
            self.roundtrip("FITS fixture owned-object cleanup");
            if ids.iter().all(|id| !self.visible(*id)) {
                return;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        let remaining = ids
            .iter()
            .copied()
            .filter(|id| self.visible(*id))
            .collect::<Vec<_>>();
        panic!("FITS fixture objects survived cleanup: {remaining:?}");
    }
}

#[allow(clippy::too_many_lines)]
pub fn run(remote_name: &str, image_path: &Path) {
    write_test_image(image_path);
    let client = CoreClient::connect(remote_name);
    assert!(
        client.node_id(UNRELATED_NAME).is_some(),
        "unrelated fixture node must predate FITS transport creation"
    );

    let sink_properties = [
        ("factory.name", "api.pipewireao.discard"),
        ("node.name", SINK_NAME),
        (
            "node.description",
            "RTC private-core FITS transport discard sink",
        ),
        ("node.virtual", "true"),
        ("node.want-driver", "true"),
        ("object.linger", "false"),
    ]
    .into_iter()
    .collect::<PropertiesBox>();
    let sink = client
        .core
        .create_object::<pw::node::Node>(SPA_NODE_FACTORY, &sink_properties)
        .expect("create RTC-owned discard sink");
    let sink_errors = Rc::clone(&client.errors);
    let sink_proxy_listener = sink
        .upcast_ref()
        .add_listener_local()
        .error(move |sequence, result, message| {
            sink_errors.borrow_mut().push(format!(
                "discard proxy sequence {sequence}, status {result}: {message}"
            ));
        })
        .register();

    let metrics = Rc::new(RefCell::new(None));
    let observed_metrics = Rc::clone(&metrics);
    let sink_listener = sink
        .add_listener_local()
        .param(move |_sequence, param_type, _index, _next, param| {
            if param_type != pw::spa::param::ParamType::Props {
                return;
            }
            let result = param
                .ok_or_else(|| "empty discard Props parameter".to_owned())
                .and_then(|pod| {
                    pod.as_object()
                        .map_err(|error| format!("discard Props is not an object: {error}"))
                })
                .and_then(parse_metrics);
            *observed_metrics.borrow_mut() = Some(result);
        })
        .register();

    let image = image_path.to_str().expect("UTF-8 FITS fixture path");
    let source_properties = [
        ("factory.name", "api.fits.source"),
        ("node.name", SOURCE_NAME),
        (
            "node.description",
            "RTC private-core complete-frame FITS source",
        ),
        ("node.virtual", "true"),
        ("object.linger", "false"),
        ("api.fits.path", image),
        ("api.fits.sample-rank", "2"),
        ("api.fits.rate", "1/1"),
        ("api.fits.schema", TEST_SCHEMA),
        ("api.fits.loop", "false"),
        ("api.fits.readiness", "timerfd"),
        ("api.fits.output-mode", "frame"),
    ]
    .into_iter()
    .collect::<PropertiesBox>();
    let source = client
        .core
        .create_object::<pw::node::Node>(SPA_NODE_FACTORY, &source_properties)
        .expect("create RTC-owned FITS source");
    let source_errors = Rc::clone(&client.errors);
    let source_proxy_listener = source
        .upcast_ref()
        .add_listener_local()
        .error(move |sequence, result, message| {
            source_errors.borrow_mut().push(format!(
                "FITS proxy sequence {sequence}, status {result}: {message}"
            ));
        })
        .register();

    let sink_id = client.wait_for_node(SINK_NAME);
    let source_id = client.wait_for_node(SOURCE_NAME);
    let sink_port = client.wait_for_port(sink_id, "in");
    let source_port = client.wait_for_port(source_id, "out");
    assert_eq!(client.port_id(sink_id, "out"), None);
    assert_eq!(client.port_id(source_id, "in"), None);

    let link_properties = [
        ("link.output.node", source_id.to_string()),
        ("link.output.port", source_port.to_string()),
        ("link.input.node", sink_id.to_string()),
        ("link.input.port", sink_port.to_string()),
        ("object.linger", "false".to_owned()),
    ]
    .into_iter()
    .collect::<PropertiesBox>();
    let link = client
        .core
        .create_object::<pw::link::Link>(&client.link_factory(), &link_properties)
        .expect("create exact FITS-to-discard link");
    let link_observation = Rc::new(RefCell::new(LinkObservation {
        id: None,
        admission: LinkAdmission::Pending("no link information".to_owned()),
    }));
    let observed_link = Rc::clone(&link_observation);
    let link_listener = link
        .add_listener_local()
        .info(move |info| {
            let admission = match info.state() {
                pw::link::LinkState::Active => LinkAdmission::Active,
                pw::link::LinkState::Error(error) => LinkAdmission::Failed(error.to_owned()),
                pw::link::LinkState::Unlinked => {
                    LinkAdmission::Failed("link became unlinked".to_owned())
                }
                state => LinkAdmission::Pending(format!("{state:?}")),
            };
            *observed_link.borrow_mut() = LinkObservation {
                id: Some(info.id()),
                admission,
            };
        })
        .register();

    for _ in 0..100 {
        client.roundtrip("FITS-to-discard link admission");
        match &link_observation.borrow().admission {
            LinkAdmission::Active => break,
            LinkAdmission::Failed(error) => panic!("FITS-to-discard link failed: {error}"),
            LinkAdmission::Pending(_) => std::thread::sleep(Duration::from_millis(5)),
        }
    }
    assert_eq!(
        link_observation.borrow().admission,
        LinkAdmission::Active,
        "FITS-to-discard link did not become active"
    );

    let delivered = (0..100).find_map(|_| {
        *metrics.borrow_mut() = None;
        sink.enum_params(
            METRIC_SEQUENCE,
            Some(pw::spa::param::ParamType::Props),
            0,
            1,
        );
        client.roundtrip("discard metric observation");
        let observed = metrics.borrow().clone();
        match observed {
            Some(Ok(value)) if value.buffers > 0 => Some(value),
            Some(Ok(_)) | None => {
                std::thread::sleep(Duration::from_millis(5));
                None
            }
            Some(Err(error)) => panic!("invalid discard metrics: {error}"),
        }
    });
    let delivered = delivered.expect("one complete FITS image reached the discard sink");
    assert_eq!(delivered.buffers, 1);
    assert_eq!(delivered.data_blocks, 1);
    assert_eq!(delivered.bytes, IMAGE_BYTES);
    assert_eq!(delivered.protocol_errors, 0);
    assert!(delivered.process_calls >= delivered.buffers);

    let link_id = link_observation
        .borrow()
        .id
        .expect("inspectable FITS-to-discard link ID");
    drop(link_listener);
    drop(link);
    client.roundtrip("FITS-to-discard link cleanup");
    drop(sink_listener);
    drop(source_proxy_listener);
    drop(sink_proxy_listener);
    drop(source);
    drop(sink);
    client.wait_for_removal(&[link_id, source_id, sink_id]);
    assert!(client.node_id(UNRELATED_NAME).is_some());
}

fn parse_metrics(object: &pw::spa::pod::PodObject) -> Result<DiscardMetrics, String> {
    Ok(DiscardMetrics {
        buffers: metric(object, DISCARD_BUFFERS, "discard.buffers")?,
        data_blocks: metric(object, DISCARD_DATA_BLOCKS, "discard.data-blocks")?,
        bytes: metric(object, DISCARD_BYTES, "discard.bytes")?,
        protocol_errors: metric(object, DISCARD_PROTOCOL_ERRORS, "discard.protocol-errors")?,
        process_calls: metric(object, DISCARD_PROCESS_CALLS, "discard.process-calls")?,
    })
}

fn metric(object: &pw::spa::pod::PodObject, id: u32, name: &str) -> Result<u64, String> {
    let value = object
        .find_prop(pw::spa::utils::Id(id))
        .ok_or_else(|| format!("{name} is missing"))?
        .value()
        .get_long()
        .map_err(|error| format!("{name} is not a Long: {error}"))?;
    u64::try_from(value).map_err(|_| format!("{name} is negative: {value}"))
}

fn write_test_image(path: &Path) {
    let mut image = Vec::new();
    for (keyword, value) in [
        ("SIMPLE", "T"),
        ("BITPIX", "16"),
        ("NAXIS", "2"),
        ("NAXIS1", "4"),
        ("NAXIS2", "3"),
        ("BSCALE", "1"),
        ("BZERO", "32768"),
    ] {
        push_card(&mut image, &format!("{keyword:<8}= {value:>20}"));
    }
    push_card(&mut image, "END");
    image.resize(2_880, b' ');
    for row in 0..IMAGE_HEIGHT {
        for column in 0..IMAGE_WIDTH {
            let value = u16::try_from(row * 100 + column).expect("test pixel value");
            let stored = i16::from_be_bytes(value.wrapping_add(0x8000).to_be_bytes());
            image.extend_from_slice(&stored.to_be_bytes());
        }
    }
    image.resize(5_760, 0);
    std::fs::write(path, image).expect("write complete-frame FITS fixture");
}

pub fn write_vector_sequence(path: &Path) {
    let mut vector = Vec::new();
    for (keyword, value) in [
        ("SIMPLE", "T"),
        ("BITPIX", "-32"),
        ("NAXIS", "2"),
        ("NAXIS1", "2"),
        ("NAXIS2", "4"),
    ] {
        push_card(&mut vector, &format!("{keyword:<8}= {value:>20}"));
    }
    push_card(&mut vector, "END");
    vector.resize(2_880, b' ');
    for value in [1.0_f32, -1.0, 0.5, 2.0, -0.25, 0.75, 3.0, -2.0] {
        vector.extend_from_slice(&value.to_be_bytes());
    }
    vector.resize(5_760, 0);
    std::fs::write(path, vector).expect("write FITS vector sequence");
}

fn push_card(header: &mut Vec<u8>, content: &str) {
    assert!(content.len() <= 80, "FITS card exceeds 80 bytes");
    header.extend_from_slice(content.as_bytes());
    header.resize(header.len() + 80 - content.len(), b' ');
}
