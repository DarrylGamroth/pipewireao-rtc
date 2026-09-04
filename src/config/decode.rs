use super::{
    DevelopmentConfig, EndpointFactory, ExecutionGroupSpec, GraphFactory, LinkSpec,
    ObjectRealization, ObjectRole, ObjectSpec, PortDirection, PortSpec, ScientificDiagnostic,
    FITS_SOURCE_FACTORY, GRAPH_FACTORY, SIMULATED_SOURCE_FACTORY, SINK_FACTORY,
};
use crate::ffi::spa_json::{Cursor, SyntaxError, Token};
use std::collections::BTreeMap;

pub(super) fn development_config(text: &str) -> Result<DevelopmentConfig, ScientificDiagnostic> {
    let mut root = Object::root(text, "configuration")?;
    let mut profile = None;
    let mut execution = None;
    let mut authority = None;
    let mut claim = None;
    let mut sources = None;
    let mut graphs = None;
    let mut sinks = None;
    let mut execution_groups = None;
    let mut properties = None;
    let mut parameters = None;
    let mut observations = None;
    let mut links = None;

    while let Some((name, value)) = root.next()? {
        match name.as_str() {
            "profile" => assign(&mut profile, value, "profile")?,
            "execution" => assign(&mut execution, value, "execution")?,
            "authority" => assign(&mut authority, value, "authority")?,
            "claim" => assign(&mut claim, value, "claim")?,
            "sources" => assign(&mut sources, value, "sources")?,
            "graphs" => assign(&mut graphs, value, "graphs")?,
            "sinks" => assign(&mut sinks, value, "sinks")?,
            "execution-groups" => assign(&mut execution_groups, value, "execution-groups")?,
            "properties" => assign(&mut properties, value, "properties")?,
            "parameters" => assign(&mut parameters, value, "parameters")?,
            "observations" => assign(&mut observations, value, "observations")?,
            "links" => assign(&mut links, value, "links")?,
            _ => return unknown_field("configuration", &name),
        }
    }

    expect_literal(required(profile, "profile")?, "profile", "development")?;
    expect_literal(
        required(execution, "execution")?,
        "execution",
        "complete-frame",
    )?;
    expect_literal(required(authority, "authority")?, "authority", "none")?;
    expect_literal(
        required(claim, "claim")?,
        "claim",
        "development-characterization",
    )?;

    Ok(DevelopmentConfig {
        sources: endpoint_array(required(sources, "sources")?, ObjectRole::Source, "sources")?,
        graphs: graph_array(required(graphs, "graphs")?)?,
        sinks: endpoint_array(required(sinks, "sinks")?, ObjectRole::Sink, "sinks")?,
        execution_groups: execution_group_array(required(execution_groups, "execution-groups")?)?,
        properties: string_map(required(properties, "properties")?, "properties")?,
        parameters: string_map(required(parameters, "parameters")?, "parameters")?,
        observations: string_array(required(observations, "observations")?, "observations")?,
        links: link_array(required(links, "links")?)?,
    })
}

struct DecodedObject {
    factory: Option<String>,
    ownership: Option<String>,
    module: Option<String>,
    node_name: String,
    plugin_path: Option<String>,
    configuration_path: Option<String>,
    arguments: BTreeMap<String, String>,
    ports: Vec<PortSpec>,
}

impl DecodedObject {
    fn with_realization<F>(self, realization: ObjectRealization<F>) -> ObjectSpec<F> {
        ObjectSpec {
            realization,
            module: self.module,
            node_name: self.node_name,
            plugin_path: self.plugin_path,
            configuration_path: self.configuration_path,
            arguments: self.arguments,
            ports: self.ports,
        }
    }
}

