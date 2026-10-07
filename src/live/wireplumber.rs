//! Explicitly selected `WirePlumber` link realization for cold integration gates.

use super::realization::{Endpoint, Identity, Intent, Link, MAX_LINKS};
use super::realization_marker::Marker;
use super::{
    configured_port_rate, is_node_named, split_endpoint, validate_ndarray_format,
    DevelopmentConfig, LinkAdmissionState, LinkContract, LiveGraphAdapter, LiveLink, ObjectRole,
    PortDirection, PortSpec, ScientificDiagnostic, CALLBACK_TIMEOUT,
};
use crate::config::LinkSpec;
use pipewire as pw;
use pw::properties::PropertiesBox;
use pw::registry::GlobalObject;
use pw::spa::utils::{Fraction, SpaTypes};
use pw::types::ObjectType;
use std::cell::{Cell, RefCell};
use std::collections::BTreeMap;
use std::rc::Rc;
use std::time::Instant;

pub(super) struct Selection {
    manager: Identity,
    marker_name: String,
    next_generation: i64,
}

type LinkFormats = BTreeMap<usize, (ObjectRole, PortSpec, Fraction)>;

pub(super) struct Session {
    marker: Marker,
    identity: Option<Identity>,
    removed: Rc<Cell<bool>>,
    intent: Option<Intent>,
    required: Vec<(Identity, ObjectType, Rc<Cell<bool>>)>,
    link_identities: BTreeMap<usize, Identity>,
    formats: LinkFormats,
    withdrawal_ack_eligible: bool,
}

fn diagnostic(message: impl Into<String>) -> ScientificDiagnostic {
    ScientificDiagnostic::new("WirePlumber realization", message)
}

fn identity(global: &GlobalObject<PropertiesBox>) -> Result<Identity, ScientificDiagnostic> {
    let serial = global
        .props
        .as_ref()
        .and_then(|props| props.get("object.serial"))
        .and_then(|value| value.parse::<u64>().ok())
        .filter(|serial| *serial != 0)
        .ok_or_else(|| diagnostic(format!("global {} has no valid serial", global.id)))?;
    if global.id == 0 || global.id == u32::MAX {
        return Err(diagnostic("invalid global identity"));
    }
    Ok(Identity {
        global_id: global.id,
        serial,
    })
}

fn property_id(
    global: &GlobalObject<PropertiesBox>,
    name: &str,
) -> Result<u32, ScientificDiagnostic> {
    global
        .props
        .as_ref()
        .and_then(|props| props.get(name))
        .and_then(|value| value.parse::<u32>().ok())
        .filter(|id| *id != 0 && *id != u32::MAX)
        .ok_or_else(|| diagnostic(format!("global {} has no valid {name}", global.id)))
}

fn exact_global<'a>(
    globals: &'a BTreeMap<u32, GlobalObject<PropertiesBox>>,
    expected: Identity,
    kind: &ObjectType,
) -> Result<&'a GlobalObject<PropertiesBox>, ScientificDiagnostic> {
    globals
        .get(&expected.global_id)
        .filter(|global| &global.type_ == kind)
        .filter(|global| identity(global).ok() == Some(expected))
        .ok_or_else(|| {
            diagnostic(format!(
                "required {kind:?} {}:{} disappeared or was replaced",
                expected.global_id, expected.serial
            ))
        })
}

fn check_endpoint(
    globals: &BTreeMap<u32, GlobalObject<PropertiesBox>>,
    endpoint: Endpoint,
    direction: &str,
) -> Result<(), ScientificDiagnostic> {
    let node = exact_global(globals, endpoint.node, &ObjectType::Node)?;
    let port = exact_global(globals, endpoint.port, &ObjectType::Port)?;
    exact_global(globals, endpoint.owner, &ObjectType::Client)?;
    if property_id(node, "client.id")? != endpoint.owner.global_id
        || property_id(port, "node.id")? != endpoint.node.global_id
        || port
            .props
            .as_ref()
            .and_then(|props| props.get("port.direction"))
            != Some(direction)
    {
        return Err(diagnostic(
            "endpoint node, port, direction or creator provenance changed",
        ));
    }
    Ok(())
}

fn prefix(identity: Identity) -> String {
    format!(
        "pipewireao/rtc-realization/{}:{}/",
        identity.global_id, identity.serial
    )
}

// These independent observations define the completion truth table.
#[allow(clippy::fn_params_excessive_bools)]
fn withdrawal_fenced(
    acknowledgment_eligible: bool,
    marker_removed: bool,
    manager_gone: bool,
    correlated_links_present: bool,
) -> bool {
    !correlated_links_present && (manager_gone || (acknowledgment_eligible && marker_removed))
}

fn capture_link_formats(
    config: &DevelopmentConfig,
    declared: &[(usize, &LinkSpec)],
) -> Result<LinkFormats, ScientificDiagnostic> {
    let mut formats = BTreeMap::new();
    for (index, link) in declared {
        let (node_name, port_name) = split_endpoint(&link.output)?;
        let (role, port) = config
            .sources
            .iter()
            .map(|node| (ObjectRole::Source, node.node_name.as_str(), &node.ports))
            .chain(
                config
                    .graphs
                    .iter()
                    .map(|node| (ObjectRole::Graph, node.node_name.as_str(), &node.ports)),
            )
            .find_map(|(role, name, ports)| {
                (name == node_name)
                    .then(|| {
                        ports
                            .iter()
                            .find(|port| port.name == port_name)
                            .map(|port| (role, port))
                    })
                    .flatten()
            })
            .ok_or_else(|| diagnostic("declared output Format specification is missing"))?;
        formats.insert(
            *index,
            (role, port.clone(), configured_port_rate(config, port)?),
        );
    }
    Ok(formats)
}

