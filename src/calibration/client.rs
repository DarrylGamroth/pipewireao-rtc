//! Native cold transport for the existing calibration coordinator.
//! Connection hints require fresh `NodeInfo`, capability and controller proof.
use crate::calibration::protocol::{
    self as codec, Action, ColdLifecycle, Command, FailureReason, ResultValue, Rule,
};
use crate::calibration::{
    CalibrationAction, CalibrationCompletion, CalibrationEffect, CalibrationEndpoint,
    CalibrationEvidence, CalibrationFailure, CalibrationRequest, ResponseBatch, SettlingRule,
};
use crate::control::envelope::{
    self as envelope, ControllerIdentity, ReplyBound, ReplyHeader, ReplyKind, RequestHeader,
};
use pipewire as pw;
use pw::properties::properties;
use pw::proxy::ProxyT;
use std::cell::RefCell;
use std::collections::BTreeMap;
use std::fs;
use std::os::unix::fs::{FileTypeExt, MetadataExt};
use std::path::Path;
use std::rc::Rc;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

#[cfg(test)]
#[path = "tests/client.rs"]
mod tests;

const PROTOCOL: &str = "pipewireao.rtc-control/1";
const CONTROLLER_PROFILE: &str = "pipewireao.rtc.controller/1";
const CAP_PREFIX: &str = "pipewireao.rtc.calibration-actions.";
static NEXT_INSTANCE: AtomicI64 = AtomicI64::new(1);

/// Exact intended owner; names or saved reports alone are not authority.
#[derive(Clone, Debug)]
pub struct Binding {
    pub remote: String,
    pub node: String,
    pub owner_pid: u32,
    pub instance: i64,
}
impl Binding {
    /// # Errors
    /// Rejects invalid bounded names, PID, incarnation or relative remotes.
    pub fn new(
        remote: String,
        node: String,
        owner_pid: u32,
        instance: i64,
    ) -> Result<Self, String> {
        if !Path::new(&remote).is_absolute()
            || node.is_empty()
            || node.len() > 128
            || node.contains('\0')
            || owner_pid == 0
            || instance <= 0
        {
            return Err("invalid native calibration binding".into());
        }
        Ok(Self {
            remote,
            node,
            owner_pid,
            instance,
        })
    }
}
fn private_remote(remote: &str) -> Result<String, String> {
    let path = Path::new(remote);
    let name = path.file_name().ok_or("remote must name a socket")?;
    let parent = fs::canonicalize(path.parent().ok_or("remote parent missing")?)
        .map_err(|e| e.to_string())?;
    let uid = fs::read_to_string("/proc/self/status")
        .map_err(|e| e.to_string())?
        .lines()
        .find_map(|line| line.strip_prefix("Uid:"))
        .and_then(|values| values.split_whitespace().nth(1))
        .and_then(|value| value.parse::<u32>().ok())
        .ok_or("effective UID unavailable")?;
    let directory = fs::symlink_metadata(&parent).map_err(|e| e.to_string())?;
    let remote = parent.join(name);
    let socket = fs::symlink_metadata(&remote).map_err(|e| e.to_string())?;
    if !path.is_absolute()
        || !directory.is_dir()
        || directory.uid() != uid
        || directory.mode() & 0o077 != 0
        || !socket.file_type().is_socket()
        || socket.uid() != uid
    {
        return Err("native remote must be an owned socket in a private directory".into());
    }
    remote
        .to_str()
        .map(str::to_owned)
        .ok_or_else(|| "remote must be UTF-8".into())
}

