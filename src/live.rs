use crate::{
    ConfigurationInput, DevelopmentConfig, EffectExecutor, EndpointFactory, LifecycleEffect,
    ObjectRole, PortDirection, PortSpec, ScientificDiagnostic,
};
use pipewire as pw;
use pw::properties::PropertiesBox;
use pw::registry::GlobalObject;
use pw::spa::param::format::{ElementType, NdArrayFormat, NdArrayLayout};
use pw::spa::pod::{Object as PodObject, Value};
use pw::spa::utils::{Fraction, SpaTypes};
use pw::types::ObjectType;
use std::cell::{Cell, RefCell};
use std::collections::BTreeMap;
use std::ffi::CString;
use std::path::{Path, PathBuf};
use std::rc::Rc;

const SPA_NODE_FACTORY: &str = "spa-node-factory";
const FITS_LIBRARY_FILE: &str = "libspa-fits.so";
const DISCARD_LIBRARY: &str = "pipewireao/libspa-pipewireao-discard";
const DISCARD_LIBRARY_FILE: &str = "libspa-pipewireao-discard.so";
// Public IDs from pipewireao-plugins/discard.h. Keep these at the narrow
// adapter boundary until the PipeWireAO Rust bindings expose that header.
const DISCARD_BUFFERS_PROPERTY: u32 = 0x0100_0000;
const DISCARD_PROCESS_CALLS_PROPERTY: u32 = DISCARD_BUFFERS_PROPERTY + 4;
const DISCARD_METRIC_SEQUENCE: i32 = 0x4453;
const FORMAT_ENUM_SEQUENCE: i32 = 0x4654;

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct LiveGraphStatus {
    pub owned_nodes: usize,
    pub owned_links: usize,
    pub running: bool,
    pub discarded_buffers: u64,
}

struct LiveNode {
    _listener: pw::node::NodeListener,
    proxy: pw::node::Node,
    state: Rc<RefCell<String>>,
}

struct LiveLink {
    listener: pw::link::LinkListener,
    proxy: pw::link::Link,
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum LinkAdmissionState {
    Unknown,
    Pending(String),
    Ready,
    Failed(String),
}

/// Adapter for one private or explicitly named `PipeWireAO` core.
pub struct LiveGraphAdapter {
    remote_name: String,
    modules: Vec<pw::local_module::LocalModule>,
    spa_nodes: Vec<pw::node::Node>,
    links: Vec<LiveLink>,
    active_nodes: Vec<LiveNode>,
    owned_node_names: Vec<String>,
    status: LiveGraphStatus,
    globals: Rc<RefCell<BTreeMap<u32, GlobalObject<PropertiesBox>>>>,
    errors: Rc<RefCell<Vec<String>>>,
    _registry_listener: pw::registry::Listener,
    _core_listener: pw::core::Listener,
    registry: pw::registry::RegistryRc,
    core: pw::core::CoreRc,
    context: pw::context::ContextRc,
    main_loop: pw::main_loop::MainLoopRc,
}

impl LiveGraphAdapter {
    /// Connects the runner adapter to an explicitly named core.
    ///
    /// # Errors
    ///
    /// Returns a diagnostic when the main loop, context, core, or registry
    /// cannot be created through the public interface.
    pub fn connect(remote_name: impl Into<String>) -> Result<Self, ScientificDiagnostic> {
        pw::init();
        let remote_name = remote_name.into();
        let main_loop = pw::main_loop::MainLoopRc::new(None).map_err(|error| {
            ScientificDiagnostic::new("PipeWire main loop", format!("creation failed: {error}"))
        })?;
        let context = pw::context::ContextRc::new(&main_loop, None).map_err(|error| {
            ScientificDiagnostic::new("PipeWire context", format!("creation failed: {error}"))
        })?;
        let connect_properties = [("remote.name", remote_name.clone())]
            .into_iter()
            .collect::<PropertiesBox>();
        let core = context
            .connect_rc(Some(connect_properties))
            .map_err(|error| {
                ScientificDiagnostic::new(
                    "PipeWire core",
                    format!("cannot connect to {remote_name:?}: {error}"),
                )
            })?;
        let registry = core.get_registry_rc().map_err(|error| {
            ScientificDiagnostic::new("PipeWire registry", format!("cannot bind: {error}"))
        })?;

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
        let reported_errors = Rc::clone(&errors);
        let core_listener = core
            .add_listener_local()
            .error(move |id, sequence, result, message| {
                reported_errors.borrow_mut().push(format!(
                    "object {id}, sequence {sequence}, status {result}: {message}"
                ));
            })
            .register();

        let adapter = Self {
            remote_name,
            modules: Vec::new(),
            spa_nodes: Vec::new(),
            links: Vec::new(),
            active_nodes: Vec::new(),
            owned_node_names: Vec::new(),
            status: LiveGraphStatus::default(),
            globals,
            errors,
            _registry_listener: registry_listener,
            _core_listener: core_listener,
            registry,
            core,
            context,
            main_loop,
        };
        adapter.roundtrip("PipeWire registry discovery")?;
        Ok(adapter)
    }