fn validate_link_contract(
    contract: &LinkContract,
    row: &Link,
    (role, port, rate): &(ObjectRole, PortSpec, Fraction),
) -> Result<(), ScientificDiagnostic> {
    let passive = match contract.passive.as_deref() {
        Some("true" | "1") => true,
        Some("false" | "0") | None => false,
        _ => return Err(diagnostic("actual link passive policy is invalid")),
    };
    if !matches!(contract.linger.as_deref(), Some("false" | "0") | None) {
        return Err(diagnostic("actual link has a lingering lifetime"));
    }
    if (
        contract.output_node,
        contract.output_port,
        contract.input_node,
        contract.input_port,
    ) != (
        row.output.node.global_id,
        row.output.port.global_id,
        row.input.node.global_id,
        row.input.port.global_id,
    ) || passive != row.passive
    {
        return Err(diagnostic(
            "actual link endpoints or passive policy differs",
        ));
    }
    let format = contract
        .format
        .as_ref()
        .ok_or_else(|| diagnostic("declared link has no negotiated Format"))?
        .as_ref()
        .map_err(|error| diagnostic(error.clone()))?;
    if format.type_ != SpaTypes::ObjectParamFormat.as_raw()
        || format.id != pw::spa::param::ParamType::Format.as_raw()
    {
        return Err(diagnostic(
            "negotiated link Format has the wrong native type or ID",
        ));
    }

    validate_ndarray_format(format, *role, port, *rate)?;
    Ok(())
}

impl LiveGraphAdapter {
    /// Selects one exact public Client as an experimental link realizer.
    /// Default connections retain direct RTC link ownership.
    ///
    /// # Errors
    /// Returns a diagnostic for invalid, missing or replaced manager identity.
    #[doc(hidden)]
    pub fn connect_with_wireplumber(
        remote_name: impl Into<String>,
        manager_id: u32,
        manager_serial: u64,
        marker_name: impl Into<String>,
    ) -> Result<Self, ScientificDiagnostic> {
        if manager_id == 0 || manager_id == u32::MAX || manager_serial == 0 {
            return Err(diagnostic(
                "manager requires a valid global ID and nonzero serial",
            ));
        }
        let marker_name = marker_name.into();
        if marker_name.is_empty() || marker_name.len() > 128 || marker_name.contains('\0') {
            return Err(diagnostic(
                "marker name must contain 1 to 128 bytes without NUL",
            ));
        }
        let mut adapter = Self::connect(remote_name)?;
        let manager = Identity {
            global_id: manager_id,
            serial: manager_serial,
        };
        exact_global(&adapter.globals.borrow(), manager, &ObjectType::Client)?;
        adapter.wireplumber = Some(Selection {
            manager,
            marker_name,
            next_generation: 1,
        });
        Ok(adapter)
    }

    fn project_endpoint(
        &self,
        name: &str,
        direction: PortDirection,
    ) -> Result<Endpoint, ScientificDiagnostic> {
        let (node_name, port_name) = split_endpoint(name)?;
        let node = self.node_global(node_name)?;
        let port = self.port_global(node.id, port_name, direction)?;
        let owner_id = property_id(&node, "client.id")?;
        let globals = self.globals.borrow();
        let owner = globals
            .get(&owner_id)
            .filter(|global| global.type_ == ObjectType::Client)
            .ok_or_else(|| diagnostic("endpoint creator Client is absent"))?;
        let endpoint = Endpoint {
            node: identity(&node)?,
            port: identity(&port)?,
            owner: identity(owner)?,
        };
        check_endpoint(
            &globals,
            endpoint,
            match direction {
                PortDirection::Input => "in",
                PortDirection::Output => "out",
            },
        )?;
        Ok(endpoint)
    }

    pub(super) fn realize_wireplumber_links(
        &mut self,
        config: &DevelopmentConfig,
        declared: &[(usize, &LinkSpec)],
    ) -> Result<(), ScientificDiagnostic> {
        if declared.is_empty() || declared.len() > MAX_LINKS {
            return Err(diagnostic("realization requires between 1 and 32 links"));
        }
        if self.wireplumber_session.is_some() {
            return Err(diagnostic("previous realization has not been withdrawn"));
        }
        let deadline = Instant::now() + CALLBACK_TIMEOUT;
        let _scope = self.scoped_deadline(deadline);
        self.prepare_wireplumber_intent(config, declared)?;
        self.wireplumber_session
            .as_mut()
            .expect("retained marker")
            .marker
            .realize()?;
        loop {
            self.roundtrip("WirePlumber declared link realization")?;
            self.check_wireplumber_identities()?;
            self.bind_wireplumber_links()?;
            if self.links.len() == declared.len()
                && self.links.iter().all(|link| {
                    matches!(
                        *link.state.borrow(),
                        LinkAdmissionState::Active | LinkAdmissionState::Paused
                    )
                })
            {
                self.check_wireplumber_cohort()?;
                return Ok(());
            }
            if let Some(link) = self
                .links
                .iter()
                .find(|link| matches!(*link.state.borrow(), LinkAdmissionState::Failed(_)))
            {
                return Err(diagnostic(format!(
                    "declared link {} failed: {:?}",
                    link.index,
                    link.state.borrow()
                )));
            }
            if !self.wait_for_callbacks(deadline, "WirePlumber declared link realization")? {
                return Err(diagnostic(
                    "declared links did not become usable before the admission deadline",
                ));
            }
        }
    }