fn endpoint(
    token: Token<'_>,
    role: ObjectRole,
    field: &str,
) -> Result<ObjectSpec<EndpointFactory>, ScientificDiagnostic> {
    let object = object_spec(token, field)?;
    let realization = match object.ownership.as_deref() {
        Some("external") => {
            if object.factory.is_some() {
                return Err(ScientificDiagnostic::new(
                    format!("{field}.factory"),
                    "external endpoint must not declare a runner-created factory",
                ));
            }
            ObjectRealization::External
        }
        None | Some("runner") => {
            let Some(name) = object.factory.as_deref() else {
                return Err(ScientificDiagnostic::new(
                    format!("{field}.factory"),
                    "runner-owned endpoint must declare a factory",
                ));
            };
            let factory = match (role, name) {
                (ObjectRole::Source, SIMULATED_SOURCE_FACTORY) => {
                    EndpointFactory::SimulatedCompleteFrameSource
                }
                (ObjectRole::Source, FITS_SOURCE_FACTORY) => {
                    EndpointFactory::FitsCompleteFrameSource
                }
                (ObjectRole::Sink, SINK_FACTORY) => EndpointFactory::FormatAgnosticDiscardSink,
                (ObjectRole::Source, name) => {
                    return Err(ScientificDiagnostic::new(
                        format!("{field}.factory"),
                        format!("factory {name:?} is not in the development-safe source allowlist"),
                    ));
                }
                (ObjectRole::Sink, name) => {
                    return Err(ScientificDiagnostic::new(
                        format!("{field}.factory"),
                        format!("factory {name:?} is not in the non-actuating sink allowlist"),
                    ));
                }
                (ObjectRole::Graph, _) => unreachable!("graph is decoded separately"),
            };
            ObjectRealization::Factory(factory)
        }
        Some(value) => {
            return Err(ScientificDiagnostic::new(
                format!("{field}.ownership"),
                format!("ownership must be runner or external, got {value:?}"),
            ));
        }
    };
    Ok(object.with_realization(realization))
}

fn graph_object(
    token: Token<'_>,
    field: &str,
) -> Result<ObjectSpec<GraphFactory>, ScientificDiagnostic> {
    let object = object_spec(token, field)?;
    if object
        .ownership
        .as_deref()
        .is_some_and(|value| value != "runner")
    {
        return Err(ScientificDiagnostic::new(
            format!("{field}.ownership"),
            "fgn-native graph ownership must be runner",
        ));
    }
    if object.factory.as_deref() != Some(GRAPH_FACTORY) {
        return Err(ScientificDiagnostic::new(
            format!("{field}.factory"),
            format!(
                "expected the fgn-native factory {GRAPH_FACTORY:?}, got {:?}",
                object.factory
            ),
        ));
    }
    Ok(object.with_realization(ObjectRealization::Factory(GraphFactory::FgnNative)))
}

fn endpoint_array(
    token: Token<'_>,
    role: ObjectRole,
    field: &str,
) -> Result<Vec<ObjectSpec<EndpointFactory>>, ScientificDiagnostic> {
    let mut array = Array::token(token, field)?;
    let mut objects = Vec::new();
    while let Some(token) = array.next()? {
        let item_field = format!("{field}[{}]", objects.len());
        objects.push(endpoint(token, role, &item_field)?);
    }
    Ok(objects)
}

fn graph_array(token: Token<'_>) -> Result<Vec<ObjectSpec<GraphFactory>>, ScientificDiagnostic> {
    let mut array = Array::token(token, "graphs")?;
    let mut objects = Vec::new();
    while let Some(token) = array.next()? {
        let field = format!("graphs[{}]", objects.len());
        objects.push(graph_object(token, &field)?);
    }
    Ok(objects)
}