#[derive(Clone, Copy)]
struct Span {
    body: usize,
    end: usize,
    next: usize,
    kind: u32,
}
fn u32_at(bytes: &[u8], offset: usize) -> Result<u32, String> {
    Ok(u32::from_ne_bytes(
        bytes
            .get(offset..offset.checked_add(4).ok_or("size overflow")?)
            .ok_or("truncated POD metadata")?
            .try_into()
            .map_err(|_| "metadata width")?,
    ))
}
fn span(bytes: &[u8], start: usize, limit: usize) -> Result<Span, String> {
    let body = start.checked_add(8).ok_or("size overflow")?;
    let end = body
        .checked_add(u32_at(bytes, start)? as usize)
        .ok_or("size overflow")?;
    let next = end.checked_add(7).ok_or("size overflow")? & !7;
    if body > limit || next > limit || limit > bytes.len() {
        return Err("invalid POD extent".into());
    }
    Ok(Span {
        body,
        end,
        next,
        kind: u32_at(bytes, start + 4)?,
    })
}
fn fields(bytes: &[u8], parent: Span, maximum: usize) -> Result<Vec<Span>, String> {
    if parent.kind != pw::spa::sys::SPA_TYPE_Struct {
        return Err("expected Struct".into());
    }
    let mut values = Vec::new();
    let mut offset = parent.body;
    while offset < parent.end {
        if values.len() == maximum {
            return Err("excess Struct arity".into());
        }
        let value = span(bytes, offset, parent.end)?;
        values.push(value);
        offset = value.next;
    }
    if offset != parent.end {
        return Err("invalid Struct extent".into());
    }
    Ok(values)
}
fn text(bytes: &[u8], value: Span) -> Result<&str, String> {
    if value.kind != pw::spa::sys::SPA_TYPE_String {
        return Err("expected String".into());
    }
    let body = &bytes[value.body..value.end];
    let (&0, body) = body.split_last().ok_or("empty String body")? else {
        return Err("unterminated String".into());
    };
    if body.contains(&0) {
        return Err("embedded NUL".into());
    }
    std::str::from_utf8(body).map_err(|e| e.to_string())
}
fn scalar(bytes: &[u8], value: Span, kind: u32, width: usize) -> Result<&[u8], String> {
    if value.kind != kind || value.end - value.body != width {
        return Err("wrong scalar width or type".into());
    }
    Ok(&bytes[value.body..value.end])
}
fn long(bytes: &[u8], value: Span) -> Result<i64, String> {
    Ok(i64::from_ne_bytes(
        scalar(bytes, value, pw::spa::sys::SPA_TYPE_Long, 8)?
            .try_into()
            .map_err(|_| "Long width")?,
    ))
}
fn id(bytes: &[u8], value: Span) -> Result<u32, String> {
    Ok(u32::from_ne_bytes(
        scalar(bytes, value, pw::spa::sys::SPA_TYPE_Id, 4)?
            .try_into()
            .map_err(|_| "Id width")?,
    ))
}
fn props(bytes: &[u8]) -> Result<Vec<Span>, String> {
    if bytes.len() > envelope::CALIBRATION_REPLY_BOUND {
        return Err("oversized owner Props".into());
    }
    let root = span(bytes, 0, bytes.len())?;
    if root.kind != pw::spa::sys::SPA_TYPE_Object
        || root.next != bytes.len()
        || root.end - root.body < 16
        || u32_at(bytes, root.body)? != pw::spa::sys::SPA_TYPE_OBJECT_Props
        || u32_at(bytes, root.body + 4)? != pw::spa::param::ParamType::Props.as_raw()
        || u32_at(bytes, root.body + 8)? != pw::spa::sys::SPA_PROP_params
        || u32_at(bytes, root.body + 12)? != 0
    {
        return Err("invalid owner Props object".into());
    }
    let value = span(bytes, root.body + 16, root.end)?;
    if value.next != root.end {
        return Err("excess Props properties".into());
    }
    fields(bytes, value, 12)
}
#[derive(Clone, Debug)]
struct Capability {
    lifecycle: ColdLifecycle,
    last_token: i64,
    controllers: Vec<ControllerIdentity>,
}
fn capability(bytes: &[u8], values: &[Span], binding: &Binding) -> Result<Capability, String> {
    if values.len() != 12 {
        return Err("capability arity".into());
    }
    let names = [
        "version",
        "instance",
        "owner-pid",
        "lifecycle",
        "last-token",
        "controllers",
    ];
    let mut ordered = [None; 6];
    for pair in values.chunks_exact(2) {
        let name = text(bytes, pair[0])?
            .strip_prefix(CAP_PREFIX)
            .ok_or("capability namespace")?;
        let index = names
            .iter()
            .position(|expected| *expected == name)
            .ok_or("unknown capability field")?;
        if ordered[index].replace(pair[1]).is_some() {
            return Err("duplicate capability field".into());
        }
    }
    let values = ordered.map(|value| value.expect("six unique known fields"));
    if scalar(bytes, values[0], pw::spa::sys::SPA_TYPE_Int, 4)? != 1_i32.to_ne_bytes()
        || long(bytes, values[1])? != binding.instance
        || id(bytes, values[2])? != binding.owner_pid
    {
        return Err("capability owner identity changed".into());
    }
    let lifecycle = match id(bytes, values[3])? {
        1 => ColdLifecycle::Preparing,
        2 => ColdLifecycle::Prepared,
        3 => ColdLifecycle::Connected,
        4 => ColdLifecycle::Fault,
        5 => ColdLifecycle::Stopped,
        _ => return Err("unknown lifecycle".into()),
    };
    let last_token = long(bytes, values[4])?;
    if last_token < 0 {
        return Err("negative accepted token".into());
    }
    let mut controllers = Vec::new();
    for row in fields(bytes, values[5], 32)? {
        let columns = fields(bytes, row, 3)?;
        if columns.len() != 3 {
            return Err("controller arity".into());
        }
        let controller = ControllerIdentity {
            global_id: id(bytes, columns[0])?,
            serial: envelope::serial_from_long(long(bytes, columns[1])?),
            instance: long(bytes, columns[2])?,
        };
        if controller.global_id == 0
            || controller.global_id == u32::MAX
            || controller.serial == 0
            || controller.instance <= 0
            || controllers
                .iter()
                .any(|p: &ControllerIdentity| p.global_id == controller.global_id)
        {
            return Err("invalid/duplicate controller".into());
        }
        controllers.push(controller);
    }
    Ok(Capability {
        lifecycle,
        last_token,
        controllers,
    })
}