    fn prepare_wireplumber_intent(
        &mut self,
        config: &DevelopmentConfig,
        declared: &[(usize, &LinkSpec)],
    ) -> Result<(), ScientificDiagnostic> {
        let selection = self
            .wireplumber
            .as_mut()
            .expect("selected WirePlumber manager");
        let manager = selection.manager;
        let generation = selection.next_generation;
        selection.next_generation = generation
            .checked_add(1)
            .ok_or_else(|| diagnostic("realization generation exhausted"))?;
        let marker_name = selection.marker_name.clone();
        exact_global(&self.globals.borrow(), manager, &ObjectType::Client)?;
        let links = declared
            .iter()
            .map(|(index, link)| {
                Ok(Link {
                    index: *index,
                    output: self.project_endpoint(&link.output, PortDirection::Output)?,
                    input: self.project_endpoint(&link.input, PortDirection::Input)?,
                    passive: link.passive,
                })
            })
            .collect::<Result<Vec<_>, ScientificDiagnostic>>()?;
        let formats = capture_link_formats(config, declared)?;
        let (marker_identity, runtime) = self.bind_realization_marker(&marker_name, formats)?;
        let intent = Intent {
            generation,
            runtime,
            manager,
            links,
        };
        let mut identities = BTreeMap::from([
            (runtime.global_id, (runtime, ObjectType::Client)),
            (manager.global_id, (manager, ObjectType::Client)),
        ]);
        for link in &intent.links {
            for endpoint in [link.output, link.input] {
                for (identity, kind) in [
                    (endpoint.node, ObjectType::Node),
                    (endpoint.port, ObjectType::Port),
                    (endpoint.owner, ObjectType::Client),
                ] {
                    if let Some((previous, previous_kind)) =
                        identities.insert(identity.global_id, (identity, kind.clone()))
                    {
                        if previous != identity || previous_kind != kind {
                            return Err(diagnostic("inconsistent endpoint incarnation"));
                        }
                    }
                }
            }
        }
        let required = identities
            .into_values()
            .map(|(identity, kind)| {
                (
                    identity,
                    kind,
                    self.watch_required_global(identity.global_id),
                )
            })
            .collect();
        let removed = self.watch_required_global(marker_identity.global_id);
        let session = self.wireplumber_session.as_mut().expect("retained marker");
        session.identity = Some(marker_identity);
        session.removed = removed;
        session.required = required;
        session.intent = Some(intent.clone());
        session.marker.prepare(intent)?;
        self.roundtrip("Prepared realization publication")?;
        self.check_wireplumber_identities()?;
        Ok(())
    }

    fn bind_realization_marker(
        &mut self,
        marker_name: &str,
        formats: LinkFormats,
    ) -> Result<(Identity, Identity), ScientificDiagnostic> {
        let marker = Marker::new(self.core.clone(), marker_name)?;
        self.wireplumber_session = Some(Session {
            marker,
            identity: None,
            removed: Rc::new(Cell::new(false)),
            intent: None,
            required: Vec::new(),
            link_identities: BTreeMap::new(),
            formats,
            withdrawal_ack_eligible: false,
        });
        let deadline = Instant::now() + CALLBACK_TIMEOUT;
        let _scope = self.scoped_deadline(deadline);
        loop {
            self.roundtrip("realization marker binding")?;
            let session = self.wireplumber_session.as_ref().expect("retained marker");
            if let Some(error) = session.marker.state_error() {
                return Err(error);
            }
            let globals = self.globals.borrow();
            if let Some(global) = globals
                .get(&session.marker.node_id())
                .filter(|global| is_node_named(global, marker_name))
            {
                let marker_identity = identity(global)?;
                let runtime_id = property_id(global, "client.id")?;
                let runtime = globals
                    .get(&runtime_id)
                    .filter(|global| global.type_ == ObjectType::Client)
                    .ok_or_else(|| diagnostic("marker creator Client is missing"))?;
                return Ok((marker_identity, identity(runtime)?));
            }
            drop(globals);
            if !self.wait_for_callbacks(deadline, "realization marker binding")? {
                return Err(diagnostic(
                    "marker did not bind before the admission deadline",
                ));
            }
        }
    }

    fn check_wireplumber_identities(&self) -> Result<(), ScientificDiagnostic> {
        let Some(session) = &self.wireplumber_session else {
            return Ok(());
        };
        if let Some(error) = session.marker.state_error() {
            return Err(error);
        }
        let globals = self.globals.borrow();
        let marker_identity = session
            .identity
            .ok_or_else(|| diagnostic("marker has no bound identity"))?;
        let marker = exact_global(&globals, marker_identity, &ObjectType::Node)?;
        if session.removed.get() {
            return Err(diagnostic("realization marker was removed"));
        }
        let intent = session
            .intent
            .as_ref()
            .ok_or_else(|| diagnostic("realization intent is absent"))?;
        if property_id(marker, "client.id")? != intent.runtime.global_id {
            return Err(diagnostic("marker creator changed"));
        }
        for (identity, kind, removed) in &session.required {
            if removed.get() {
                return Err(diagnostic("required realization identity was removed"));
            }
            exact_global(&globals, *identity, kind)?;
        }
        for link in &intent.links {
            check_endpoint(&globals, link.output, "out")?;
            check_endpoint(&globals, link.input, "in")?;
        }
        Ok(())
    }

    fn bind_wireplumber_links(&mut self) -> Result<(), ScientificDiagnostic> {
        let session = self.wireplumber_session.as_ref().expect("retained marker");
        let path_prefix = prefix(session.identity.expect("bound marker"));
        let intent = session.intent.as_ref().expect("prepared intent");
        let globals = self.globals.borrow();
        let mut bindings = Vec::new();
        for row in &intent.links {
            let path = format!("{path_prefix}{}", row.index);
            let matching = globals
                .values()
                .filter(|global| {
                    global.type_ == ObjectType::Link
                        && global
                            .props
                            .as_ref()
                            .and_then(|props| props.get("object.path"))
                            == Some(path.as_str())
                })
                .collect::<Vec<_>>();
            if matching.len() > 1 {
                return Err(diagnostic("duplicate correlated link path"));
            }
            if self.links.iter().any(|link| link.index == row.index) {
                continue;
            }
            if let [global] = matching.as_slice() {
                if property_id(global, "client.id")? != intent.manager.global_id {
                    return Err(diagnostic(
                        "correlated link was created by a different Client",
                    ));
                }
                let link_identity = identity(global)?;
                let proxy = self
                    .registry
                    .bind::<pw::link::Link, _>(global)
                    .map_err(|error| diagnostic(error.to_string()))?;
                bindings.push((row.index, link_identity, proxy));
            }
        }
        drop(globals);
        for (index, identity, proxy) in bindings {
            let observed_passive = Rc::new(RefCell::new(None));
            self.links.push(LiveLink::observe(
                index,
                proxy,
                &self.required_global_removals,
                &observed_passive,
            ));
            self.wireplumber_session
                .as_mut()
                .expect("retained marker")
                .link_identities
                .insert(index, identity);
        }
        Ok(())
    }

