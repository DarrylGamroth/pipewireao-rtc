//! Cold native ingress for the existing sole Runner dispatcher.

#[cfg(test)]
#[path = "native_runner_endpoint_tests.rs"]
mod tests;

use crate::control::{self, Command, ControlError, ExecutionResult, PropertyGenerationObservation};
use crate::native_runner_mailbox::{Accepted, Stage};
use crate::native_runner_result as result;
use pipewire as pw;
use pipewireao_rtc::native_control_codec::{
    self as envelope, ControllerIdentity, ReplyHeader, RequestHeader,
};
use pipewireao_rtc::{
    ExecutionGroupState, LifecycleState, LiveGraphAdapter, ParameterGeneration, PropertyGeneration,
    Runner, ScientificDiagnostic,
};
use pw::properties::properties;
use pw::proxy::ProxyT;
use pw::spa::pod::serialize::PodSerializer;
use pw::spa::pod::{Object, Pod, Property, Value};
use pw::spa::utils::{Id, SpaTypes};
use std::cell::{Cell, RefCell};
use std::collections::{BTreeMap, BTreeSet};
use std::io::Cursor;
use std::os::unix::fs::{FileTypeExt, MetadataExt};
use std::path::Path;
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::time::{Duration, Instant};

const PROTOCOL: &str = "pipewireao.rtc-control/1";
const CONTROLLER_PROFILE: &str = "pipewireao.rtc.controller/1";
const CONTROLLER_PREFIX: &str = "pipewireao.rtc.controller.";
const MARKER_BOUND: usize = 32;

pub(crate) struct Options {
    pub name: String,
    pub instance: i64,
}

pub(crate) fn validate_remote(remote: &str) -> Result<String, ScientificDiagnostic> {
    let path =
        crate::control_socket::validate_socket_path(Path::new(remote)).map_err(diagnostic)?;
    let metadata = std::fs::symlink_metadata(&path).map_err(diagnostic)?;
    if !metadata.file_type().is_socket()
        || metadata.uid() != crate::control_socket::effective_uid().map_err(diagnostic)?
    {
        return Err(diagnostic(
            "native remote must be the effective user's socket in a private directory",
        ));
    }
    path.to_str()
        .map(str::to_owned)
        .ok_or_else(|| diagnostic("private remote must be UTF-8"))
}

fn diagnostic(error: impl std::fmt::Display) -> ScientificDiagnostic {
    ScientificDiagnostic::new("native runner control", error.to_string())
}

fn control_error(message: &str) -> ControlError {
    ControlError::new("native.runner.control", message)
}

fn reply(request: &RequestHeader, code: i32) -> ReplyHeader {
    ReplyHeader {
        version: envelope::VERSION,
        endpoint_instance: request.endpoint_instance,
        controller: request.controller,
        token: request.token,
        operation: request.operation,
        result: code,
    }
}

fn sentinel(instance: i64, code: i32) -> ReplyHeader {
    ReplyHeader {
        version: envelope::VERSION,
        endpoint_instance: instance,
        controller: ControllerIdentity {
            global_id: 0,
            serial: 0,
            instance: 0,
        },
        token: 0,
        operation: 0,
        result: code,
    }
}

struct Marker {
    _info_listener: pw::node::NodeListener,
    _proxy_listener: pw::proxy::ProxyListener,
    _node: pw::node::Node,
}

#[derive(Clone, Copy, Eq, PartialEq)]
struct MarkerProof {
    identity: ControllerIdentity,
    pid: u32,
}

fn marker_proof(info: &pw::node::NodeInfoRef, id: u32, serial: u64) -> Option<MarkerProof> {
    if info.id() != id || info.n_input_ports() != 0 || info.n_output_ports() != 0 {
        return None;
    }
    let props = info.props()?;
    if props.get("pipewireao.rtc-control.protocol")? != PROTOCOL
        || props.get("pipewireao.rtc-control.profile")? != CONTROLLER_PROFILE
    {
        return None;
    }
    let observed_serial = props.get("object.serial")?.parse::<u64>().ok()?;
    let instance = props
        .get("pipewireao.rtc-control.instance")?
        .parse::<i64>()
        .ok()?;
    let pid = props
        .get("pipewireao.rtc-control.owner-pid")?
        .parse::<u32>()
        .ok()?;
    if observed_serial != serial || instance <= 0 || pid == 0 {
        return None;
    }
    Some(MarkerProof {
        identity: ControllerIdentity {
            global_id: id,
            serial,
            instance,
        },
        pid,
    })
}