#[derive(Clone, Copy)]
struct Candidate {
    id: u32,
    serial: u64,
    version: u32,
    permissions: pw::permissions::PermissionFlags,
}
#[derive(Clone)]
enum Terminal {
    Completion(codec::Completion),
    Rejection(codec::Rejection),
}
impl Terminal {
    fn header(&self) -> ReplyHeader {
        match self {
            Self::Completion(value) => value.header,
            Self::Rejection(value) => value.header,
        }
    }
}
struct Observed {
    value: Terminal,
    at: Instant,
    bytes: Vec<u8>,
}
// Independent transport proof/event facts; the SCI coordinator owns its phases.
#[allow(clippy::struct_excessive_bools)]
struct Observation {
    binding: Binding,
    marker_name: String,
    marker_instance: i64,
    candidates: BTreeMap<String, Candidate>,
    owner: Option<Candidate>,
    identity: Option<ControllerIdentity>,
    owner_ready: bool,
    marker_ready: bool,
    capability: Option<Capability>,
    completion_seen: bool,
    rejection_seen: bool,
    max_token: i64,
    pending: Option<RequestHeader>,
    matched: Option<Observed>,
    last_completion: Option<(i64, Vec<u8>)>,
    failure: Option<(String, Instant)>,
    fatal: bool,
}
impl Observation {
    fn fail(&mut self, message: impl Into<String>, retirement: bool) {
        self.fail_at(message, retirement, Instant::now());
    }
    fn fail_at(&mut self, message: impl Into<String>, retirement: bool, at: Instant) {
        self.fatal |= !retirement;
        if self.failure.is_none() {
            self.failure = Some((message.into(), at));
        }
    }
    fn healthy(&self) -> Result<(), String> {
        self.failure
            .as_ref()
            .map_or(Ok(()), |(message, _)| Err(message.clone()))
    }
    fn observe(&mut self, bytes: &[u8]) -> Result<(), String> {
        if self.fatal {
            return Ok(());
        }
        let values = props(bytes)?;
        let first = *values.first().ok_or("empty owner Props")?;
        let name = text(bytes, first)?;
        if name.starts_with(CAP_PREFIX) {
            let cap = capability(bytes, &values, &self.binding)?;
            if cap.last_token >= self.max_token {
                self.max_token = cap.last_token;
                self.capability = Some(cap);
            }
            return Ok(());
        }
        let value = if name == "pipewireao.rtc.control.completion.header" {
            let outer =
                envelope::decode_reply(bytes, ReplyKind::Completion, ReplyBound::Calibration)
                    .map_err(|e| e.to_string())?;
            if outer.header.endpoint_instance != self.binding.instance {
                return Err("completion instance changed".into());
            }
            self.completion_seen = true;
            if outer.header.token == 0 {
                if !outer.payload.is_empty() {
                    return Err("invalid completion sentinel".into());
                }
                return Ok(());
            }
            if let Some((token, prior)) = &self.last_completion {
                if *token == outer.header.token && prior != bytes {
                    return Err("conflicting terminal completion".into());
                }
            }
            if self
                .last_completion
                .as_ref()
                .map_or(true, |(token, _)| outer.header.token >= *token)
            {
                self.last_completion = Some((outer.header.token, bytes.to_vec()));
            }
            self.max_token = self.max_token.max(outer.header.token);
            Terminal::Completion(codec::decode_completion(bytes).map_err(|e| e.to_string())?)
        } else if name == "pipewireao.rtc.control.rejection.header" {
            let value = codec::decode_rejection(bytes).map_err(|e| e.to_string())?;
            if value.header.endpoint_instance != self.binding.instance {
                return Err("rejection instance changed".into());
            }
            self.rejection_seen = true;
            Terminal::Rejection(value)
        } else {
            return Err("unrecognized owner Props".into());
        };
        if self
            .pending
            .is_some_and(|request| same_request(value.header(), request))
        {
            if let Some(previous) = &self.matched {
                if previous.bytes != bytes {
                    return Err("conflicting matching terminal".into());
                }
            } else if self.failure.is_none() {
                self.matched = Some(Observed {
                    value,
                    at: Instant::now(),
                    bytes: bytes.to_vec(),
                });
            }
        }
        Ok(())
    }
}
fn same_request(reply: ReplyHeader, request: RequestHeader) -> bool {
    reply.endpoint_instance == request.endpoint_instance
        && reply.controller == request.controller
        && reply.token == request.token
        && reply.operation == request.operation
}
struct BoundNode {
    _info: pw::node::NodeListener,
    _proxy: pw::proxy::ProxyListener,
    node: pw::node::Node,
}
struct Resources {
    owner: Option<BoundNode>,
    marker_node: Option<BoundNode>,
    filter_error: Arc<Mutex<Option<(String, Instant)>>>,
    _filter_listener: pw::filter::FilterListenerRc<'static, ()>,
    _marker: pw::filter::FilterRc,
    _registry_listener: pw::registry::Listener,
    _core_listener: pw::core::Listener,
    registry: pw::registry::RegistryRc,
    _core: pw::core::CoreRc,
    loop_: pw::main_loop::MainLoopRc,
}
/// One actual controller, one pending request, no reconnect or unknown-outcome retry.
pub struct NativeCalibrationEndpoint {
    resources: Option<Resources>,
    observation: Rc<RefCell<Observation>>,
    pending: Option<CalibrationRequest>,
    last_token: i64,
    fault: Option<CalibrationFailure>,
}
fn node_info(
    observation: &mut Observation,
    info: &pw::node::NodeInfoRef,
    candidate: Candidate,
    marker: bool,
) -> Result<(), String> {
    if info.id() != candidate.id
        || info.n_input_ports() != 0
        || info.n_output_ports() != 0
        || matches!(info.state(), pw::node::NodeState::Error(_))
    {
        return Err("bound control node changed".into());
    }
    if !info.change_mask().contains(pw::node::NodeChangeMask::PROPS) {
        return Ok(());
    }
    let props = info.props().ok_or("full NodeInfo properties absent")?;
    let (name, pid, instance, profile) = if marker {
        (
            observation.marker_name.as_str(),
            std::process::id(),
            observation.marker_instance,
            CONTROLLER_PROFILE,
        )
    } else {
        (
            observation.binding.node.as_str(),
            observation.binding.owner_pid,
            observation.binding.instance,
            codec::PROFILE,
        )
    };
    if props.get("node.name") != Some(name)
        || props
            .get("object.serial")
            .and_then(|v| v.parse::<u64>().ok())
            != Some(candidate.serial)
        || props.get("pipewireao.rtc-control.protocol") != Some(PROTOCOL)
        || props.get("pipewireao.rtc-control.profile") != Some(profile)
        || props.get("pipewireao.rtc-control.owner-pid") != Some(pid.to_string().as_str())
        || props.get("pipewireao.rtc-control.instance") != Some(instance.to_string().as_str())
    {
        return Err("full NodeInfo owner/controller proof changed".into());
    }
    if marker {
        observation.marker_ready = true;
    } else {
        observation.owner_ready = true;
    }
    Ok(())
}
fn bind_node(
    registry: &pw::registry::RegistryRc,
    observation: &Rc<RefCell<Observation>>,
    candidate: Candidate,
    marker: bool,
) -> Result<BoundNode, String> {
    let global = pw::registry::GlobalObject::<&pw::spa::utils::dict::DictRef> {
        id: candidate.id,
        permissions: candidate.permissions,
        type_: pw::types::ObjectType::Node,
        version: candidate.version,
        props: None,
    };
    let node = registry
        .bind::<pw::node::Node, _>(&global)
        .map_err(|e| e.to_string())?;
    let state = Rc::clone(observation);
    let parameters = Rc::clone(observation);
    let info = node
        .add_listener_local()
        .info(move |info| {
            let mut state = state.borrow_mut();
            if let Err(error) = node_info(&mut state, info, candidate, marker) {
                state.fail(error, false);
            }
        })
        .param(move |_, kind, _, _, pod| {
            if !marker && kind == pw::spa::param::ParamType::Props {
                if let Some(pod) = pod {
                    let mut state = parameters.borrow_mut();
                    if let Err(error) = state.observe(pod.as_bytes()) {
                        state.fail(error, false);
                    }
                }
            }
        })
        .register();
    let removed = Rc::clone(observation);
    let failed = Rc::clone(observation);
    let proxy = node
        .upcast_ref()
        .add_listener_local()
        .removed(move || removed.borrow_mut().fail("bound node removed", true))
        .error(move |_, _, message| failed.borrow_mut().fail(message, true))
        .register();
    Ok(BoundNode {
        _info: info,
        _proxy: proxy,
        node,
    })
}
fn registry_listener(
    registry: &pw::registry::RegistryRc,
    observation: &Rc<RefCell<Observation>>,
) -> pw::registry::Listener {
    let added = Rc::clone(observation);
    let removed = Rc::clone(observation);
    registry
        .add_listener_local()
        .global(move |global| {
            if global.type_ != pw::types::ObjectType::Node {
                return;
            }
            let Some(props) = global.props else {
                return;
            };
            let Some(name) = props.get("node.name") else {
                return;
            };
            let mut state = added.borrow_mut();
            if name != state.binding.node && name != state.marker_name {
                return;
            }
            let Some(serial) = props
                .get("object.serial")
                .and_then(|v| v.parse::<u64>().ok())
                .filter(|v| *v > 0)
            else {
                state.fail("invalid registry object serial", false);
                return;
            };
            if global.id == 0
                || global.id == u32::MAX
                || state
                    .candidates
                    .get(name)
                    .is_some_and(|v| v.id != global.id || v.serial != serial)
            {
                state.fail("ambiguous/replaced control node", false);
                return;
            }
            state.candidates.insert(
                name.to_owned(),
                Candidate {
                    id: global.id,
                    serial,
                    version: global.version,
                    permissions: global.permissions,
                },
            );
        })
        .global_remove(move |id| {
            let mut state = removed.borrow_mut();
            state.candidates.retain(|_, value| value.id != id);
            if state.owner.is_some_and(|v| v.id == id)
                || state.identity.is_some_and(|v| v.global_id == id)
            {
                state.fail("owner/controller incarnation removed", true);
            }
        })
        .register()
}
impl Resources {
    fn connect(
        remote: &str,
        observation: &Rc<RefCell<Observation>>,
        marker_name: &str,
        marker_instance: i64,
        deadline: Instant,
    ) -> Result<Self, String> {
        let loop_ = pw::main_loop::MainLoopRc::new(None).map_err(|e| e.to_string())?;
        let context = pw::context::ContextRc::new(&loop_, None).map_err(|e| e.to_string())?;
        let core = context
            .connect_fd_rc(crate::connection::connect_socket(remote, deadline)?, None)
            .map_err(|e| e.to_string())?;
        let errors = Rc::clone(observation);
        let core_listener = core
            .add_listener_local()
            .error(move |_, _, _, message| errors.borrow_mut().fail(message, true))
            .register();
        let registry = core.get_registry_rc().map_err(|e| e.to_string())?;
        let registry_listener = registry_listener(&registry, observation);
        let marker=pw::filter::FilterRc::new(core.clone(),marker_name,properties! {
            "node.name"=>marker_name,"media.class"=>"Control",
            "pipewireao.rtc-control.protocol"=>PROTOCOL,"pipewireao.rtc-control.profile"=>CONTROLLER_PROFILE,
            "pipewireao.rtc-control.instance"=>marker_instance.to_string(),"pipewireao.rtc-control.owner-pid"=>std::process::id().to_string(),
        }).map_err(|e|e.to_string())?;
        let filter_error = Arc::new(Mutex::new(None));
        let errors = Arc::clone(&filter_error);
        let filter_listener = marker
            .add_local_listener::<()>()
            .state_changed(move |_, (), _, state| {
                if let pw::filter::FilterState::Error(message) = state {
                    let mut errors = errors.lock().expect("filter error channel poisoned");
                    if errors.is_none() {
                        *errors = Some((message, Instant::now()));
                    }
                }
            })
            .register()
            .map_err(|e| e.to_string())?;
        marker
            .connect(pw::filter::FilterFlags::INACTIVE, &mut [])
            .map_err(|e| e.to_string())?;
        Ok(Self {
            owner: None,
            marker_node: None,
            filter_error,
            _filter_listener: filter_listener,
            _marker: marker,
            _registry_listener: registry_listener,
            _core_listener: core_listener,
            registry,
            _core: core,
            loop_,
        })
    }
}

