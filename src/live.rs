use crate::{
    ConfigurationInput, DevelopmentConfig, EffectExecutor, LifecycleEffect, ObjectRole,
    PortDirection, ScientificDiagnostic,
};
use pipewire as pw;
use pw::properties::PropertiesBox;
use pw::registry::GlobalObject;
use pw::types::ObjectType;
use std::cell::{Cell, RefCell};
use std::collections::BTreeMap;
use std::ffi::CString;
use std::path::{Path, PathBuf};
use std::rc::Rc;

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct LiveGraphStatus {
    pub owned_nodes: usize,
    pub owned_links: usize,
    pub running: bool,
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
            "source.plugin.path",
            &config.source.plugin_path,
            "CALCULON_FGN_BUNDLE",
        )?;
        let sink_plugin = resolve_artifact(
            "sink.plugin.path",
            &config.sink.plugin_path,
            "PIPEWIREAO_NDARRAY_EXAMPLE",
        )?;
        let specifications = [
            (
                ObjectRole::Source,
                config.source.module.as_str(),
                render_source_args(config, &calculon, &self.remote_name),
                config.source.node_name.as_str(),
            ),
            (
                ObjectRole::Graph,
                config.graph.module.as_str(),
                render_graph_args(config, &calculon, &self.remote_name),
                config.graph.node_name.as_str(),
            ),
            (
                ObjectRole::Sink,
                config.sink.module.as_str(),
                render_sink_args(config, &sink_plugin, &self.remote_name),
                config.sink.node_name.as_str(),
            ),
        ];

        for (role, module, arguments, node_name) in specifications {
            if let Err(error) = self.load_owned_module(role, module, &arguments, node_name) {
                let _ = self.cleanup();
                return Err(error);
            }
        }
        self.owned_node_names = vec![
            config.source.node_name.clone(),
            config.graph.node_name.clone(),
            config.sink.node_name.clone(),
        ];

        if let Err(error) = self.validate_live_ports(config) {
            let _ = self.cleanup();
            return Err(error);
        }
        for (index, link) in config.links.iter().enumerate() {
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

        // Downstream-first commands prevent the finite source from outrunning its sink.
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
        for _ in 0..100 {
            self.roundtrip("start source -> graph -> sink")?;
            states = self
                .active_nodes
                .iter()
                .map(|node| node.state.borrow().clone())
                .collect::<Vec<_>>();
            if states.iter().all(|state| state == "Running") {
                self.status.running = true;
                return Ok(());
            }
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        Err(ScientificDiagnostic::new(
            "topology",
            format!("required nodes did not all enter RUNNING; observed states {states:?}"),
        ))
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
        for _ in 0..100 {
            self.roundtrip(&format!("{} node creation", role.name()))?;
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
                            == Some(node_name)
                })
                .count();
            if matches == 1 {
                return Ok(());
            }
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        Err(ScientificDiagnostic::new(
            format!("{}.node.name", role.name()),
            format!("inspectable node {node_name:?} did not appear after module creation"),
        ))
    }

    fn validate_live_ports(&self, config: &DevelopmentConfig) -> Result<(), ScientificDiagnostic> {
        let expected = [
            (&config.source.node_name, &config.source.ports),
            (&config.graph.node_name, &config.graph.ports),
            (&config.sink.node_name, &config.sink.ports),
        ];
        for (node_name, ports) in expected {
            let node = self.node_global(node_name)?;
            for port in ports {
                self.port_global(node.id, &port.name, port.direction)
                    .map_err(|error| {
                        ScientificDiagnostic::new(
                            format!("node {node_name} port {}", port.name),
                            error.message().to_owned(),
                        )
                    })?;
            }
        }
        Ok(())
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
            .filter(|global| {
                global.type_ == ObjectType::Node
                    && global
                        .props
                        .as_ref()
                        .and_then(|properties| properties.get("node.name"))
                        == Some(node_name)
            })
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
        match matches.as_slice() {
            [global] => Ok(global.to_owned()),
            _ => Err(ScientificDiagnostic::new(
                format!("port {port_name}"),
                format!(
                    "expected one {direction} port on node {node_id}, observed {}",
                    matches.len()
                ),
            )),
        }
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
                globals.values().any(|global| {
                    global.type_ == ObjectType::Node
                        && global
                            .props
                            .as_ref()
                            .and_then(|properties| properties.get("node.name"))
                            == Some(node_name.as_str())
                })
            })
            .count()
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

fn render_source_args(config: &DevelopmentConfig, plugin: &Path, remote: &str) -> String {
    format!(
        "{{ remote.name = {} node.name = {} filter.graph = {{ nodes = [ {{ type = ndarray name = source plugin = {} label = {} config = {} }} ] inputs = [ ] outputs = [ \"source:excitation\" ] }} }}",
        quote_spa(remote),
        quote_spa(&config.source.node_name),
        quote_spa(&plugin.display().to_string()),
        quote_spa(&config.source.algorithm_label),
        render_map(&config.source.algorithm_config),
    )
}

fn render_graph_args(config: &DevelopmentConfig, plugin: &Path, remote: &str) -> String {
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
        quote_spa(&config.graph.algorithm_label),
        render_map(&config.graph.algorithm_config),
        render_map(&properties),
    )
}

fn render_sink_args(config: &DevelopmentConfig, plugin: &Path, remote: &str) -> String {
    format!(
        "{{ remote.name = {} node.name = {} filter.graph = {{ nodes = [ {{ type = ndarray name = sink plugin = {} label = {} config = {} }} ] inputs = [ \"sink:in\" ] outputs = [ ] }} }}",
        quote_spa(remote),
        quote_spa(&config.sink.node_name),
        quote_spa(&plugin.display().to_string()),
        quote_spa(&config.sink.algorithm_label),
        render_map(&config.sink.algorithm_config),
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