fn observe_marker(
    registry: &pw::registry::RegistryRc,
    global: &pw::registry::GlobalObject<&pw::spa::utils::dict::DictRef>,
    bindings: &RefCell<BTreeMap<u32, Marker>>,
    stage: &Arc<Mutex<Stage>>,
) {
    if global.type_ != pw::types::ObjectType::Node || bindings.borrow().len() >= MARKER_BOUND {
        return;
    }
    let Some(props) = global.props else {
        return;
    };
    let Some(name) = props.get("node.name") else {
        return;
    };
    if name.len() > 128 || !name.starts_with(CONTROLLER_PREFIX) {
        return;
    }
    let Some(serial) = props
        .get("object.serial")
        .and_then(|s| s.parse::<u64>().ok())
        .filter(|s| *s > 0)
    else {
        return;
    };
    let Ok(node) = registry.bind::<pw::node::Node, _>(global) else {
        return;
    };
    let id = global.id;
    let proof = Rc::new(Cell::new(None::<MarkerProof>));
    let revoked = Rc::new(Cell::new(false));
    let catalog = Arc::clone(stage);
    let info_listener = node
        .add_listener_local()
        .info(move |info| {
            if revoked.get() {
                return;
            }
            if proof.get().is_some()
                && !info.change_mask().contains(pw::node::NodeChangeMask::PROPS)
                && info.n_input_ports() == 0
                && info.n_output_ports() == 0
            {
                return;
            }
            let current = marker_proof(info, id, serial);
            if let Some(previous) = proof.get() {
                if current != Some(previous) {
                    revoked.set(true);
                    catalog
                        .lock()
                        .expect("native mailbox poisoned")
                        .remove_controller(id);
                }
            } else if let Some(current) = current {
                if catalog
                    .lock()
                    .expect("native mailbox poisoned")
                    .add_controller(current.identity)
                {
                    proof.set(Some(current));
                }
            }
        })
        .register();
    let removed = Arc::clone(stage);
    let failed = Arc::clone(stage);
    let proxy_listener = node
        .upcast_ref()
        .add_listener_local()
        .removed(move || {
            removed
                .lock()
                .expect("native mailbox poisoned")
                .remove_controller(id);
        })
        .error(move |_, _, _| {
            failed
                .lock()
                .expect("native mailbox poisoned")
                .remove_controller(id);
        })
        .register();
    bindings.borrow_mut().insert(
        id,
        Marker {
            _info_listener: info_listener,
            _proxy_listener: proxy_listener,
            _node: node,
        },
    );
}

fn capability(stage: &Stage, lifecycle: LifecycleState) -> Result<Vec<u8>, ScientificDiagnostic> {
    let fields = [
        ("version", Value::Int(1)),
        ("instance", Value::Long(stage.instance)),
        ("owner-pid", Value::Id(Id(std::process::id()))),
        ("lifecycle", Value::Id(Id(result::lifecycle_id(lifecycle)))),
        ("last-token", Value::Long(stage.last_token)),
        (
            "controllers",
            Value::Struct(
                stage
                    .controllers
                    .values()
                    .map(|identity| {
                        Value::Struct(vec![
                            Value::Id(Id(identity.global_id)),
                            Value::Long(envelope::serial_to_long(identity.serial)),
                            Value::Long(identity.instance),
                        ])
                    })
                    .collect(),
            ),
        ),
    ];
    let value = Value::Object(Object {
        type_: SpaTypes::ObjectParamProps.as_raw(),
        id: pw::spa::param::ParamType::Props.as_raw(),
        properties: vec![Property::new(
            pw::spa::sys::SPA_PROP_params,
            Value::Struct(
                fields
                    .into_iter()
                    .flat_map(|(name, value)| {
                        [
                            Value::String(format!("pipewireao.rtc.runner.{name}")),
                            value,
                        ]
                    })
                    .collect(),
            ),
        )],
    });
    Ok(PodSerializer::serialize(Cursor::new(Vec::new()), &value)
        .map_err(diagnostic)?
        .0
        .into_inner())
}