impl NativeCalibrationEndpoint {
    /// Prove one live owner and actual controller before submitting Hold.
    /// # Errors
    /// Returns setup/proof failure or expiration of the single absolute deadline.
    pub fn connect(binding: Binding, deadline: Instant) -> Result<Self, String> {
        Binding::new(
            binding.remote.clone(),
            binding.node.clone(),
            binding.owner_pid,
            binding.instance,
        )?;
        let remote = private_remote(&binding.remote)?;
        if Instant::now() >= deadline {
            return Err("connection deadline expired".into());
        }
        let marker_instance = NEXT_INSTANCE
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |v| v.checked_add(1))
            .map_err(|_| "controller incarnation exhausted")?;
        let marker_name = format!(
            "pipewireao.rtc.controller.rust.{}.{}",
            std::process::id(),
            marker_instance
        );
        let observation = Rc::new(RefCell::new(Observation {
            binding,
            marker_name: marker_name.clone(),
            marker_instance,
            candidates: BTreeMap::new(),
            owner: None,
            identity: None,
            owner_ready: false,
            marker_ready: false,
            capability: None,
            completion_seen: false,
            rejection_seen: false,
            max_token: 0,
            pending: None,
            matched: None,
            last_completion: None,
            failure: None,
            fatal: false,
        }));
        let mut client = Self {
            resources: Some(Resources::connect(
                &remote,
                &observation,
                &marker_name,
                marker_instance,
                deadline,
            )?),
            observation,
            pending: None,
            last_token: 0,
            fault: None,
        };
        client.prove(deadline)?;
        Ok(client)
    }
    fn prove(&mut self, deadline: Instant) -> Result<(), String> {
        let marker_instance = self.observation.borrow().marker_instance;
        self.poll_until(deadline, |s| s.candidates.contains_key(&s.marker_name))?;
        let marker_candidate = {
            let state = self.observation.borrow();
            state.candidates[&state.marker_name]
        };
        self.observation.borrow_mut().identity = Some(ControllerIdentity {
            global_id: marker_candidate.id,
            serial: marker_candidate.serial,
            instance: marker_instance,
        });
        let resources = self.resources.as_mut().expect("connected resources");
        resources.marker_node = Some(bind_node(
            &resources.registry,
            &self.observation,
            marker_candidate,
            true,
        )?);
        self.poll_until(deadline, |s| {
            s.marker_ready && s.candidates.contains_key(&s.binding.node)
        })?;
        let owner = {
            let state = self.observation.borrow();
            state.candidates[&state.binding.node]
        };
        self.observation.borrow_mut().owner = Some(owner);
        let resources = self.resources.as_mut().expect("connected resources");
        resources.owner = Some(bind_node(
            &resources.registry,
            &self.observation,
            owner,
            false,
        )?);
        self.poll_until(deadline, |s| s.owner_ready)?;
        let node = &self
            .resources
            .as_ref()
            .expect("connected resources")
            .owner
            .as_ref()
            .expect("bound owner")
            .node;
        node.subscribe_params(&[pw::spa::param::ParamType::Props]);
        node.enum_params(1, Some(pw::spa::param::ParamType::Props), 0, 8);
        self.poll_until(deadline, |s| {
            s.completion_seen
                && s.rejection_seen
                && s.capability.as_ref().is_some_and(|cap| {
                    cap.controllers
                        .contains(&s.identity.expect("proven controller"))
                })
        })?;
        self.poll_until(deadline, |s| {
            s.capability.as_ref().is_some_and(|cap| {
                cap.lifecycle != ColdLifecycle::Preparing
                    && cap.lifecycle != ColdLifecycle::Prepared
            })
        })?;
        if self
            .observation
            .borrow()
            .capability
            .as_ref()
            .expect("proven capability")
            .lifecycle
            != ColdLifecycle::Connected
        {
            return Err("native calibration owner is unavailable".into());
        }
        Ok(())
    }
    fn iterate(&self, deadline: Instant) -> Result<(), String> {
        let remaining = deadline
            .checked_duration_since(Instant::now())
            .ok_or("absolute deadline expired")?;
        let resources = self.resources.as_ref().ok_or("native connection retired")?;
        if resources.loop_.loop_().iterate(pw::loop_::Timeout::Finite(
            remaining.min(Duration::from_millis(10)),
        )) < 0
        {
            return Err("native loop iteration failed".into());
        }
        if let Some((message, at)) = resources
            .filter_error
            .lock()
            .expect("filter error channel poisoned")
            .take()
        {
            self.observation.borrow_mut().fail_at(message, true, at);
        }
        Ok(())
    }
    fn poll_until(
        &self,
        deadline: Instant,
        predicate: impl Fn(&Observation) -> bool,
    ) -> Result<(), String> {
        loop {
            if Instant::now() >= deadline {
                return Err("absolute deadline expired".into());
            }
            {
                let state = self.observation.borrow();
                state.healthy()?;
                if predicate(&state) {
                    return Ok(());
                }
            }
            self.iterate(deadline)?;
        }
    }
    fn retire(&mut self, failure: CalibrationFailure) {
        self.fault = Some(failure);
        self.pending = None;
        self.resources = None;
    }
    /// Last transport retirement reason, when one occurred.
    #[must_use]
    pub const fn fault_reason(&self) -> Option<CalibrationFailure> {
        self.fault
    }
}
fn wire_rule(rule: SettlingRule) -> Result<Rule, CalibrationFailure> {
    Ok(match rule {
        SettlingRule::Immediate => Rule::Immediate,
        SettlingRule::DiscardExposures(frames) => Rule::DiscardExposures(frames),
        SettlingRule::ModelTime(duration) => Rule::ModelTime(
            u64::try_from(duration.as_nanos()).map_err(|_| CalibrationFailure::InvalidEvidence)?,
        ),
    })
}
fn wire_action(action: &CalibrationAction) -> Result<Action, CalibrationFailure> {
    let invalid = |_| CalibrationFailure::InvalidEvidence;
    let probe = |value: usize| {
        if value > 16383 {
            return Err(CalibrationFailure::InvalidEvidence);
        }
        u32::try_from(value).map_err(invalid)
    };
    Ok(match action {
        CalibrationAction::Hold => Action::Hold,
        CalibrationAction::Release => Action::Release,
        CalibrationAction::Adopt { probe: p, figure } => {
            let probe = probe(*p)?;
            codec::preflight_figure_request(figure, None)
                .map_err(|_| CalibrationFailure::InvalidEvidence)?;
            Action::Adopt {
                probe,
                figure: figure.to_vec(),
            }
        }
        CalibrationAction::Restore { figure, rule } => {
            let rule = wire_rule(*rule)?;
            codec::preflight_figure_request(figure, Some(rule))
                .map_err(|_| CalibrationFailure::InvalidEvidence)?;
            Action::Restore {
                figure: figure.to_vec(),
                rule,
            }
        }
        CalibrationAction::Settle {
            probe: p,
            after,
            rule,
        } => Action::Settle {
            probe: probe(*p)?,
            after: *after,
            rule: wire_rule(*rule)?,
        },
        CalibrationAction::Collect {
            probe: p,
            after,
            measurements,
            frames,
        } => Action::Collect {
            probe: probe(*p)?,
            after: *after,
            measurements: u32::try_from(*measurements).map_err(invalid)?,
            frames: u32::try_from(*frames).map_err(invalid)?,
        },
    })
}
fn evidence(result: ResultValue) -> Result<CalibrationEvidence, CalibrationFailure> {
    Ok(match result {
        ResultValue::Held(cursor) => CalibrationEvidence::Held(cursor),
        ResultValue::Adopted {
            cursor,
            figure,
            clipped,
        } => CalibrationEvidence::Adopted {
            cursor,
            figure: figure.into(),
            clipped,
        },
        ResultValue::Settled(cursor) => CalibrationEvidence::Settled(cursor),
        ResultValue::Responses {
            values,
            exposures,
            valid,
        } => CalibrationEvidence::Responses(ResponseBatch {
            values,
            exposures,
            valid,
        }),
        ResultValue::Restored { figure, clipped } => CalibrationEvidence::Restored {
            figure: figure.into(),
            clipped,
        },
        ResultValue::Released => CalibrationEvidence::Released,
        ResultValue::Failed(reason) => {
            return Err(match reason {
                FailureReason::Cancelled => CalibrationFailure::Cancelled,
                FailureReason::Endpoint => CalibrationFailure::Endpoint,
                FailureReason::InvalidEvidence => CalibrationFailure::InvalidEvidence,
                FailureReason::ProbeClipped => CalibrationFailure::ProbeClipped,
            })
        }
        ResultValue::Captured { .. } => return Err(CalibrationFailure::InvalidEvidence),
    })
}
impl CalibrationEndpoint for NativeCalibrationEndpoint {
    fn submit(&mut self, effect: &CalibrationEffect) -> Result<(), CalibrationFailure> {
        if self.pending.is_some() || self.resources.is_none() {
            return Err(CalibrationFailure::Endpoint);
        }
        if Instant::now() >= effect.deadline {
            return Err(CalibrationFailure::Endpoint);
        }
        let action = wire_action(&effect.action)?;
        let mut state = self.observation.borrow_mut();
        if state.healthy().is_err() {
            drop(state);
            self.retire(CalibrationFailure::Endpoint);
            return Err(CalibrationFailure::Endpoint);
        }
        let token = self
            .last_token
            .max(state.max_token)
            .checked_add(1)
            .ok_or(CalibrationFailure::InvalidEvidence)?;
        let budget = effect
            .deadline
            .checked_duration_since(Instant::now())
            .ok_or(CalibrationFailure::Endpoint)?;
        let header = RequestHeader {
            version: envelope::VERSION,
            endpoint_instance: state.binding.instance,
            controller: state.identity.ok_or(CalibrationFailure::Endpoint)?,
            token,
            operation: action.operation(),
            budget_ns: i64::try_from(budget.as_nanos())
                .map_err(|_| CalibrationFailure::InvalidEvidence)?,
        };
        let command = Command {
            run: effect.request.run,
            serial: effect.request.serial,
            action,
        };
        let bytes = codec::encode_request(&header, &command)
            .map_err(|_| CalibrationFailure::InvalidEvidence)?;
        if Instant::now() >= effect.deadline {
            return Err(CalibrationFailure::Endpoint);
        }
        let pod =
            pw::spa::pod::Pod::from_bytes(&bytes).ok_or(CalibrationFailure::InvalidEvidence)?;
        state.pending = Some(header);
        state.matched = None;
        self.pending = Some(effect.request);
        self.last_token = token;
        self.resources
            .as_ref()
            .expect("connected resources")
            .owner
            .as_ref()
            .expect("bound owner")
            .node
            .set_param(pw::spa::param::ParamType::Props, 0, pod);
        Ok(())
    }
    fn receive(
        &mut self,
        deadline: Instant,
    ) -> Result<Option<CalibrationCompletion>, CalibrationFailure> {
        loop {
            let outcome = {
                let mut state = self.observation.borrow_mut();
                if !state.fatal
                    && state.matched.as_ref().is_some_and(|m| {
                        m.at <= deadline
                            && state.failure.as_ref().map_or(true, |(_, at)| m.at <= *at)
                    })
                {
                    Some(Ok(state.matched.take().expect("matching terminal").value))
                } else if state.failure.is_some() || state.fatal {
                    Some(Err(CalibrationFailure::Endpoint))
                } else {
                    None
                }
            };
            if let Some(outcome) = outcome {
                let terminal = match outcome {
                    Ok(value) => value,
                    Err(error) => {
                        self.retire(error);
                        return Err(error);
                    }
                };
                let request = self
                    .pending
                    .take()
                    .ok_or(CalibrationFailure::InvalidEvidence)?;
                self.observation.borrow_mut().pending = None;
                let Terminal::Completion(completion) = terminal else {
                    self.retire(CalibrationFailure::Endpoint);
                    return Err(CalibrationFailure::Endpoint);
                };
                if completion.run != request.run || completion.serial != request.serial {
                    self.retire(CalibrationFailure::InvalidEvidence);
                    return Err(CalibrationFailure::InvalidEvidence);
                }
                if completion.header.result != 0 || completion.result.is_none() {
                    self.retire(CalibrationFailure::Endpoint);
                    return Err(CalibrationFailure::Endpoint);
                }
                return Ok(Some(CalibrationCompletion {
                    request,
                    result: evidence(completion.result.expect("validated result")),
                }));
            }
            if Instant::now() >= deadline {
                self.retire(CalibrationFailure::Endpoint);
                return Ok(None);
            }
            if self.iterate(deadline).is_err() {
                self.retire(CalibrationFailure::Endpoint);
                return Err(CalibrationFailure::Endpoint);
            }
        }
    }
    fn fault(&mut self, failure: CalibrationFailure) {
        self.retire(failure);
    }
}