    pub(super) fn check_wireplumber_cohort(&self) -> Result<(), ScientificDiagnostic> {
        let Some(session) = &self.wireplumber_session else {
            return Ok(());
        };
        self.roundtrip("required WirePlumber realization monitor")?;
        self.check_wireplumber_identities()?;
        let intent = session.intent.as_ref().expect("prepared intent");
        let path_prefix = prefix(session.identity.expect("bound marker"));
        let globals = self.globals.borrow();
        let correlated = globals
            .values()
            .filter(|global| {
                global.type_ == ObjectType::Link
                    && global
                        .props
                        .as_ref()
                        .and_then(|props| props.get("object.path"))
                        .is_some_and(|path| path.starts_with(&path_prefix))
            })
            .count();
        if correlated != intent.links.len() || self.links.len() != intent.links.len() {
            return Err(diagnostic(
                "actual correlated link cohort differs from the declared intent",
            ));
        }
        for row in &intent.links {
            let link = self
                .links
                .iter()
                .find(|link| link.index == row.index)
                .ok_or_else(|| diagnostic("declared link observer is missing"))?;
            let expected = session
                .link_identities
                .get(&row.index)
                .ok_or_else(|| diagnostic("declared link identity is missing"))?;
            let global = exact_global(&globals, *expected, &ObjectType::Link)?;
            let path = format!("{path_prefix}{}", row.index);
            if link.removed.get()
                || link.global_id.get() != Some(expected.global_id)
                || property_id(global, "client.id")? != intent.manager.global_id
                || global
                    .props
                    .as_ref()
                    .and_then(|props| props.get("object.path"))
                    != Some(path.as_str())
                || global
                    .props
                    .as_ref()
                    .and_then(|props| props.get("object.linger"))
                    == Some("true")
            {
                return Err(diagnostic(
                    "declared link identity, path, owner or lifetime differs",
                ));
            }
            if !matches!(
                *link.state.borrow(),
                LinkAdmissionState::Active | LinkAdmissionState::Paused
            ) {
                return Err(diagnostic("declared link is not usable"));
            }
            let contract = link.contract.borrow();
            let contract = contract
                .as_ref()
                .ok_or_else(|| diagnostic("declared LinkInfo is absent"))?;
            let expected_format = session
                .formats
                .get(&row.index)
                .expect("declared output Format");
            validate_link_contract(contract, row, expected_format)?;
        }
        Ok(())
    }