struct Job {
    request: RequestHeader,
    deadline: Instant,
    command: Command,
}
struct Prepared {
    request: RequestHeader,
    command: Result<Command, ControlError>,
}

struct Preparation {
    jobs: mpsc::SyncSender<Job>,
    results: mpsc::Receiver<Prepared>,
    // Dropping a JoinHandle detaches; shutdown never joins blocked file I/O.
    _thread: std::thread::JoinHandle<()>,
}

impl Preparation {
    fn new() -> Result<Self, ScientificDiagnostic> {
        let (jobs, receive) = mpsc::sync_channel::<Job>(1);
        let (publish, results) = mpsc::sync_channel(1);
        let thread = std::thread::Builder::new()
            .name("rtc-param-prepare".into())
            .spawn(move || {
                while let Ok(job) = receive.recv() {
                    let mut command = if Instant::now() >= job.deadline {
                        Err(control_error(
                            "parameter preparation expired before file access",
                        ))
                    } else {
                        control::prepare(job.command)
                    };
                    if Instant::now() >= job.deadline {
                        command = Err(control_error(
                            "parameter preparation expired; result will not be dispatched",
                        ));
                    }
                    if publish
                        .send(Prepared {
                            request: job.request,
                            command,
                        })
                        .is_err()
                    {
                        break;
                    }
                }
            })
            .map_err(diagnostic)?;
        Ok(Self {
            jobs,
            results,
            _thread: thread,
        })
    }
}

struct Endpoint {
    _registry_listener: pw::registry::Listener,
    _registry: pw::registry::RegistryRc,
    _markers: Rc<RefCell<BTreeMap<u32, Marker>>>,
    _filter_listener: pw::filter::FilterListenerRc<'static, ()>,
    filter: pw::filter::FilterRc,
    stage: Arc<Mutex<Stage>>,
    fatal: Arc<Mutex<Option<String>>>,
    completion: Vec<u8>,
    rejection: Vec<u8>,
}

fn pod(bytes: &[u8]) -> Result<&Pod, ScientificDiagnostic> {
    Pod::from_bytes(bytes).ok_or_else(|| diagnostic("internal serialized POD is incomplete"))
}

impl Endpoint {
    fn new(
        runner: &Runner<LiveGraphAdapter>,
        options: &Options,
    ) -> Result<Self, ScientificDiagnostic> {
        let core = runner.executor().control_core();
        let registry = core.get_registry_rc().map_err(diagnostic)?;
        let markers = Rc::new(RefCell::new(BTreeMap::new()));
        let stage = Arc::new(Mutex::new(Stage::new(options.instance)));
        let added = Rc::clone(&markers);
        let removed = Rc::clone(&markers);
        let bind_registry = registry.clone();
        let added_state = Arc::clone(&stage);
        let removed_state = Arc::clone(&stage);
        let registry_listener = registry
            .add_listener_local()
            .global(move |global| observe_marker(&bind_registry, global, &added, &added_state))
            .global_remove(move |id| {
                removed_state
                    .lock()
                    .expect("native mailbox poisoned")
                    .remove_controller(id);
                removed.borrow_mut().remove(&id);
            })
            .register();
        let filter = pw::filter::FilterRc::new(
            core,
            &options.name,
            properties! {
                "node.name" => options.name.clone(), "media.class" => "Control",
                "pipewireao.rtc-control.protocol" => PROTOCOL,
                "pipewireao.rtc-control.profile" => crate::native_runner_codec::PROFILE,
                "pipewireao.rtc-control.instance" => options.instance.to_string(),
                "pipewireao.rtc-control.owner-pid" => std::process::id().to_string(),
            },
        )
        .map_err(diagnostic)?;
        let callback = Arc::clone(&stage);
        let fatal = Arc::new(Mutex::new(None));
        let filter_failure = Arc::clone(&fatal);
        let listener = filter
            .add_local_listener::<()>()
            .param_changed(move |_, (), port, id, param| {
                if port.is_none() && id == pw::spa::param::ParamType::Props.as_raw() {
                    if let Some(param) = param {
                        callback
                            .lock()
                            .expect("native mailbox poisoned")
                            .stage(param.as_bytes(), Instant::now());
                    }
                }
            })
            .state_changed(move |_, (), _, state| {
                if let pw::filter::FilterState::Error(message) = state {
                    *filter_failure.lock().expect("native mailbox poisoned") =
                        Some(if message.len() <= 256 {
                            message
                        } else {
                            "control Filter failed with oversized diagnostic".into()
                        });
                }
            })
            .register()
            .map_err(diagnostic)?;
        let completion =
            envelope::encode_completion(&sentinel(options.instance, 0), &[]).map_err(diagnostic)?;
        let rejection = result::encode_rejection(
            &sentinel(options.instance, -libc::ENODATA),
            runner.state(),
            &control_error("no rejected request"),
        )
        .map_err(|e| diagnostic(e.message))?;
        let cap = capability(
            &stage.lock().expect("native mailbox poisoned"),
            runner.state(),
        )?;
        filter
            .connect(
                pw::filter::FilterFlags::INACTIVE,
                &mut [pod(&cap)?, pod(&completion)?, pod(&rejection)?],
            )
            .map_err(diagnostic)?;
        Ok(Self {
            _registry_listener: registry_listener,
            _registry: registry,
            _markers: markers,
            _filter_listener: listener,
            filter,
            stage,
            fatal,
            completion,
            rejection,
        })
    }

