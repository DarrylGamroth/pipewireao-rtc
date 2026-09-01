use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::path::Path;

mod parser;
use parser::{Parser, Value};

const SOURCE_FACTORY: &str = "pipewireao.simulated-complete-frame";
const SINK_FACTORY: &str = "pipewireao.discard-complete-frame";
const GRAPH_FACTORY: &str = "pipewireao.calculon-fgn-native";
const MODULE_NAME: &str = "libpipewire-module-ndarray-filter-chain";

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
    DiscardCompleteFrameSink,
}

impl EndpointFactory {
    #[must_use]
    pub const fn configured_name(self) -> &'static str {
        match self {
            Self::SimulatedCompleteFrameSource => SOURCE_FACTORY,
            Self::DiscardCompleteFrameSink => SINK_FACTORY,
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
pub struct ObjectSpec<F> {
    pub factory: F,
    pub module: String,
    pub node_name: String,
    pub plugin_path: String,
    pub algorithm_label: String,
    pub algorithm_config: BTreeMap<String, String>,
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
        let value = Parser::new(text).parse()?;
        let root = value.object("configuration")?;
        ensure_only(
            root,
            "configuration",
            &[
                "profile",
                "execution",
                "authority",
                "claim",
                "source",
                "graph",
                "sink",
                "properties",
                "parameters",
                "observations",
                "links",
            ],
        )?;

        expect_literal(root, "profile", "development")?;
        expect_literal(root, "execution", "complete-frame")?;
        expect_literal(root, "authority", "none")?;
        expect_literal(root, "claim", "development-characterization")?;

        let source = parse_endpoint(root, ObjectRole::Source)?;
        let graph = parse_graph(root)?;
        let sink = parse_endpoint(root, ObjectRole::Sink)?;
        let properties = string_map(required(root, "properties")?, "properties")?;
        let parameters = string_map(required(root, "parameters")?, "parameters")?;
        let observations = string_array(required(root, "observations")?, "observations")?;
        let links = parse_links(required(root, "links")?)?;

        let config = Self {
            source,
            graph,
            sink,
            properties,
            parameters,
            observations,
            links,
        };
        config.validate()?;
        Ok(config)
    }

    /// Validates the resolved scientific and topology contract.
    ///
    /// # Errors
    ///
    /// Returns the first field-specific scientific diagnostic.
    pub fn validate(&self) -> Result<(), ScientificDiagnostic> {
        validate_object_identity(
            ObjectRole::Source,
            &self.source.node_name,
            &self.source.plugin_path,
            "${CALCULON_FGN_BUNDLE}",
        )?;
        validate_object_identity(
            ObjectRole::Graph,
            &self.graph.node_name,
            &self.graph.plugin_path,
            "${CALCULON_FGN_BUNDLE}",
        )?;
        validate_object_identity(
            ObjectRole::Sink,
            &self.sink.node_name,
            &self.sink.plugin_path,
            "${PIPEWIREAO_NDARRAY_EXAMPLE}",
        )?;
        let names = [
            self.source.node_name.as_str(),
            self.graph.node_name.as_str(),
            self.sink.node_name.as_str(),
        ];
        if names.into_iter().collect::<BTreeSet<_>>().len() != names.len() {
            return Err(ScientificDiagnostic::new(
                "node.name",
                "source, graph, and sink node names must be distinct",
            ));
        }
        validate_module(ObjectRole::Source, &self.source.module)?;
        validate_module(ObjectRole::Graph, &self.graph.module)?;
        validate_module(ObjectRole::Sink, &self.sink.module)?;

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

        require_algorithm(
            ObjectRole::Source,
            &self.source.algorithm_label,
            "docrime-excitation-f32",
        )?;
        require_algorithm(
            ObjectRole::Graph,
            &self.graph.algorithm_label,
            "leaky-integrator-f32",
        )?;
        require_algorithm(ObjectRole::Sink, &self.sink.algorithm_label, "scale-f32")?;

        validate_port_contracts(self)?;
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

fn parse_endpoint(
    root: &BTreeMap<String, Value>,
    role: ObjectRole,
) -> Result<ObjectSpec<EndpointFactory>, ScientificDiagnostic> {
    let value = required(root, role.name())?;
    let object = value.object(role.name())?;
    ensure_only(
        object,
        role.name(),
        &[
            "factory",
            "module",
            "node.name",
            "plugin.path",
            "algorithm.label",
            "algorithm.config",
            "ports",
        ],
    )?;
    let factory_name = string(
        required(object, "factory")?,
        &format!("{}.factory", role.name()),
    )?;
    let factory = match (role, factory_name.as_str()) {
        (ObjectRole::Source, SOURCE_FACTORY) => EndpointFactory::SimulatedCompleteFrameSource,
        (ObjectRole::Sink, SINK_FACTORY) => EndpointFactory::DiscardCompleteFrameSink,
        (ObjectRole::Source, _) => {
            return Err(ScientificDiagnostic::new(
                "source.factory",
                format!("factory {factory_name:?} is not in the development-safe source allowlist"),
            ));
        }
        (ObjectRole::Sink, _) => {
            return Err(ScientificDiagnostic::new(
                "sink.factory",
                format!("factory {factory_name:?} is not in the non-actuating sink allowlist"),
            ));
        }
        (ObjectRole::Graph, _) => unreachable!("graph is parsed separately"),
    };
    parse_object_fields(object, role, factory)
}

fn parse_graph(
    root: &BTreeMap<String, Value>,
) -> Result<ObjectSpec<GraphFactory>, ScientificDiagnostic> {
    let object = required(root, "graph")?.object("graph")?;
    ensure_only(
        object,
        "graph",
        &[
            "factory",
            "module",
            "node.name",
            "plugin.path",
            "algorithm.label",
            "algorithm.config",
            "ports",
        ],
    )?;
    let name = string(required(object, "factory")?, "graph.factory")?;
    if name != GRAPH_FACTORY {
        return Err(ScientificDiagnostic::new(
            "graph.factory",
            format!("expected the fgn-native factory {GRAPH_FACTORY:?}, got {name:?}"),
        ));
    }
    parse_object_fields(object, ObjectRole::Graph, GraphFactory::CalculonFgnNative)
}

fn parse_object_fields<F: Copy>(
    object: &BTreeMap<String, Value>,
    role: ObjectRole,
    factory: F,
) -> Result<ObjectSpec<F>, ScientificDiagnostic> {
    Ok(ObjectSpec {
        factory,
        module: string(
            required(object, "module")?,
            &format!("{}.module", role.name()),
        )?,
        node_name: string(
            required(object, "node.name")?,
            &format!("{}.node.name", role.name()),
        )?,
        plugin_path: string(
            required(object, "plugin.path")?,
            &format!("{}.plugin.path", role.name()),
        )?,
        algorithm_label: string(
            required(object, "algorithm.label")?,
            &format!("{}.algorithm.label", role.name()),
        )?,
        algorithm_config: string_map(
            required(object, "algorithm.config")?,
            &format!("{}.algorithm.config", role.name()),
        )?,
        ports: parse_ports(
            required(object, "ports")?,
            &format!("{}.ports", role.name()),
        )?,
    })
}

fn parse_ports(value: &Value, field: &str) -> Result<Vec<PortSpec>, ScientificDiagnostic> {
    let values = value.array(field)?;
    let mut result = Vec::with_capacity(values.len());
    for (index, value) in values.iter().enumerate() {
        let item_field = format!("{field}[{index}]");
        let object = value.object(&item_field)?;
        ensure_only(
            object,
            &item_field,
            &["name", "direction", "element-type", "shape", "schema"],
        )?;
        let direction_field = format!("{item_field}.direction");
        result.push(PortSpec {
            name: string(required(object, "name")?, &format!("{item_field}.name"))?,
            direction: PortDirection::parse(
                &direction_field,
                &string(required(object, "direction")?, &direction_field)?,
            )?,
            element_type: string(
                required(object, "element-type")?,
                &format!("{item_field}.element-type"),
            )?,
            shape: integer_array(required(object, "shape")?, &format!("{item_field}.shape"))?,
            schema: string(required(object, "schema")?, &format!("{item_field}.schema"))?,
        });
    }
    Ok(result)
}

fn parse_links(value: &Value) -> Result<Vec<LinkSpec>, ScientificDiagnostic> {
    let values = value.array("links")?;
    let mut result = Vec::with_capacity(values.len());
    for (index, value) in values.iter().enumerate() {
        let field = format!("links[{index}]");
        let object = value.object(&field)?;
        ensure_only(object, &field, &["output", "input"])?;
        result.push(LinkSpec {
            output: string(required(object, "output")?, &format!("{field}.output"))?,
            input: string(required(object, "input")?, &format!("{field}.input"))?,
        });
    }
    Ok(result)
}

fn validate_module(role: ObjectRole, module: &str) -> Result<(), ScientificDiagnostic> {
    if module == MODULE_NAME {
        Ok(())
    } else {
        Err(ScientificDiagnostic::new(
            format!("{}.module", role.name()),
            format!("expected public PipeWireAO module {MODULE_NAME:?}, got {module:?}"),
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
    actual: &str,
    expected: &str,
) -> Result<(), ScientificDiagnostic> {
    if actual == expected {
        Ok(())
    } else {
        Err(ScientificDiagnostic::new(
            format!("{}.algorithm.label", role.name()),
            format!("expected scientific algorithm {expected:?}, got {actual:?}"),
        ))
    }
}

fn validate_port_contracts(config: &DevelopmentConfig) -> Result<(), ScientificDiagnostic> {
    let expected = [
        (
            ObjectRole::Source,
            &config.source.ports[0],
            "excitation",
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

fn validate_algorithm_config(config: &DevelopmentConfig) -> Result<(), ScientificDiagnostic> {
    expect_map_values(
        &config.source.algorithm_config,
        "source.algorithm.config",
        &[("amplitudes", "[ 1.0 2.0 ]"), ("seed", "0")],
    )?;
    expect_map_values(
        &config.graph.algorithm_config,
        "graph.algorithm.config",
        &[
            ("extent", "2"),
            ("initial_state", "0.0"),
            ("input_schema", "org.calculon.ao.docrime-excitation/1"),
            ("output_schema", "org.calculon.ao.controller-command/1"),
        ],
    )?;
    expect_map_values(
        &config.sink.algorithm_config,
        "sink.algorithm.config",
        &[
            ("shape", "[ 2 ]"),
            ("schema", "org.calculon.ao.controller-command/1"),
        ],
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
    let expected = [
        LinkSpec {
            output: format!("{}:excitation", config.source.node_name),
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

fn expect_map_values(
    actual: &BTreeMap<String, String>,
    field: &str,
    expected: &[(&str, &str)],
) -> Result<(), ScientificDiagnostic> {
    let expected = expected
        .iter()
        .map(|(key, value)| ((*key).to_owned(), (*value).to_owned()))
        .collect::<BTreeMap<_, _>>();
    if actual == &expected {
        Ok(())
    } else {
        Err(ScientificDiagnostic::new(
            field,
            format!("expected declared values {expected:?}, got {actual:?}"),
        ))
    }
}

fn expect_literal(
    root: &BTreeMap<String, Value>,
    key: &str,
    expected: &str,
) -> Result<(), ScientificDiagnostic> {
    let actual = string(required(root, key)?, key)?;
    if actual == expected {
        Ok(())
    } else {
        Err(ScientificDiagnostic::new(
            key,
            format!("expected {expected:?}, got {actual:?}"),
        ))
    }
}

fn ensure_only(
    object: &BTreeMap<String, Value>,
    field: &str,
    allowed: &[&str],
) -> Result<(), ScientificDiagnostic> {
    for name in object.keys() {
        if !allowed.contains(&name.as_str()) {
            return Err(ScientificDiagnostic::new(
                format!("{field}.{name}"),
                "field is not part of the development configuration model",
            ));
        }
    }
    Ok(())
}

fn required<'a>(
    object: &'a BTreeMap<String, Value>,
    key: &str,
) -> Result<&'a Value, ScientificDiagnostic> {
    object
        .get(key)
        .ok_or_else(|| ScientificDiagnostic::new(key, "required field is missing"))
}

fn string(value: &Value, field: &str) -> Result<String, ScientificDiagnostic> {
    match value {
        Value::Atom(value) => Ok(value.clone()),
        _ => Err(ScientificDiagnostic::new(field, "expected a scalar value")),
    }
}

fn string_map(
    value: &Value,
    field: &str,
) -> Result<BTreeMap<String, String>, ScientificDiagnostic> {
    value
        .object(field)?
        .iter()
        .map(|(key, value)| {
            scalar_or_array(value, &format!("{field}.{key}")).map(|value| (key.clone(), value))
        })
        .collect()
}

fn scalar_or_array(value: &Value, field: &str) -> Result<String, ScientificDiagnostic> {
    match value {
        Value::Atom(value) => Ok(value.clone()),
        Value::Array(values) => {
            let values = values
                .iter()
                .enumerate()
                .map(|(index, value)| string(value, &format!("{field}[{index}]")))
                .collect::<Result<Vec<_>, _>>()?;
            Ok(format!("[ {} ]", values.join(" ")))
        }
        Value::Object(_) => Err(ScientificDiagnostic::new(
            field,
            "nested objects are not valid scalar or ndarray construction values",
        )),
    }
}

fn string_array(value: &Value, field: &str) -> Result<Vec<String>, ScientificDiagnostic> {
    value
        .array(field)?
        .iter()
        .enumerate()
        .map(|(index, value)| string(value, &format!("{field}[{index}]")))
        .collect()
}

fn integer_array(value: &Value, field: &str) -> Result<Vec<u32>, ScientificDiagnostic> {
    value
        .array(field)?
        .iter()
        .enumerate()
        .map(|(index, value)| {
            let item_field = format!("{field}[{index}]");
            let value = string(value, &item_field)?;
            value.parse::<u32>().map_err(|error| {
                ScientificDiagnostic::new(
                    item_field,
                    format!("shape extent {value:?} is not an unsigned integer: {error}"),
                )
            })
        })
        .collect()
}
