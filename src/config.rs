use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::path::Path;

mod decode;

const SIMULATED_SOURCE_FACTORY: &str = "pipewireao.simulated-complete-frame";
const FITS_SOURCE_FACTORY: &str = "api.fits.source";
const SINK_FACTORY: &str = "api.pipewireao.discard";
const GRAPH_FACTORY: &str = "pipewireao.calculon-fgn-native";
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
    CalculonFgnNative,
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

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AlgorithmSpec {
    pub label: String,
    pub config: BTreeMap<String, String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ObjectSpec<F> {
    pub factory: F,
    pub module: String,
    pub node_name: String,
    pub plugin_path: String,
    pub arguments: BTreeMap<String, String>,
    pub algorithm: Option<AlgorithmSpec>,
    pub ports: Vec<PortSpec>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LinkSpec {
    pub output: String,
    pub input: String,
}

/// Resolved, development-only model loaded from relaxed SPA-JSON.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DevelopmentConfig {
    pub source: ObjectSpec<EndpointFactory>,
    pub graph: ObjectSpec<GraphFactory>,
    pub sink: ObjectSpec<EndpointFactory>,
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

    /// Validates the resolved scientific and topology contract.
    ///
    /// # Errors
    ///
    /// Returns the first field-specific scientific diagnostic.
    pub fn validate(&self) -> Result<(), ScientificDiagnostic> {
        validate_object_contracts(self)?;

        validate_ports(
            ObjectRole::Source,
            &self.source.ports,
            &[PortDirection::Output],
        )?;
        validate_ports(
            ObjectRole::Graph,
            &self.graph.ports,
            &[PortDirection::Input, PortDirection::Output],
        )?;
        validate_ports(ObjectRole::Sink, &self.sink.ports, &[PortDirection::Input])?;

        match self.source.factory {
            EndpointFactory::SimulatedCompleteFrameSource => require_algorithm(
                ObjectRole::Source,
                self.source.algorithm.as_ref(),
                "docrime-excitation-f32",
            )?,
            EndpointFactory::FitsCompleteFrameSource => {
                if self.source.algorithm.is_some() {
                    return Err(ScientificDiagnostic::new(
                        "source.algorithm.label",
                        "the FITS SPA source does not run a scientific algorithm",
                    ));
                }
            }
            EndpointFactory::FormatAgnosticDiscardSink => {
                unreachable!("source cannot use a sink factory")
            }
        }
        require_algorithm(
            ObjectRole::Graph,
            self.graph.algorithm.as_ref(),
            "leaky-integrator-f32",
        )?;
        if self.sink.algorithm.is_some() {
            return Err(ScientificDiagnostic::new(
                "sink.algorithm.label",
                "the discard SPA sink does not run a scientific algorithm",
            ));
        }
        if !self.graph.arguments.is_empty() {
            return Err(ScientificDiagnostic::new(
                "graph.args",
                "the fgn-native graph uses filter.graph configuration, not SPA factory arguments",
            ));
        }
        if !self.sink.arguments.is_empty() {
            return Err(ScientificDiagnostic::new(
                "sink.args",
                "the discard sink has no fixture-specific factory arguments",
            ));
        }

        validate_port_contracts(self)?;
        validate_source_arguments(self)?;
        validate_algorithm_config(self)?;
        validate_properties(self)?;
        if !self.parameters.is_empty() {
            return Err(ScientificDiagnostic::new(
                "parameters",
                "the increment-1 leaky-integrator fixture declares no ndarray parameters",
            ));
        }
        if !self.observations.is_empty() {
            return Err(ScientificDiagnostic::new(
                "observations",
                "no bounded non-gating observation port exists for this fixture",
            ));
        }
        validate_links(self)
    }

    #[must_use]
    pub fn object_count(&self) -> usize {
        3
    }
}

fn validate_object_contracts(config: &DevelopmentConfig) -> Result<(), ScientificDiagnostic> {
    let (source_plugin, source_module) = match config.source.factory {
        EndpointFactory::SimulatedCompleteFrameSource => {
            ("${CALCULON_FGN_BUNDLE}", FILTER_CHAIN_MODULE)
        }
        EndpointFactory::FitsCompleteFrameSource => {
            ("${PIPEWIREAO_FITS_PLUGIN}", SPA_NODE_FACTORY_MODULE)
        }
        EndpointFactory::FormatAgnosticDiscardSink => {
            unreachable!("source cannot use a sink factory")
        }
    };
    for (role, node_name, plugin_path, expected_plugin) in [
        (
            ObjectRole::Source,
            config.source.node_name.as_str(),
            config.source.plugin_path.as_str(),
            source_plugin,
        ),
        (
            ObjectRole::Graph,
            config.graph.node_name.as_str(),
            config.graph.plugin_path.as_str(),
            "${CALCULON_FGN_BUNDLE}",
        ),
        (
            ObjectRole::Sink,
            config.sink.node_name.as_str(),
            config.sink.plugin_path.as_str(),
            "${PIPEWIREAO_DISCARD_PLUGIN}",
        ),
    ] {
        validate_object_identity(role, node_name, plugin_path, expected_plugin)?;
    }
    let names = [
        config.source.node_name.as_str(),
        config.graph.node_name.as_str(),
        config.sink.node_name.as_str(),
    ];
    if names.into_iter().collect::<BTreeSet<_>>().len() != names.len() {
        return Err(ScientificDiagnostic::new(
            "node.name",
            "source, graph, and sink node names must be distinct",
        ));
    }
    validate_module(ObjectRole::Source, &config.source.module, source_module)?;
    validate_module(ObjectRole::Graph, &config.graph.module, FILTER_CHAIN_MODULE)?;
    validate_module(
        ObjectRole::Sink,
        &config.sink.module,
        SPA_NODE_FACTORY_MODULE,
    )
}

fn validate_module(
    role: ObjectRole,
    module: &str,
    expected: &str,
) -> Result<(), ScientificDiagnostic> {
    if module == expected {
        Ok(())
    } else {
        Err(ScientificDiagnostic::new(
            format!("{}.module", role.name()),
            format!("expected public PipeWireAO module {expected:?}, got {module:?}"),
        ))
    }
}

fn validate_object_identity(
    role: ObjectRole,
    node_name: &str,
    plugin_path: &str,
    expected_plugin: &str,
) -> Result<(), ScientificDiagnostic> {
    if node_name.is_empty() {
        return Err(ScientificDiagnostic::new(
            format!("{}.node.name", role.name()),
            "node name must not be empty",
        ));
    }
    if plugin_path != expected_plugin {
        return Err(ScientificDiagnostic::new(
            format!("{}.plugin.path", role.name()),
            format!(
                "expected maintained build-tree artifact reference {expected_plugin:?}, got {plugin_path:?}"
            ),
        ));
    }
    Ok(())
}

fn validate_ports(
    role: ObjectRole,
    ports: &[PortSpec],
    directions: &[PortDirection],
) -> Result<(), ScientificDiagnostic> {
    if ports.len() != directions.len() {
        return Err(ScientificDiagnostic::new(
            format!("{}.ports", role.name()),
            format!(
                "expected {} declared scientific port(s), got {}",
                directions.len(),
                ports.len()
            ),
        ));
    }
    for (port, direction) in ports.iter().zip(directions) {
        if port.direction != *direction {
            return Err(ScientificDiagnostic::new(
                format!("{}.ports.{}.direction", role.name(), port.name),
                format!("expected {direction:?}, got {:?}", port.direction),
            ));
        }
        if port.element_type != "F32_LE" {
            return Err(ScientificDiagnostic::new(
                format!("{}.ports.{}.element-type", role.name(), port.name),
                format!("expected F32_LE, got {:?}", port.element_type),
            ));
        }
        if port.shape != [2] {
            return Err(ScientificDiagnostic::new(
                format!("{}.ports.{}.shape", role.name(), port.name),
                format!("expected [2], got {:?}", port.shape),
            ));
        }
    }
    Ok(())
}

fn require_algorithm(
    role: ObjectRole,
    actual: Option<&AlgorithmSpec>,
    expected: &str,
) -> Result<(), ScientificDiagnostic> {
    if actual.is_some_and(|algorithm| algorithm.label == expected) {
        Ok(())
    } else {
        Err(ScientificDiagnostic::new(
            format!("{}.algorithm.label", role.name()),
            format!(
                "expected scientific algorithm {expected:?}, got {:?}",
                actual.map(|algorithm| algorithm.label.as_str())
            ),
        ))
    }
}

fn validate_port_contracts(config: &DevelopmentConfig) -> Result<(), ScientificDiagnostic> {
    let source_port_name = match config.source.factory {
        EndpointFactory::SimulatedCompleteFrameSource => "excitation",
        EndpointFactory::FitsCompleteFrameSource => "output",
        EndpointFactory::FormatAgnosticDiscardSink => {
            unreachable!("source cannot use a sink factory")
        }
    };
    let expected = [
        (
            ObjectRole::Source,
            &config.source.ports[0],
            source_port_name,
            "org.calculon.ao.docrime-excitation/1",
        ),
        (
            ObjectRole::Graph,
            &config.graph.ports[0],
            "input",
            "org.calculon.ao.docrime-excitation/1",
        ),
        (
            ObjectRole::Graph,
            &config.graph.ports[1],
            "output",
            "org.calculon.ao.controller-command/1",
        ),
        (
            ObjectRole::Sink,
            &config.sink.ports[0],
            "in",
            "org.calculon.ao.controller-command/1",
        ),
    ];
    for (role, port, name, schema) in expected {
        if port.name != name {
            return Err(ScientificDiagnostic::new(
                format!("{}.ports.{}.name", role.name(), port.name),
                format!("expected scientific port name {name:?}"),
            ));
        }
        if port.schema != schema {
            return Err(ScientificDiagnostic::new(
                format!("{}.ports.{}.schema", role.name(), port.name),
                format!("expected schema {schema:?}, got {:?}", port.schema),
            ));
        }
    }
    Ok(())
}

fn validate_source_arguments(config: &DevelopmentConfig) -> Result<(), ScientificDiagnostic> {
    match config.source.factory {
        EndpointFactory::SimulatedCompleteFrameSource => {
            if config.source.arguments.is_empty() {
                Ok(())
            } else {
                Err(ScientificDiagnostic::new(
                    "source.args",
                    "the simulated FGN source has no SPA factory arguments",
                ))
            }
        }
        EndpointFactory::FitsCompleteFrameSource => validate_exact_values(
            &config.source.arguments,
            "source.args",
            &[
                ("api.fits.hdu", "1"),
                ("api.fits.io-mode", "file"),
                ("api.fits.loop", "true"),
                ("api.fits.output-mode", "frame"),
                ("api.fits.path", "${PIPEWIREAO_RTC_FITS_PATH}"),
                ("api.fits.prefault", "false"),
                ("api.fits.rate", "1000/1"),
                ("api.fits.readiness", "timerfd"),
                ("api.fits.sample-rank", "1"),
                ("api.fits.schema", "org.calculon.ao.docrime-excitation/1"),
            ],
            "factory argument",
        ),
        EndpointFactory::FormatAgnosticDiscardSink => {
            unreachable!("source cannot use a sink factory")
        }
    }
}

fn validate_exact_values(
    actual: &BTreeMap<String, String>,
    field: &str,
    expected: &[(&str, &str)],
    value_kind: &str,
) -> Result<(), ScientificDiagnostic> {
    let expected_names = expected
        .iter()
        .map(|(name, _)| *name)
        .collect::<BTreeSet<_>>();
    if let Some(name) = actual
        .keys()
        .find(|name| !expected_names.contains(name.as_str()))
    {
        return Err(ScientificDiagnostic::new(
            format!("{field}.{name}"),
            format!("{value_kind} is not admitted for this fixture"),
        ));
    }
    for (name, expected_value) in expected {
        match actual.get(*name) {
            Some(value) if value == expected_value => {}
            Some(value) => {
                return Err(ScientificDiagnostic::new(
                    format!("{field}.{name}"),
                    format!("expected {expected_value:?}, got {value:?}"),
                ));
            }
            None => {
                return Err(ScientificDiagnostic::new(
                    format!("{field}.{name}"),
                    format!("required {value_kind} is missing"),
                ));
            }
        }
    }
    Ok(())
}

fn validate_algorithm_config(config: &DevelopmentConfig) -> Result<(), ScientificDiagnostic> {
    let graph = config
        .graph
        .algorithm
        .as_ref()
        .expect("graph algorithm was validated");
    if let EndpointFactory::SimulatedCompleteFrameSource = config.source.factory {
        let source = config
            .source
            .algorithm
            .as_ref()
            .expect("simulated source algorithm was validated");
        validate_exact_values(
            &source.config,
            "source.algorithm.config",
            &[("amplitudes", "[ 1.0 2.0 ]"), ("seed", "0")],
            "construction value",
        )?;
    }
    validate_exact_values(
        &graph.config,
        "graph.algorithm.config",
        &[
            ("extent", "2"),
            ("initial_state", "0.0"),
            ("input_schema", "org.calculon.ao.docrime-excitation/1"),
            ("output_schema", "org.calculon.ao.controller-command/1"),
            ("rate", "[ 1000 1 ]"),
        ],
        "construction value",
    )
}

fn validate_properties(config: &DevelopmentConfig) -> Result<(), ScientificDiagnostic> {
    let expected = BTreeSet::from(["graph.gain", "graph.pole"]);
    let actual = config
        .properties
        .keys()
        .map(String::as_str)
        .collect::<BTreeSet<_>>();
    if actual != expected {
        return Err(ScientificDiagnostic::new(
            "properties",
            format!("expected scalar properties {expected:?}, got {actual:?}"),
        ));
    }
    for (name, value) in &config.properties {
        let parsed = value.parse::<f32>().map_err(|error| {
            ScientificDiagnostic::new(name, format!("scalar value {value:?} is not f32: {error}"))
        })?;
        if !parsed.is_finite() {
            return Err(ScientificDiagnostic::new(
                name,
                format!("scalar value {value:?} must be finite"),
            ));
        }
    }
    Ok(())
}

fn validate_links(config: &DevelopmentConfig) -> Result<(), ScientificDiagnostic> {
    let source_port = match config.source.factory {
        EndpointFactory::SimulatedCompleteFrameSource => "excitation",
        EndpointFactory::FitsCompleteFrameSource => "output",
        EndpointFactory::FormatAgnosticDiscardSink => {
            unreachable!("source cannot use a sink factory")
        }
    };
    let expected = [
        LinkSpec {
            output: format!("{}:{source_port}", config.source.node_name),
            input: format!("{}:input", config.graph.node_name),
        },
        LinkSpec {
            output: format!("{}:output", config.graph.node_name),
            input: format!("{}:in", config.sink.node_name),
        },
    ];
    if config.links == expected {
        Ok(())
    } else {
        Err(ScientificDiagnostic::new(
            "links",
            format!(
                "expected exact source -> graph -> sink links {expected:?}, got {:?}",
                config.links
            ),
        ))
    }
}
