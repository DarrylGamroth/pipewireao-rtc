use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::fmt;
use std::path::Path;

mod decode;

const SIMULATED_SOURCE_FACTORY: &str = "pipewireao.simulated-complete-frame";
const FITS_SOURCE_FACTORY: &str = "api.fits.source";
const SINK_FACTORY: &str = "api.pipewireao.discard";
const GRAPH_FACTORY: &str = "pipewireao.fgn-native";
const FILTER_CHAIN_MODULE: &str = "libpipewire-module-ndarray-filter-chain";
const SPA_NODE_FACTORY_MODULE: &str = "libpipewire-module-spa-node-factory";

/// A diagnostic expressed in the configured scientific vocabulary.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ScientificDiagnostic {
    field: String,
    message: String,
}

impl ScientificDiagnostic {
    #[must_use]
    pub fn new(field: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            field: field.into(),
            message: message.into(),
        }
    }

    #[must_use]
    pub fn field(&self) -> &str {
        &self.field
    }

    #[must_use]
    pub fn message(&self) -> &str {
        &self.message
    }
}

impl fmt::Display for ScientificDiagnostic {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}: {}", self.field, self.message)
    }
}

impl std::error::Error for ScientificDiagnostic {}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ObjectRole {
    Source,
    Graph,
    Sink,
}