    pub(super) fn withdraw_wireplumber(&mut self) -> Result<(), ScientificDiagnostic> {
        let Some(session) = &self.wireplumber_session else {
            return Ok(());
        };
        if !session.marker.attempted_realize() {
            // Prepared never authorized links, so local destruction is enough.
            self.wireplumber_session.take();
            return self.roundtrip("Prepared marker local cleanup");
        }
        let marker_identity = session.identity.expect("Realize requires a bound marker");
        let manager = session
            .intent
            .as_ref()
            .expect("Realize requires an intent")
            .manager;
        let path_prefix = prefix(marker_identity);
        let deadline = Instant::now() + CALLBACK_TIMEOUT;
        let _scope = self.scoped_deadline(deadline);
        self.roundtrip("realization presence before Withdraw")?;
        let marker_was_alive = {
            let session = self.wireplumber_session.as_ref().expect("retained marker");
            !session.removed.get()
                && exact_global(&self.globals.borrow(), marker_identity, &ObjectType::Node).is_ok()
        };
        let session = self.wireplumber_session.as_mut().expect("retained marker");
        let submission_error = session.marker.withdraw().err();
        if marker_was_alive && submission_error.is_none() {
            // Retain eligibility across a bounded wait that ends before the
            // acknowledgment arrives. Prior unexplained removal is never ACK.
            // Subsequent removal is ACK under the designated manager's destroy
            // contract; the registry event does not identify an arbitrary remover.
            session.withdrawal_ack_eligible = true;
        }
        loop {
            self.roundtrip("WirePlumber realization withdrawal")?;
            let globals = self.globals.borrow();
            let manager_gone = exact_global(&globals, manager, &ObjectType::Client).is_err();
            let session = self
                .wireplumber_session
                .as_ref()
                .expect("retained withdrawal marker");
            let marker_removed = session.removed.get()
                && !globals
                    .get(&marker_identity.global_id)
                    .is_some_and(|global| identity(global).ok() == Some(marker_identity));
            let correlated = globals.values().any(|global| {
                global.type_ == ObjectType::Link
                    && global
                        .props
                        .as_ref()
                        .and_then(|props| props.get("object.path"))
                        .is_some_and(|path| path.starts_with(&path_prefix))
            });
            if withdrawal_fenced(
                session.withdrawal_ack_eligible,
                marker_removed,
                manager_gone,
                correlated,
            ) {
                drop(globals);
                self.wireplumber_session.take();
                return Ok(());
            }
            drop(globals);
            if !self.wait_for_callbacks(deadline, "WirePlumber realization withdrawal")? {
                return Err(submission_error.unwrap_or_else(|| diagnostic("withdrawal is unknown: exact marker removal and zero correlated links were not confirmed")));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct ObservedProps {
        _listener: pw::node::NodeListener,
        readable: Rc<Cell<bool>>,
        writable: Rc<Cell<bool>>,
        values: Rc<RefCell<Vec<pw::spa::pod::Value>>>,
    }

    impl ObservedProps {
        fn new(node: &pw::node::Node) -> Self {
            use pw::spa::param::{ParamInfoFlags, ParamType};
            use pw::spa::pod::deserialize::PodDeserializer;
            let readable = Rc::new(Cell::new(false));
            let readable_props = Rc::clone(&readable);
            let writable = Rc::new(Cell::new(false));
            let writable_props = Rc::clone(&writable);
            let values = Rc::new(RefCell::new(Vec::new()));
            let observed_props = Rc::clone(&values);
            let listener = node
                .add_listener_local()
                .info(move |info| {
                    let params = info
                        .params()
                        .iter()
                        .map(|param| (param.id(), param.flags()))
                        .collect::<Vec<_>>();
                    eprintln!("BOOTSTRAP_NODE_PARAMS {params:?}");
                    readable_props.set(params.iter().any(|(id, flags)| {
                        *id == ParamType::Props && flags.contains(ParamInfoFlags::READ)
                    }));
                    writable_props.set(params.iter().any(|(id, flags)| {
                        *id == ParamType::Props && flags.contains(ParamInfoFlags::WRITE)
                    }));
                })
                .param(move |_, id, _, _, pod| {
                    if id == ParamType::Props {
                        if let Some(pod) = pod {
                            observed_props.borrow_mut().push(
                                PodDeserializer::deserialize_any_from(pod.as_bytes())
                                    .unwrap()
                                    .1,
                            );
                        }
                    }
                })
                .register();
            Self {
                _listener: listener,
                readable,
                writable,
                values,
            }
        }
    }

    fn bootstrap_intent(runtime: Identity, manager: Identity) -> Intent {
        let count = std::env::var("PIPEWIREAO_REALIZATION_BOOTSTRAP_LINKS")
            .unwrap_or_else(|_| "1".into())
            .parse::<usize>()
            .unwrap();
        assert!((1..=4).contains(&count));
        let endpoint = |base| Endpoint {
            node: Identity {
                global_id: base,
                serial: 1,
            },
            port: Identity {
                global_id: base + 1,
                serial: 2,
            },
            owner: runtime,
        };
        Intent {
            generation: 1,
            runtime,
            manager,
            links: (0..count)
                .map(|index| {
                    let base = 0x7fff_ff00 + u32::try_from(index).unwrap() * 4;
                    Link {
                        index,
                        output: endpoint(base),
                        input: endpoint(base + 2),
                        passive: index % 2 != 0,
                    }
                })
                .collect(),
        }
    }

    fn bootstrap_expected(intent: &Intent) -> pw::spa::pod::Value {
        use pw::spa::pod::deserialize::PodDeserializer;
        let bytes =
            super::super::realization::encode(intent, super::super::realization::Phase::Prepared)
                .unwrap();
        eprintln!(
            "BOOTSTRAP_INTENT links={} encoded_bytes={}",
            intent.links.len(),
            bytes.len()
        );
        PodDeserializer::deserialize_any_from(&bytes).unwrap().1
    }

    fn marker_loss_connection() -> (LiveGraphAdapter, Identity, String, String) {
        let remote = std::env::var("PIPEWIREAO_REALIZATION_REMOTE").unwrap();
        let manager = Identity {
            global_id: std::env::var("PIPEWIREAO_REALIZATION_MANAGER_ID")
                .unwrap()
                .parse()
                .unwrap(),
            serial: std::env::var("PIPEWIREAO_REALIZATION_MANAGER_SERIAL")
                .unwrap()
                .parse()
                .unwrap(),
        };
        let name = std::env::var("PIPEWIREAO_REALIZATION_MARKER_NAME").unwrap();
        let log = std::env::var("PIPEWIREAO_REALIZATION_LOG").unwrap();
        let adapter = LiveGraphAdapter::connect_with_wireplumber(
            remote,
            manager.global_id,
            manager.serial,
            &name,
        )
        .unwrap();
        (adapter, manager, name, log)
    }

    fn prepare_marker_loss(
        adapter: &mut LiveGraphAdapter,
        manager: Identity,
        name: &str,
    ) -> Identity {
        let row = Link {
            index: 0,
            output: adapter
                .project_endpoint("realization.source:output_1", PortDirection::Output)
                .unwrap(),
            input: adapter
                .project_endpoint("realization.sink:input_1", PortDirection::Input)
                .unwrap(),
            passive: false,
        };
        let (marker, runtime) = adapter
            .bind_realization_marker(name, BTreeMap::new())
            .unwrap();
        let removed = adapter.watch_required_global(marker.global_id);
        let intent = Intent {
            generation: 1,
            runtime,
            manager,
            links: vec![row],
        };
        let session = adapter.wireplumber_session.as_mut().unwrap();
        session.identity = Some(marker);
        session.removed = removed;
        session.intent = Some(intent.clone());
        session.marker.prepare(intent).unwrap();
        adapter
            .roundtrip("marker loss Prepared publication")
            .unwrap();
        adapter
            .wireplumber_session
            .as_mut()
            .unwrap()
            .marker
            .realize()
            .unwrap();
        marker
    }

    fn correlated_globals(adapter: &LiveGraphAdapter, marker: Identity) -> Vec<Identity> {
        let path_prefix = prefix(marker);
        adapter
            .globals
            .borrow()
            .values()
            .filter(|global| {
                global.type_ == ObjectType::Link
                    && global
                        .props
                        .as_ref()
                        .and_then(|props| props.get("object.path"))
                        .is_some_and(|path| path.starts_with(&path_prefix))
            })
            .map(|global| identity(global).unwrap())
            .collect()
    }

    fn wait_marker_loss(adapter: &LiveGraphAdapter, field: &str, proof: impl Fn() -> bool) {
        let deadline = Instant::now() + CALLBACK_TIMEOUT;
        let _scope = adapter.scoped_deadline(deadline);
        loop {
            adapter.roundtrip(field).unwrap();
            if proof() {
                return;
            }
            assert!(
                adapter.wait_for_callbacks(deadline, field).unwrap(),
                "{field}"
            );
        }
    }

    fn assert_next_realization_fenced(adapter: &mut LiveGraphAdapter) {
        // The retained-session check precedes any configuration or Format work.
        let config = DevelopmentConfig {
            execution: crate::config::ExecutionMode::CompleteFrame,
            rate: "100/1".into(),
            sources: vec![],
            graphs: vec![],
            sinks: vec![],
            execution_groups: vec![],
            properties: BTreeMap::new(),
            parameters: BTreeMap::new(),
            observations: vec![],
            links: vec![],
        };
        let declaration = LinkSpec {
            output: "realization.source:output_1".into(),
            input: "realization.sink:input_1".into(),
            passive: false,
        };
        let error = adapter
            .realize_wireplumber_links(&config, &[(0, &declaration)])
            .unwrap_err();
        assert_eq!(
            error.message(),
            "previous realization has not been withdrawn"
        );
        eprintln!("RUST_MARKER_LOSS_NEXT_REALIZATION_FENCED");
    }

    fn observe_marker_loss_link(adapter: &mut LiveGraphAdapter, marker: Identity) {
        let link = correlated_globals(adapter, marker)[0];
        let manager = adapter
            .wireplumber_session
            .as_ref()
            .unwrap()
            .intent
            .as_ref()
            .unwrap()
            .manager;
        assert_eq!(
            property_id(&adapter.globals.borrow()[&link.global_id], "client.id").unwrap(),
            manager.global_id
        );
        adapter.bind_wireplumber_links().unwrap();
        adapter
            .roundtrip("pending marker loss LinkInfo discovery")
            .unwrap();
        assert_eq!(adapter.links.len(), 1);
        let contract = adapter.links[0].contract.borrow();
        let contract = contract.as_ref().unwrap();
        let row = adapter
            .wireplumber_session
            .as_ref()
            .unwrap()
            .intent
            .as_ref()
            .unwrap()
            .links[0];
        assert_eq!(
            [
                contract.output_node,
                contract.output_port,
                contract.input_node,
                contract.input_port
            ],
            [
                row.output.node.global_id,
                row.output.port.global_id,
                row.input.node.global_id,
                row.input.port.global_id
            ]
        );
        eprintln!(
            "RUST_MARKER_LOSS_PENDING_LINK_OBSERVED marker={}:{} link={}:{}",
            marker.global_id, marker.serial, link.global_id, link.serial
        );
    }

    #[test]
    #[ignore = "requires private actual Ports and a WirePlumber activation callback held for 500 ms"]
    fn unexpected_marker_loss_cannot_acknowledge_pending_withdrawal() {
        let (mut adapter, manager, name, log) = marker_loss_connection();
        let marker = prepare_marker_loss(&mut adapter, manager, &name);
        wait_marker_loss(&adapter, "held activation discovery", || {
            let links = correlated_globals(&adapter, marker);
            links.len() == 1
                && std::fs::read_to_string(&log).unwrap().lines().any(|line| {
                    line.trim_end().ends_with(&format!(
                        "PROBE_PENDING_ACTIVATION_HELD {}",
                        links[0].global_id
                    ))
                })
        });
        observe_marker_loss_link(&mut adapter, marker);
        let transcript = std::fs::read_to_string(&log).unwrap();
        assert!(!transcript.contains("PROBE_DELAYED_ACTIVATION_DELIVERED"));
        adapter
            .registry
            .destroy_global(marker.global_id)
            .into_result()
            .unwrap();
        wait_marker_loss(&adapter, "unexpected exact marker removal", || {
            adapter.wireplumber_session.as_ref().unwrap().removed.get()
                && exact_global(&adapter.globals.borrow(), marker, &ObjectType::Node).is_err()
        });
        assert!(!std::fs::read_to_string(&log)
            .unwrap()
            .contains("PROBE_DELAYED_ACTIVATION_DELIVERED"));
        let error = adapter.withdraw_wireplumber().unwrap_err();
        wait_marker_loss(
            &adapter,
            "pending callbacks drained after marker loss",
            || {
                correlated_globals(&adapter, marker).is_empty()
                    && std::fs::read_to_string(&log)
                        .unwrap()
                        .contains("PROBE_DELAYED_ACTIVATION_DELIVERED")
            },
        );
        exact_global(&adapter.globals.borrow(), manager, &ObjectType::Client).unwrap();
        let session = adapter.wireplumber_session.as_ref().unwrap();
        assert_eq!(session.identity, Some(marker));
        assert!(!session.withdrawal_ack_eligible);
        assert!(session.marker.attempted_realize());
        eprintln!(
            "RUST_MARKER_LOSS_UNKNOWN_RETAINED marker={}:{} correlated_links=0 error={error}",
            marker.global_id, marker.serial
        );
        assert_next_realization_fenced(&mut adapter);
        let can_destroy = adapter.globals.borrow()[&manager.global_id]
            .permissions
            .contains(pw::permissions::PermissionFlags::X);
        if !can_destroy {
            eprintln!("RUST_MARKER_LOSS_MANAGER_DESTROY_UNSUPPORTED");
            return;
        }
        adapter
            .registry
            .destroy_global(manager.global_id)
            .into_result()
            .unwrap();
        wait_marker_loss(&adapter, "exact manager revocation", || {
            exact_global(&adapter.globals.borrow(), manager, &ObjectType::Client).is_err()
        });
        adapter.withdraw_wireplumber().unwrap();
        assert!(adapter.wireplumber_session.is_none());
        assert!(correlated_globals(&adapter, marker).is_empty());
        eprintln!(
            "RUST_MARKER_LOSS_MANAGER_GONE_CLEANUP manager={}:{}",
            manager.global_id, manager.serial
        );
    }

    #[test]
    #[ignore = "requires an isolated core, selected WirePlumber profile and its fresh policy log"]
    fn empty_marker_then_prepared_props_are_public_and_policy_recognized() {
        use pw::spa::param::ParamType;

        let remote = std::env::var("PIPEWIREAO_REALIZATION_REMOTE").unwrap();
        let manager_id = std::env::var("PIPEWIREAO_REALIZATION_MANAGER_ID")
            .unwrap()
            .parse::<u32>()
            .unwrap();
        let manager_serial = std::env::var("PIPEWIREAO_REALIZATION_MANAGER_SERIAL")
            .unwrap()
            .parse::<u64>()
            .unwrap();
        let name = std::env::var("PIPEWIREAO_REALIZATION_MARKER_NAME").unwrap();
        let log = std::env::var("PIPEWIREAO_REALIZATION_LOG").unwrap();
        let mut adapter =
            LiveGraphAdapter::connect_with_wireplumber(remote, manager_id, manager_serial, &name)
                .unwrap();
        let (marker_identity, runtime) = adapter
            .bind_realization_marker(&name, BTreeMap::new())
            .unwrap();
        let global = adapter
            .globals
            .borrow()
            .get(&marker_identity.global_id)
            .unwrap()
            .to_owned();
        let node = adapter.registry.bind::<pw::node::Node, _>(&global).unwrap();
        let observed = ObservedProps::new(&node);
        adapter
            .roundtrip("empty marker NodeInfo discovery")
            .unwrap();
        assert!(observed.writable.get());
        assert!(!observed.readable.get());
        let intent = bootstrap_intent(
            runtime,
            Identity {
                global_id: manager_id,
                serial: manager_serial,
            },
        );
        let expected = bootstrap_expected(&intent);
        assert!(!observed.values.borrow().contains(&expected));
        adapter
            .wireplumber_session
            .as_mut()
            .unwrap()
            .marker
            .prepare(intent)
            .unwrap();
        let deadline = Instant::now() + CALLBACK_TIMEOUT;
        let _scope = adapter.scoped_deadline(deadline);
        let recognition = format!(
            "RTC_REALIZATION_PREPARED {}:{}",
            marker_identity.global_id, marker_identity.serial
        );
        let mut subscribed = false;
        loop {
            adapter
                .roundtrip("Prepared marker public Props discovery")
                .unwrap();
            if observed.readable.get() {
                if !subscribed {
                    node.subscribe_params(&[ParamType::Props]);
                    subscribed = true;
                }
                node.enum_params(1, Some(ParamType::Props), 0, 1);
                adapter
                    .roundtrip("Prepared marker Props enumeration")
                    .unwrap();
            }
            let public_props = observed.values.borrow().contains(&expected);
            let policy_recognized = std::fs::read_to_string(&log)
                .unwrap()
                .lines()
                .any(|line| line.trim_end().ends_with(&recognition));
            if observed.readable.get() && public_props && policy_recognized {
                break;
            }
            assert!(adapter.wait_for_callbacks(deadline, "Prepared marker policy recognition").unwrap(),
                "empty-to-Prepared failed: Props readable={} exact public snapshot={public_props} policy recognized={policy_recognized}", observed.readable.get());
        }
        assert!(
            adapter
                .globals
                .borrow()
                .values()
                .all(|global| global.type_ != ObjectType::Link),
            "Prepared authorized links"
        );
        eprintln!(
            "BOOTSTRAP_PREPARED_PROPS_VERIFIED marker={}:{}",
            marker_identity.global_id, marker_identity.serial
        );
        adapter.withdraw_wireplumber().unwrap();
    }

    #[test]
    fn withdrawal_requires_an_eligible_acknowledgment_or_manager_revocation() {
        // An already removed marker, or an unknown Withdraw submission, cannot
        // acknowledge pending activation drain while its manager is alive.
        assert!(!withdrawal_fenced(false, true, false, false));
        // A successful Withdraw from the exact live marker can be acknowledged
        // by its subsequent removal, with no correlated links still present.
        assert!(withdrawal_fenced(true, true, false, false));
        assert!(!withdrawal_fenced(true, false, false, false));
        // Exact manager disappearance revokes the non-lingering cohort, but a
        // correlated link still visible keeps either completion path fenced.
        assert!(withdrawal_fenced(false, false, true, false));
        assert!(!withdrawal_fenced(false, true, true, true));
        assert!(!withdrawal_fenced(true, true, false, true));
    }

    #[test]
    #[ignore = "requires an isolated core, selected WirePlumber profile and complete-frame RTC fixture"]
    fn same_process_unload_fences_before_next_realization() {
        use crate::{ConfigurationInput, LifecycleEvent, LifecycleState, Runner};
        use std::path::PathBuf;

        let remote = std::env::var("PIPEWIREAO_REALIZATION_REMOTE").unwrap();
        let manager_id = std::env::var("PIPEWIREAO_REALIZATION_MANAGER_ID")
            .unwrap()
            .parse::<u32>()
            .unwrap();
        let manager_serial = std::env::var("PIPEWIREAO_REALIZATION_MANAGER_SERIAL")
            .unwrap()
            .parse::<u64>()
            .unwrap();
        let config = PathBuf::from(std::env::var_os("PIPEWIREAO_REALIZATION_CONFIG").unwrap());
        let marker_name = std::env::var("PIPEWIREAO_REALIZATION_MARKER_NAME")
            .unwrap_or_else(|_| "pipewireao.rtc.realization-test".into());
        let adapter = LiveGraphAdapter::connect_with_wireplumber(
            remote,
            manager_id,
            manager_serial,
            marker_name,
        )
        .unwrap();
        let mut runner = Runner::new(adapter);
        let mut previous = None;
        for _ in 0..2 {
            assert_eq!(
                runner
                    .dispatch(LifecycleEvent::Load(ConfigurationInput::File(
                        config.clone()
                    )))
                    .unwrap(),
                LifecycleState::Ready,
                "load failed: {:?}",
                runner.diagnostic(),
            );
            let adapter = runner.executor();
            adapter.check_wireplumber_cohort().unwrap();
            assert_eq!(adapter.status().owned_links, 0);
            let session = adapter.wireplumber_session.as_ref().unwrap();
            let marker_identity = session.identity.unwrap();
            let intent = session.intent.as_ref().unwrap();
            let generation = intent.generation;
            let runtime = intent.runtime;
            if let Some((old_marker, old_generation, old_runtime)) = previous {
                assert_ne!(marker_identity, old_marker);
                assert!(generation > old_generation);
                assert_eq!(runtime, old_runtime);
            }
            eprintln!(
                "REALIZATION_ADMITTED generation={generation} marker={}:{} runtime={}:{} links={}",
                marker_identity.global_id,
                marker_identity.serial,
                runtime.global_id,
                runtime.serial,
                adapter.links.len()
            );
            assert_eq!(
                runner.dispatch(LifecycleEvent::Unload).unwrap(),
                LifecycleState::Offline,
                "unload failed: {:?}",
                runner.diagnostic()
            );
            let adapter = runner.executor();
            assert!(adapter.wireplumber_session.is_none());
            assert!(adapter.links.is_empty());
            let globals = adapter.globals.borrow();
            assert!(!globals
                .get(&marker_identity.global_id)
                .is_some_and(|global| identity(global).ok() == Some(marker_identity)));
            let path_prefix = prefix(marker_identity);
            assert!(!globals
                .values()
                .any(|global| global.type_ == ObjectType::Link
                    && global
                        .props
                        .as_ref()
                        .and_then(|props| props.get("object.path"))
                        .is_some_and(|path| path.starts_with(&path_prefix))));
            eprintln!(
                "REALIZATION_WITHDRAWN generation={generation} marker={}:{} correlated_links=0",
                marker_identity.global_id, marker_identity.serial
            );
            previous = Some((marker_identity, generation, runtime));
        }
    }

    fn global(id: u32, kind: ObjectType, values: &[(&str, &str)]) -> GlobalObject<PropertiesBox> {
        GlobalObject {
            id,
            permissions: pw::permissions::PermissionFlags::empty(),
            type_: kind,
            version: 1,
            props: Some(values.iter().copied().collect()),
        }
    }

    fn endpoints() -> (BTreeMap<u32, GlobalObject<PropertiesBox>>, Endpoint) {
        let globals = BTreeMap::from([
            (
                10,
                global(
                    10,
                    ObjectType::Node,
                    &[("object.serial", "100"), ("client.id", "30")],
                ),
            ),
            (
                20,
                global(
                    20,
                    ObjectType::Port,
                    &[
                        ("object.serial", "200"),
                        ("node.id", "10"),
                        ("port.direction", "out"),
                    ],
                ),
            ),
            (
                30,
                global(30, ObjectType::Client, &[("object.serial", "300")]),
            ),
        ]);
        let endpoint = Endpoint {
            node: Identity {
                global_id: 10,
                serial: 100,
            },
            port: Identity {
                global_id: 20,
                serial: 200,
            },
            owner: Identity {
                global_id: 30,
                serial: 300,
            },
        };
        (globals, endpoint)
    }

    #[test]
    fn exact_manager_requires_client_type_and_full_serial() {
        let serial = u64::MAX;
        let mut globals = BTreeMap::from([(
            30,
            global(
                30,
                ObjectType::Client,
                &[("object.serial", "18446744073709551615")],
            ),
        )]);
        let expected = Identity {
            global_id: 30,
            serial,
        };
        assert!(exact_global(&globals, expected, &ObjectType::Client).is_ok());
        globals.get_mut(&30).unwrap().type_ = ObjectType::Node;
        assert!(exact_global(&globals, expected, &ObjectType::Client).is_err());
        globals.get_mut(&30).unwrap().type_ = ObjectType::Client;
        globals
            .get_mut(&30)
            .unwrap()
            .props
            .as_mut()
            .unwrap()
            .insert("object.serial", "1");
        assert!(exact_global(&globals, expected, &ObjectType::Client).is_err());
        globals.clear();
        assert!(exact_global(&globals, expected, &ObjectType::Client).is_err());
    }

    #[test]
    fn endpoint_checks_node_port_and_creator_incarnations() {
        let (globals, endpoint) = endpoints();
        assert!(check_endpoint(&globals, endpoint, "out").is_ok());
        assert!(check_endpoint(&globals, endpoint, "in").is_err());
        for id in [10, 20, 30] {
            let mut replaced = globals
                .iter()
                .map(|(id, global)| (*id, global.to_owned()))
                .collect::<BTreeMap<_, _>>();
            replaced
                .get_mut(&id)
                .unwrap()
                .props
                .as_mut()
                .unwrap()
                .insert("object.serial", "999");
            assert!(check_endpoint(&replaced, endpoint, "out").is_err());
            replaced.remove(&id);
            assert!(check_endpoint(&replaced, endpoint, "out").is_err());
        }
        for (id, property, changed) in [
            (10, "client.id", "31"),
            (20, "node.id", "11"),
            (20, "port.direction", "in"),
        ] {
            let mut changed_globals = globals
                .iter()
                .map(|(id, global)| (*id, global.to_owned()))
                .collect::<BTreeMap<_, _>>();
            changed_globals
                .get_mut(&id)
                .unwrap()
                .props
                .as_mut()
                .unwrap()
                .insert(property, changed);
            assert!(check_endpoint(&changed_globals, endpoint, "out").is_err());
        }
    }

    #[test]
    fn invalid_selection_is_rejected_before_connecting() {
        for (id, serial) in [(0, 1), (u32::MAX, 1), (1, 0)] {
            assert!(
                LiveGraphAdapter::connect_with_wireplumber("unused", id, serial, "marker").is_err()
            );
        }
        for name in ["", "marker\0suffix"] {
            assert!(LiveGraphAdapter::connect_with_wireplumber("unused", 1, 1, name).is_err());
        }
        assert!(
            LiveGraphAdapter::connect_with_wireplumber("unused", 1, 1, "x".repeat(129)).is_err()
        );
    }
}
