//! Bounded native public supervisor client. One exact binding, no reconnect/retry.
//! Transport machinery is domain-specific pending reviewed common-client extraction.
use crate::control::Command;
use crate::native_control_codec::{
    self as envelope, ControllerIdentity, ReplyBound, ReplyHeader, ReplyKind, RequestHeader,
};
use crate::native_runner_codec::Operation;
use crate::native_supervisor_codec::{self as codec, Phase};
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

const PROTOCOL: &str = "pipewireao.rtc-control/1";
const CONTROLLER_PROFILE: &str = "pipewireao.rtc.controller/1";
const CAP_PREFIX: &str = "pipewireao.rtc.deployment-supervisor.";
const UUID_PROPERTY: &str = "pipewireao.rtc.deployment-supervisor.session-uuid";
static NEXT_INSTANCE: AtomicI64 = AtomicI64::new(1);

/// Exact intended owner; names or saved reports alone are not authority.
#[derive(Clone, Debug)]
pub struct Binding {
    pub remote: String,
    pub node: String,
    pub owner_pid: u32,
    pub instance: i64,
    pub expected_uuid: Option<String>,
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
            return Err("invalid native supervisor binding".into());
        }
        Ok(Self {
            remote,
            node,
            owner_pid,
            instance,
            expected_uuid: None,
        })
    }

    /// Require this immutable deployment identity from the live bound `NodeInfo`.
    /// # Errors
    /// Rejects noncanonical, zero or unbounded UUID hints.
    pub fn with_expected_uuid(mut self, uuid: String) -> Result<Self, String> {
        validate_uuid(&uuid)?;
        self.expected_uuid = Some(uuid);
        Ok(self)
    }
}
fn validate_uuid(value: &str) -> Result<(), String> {
    if value.len() != 36
        || value == "00000000-0000-0000-0000-000000000000"
        || !value.bytes().enumerate().all(|(i, c)| {
            if matches!(i, 8 | 13 | 18 | 23) {
                c == b'-'
            } else {
                c.is_ascii_digit() || (b'a'..=b'f').contains(&c)
            }
        })
    {
        return Err("supervisor UUID must be nonzero canonical bounded text".into());
    }
    Ok(())
}
fn effective_uid() -> Result<u32, String> {
    fs::read_to_string("/proc/self/status")
        .map_err(|e| e.to_string())?
        .lines()
        .find_map(|line| line.strip_prefix("Uid:"))
        .and_then(|values| values.split_whitespace().nth(1))
        .and_then(|value| value.parse::<u32>().ok())
        .ok_or_else(|| "effective UID unavailable".into())
}
fn private_remote(remote: &str) -> Result<String, String> {
    let path = Path::new(remote);
    let name = path.file_name().ok_or("remote must name a socket")?;
    let parent = fs::canonicalize(path.parent().ok_or("remote parent missing")?)
        .map_err(|e| e.to_string())?;
    let uid = effective_uid()?;
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
    if bytes.len() > envelope::LIFECYCLE_REPLY_BOUND {
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
    _lifecycle: Phase,
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
        1 => Phase::Preparing,
        2 => Phase::Admitted,
        3 => Phase::Failed,
        4 => Phase::Stopping,
        5 => Phase::Stopped,
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
        _lifecycle: lifecycle,
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
#[allow(clippy::large_enum_variant)] // The cold owned snapshot is bounded and avoids extra indirection.
pub enum Reply {
    Completion(codec::Completion),
    Rejection(codec::Rejection),
}
impl Reply {
    #[must_use]
    pub fn header(&self) -> ReplyHeader {
        match self {
            Self::Completion(value) => value.header,
            Self::Rejection(value) => value.header,
        }
    }

    /// Render the verified typed reply for operator display or saved reports.
    /// JSON is created locally and never forms the control request/reply wire.
    #[must_use]
    pub fn render(&self, request_id: Option<&str>) -> serde_json::Value {
        use serde_json::json;
        let header = self.header();
        let (phase, admitted, snapshot, result, error) = match self {
            Self::Completion(c) => (
                c.lifecycle,
                c.admitted,
                c.snapshot.as_ref(),
                c.result.as_ref(),
                c.error.as_ref(),
            ),
            Self::Rejection(r) => (r.lifecycle, r.admitted, None, None, Some(&r.error)),
        };
        let observed = snapshot.and_then(|s| s.runner.as_ref());
        let record = result.or_else(|| observed.map(|r| &r.status));
        let phase = format!("{phase:?}").to_ascii_lowercase();
        let mut value = json!({
            "version":1, "id":request_id.map_or_else(|| header.token.to_string(), str::to_owned),
            "session_id":observed.map(|r| &r.session_id),
            "state":record.map(|r| crate::control::state_name(r.lifecycle)),
            "result":record.map(|r| r.result.legacy_json()), "ok":header.result==0,
            "error":error.map(|e| json!({"field":e.field,"message":e.message})),
            "phase":if admitted {"running"} else {&phase}, "supervisor_phase":phase,
            "admitted":admitted,"native_token":header.token,"endpoint_instance":header.endpoint_instance,
            "processes":{},
        });
        if let Some(snapshot) = snapshot {
            value["processes"] = serde_json::Value::Object(
                snapshot
                    .processes
                    .iter()
                    .map(|p| (p.role.clone(), json!({"pid":p.pid})))
                    .collect(),
            );
            if let Some(runner) = &snapshot.runner {
                value["runner_endpoint"] = binding_json(&runner.binding);
            }
            if let Some(source) = &snapshot.source {
                value["source_endpoint"] = binding_json(&source.binding);
                value["source"] = source_json(source);
                if let Some(instrument) = value["source"].get("instrument").cloned() {
                    value["source_endpoint"]["instrument"] = instrument;
                }
            }
            if let Some(heart) = &snapshot.heart {
                value["heart_endpoint"] = binding_json(&heart.binding);
            }
            if header.operation == Operation::Quit as u32 {
                value["snapshot_order"] = json!("before_quit_effect");
            }
        }
        value
    }
}

fn binding_json(binding: &codec::Binding) -> serde_json::Value {
    serde_json::json!({"node":binding.name,"profile":binding.profile,"owner_pid":binding.pid,
        "global_id":binding.global_id,"serial":binding.serial,"instance":binding.instance})
}
fn cursor_json(cursor: Option<&codec::Cursor>) -> serde_json::Value {
    cursor.map_or(serde_json::Value::Null, |c| {
        serde_json::json!({
        "domain":c.domain,"generation":c.generation,"sequence":c.sequence,"model_ns":c.model_ns})
    })
}
fn source_json(source: &codec::SourceObservation) -> serde_json::Value {
    use serde_json::json;
    match &source.snapshot {
        codec::SourceSnapshot::Simulator(s) => {
            json!({"version":1,"id":source.token,"operation":"status",
            "ok":true,"error":null,"state":if s.running {"running"} else {"paused"},
            "generation":s.generation,"sequence":s.sequence,"completed":s.completed,
            "instance":source.binding.instance,"report-generation":s.report_generation,"report-sequence":s.report_sequence,
            "report-ready":s.generation==s.report_generation&&s.sequence==s.report_sequence})
        }
        codec::SourceSnapshot::Calibration {
            lifecycle,
            snapshot: s,
        }
        | codec::SourceSnapshot::Correction {
            lifecycle,
            snapshot: s,
        } => json!({
            "version":1,"id":source.token,"operation":"status","native_token":source.token,
            "endpoint_instance":source.binding.instance,"ok":true,"error":null,
            "state":if s.running {"running"} else {"paused"},"sequence":s.cursor.as_ref().map(|c| c.sequence),
            "completed":s.completed,"cursor":cursor_json(s.cursor.as_ref()),"report_cursor":cursor_json(s.report_cursor.as_ref()),
            "phase":s.phase,"held":s.held,"restored":s.restored,"window":s.window,
            "lifecycle":format!("{lifecycle:?}"),"instrument":format!("{:?}",s.instrument).to_ascii_lowercase(),
        }),
    }
}
struct Observed {
    value: Reply,
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
    uuid: Option<String>,
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
    fn terminal(&mut self, deadline: Instant) -> Option<Result<Reply, String>> {
        if !self.fatal
            && self.matched.as_ref().is_some_and(|m| {
                m.at <= deadline && self.failure.as_ref().map_or(true, |(_, at)| m.at <= *at)
            })
        {
            self.pending = None;
            Some(Ok(self.matched.take().expect("matching terminal").value))
        } else if self.failure.is_some() || self.fatal {
            Some(Err(self
                .failure
                .as_ref()
                .map_or("invalid native evidence", |(m, _)| m.as_str())
                .to_owned()))
        } else {
            None
        }
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
            let outer = envelope::decode_reply(bytes, ReplyKind::Completion, ReplyBound::Lifecycle)
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
            Reply::Completion(codec::decode_completion(bytes).map_err(|e| e.message)?)
        } else if name == "pipewireao.rtc.control.rejection.header" {
            let value = codec::decode_rejection(bytes).map_err(|e| e.message)?;
            if value.header.endpoint_instance != self.binding.instance {
                return Err("rejection instance changed".into());
            }
            self.rejection_seen = true;
            Reply::Rejection(value)
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
pub struct Client {
    resources: Option<Resources>,
    observation: Rc<RefCell<Observation>>,
    last_token: i64,
    retired: bool,
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
        let uuid = props.get(UUID_PROPERTY).ok_or("supervisor UUID absent")?;
        validate_uuid(uuid)?;
        if observation.uuid.as_ref().is_some_and(|prior| prior != uuid)
            || observation
                .binding
                .expected_uuid
                .as_ref()
                .is_some_and(|expected| expected != uuid)
        {
            return Err("bound supervisor UUID changed or differs from intended identity".into());
        }
        observation.uuid = Some(uuid.into());
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
            .connect_fd_rc(
                crate::native_connection::connect_socket(remote, deadline)?,
                None,
            )
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

impl Client {
    /// Prove one live public owner and actual controller, including Preparing.
    /// # Errors
    /// Returns setup/proof failure or expiration of the single absolute deadline.
    pub fn connect(binding: Binding, deadline: Instant) -> Result<Self, String> {
        Binding::new(
            binding.remote.clone(),
            binding.node.clone(),
            binding.owner_pid,
            binding.instance,
        )?;
        if let Some(uuid) = &binding.expected_uuid {
            validate_uuid(uuid)?;
        }
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
            uuid: None,
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
            last_token: 0,
            retired: false,
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
    fn retire(&mut self) {
        self.retired = true;
        self.observation.borrow_mut().pending = None;
        self.resources = None;
    }

    /// Current exact owner identity, obtained from bound `NodeInfo`.
    #[must_use]
    pub fn owner_binding(&self) -> Option<codec::Binding> {
        if self.retired || self.resources.is_none() {
            return None;
        }
        let state = self.observation.borrow();
        let owner = state.owner?;
        state.healthy().ok()?;
        state.owner_ready.then(|| codec::Binding {
            name: state.binding.node.clone(),
            profile: codec::PROFILE.into(),
            pid: state.binding.owner_pid,
            global_id: owner.id,
            serial: owner.serial,
            instance: state.binding.instance,
        })
    }

    /// Immutable live identity from this exact owner binding.
    #[must_use]
    pub fn live_uuid(&self) -> Option<String> {
        if self.retired || self.resources.is_none() {
            return None;
        }
        let state = self.observation.borrow();
        state.healthy().ok()?;
        state.uuid.clone()
    }

    /// Submit once and await the exact matching native terminal within one deadline.
    /// # Errors
    /// `BeforeSend` means no request was submitted. `UnknownOutcome` retires this
    /// client permanently; callers must not reconnect or retry that operation.
    /// # Panics
    /// Panics only if private connected-resource or matching-terminal invariants are violated.
    pub fn request(&mut self, command: &Command, deadline: Instant) -> Result<Reply, ClientError> {
        if self.retired || self.resources.is_none() {
            return Err(ClientError::UnknownOutcome("native client retired".into()));
        }
        // Drain already available events with the same finite deadline before
        // choosing the next token. A concurrent caller can still win admission;
        // a native rejection is returned without replaying this command.
        if let Err(message) = self.iterate(deadline) {
            self.retire();
            return Err(ClientError::BeforeSend(message));
        }
        let failure = self.observation.borrow().healthy().err();
        if let Some(message) = failure {
            self.retire();
            return Err(ClientError::BeforeSend(message));
        }
        let submitted = (|| {
            let mut state = self.observation.borrow_mut();
            state.healthy().map_err(ClientError::BeforeSend)?;
            if state.pending.is_some() {
                return Err(ClientError::BeforeSend("request already pending".into()));
            }
            let token = self
                .last_token
                .max(state.max_token)
                .checked_add(1)
                .ok_or_else(|| ClientError::BeforeSend("native token exhausted".into()))?;
            let budget = deadline
                .checked_duration_since(Instant::now())
                .ok_or_else(|| ClientError::BeforeSend("absolute deadline expired".into()))?;
            let header = RequestHeader {
                version: envelope::VERSION,
                endpoint_instance: state.binding.instance,
                controller: state
                    .identity
                    .ok_or_else(|| ClientError::BeforeSend("controller absent".into()))?,
                token,
                operation: operation(command)? as u32,
                budget_ns: i64::try_from(budget.as_nanos())
                    .map_err(|_| ClientError::BeforeSend("deadline exceeds wire budget".into()))?,
            };
            let bytes = codec::encode_request(&header, command)
                .map_err(|e| ClientError::BeforeSend(e.message))?;
            if Instant::now() >= deadline {
                return Err(ClientError::BeforeSend("absolute deadline expired".into()));
            }
            let pod = pw::spa::pod::Pod::from_bytes(&bytes)
                .ok_or_else(|| ClientError::BeforeSend("invalid encoded request".into()))?;
            state.pending = Some(header);
            state.matched = None;
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
        })();
        submitted?;
        loop {
            let outcome = self.observation.borrow_mut().terminal(deadline);
            if let Some(outcome) = outcome {
                return outcome.map_err(|message| {
                    self.retire();
                    ClientError::UnknownOutcome(message)
                });
            }
            if Instant::now() >= deadline {
                self.retire();
                return Err(ClientError::UnknownOutcome(
                    "absolute deadline expired after submission".into(),
                ));
            }
            if let Err(message) = self.iterate(deadline) {
                self.retire();
                return Err(ClientError::UnknownOutcome(message));
            }
        }
    }
}

/// A transport error explicitly distinguishes failure before submission.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ClientError {
    BeforeSend(String),
    UnknownOutcome(String),
}
impl std::fmt::Display for ClientError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::BeforeSend(message) => write!(f, "native request not submitted: {message}"),
            Self::UnknownOutcome(message) => {
                write!(f, "native outcome unknown; client retired: {message}")
            }
        }
    }
}
impl std::error::Error for ClientError {}

fn operation(command: &Command) -> Result<Operation, ClientError> {
    Ok(match command {
        Command::Quit => Operation::Quit,
        Command::Groups => Operation::Groups,
        Command::Status => Operation::Status,
        Command::Properties(_) => Operation::Properties,
        Command::PropertyGeneration(..) => Operation::PropertyGeneration,
        Command::ParameterGeneration(..) => Operation::ParameterGeneration,
        Command::StopGroup(_) => Operation::StopGroup,
        Command::StartGroup(_) => Operation::StartGroup,
        Command::SessionStop => Operation::SessionStop,
        Command::SessionStart => Operation::SessionStart,
        Command::SourceEnded => Operation::SourceEnded,
        Command::Reset => Operation::Reset,
        Command::PropertiesSet(..) => Operation::PropertiesSet,
        Command::Parameter { .. } => Operation::Parameter,
        Command::PreparedParameter { .. } => {
            return Err(ClientError::BeforeSend(
                "prepared parameter has no public wire command".into(),
            ))
        }
    })
}

#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct Locator {
    version: u8,
    profile: String,
    remote: String,
    node: String,
    owner_pid: u32,
    instance: i64,
}
impl Binding {
    /// Read bounded saved hints; the subsequent live bind supplies authority.
    /// # Errors
    /// Rejects symlinks, nonregular/unowned files, malformed or excessive hints.
    pub fn from_locator(path: &Path) -> Result<Self, String> {
        use std::io::Read;
        use std::os::unix::fs::OpenOptionsExt;
        let file = fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .open(path)
            .map_err(|e| e.to_string())?;
        let metadata = file.metadata().map_err(|e| e.to_string())?;
        let uid = effective_uid()?;
        if !metadata.is_file() || metadata.uid() != uid || metadata.len() > 4096 {
            return Err("supervisor locator must be a bounded owned regular file".into());
        }
        let mut bytes = Vec::new();
        file.take(4097)
            .read_to_end(&mut bytes)
            .map_err(|e| e.to_string())?;
        if bytes.len() > 4096 {
            return Err("supervisor locator exceeds 4096 bytes".into());
        }
        let locator: Locator = serde_json::from_slice(&bytes).map_err(|e| e.to_string())?;
        if locator.version != 1 || locator.profile != codec::PROFILE {
            return Err("unsupported supervisor locator profile/version".into());
        }
        Self::new(
            locator.remote,
            locator.node,
            locator.owner_pid,
            locator.instance,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture(name: &str) -> Vec<u8> {
        fs::read(
            Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("tests/fixtures/native-supervisor")
                .join(name),
        )
        .unwrap()
    }
    fn observation(bytes: &[u8]) -> Observation {
        let header = codec::decode_completion(bytes).unwrap().header;
        Observation {
            binding: Binding::new(
                "/tmp/private/core".into(),
                "owner".into(),
                1,
                header.endpoint_instance,
            )
            .unwrap(),
            marker_name: "marker".into(),
            marker_instance: 1,
            candidates: BTreeMap::new(),
            owner: None,
            identity: Some(header.controller),
            owner_ready: true,
            uuid: Some("11111111-1111-1111-1111-111111111111".into()),
            marker_ready: true,
            capability: None,
            completion_seen: false,
            rejection_seen: false,
            max_token: 0,
            pending: Some(RequestHeader {
                version: envelope::VERSION,
                endpoint_instance: header.endpoint_instance,
                controller: header.controller,
                token: header.token,
                operation: header.operation,
                budget_ns: 1_000_000_000,
            }),
            matched: None,
            last_completion: None,
            failure: None,
            fatal: false,
        }
    }
    #[test]
    fn uuid_is_bounded_canonical_and_nonzero() {
        assert!(validate_uuid("12345678-1234-1234-1234-123456789abc").is_ok());
        for uuid in [
            "00000000-0000-0000-0000-000000000000",
            "12345678-1234-1234-1234-123456789ABC",
            "1234567811234-1234-1234-123456789abc",
            "short",
        ] {
            assert!(validate_uuid(uuid).is_err());
        }
    }
    #[test]
    fn saved_locator_is_bounded_hints_only() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("control.json");
        let hints = serde_json::json!({"version":1,"profile":codec::PROFILE,"remote":"/tmp/private/core","node":"owner","owner_pid":42,"instance":5});
        fs::write(&path, hints.to_string()).unwrap();
        let binding = Binding::from_locator(&path).unwrap();
        assert_eq!(binding.owner_pid, 42);
        assert!(binding.expected_uuid.is_none());
        let symlink = directory.path().join("link");
        std::os::unix::fs::symlink(&path, &symlink).unwrap();
        assert!(Binding::from_locator(&symlink).is_err());
        fs::write(&path, vec![b' '; 4097]).unwrap();
        assert!(Binding::from_locator(&path).is_err());
        let mut extra = hints.clone();
        extra["admitted"] = serde_json::json!(true);
        fs::write(&path, extra.to_string()).unwrap();
        assert!(Binding::from_locator(&path).is_err());
        let mut wrong = hints;
        wrong["profile"] = serde_json::json!(crate::native_runner_codec::PROFILE);
        fs::write(&path, wrong.to_string()).unwrap();
        assert!(Binding::from_locator(&path).is_err());
    }
    #[test]
    fn matching_terminal_precedes_later_retirement() {
        let bytes = fixture("reply-status-simulator.pod");
        let mut state = observation(&bytes);
        state.observe(&bytes).unwrap();
        let at = state.matched.as_ref().unwrap().at;
        state.fail_at("removed", true, at + Duration::from_millis(1));
        assert!(matches!(
            state.terminal(at + Duration::from_secs(1)),
            Some(Ok(Reply::Completion(_)))
        ));
        assert!(state.healthy().is_err());
    }
    #[test]
    fn earlier_retirement_fatal_evidence_and_late_terminal_do_not_complete() {
        let bytes = fixture("reply-status-simulator.pod");
        let mut state = observation(&bytes);
        state.fail("removed", true);
        state.observe(&bytes).unwrap();
        assert!(state.matched.is_none());
        assert!(matches!(
            state.terminal(Instant::now() + Duration::from_secs(1)),
            Some(Err(_))
        ));
        let mut state = observation(&bytes);
        state.observe(&bytes).unwrap();
        state.fail("malformed", false);
        assert!(matches!(
            state.terminal(Instant::now() + Duration::from_secs(1)),
            Some(Err(_))
        ));
        let mut state = observation(&bytes);
        let deadline = Instant::now()
            .checked_sub(Duration::from_millis(1))
            .unwrap();
        state.observe(&bytes).unwrap();
        assert!(state.terminal(deadline).is_none());
    }
    #[test]
    fn malformed_and_conflicting_native_evidence_is_rejected() {
        let bytes = fixture("reply-status-simulator.pod");
        let mut state = observation(&bytes);
        assert!(state
            .observe(&vec![0; envelope::LIFECYCLE_REPLY_BOUND + 1])
            .is_err());
        assert!(state
            .observe(&fixture("bad-reply-source-token.pod"))
            .is_err());
        let mut state = observation(&bytes);
        state.observe(&bytes).unwrap();
        let mut c = codec::decode_completion(&bytes).unwrap();
        c.snapshot.as_mut().unwrap().source.as_mut().unwrap().token += 1;
        // Changing the valid bounded message while retaining its token is fatal.
        c.snapshot.as_mut().unwrap().source = None;
        assert!(state
            .observe(&codec::encode_completion(&c).unwrap())
            .is_err());
    }
    #[test]
    fn rendering_preserves_runner_and_source_domains() {
        let reply = Reply::Completion(
            codec::decode_completion(&fixture("reply-status-simulator.pod")).unwrap(),
        );
        let value = reply.render(Some("operator"));
        assert_eq!(value["id"], "operator");
        assert_eq!(value["supervisor_phase"], "admitted");
        assert!(value["source"]["report-generation"].is_i64());
        assert!(value["source"]["report-ready"].is_boolean());
        let reply = Reply::Completion(
            codec::decode_completion(&fixture("reply-status-calibration.pod")).unwrap(),
        );
        let value = reply.render(None);
        assert_eq!(value["source"]["lifecycle"], "Connected");
        assert!(value["source"]["cursor"]["domain"].is_u64());
        assert_eq!(value["source_endpoint"]["instrument"], "classic");
        let partial = Reply::Completion(
            codec::decode_completion(&fixture("reply-failed-partial.pod")).unwrap(),
        );
        let shown = partial.render(None);
        assert_eq!(shown["ok"], false);
        assert_eq!(shown["state"], "Running");
        assert_eq!(shown["result"]["outcome"], "completed");
        assert_eq!(shown["error"]["field"], "source.state");
        let reply = Reply::Completion(
            codec::decode_completion(&fixture("reply-status-preparing.pod")).unwrap(),
        );
        let value = reply.render(None);
        assert!(value["session_id"].is_null());
        assert_eq!(value["admitted"], false);
    }
}