    fn publish(&mut self, lifecycle: LifecycleState) -> Result<(), ScientificDiagnostic> {
        let cap = {
            let mut stage = self.stage.lock().expect("native mailbox poisoned");
            stage.dirty = false;
            capability(&stage, lifecycle)?
        };
        self.filter
            .update_params(&mut [pod(&cap)?, pod(&self.completion)?, pod(&self.rejection)?])
            .map_err(diagnostic)
    }

    fn publish_pending(&mut self, lifecycle: LifecycleState) -> Result<(), ScientificDiagnostic> {
        let (rejection, dirty) = {
            let mut stage = self.stage.lock().expect("native mailbox poisoned");
            (stage.rejection.take(), stage.dirty)
        };
        if let Some(rejection) = rejection {
            self.rejection =
                result::encode_rejection(&rejection.header, lifecycle, &rejection.error)
                    .or_else(|_| {
                        result::encode_rejection(
                            &rejection.header,
                            lifecycle,
                            &control_error(
                                "request rejected; diagnostic exceeds native reply capacity",
                            ),
                        )
                    })
                    .map_err(|e| diagnostic(e.message))?;
        } else if !dirty {
            return Ok(());
        }
        self.publish(lifecycle)
    }

    fn live(&self, accepted: &Accepted) -> bool {
        self.stage
            .lock()
            .expect("native mailbox poisoned")
            .is_live(&accepted.header)
    }

    // Timeout/failure publication is nonwaiting even after the operation budget.
    // Success is rechecked immediately before this local publication boundary.
    fn finish(
        &mut self,
        accepted: &Accepted,
        lifecycle: LifecycleState,
        value: Result<ExecutionResult, (i32, ControlError)>,
    ) -> Result<(), ScientificDiagnostic> {
        let value = if accepted.is_expired(Instant::now()) {
            Err((
                -libc::ETIMEDOUT,
                control_error("operation expired; applied effects are not rolled back"),
            ))
        } else if !self.live(accepted) {
            Err((
                -libc::ESTALE,
                control_error("controller removal was observed; operation outcome is unknown"),
            ))
        } else {
            value
        };
        let bytes = match &value {
            Ok(value) => result::encode_completion(&reply(&accepted.header, 0), lifecycle, value),
            Err((code, error)) => {
                result::encode_failed_completion(&reply(&accepted.header, *code), lifecycle, error)
            }
        }
        .or_else(|_| {
            result::encode_failed_completion(
                &reply(&accepted.header, -libc::EOVERFLOW),
                lifecycle,
                &control_error("operation result exceeds or violates native reply contract"),
            )
        })
        .map_err(|e| diagnostic(e.message))?;
        self.completion = if value.is_ok()
            && (accepted.is_expired(Instant::now()) || !self.live(accepted))
        {
            result::encode_failed_completion(&reply(&accepted.header, -libc::ETIMEDOUT), lifecycle,
                &control_error("success publication missed deadline or observed caller removal; outcome unknown"))
                .map_err(|e| diagnostic(e.message))?
        } else {
            bytes
        };
        self.publish(lifecycle)?;
        if !self
            .stage
            .lock()
            .expect("native mailbox poisoned")
            .complete(accepted)
        {
            return Err(diagnostic("accepted slot changed before completion"));
        }
        Ok(())
    }
}