    #[must_use]
    pub fn status(&self) -> LiveGraphStatus {
        let mut status = self.status.clone();
        status.owned_nodes = self.count_owned_nodes();
        status.owned_links = self.links.len();
        status
    }

    fn realize(&mut self, config: &DevelopmentConfig) -> Result<(), ScientificDiagnostic> {
        config.validate()?;
        self.cleanup()?;
        self.clear_errors();

        let calculon = resolve_artifact(
            "graph.plugin.path",
            &config.graph.plugin_path,
            "CALCULON_FGN_BUNDLE",
        )?;
        let sink_plugin = resolve_artifact(
            "sink.plugin.path",
            &config.sink.plugin_path,
            "PIPEWIREAO_DISCARD_PLUGIN",
        )?;
        self.owned_node_names = vec![
            config.source.node_name.clone(),
            config.graph.node_name.clone(),
            config.sink.node_name.clone(),
        ];

        let source_result = match config.source.factory {
            EndpointFactory::SimulatedCompleteFrameSource => {
                let source_plugin = resolve_artifact(
                    "source.plugin.path",
                    &config.source.plugin_path,
                    "CALCULON_FGN_BUNDLE",
                )?;
                let source_arguments =
                    render_source_args(config, &source_plugin, &self.remote_name);
                self.load_owned_module(
                    ObjectRole::Source,
                    &config.source.module,
                    &source_arguments,
                    &config.source.node_name,
                )
            }
            EndpointFactory::FitsCompleteFrameSource => {
                let source_plugin = resolve_artifact(
                    "source.plugin.path",
                    &config.source.plugin_path,
                    "PIPEWIREAO_FITS_PLUGIN",
                )?;
                self.create_owned_spa_source(config, &source_plugin)
            }
            EndpointFactory::FormatAgnosticDiscardSink => {
                unreachable!("validated source cannot use a sink factory")
            }
        };
        if let Err(error) = source_result {
            let _ = self.cleanup();
            return Err(error);
        }
        let graph_arguments = render_graph_args(config, &calculon, &self.remote_name);
        if let Err(error) = self.load_owned_module(
            ObjectRole::Graph,
            &config.graph.module,
            &graph_arguments,
            &config.graph.node_name,
        ) {
            let _ = self.cleanup();
            return Err(error);
        }
        if let Err(error) = self.create_owned_spa_sink(config, &sink_plugin) {
            let _ = self.cleanup();
            return Err(error);
        }

        if let Err(error) = self.validate_live_ports(config) {
            let _ = self.cleanup();
            return Err(error);
        }
        // Admit links downstream-first so no source can publish into a
        // partially realized processing path.
        for (index, link) in config.links.iter().enumerate().rev() {
            if let Err(error) = self.create_link(index, &link.output, &link.input) {
                let _ = self.cleanup();
                return Err(error);
            }
        }

        self.status.owned_nodes = self.count_owned_nodes();
        self.status.owned_links = self.links.len();
        if self.status.owned_nodes != 3 || self.status.owned_links != 2 {
            let diagnostic = ScientificDiagnostic::new(
                "topology",
                format!(
                    "expected exactly three owned nodes and two owned links, observed {} node(s) and {} link(s)",
                    self.status.owned_nodes, self.status.owned_links
                ),
            );
            let _ = self.cleanup();
            return Err(diagnostic);
        }
        Ok(())
    }