fn object_spec(token: Token<'_>, field: &str) -> Result<DecodedObject, ScientificDiagnostic> {
    let mut object = Object::token(token, field)?;
    let mut factory = None;
    let mut ownership = None;
    let mut module = None;
    let mut node_name = None;
    let mut plugin_path = None;
    let mut configuration_path = None;
    let mut arguments = None;
    let mut ports = None;

    while let Some((name, value)) = object.next()? {
        match name.as_str() {
            "factory" => assign(&mut factory, value, &format!("{field}.factory"))?,
            "ownership" => assign(&mut ownership, value, &format!("{field}.ownership"))?,
            "module" => assign(&mut module, value, &format!("{field}.module"))?,
            "node.name" => assign(&mut node_name, value, &format!("{field}.node.name"))?,
            "plugin.path" => assign(&mut plugin_path, value, &format!("{field}.plugin.path"))?,
            "config.path" => assign(
                &mut configuration_path,
                value,
                &format!("{field}.config.path"),
            )?,
            "args" => assign(&mut arguments, value, &format!("{field}.args"))?,
            "ports" => assign(&mut ports, value, &format!("{field}.ports"))?,
            _ => return unknown_field(field, &name),
        }
    }

    Ok(DecodedObject {
        factory: factory
            .map(|token| scalar(token, &format!("{field}.factory")))
            .transpose()?,
        ownership: ownership
            .map(|token| scalar(token, &format!("{field}.ownership")))
            .transpose()?,
        module: module
            .map(|token| scalar(token, &format!("{field}.module")))
            .transpose()?,
        node_name: scalar(
            required(node_name, &format!("{field}.node.name"))?,
            &format!("{field}.node.name"),
        )?,
        plugin_path: plugin_path
            .map(|token| scalar(token, &format!("{field}.plugin.path")))
            .transpose()?,
        configuration_path: configuration_path
            .map(|token| scalar(token, &format!("{field}.config.path")))
            .transpose()?,
        arguments: arguments.map_or_else(
            || Ok(BTreeMap::new()),
            |token| string_map(token, &format!("{field}.args")),
        )?,
        ports: port_array(
            required(ports, &format!("{field}.ports"))?,
            &format!("{field}.ports"),
        )?,
    })
}

fn port_array(token: Token<'_>, field: &str) -> Result<Vec<PortSpec>, ScientificDiagnostic> {
    let mut array = Array::token(token, field)?;
    let mut ports = Vec::new();
    while let Some(token) = array.next()? {
        let item_field = format!("{field}[{}]", ports.len());
        ports.push(port(token, &item_field)?);
    }
    Ok(ports)
}

fn port(token: Token<'_>, field: &str) -> Result<PortSpec, ScientificDiagnostic> {
    let mut object = Object::token(token, field)?;
    let mut name = None;
    let mut direction = None;
    let mut element_type = None;
    let mut shape = None;
    let mut schema = None;
    while let Some((key, value)) = object.next()? {
        match key.as_str() {
            "name" => assign(&mut name, value, &format!("{field}.name"))?,
            "direction" => assign(&mut direction, value, &format!("{field}.direction"))?,
            "element-type" => assign(&mut element_type, value, &format!("{field}.element-type"))?,
            "shape" => assign(&mut shape, value, &format!("{field}.shape"))?,
            "schema" => assign(&mut schema, value, &format!("{field}.schema"))?,
            _ => return unknown_field(field, &key),
        }
    }
    let direction_field = format!("{field}.direction");
    Ok(PortSpec {
        name: scalar(
            required(name, &format!("{field}.name"))?,
            &format!("{field}.name"),
        )?,
        direction: PortDirection::parse(
            &direction_field,
            &scalar(required(direction, &direction_field)?, &direction_field)?,
        )?,
        element_type: scalar(
            required(element_type, &format!("{field}.element-type"))?,
            &format!("{field}.element-type"),
        )?,
        shape: integer_array(
            required(shape, &format!("{field}.shape"))?,
            &format!("{field}.shape"),
        )?,
        schema: scalar(
            required(schema, &format!("{field}.schema"))?,
            &format!("{field}.schema"),
        )?,
    })
}