fn preflight_mutation(accepted: &Accepted, lifecycle: LifecycleState) -> Result<(), ControlError> {
    use Command as C;
    let (state, value) = match &accepted.command {
        C::Quit => (lifecycle, ExecutionResult::Quit),
        C::SessionStop => (
            LifecycleState::Ready,
            ExecutionResult::SessionStop {
                state: LifecycleState::Ready,
            },
        ),
        C::SessionStart => (
            LifecycleState::Running,
            ExecutionResult::SessionStart {
                state: LifecycleState::Running,
            },
        ),
        C::SourceEnded => (
            LifecycleState::Ready,
            ExecutionResult::SourceEnded {
                state: LifecycleState::Ready,
            },
        ),
        C::Reset => (
            LifecycleState::Ready,
            ExecutionResult::Reset {
                state: LifecycleState::Ready,
            },
        ),
        C::StopGroup(group) | C::StartGroup(group) => {
            let requested = if matches!(&accepted.command, C::StopGroup(_)) {
                ExecutionGroupState::Stopped
            } else {
                ExecutionGroupState::Running
            };
            (
                lifecycle,
                ExecutionResult::GroupState {
                    group: group.clone(),
                    requested,
                    observed: Some(requested),
                },
            )
        }
        C::PropertiesSet(graph, values) => {
            let nodes = values
                .keys()
                .filter_map(|key| key.split_once(':').map(|(node, _)| node))
                .collect::<BTreeSet<_>>();
            (
                lifecycle,
                ExecutionResult::PropertiesSet {
                    graph: graph.clone(),
                    generations: nodes
                        .into_iter()
                        .map(|node| PropertyGenerationObservation {
                            node: node.to_owned(),
                            generation: Some(PropertyGeneration {
                                requested: i64::MAX,
                                active: Some(i64::MAX),
                            }),
                        })
                        .collect(),
                    active_adoption_observed: false,
                },
            )
        }
        C::Parameter {
            graph, parameter, ..
        } => (
            lifecycle,
            ExecutionResult::Parameter {
                graph: graph.clone(),
                parameter: parameter.clone(),
                generation: Some(ParameterGeneration {
                    requested: i64::MAX,
                    active: i64::MAX,
                }),
            },
        ),
        C::PreparedParameter { .. } => {
            return Err(control_error(
                "internal prepared command cannot be admitted",
            ))
        }
        C::Groups
        | C::Status
        | C::Properties(_)
        | C::PropertyGeneration(_, _)
        | C::ParameterGeneration(_, _) => return Ok(()),
    };
    result::validate_completion_capacity(&reply(&accepted.header, 0), state, &value)
}

fn execute(
    runner: &mut Runner<LiveGraphAdapter>,
    endpoint: &mut Endpoint,
    accepted: &Accepted,
    command: Command,
) -> Result<bool, ScientificDiagnostic> {
    let mut shutdown = false;
    let execution = runner.with_control_deadline(accepted.deadline, |runner| {
        runner
            .executor_mut()
            .progress_until(accepted.deadline)
            .map_err(|e| (-libc::EIO, ControlError::new(e.field(), e.message())))?;
        if accepted.is_expired(Instant::now()) {
            return Err((
                -libc::ETIMEDOUT,
                control_error("queued request expired before effects"),
            ));
        }
        if !endpoint.live(accepted) {
            return Err((
                -libc::ESTALE,
                control_error("controller removal observed before effects"),
            ));
        }
        let execution = command.execute(runner).map_err(|e| (-libc::EINVAL, e))?;
        shutdown = execution.shutdown;
        runner
            .executor_mut()
            .progress_until(accepted.deadline)
            .map_err(|e| (-libc::EIO, ControlError::new(e.field(), e.message())))?;
        Ok(execution)
    });
    endpoint.finish(
        accepted,
        runner.state(),
        execution.map(|value| value.result),
    )?;
    if shutdown {
        // Flush normal quit completion before dropping its exported node. This
        // does not rewrite the stable application result if observation fails.
        let _ = runner.executor_mut().progress_until(accepted.deadline);
    }
    Ok(shutdown)
}