impl ObjectRole {
    #[must_use]
    pub const fn name(self) -> &'static str {
        match self {
            Self::Source => "source",
            Self::Graph => "graph",
            Self::Sink => "sink",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EndpointFactory {
    SimulatedCompleteFrameSource,
    FitsCompleteFrameSource,
    FormatAgnosticDiscardSink,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ObjectRealization<F> {
    Factory(F),
    External,
}

impl<F> ObjectRealization<F> {
    #[must_use]
    pub const fn is_external(&self) -> bool {
        matches!(self, Self::External)
    }
}

impl EndpointFactory {
    #[must_use]
    pub const fn configured_name(self) -> &'static str {
        match self {
            Self::SimulatedCompleteFrameSource => SIMULATED_SOURCE_FACTORY,
            Self::FitsCompleteFrameSource => FITS_SOURCE_FACTORY,
            Self::FormatAgnosticDiscardSink => SINK_FACTORY,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum GraphFactory {
    FgnNative,
}

impl GraphFactory {
    #[must_use]
    pub const fn configured_name(self) -> &'static str {
        GRAPH_FACTORY
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PortDirection {
    Input,
    Output,
}

impl PortDirection {
    fn parse(field: &str, value: &str) -> Result<Self, ScientificDiagnostic> {
        match value {
            "input" => Ok(Self::Input),
            "output" => Ok(Self::Output),
            _ => Err(ScientificDiagnostic::new(
                field,
                format!("direction must be input or output, got {value:?}"),
            )),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PortSpec {
    pub name: String,
    pub direction: PortDirection,
    pub element_type: String,
    pub shape: Vec<u32>,
    pub schema: String,
}

/// One admitted `PipeWire` object at an RTC session boundary.
///
/// `configuration_path` identifies an already-authored standard `PipeWire`
/// module-argument file. The RTC never parses or regenerates its `filter.graph`.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ObjectSpec<F> {
    pub realization: ObjectRealization<F>,
    pub module: Option<String>,
    pub node_name: String,
    pub plugin_path: Option<String>,
    pub configuration_path: Option<String>,
    pub arguments: BTreeMap<String, String>,
    pub ports: Vec<PortSpec>,
}

#[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd)]
pub struct LinkSpec {
    pub output: String,
    pub input: String,
    pub passive: bool,
}

/// Named session nodes that start and stop as one processing unit.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ExecutionGroupSpec {
    pub name: String,
    pub nodes: Vec<String>,
}

/// Resolved, development-only session loaded from relaxed SPA-JSON.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DevelopmentConfig {
    pub sources: Vec<ObjectSpec<EndpointFactory>>,
    pub graphs: Vec<ObjectSpec<GraphFactory>>,
    pub sinks: Vec<ObjectSpec<EndpointFactory>>,
    pub execution_groups: Vec<ExecutionGroupSpec>,
    pub properties: BTreeMap<String, String>,
    pub parameters: BTreeMap<String, String>,
    pub observations: Vec<String>,
    pub links: Vec<LinkSpec>,
}

impl DevelopmentConfig {
    /// Loads and validates a relaxed SPA-JSON development configuration.
    ///
    /// # Errors
    ///
    /// Returns a scientific diagnostic when the file cannot be read, parsed,
    /// or admitted to the development-only profile.
    pub fn load(path: &Path) -> Result<Self, ScientificDiagnostic> {
        let text = std::fs::read_to_string(path).map_err(|error| {
            ScientificDiagnostic::new(
                "configuration",
                format!("cannot read {}: {error}", path.display()),
            )
        })?;
        Self::parse(&text)
    }

    /// Parses and validates a relaxed SPA-JSON development configuration.
    ///
    /// # Errors
    ///
    /// Returns a scientific diagnostic for invalid syntax, missing fields, or
    /// a value outside the maintained development contract.
    pub fn parse(text: &str) -> Result<Self, ScientificDiagnostic> {
        let config = decode::development_config(text)?;
        config.validate()?;
        Ok(config)
    }

    /// Validates the complete-frame, non-actuating session contract.
    ///
    /// # Errors
    ///
    /// Returns the first field-specific scientific diagnostic.
    pub fn validate(&self) -> Result<(), ScientificDiagnostic> {
        if self.sources.is_empty() {
            return Err(ScientificDiagnostic::new(
                "sources",
                "at least one complete-frame source is required",
            ));
        }
        if self.graphs.is_empty() {
            return Err(ScientificDiagnostic::new(
                "graphs",
                "at least one fgn-native graph is required",
            ));
        }
        if self.sinks.is_empty() {
            return Err(ScientificDiagnostic::new(
                "sinks",
                "at least one non-actuating sink is required",
            ));
        }

        let mut node_names = BTreeSet::new();
        for (index, source) in self.sources.iter().enumerate() {
            let field = format!("sources[{index}]");
            validate_source(source, &field)?;
            validate_node_name(&source.node_name, &field, &mut node_names)?;
        }
        for (index, graph) in self.graphs.iter().enumerate() {
            let field = format!("graphs[{index}]");
            validate_graph(graph, &field)?;
            validate_node_name(&graph.node_name, &field, &mut node_names)?;
        }
        for (index, sink) in self.sinks.iter().enumerate() {
            let field = format!("sinks[{index}]");
            validate_sink(sink, &field)?;
            validate_node_name(&sink.node_name, &field, &mut node_names)?;
        }

        if !self.properties.is_empty() {
            return Err(ScientificDiagnostic::new(
                "properties",
                "graph properties belong in the delegated filter.graph configuration",
            ));
        }
        if !self.parameters.is_empty() {
            return Err(ScientificDiagnostic::new(
                "parameters",
                "this complete-frame fixture declares no runtime ndarray parameters",
            ));
        }
        if !self.observations.is_empty() {
            return Err(ScientificDiagnostic::new(
                "observations",
                "no bounded non-gating observation port exists for this fixture",
            ));
        }
        validate_execution_groups(self)?;
        validate_links(self)
    }

    #[must_use]
    pub fn object_count(&self) -> usize {
        self.sources.len() + self.graphs.len() + self.sinks.len()
    }

    #[must_use]
    pub fn owned_object_count(&self) -> usize {
        self.graphs.len()
            + self
                .sources
                .iter()
                .filter(|object| !object.realization.is_external())
                .count()
            + self
                .sinks
                .iter()
                .filter(|object| !object.realization.is_external())
                .count()
    }

    #[must_use]
    pub fn owned_node_names(&self) -> Vec<&str> {
        self.sources
            .iter()
            .filter(|object| !object.realization.is_external())
            .map(|object| object.node_name.as_str())
            .chain(self.graphs.iter().map(|object| object.node_name.as_str()))
            .chain(
                self.sinks
                    .iter()
                    .filter(|object| !object.realization.is_external())
                    .map(|object| object.node_name.as_str()),
            )
            .collect()
    }

    #[must_use]
    pub fn externally_owned_node_names(&self) -> Vec<&str> {
        self.sources
            .iter()
            .filter(|object| object.realization.is_external())
            .map(|object| object.node_name.as_str())
            .chain(
                self.sinks
                    .iter()
                    .filter(|object| object.realization.is_external())
                    .map(|object| object.node_name.as_str()),
            )
            .collect()
    }

    #[must_use]
    pub fn owned_topological_node_names(&self) -> Vec<String> {
        let owned = self.owned_node_names().into_iter().collect::<BTreeSet<_>>();
        self.topological_node_names()
            .into_iter()
            .filter(|name| owned.contains(name.as_str()))
            .collect()
    }

    #[must_use]
    pub fn node_names(&self) -> Vec<&str> {
        self.sources
            .iter()
            .map(|object| object.node_name.as_str())
            .chain(self.graphs.iter().map(|object| object.node_name.as_str()))
            .chain(self.sinks.iter().map(|object| object.node_name.as_str()))
            .collect()
    }

    #[must_use]
    pub fn execution_group(&self, name: &str) -> Option<&ExecutionGroupSpec> {
        self.execution_groups
            .iter()
            .find(|group| group.name == name)
    }

    #[must_use]
    pub fn execution_group_names(&self) -> Vec<String> {
        self.execution_groups
            .iter()
            .map(|group| group.name.clone())
            .collect()
    }

    #[must_use]
    pub fn execution_group_for_node(&self, node_name: &str) -> Option<&str> {
        self.execution_groups.iter().find_map(|group| {
            group
                .nodes
                .iter()
                .any(|member| member == node_name)
                .then_some(group.name.as_str())
        })
    }

    #[must_use]
    pub fn execution_group_node_names(&self, name: &str) -> Option<Vec<String>> {
        let group = self.execution_group(name)?;
        Some(
            self.topological_node_names()
                .into_iter()
                .filter(|node| group.nodes.contains(node))
                .collect(),
        )
    }

    #[must_use]
    pub fn execution_group_sink_names(&self, name: &str) -> Option<Vec<String>> {
        let group = self.execution_group(name)?;
        Some(
            self.sinks
                .iter()
                .filter(|sink| !sink.realization.is_external())
                .filter(|sink| group.nodes.contains(&sink.node_name))
                .map(|sink| sink.node_name.clone())
                .collect(),
        )
    }

    /// Returns nodes in upstream-to-downstream order. Validation guarantees an
    /// acyclic topology, so callers may reverse this for downstream-first start.
    ///
    /// # Panics
    ///
    /// Panics when called before the configuration has passed [`Self::validate`].
    #[must_use]
    pub fn topological_node_names(&self) -> Vec<String> {
        let names = self.node_names();
        let mut incoming = names
            .iter()
            .map(|name| ((*name).to_owned(), 0_usize))
            .collect::<BTreeMap<_, _>>();
        let mut outgoing = BTreeMap::<String, BTreeSet<String>>::new();
        for link in &self.links {
            let (output_node, _) = split_endpoint(&link.output).expect("validated output endpoint");
            let (input_node, _) = split_endpoint(&link.input).expect("validated input endpoint");
            if outgoing
                .entry(output_node.to_owned())
                .or_default()
                .insert(input_node.to_owned())
            {
                *incoming.get_mut(input_node).expect("validated input node") += 1;
            }
        }
        let mut ready = incoming
            .iter()
            .filter_map(|(name, count)| (*count == 0).then_some(name.clone()))
            .collect::<VecDeque<_>>();
        let mut order = Vec::with_capacity(names.len());
        while let Some(node) = ready.pop_front() {
            order.push(node.clone());
            if let Some(destinations) = outgoing.get(&node) {
                for destination in destinations {
                    let count = incoming
                        .get_mut(destination)
                        .expect("validated destination");
                    *count -= 1;
                    if *count == 0 {
                        ready.push_back(destination.clone());
                    }
                }
            }
        }
        order
    }

    /// # Panics
    ///
    /// Panics when called before the configuration has passed [`Self::validate`].
    #[must_use]
    pub fn links_downstream_first(&self) -> Vec<(usize, &LinkSpec)> {
        let order = self
            .topological_node_names()
            .into_iter()
            .enumerate()
            .map(|(index, name)| (name, index))
            .collect::<BTreeMap<_, _>>();
        let mut links = self.links.iter().enumerate().collect::<Vec<_>>();
        links.sort_by_key(|(_, link)| {
            let (node, _) = split_endpoint(&link.output).expect("validated output endpoint");
            std::cmp::Reverse(order[node])
        });
        links
    }
}

fn validate_execution_groups(config: &DevelopmentConfig) -> Result<(), ScientificDiagnostic> {
    if config.execution_groups.is_empty() {
        return Err(ScientificDiagnostic::new(
            "execution-groups",
            "at least one execution group is required",
        ));
    }

    let node_names = config.node_names().into_iter().collect::<BTreeSet<_>>();
    let graph_names = config
        .graphs
        .iter()
        .map(|graph| graph.node_name.as_str())
        .collect::<BTreeSet<_>>();
    let external_names = config
        .externally_owned_node_names()
        .into_iter()
        .collect::<BTreeSet<_>>();
    let mut names = BTreeSet::new();
    let mut membership = BTreeMap::<&str, &str>::new();

    for (group_index, group) in config.execution_groups.iter().enumerate() {
        let field = format!("execution-groups[{group_index}]");
        if group.name.is_empty() || group.name.contains('\0') {
            return Err(ScientificDiagnostic::new(
                format!("{field}.name"),
                "execution-group name must be non-empty and contain no NUL",
            ));
        }
        if !names.insert(group.name.as_str()) {
            return Err(ScientificDiagnostic::new(
                format!("{field}.name"),
                format!("execution-group name {:?} is duplicated", group.name),
            ));
        }
        if group.nodes.is_empty() {
            return Err(ScientificDiagnostic::new(
                format!("{field}.nodes"),
                "execution group must contain at least one session node",
            ));
        }

        let mut contains_graph = false;
        for (member_index, member) in group.nodes.iter().enumerate() {
            let member_field = format!("{field}.nodes[{member_index}]");
            if !node_names.contains(member.as_str()) {
                return Err(ScientificDiagnostic::new(
                    member_field,
                    format!("session node {member:?} is not declared"),
                ));
            }
            if external_names.contains(member.as_str()) {
                return Err(ScientificDiagnostic::new(
                    member_field,
                    "external HIL endpoint lifecycle remains application-owned",
                ));
            }
            if let Some(previous) = membership.insert(member, &group.name) {
                return Err(ScientificDiagnostic::new(
                    member_field,
                    format!(
                        "session node {member:?} already belongs to execution group {previous:?}"
                    ),
                ));
            }
            contains_graph |= graph_names.contains(member.as_str());
        }
        if !contains_graph {
            return Err(ScientificDiagnostic::new(
                format!("{field}.nodes"),
                "execution group must contain at least one fgn-native graph",
            ));
        }
    }

    for graph in &config.graphs {
        if !membership.contains_key(graph.node_name.as_str()) {
            return Err(ScientificDiagnostic::new(
                format!("graph {}.execution-group", graph.node_name),
                "every fgn-native graph must belong to exactly one execution group",
            ));
        }
    }
    for sink in &config.sinks {
        if sink.realization.is_external() {
            continue;
        }
        if !membership.contains_key(sink.node_name.as_str()) {
            return Err(ScientificDiagnostic::new(
                format!("sink {}.execution-group", sink.node_name),
                "every non-actuating sink must belong to exactly one execution group",
            ));
        }
    }
    Ok(())
}

fn validate_source(
    source: &ObjectSpec<EndpointFactory>,
    field: &str,
) -> Result<(), ScientificDiagnostic> {
    validate_ports(field, &source.ports, &[PortDirection::Output])?;
    match source.realization {
        ObjectRealization::Factory(EndpointFactory::FitsCompleteFrameSource) => {
            validate_exact_shape(&source.ports[0], field, &[2])?;
            validate_required_module(field, source.module.as_deref(), SPA_NODE_FACTORY_MODULE)?;
            validate_exact_reference(
                &format!("{field}.plugin.path"),
                source.plugin_path.as_deref(),
                "${PIPEWIREAO_FITS_PLUGIN}",
            )?;
            reject_configuration_path(field, source.configuration_path.as_deref())?;
            validate_fits_arguments(source, field)
        }
        ObjectRealization::Factory(EndpointFactory::SimulatedCompleteFrameSource) => {
            validate_exact_shape(&source.ports[0], field, &[2])?;
            validate_required_module(field, source.module.as_deref(), FILTER_CHAIN_MODULE)?;
            reject_plugin_path(field, source.plugin_path.as_deref())?;
            validate_configuration_reference(
                &format!("{field}.config.path"),
                source.configuration_path.as_deref(),
                "PIPEWIREAO_RTC_SOURCE_GRAPH_",
            )?;
            if source.arguments.is_empty() {
                Ok(())
            } else {
                Err(ScientificDiagnostic::new(
                    format!("{field}.args"),
                    "the delegated simulated source takes no RTC-rendered arguments",
                ))
            }
        }
        ObjectRealization::Factory(EndpointFactory::FormatAgnosticDiscardSink) => {
            unreachable!("source allowlist")
        }
        ObjectRealization::External => validate_external_endpoint(source, field),
    }
}

fn validate_graph(
    graph: &ObjectSpec<GraphFactory>,
    field: &str,
) -> Result<(), ScientificDiagnostic> {
    if graph.realization != ObjectRealization::Factory(GraphFactory::FgnNative) {
        return Err(ScientificDiagnostic::new(
            format!("{field}.factory"),
            "graph must use the fgn-native factory",
        ));
    }
    validate_required_module(field, graph.module.as_deref(), FILTER_CHAIN_MODULE)?;
    validate_ports(
        field,
        &graph.ports,
        &[PortDirection::Input, PortDirection::Output],
    )?;
    reject_plugin_path(field, graph.plugin_path.as_deref())?;
    validate_configuration_reference(
        &format!("{field}.config.path"),
        graph.configuration_path.as_deref(),
        "PIPEWIREAO_RTC_GRAPH_",
    )?;
    if graph.arguments.is_empty() {
        Ok(())
    } else {
        Err(ScientificDiagnostic::new(
            format!("{field}.args"),
            "the graph uses its delegated filter.graph configuration, not RTC-rendered arguments",
        ))
    }
}

fn validate_sink(
    sink: &ObjectSpec<EndpointFactory>,
    field: &str,
) -> Result<(), ScientificDiagnostic> {
    validate_ports(field, &sink.ports, &[PortDirection::Input])?;
    match sink.realization {
        ObjectRealization::Factory(EndpointFactory::FormatAgnosticDiscardSink) => {
            validate_exact_shape(&sink.ports[0], field, &[2])?;
            validate_required_module(field, sink.module.as_deref(), SPA_NODE_FACTORY_MODULE)?;
            validate_exact_reference(
                &format!("{field}.plugin.path"),
                sink.plugin_path.as_deref(),
                "${PIPEWIREAO_DISCARD_PLUGIN}",
            )?;
            reject_configuration_path(field, sink.configuration_path.as_deref())?;
            if sink.arguments.is_empty() {
                Ok(())
            } else {
                Err(ScientificDiagnostic::new(
                    format!("{field}.args"),
                    "the format-agnostic discard sink takes no fixture arguments",
                ))
            }
        }
        ObjectRealization::External => validate_external_endpoint(sink, field),
        ObjectRealization::Factory(_) => unreachable!("sink allowlist"),
    }
}

fn validate_external_endpoint<F>(
    endpoint: &ObjectSpec<F>,
    field: &str,
) -> Result<(), ScientificDiagnostic> {
    if endpoint.module.is_some() {
        return Err(ScientificDiagnostic::new(
            format!("{field}.module"),
            "external HIL endpoint must not declare a runner-loaded module",
        ));
    }
    reject_plugin_path(field, endpoint.plugin_path.as_deref())?;
    reject_configuration_path(field, endpoint.configuration_path.as_deref())?;
    if endpoint.arguments.is_empty() {
        Ok(())
    } else {
        Err(ScientificDiagnostic::new(
            format!("{field}.args"),
            "external HIL endpoint takes no runner-rendered arguments",
        ))
    }
}

fn validate_exact_shape(
    port: &PortSpec,
    field: &str,
    expected_shape: &[u32],
) -> Result<(), ScientificDiagnostic> {
    if port.shape == expected_shape {
        Ok(())
    } else {
        Err(ScientificDiagnostic::new(
            format!("{field}.ports.{}.shape", port.name),
            format!("expected {expected_shape:?}, got {:?}", port.shape),
        ))
    }
}

fn validate_node_name(
    name: &str,
    field: &str,
    names: &mut BTreeSet<String>,
) -> Result<(), ScientificDiagnostic> {
    if name.is_empty() || name.contains(':') || name.contains('\0') {
        return Err(ScientificDiagnostic::new(
            format!("{field}.node.name"),
            "node name must be non-empty and contain neither ':' nor NUL",
        ));
    }
    if !names.insert(name.to_owned()) {
        return Err(ScientificDiagnostic::new(
            format!("{field}.node.name"),
            format!("node name {name:?} is duplicated in the session"),
        ));
    }
    Ok(())
}

fn validate_required_module(
    field: &str,
    actual: Option<&str>,
    expected: &str,
) -> Result<(), ScientificDiagnostic> {
    if actual == Some(expected) {
        Ok(())
    } else {
        Err(ScientificDiagnostic::new(
            format!("{field}.module"),
            format!("expected public PipeWireAO module {expected:?}, got {actual:?}"),
        ))
    }
}

fn validate_ports(
    field: &str,
    ports: &[PortSpec],
    directions: &[PortDirection],
) -> Result<(), ScientificDiagnostic> {
    if ports.len() != directions.len() {
        return Err(ScientificDiagnostic::new(
            format!("{field}.ports"),
            format!(
                "expected {} declared scientific port(s), got {}",
                directions.len(),
                ports.len()
            ),
        ));
    }
    let mut names = BTreeSet::new();
    for (port, direction) in ports.iter().zip(directions) {
        let port_field = format!("{field}.ports.{}", port.name);
        if port.name.is_empty() || !names.insert(port.name.as_str()) {
            return Err(ScientificDiagnostic::new(
                format!("{port_field}.name"),
                "port name must be non-empty and unique on its node",
            ));
        }
        if port.direction != *direction {
            return Err(ScientificDiagnostic::new(
                format!("{port_field}.direction"),
                format!("expected {direction:?}, got {:?}", port.direction),
            ));
        }
        if port.element_type != "F32_LE" {
            return Err(ScientificDiagnostic::new(
                format!("{port_field}.element-type"),
                format!("expected F32_LE, got {:?}", port.element_type),
            ));
        }
        if port.shape.is_empty() || port.shape.contains(&0) {
            return Err(ScientificDiagnostic::new(
                format!("{port_field}.shape"),
                "complete ndarray shape must have positive dimensions",
            ));
        }
        if port.schema.is_empty() {
            return Err(ScientificDiagnostic::new(
                format!("{port_field}.schema"),
                "scientific schema must not be empty",
            ));
        }
    }
    Ok(())
}

fn validate_fits_arguments(
    source: &ObjectSpec<EndpointFactory>,
    field: &str,
) -> Result<(), ScientificDiagnostic> {
    let source_port = &source.ports[0];
    let expected = [
        ("api.fits.hdu", "1"),
        ("api.fits.io-mode", "file"),
        ("api.fits.loop", "true"),
        ("api.fits.output-mode", "frame"),
        ("api.fits.prefault", "false"),
        ("api.fits.rate", "1000/1"),
        ("api.fits.readiness", "timerfd"),
        ("api.fits.sample-rank", "1"),
        ("api.fits.schema", source_port.schema.as_str()),
    ];
    let expected_names = expected
        .iter()
        .map(|(name, _)| *name)
        .chain(std::iter::once("api.fits.path"))
        .collect::<BTreeSet<_>>();
    if let Some(name) = source
        .arguments
        .keys()
        .find(|name| !expected_names.contains(name.as_str()))
    {
        return Err(ScientificDiagnostic::new(
            format!("{field}.args.{name}"),
            "factory argument is not admitted for this fixture",
        ));
    }
    for (name, expected_value) in expected {
        match source.arguments.get(name) {
            Some(value) if value == expected_value => {}
            Some(value) => {
                return Err(ScientificDiagnostic::new(
                    format!("{field}.args.{name}"),
                    format!("expected {expected_value:?}, got {value:?}"),
                ));
            }
            None => {
                return Err(ScientificDiagnostic::new(
                    format!("{field}.args.{name}"),
                    "required factory argument is missing",
                ));
            }
        }
    }
    validate_configuration_reference(
        &format!("{field}.args.api.fits.path"),
        source.arguments.get("api.fits.path").map(String::as_str),
        "PIPEWIREAO_RTC_FITS_PATH",
    )
}

fn validate_exact_reference(
    field: &str,
    actual: Option<&str>,
    expected: &str,
) -> Result<(), ScientificDiagnostic> {
    match actual {
        Some(actual) if actual == expected => Ok(()),
        Some(actual) => Err(ScientificDiagnostic::new(
            field,
            format!(
                "expected maintained build-tree artifact reference {expected:?}, got {actual:?}"
            ),
        )),
        None => Err(ScientificDiagnostic::new(
            field,
            "required field is missing",
        )),
    }
}

fn validate_configuration_reference(
    field: &str,
    actual: Option<&str>,
    prefix: &str,
) -> Result<(), ScientificDiagnostic> {
    let Some(actual) = actual else {
        return Err(ScientificDiagnostic::new(
            field,
            "required field is missing",
        ));
    };
    let Some(variable) = actual
        .strip_prefix("${")
        .and_then(|value| value.strip_suffix('}'))
    else {
        return Err(ScientificDiagnostic::new(
            field,
            "path must be an explicit development environment reference",
        ));
    };
    if !variable.starts_with(prefix)
        || !variable
            .bytes()
            .all(|byte| byte.is_ascii_uppercase() || byte.is_ascii_digit() || byte == b'_')
    {
        return Err(ScientificDiagnostic::new(
            field,
            format!("environment variable must start with {prefix:?} and use uppercase ASCII"),
        ));
    }
    Ok(())
}

fn reject_plugin_path(field: &str, value: Option<&str>) -> Result<(), ScientificDiagnostic> {
    if value.is_none() {
        Ok(())
    } else {
        Err(ScientificDiagnostic::new(
            format!("{field}.plugin.path"),
            "delegated filter.graph configuration owns its plugin paths",
        ))
    }
}

fn reject_configuration_path(field: &str, value: Option<&str>) -> Result<(), ScientificDiagnostic> {
    if value.is_none() {
        Ok(())
    } else {
        Err(ScientificDiagnostic::new(
            format!("{field}.config.path"),
            "this SPA factory does not load a filter.graph configuration",
        ))
    }
}

#[derive(Clone, Copy)]
struct PortReference<'a> {
    role: ObjectRole,
    port: &'a PortSpec,
}

#[allow(clippy::too_many_lines)]
fn validate_links(config: &DevelopmentConfig) -> Result<(), ScientificDiagnostic> {
    if config.links.is_empty() {
        return Err(ScientificDiagnostic::new(
            "links",
            "at least one declared PipeWire link is required",
        ));
    }
    let mut links = BTreeSet::new();
    let mut incoming = BTreeMap::<String, usize>::new();
    let mut outgoing = BTreeMap::<String, usize>::new();
    let mut node_edges = BTreeSet::<(String, String)>::new();
    for (index, link) in config.links.iter().enumerate() {
        let field = format!("links[{index}]");
        if !links.insert(link.clone()) {
            return Err(ScientificDiagnostic::new(
                field,
                "declared link is duplicated",
            ));
        }
        let (output_node, output_port) = split_endpoint(&link.output)
            .map_err(|message| ScientificDiagnostic::new(format!("{field}.output"), message))?;
        let (input_node, input_port) = split_endpoint(&link.input)
            .map_err(|message| ScientificDiagnostic::new(format!("{field}.input"), message))?;
        let output = find_port(config, output_node, output_port).ok_or_else(|| {
            ScientificDiagnostic::new(
                format!("{field}.output"),
                format!("scientific output port {:?} is not declared", link.output),
            )
        })?;
        let input = find_port(config, input_node, input_port).ok_or_else(|| {
            ScientificDiagnostic::new(
                format!("{field}.input"),
                format!("scientific input port {:?} is not declared", link.input),
            )
        })?;
        if output.port.direction != PortDirection::Output {
            return Err(ScientificDiagnostic::new(
                format!("{field}.output"),
                "link output endpoint is not an output port",
            ));
        }
        if input.port.direction != PortDirection::Input {
            return Err(ScientificDiagnostic::new(
                format!("{field}.input"),
                "link input endpoint is not an input port",
            ));
        }
        let admitted_roles = matches!(output.role, ObjectRole::Source | ObjectRole::Graph)
            && matches!(input.role, ObjectRole::Graph | ObjectRole::Sink)
            && !(output.role == ObjectRole::Source && input.role == ObjectRole::Sink);
        if !admitted_roles {
            return Err(ScientificDiagnostic::new(
                field,
                "links must be source -> graph, graph -> graph, or graph -> sink",
            ));
        }
        let output_group = config.execution_group_for_node(output_node);
        let input_group = config.execution_group_for_node(input_node);
        if let (Some(output_group), Some(input_group)) = (output_group, input_group) {
            if output_group != input_group {
                return Err(ScientificDiagnostic::new(
                    format!("{field}.execution-group"),
                    format!(
                        "direct link from execution group {output_group:?} to {input_group:?} is not selectively controllable"
                    ),
                ));
            }
        }
        let enters_group_from_session_node = output_group.is_none() && input_group.is_some();
        if link.passive != enters_group_from_session_node {
            let expected = enters_group_from_session_node;
            return Err(ScientificDiagnostic::new(
                format!("{field}.passive"),
                format!("link.passive must be {expected} for this execution-group boundary"),
            ));
        }
        if output.port.element_type != input.port.element_type {
            return Err(ScientificDiagnostic::new(
                format!("{field}.element-type"),
                format!(
                    "output {} and input {} have incompatible element types {:?} and {:?}",
                    link.output, link.input, output.port.element_type, input.port.element_type
                ),
            ));
        }
        if output.port.shape != input.port.shape {
            return Err(ScientificDiagnostic::new(
                format!("{field}.shape"),
                format!(
                    "output {} and input {} have incompatible shapes {:?} and {:?}",
                    link.output, link.input, output.port.shape, input.port.shape
                ),
            ));
        }
        if output.port.schema != input.port.schema {
            return Err(ScientificDiagnostic::new(
                format!("{field}.schema"),
                format!(
                    "output {} and input {} have incompatible schemas {:?} and {:?}",
                    link.output, link.input, output.port.schema, input.port.schema
                ),
            ));
        }
        *outgoing.entry(link.output.clone()).or_default() += 1;
        *incoming.entry(link.input.clone()).or_default() += 1;
        node_edges.insert((output_node.to_owned(), input_node.to_owned()));
    }

    for graph in &config.graphs {
        for port in graph
            .ports
            .iter()
            .filter(|port| port.direction == PortDirection::Input)
        {
            require_one_producer(&incoming, &graph.node_name, port)?;
        }
    }
    for sink in &config.sinks {
        for port in &sink.ports {
            require_one_producer(&incoming, &sink.node_name, port)?;
        }
    }
    for source in &config.sources {
        require_consumer(&outgoing, &source.node_name, &source.ports[0])?;
    }
    for graph in &config.graphs {
        for port in graph
            .ports
            .iter()
            .filter(|port| port.direction == PortDirection::Output)
        {
            require_consumer(&outgoing, &graph.node_name, port)?;
        }
    }

    validate_acyclic(config, &node_edges)?;
    validate_reachability(config, &node_edges)
}

fn split_endpoint(endpoint: &str) -> Result<(&str, &str), &'static str> {
    let Some((node, port)) = endpoint.split_once(':') else {
        return Err("endpoint must use node.name:port.name syntax");
    };
    if node.is_empty() || port.is_empty() {
        return Err("endpoint node and port names must not be empty");
    }
    Ok((node, port))
}

fn find_port<'a>(
    config: &'a DevelopmentConfig,
    node_name: &str,
    port_name: &str,
) -> Option<PortReference<'a>> {
    config
        .sources
        .iter()
        .find(|object| object.node_name == node_name)
        .and_then(|object| object.ports.iter().find(|port| port.name == port_name))
        .map(|port| PortReference {
            role: ObjectRole::Source,
            port,
        })
        .or_else(|| {
            config
                .graphs
                .iter()
                .find(|object| object.node_name == node_name)
                .and_then(|object| object.ports.iter().find(|port| port.name == port_name))
                .map(|port| PortReference {
                    role: ObjectRole::Graph,
                    port,
                })
        })
        .or_else(|| {
            config
                .sinks
                .iter()
                .find(|object| object.node_name == node_name)
                .and_then(|object| object.ports.iter().find(|port| port.name == port_name))
                .map(|port| PortReference {
                    role: ObjectRole::Sink,
                    port,
                })
        })
}

fn require_one_producer(
    incoming: &BTreeMap<String, usize>,
    node_name: &str,
    port: &PortSpec,
) -> Result<(), ScientificDiagnostic> {
    let endpoint = format!("{node_name}:{}", port.name);
    match incoming.get(&endpoint).copied().unwrap_or_default() {
        1 => Ok(()),
        count => Err(ScientificDiagnostic::new(
            format!("port {endpoint}"),
            format!("input requires exactly one producer, got {count}"),
        )),
    }
}

fn require_consumer(
    outgoing: &BTreeMap<String, usize>,
    node_name: &str,
    port: &PortSpec,
) -> Result<(), ScientificDiagnostic> {
    let endpoint = format!("{node_name}:{}", port.name);
    if outgoing.get(&endpoint).copied().unwrap_or_default() > 0 {
        Ok(())
    } else {
        Err(ScientificDiagnostic::new(
            format!("port {endpoint}"),
            "output requires at least one declared consumer",
        ))
    }
}

fn validate_acyclic(
    config: &DevelopmentConfig,
    edges: &BTreeSet<(String, String)>,
) -> Result<(), ScientificDiagnostic> {
    let mut incoming = config
        .node_names()
        .into_iter()
        .map(|name| (name.to_owned(), 0_usize))
        .collect::<BTreeMap<_, _>>();
    let mut outgoing = BTreeMap::<String, Vec<String>>::new();
    for (source, destination) in edges {
        *incoming.get_mut(destination).expect("validated node") += 1;
        outgoing
            .entry(source.clone())
            .or_default()
            .push(destination.clone());
    }
    let mut ready = incoming
        .iter()
        .filter_map(|(name, count)| (*count == 0).then_some(name.clone()))
        .collect::<VecDeque<_>>();
    let mut visited = 0;
    while let Some(node) = ready.pop_front() {
        visited += 1;
        for destination in outgoing.get(&node).into_iter().flatten() {
            let count = incoming.get_mut(destination).expect("validated node");
            *count -= 1;
            if *count == 0 {
                ready.push_back(destination.clone());
            }
        }
    }
    if visited == incoming.len() {
        Ok(())
    } else {
        Err(ScientificDiagnostic::new(
            "links",
            "declared session topology contains a cycle",
        ))
    }
}

fn validate_reachability(
    config: &DevelopmentConfig,
    edges: &BTreeSet<(String, String)>,
) -> Result<(), ScientificDiagnostic> {
    let source_names = config
        .sources
        .iter()
        .map(|source| source.node_name.as_str())
        .collect::<BTreeSet<_>>();
    let sink_names = config
        .sinks
        .iter()
        .map(|sink| sink.node_name.as_str())
        .collect::<BTreeSet<_>>();
    let forward = closure(source_names, edges, false);
    let backward = closure(sink_names, edges, true);
    for graph in &config.graphs {
        if !forward.contains(graph.node_name.as_str()) {
            return Err(ScientificDiagnostic::new(
                format!("graph {}", graph.node_name),
                "graph is not reachable from a declared source",
            ));
        }
        if !backward.contains(graph.node_name.as_str()) {
            return Err(ScientificDiagnostic::new(
                format!("graph {}", graph.node_name),
                "graph does not reach a declared non-actuating sink",
            ));
        }
    }
    Ok(())
}

fn closure<'a>(
    initial: BTreeSet<&'a str>,
    edges: &'a BTreeSet<(String, String)>,
    reverse: bool,
) -> BTreeSet<&'a str> {
    let mut visited = initial;
    loop {
        let before = visited.len();
        for (source, destination) in edges {
            let (from, to) = if reverse {
                (destination.as_str(), source.as_str())
            } else {
                (source.as_str(), destination.as_str())
            };
            if visited.contains(from) {
                visited.insert(to);
            }
        }
        if visited.len() == before {
            return visited;
        }
    }
}