fn link_array(token: Token<'_>) -> Result<Vec<LinkSpec>, ScientificDiagnostic> {
    let mut array = Array::token(token, "links")?;
    let mut links = Vec::new();
    while let Some(token) = array.next()? {
        let field = format!("links[{}]", links.len());
        let mut object = Object::token(token, &field)?;
        let mut output = None;
        let mut input = None;
        let mut passive = None;
        while let Some((name, value)) = object.next()? {
            match name.as_str() {
                "output" => assign(&mut output, value, &format!("{field}.output"))?,
                "input" => assign(&mut input, value, &format!("{field}.input"))?,
                "passive" => assign(&mut passive, value, &format!("{field}.passive"))?,
                _ => return unknown_field(&field, &name),
            }
        }
        links.push(LinkSpec {
            output: scalar(
                required(output, &format!("{field}.output"))?,
                &format!("{field}.output"),
            )?,
            input: scalar(
                required(input, &format!("{field}.input"))?,
                &format!("{field}.input"),
            )?,
            passive: boolean(
                required(passive, &format!("{field}.passive"))?,
                &format!("{field}.passive"),
            )?,
        });
    }
    Ok(links)
}

fn execution_group_array(
    token: Token<'_>,
) -> Result<Vec<ExecutionGroupSpec>, ScientificDiagnostic> {
    let mut array = Array::token(token, "execution-groups")?;
    let mut groups = Vec::new();
    while let Some(token) = array.next()? {
        let field = format!("execution-groups[{}]", groups.len());
        let mut object = Object::token(token, &field)?;
        let mut name = None;
        let mut nodes = None;
        while let Some((key, value)) = object.next()? {
            match key.as_str() {
                "name" => assign(&mut name, value, &format!("{field}.name"))?,
                "nodes" => assign(&mut nodes, value, &format!("{field}.nodes"))?,
                _ => return unknown_field(&field, &key),
            }
        }
        groups.push(ExecutionGroupSpec {
            name: scalar(
                required(name, &format!("{field}.name"))?,
                &format!("{field}.name"),
            )?,
            nodes: string_array(
                required(nodes, &format!("{field}.nodes"))?,
                &format!("{field}.nodes"),
            )?,
        });
    }
    Ok(groups)
}

fn string_map(
    token: Token<'_>,
    field: &str,
) -> Result<BTreeMap<String, String>, ScientificDiagnostic> {
    let mut object = Object::token(token, field)?;
    let mut values = BTreeMap::new();
    while let Some((name, token)) = object.next()? {
        let item_field = format!("{field}.{name}");
        let value = scalar_or_array(token, &item_field)?;
        if values.insert(name, value).is_some() {
            return duplicate_field(&item_field);
        }
    }
    Ok(values)
}

fn scalar_or_array(token: Token<'_>, field: &str) -> Result<String, ScientificDiagnostic> {
    if token.is_array() {
        let mut array = token.array().map_err(|error| syntax(field, error))?;
        let mut values = Vec::new();
        while let Some(token) = array.next().map_err(|error| syntax(field, error))? {
            values.push(scalar(token, &format!("{field}[{}]", values.len()))?);
        }
        return Ok(format!("[ {} ]", values.join(" ")));
    }
    if token.is_object() {
        return Err(ScientificDiagnostic::new(
            field,
            "nested objects are not valid scalar or ndarray construction values",
        ));
    }
    scalar(token, field)
}

fn string_array(token: Token<'_>, field: &str) -> Result<Vec<String>, ScientificDiagnostic> {
    let mut array = Array::token(token, field)?;
    let mut values = Vec::new();
    while let Some(token) = array.next()? {
        values.push(scalar(token, &format!("{field}[{}]", values.len()))?);
    }
    Ok(values)
}

fn integer_array(token: Token<'_>, field: &str) -> Result<Vec<u32>, ScientificDiagnostic> {
    string_array(token, field)?
        .into_iter()
        .enumerate()
        .map(|(index, value)| {
            value.parse::<u32>().map_err(|error| {
                ScientificDiagnostic::new(
                    format!("{field}[{index}]"),
                    format!("shape extent {value:?} is not an unsigned integer: {error}"),
                )
            })
        })
        .collect()
}