fn dispatch_request(
    runner: &mut Runner<LiveGraphAdapter>,
    endpoint: &mut Endpoint,
    preparation: &Preparation,
    accepted: Accepted,
) -> Result<(Option<Accepted>, bool), ScientificDiagnostic> {
    if accepted.is_expired(Instant::now()) || !endpoint.live(&accepted) {
        endpoint.finish(
            &accepted,
            runner.state(),
            Err((
                -libc::ECANCELED,
                control_error("request expired or removal observed before dispatch"),
            )),
        )?;
    } else if let Err(error) = preflight_mutation(&accepted, runner.state()) {
        endpoint.finish(&accepted, runner.state(), Err((-libc::EOVERFLOW, error)))?;
    } else if matches!(&accepted.command, Command::Parameter { .. }) {
        if let Err(error) = runner.executor_mut().progress_until(accepted.deadline) {
            endpoint.finish(
                &accepted,
                runner.state(),
                Err((
                    -libc::EIO,
                    ControlError::new(error.field(), error.message()),
                )),
            )?;
        } else if accepted.is_expired(Instant::now()) || !endpoint.live(&accepted) {
            endpoint.finish(
                &accepted,
                runner.state(),
                Err((
                    -libc::ECANCELED,
                    control_error("parameter preparation not started after expiry/removal"),
                )),
            )?;
        } else {
            preparation
                .jobs
                .try_send(Job {
                    request: accepted.header,
                    deadline: accepted.deadline,
                    command: accepted.command.clone(),
                })
                .map_err(diagnostic)?;
            endpoint
                .stage
                .lock()
                .expect("native mailbox poisoned")
                .worker_busy = true;
            return Ok((Some(accepted), false));
        }
    } else {
        let shutdown = execute(runner, endpoint, &accepted, accepted.command.clone())?;
        return Ok((None, shutdown));
    }
    Ok((None, false))
}

fn monitor_required_objects(
    runner: &mut Runner<LiveGraphAdapter>,
    endpoint: &mut Endpoint,
    current: &mut Option<Accepted>,
) -> Result<(), ScientificDiagnostic> {
    struct Maintenance(Arc<Mutex<Stage>>);
    impl Drop for Maintenance {
        fn drop(&mut self) {
            self.0.lock().expect("native mailbox poisoned").maintenance = false;
        }
    }
    // A callback may already have accepted queued work. Inherit that budget
    // too. While monitoring has no accepted request, reject reentrant arrivals
    // as busy rather than admitting them behind a fresh maintenance wait.
    let request_deadline = {
        let mut stage = endpoint.stage.lock().expect("native mailbox poisoned");
        stage.maintenance = true;
        current
            .as_ref()
            .or(stage.pending.as_ref())
            .map(|accepted| accepted.deadline)
    };
    let deadline = request_deadline.unwrap_or_else(|| Instant::now() + Duration::from_secs(5));
    let _maintenance = Maintenance(Arc::clone(&endpoint.stage));
    if !matches!(
        runner.state(),
        LifecycleState::Ready | LifecycleState::Running
    ) {
        return Ok(());
    }
    let observation = runner.with_control_deadline(deadline, |runner| {
        use pipewireao_rtc::EffectExecutor;
        runner.executor_mut().check_required_objects()
    });
    if request_deadline.is_some_and(|deadline| Instant::now() >= deadline) {
        let accepted = current.take().or_else(|| {
            endpoint
                .stage
                .lock()
                .expect("native mailbox poisoned")
                .take_pending()
        });
        if let Some(accepted) = accepted {
            endpoint.finish(
                &accepted,
                runner.state(),
                Err((
                    -libc::ETIMEDOUT,
                    control_error(
                        "request expired during monitoring; no command effect dispatched",
                    ),
                )),
            )?;
        }
        // A request-scoped timeout is not evidence of a required-object fault.
        // The next maintenance check has its own budget after request release.
        return Ok(());
    }
    let state = runner.with_control_deadline(deadline, |runner| {
        runner
            .apply_required_object_observation(observation)
            .map_err(diagnostic)
    })?;
    if state == LifecycleState::Fault {
        let accepted = current.take().or_else(|| {
            endpoint
                .stage
                .lock()
                .expect("native mailbox poisoned")
                .take_pending()
        });
        if let Some(accepted) = accepted {
            endpoint.finish(
                &accepted,
                state,
                Err((
                    -libc::ECANCELED,
                    control_error("required-object failure fenced parameter preparation"),
                )),
            )?;
        }
        endpoint.publish(state)?;
        return Err(runner
            .diagnostic()
            .cloned()
            .unwrap_or_else(|| diagnostic("required-object monitor reached Fault")));
    }
    Ok(())
}