    fn start(&mut self) -> Result<(), ScientificDiagnostic> {
        if self.count_owned_nodes() != 3 || self.links.len() != 2 {
            return Err(ScientificDiagnostic::new(
                "topology",
                "source, graph, sink, and both declared links must exist before start",
            ));
        }
        self.clear_errors();
        self.active_nodes.clear();
        let discarded_before_start = self.discard_buffer_count()?;
        self.status.discarded_buffers = discarded_before_start;

        // Downstream-first commands prevent the source from outrunning its sink.
        for node_name in self.owned_node_names.iter().rev() {
            let global = self.node_global(node_name)?;
            let node = self
                .registry
                .bind::<pw::node::Node, _>(&global)
                .map_err(|error| {
                    ScientificDiagnostic::new(
                        format!("node {node_name}"),
                        format!("cannot bind required node: {error}"),
                    )
                })?;
            let state = Rc::new(RefCell::new(String::from("unknown")));
            let observed = Rc::clone(&state);
            let listener = node
                .add_listener_local()
                .info(move |info| {
                    *observed.borrow_mut() = format!("{:?}", info.state());
                })
                .register();
            node.send_command(&pw::spa::node::command::NodeCommand::new(
                pw::spa::node::command::NodeCommandId::START,
            ));
            self.active_nodes.push(LiveNode {
                _listener: listener,
                proxy: node,
                state,
            });
        }
        let mut states = Vec::new();
        let mut all_running = false;
        for _ in 0..100 {
            self.roundtrip("start source -> graph -> sink")?;
            states = self
                .active_nodes
                .iter()
                .map(|node| node.state.borrow().clone())
                .collect::<Vec<_>>();
            if states.iter().all(|state| state == "Running") {
                all_running = true;
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        if !all_running {
            return Err(ScientificDiagnostic::new(
                "topology",
                format!("required nodes did not all enter RUNNING; observed states {states:?}"),
            ));
        }
        self.status.discarded_buffers = self.wait_for_discarded_buffer(discarded_before_start)?;
        self.status.running = true;
        Ok(())
    }

    fn stop(&mut self) -> Result<(), ScientificDiagnostic> {
        self.clear_errors();
        for node in &self.active_nodes {
            node.proxy
                .send_command(&pw::spa::node::command::NodeCommand::new(
                    pw::spa::node::command::NodeCommandId::PAUSE,
                ));
        }
        if !self.active_nodes.is_empty() {
            self.roundtrip("stop source -> graph -> sink")?;
        }
        self.active_nodes.clear();
        self.status.running = false;
        Ok(())
    }

    fn cleanup(&mut self) -> Result<(), ScientificDiagnostic> {
        let mut first_error = self.stop().err();
        self.clear_errors();
        for link in self.links.drain(..) {
            drop(link.listener);
            // These links deliberately do not set object.linger. Destroying
            // their client proxies therefore removes the server resources;
            // additionally asking Core::destroy_object would race that
            // automatic removal and report an unknown resource.
            drop(link.proxy);
        }
        if let Err(error) = self.roundtrip("runner-owned link cleanup") {
            first_error.get_or_insert(error);
        }

        self.spa_nodes.clear();
        self.modules.clear();
        if let Err(error) = self.roundtrip("runner-owned node cleanup") {
            first_error.get_or_insert(error);
        }
        self.status = LiveGraphStatus::default();
        if self.count_owned_nodes() != 0 {
            first_error.get_or_insert_with(|| {
                ScientificDiagnostic::new(
                    "cleanup",
                    "one or more runner-owned nodes remain visible after unload",
                )
            });
        }
        self.owned_node_names.clear();
        match first_error {
            Some(error) => Err(error),
            None => Ok(()),
        }
    }

    fn load_owned_module(
        &mut self,
        role: ObjectRole,
        module_name: &str,
        arguments: &str,
        node_name: &str,
    ) -> Result<(), ScientificDiagnostic> {
        let module = CString::new(module_name).map_err(|_| {
            ScientificDiagnostic::new(
                format!("{}.module", role.name()),
                "module name contains a NUL byte",
            )
        })?;
        let arguments = CString::new(arguments).map_err(|_| {
            ScientificDiagnostic::new(
                format!("{}.module.args", role.name()),
                "rendered module arguments contain a NUL byte",
            )
        })?;
        let owned =
            pw::local_module::LocalModule::load(&self.context, &module, Some(&arguments), None)
                .map_err(|error| {
                    let message = format!("PipeWireAO rejected module {module_name:?}: {error}");
                    ScientificDiagnostic::new(role.name(), message)
                })?;
        self.modules.push(owned);
        self.wait_for_owned_node(role, node_name)
    }

    fn create_owned_spa_sink(
        &mut self,
        config: &DevelopmentConfig,
        plugin: &Path,
    ) -> Result<(), ScientificDiagnostic> {
        if plugin.file_name().and_then(|name| name.to_str()) != Some(DISCARD_LIBRARY_FILE) {
            return Err(ScientificDiagnostic::new(
                "sink.plugin.path",
                format!(
                    "expected maintained discard plugin {DISCARD_LIBRARY_FILE:?}, got {}",
                    plugin.display()
                ),
            ));
        }
        let properties = [
            ("factory.name", config.sink.factory.configured_name()),
            ("library.name", DISCARD_LIBRARY),
            ("node.name", config.sink.node_name.as_str()),
            (
                "node.description",
                "PipeWireAO RTC non-actuating discard sink",
            ),
            ("node.virtual", "true"),
            ("node.want-driver", "true"),
            ("object.linger", "false"),
        ]
        .into_iter()
        .collect::<PropertiesBox>();
        let node = self
            .core
            .create_object::<pw::node::Node>(SPA_NODE_FACTORY, &properties)
            .map_err(|error| {
                ScientificDiagnostic::new(
                    "sink.factory",
                    format!(
                        "PipeWire spa-node-factory rejected {:?}: {error}",
                        config.sink.factory.configured_name()
                    ),
                )
            })?;
        self.spa_nodes.push(node);
        self.wait_for_owned_node(ObjectRole::Sink, &config.sink.node_name)
    }

    fn create_owned_spa_source(
        &mut self,
        config: &DevelopmentConfig,
        plugin: &Path,
    ) -> Result<(), ScientificDiagnostic> {
        if plugin.file_name().and_then(|name| name.to_str()) != Some(FITS_LIBRARY_FILE) {
            return Err(ScientificDiagnostic::new(
                "source.plugin.path",
                format!(
                    "expected maintained FITS plugin {FITS_LIBRARY_FILE:?}, got {}",
                    plugin.display()
                ),
            ));
        }
        let image = resolve_file_reference(
            "source.args.api.fits.path",
            config
                .source
                .arguments
                .get("api.fits.path")
                .expect("FITS path argument was validated"),
            "PIPEWIREAO_RTC_FITS_PATH",
        )?;
        let image = image.to_str().ok_or_else(|| {
            ScientificDiagnostic::new(
                "source.args.api.fits.path",
                "resolved FITS path is not valid UTF-8",
            )
        })?;
        let mut properties = PropertiesBox::new();
        properties.insert("factory.name", config.source.factory.configured_name());
        properties.insert("node.name", config.source.node_name.as_str());
        properties.insert(
            "node.description",
            "PipeWireAO RTC recorded complete-frame source",
        );
        properties.insert("node.virtual", "true");
        properties.insert("object.linger", "false");
        for (name, configured) in &config.source.arguments {
            if name == "api.fits.path" {
                properties.insert(name.as_str(), image);
            } else {
                properties.insert(name.as_str(), configured.as_str());
            }
        }
        let node = self
            .core
            .create_object::<pw::node::Node>(SPA_NODE_FACTORY, &properties)
            .map_err(|error| {
                ScientificDiagnostic::new(
                    "source.factory",
                    format!(
                        "PipeWire spa-node-factory rejected {:?}: {error}",
                        config.source.factory.configured_name()
                    ),
                )
            })?;
        self.spa_nodes.push(node);
        self.wait_for_owned_node(ObjectRole::Source, &config.source.node_name)
    }

    fn wait_for_owned_node(
        &self,
        role: ObjectRole,
        node_name: &str,
    ) -> Result<(), ScientificDiagnostic> {
        for _ in 0..100 {
            self.roundtrip(&format!("{} node creation", role.name()))?;
            let matches = self
                .globals
                .borrow()
                .values()
                .filter(|global| is_node_named(global, node_name))
                .count();
            if matches == 1 {
                return Ok(());
            }
            std::thread::sleep(std::time::Duration::from_millis(5));
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
        Err(ScientificDiagnostic::new(
            format!("{}.node.name", role.name()),
            format!(
                "inspectable node {node_name:?} did not appear after creation; visible nodes {visible:?}"
            ),
        ))
    }

    fn discard_buffer_count(&self) -> Result<u64, ScientificDiagnostic> {
        self.discard_metric(DISCARD_BUFFERS_PROPERTY, "discard.buffers")
    }

    fn discard_metric(
        &self,
        property_id: u32,
        metric_name: &str,
    ) -> Result<u64, ScientificDiagnostic> {
        let metric_name = metric_name.to_owned();
        let callback_metric_name = metric_name.clone();
        let global = self.node_global(
            self.owned_node_names
                .last()
                .ok_or_else(|| ScientificDiagnostic::new("sink", "sink is not realized"))?,
        )?;
        let node = self
            .registry
            .bind::<pw::node::Node, _>(&global)
            .map_err(|error| {
                ScientificDiagnostic::new(
                    format!("sink.{metric_name}"),
                    format!("cannot bind discard sink metrics: {error}"),
                )
            })?;
        let result = Rc::new(RefCell::new(None));
        let observed = Rc::clone(&result);
        let events = Rc::new(RefCell::new(Vec::new()));
        let seen_events = Rc::clone(&events);
        let _listener = node
            .add_listener_local()
            .param(move |sequence, param_type, _index, _next, param| {
                seen_events
                    .borrow_mut()
                    .push((sequence, param_type.as_raw(), param.is_some()));
                if param_type != pw::spa::param::ParamType::Props {
                    return;
                }
                let value = param
                    .ok_or_else(|| "discard sink returned an empty Props parameter".to_owned())
                    .and_then(|pod| {
                        pod.as_object()
                            .map_err(|error| format!("discard Props is not an object: {error}"))
                    })
                    .and_then(|object| {
                        object
                            .find_prop(pw::spa::utils::Id(property_id))
                            .ok_or_else(|| format!("{callback_metric_name} is missing"))
                    })
                    .and_then(|property| {
                        property.value().get_long().map_err(|error| {
                            format!("{callback_metric_name} is not a Long: {error}")
                        })
                    })
                    .and_then(|value| {
                        u64::try_from(value)
                            .map_err(|_| format!("{callback_metric_name} is negative: {value}"))
                    });
                *observed.borrow_mut() = Some(value);
            })
            .register();
        node.enum_params(
            DISCARD_METRIC_SEQUENCE,
            Some(pw::spa::param::ParamType::Props),
            0,
            1,
        );
        self.roundtrip(&format!("sink.{metric_name}"))?;
        let result = result.borrow_mut().take().ok_or_else(|| {
            ScientificDiagnostic::new(
                format!("sink.{metric_name}"),
                format!(
                    "discard sink did not return its metrics parameter; parameter events {:?}",
                    events.borrow()
                ),
            )
        })?;
        result.map_err(|message| ScientificDiagnostic::new(format!("sink.{metric_name}"), message))
    }

    fn wait_for_discarded_buffer(&self, previous: u64) -> Result<u64, ScientificDiagnostic> {
        let mut observed = previous;
        for _ in 0..100 {
            observed = self.discard_buffer_count()?;
            if observed > previous {
                return Ok(observed);
            }
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        let process_calls = self
            .discard_metric(DISCARD_PROCESS_CALLS_PROPERTY, "discard.process-calls")
            .unwrap_or(0);
        Err(ScientificDiagnostic::new(
            "sink.discard.buffers",
            format!(
                "no complete buffer reached the discard sink after start; counter remained {observed} after {process_calls} process calls"
            ),
        ))
    }

    fn validate_live_ports(&self, config: &DevelopmentConfig) -> Result<(), ScientificDiagnostic> {
        let expected = [
            (
                ObjectRole::Source,
                &config.source.node_name,
                &config.source.ports,
            ),
            (
                ObjectRole::Graph,
                &config.graph.node_name,
                &config.graph.ports,
            ),
            (ObjectRole::Sink, &config.sink.node_name, &config.sink.ports),
        ];
        for (role, node_name, ports) in expected {
            let node = self.node_global(node_name)?;
            for port in ports {
                let port_global = self
                    .port_global(node.id, &port.name, port.direction)
                    .map_err(|error| {
                        ScientificDiagnostic::new(
                            format!("node {node_name} port {}", port.name),
                            error.message().to_owned(),
                        )
                    })?;
                let format = self.enumerate_port_format(role, &port.name, &port_global)?;
                if role == ObjectRole::Sink {
                    validate_discard_wildcard(&format, role, &port.name)?;
                } else {
                    validate_ndarray_port(&format, role, port)?;
                }
            }
        }
        Ok(())
    }

    fn enumerate_port_format(
        &self,
        role: ObjectRole,
        port_name: &str,
        global: &GlobalObject<PropertiesBox>,
    ) -> Result<PodObject, ScientificDiagnostic> {
        let field = format!("{}.ports.{port_name}.format", role.name());
        let port = self
            .registry
            .bind::<pw::port::Port, _>(global)
            .map_err(|error| ScientificDiagnostic::new(&field, error.to_string()))?;
        let formats = Rc::new(RefCell::new(Vec::new()));
        let observed = Rc::clone(&formats);
        let _listener = port
            .add_listener_local()
            .param(move |_sequence, param_type, _index, _next, param| {
                if param_type != pw::spa::param::ParamType::EnumFormat {
                    return;
                }
                let decoded = param
                    .ok_or_else(|| "PipeWire returned an empty EnumFormat parameter".to_owned())
                    .and_then(|pod| {
                        pw::spa::pod::deserialize::PodDeserializer::deserialize_from::<Value>(
                            pod.as_bytes(),
                        )
                        .map_err(|error| format!("cannot decode EnumFormat: {error:?}"))
                    })
                    .and_then(|(_, value)| match value {
                        Value::Object(object) => Ok(object),
                        other => Err(format!("EnumFormat is not an object: {other:?}")),
                    });
                observed.borrow_mut().push(decoded);
            })
            .register();
        port.enum_params(
            FORMAT_ENUM_SEQUENCE,
            Some(pw::spa::param::ParamType::EnumFormat),
            0,
            u32::MAX,
        );
        self.roundtrip(&field)?;
        let mut formats = formats.borrow_mut();
        if formats.len() != 1 {
            return Err(ScientificDiagnostic::new(
                field,
                format!(
                    "expected exactly one configured EnumFormat, observed {}",
                    formats.len()
                ),
            ));
        }
        formats
            .pop()
            .expect("one format was observed")
            .map_err(|message| ScientificDiagnostic::new(field, message))
    }

    fn create_link(
        &mut self,
        index: usize,
        output: &str,
        input: &str,
    ) -> Result<(), ScientificDiagnostic> {
        let (output_node_name, output_port_name) = split_endpoint(output)?;
        let (input_node_name, input_port_name) = split_endpoint(input)?;
        let output_node_id = self.node_global(output_node_name)?.id;
        let input_node_id = self.node_global(input_node_name)?.id;
        let output_port_id = self
            .port_global(output_node_id, output_port_name, PortDirection::Output)?
            .id;
        let input_port_id = self
            .port_global(input_node_id, input_port_name, PortDirection::Input)?
            .id;
        let factory = self.link_factory()?;
        let properties = [
            ("link.output.node", output_node_id.to_string()),
            ("link.output.port", output_port_id.to_string()),
            ("link.input.node", input_node_id.to_string()),
            ("link.input.port", input_port_id.to_string()),
        ]
        .into_iter()
        .collect::<PropertiesBox>();

        self.clear_errors();
        let link = self
            .core
            .create_object::<pw::link::Link>(&factory, &properties)
            .map_err(|error| {
                ScientificDiagnostic::new(
                    format!("links[{index}] {output} -> {input}"),
                    format!("link factory rejected creation: {error}"),
                )
            })?;
        let state = Rc::new(RefCell::new(LinkAdmissionState::Unknown));
        let observed = Rc::clone(&state);
        let listener = link
            .add_listener_local()
            .info(move |info| {
                *observed.borrow_mut() = match info.state() {
                    pw::link::LinkState::Error(error) => {
                        LinkAdmissionState::Failed(error.to_owned())
                    }
                    pw::link::LinkState::Unlinked => {
                        LinkAdmissionState::Failed("link became unlinked".to_owned())
                    }
                    pw::link::LinkState::Paused | pw::link::LinkState::Active => {
                        LinkAdmissionState::Ready
                    }
                    pending => LinkAdmissionState::Pending(format!("{pending:?}")),
                };
            })
            .register();
        self.links.push(LiveLink {
            listener,
            proxy: link,
        });

        let label = format!("links[{index}] {output} -> {input}");
        for _ in 0..100 {
            self.roundtrip(&label)?;
            match state.borrow().clone() {
                LinkAdmissionState::Ready => return Ok(()),
                LinkAdmissionState::Failed(error) => {
                    return Err(ScientificDiagnostic::new(label, error));
                }
                LinkAdmissionState::Unknown | LinkAdmissionState::Pending(_) => {}
            }
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        let final_state = state.borrow().clone();
        Err(ScientificDiagnostic::new(
            label,
            format!("link did not become usable before the admission deadline; final state {final_state:?}"),
        ))
    }

    fn node_global(
        &self,
        node_name: &str,
    ) -> Result<GlobalObject<PropertiesBox>, ScientificDiagnostic> {
        let matches = self
            .globals
            .borrow()
            .values()
            .filter(|global| is_node_named(global, node_name))
            .map(GlobalObject::to_owned)
            .collect::<Vec<_>>();
        match matches.as_slice() {
            [global] => Ok(global.to_owned()),
            _ => Err(ScientificDiagnostic::new(
                format!("node {node_name}"),
                format!("expected one required node, observed {}", matches.len()),
            )),
        }
    }

    fn port_global(
        &self,
        node_id: u32,
        port_name: &str,
        direction: PortDirection,
    ) -> Result<GlobalObject<PropertiesBox>, ScientificDiagnostic> {
        let node_id = node_id.to_string();
        let direction = match direction {
            PortDirection::Input => "in",
            PortDirection::Output => "out",
        };
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
                    && properties.get("port.name").is_some_and(|name| {
                        name == port_name || name.ends_with(&format!(":{port_name}"))
                    })
                    && properties.get("port.direction") == Some(direction)
            })
            .map(GlobalObject::to_owned)
            .collect::<Vec<_>>();
        if let [global] = matches.as_slice() {
            return Ok(global.to_owned());
        }
        let visible = self
            .globals
            .borrow()
            .values()
            .filter(|global| global.type_ == ObjectType::Port)
            .filter_map(|global| global.props.as_ref())
            .filter(|properties| properties.get("node.id") == Some(node_id.as_str()))
            .map(|properties| {
                (
                    properties.get("port.name").map(str::to_owned),
                    properties.get("port.direction").map(str::to_owned),
                )
            })
            .collect::<Vec<_>>();
        Err(ScientificDiagnostic::new(
            format!("port {port_name}"),
            format!(
                "expected one {direction} port on node {node_id}, observed {}; visible ports {visible:?}",
                matches.len()
            ),
        ))
    }

    fn link_factory(&self) -> Result<String, ScientificDiagnostic> {
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
            .ok_or_else(|| {
                ScientificDiagnostic::new(
                    "link factory",
                    "private core does not expose a public PipeWire link factory",
                )
            })
    }

    fn roundtrip(&self, field: &str) -> Result<(), ScientificDiagnostic> {
        let completed = Rc::new(Cell::new(false));
        let observed = Rc::clone(&completed);
        let main_loop = self.main_loop.clone();
        let pending = self.core.sync(0).map_err(|error| {
            ScientificDiagnostic::new(field, format!("PipeWire sync failed: {error}"))
        })?;
        let _listener = self
            .core
            .add_listener_local()
            .done(move |id, sequence| {
                if id == pw::core::PW_ID_CORE && sequence == pending {
                    observed.set(true);
                    main_loop.quit();
                }
            })
            .register();
        while !completed.get() {
            self.main_loop.run();
        }
        let errors = std::mem::take(&mut *self.errors.borrow_mut());
        if errors.is_empty() {
            Ok(())
        } else {
            Err(ScientificDiagnostic::new(
                field,
                format!("PipeWire operation failed: {}", errors.join("; ")),
            ))
        }
    }

    fn clear_errors(&self) {
        self.errors.borrow_mut().clear();
    }

    fn count_owned_nodes(&self) -> usize {
        let globals = self.globals.borrow();
        self.owned_node_names
            .iter()
            .filter(|node_name| {
                globals
                    .values()
                    .any(|global| is_node_named(global, node_name))
            })
            .count()
    }
}

fn is_node_named(global: &GlobalObject<PropertiesBox>, node_name: &str) -> bool {
    global.type_ == ObjectType::Node
        && global
            .props
            .as_ref()
            .and_then(|properties| properties.get("node.name"))
            == Some(node_name)
}

fn validate_ndarray_port(
    object: &PodObject,
    role: ObjectRole,
    port: &PortSpec,
) -> Result<(), ScientificDiagnostic> {
    validate_format_object(object, role, &port.name)?;
    let observed =
        NdArrayFormat::<Vec<u32>>::from_properties(&object.properties).map_err(|error| {
            ScientificDiagnostic::new(
                format!("{}.ports.{}.format", role.name(), port.name),
                format!("invalid ndarray EnumFormat: {error}"),
            )
        })?;
    if observed.element_type() != ElementType::F32Le {
        return Err(ScientificDiagnostic::new(
            format!("{}.ports.{}.element-type", role.name(), port.name),
            format!("expected F32_LE, observed {:?}", observed.element_type()),
        ));
    }
    if observed.shape() != port.shape {
        return Err(ScientificDiagnostic::new(
            format!("{}.ports.{}.shape", role.name(), port.name),
            format!("expected {:?}, observed {:?}", port.shape, observed.shape()),
        ));
    }
    if observed.layout() != NdArrayLayout::RowMajor {
        return Err(ScientificDiagnostic::new(
            format!("{}.ports.{}.layout", role.name(), port.name),
            format!("expected row-major, observed {:?}", observed.layout()),
        ));
    }
    let expected_rate = Fraction {
        num: 1000,
        denom: 1,
    };
    if observed.rate() != Some(expected_rate) {
        return Err(ScientificDiagnostic::new(
            format!("{}.ports.{}.rate", role.name(), port.name),
            format!(
                "expected 1000/1 complete frames per second, observed {:?}",
                observed.rate()
            ),
        ));
    }
    let schema = one_string_property(
        object,
        pw::spa::sys::SPA_FORMAT_NDARRAY_schema,
        role,
        &port.name,
        "schema",
    )?;
    if schema != port.schema {
        return Err(ScientificDiagnostic::new(
            format!("{}.ports.{}.schema", role.name(), port.name),
            format!("expected {:?}, observed {schema:?}", port.schema),
        ));
    }
    if object
        .properties
        .iter()
        .any(|property| property.key == pw::spa::sys::SPA_FORMAT_NDARRAY_profile)
    {
        return Err(ScientificDiagnostic::new(
            format!("{}.ports.{}.profile", role.name(), port.name),
            "the increment-1 format must not declare an unconfigured ndarray profile",
        ));
    }
    Ok(())
}

fn validate_discard_wildcard(
    object: &PodObject,
    role: ObjectRole,
    port_name: &str,
) -> Result<(), ScientificDiagnostic> {
    validate_format_object(object, role, port_name)?;
    if object.properties.is_empty() {
        Ok(())
    } else {
        Err(ScientificDiagnostic::new(
            format!("{}.ports.{port_name}.format", role.name()),
            "the discard sink must advertise an unconstrained format object",
        ))
    }
}

fn validate_format_object(
    object: &PodObject,
    role: ObjectRole,
    port_name: &str,
) -> Result<(), ScientificDiagnostic> {
    if object.type_ == SpaTypes::ObjectParamFormat.as_raw()
        && object.id == pw::spa::param::ParamType::EnumFormat.as_raw()
    {
        Ok(())
    } else {
        Err(ScientificDiagnostic::new(
            format!("{}.ports.{port_name}.format", role.name()),
            format!(
                "expected a SPA EnumFormat object, observed type {} id {}",
                object.type_, object.id
            ),
        ))
    }
}

fn one_string_property(
    object: &PodObject,
    key: u32,
    role: ObjectRole,
    port_name: &str,
    property_name: &str,
) -> Result<String, ScientificDiagnostic> {
    let field = format!("{}.ports.{port_name}.{property_name}", role.name());
    let mut matching = object
        .properties
        .iter()
        .filter(|property| property.key == key);
    let property = matching
        .next()
        .ok_or_else(|| ScientificDiagnostic::new(&field, "required property is missing"))?;
    if matching.next().is_some() {
        return Err(ScientificDiagnostic::new(
            field,
            "property is declared more than once",
        ));
    }
    match &property.value {
        Value::String(value) => Ok(value.clone()),
        other => Err(ScientificDiagnostic::new(
            field,
            format!("expected a fixed string, observed {other:?}"),
        )),
    }
}

impl EffectExecutor for LiveGraphAdapter {
    fn execute(&mut self, effect: &LifecycleEffect) -> Result<(), ScientificDiagnostic> {
        match effect {
            LifecycleEffect::Realize { config, .. } => {
                let resolved = match config {
                    ConfigurationInput::Resolved(config) => (**config).clone(),
                    ConfigurationInput::File(path) => DevelopmentConfig::load(path)?,
                };
                self.realize(&resolved)
            }
            LifecycleEffect::Start { .. } => self.start(),
            LifecycleEffect::Stop { .. } => self.stop(),
            LifecycleEffect::Cleanup { .. } => self.cleanup(),
        }
    }
}

impl Drop for LiveGraphAdapter {
    fn drop(&mut self) {
        let _ = self.cleanup();
    }
}

fn split_endpoint(endpoint: &str) -> Result<(&str, &str), ScientificDiagnostic> {
    endpoint.split_once(':').ok_or_else(|| {
        ScientificDiagnostic::new(
            "links",
            format!("scientific endpoint {endpoint:?} must be node:port"),
        )
    })
}

fn resolve_artifact(
    field: &str,
    configured: &str,
    environment_name: &str,
) -> Result<PathBuf, ScientificDiagnostic> {
    let expected = format!("${{{environment_name}}}");
    if configured != expected {
        return Err(ScientificDiagnostic::new(
            field,
            format!("expected maintained artifact reference {expected:?}"),
        ));
    }
    let path = std::env::var_os(environment_name).ok_or_else(|| {
        ScientificDiagnostic::new(
            field,
            format!("environment variable {environment_name} is not set"),
        )
    })?;
    let path = PathBuf::from(path);
    if !path.is_file() {
        return Err(ScientificDiagnostic::new(
            field,
            format!("build-tree plugin {} is not a regular file", path.display()),
        ));
    }
    let canonical = path.canonicalize().map_err(|error| {
        ScientificDiagnostic::new(
            field,
            format!(
                "cannot resolve build-tree plugin {}: {error}",
                path.display()
            ),
        )
    })?;
    if canonical.starts_with("/usr") {
        return Err(ScientificDiagnostic::new(
            field,
            format!(
                "system plugin path {} is forbidden; use the reviewed build-tree artifact",
                canonical.display()
            ),
        ));
    }
    Ok(canonical)
}

fn resolve_file_reference(
    field: &str,
    configured: &str,
    environment_name: &str,
) -> Result<PathBuf, ScientificDiagnostic> {
    let expected = format!("${{{environment_name}}}");
    if configured != expected {
        return Err(ScientificDiagnostic::new(
            field,
            format!("expected runtime file reference {expected:?}"),
        ));
    }
    let path = std::env::var_os(environment_name).ok_or_else(|| {
        ScientificDiagnostic::new(
            field,
            format!("environment variable {environment_name} is not set"),
        )
    })?;
    let path = PathBuf::from(path);
    if !path.is_file() {
        return Err(ScientificDiagnostic::new(
            field,
            format!("runtime input {} is not a regular file", path.display()),
        ));
    }
    path.canonicalize().map_err(|error| {
        ScientificDiagnostic::new(
            field,
            format!("cannot resolve runtime input {}: {error}", path.display()),
        )
    })
}

fn render_source_args(config: &DevelopmentConfig, plugin: &Path, remote: &str) -> String {
    let algorithm = config
        .source
        .algorithm
        .as_ref()
        .expect("source algorithm was validated");
    format!(
        "{{ remote.name = {} node.name = {} filter.graph = {{ nodes = [ {{ type = ndarray name = source plugin = {} label = {} config = {} }} ] inputs = [ ] outputs = [ \"source:excitation\" ] }} }}",
        quote_spa(remote),
        quote_spa(&config.source.node_name),
        quote_spa(&plugin.display().to_string()),
        quote_spa(&algorithm.label),
        render_map(&algorithm.config),
    )
}

fn render_graph_args(config: &DevelopmentConfig, plugin: &Path, remote: &str) -> String {
    let algorithm = config
        .graph
        .algorithm
        .as_ref()
        .expect("graph algorithm was validated");
    let properties = config
        .properties
        .iter()
        .map(|(name, value)| {
            (
                name.strip_prefix("graph.").unwrap_or(name).to_owned(),
                value.clone(),
            )
        })
        .collect::<BTreeMap<_, _>>();
    format!(
        "{{ remote.name = {} node.name = {} filter.graph = {{ nodes = [ {{ type = ndarray name = graph plugin = {} label = {} config = {} props = {} }} ] inputs = [ \"graph:input\" ] outputs = [ \"graph:output\" ] }} }}",
        quote_spa(remote),
        quote_spa(&config.graph.node_name),
        quote_spa(&plugin.display().to_string()),
        quote_spa(&algorithm.label),
        render_map(&algorithm.config),
        render_map(&properties),
    )
}

fn render_map(values: &BTreeMap<String, String>) -> String {
    let fields = values
        .iter()
        .map(|(name, value)| format!("{name} = {value}"))
        .collect::<Vec<_>>()
        .join(" ");
    format!("{{ {fields} }}")
}

fn quote_spa(value: &str) -> String {
    format!("\"{}\"", value.replace('\\', "\\\\").replace('"', "\\\""))
}