fn expect_literal(
    token: Token<'_>,
    field: &str,
    expected: &str,
) -> Result<(), ScientificDiagnostic> {
    let actual = scalar(token, field)?;
    if actual == expected {
        Ok(())
    } else {
        Err(ScientificDiagnostic::new(
            field,
            format!("expected {expected:?}, got {actual:?}"),
        ))
    }
}

fn boolean(token: Token<'_>, field: &str) -> Result<bool, ScientificDiagnostic> {
    match scalar(token, field)?.as_str() {
        "true" => Ok(true),
        "false" => Ok(false),
        value => Err(ScientificDiagnostic::new(
            field,
            format!("expected true or false, got {value:?}"),
        )),
    }
}

fn scalar(token: Token<'_>, field: &str) -> Result<String, ScientificDiagnostic> {
    let value = token.scalar().map_err(|error| syntax(field, error))?;
    if value.contains('\0') {
        return Err(ScientificDiagnostic::new(
            field,
            "scalar values must not contain NUL",
        ));
    }
    Ok(value)
}

fn assign<T>(slot: &mut Option<T>, value: T, field: &str) -> Result<(), ScientificDiagnostic> {
    if slot.is_some() {
        duplicate_field(field)
    } else {
        *slot = Some(value);
        Ok(())
    }
}

fn required<T>(value: Option<T>, field: &str) -> Result<T, ScientificDiagnostic> {
    value.ok_or_else(|| ScientificDiagnostic::new(field, "required field is missing"))
}

fn duplicate_field<T>(field: &str) -> Result<T, ScientificDiagnostic> {
    Err(ScientificDiagnostic::new(field, "field is duplicated"))
}

fn unknown_field<T>(object: &str, name: &str) -> Result<T, ScientificDiagnostic> {
    Err(ScientificDiagnostic::new(
        format!("{object}.{name}"),
        "field is not part of the development configuration model",
    ))
}

fn syntax(field: &str, error: SyntaxError) -> ScientificDiagnostic {
    let SyntaxError {
        line,
        column,
        reason,
    } = error;
    let location = if line > 0 && column > 0 {
        format!(" at line {line}, column {column}")
    } else {
        String::new()
    };
    ScientificDiagnostic::new(
        field,
        format!("invalid relaxed SPA-JSON{location}: {reason}"),
    )
}

struct Object<'document> {
    cursor: Cursor<'document>,
    field: String,
}

impl<'document> Object<'document> {
    fn root(document: &'document str, field: &str) -> Result<Self, ScientificDiagnostic> {
        let cursor = Cursor::root_object(document).map_err(|error| syntax(field, error))?;
        Ok(Self {
            cursor,
            field: field.to_owned(),
        })
    }

    fn token(token: Token<'document>, field: &str) -> Result<Self, ScientificDiagnostic> {
        let cursor = token.object().map_err(|error| syntax(field, error))?;
        Ok(Self {
            cursor,
            field: field.to_owned(),
        })
    }

    fn next(&mut self) -> Result<Option<(String, Token<'document>)>, ScientificDiagnostic> {
        let Some(entry) = self
            .cursor
            .next_entry()
            .map_err(|error| syntax(&self.field, error))?
        else {
            return Ok(None);
        };
        if entry.key.contains('\0') {
            return Err(ScientificDiagnostic::new(
                &self.field,
                "object keys must not contain NUL",
            ));
        }
        Ok(Some((entry.key, entry.value)))
    }
}

struct Array<'document> {
    cursor: Cursor<'document>,
    field: String,
}

impl<'document> Array<'document> {
    fn token(token: Token<'document>, field: &str) -> Result<Self, ScientificDiagnostic> {
        let cursor = token.array().map_err(|error| syntax(field, error))?;
        Ok(Self {
            cursor,
            field: field.to_owned(),
        })
    }

    fn next(&mut self) -> Result<Option<Token<'document>>, ScientificDiagnostic> {
        self.cursor
            .next()
            .map_err(|error| syntax(&self.field, error))
    }
}