fn dispatch_prepared_result(
    runner: &mut Runner<LiveGraphAdapter>,
    endpoint: &mut Endpoint,
    current: &mut Option<Accepted>,
    prepared: Prepared,
) -> Result<bool, ScientificDiagnostic> {
    endpoint
        .stage
        .lock()
        .expect("native mailbox poisoned")
        .worker_busy = false;
    if !current
        .as_ref()
        .is_some_and(|accepted| accepted.header == prepared.request)
    {
        return Ok(false);
    }
    let accepted = current.take().expect("matching preparation");
    match prepared.command {
        Ok(command) => execute(runner, endpoint, &accepted, command),
        Err(error) => {
            endpoint.finish(&accepted, runner.state(), Err((-libc::EIO, error)))?;
            Ok(false)
        }
    }
}

pub(crate) fn run(
    runner: &mut Runner<LiveGraphAdapter>,
    options: &Options,
) -> Result<(), ScientificDiagnostic> {
    let mut endpoint = Endpoint::new(runner, options)?;
    let preparation = Preparation::new()?;
    let stopping = Arc::new(AtomicBool::new(false));
    signal_hook::flag::register(signal_hook::consts::SIGTERM, Arc::clone(&stopping))
        .map_err(diagnostic)?;
    let loop_ = runner.executor().main_loop();
    let mut current: Option<Accepted> = None;
    let mut monitor = Instant::now() + Duration::from_millis(100);
    loop {
        if stopping.load(Ordering::Acquire) {
            return Ok(());
        }
        if let Some(error) = endpoint
            .fatal
            .lock()
            .expect("native mailbox poisoned")
            .take()
        {
            return Err(diagnostic(error));
        }
        if loop_
            .loop_()
            .iterate(pw::loop_::Timeout::Finite(Duration::from_millis(5)))
            < 0
        {
            return Err(diagnostic("control loop iteration failed"));
        }
        endpoint.publish_pending(runner.state())?;
        let abandoned_pending = {
            let mut stage = endpoint.stage.lock().expect("native mailbox poisoned");
            let abandoned = stage.pending.as_ref().is_some_and(|accepted| {
                accepted.is_expired(Instant::now())
                    || stage.controllers.get(&accepted.header.controller.global_id)
                        != Some(&accepted.header.controller)
            });
            abandoned.then(|| stage.take_pending()).flatten()
        };
        if let Some(accepted) = abandoned_pending {
            endpoint.finish(
                &accepted,
                runner.state(),
                Err((
                    -libc::ECANCELED,
                    control_error("queued request abandoned; no effect dispatched"),
                )),
            )?;
        }
        if current
            .as_ref()
            .is_some_and(|accepted| accepted.is_expired(Instant::now()) || !endpoint.live(accepted))
        {
            let accepted = current.take().expect("abandoned preparation");
            endpoint.finish(
                &accepted,
                runner.state(),
                Err((
                    -libc::ECANCELED,
                    control_error("parameter preparation abandoned; no effect dispatched"),
                )),
            )?;
        }
        if Instant::now() >= monitor {
            monitor = Instant::now() + Duration::from_millis(100);
            monitor_required_objects(runner, &mut endpoint, &mut current)?;
        }
        if let Ok(prepared) = preparation.results.try_recv() {
            if dispatch_prepared_result(runner, &mut endpoint, &mut current, prepared)? {
                return Ok(());
            }
        }
        let accepted = if current.is_none() {
            endpoint
                .stage
                .lock()
                .expect("native mailbox poisoned")
                .take_pending()
        } else {
            None
        };
        if let Some(accepted) = accepted {
            let (preparing, shutdown) =
                dispatch_request(runner, &mut endpoint, &preparation, accepted)?;
            current = preparing;
            if shutdown {
                return Ok(());
            }
        }
    }
}
