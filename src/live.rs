use crate::{
    ConfigurationInput, DevelopmentConfig, EffectExecutor, EffectToken, EndpointFactory,
    GraphFactory, LifecycleEffect, LifecycleEffectSuccess, NdArrayParameterValue,
    ObjectRealization, ObjectRole, ObjectSpec, ParameterGeneration, PortDirection, PortSpec,
    PropertyGeneration, RequiredObjectStatus, ScalarValue, ScientificDiagnostic,
};
use pipewire as pw;
use pw::properties::PropertiesBox;
use pw::registry::GlobalObject;
use pw::reset_control::{self, ResetControlError, ResetControlStatus};
use pw::run_control::{self, RunControlError, RunControlStatus, RunState};
use pw::spa::param::format::{ElementType, NdArrayFormat, NdArrayLayout};
use pw::spa::param::Parameters;
use pw::spa::pod::deserialize::PodDeserializer;
use pw::spa::pod::serialize::PodSerializer;
use pw::spa::pod::{
    ChoiceValue, Object as PodObject, Property as PodProperty, PropertyFlags, Value,
};
use pw::spa::utils::{Fraction, Id, SpaTypes};
use pw::types::ObjectType;
use std::cell::{Cell, RefCell};
use std::collections::{BTreeMap, BTreeSet};
use std::ffi::CString;
use std::io::Cursor;
use std::mem::size_of;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

const SPA_NODE_FACTORY: &str = "spa-node-factory";
const FITS_LIBRARY_FILE: &str = "libspa-fits.so";
const DISCARD_LIBRARY: &str = "pipewireao/libspa-pipewireao-discard";
const DISCARD_LIBRARY_FILE: &str = "libspa-pipewireao-discard.so";
const NDARRAY_LIBRARY: &str = "ndarray/libspa-ndarray";
const NDARRAY_LIBRARY_FILE: &str = "libspa-ndarray.so";
const DISCARD_METRIC_SEQUENCE: i32 = 0x4453;
const FITS_STATUS_SEQUENCE: i32 = 0x4649;
const FORMAT_ENUM_SEQUENCE: i32 = 0x4654;
const CALLBACK_TIMEOUT: Duration = Duration::from_secs(5);

// These scopes are private and lexically nested on the sole adapter owner.
// Admission and lexical limits are separate: a request's limit must survive
// return from an inner scope even when that scope already has a shorter limit.
#[derive(Clone, Copy, Default)]
struct ControlDeadline {
    scope: Option<Instant>,
    admission: Option<Instant>,
}

impl ControlDeadline {
    fn effective(self) -> Option<Instant> {
        match (self.scope, self.admission) {
            (Some(scope), Some(admission)) => Some(scope.min(admission)),
            (scope, admission) => scope.or(admission),
        }
    }

    fn limit(&mut self, deadline: Instant) {
        if self.scope.is_some() {
            self.admission = Some(
                self.admission
                    .map_or(deadline, |current| current.min(deadline)),
            );
        }
    }
}

struct DeadlineGuard {
    current: Arc<Mutex<ControlDeadline>>,
    previous: ControlDeadline,
}

impl crate::Runner<LiveGraphAdapter> {
    /// Executes cold control work with one inherited adapter deadline.
    /// Scope restoration is lexical, including return and panic unwinding.
    /// This bounds nested PipeWire waits, not arbitrary filesystem/native calls.
    #[doc(hidden)]
    pub fn with_control_deadline<T>(
        &mut self,
        deadline: Instant,
        operation: impl FnOnce(&mut Self) -> T,
    ) -> T {
        let _scope = self.executor().scoped_deadline(deadline);
        operation(self)
    }
}

impl DeadlineGuard {
    fn new(current: Arc<Mutex<ControlDeadline>>, deadline: Instant) -> Self {
        let previous = {
            let mut active = current.lock().expect("control deadline poisoned");
            let previous = *active;
            active.scope = Some(previous.scope.map_or(deadline, |outer| outer.min(deadline)));
            previous
        };
        Self { current, previous }
    }
}

impl Drop for DeadlineGuard {
    fn drop(&mut self) {
        let mut active = self.current.lock().expect("control deadline poisoned");
        let admission = active.admission;
        *active = self.previous;
        // Only an inner scope carries reentrant admission limits to its parent.
        // The outermost scope restores all prior state, including after unwind.
        if active.scope.is_some() {
            if let Some(admission) = admission {
                active.limit(admission);
            }
        }
    }
}

#[cfg(test)]
mod deadline_tests {
    use super::{Arc, Cell, ControlDeadline, DeadlineGuard, Duration, Instant, Mutex, Rc};

    #[test]
    fn nested_scopes_preserve_the_earliest_deadline() {
        let current = Arc::new(Mutex::new(ControlDeadline::default()));
        let early = Instant::now() + Duration::from_secs(1);
        let late = early + Duration::from_secs(1);
        let outer = DeadlineGuard::new(Arc::clone(&current), early);
        {
            let _inner = DeadlineGuard::new(Arc::clone(&current), late);
            assert_eq!(current.lock().unwrap().effective(), Some(early));
        }
        assert_eq!(current.lock().unwrap().effective(), Some(early));
        drop(outer);
        assert_eq!(current.lock().unwrap().effective(), None);
    }

    #[test]
    fn inner_earlier_deadline_restores_parent_on_return() {
        let current = Arc::new(Mutex::new(ControlDeadline::default()));
        let early = Instant::now();
        let late = early + Duration::from_secs(1);
        let _outer = DeadlineGuard::new(Arc::clone(&current), late);
        {
            let _inner = DeadlineGuard::new(Arc::clone(&current), early);
            assert_eq!(current.lock().unwrap().effective(), Some(early));
        }
        assert_eq!(current.lock().unwrap().effective(), Some(late));
    }

    #[test]
    fn deadline_is_restored_on_unwind() {
        let current = Arc::new(Mutex::new(ControlDeadline::default()));
        let deadline = Instant::now();
        let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _scope =
                DeadlineGuard::new(Arc::clone(&current), deadline + Duration::from_secs(1));
            current.lock().unwrap().limit(deadline);
            panic!("diagnostic unwind");
        }));
        assert!(outcome.is_err());
        assert_eq!(current.lock().unwrap().effective(), None);
        let fresh = deadline + Duration::from_secs(2);
        let _scope = DeadlineGuard::new(Arc::clone(&current), fresh);
        assert_eq!(current.lock().unwrap().effective(), Some(fresh));
    }

    #[test]
    fn admission_limit_survives_a_shorter_or_equal_inner_scope() {
        for milliseconds in [100, 250, 500] {
            let current = Arc::new(Mutex::new(ControlDeadline::default()));
            let now = Instant::now();
            let outer = DeadlineGuard::new(Arc::clone(&current), now + Duration::from_secs(5));
            {
                let _inner = DeadlineGuard::new(
                    Arc::clone(&current),
                    now + Duration::from_millis(milliseconds),
                );
                current
                    .lock()
                    .unwrap()
                    .limit(now + Duration::from_millis(250));
                assert_eq!(
                    current.lock().unwrap().effective(),
                    Some(now + Duration::from_millis(milliseconds.min(250)))
                );
            }
            assert_eq!(
                current.lock().unwrap().effective(),
                Some(now + Duration::from_millis(250))
            );
            drop(outer);
            assert_eq!(current.lock().unwrap().effective(), None);
        }
    }

    #[test]
    fn admission_limit_is_inactive_without_a_scope_and_cannot_extend_it() {
        let current = Arc::new(Mutex::new(ControlDeadline::default()));
        let now = Instant::now();
        current.lock().unwrap().limit(now);
        assert_eq!(current.lock().unwrap().effective(), None);
        let _scope = DeadlineGuard::new(Arc::clone(&current), now + Duration::from_secs(1));
        current
            .lock()
            .unwrap()
            .limit(now + Duration::from_millis(250));
        current.lock().unwrap().limit(now + Duration::from_secs(2));
        assert_eq!(
            current.lock().unwrap().effective(),
            Some(now + Duration::from_millis(250))
        );
    }

    // The companion Julia fixture stops only its private daemon after READY.
    // Marker files synchronize the test, not an operational control interface.
    #[test]
    #[ignore = "requires the native synchronization private-core fixture"]
    fn stopped_core_bounds_discovery_and_cleanup() {
        let remote = std::env::var("PIPEWIREAO_SYNC_PROOF_REMOTE").unwrap();
        let directory =
            std::path::PathBuf::from(std::env::var_os("PIPEWIREAO_SYNC_PROOF_DIRECTORY").unwrap());
        let mut adapter = super::LiveGraphAdapter::connect(remote).unwrap();
        let done_events = Rc::new(Cell::new(0_u32));
        let seen = Rc::clone(&done_events);
        let _listener = adapter
            .core
            .add_listener_local()
            .done(move |id, _sequence| {
                if id == pipewire::core::PW_ID_CORE {
                    seen.set(seen.get() + 1);
                }
            })
            .register();
        std::fs::write(directory.join("ready"), "").unwrap();
        let marker = |name: &str| {
            let deadline = Instant::now() + Duration::from_secs(30);
            while !directory.join(name).is_file() {
                assert!(
                    Instant::now() < deadline,
                    "fixture marker deadline expired: {name}"
                );
                std::thread::sleep(Duration::from_millis(2));
            }
        };
        let record =
            |stage: &str, started: Instant, value: Result<(), super::ScientificDiagnostic>| {
                assert!(value.is_err());
                std::fs::write(
                    directory.join(format!("result-{stage}")),
                    format!(
                        "elapsed_ns={} result={value:?}\n",
                        started.elapsed().as_nanos()
                    ),
                )
                .unwrap();
                marker(&format!("release-{stage}"));
            };
        marker("go-discovery");
        let started = Instant::now();
        let result =
            adapter.wait_for_external_object(super::ObjectRole::Graph, "absent.sync.proof");
        record("discovery", started, result);
        let started = Instant::now();
        let result = adapter.cleanup(None);
        record("cleanup", started, result);
        // The fixture resumes the daemon to serve old requests while this
        // owner waits, then stops it again before allowing a new sync.
        marker("go-stale");
        let started = Instant::now();
        let result = adapter.progress_until(Instant::now() + Duration::from_millis(250));
        assert_eq!(
            done_events.get(),
            2,
            "both old sync replies must actually have been observed"
        );
        std::fs::write(
            directory.join("late-done-count"),
            done_events.get().to_string(),
        )
        .unwrap();
        record("stale", started, result);
        marker("go-fresh");
        adapter.progress().unwrap();
        // This empty adapter never owned a scientific graph. Local handle
        // release for populated arrays is source-reviewed, not measured here.
        assert!(
            adapter.links.is_empty() && adapter.spa_nodes.is_empty() && adapter.modules.is_empty()
        );
    }

    #[test]
    #[ignore = "requires the native runner destructor private-core fixture"]
    fn dropped_clean_adapter_does_not_start_new_sync() {
        let remote = std::env::var("PIPEWIREAO_DROP_PROOF_REMOTE").unwrap();
        let directory =
            std::path::PathBuf::from(std::env::var_os("PIPEWIREAO_DROP_PROOF_DIRECTORY").unwrap());
        let mut adapter = super::LiveGraphAdapter::connect(remote).unwrap();
        adapter.cleanup(None).unwrap();
        std::fs::write(directory.join("ready"), "").unwrap();
        let deadline = Instant::now() + Duration::from_secs(15);
        while !directory.join("drop").is_file() {
            assert!(Instant::now() < deadline, "fixture did not release drop");
            std::thread::sleep(Duration::from_millis(2));
        }
        let started = Instant::now();
        drop(adapter);
        let elapsed = started.elapsed();
        std::fs::write(directory.join("elapsed-ns"), elapsed.as_nanos().to_string()).unwrap();
        assert!(
            elapsed < Duration::from_millis(250),
            "already-clean adapter destructor started another synchronization budget: {elapsed:?}"
        );
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct LiveGraphStatus {
    pub owned_nodes: usize,
    pub owned_links: usize,
    pub running: bool,
    pub discarded_buffers: u64,
    pub discarded_by_sink: BTreeMap<String, u64>,
}

/// Format-independent metrics reported by one development discard sink.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DiscardObservation {
    pub buffers: u64,
    pub bytes: u64,
    pub payload_digest: u64,
    pub digest_bytes: u64,
}

struct ControlledGraph {
    name: String,
    global_id: u32,
    _listener: pw::node::NodeListener,
    proxy: pw::node::Node,
    status_events: Rc<RefCell<Vec<Result<RunControlStatus, String>>>>,
    reset_events: Rc<RefCell<Vec<Result<ResetControlStatus, String>>>>,
    property_events: GraphPropertyEvents,
    property_info: GraphPropertyInfoEvents,
    advertised_params: GraphAdvertisedParams,
}

struct LatestHoldNode {
    name: String,
    global_id: u32,
    _listener: pw::node::NodeListener,
    proxy: pw::node::Node,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum LatestHoldCommand {
    Start,
    Pause,
}

impl LatestHoldCommand {
    fn node_command(self) -> pw::spa::node::command::NodeCommand {
        let id = match self {
            Self::Start => pw::spa::node::command::NodeCommandId::START,
            Self::Pause => pw::spa::node::command::NodeCommandId::PAUSE,
        };
        pw::spa::node::command::NodeCommand::new(id)
    }
}

fn link_admission_key(
    input_is_latest_hold: bool,
    input_order: usize,
    output_order: usize,
) -> (u8, usize) {
    if input_is_latest_hold {
        // Allocation dependencies between cascaded hold nodes run upstream-first.
        (0, input_order)
    } else {
        (1, usize::MAX - output_order)
    }
}

type GraphPropertyEvents = Rc<RefCell<Vec<Result<BTreeMap<String, ScalarValue>, String>>>>;
type GraphPropertyInfoEvents = Rc<RefCell<Vec<Result<(String, bool, Value), String>>>>;
type GraphAdvertisedParams =
    Rc<RefCell<Option<Vec<(pw::spa::param::ParamType, pw::spa::param::ParamInfoFlags)>>>>;

fn graph_param_subscription_ids(
    advertised: Option<&[(pw::spa::param::ParamType, pw::spa::param::ParamInfoFlags)]>,
) -> Result<Vec<pw::spa::param::ParamType>, &'static str> {
    let Some(advertised) = advertised else {
        return Err("owner did not publish initial NodeInfo parameter capabilities");
    };
    let mut ids = vec![pw::spa::param::ParamType::Props];
    if advertised.iter().any(|(id, flags)| {
        *id == pw::spa::param::ParamType::PropInfo
            && flags.contains(pw::spa::param::ParamInfoFlags::READ)
    }) {
        ids.push(pw::spa::param::ParamType::PropInfo);
    }
    Ok(ids)
}

#[cfg(test)]
mod graph_param_subscription_tests {
    use super::*;
    use pw::spa::param::{ParamInfoFlags, ParamType};

    #[test]
    fn props_remain_mandatory_and_prop_info_requires_read_capability() {
        assert_eq!(
            graph_param_subscription_ids(None).unwrap_err(),
            "owner did not publish initial NodeInfo parameter capabilities"
        );
        assert_eq!(
            graph_param_subscription_ids(Some(&[])).unwrap(),
            [ParamType::Props]
        );
        assert_eq!(
            graph_param_subscription_ids(Some(&[(ParamType::Props, ParamInfoFlags::empty())]))
                .unwrap(),
            [ParamType::Props]
        );
        for flags in [
            ParamInfoFlags::empty(),
            ParamInfoFlags::SERIAL,
            ParamInfoFlags::WRITE,
        ] {
            assert_eq!(
                graph_param_subscription_ids(Some(&[(ParamType::PropInfo, flags)])).unwrap(),
                [ParamType::Props]
            );
        }
        assert_eq!(
            graph_param_subscription_ids(Some(&[(
                ParamType::PropInfo,
                ParamInfoFlags::READ | ParamInfoFlags::SERIAL,
            )]))
            .unwrap(),
            [ParamType::Props, ParamType::PropInfo],
        );
        assert_eq!(
            graph_param_subscription_ids(Some(&[
                (ParamType::PropInfo, ParamInfoFlags::READWRITE,)
            ]))
            .unwrap(),
            [ParamType::Props, ParamType::PropInfo],
        );
    }
}

fn graph_reached_requested_state(
    graph: &ControlledGraph,
    wire_token: i64,
    requested_state: RunState,
) -> Result<bool, ScientificDiagnostic> {
    let events = graph.status_events.borrow();
    statuses_reach_requested_state(&graph.name, &events, wire_token, requested_state)
}

fn statuses_reach_requested_state(
    graph_name: &str,
    events: &[Result<RunControlStatus, String>],
    wire_token: i64,
    requested_state: RunState,
) -> Result<bool, ScientificDiagnostic> {
    let mut matching_status = None;
    for event in events {
        let status = event.as_ref().map_err(|error| {
            ScientificDiagnostic::new(format!("graph {graph_name}.run-control"), error.clone())
        })?;
        if status.completed_token < wire_token {
            continue;
        }
        if status.completed_token > wire_token {
            return Err(ScientificDiagnostic::new(
                format!("graph {graph_name}.run-control.completed-token"),
                format!(
                    "expected lifecycle token {wire_token}, observed {}",
                    status.completed_token
                ),
            ));
        }
        if matching_status.is_some_and(|previous| previous != *status) {
            return Err(ScientificDiagnostic::new(
                format!("graph {graph_name}.run-control.completed-token"),
                format!("conflicting completion statuses for lifecycle token {wire_token}"),
            ));
        }
        matching_status = Some(*status);
        if status.result != 0 {
            return Err(ScientificDiagnostic::new(
                format!("graph {graph_name}.run-control.result"),
                format!(
                    "owner rejected lifecycle token {wire_token} with {}",
                    status.result
                ),
            ));
        }
        if status.actual_state != requested_state {
            return Err(ScientificDiagnostic::new(
                format!("graph {graph_name}.run-control.actual-state"),
                format!(
                    "lifecycle token {wire_token} requested {requested_state:?}, observed {:?}",
                    status.actual_state
                ),
            ));
        }
    }
    Ok(matching_status.is_some())
}

fn reset_reached_completion(
    graph: &ControlledGraph,
    wire_token: i64,
) -> Result<bool, ScientificDiagnostic> {
    let events = graph.reset_events.borrow();
    let mut matched = false;
    for event in events.iter() {
        let status = event.as_ref().map_err(|error| {
            ScientificDiagnostic::new(format!("graph {}.reset-control", graph.name), error.clone())
        })?;
        if status.completed_token < wire_token {
            continue;
        }
        if status.completed_token > wire_token {
            return Err(ScientificDiagnostic::new(
                format!("graph {}.reset-control.completed-token", graph.name),
                format!(
                    "expected lifecycle token {wire_token}, observed {}",
                    status.completed_token
                ),
            ));
        }
        if matched {
            continue;
        }
        matched = true;
        if status.result != 0 {
            return Err(ScientificDiagnostic::new(
                format!("graph {}.reset-control.result", graph.name),
                format!(
                    "owner rejected reset token {wire_token} with {}",
                    status.result
                ),
            ));
        }
    }
    Ok(matched)
}

#[cfg(test)]
mod run_control_status_tests {
    use super::*;

    fn status(token: i64, result: i32, state: RunState) -> RunControlStatus {
        RunControlStatus {
            completed_token: token,
            result,
            actual_state: state,
        }
    }

    #[test]
    fn older_and_identical_current_state_snapshots_are_idempotent() {
        let events = [
            Ok(status(40, 0, RunState::Stopped)),
            Ok(status(41, 0, RunState::Running)),
            Ok(status(41, 0, RunState::Running)),
        ];
        assert!(statuses_reach_requested_state("graph", &events, 41, RunState::Running).unwrap());
    }

    #[test]
    fn future_conflicting_failed_and_wrong_state_snapshots_are_rejected() {
        let future = [Ok(status(42, 0, RunState::Running))];
        assert_eq!(
            statuses_reach_requested_state("graph", &future, 41, RunState::Running)
                .unwrap_err()
                .field(),
            "graph graph.run-control.completed-token"
        );

        let conflicting = [
            Ok(status(41, 0, RunState::Running)),
            Ok(status(41, 0, RunState::Stopped)),
        ];
        assert!(
            statuses_reach_requested_state("graph", &conflicting, 41, RunState::Running)
                .unwrap_err()
                .message()
                .contains("conflicting")
        );

        let failed = [Ok(status(41, -5, RunState::Stopped))];
        assert_eq!(
            statuses_reach_requested_state("graph", &failed, 41, RunState::Running)
                .unwrap_err()
                .field(),
            "graph graph.run-control.result"
        );

        let wrong_state = [Ok(status(41, 0, RunState::Stopped))];
        assert_eq!(
            statuses_reach_requested_state("graph", &wrong_state, 41, RunState::Running)
                .unwrap_err()
                .field(),
            "graph graph.run-control.actual-state"
        );
    }
}

#[cfg(test)]
mod latest_hold_control_tests {
    use super::*;

    #[test]
    fn standard_commands_are_start_and_pause_never_suspend() {
        let start = LatestHoldCommand::Start.node_command();
        let pause = LatestHoldCommand::Pause.node_command();
        assert_eq!(start.id(), pw::spa::node::command::NodeCommandId::START);
        assert_eq!(pause.id(), pw::spa::node::command::NodeCommandId::PAUSE);
        assert_ne!(start.id(), pw::spa::node::command::NodeCommandId::SUSPEND);
        assert_ne!(pause.id(), pw::spa::node::command::NodeCommandId::SUSPEND);
    }

    #[test]
    fn factory_identity_uses_node_information_not_registry_global_properties() {
        assert!(validate_node_factory_identity(
            "graphs[0]",
            Some("api.ndarray.latest-hold"),
            "api.ndarray.latest-hold",
        )
        .is_ok());
        let error = validate_node_factory_identity(
            "graphs[0]",
            Some("api.ndarray.other"),
            "api.ndarray.latest-hold",
        )
        .expect_err("mismatched NodeInfo factory identity");
        assert_eq!(error.field(), "graphs[0].factory");
        let error = validate_node_factory_identity("graphs[0]", None, "api.ndarray.latest-hold")
            .expect_err("missing NodeInfo factory identity");
        assert_eq!(error.field(), "graphs[0].factory");
    }

    #[test]
    fn hold_ingress_allocation_dependencies_precede_downstream_links() {
        let source_to_first_hold = link_admission_key(true, 1, 0);
        let first_to_second_hold = link_admission_key(true, 2, 1);
        let second_hold_to_sink = link_admission_key(false, 3, 2);
        assert!(source_to_first_hold < first_to_second_hold);
        assert!(first_to_second_hold < second_hold_to_sink);
    }

    #[test]
    fn observed_port_rate_accepts_equivalent_rational_spelling() {
        assert!(fractions_equivalent(
            Fraction {
                num: 2000,
                denom: 2
            },
            Fraction {
                num: 1000,
                denom: 1
            },
        ));
        assert!(!fractions_equivalent(
            Fraction { num: 500, denom: 1 },
            Fraction {
                num: 1000,
                denom: 1
            },
        ));
    }
}

struct LiveLink {
    listener: pw::link::LinkListener,
    proxy: pw::link::Link,
    state: Rc<RefCell<LinkAdmissionState>>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum LinkAdmissionState {
    Unknown,
    Pending(String),
    Paused,
    Active,
    Failed(String),
}

struct RequiredExternalPort {
    global_id: u32,
    specification: PortSpec,
    expected_rate: Fraction,
}

struct RequiredExternalObject {
    role: ObjectRole,
    node_name: String,
    global_id: u32,
    ports: Vec<RequiredExternalPort>,
}

#[derive(Default)]
struct ParameterProcessState {
    pending: Option<Arc<Vec<u8>>>,
    failure: Option<String>,
    stride: i32,
}

impl ParameterProcessState {
    fn queue_payload(&mut self, payload: &Arc<Vec<u8>>) -> Result<(), &'static str> {
        if self.pending.is_some() {
            return Err("a parameter value is already pending");
        }
        self.failure = None;
        self.pending = Some(Arc::clone(payload));
        Ok(())
    }
}

struct ParameterPublisher {
    node_name: String,
    port: PortSpec,
    _listener: pw::stream::StreamListener<Rc<RefCell<ParameterProcessState>>>,
    stream: pw::stream::StreamRc,
    state: Rc<RefCell<ParameterProcessState>>,
}

enum PropertyUpdateOutcome {
    Submitted,
    Active(BTreeMap<String, PropertyGeneration>),
}

/// Adapter for one private or explicitly named `PipeWireAO` core.
pub struct LiveGraphAdapter {
    modules: Vec<pw::local_module::LocalModule>,
    spa_nodes: Vec<pw::node::Node>,
    parameter_publishers: Vec<ParameterPublisher>,
    links: Vec<LiveLink>,
    controlled_graphs: Vec<ControlledGraph>,
    latest_hold_nodes: Vec<LatestHoldNode>,
    owned_node_names: Vec<String>,
    required_node_names: Vec<String>,
    required_external_objects: Vec<RequiredExternalObject>,
    finite_source_names: Vec<String>,
    // An external source may publish only after the session reaches RUNNING.
    has_external_source: bool,
    graph_order: Vec<String>,
    latest_hold_order: Vec<String>,
    sink_names: Vec<String>,
    execution_group_nodes: BTreeMap<String, Vec<String>>,
    execution_group_latest_holds: BTreeMap<String, Vec<String>>,
    execution_group_sinks: BTreeMap<String, Vec<String>>,
    parameter_routes: BTreeMap<(String, String), String>,
    expected_objects: usize,
    expected_links: usize,
    creation_failure_after: Option<usize>,
    created_resources: usize,
    status: LiveGraphStatus,
    globals: Rc<RefCell<BTreeMap<u32, GlobalObject<PropertiesBox>>>>,
    errors: Rc<RefCell<Vec<String>>>,
    callback_deadline: Arc<Mutex<ControlDeadline>>,
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
        let remote_name = remote_name.into();
        Self::connect_with_options(&remote_name, None)
    }

    /// Connects a live adapter that injects one failure after the selected
    /// runner-owned node or link has actually been created.
    ///
    /// This constructor exists for private-core integration testing. The
    /// failure is one-shot so the same runner can prove retry and cleanup.
    #[doc(hidden)]
    pub fn connect_with_creation_failure(
        remote_name: impl Into<String>,
        after: usize,
    ) -> Result<Self, ScientificDiagnostic> {
        if after == 0 {
            return Err(ScientificDiagnostic::new(
                "creation failure point",
                "failure point must be positive",
            ));
        }
        let remote_name = remote_name.into();
        Self::connect_with_options(&remote_name, Some(after))
    }

    fn connect_with_options(
        remote_name: &str,
        creation_failure_after: Option<usize>,
    ) -> Result<Self, ScientificDiagnostic> {
        pw::init();
        let main_loop = pw::main_loop::MainLoopRc::new(None).map_err(|error| {
            ScientificDiagnostic::new("PipeWire main loop", format!("creation failed: {error}"))
        })?;
        let context = pw::context::ContextRc::new(&main_loop, None).map_err(|error| {
            ScientificDiagnostic::new("PipeWire context", format!("creation failed: {error}"))
        })?;
        let connect_properties = [("remote.name", remote_name)]
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
            modules: Vec::new(),
            spa_nodes: Vec::new(),
            parameter_publishers: Vec::new(),
            links: Vec::new(),
            controlled_graphs: Vec::new(),
            latest_hold_nodes: Vec::new(),
            owned_node_names: Vec::new(),
            required_node_names: Vec::new(),
            required_external_objects: Vec::new(),
            finite_source_names: Vec::new(),
            has_external_source: false,
            graph_order: Vec::new(),
            latest_hold_order: Vec::new(),
            sink_names: Vec::new(),
            execution_group_nodes: BTreeMap::new(),
            execution_group_latest_holds: BTreeMap::new(),
            execution_group_sinks: BTreeMap::new(),
            parameter_routes: BTreeMap::new(),
            expected_objects: 0,
            expected_links: 0,
            creation_failure_after,
            created_resources: 0,
            status: LiveGraphStatus::default(),
            globals,
            errors,
            callback_deadline: Arc::new(Mutex::new(ControlDeadline::default())),
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

    /// Shares the adapter's owner-thread main loop with an embedding event loop.
    ///
    /// Drive this loop on the thread that owns the adapter. Call runner control
    /// methods after loop callbacks return, since those methods may perform
    /// nested `PipeWire` synchronization. Callbacks should enqueue control work.
    #[must_use]
    pub fn main_loop(&self) -> pw::main_loop::MainLoopRc {
        self.main_loop.clone()
    }

    /// Shares the existing public connection with a cold control endpoint.
    /// The endpoint must use this adapter's sole owner thread and main loop.
    #[doc(hidden)]
    #[must_use]
    pub fn control_core(&self) -> pw::core::CoreRc {
        self.core.clone()
    }

    /// Returns an owner-thread callback that can only shorten an active cold
    /// deadline. Use it when admitting a request during a nested PipeWire wait.
    /// It has no effect outside a lexical control scope.
    #[doc(hidden)]
    pub fn control_deadline_limiter(&self) -> impl Fn(Instant) + 'static {
        let current = Arc::clone(&self.callback_deadline);
        move |deadline| {
            current
                .lock()
                .expect("control deadline poisoned")
                .limit(deadline);
        }
    }

    #[must_use]
    pub fn status(&self) -> LiveGraphStatus {
        let mut status = self.status.clone();
        status.owned_nodes = self.count_owned_nodes();
        status.owned_links = self.links.len();
        status
    }

    /// Reads the maintained discard metrics for every realized sink.
    ///
    /// # Errors
    ///
    /// Returns a scientific diagnostic when a sink metric is unavailable.
    pub fn observe_discarded_buffers(
        &mut self,
    ) -> Result<BTreeMap<String, u64>, ScientificDiagnostic> {
        let observed = self.discard_buffer_counts()?;
        self.status.discarded_buffers = observed.values().sum();
        self.status.discarded_by_sink.clone_from(&observed);
        Ok(observed)
    }

    /// Dispatches pending PipeWire callbacks without changing lifecycle state.
    ///
    /// Embedders normally call [`Runner::poll_required_objects`](crate::Runner::poll_required_objects),
    /// which also performs required-object validation. This narrower operation
    /// exists for integration harnesses that must drive another application's
    /// callback exchange before that application has restored its public node.
    ///
    /// # Errors
    ///
    /// Returns a diagnostic for a PipeWire core synchronization failure.
    #[doc(hidden)]
    pub fn progress(&self) -> Result<(), ScientificDiagnostic> {
        self.roundtrip("PipeWire callback progress")
    }

    /// Drives callback synchronization within an explicit absolute deadline.
    /// This bounds callback waits, not arbitrary code executed by callbacks.
    ///
    /// # Errors
    /// Returns a diagnostic for expiry, core errors or a loop iteration failure.
    #[doc(hidden)]
    pub fn progress_until(&self, deadline: Instant) -> Result<(), ScientificDiagnostic> {
        self.roundtrip_until(deadline, "PipeWire callback progress")
    }

    /// Observes the requested and active scalar-property generations exported
    /// by a realized graph node.
    ///
    /// # Errors
    ///
    /// Returns a diagnostic when the graph or generation properties are not
    /// available through its standard `PipeWire` Props surface.
    pub fn observe_property_generation(
        &self,
        graph_name: &str,
        node_name: &str,
    ) -> Result<PropertyGeneration, ScientificDiagnostic> {
        self.roundtrip(&format!("graph {graph_name} property observation"))?;
        let graph = self.controlled_graph(graph_name)?;
        property_generation(&latest_property_snapshot(graph)?, node_name)
    }

    /// Reads the graph owner's latest standard `SPA_PARAM_Props` snapshot.
    ///
    /// # Errors
    ///
    /// Returns a diagnostic if the graph or its published scientific Props
    /// snapshot is unavailable.
    pub fn observe_properties(
        &self,
        graph_name: &str,
    ) -> Result<BTreeMap<String, ScalarValue>, ScientificDiagnostic> {
        self.roundtrip(&format!("graph {graph_name} property observation"))?;
        latest_property_snapshot(self.controlled_graph(graph_name)?)
    }

    /// Observes the requested and active ndarray-parameter sequences exported
    /// by a realized graph node.
    ///
    /// # Errors
    ///
    /// Returns a diagnostic when the graph or sequence properties are not
    /// available through its standard `PipeWire` Props surface.
    pub fn observe_parameter_generation(
        &self,
        graph_name: &str,
        node_name: &str,
    ) -> Result<ParameterGeneration, ScientificDiagnostic> {
        self.roundtrip(&format!("graph {graph_name} parameter observation"))?;
        let graph = self.controlled_graph(graph_name)?;
        parameter_generation(&latest_property_snapshot(graph)?, node_name)
    }

    /// Reads buffer counts and the ordered payload digest for every sink.
    ///
    /// `digest_bytes == bytes` proves that every advertised payload byte was
    /// addressable and included in `payload_digest`.
    ///
    /// # Errors
    ///
    /// Returns a scientific diagnostic when a sink metric is unavailable.
    pub fn observe_discard_payloads(
        &self,
    ) -> Result<BTreeMap<String, DiscardObservation>, ScientificDiagnostic> {
        self.sink_names
            .iter()
            .map(|sink| {
                let counter =
                    |metric: pw::discard::DiscardMetric| self.discard_counter(sink, metric);
                let observation = DiscardObservation {
                    buffers: counter(pw::discard::DiscardMetric::Buffers)?,
                    bytes: counter(pw::discard::DiscardMetric::Bytes)?,
                    payload_digest: u64::from_ne_bytes(
                        self.discard_metric_long(sink, pw::discard::DiscardMetric::PayloadDigest)?
                            .to_ne_bytes(),
                    ),
                    digest_bytes: counter(pw::discard::DiscardMetric::DigestBytes)?,
                };
                Ok((sink.clone(), observation))
            })
            .collect()
    }

    fn realize(
        &mut self,
        config: &DevelopmentConfig,
        token: EffectToken,
    ) -> Result<(), ScientificDiagnostic> {
        config.validate()?;
        self.cleanup(Some(token))?;
        self.clear_errors();
        self.created_resources = 0;
        self.prepare_realization(config);

        for (index, source) in config.sources.iter().enumerate() {
            let field = format!("sources[{index}]");
            if let Err(error) = self.create_source(source, &field) {
                let _ = self.cleanup(Some(token));
                return Err(error);
            }
            if !source.realization.is_external() {
                if let Err(error) = self.finish_creation_point(&field) {
                    let _ = self.cleanup(Some(token));
                    return Err(error);
                }
            }
        }
        for (index, graph) in config.graphs.iter().enumerate() {
            let field = format!("graphs[{index}]");
            if let Err(error) = self.create_graph(graph, &field) {
                let _ = self.cleanup(Some(token));
                return Err(error);
            }
            if !graph.realization.is_external() {
                if let Err(error) = self.finish_creation_point(&field) {
                    let _ = self.cleanup(Some(token));
                    return Err(error);
                }
            }
        }
        for (index, sink) in config.sinks.iter().enumerate() {
            let field = format!("sinks[{index}]");
            if let Err(error) = self.create_sink(sink, &field) {
                let _ = self.cleanup(Some(token));
                return Err(error);
            }
            if !sink.realization.is_external() {
                if let Err(error) = self.finish_creation_point(&field) {
                    let _ = self.cleanup(Some(token));
                    return Err(error);
                }
            }
        }

        if let Err(error) = self.admit_ports_and_links(config) {
            let _ = self.cleanup(Some(token));
            return Err(error);
        }

        if let Err(error) = self.bind_controlled_graphs() {
            let _ = self.cleanup(Some(token));
            return Err(error);
        }
        if let Err(error) = self.publish_initial_parameters(config) {
            let _ = self.cleanup(Some(token));
            return Err(error);
        }

        self.status.owned_nodes = self.count_owned_nodes();
        self.status.owned_links = self.links.len();
        if self.status.owned_nodes != self.expected_objects
            || self.count_required_nodes() != self.required_node_names.len()
            || self.status.owned_links != self.expected_links
        {
            let diagnostic = ScientificDiagnostic::new(
                "topology",
                format!(
                    "expected exactly {} runner-owned nodes, {} required nodes, and {} declared links; observed {} owned node(s), {} required node(s), and {} link(s)",
                    self.expected_objects,
                    self.required_node_names.len(),
                    self.expected_links,
                    self.status.owned_nodes,
                    self.count_required_nodes(),
                    self.status.owned_links
                ),
            );
            let _ = self.cleanup(Some(token));
            return Err(diagnostic);
        }
        Ok(())
    }

    fn prepare_realization(&mut self, config: &DevelopmentConfig) {
        self.owned_node_names = config
            .owned_node_names()
            .into_iter()
            .map(str::to_owned)
            .collect();
        self.required_node_names = config.node_names().into_iter().map(str::to_owned).collect();
        let complete_frame_sources = config.sources.iter().filter(|source| {
            !matches!(
                source.realization,
                ObjectRealization::Factory(EndpointFactory::RuntimeParameterSource)
            )
        });
        self.finite_source_names = if complete_frame_sources.clone().all(|source| {
            matches!(
                source.realization,
                ObjectRealization::Factory(EndpointFactory::FitsCompleteFrameSource)
            ) && source.arguments.get("api.fits.loop").map(String::as_str) == Some("false")
        }) {
            complete_frame_sources
                .map(|source| source.node_name.clone())
                .collect()
        } else {
            Vec::new()
        };
        self.has_external_source = config
            .sources
            .iter()
            .any(|source| source.realization.is_external());
        self.graph_order = config.session_controlled_graph_names();
        self.prepare_latest_holds(config);
        self.sink_names = config
            .sinks
            .iter()
            .filter(|sink| !sink.realization.is_external())
            .map(|sink| sink.node_name.clone())
            .collect();
        self.execution_group_nodes = config
            .execution_groups
            .iter()
            .map(|group| {
                (
                    group.name.clone(),
                    config
                        .execution_group_graph_names(&group.name)
                        .expect("validated execution group"),
                )
            })
            .collect();
        self.execution_group_sinks = config
            .execution_groups
            .iter()
            .map(|group| {
                (
                    group.name.clone(),
                    config
                        .execution_group_sink_names(&group.name)
                        .expect("validated execution group"),
                )
            })
            .collect();
        self.parameter_routes = config
            .sources
            .iter()
            .filter(|source| {
                matches!(
                    source.realization,
                    ObjectRealization::Factory(EndpointFactory::RuntimeParameterSource)
                )
            })
            .map(|source| {
                let output = format!("{}:{}", source.node_name, source.ports[0].name);
                let link = config
                    .links
                    .iter()
                    .find(|link| link.output == output)
                    .expect("validated parameter link");
                let (graph, parameter) =
                    split_endpoint(&link.input).expect("validated parameter input");
                (
                    (graph.to_owned(), parameter.to_owned()),
                    source.node_name.clone(),
                )
            })
            .collect();
        self.expected_objects = config.owned_object_count();
        self.expected_links = config.links.len();
    }

    fn prepare_latest_holds(&mut self, config: &DevelopmentConfig) {
        let latest_holds = config
            .graphs
            .iter()
            .filter(|graph| {
                matches!(
                    graph.realization,
                    ObjectRealization::Factory(GraphFactory::NdarrayLatestHold)
                )
            })
            .map(|graph| graph.node_name.as_str())
            .collect::<BTreeSet<_>>();
        self.latest_hold_order = config
            .session_controlled_topological_node_names()
            .into_iter()
            .filter(|node| latest_holds.contains(node.as_str()))
            .collect();
        self.execution_group_latest_holds = config
            .execution_groups
            .iter()
            .map(|group| {
                (
                    group.name.clone(),
                    config
                        .execution_group_node_names(&group.name)
                        .expect("validated execution group")
                        .into_iter()
                        .filter(|node| latest_holds.contains(node.as_str()))
                        .collect(),
                )
            })
            .collect();
    }

    fn finish_creation_point(&mut self, field: &str) -> Result<(), ScientificDiagnostic> {
        self.created_resources += 1;
        if self.creation_failure_after == Some(self.created_resources) {
            self.creation_failure_after = None;
            Err(ScientificDiagnostic::new(
                field,
                format!(
                    "injected live failure after runner-owned creation point {}",
                    self.created_resources
                ),
            ))
        } else {
            Ok(())
        }
    }

    fn admit_ports_and_links(
        &mut self,
        config: &DevelopmentConfig,
    ) -> Result<(), ScientificDiagnostic> {
        self.validate_live_ports(config)?;
        // Admit links downstream-first so no source can publish into a
        // partially realized processing path. A latest/hold ingress is the
        // exception: its input pool must exist before PipeWire asks its output
        // port to allocate zero-copy aliases.
        let node_order = config
            .topological_node_names()
            .into_iter()
            .enumerate()
            .map(|(index, name)| (name, index))
            .collect::<BTreeMap<_, _>>();
        let latest_hold_names = config
            .graphs
            .iter()
            .filter(|graph| {
                graph.realization == ObjectRealization::Factory(GraphFactory::NdarrayLatestHold)
            })
            .map(|graph| graph.node_name.as_str())
            .collect::<BTreeSet<_>>();
        let mut links = config.links.iter().enumerate().collect::<Vec<_>>();
        links.sort_by_key(|(_, link)| {
            let input_node = split_endpoint(&link.input)
                .expect("validated latest/hold input endpoint")
                .0;
            let output_node = split_endpoint(&link.output)
                .expect("validated latest/hold output endpoint")
                .0;
            link_admission_key(
                latest_hold_names.contains(input_node),
                node_order[input_node],
                node_order[output_node],
            )
        });
        for (index, link) in links {
            self.create_link(index, &link.output, &link.input, link.passive)?;
            self.finish_creation_point(&format!("links[{index}]"))?;
        }
        self.required_external_objects = self.capture_required_external_objects(config)?;
        Ok(())
    }

    fn start(&mut self, token: EffectToken) -> Result<(), ScientificDiagnostic> {
        if self.count_owned_nodes() != self.expected_objects
            || self.count_required_nodes() != self.required_node_names.len()
            || self.links.len() != self.expected_links
        {
            return Err(ScientificDiagnostic::new(
                "topology",
                "every declared source, graph, sink, and link must exist before start",
            ));
        }
        self.clear_errors();
        let discarded_before_start = self.discard_buffer_counts()?;
        self.status.discarded_buffers = discarded_before_start.values().sum();
        self.status.discarded_by_sink = discarded_before_start.clone();

        let mut start_order = self.graph_order.clone();
        start_order.reverse();
        self.request_graphs(
            &start_order,
            token,
            RunState::Running,
            "start scientific session",
        )?;
        let mut latest_hold_start_order = self.latest_hold_order.clone();
        latest_hold_start_order.reverse();
        self.request_latest_holds(
            &latest_hold_start_order,
            LatestHoldCommand::Start,
            "start latest/hold nodes",
        )?;
        self.wait_for_links_active("start scientific session")?;
        self.trigger_pending_parameters()?;
        self.status.running = true;
        self.status.discarded_by_sink = if self.has_external_source {
            discarded_before_start
        } else {
            self.wait_for_discarded_buffers(&discarded_before_start)?
        };
        self.status.discarded_buffers = self.status.discarded_by_sink.values().sum();
        Ok(())
    }

    fn stop(&mut self, token: EffectToken) -> Result<(), ScientificDiagnostic> {
        self.clear_errors();
        let latest_hold_order = self.latest_hold_order.clone();
        self.request_latest_holds(
            &latest_hold_order,
            LatestHoldCommand::Pause,
            "pause latest/hold nodes",
        )?;
        let graph_order = self.graph_order.clone();
        if !graph_order.is_empty() {
            self.request_graphs(
                &graph_order,
                token,
                RunState::Stopped,
                "stop scientific session",
            )?;
            self.status.discarded_by_sink = self.wait_for_discard_quiescence()?;
            self.status.discarded_buffers = self.status.discarded_by_sink.values().sum();
        }
        self.status.running = false;
        Ok(())
    }

    fn start_execution_group(
        &mut self,
        name: &str,
        token: EffectToken,
    ) -> Result<(), ScientificDiagnostic> {
        let nodes = self
            .execution_group_nodes
            .get(name)
            .cloned()
            .ok_or_else(|| {
                ScientificDiagnostic::new(
                    format!("execution-group {name}"),
                    "group is not realized",
                )
            })?;
        let sinks = self
            .execution_group_sinks
            .get(name)
            .expect("realized group sinks")
            .clone();
        let before = self.discard_buffer_counts_for(&sinks)?;
        let mut start_order = nodes;
        start_order.reverse();
        self.request_graphs(
            &start_order,
            token,
            RunState::Running,
            &format!("start execution group {name}"),
        )?;
        let latest_holds = self
            .execution_group_latest_holds
            .get(name)
            .expect("realized group latest/hold nodes")
            .clone();
        let mut latest_holds = latest_holds;
        latest_holds.reverse();
        self.request_latest_holds(
            &latest_holds,
            LatestHoldCommand::Start,
            &format!("start latest/hold nodes in execution group {name}"),
        )?;
        let observed = if self.has_external_source {
            before
        } else {
            self.wait_for_discarded_buffers(&before)?
        };
        self.status.discarded_by_sink.extend(observed);
        self.status.discarded_buffers = self.status.discarded_by_sink.values().sum();
        Ok(())
    }

    fn stop_execution_group(
        &mut self,
        name: &str,
        token: EffectToken,
    ) -> Result<(), ScientificDiagnostic> {
        let nodes = self
            .execution_group_nodes
            .get(name)
            .cloned()
            .ok_or_else(|| {
                ScientificDiagnostic::new(
                    format!("execution-group {name}"),
                    "group is not realized",
                )
            })?;
        let latest_holds = self
            .execution_group_latest_holds
            .get(name)
            .expect("realized group latest/hold nodes")
            .clone();
        self.request_latest_holds(
            &latest_holds,
            LatestHoldCommand::Pause,
            &format!("pause latest/hold nodes in execution group {name}"),
        )?;
        self.request_graphs(
            &nodes,
            token,
            RunState::Stopped,
            &format!("stop execution group {name}"),
        )?;
        let sinks = self
            .execution_group_sinks
            .get(name)
            .expect("realized group sinks");
        let observed = self.wait_for_discard_quiescence_for(sinks)?;
        self.status.discarded_by_sink.extend(observed);
        self.status.discarded_buffers = self.status.discarded_by_sink.values().sum();
        Ok(())
    }

    fn reset(&mut self, token: EffectToken) -> Result<(), ScientificDiagnostic> {
        let latest_hold_order = self.latest_hold_order.clone();
        self.request_latest_holds(
            &latest_hold_order,
            LatestHoldCommand::Pause,
            "pause latest/hold nodes before reset",
        )?;
        self.reset_numerical_graphs(token)
    }

    fn reset_numerical_graphs(&mut self, token: EffectToken) -> Result<(), ScientificDiagnostic> {
        let deadline = Instant::now() + CALLBACK_TIMEOUT;
        let _deadline = self.scoped_deadline(deadline);
        let wire_token = i64::try_from(token.value()).map_err(|_| {
            ScientificDiagnostic::new(
                "lifecycle effect token",
                format!(
                    "token {} does not fit the reset-control Long",
                    token.value()
                ),
            )
        })?;
        self.clear_errors();
        self.roundtrip("reset processing graphs")?;
        for graph in &self.controlled_graphs {
            graph.reset_events.borrow_mut().clear();
            let bytes = reset_control::build_request(wire_token).map_err(|error| {
                ScientificDiagnostic::new(
                    format!("graph {}.reset-control", graph.name),
                    error.to_string(),
                )
            })?;
            let pod = pw::spa::pod::Pod::from_bytes(&bytes).ok_or_else(|| {
                ScientificDiagnostic::new(
                    format!("graph {}.reset-control", graph.name),
                    "serialized request is not a complete SPA POD",
                )
            })?;
            graph
                .proxy
                .set_param(pw::spa::param::ParamType::Props, 0, pod);
        }
        loop {
            self.roundtrip("reset processing graphs")?;
            let completed = self
                .controlled_graphs
                .iter()
                .map(|graph| reset_reached_completion(graph, wire_token))
                .collect::<Result<Vec<_>, _>>()?
                .into_iter()
                .filter(|completed| *completed)
                .count();
            if completed == self.controlled_graphs.len() {
                return Ok(());
            }
            if !self.wait_for_callbacks(deadline, "reset processing graphs")? {
                break;
            }
        }
        Err(ScientificDiagnostic::new(
            "reset-control",
            format!("timed out waiting for reset token {wire_token}"),
        ))
    }

    /// Checks a property transaction before entering the lifecycle.
    ///
    /// # Errors
    /// Returns a diagnostic for an unrealized graph, undeclared or read-only
    /// property, incompatible scalar type, or malformed qualified name.
    pub fn validate_property_update(
        &self,
        graph_name: &str,
        values: &BTreeMap<String, ScalarValue>,
    ) -> Result<(), ScientificDiagnostic> {
        let graph = self.controlled_graph(graph_name)?;
        if values.is_empty()
            || values.keys().any(|name| {
                !matches!(name.split_once(':'), Some((node, property))
                    if !node.is_empty() && !property.is_empty())
            })
        {
            return Err(ScientificDiagnostic::new(
                format!("graph {graph_name}.properties"),
                "property update requires at least one qualified node:property name",
            ));
        }
        validate_property_declarations(graph_name, values, &graph.property_info.borrow())
    }

    fn update_properties(
        &mut self,
        graph_name: &str,
        values: &BTreeMap<String, ScalarValue>,
    ) -> Result<PropertyUpdateOutcome, ScientificDiagnostic> {
        let deadline = Instant::now() + CALLBACK_TIMEOUT;
        let _deadline = self.scoped_deadline(deadline);
        self.validate_property_update(graph_name, values)?;
        let affected_nodes = values
            .keys()
            .filter_map(|name| name.split_once(':').map(|(node, _)| node.to_owned()))
            .collect::<BTreeSet<_>>();
        let running = self.status.running;
        let graph = self.controlled_graph(graph_name)?;
        let baseline_generations = if running {
            let baseline = latest_property_snapshot(graph)?;
            affected_nodes
                .iter()
                .map(|node| {
                    property_generation(&baseline, node)
                        .map(|generation| (node.clone(), generation))
                })
                .collect::<Result<BTreeMap<_, _>, _>>()?
        } else {
            BTreeMap::new()
        };
        let bytes = build_property_update(values).map_err(|error| {
            ScientificDiagnostic::new(format!("graph {graph_name}.properties"), error)
        })?;
        let pod = pw::spa::pod::Pod::from_bytes(&bytes).ok_or_else(|| {
            ScientificDiagnostic::new(
                format!("graph {graph_name}.properties"),
                "serialized property transaction is not a complete SPA POD",
            )
        })?;
        self.clear_errors();
        graph
            .proxy
            .set_param(pw::spa::param::ParamType::Props, 0, pod);
        if !running {
            self.roundtrip(&format!("graph {graph_name} property submission"))?;
            return Ok(PropertyUpdateOutcome::Submitted);
        }
        loop {
            self.roundtrip(&format!("graph {graph_name} property transaction"))?;
            let snapshot = latest_property_snapshot(graph)?;
            let mut observed = BTreeMap::new();
            let mut complete = true;
            for node in &affected_nodes {
                let generation = property_generation(&snapshot, node)?;
                let baseline = baseline_generations[node];
                if generation.requested <= baseline.requested
                    || generation.active != Some(generation.requested)
                {
                    complete = false;
                    break;
                }
                observed.insert(
                    node.clone(),
                    PropertyGeneration {
                        requested: generation.requested,
                        active: Some(generation.requested),
                    },
                );
            }
            if complete {
                return Ok(PropertyUpdateOutcome::Active(observed));
            }
            if !self.wait_for_callbacks(
                deadline,
                &format!("graph {graph_name} property transaction"),
            )? {
                break;
            }
        }
        Err(ScientificDiagnostic::new(
            format!("graph {graph_name}.properties"),
            "timed out waiting for requested properties to become active",
        ))
    }

    fn controlled_graph(&self, graph_name: &str) -> Result<&ControlledGraph, ScientificDiagnostic> {
        self.controlled_graphs
            .iter()
            .find(|graph| graph.name == graph_name)
            .ok_or_else(|| {
                ScientificDiagnostic::new(
                    format!("graph {graph_name}"),
                    "graph is not realized under RTC control",
                )
            })
    }

    fn publish_initial_parameters(
        &mut self,
        config: &DevelopmentConfig,
    ) -> Result<(), ScientificDiagnostic> {
        for (input, configured_path) in &config.parameters {
            let (graph_name, parameter_name) =
                split_endpoint(input).expect("validated parameter target");
            let graph = config
                .graphs
                .iter()
                .find(|graph| graph.node_name == graph_name)
                .expect("validated parameter graph");
            let port = graph
                .ports
                .iter()
                .find(|port| port.name == parameter_name)
                .expect("validated parameter port");
            let path = resolve_file_reference(&format!("parameters.{input}"), configured_path)?;
            let bytes = std::fs::read(&path).map_err(|error| {
                ScientificDiagnostic::new(
                    format!("parameters.{input}"),
                    format!("cannot read {}: {error}", path.display()),
                )
            })?;
            self.update_parameter(
                graph_name,
                parameter_name,
                &NdArrayParameterValue {
                    element_type: port.element_type.clone(),
                    shape: port.shape.clone(),
                    schema: port.schema.clone(),
                    bytes: Arc::new(bytes),
                },
            )?;
        }
        Ok(())
    }

    /// Check a declared parameter replacement before entering the lifecycle.
    /// A pending value is an operator rejection, not a session failure.
    ///
    /// # Errors
    /// Returns a diagnostic for an undeclared/incompatible target or a busy publisher.
    pub fn validate_parameter_update(
        &self,
        graph_name: &str,
        parameter_name: &str,
        value: &NdArrayParameterValue,
    ) -> Result<(), ScientificDiagnostic> {
        let publisher = self.parameter_publisher_for_value(graph_name, parameter_name, value)?;
        if publisher.state.borrow().pending.is_some() {
            return Err(ScientificDiagnostic::new(
                format!("graph {graph_name}.ports.{parameter_name}"),
                "a parameter value is already pending; retry only after observing publication",
            ));
        }
        Ok(())
    }

    fn parameter_publisher_for_value(
        &self,
        graph_name: &str,
        parameter_name: &str,
        value: &NdArrayParameterValue,
    ) -> Result<&ParameterPublisher, ScientificDiagnostic> {
        let target = (graph_name.to_owned(), parameter_name.to_owned());
        let source_name = self.parameter_routes.get(&target).ok_or_else(|| {
            ScientificDiagnostic::new(
                format!("graph {graph_name}.ports.{parameter_name}"),
                "no runtime parameter source is declared for this graph input",
            )
        })?;
        let publisher = self
            .parameter_publishers
            .iter()
            .find(|publisher| publisher.node_name == *source_name)
            .ok_or_else(|| {
                ScientificDiagnostic::new(
                    format!("graph {graph_name}.ports.{parameter_name}"),
                    format!("runtime parameter source {source_name:?} is not realized"),
                )
            })?;
        if value.element_type != publisher.port.element_type
            || value.shape != publisher.port.shape
            || value.schema != publisher.port.schema
        {
            return Err(ScientificDiagnostic::new(
                format!("graph {graph_name}.ports.{parameter_name}.format"),
                format!(
                    "expected {} {:?} {:?}, got {} {:?} {:?}",
                    publisher.port.element_type,
                    publisher.port.shape,
                    publisher.port.schema,
                    value.element_type,
                    value.shape,
                    value.schema
                ),
            ));
        }
        let expected_bytes = publisher
            .port
            .shape
            .iter()
            .try_fold(size_of::<f32>(), |bytes, dimension| {
                bytes.checked_mul(*dimension as usize)
            })
            .ok_or_else(|| {
                ScientificDiagnostic::new(
                    format!("graph {graph_name}.ports.{parameter_name}.shape"),
                    "parameter byte count overflows addressable storage",
                )
            })?;
        if value.bytes.len() != expected_bytes {
            return Err(ScientificDiagnostic::new(
                format!("graph {graph_name}.ports.{parameter_name}.shape"),
                format!(
                    "expected {expected_bytes} payload bytes, got {}",
                    value.bytes.len()
                ),
            ));
        }
        Ok(publisher)
    }

    fn update_parameter(
        &mut self,
        graph_name: &str,
        parameter_name: &str,
        value: &NdArrayParameterValue,
    ) -> Result<(), ScientificDiagnostic> {
        let publisher = self.parameter_publisher_for_value(graph_name, parameter_name, value)?;
        {
            let mut state = publisher.state.borrow_mut();
            state.queue_payload(&value.bytes).map_err(|message| {
                ScientificDiagnostic::new(
                    format!("graph {graph_name}.ports.{parameter_name}"),
                    message,
                )
            })?;
        }
        if self.status.running {
            publisher.stream.trigger_process().map_err(|error| {
                ScientificDiagnostic::new(
                    format!("graph {graph_name}.ports.{parameter_name}"),
                    format!("cannot trigger parameter publication: {error}"),
                )
            })?;
        }
        Ok(())
    }

    fn trigger_pending_parameters(&self) -> Result<(), ScientificDiagnostic> {
        for publisher in &self.parameter_publishers {
            if publisher.state.borrow().pending.is_some() {
                publisher.stream.trigger_process().map_err(|error| {
                    ScientificDiagnostic::new(
                        format!("source {}", publisher.node_name),
                        format!("cannot trigger parameter publication: {error}"),
                    )
                })?;
            }
        }
        Ok(())
    }

    #[allow(clippy::too_many_lines)]
    fn bind_controlled_graphs(&mut self) -> Result<(), ScientificDiagnostic> {
        self.controlled_graphs.clear();
        for node_name in &self.graph_order {
            let global = self.node_global(node_name)?;
            let node = self
                .registry
                .bind::<pw::node::Node, _>(&global)
                .map_err(|error| {
                    ScientificDiagnostic::new(
                        format!("graph {node_name}.run-control"),
                        format!("cannot bind processing graph: {error}"),
                    )
                })?;
            let status_events = Rc::new(RefCell::new(Vec::new()));
            let observed = Rc::clone(&status_events);
            let reset_events = Rc::new(RefCell::new(Vec::new()));
            let observed_resets = Rc::clone(&reset_events);
            let property_events = Rc::new(RefCell::new(Vec::new()));
            let observed_properties = Rc::clone(&property_events);
            let property_info = Rc::new(RefCell::new(Vec::new()));
            let observed_property_info = Rc::clone(&property_info);
            let advertised_params = Rc::new(RefCell::new(None));
            let observed_params = Rc::clone(&advertised_params);
            let observed_initial_info = Rc::new(Cell::new(false));
            let initial_info = Rc::clone(&observed_initial_info);
            let listener = node
                .add_listener_local()
                .info(move |info| {
                    let first_info = !initial_info.replace(true);
                    if first_info
                        || info
                            .change_mask()
                            .contains(pw::node::NodeChangeMask::PARAMS)
                    {
                        *observed_params.borrow_mut() = Some(
                            info.params()
                                .iter()
                                .map(|param| (param.id(), param.flags()))
                                .collect(),
                        );
                    }
                })
                .param(move |_sequence, param_type, _index, _next, param| {
                    if param_type == pw::spa::param::ParamType::PropInfo {
                        if let Some(pod) = param {
                            observed_property_info
                                .borrow_mut()
                                .push(parse_property_info(pod));
                        }
                        return;
                    }
                    if param_type != pw::spa::param::ParamType::Props {
                        return;
                    }
                    let Some(pod) = param else {
                        observed
                            .borrow_mut()
                            .push(Err("owner published an empty Props parameter".to_owned()));
                        return;
                    };
                    match run_control::parse_status(pod) {
                        Ok(status) => observed.borrow_mut().push(Ok(status)),
                        Err(RunControlError::NotRunControl) => {
                            match reset_control::parse_status(pod) {
                                Ok(status) => observed_resets.borrow_mut().push(Ok(status)),
                                Err(ResetControlError::NotResetControl) => {
                                    observed_properties
                                        .borrow_mut()
                                        .push(parse_property_snapshot(pod));
                                }
                                Err(error) => {
                                    observed_resets.borrow_mut().push(Err(error.to_string()));
                                }
                            }
                        }
                        Err(error) => observed.borrow_mut().push(Err(error.to_string())),
                    }
                })
                .register();
            self.controlled_graphs.push(ControlledGraph {
                name: node_name.clone(),
                global_id: global.id,
                _listener: listener,
                proxy: node,
                status_events,
                reset_events,
                property_events,
                property_info,
                advertised_params,
            });
        }
        self.roundtrip("processing graph parameter capability discovery")?;
        for graph in &self.controlled_graphs {
            let ids = graph_param_subscription_ids(graph.advertised_params.borrow().as_deref())
                .map_err(|error| {
                    ScientificDiagnostic::new(format!("graph {}.params", graph.name), error)
                })?;
            graph.proxy.subscribe_params(&ids);
        }
        self.roundtrip("processing graph run-control discovery")?;
        for graph in &self.controlled_graphs {
            let events = graph.status_events.borrow();
            if events.len() != 1 {
                return Err(ScientificDiagnostic::new(
                    format!("graph {}.run-control", graph.name),
                    format!(
                        "expected one initial owner status, observed {} events",
                        events.len()
                    ),
                ));
            }
            let status = events[0].as_ref().map_err(|error| {
                ScientificDiagnostic::new(
                    format!("graph {}.run-control", graph.name),
                    error.clone(),
                )
            })?;
            if status.result != 0 || status.actual_state != RunState::Stopped {
                return Err(ScientificDiagnostic::new(
                    format!("graph {}.run-control", graph.name),
                    format!("owner is not ready and stopped: {status:?}"),
                ));
            }
            let reset_events = graph.reset_events.borrow();
            if reset_events.len() != 1 {
                return Err(ScientificDiagnostic::new(
                    format!("graph {}.reset-control", graph.name),
                    format!(
                        "expected one initial owner status, observed {} events",
                        reset_events.len()
                    ),
                ));
            }
            let reset_status = reset_events[0].as_ref().map_err(|error| {
                ScientificDiagnostic::new(
                    format!("graph {}.reset-control", graph.name),
                    error.clone(),
                )
            })?;
            if reset_status.completed_token != 0 || reset_status.result != 0 {
                return Err(ScientificDiagnostic::new(
                    format!("graph {}.reset-control", graph.name),
                    format!("owner is not ready for reset: {reset_status:?}"),
                ));
            }
            latest_property_snapshot(graph)?;
        }
        Ok(())
    }

    fn request_graphs(
        &mut self,
        graph_names: &[String],
        token: EffectToken,
        requested_state: RunState,
        label: &str,
    ) -> Result<(), ScientificDiagnostic> {
        let deadline = Instant::now() + CALLBACK_TIMEOUT;
        let _deadline = self.scoped_deadline(deadline);
        let wire_token = i64::try_from(token.value()).map_err(|_| {
            ScientificDiagnostic::new(
                "lifecycle effect token",
                format!("token {} does not fit the run-control Long", token.value()),
            )
        })?;
        self.roundtrip(label)?;
        for graph_name in graph_names {
            let graph = self
                .controlled_graphs
                .iter()
                .find(|graph| graph.name == *graph_name)
                .ok_or_else(|| {
                    ScientificDiagnostic::new(
                        format!("graph {graph_name}.run-control"),
                        "processing graph is not bound to its owner contract",
                    )
                })?;
            if !self
                .globals
                .borrow()
                .get(&graph.global_id)
                .is_some_and(|global| is_node_named(global, graph_name))
            {
                return Err(ScientificDiagnostic::new(
                    format!("graph {graph_name}.run-control"),
                    "required processing graph disappeared before the request",
                ));
            }
            graph.status_events.borrow_mut().clear();
            let bytes =
                run_control::build_request(wire_token, requested_state).map_err(|error| {
                    ScientificDiagnostic::new(
                        format!("graph {graph_name}.run-control"),
                        error.to_string(),
                    )
                })?;
            let pod = pw::spa::pod::Pod::from_bytes(&bytes).ok_or_else(|| {
                ScientificDiagnostic::new(
                    format!("graph {graph_name}.run-control"),
                    "serialized request is not a complete SPA POD",
                )
            })?;
            graph
                .proxy
                .set_param(pw::spa::param::ParamType::Props, 0, pod);
        }
        loop {
            self.roundtrip(label)?;
            let mut completed = 0;
            for graph in self
                .controlled_graphs
                .iter()
                .filter(|graph| graph_names.contains(&graph.name))
            {
                completed += usize::from(graph_reached_requested_state(
                    graph,
                    wire_token,
                    requested_state,
                )?);
            }
            if completed == graph_names.len() {
                return Ok(());
            }
            if !self.wait_for_callbacks(deadline, label)? {
                break;
            }
        }
        let status_events = self
            .controlled_graphs
            .iter()
            .filter(|graph| graph_names.contains(&graph.name))
            .map(|graph| (graph.name.as_str(), graph.status_events.borrow().clone()))
            .collect::<Vec<_>>();
        Err(ScientificDiagnostic::new(
            "run-control",
            format!(
                "timed out waiting for lifecycle token {wire_token} to reach {requested_state:?} on {graph_names:?}; status events {status_events:?}"
            ),
        ))
    }

    fn request_latest_holds(
        &self,
        node_names: &[String],
        command: LatestHoldCommand,
        label: &str,
    ) -> Result<(), ScientificDiagnostic> {
        if node_names.is_empty() {
            return Ok(());
        }
        for node_name in node_names {
            let node = self
                .latest_hold_nodes
                .iter()
                .find(|node| node.name == *node_name)
                .ok_or_else(|| {
                    ScientificDiagnostic::new(
                        format!("graph {node_name}.command"),
                        "latest/hold node is not bound to its standard SPA command surface",
                    )
                })?;
            if !self
                .globals
                .borrow()
                .get(&node.global_id)
                .is_some_and(|global| is_node_named(global, node_name))
            {
                return Err(ScientificDiagnostic::new(
                    format!("graph {node_name}.command"),
                    "required latest/hold node disappeared before the command",
                ));
            }
            node.proxy.send_command(&command.node_command());
        }
        // The public pw_node command method has no tokened completion reply.
        // A core roundtrip proves delivery and reports asynchronous core
        // errors without inventing a private acknowledgement protocol.
        self.roundtrip(label)
    }

    fn wait_for_links_active(&mut self, label: &str) -> Result<(), ScientificDiagnostic> {
        let mut states;
        let deadline = Instant::now() + Duration::from_millis(500);
        let _deadline = self.scoped_deadline(deadline);
        loop {
            self.roundtrip(label)?;
            states = self
                .links
                .iter()
                .map(|link| link.state.borrow().clone())
                .collect::<Vec<_>>();
            if states
                .iter()
                .all(|state| *state == LinkAdmissionState::Active)
            {
                return Ok(());
            }
            if !self.wait_for_callbacks(deadline, label)? {
                break;
            }
        }
        Err(ScientificDiagnostic::new(
            "topology",
            format!("required links did not all enter Active; observed states {states:?}"),
        ))
    }

    fn cleanup(&mut self, token: Option<EffectToken>) -> Result<(), ScientificDiagnostic> {
        let _deadline = self.scoped_deadline(Instant::now() + CALLBACK_TIMEOUT);
        let present_latest_holds = self
            .latest_hold_order
            .iter()
            .filter(|name| {
                self.latest_hold_nodes.iter().any(|node| {
                    node.name == **name
                        && self
                            .globals
                            .borrow()
                            .get(&node.global_id)
                            .is_some_and(|global| is_node_named(global, name))
                })
            })
            .cloned()
            .collect::<Vec<_>>();
        let present_graphs = self
            .graph_order
            .iter()
            .filter(|name| {
                self.controlled_graphs.iter().any(|graph| {
                    graph.name == **name
                        && self
                            .globals
                            .borrow()
                            .get(&graph.global_id)
                            .is_some_and(|global| is_node_named(global, name))
                })
            })
            .cloned()
            .collect::<Vec<_>>();
        let mut first_error = (!present_latest_holds.is_empty())
            .then(|| {
                self.request_latest_holds(
                    &present_latest_holds,
                    LatestHoldCommand::Pause,
                    "pause latest/hold nodes before cleanup",
                )
                .err()
            })
            .flatten();
        let graph_stop_error = token.and_then(|token| {
            (!present_graphs.is_empty())
                .then(|| {
                    self.request_graphs(
                        &present_graphs,
                        token,
                        RunState::Stopped,
                        "stop processing graphs before cleanup",
                    )
                    .err()
                })
                .flatten()
        });
        if let Some(error) = graph_stop_error {
            first_error.get_or_insert(error);
        }
        self.status.running = false;
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

        self.controlled_graphs.clear();
        if let Err(error) = self.roundtrip("processing graph control release") {
            first_error.get_or_insert(error);
        }
        self.latest_hold_nodes.clear();
        self.spa_nodes.clear();
        self.parameter_publishers.clear();
        self.modules.clear();
        if let Err(error) = self.wait_for_owned_nodes_removed() {
            first_error.get_or_insert(error);
        }
        self.status = LiveGraphStatus::default();
        self.owned_node_names.clear();
        self.required_node_names.clear();
        self.required_external_objects.clear();
        self.finite_source_names.clear();
        self.has_external_source = false;
        self.graph_order.clear();
        self.latest_hold_order.clear();
        self.sink_names.clear();
        self.execution_group_nodes.clear();
        self.execution_group_latest_holds.clear();
        self.execution_group_sinks.clear();
        self.parameter_routes.clear();
        self.expected_objects = 0;
        self.expected_links = 0;
        match first_error {
            Some(error) => Err(error),
            None => Ok(()),
        }
    }

    fn wait_for_owned_nodes_removed(&self) -> Result<(), ScientificDiagnostic> {
        let deadline = Instant::now() + Duration::from_millis(500);
        let _deadline = self.scoped_deadline(deadline);
        loop {
            self.roundtrip("runner-owned node cleanup")?;
            if self.count_owned_nodes() == 0 {
                return Ok(());
            }
            if !self.wait_for_callbacks(deadline, "runner-owned node cleanup")? {
                break;
            }
        }
        let remaining = self
            .owned_node_names
            .iter()
            .filter(|name| {
                self.globals
                    .borrow()
                    .values()
                    .any(|global| is_node_named(global, name))
            })
            .cloned()
            .collect::<Vec<_>>();
        Err(ScientificDiagnostic::new(
            "cleanup",
            format!("runner-owned nodes remain visible after unload: {remaining:?}"),
        ))
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

    fn create_source(
        &mut self,
        source: &ObjectSpec<EndpointFactory>,
        field: &str,
    ) -> Result<(), ScientificDiagnostic> {
        match source.realization {
            ObjectRealization::Factory(EndpointFactory::SimulatedCompleteFrameSource) => {
                let arguments = read_module_arguments(
                    &format!("{field}.config.path"),
                    source
                        .configuration_path
                        .as_deref()
                        .expect("simulated source configuration was validated"),
                )?;
                self.load_owned_module(
                    ObjectRole::Source,
                    source
                        .module
                        .as_deref()
                        .expect("source module was validated"),
                    &arguments,
                    &source.node_name,
                )
            }
            ObjectRealization::Factory(EndpointFactory::FitsCompleteFrameSource) => {
                let plugin = resolve_artifact(
                    &format!("{field}.plugin.path"),
                    source
                        .plugin_path
                        .as_deref()
                        .expect("FITS plugin path was validated"),
                    "PIPEWIREAO_FITS_PLUGIN",
                )?;
                self.create_owned_spa_source(source, field, &plugin)
            }
            ObjectRealization::Factory(EndpointFactory::RuntimeParameterSource) => {
                self.create_parameter_publisher(source, field)
            }
            ObjectRealization::Factory(EndpointFactory::FormatAgnosticDiscardSink) => {
                unreachable!("validated source cannot use a sink factory")
            }
            ObjectRealization::External { .. } => {
                self.wait_for_external_object(ObjectRole::Source, &source.node_name)
            }
        }
    }

    #[allow(clippy::too_many_lines)]
    fn create_parameter_publisher(
        &mut self,
        source: &ObjectSpec<EndpointFactory>,
        field: &str,
    ) -> Result<(), ScientificDiagnostic> {
        let port = source.ports[0].clone();
        let stride = parameter_stride(&port).map_err(|message| {
            ScientificDiagnostic::new(format!("{field}.ports.{}.shape", port.name), message)
        })?;
        let state = Rc::new(RefCell::new(ParameterProcessState {
            stride,
            ..ParameterProcessState::default()
        }));
        let properties = [
            ("node.name", source.node_name.as_str()),
            (
                "node.description",
                "PipeWireAO RTC ndarray parameter source",
            ),
            ("media.type", "Application"),
            ("media.category", "Playback"),
            ("media.role", "DSP"),
            ("node.virtual", "true"),
            ("object.linger", "false"),
        ]
        .into_iter()
        .collect::<PropertiesBox>();
        let stream = pw::stream::StreamRc::new(
            self.core.clone(),
            &format!("{} parameter output", source.node_name),
            properties,
        )
        .map_err(|error| {
            ScientificDiagnostic::new(
                format!("{field}.factory"),
                format!("cannot create runtime parameter stream: {error}"),
            )
        })?;
        let callback_state = Rc::clone(&state);
        let listener = stream
            .add_local_listener_with_user_data(callback_state)
            .state_changed(|_, state, _, current| {
                if let pw::stream::StreamState::Error(error) = current {
                    state.borrow_mut().failure = Some(error);
                }
            })
            .process(|stream, state| {
                let payload = state.borrow_mut().pending.take();
                let Some(payload) = payload else {
                    return;
                };
                let Some(mut buffer) = stream.dequeue_buffer() else {
                    state.borrow_mut().pending = Some(payload);
                    return;
                };
                let Some(data) = buffer.datas_mut().first_mut() else {
                    state.borrow_mut().failure =
                        Some("parameter buffer has no data plane".to_owned());
                    return;
                };
                let Some(storage) = data.data() else {
                    state.borrow_mut().failure = Some("parameter buffer is not mapped".to_owned());
                    return;
                };
                if storage.len() < payload.len() {
                    state.borrow_mut().failure = Some(format!(
                        "parameter buffer capacity {} is smaller than {} bytes",
                        storage.len(),
                        payload.len()
                    ));
                    return;
                }
                let Ok(payload_size) = u32::try_from(payload.len()) else {
                    state.borrow_mut().failure = Some(format!(
                        "parameter payload {} exceeds the SPA chunk size range",
                        payload.len()
                    ));
                    return;
                };
                storage[..payload.len()].copy_from_slice(payload.as_slice());
                let state = state.borrow();
                let chunk = data.chunk_mut();
                *chunk.offset_mut() = 0;
                *chunk.size_mut() = payload_size;
                *chunk.stride_mut() = state.stride;
            })
            .register()
            .map_err(|error| {
                ScientificDiagnostic::new(
                    format!("{field}.factory"),
                    format!("cannot observe runtime parameter stream: {error}"),
                )
            })?;
        let parameters = parameter_stream_parameters(&port).map_err(|message| {
            ScientificDiagnostic::new(format!("{field}.ports.{}.format", port.name), message)
        })?;
        let mut pods = parameters.pods();
        stream
            .connect(
                pw::spa::utils::Direction::Output,
                None,
                pw::stream::StreamFlags::MAP_BUFFERS
                    | pw::stream::StreamFlags::NO_CONVERT
                    | pw::stream::StreamFlags::DONT_RECONNECT,
                &mut pods,
            )
            .map_err(|error| {
                ScientificDiagnostic::new(
                    format!("{field}.ports.{}.format", port.name),
                    format!("cannot connect runtime parameter stream: {error}"),
                )
            })?;
        stream.set_active(true).map_err(|error| {
            ScientificDiagnostic::new(
                format!("{field}.factory"),
                format!("cannot activate runtime parameter stream: {error}"),
            )
        })?;
        self.parameter_publishers.push(ParameterPublisher {
            node_name: source.node_name.clone(),
            port,
            _listener: listener,
            stream,
            state,
        });
        self.wait_for_owned_node(ObjectRole::Source, &source.node_name)
    }

    fn create_graph(
        &mut self,
        graph: &ObjectSpec<GraphFactory>,
        field: &str,
    ) -> Result<(), ScientificDiagnostic> {
        match graph.realization {
            ObjectRealization::Factory(GraphFactory::FgnNative) => {
                let arguments = read_module_arguments(
                    &format!("{field}.config.path"),
                    graph
                        .configuration_path
                        .as_deref()
                        .expect("graph configuration was validated"),
                )?;
                self.load_owned_module(
                    ObjectRole::Graph,
                    graph.module.as_deref().expect("graph module was validated"),
                    &arguments,
                    &graph.node_name,
                )
            }
            ObjectRealization::Factory(GraphFactory::NdarrayLatestHold) => {
                let plugin = resolve_artifact(
                    &format!("{field}.plugin.path"),
                    graph
                        .plugin_path
                        .as_deref()
                        .expect("latest/hold plugin path was validated"),
                    "PIPEWIREAO_NDARRAY_PLUGIN",
                )?;
                self.create_owned_latest_hold(graph, field, &plugin)
            }
            ObjectRealization::External { .. } => {
                self.wait_for_external_object(ObjectRole::Graph, &graph.node_name)
            }
        }
    }

    fn create_owned_latest_hold(
        &mut self,
        graph: &ObjectSpec<GraphFactory>,
        field: &str,
        plugin: &Path,
    ) -> Result<(), ScientificDiagnostic> {
        if plugin.file_name().and_then(|name| name.to_str()) != Some(NDARRAY_LIBRARY_FILE) {
            return Err(ScientificDiagnostic::new(
                format!("{field}.plugin.path"),
                format!(
                    "expected maintained ndarray plugin {NDARRAY_LIBRARY_FILE:?}, got {}",
                    plugin.display()
                ),
            ));
        }
        let factory = match graph.realization {
            ObjectRealization::Factory(factory) => factory,
            ObjectRealization::External { .. } => unreachable!("owned latest/hold node"),
        };
        let mut properties = PropertiesBox::new();
        properties.insert("factory.name", factory.configured_name());
        properties.insert("library.name", NDARRAY_LIBRARY);
        properties.insert("node.name", graph.node_name.as_str());
        properties.insert("node.description", "PipeWireAO RTC ndarray latest/hold");
        properties.insert("node.virtual", "true");
        properties.insert("node.want-driver", "false");
        // Live Props counters must reach the SPA node after a broad param query.
        properties.insert("node.cache-params", "false");
        properties.insert("object.linger", "false");
        for (name, value) in &graph.arguments {
            properties.insert(name.as_str(), value.as_str());
        }
        let node = self
            .core
            .create_object::<pw::node::Node>(SPA_NODE_FACTORY, &properties)
            .map_err(|error| {
                ScientificDiagnostic::new(
                    format!("{field}.factory"),
                    format!(
                        "PipeWire spa-node-factory rejected {:?}: {error}",
                        factory.configured_name()
                    ),
                )
            })?;
        let observed_factory = Rc::new(RefCell::new(None));
        let observed = Rc::clone(&observed_factory);
        let listener = node
            .add_listener_local()
            .info(move |info| {
                if let Some(factory) = info
                    .props()
                    .and_then(|properties| properties.get("factory.name"))
                {
                    *observed.borrow_mut() = Some(factory.to_owned());
                }
            })
            .register();
        self.wait_for_owned_node(ObjectRole::Graph, &graph.node_name)?;
        let global = self.node_global(&graph.node_name)?;
        self.roundtrip(&format!("{field} NodeInfo factory identity"))?;
        let observed_factory = observed_factory.borrow().clone();
        validate_node_factory_identity(
            field,
            observed_factory.as_deref(),
            factory.configured_name(),
        )?;
        self.latest_hold_nodes.push(LatestHoldNode {
            name: graph.node_name.clone(),
            global_id: global.id,
            _listener: listener,
            proxy: node,
        });
        Ok(())
    }

    fn create_sink(
        &mut self,
        sink: &ObjectSpec<EndpointFactory>,
        field: &str,
    ) -> Result<(), ScientificDiagnostic> {
        match sink.realization {
            ObjectRealization::Factory(EndpointFactory::FormatAgnosticDiscardSink) => {
                let plugin = resolve_artifact(
                    &format!("{field}.plugin.path"),
                    sink.plugin_path
                        .as_deref()
                        .expect("discard plugin path was validated"),
                    "PIPEWIREAO_DISCARD_PLUGIN",
                )?;
                self.create_owned_spa_sink(sink, field, &plugin)
            }
            ObjectRealization::External { .. } => {
                self.wait_for_external_object(ObjectRole::Sink, &sink.node_name)
            }
            ObjectRealization::Factory(_) => unreachable!("validated sink factory"),
        }
    }

    fn create_owned_spa_sink(
        &mut self,
        sink: &ObjectSpec<EndpointFactory>,
        field: &str,
        plugin: &Path,
    ) -> Result<(), ScientificDiagnostic> {
        if plugin.file_name().and_then(|name| name.to_str()) != Some(DISCARD_LIBRARY_FILE) {
            return Err(ScientificDiagnostic::new(
                format!("{field}.plugin.path"),
                format!(
                    "expected maintained discard plugin {DISCARD_LIBRARY_FILE:?}, got {}",
                    plugin.display()
                ),
            ));
        }
        let mut properties = [
            (
                "factory.name",
                match sink.realization {
                    ObjectRealization::Factory(factory) => factory.configured_name(),
                    ObjectRealization::External { .. } => unreachable!("owned SPA sink"),
                },
            ),
            ("library.name", DISCARD_LIBRARY),
            ("node.name", sink.node_name.as_str()),
            (
                "node.description",
                "PipeWireAO RTC non-actuating discard sink",
            ),
            ("node.virtual", "true"),
            ("node.want-driver", "true"),
            // Lifecycle progress needs live counters after broad Props queries.
            ("node.cache-params", "false"),
            ("object.linger", "false"),
        ]
        .into_iter()
        .collect::<PropertiesBox>();
        // Endpoint admission permits only the public loop-placement property.
        // The daemon remains responsible for applying that loop's policy.
        for (name, value) in &sink.arguments {
            properties.insert(name.as_str(), value.as_str());
        }
        let node = self
            .core
            .create_object::<pw::node::Node>(SPA_NODE_FACTORY, &properties)
            .map_err(|error| {
                ScientificDiagnostic::new(
                    format!("{field}.factory"),
                    format!(
                        "PipeWire spa-node-factory rejected {:?}: {error}",
                        match sink.realization {
                            ObjectRealization::Factory(factory) => factory.configured_name(),
                            ObjectRealization::External { .. } => unreachable!("owned SPA sink"),
                        }
                    ),
                )
            })?;
        self.spa_nodes.push(node);
        self.wait_for_owned_node(ObjectRole::Sink, &sink.node_name)
    }

    fn create_owned_spa_source(
        &mut self,
        source: &ObjectSpec<EndpointFactory>,
        field: &str,
        plugin: &Path,
    ) -> Result<(), ScientificDiagnostic> {
        if plugin.file_name().and_then(|name| name.to_str()) != Some(FITS_LIBRARY_FILE) {
            return Err(ScientificDiagnostic::new(
                format!("{field}.plugin.path"),
                format!(
                    "expected maintained FITS plugin {FITS_LIBRARY_FILE:?}, got {}",
                    plugin.display()
                ),
            ));
        }
        let image = resolve_file_reference(
            &format!("{field}.args.api.fits.path"),
            source
                .arguments
                .get("api.fits.path")
                .expect("FITS path argument was validated"),
        )?;
        let image = image.to_str().ok_or_else(|| {
            ScientificDiagnostic::new(
                format!("{field}.args.api.fits.path"),
                "resolved FITS path is not valid UTF-8",
            )
        })?;
        let mut properties = PropertiesBox::new();
        let factory = match source.realization {
            ObjectRealization::Factory(factory) => factory,
            ObjectRealization::External { .. } => unreachable!("owned SPA source"),
        };
        properties.insert("factory.name", factory.configured_name());
        properties.insert("node.name", source.node_name.as_str());
        properties.insert(
            "node.description",
            "PipeWireAO RTC recorded complete-frame source",
        );
        properties.insert("node.virtual", "true");
        properties.insert("object.linger", "false");
        for (name, configured) in &source.arguments {
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
                    format!("{field}.factory"),
                    format!(
                        "PipeWire spa-node-factory rejected {:?}: {error}",
                        factory.configured_name()
                    ),
                )
            })?;
        self.spa_nodes.push(node);
        self.wait_for_owned_node(ObjectRole::Source, &source.node_name)
    }

    fn wait_for_owned_node(
        &self,
        role: ObjectRole,
        node_name: &str,
    ) -> Result<(), ScientificDiagnostic> {
        let deadline = Instant::now() + Duration::from_millis(500);
        let _deadline = self.scoped_deadline(deadline);
        loop {
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
            if !self.wait_for_callbacks(deadline, &format!("{} node creation", role.name()))? {
                break;
            }
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

    fn wait_for_external_object(
        &self,
        role: ObjectRole,
        node_name: &str,
    ) -> Result<(), ScientificDiagnostic> {
        let deadline = Instant::now() + Duration::from_millis(500);
        let _deadline = self.scoped_deadline(deadline);
        loop {
            self.roundtrip(&format!("external {} discovery", role.name()))?;
            let globals = self.globals.borrow();
            let matches = globals
                .values()
                .filter(|global| is_node_named(global, node_name))
                .collect::<Vec<_>>();
            if matches.len() == 1 {
                return Ok(());
            }
            if matches.len() > 1 {
                return Err(ScientificDiagnostic::new(
                    format!("{}.node.name", role.name()),
                    format!("external node name {node_name:?} is not unique"),
                ));
            }
            drop(globals);
            if !self.wait_for_callbacks(deadline, &format!("external {} discovery", role.name()))? {
                break;
            }
        }
        Err(ScientificDiagnostic::new(
            format!("{}.node.name", role.name()),
            format!("required external node {node_name:?} is not inspectable"),
        ))
    }

    fn discard_buffer_counts(&self) -> Result<BTreeMap<String, u64>, ScientificDiagnostic> {
        self.discard_buffer_counts_for(&self.sink_names)
    }

    fn fits_source_completed(&self, source_name: &str) -> Result<bool, ScientificDiagnostic> {
        let global = self.node_global(source_name)?;
        let node = self
            .registry
            .bind::<pw::node::Node, _>(&global)
            .map_err(|error| {
                ScientificDiagnostic::new(
                    format!("source {source_name}.{}", pw::fits::COMPLETED_PROPERTY_NAME),
                    format!("cannot bind FITS source status: {error}"),
                )
            })?;
        let result = Rc::new(RefCell::new(None));
        let observed = Rc::clone(&result);
        let _listener = node
            .add_listener_local()
            .param(move |_sequence, param_type, _index, _next, param| {
                if param_type != pw::spa::param::ParamType::Props {
                    return;
                }
                let value = param
                    .ok_or_else(|| "FITS source returned an empty Props parameter".to_owned())
                    .and_then(|pod| {
                        pod.as_object()
                            .map_err(|error| format!("FITS Props is not an object: {error}"))
                    })
                    .and_then(|object| {
                        object
                            .find_prop(pw::spa::utils::Id(pw::fits::COMPLETED_PROPERTY))
                            .ok_or_else(|| {
                                format!("{} is missing", pw::fits::COMPLETED_PROPERTY_NAME)
                            })
                    })
                    .and_then(|property| {
                        property.value().get_bool().map_err(|error| {
                            format!(
                                "{} is not a Bool: {error}",
                                pw::fits::COMPLETED_PROPERTY_NAME
                            )
                        })
                    });
                *observed.borrow_mut() = Some(value);
            })
            .register();
        node.enum_params(
            FITS_STATUS_SEQUENCE,
            Some(pw::spa::param::ParamType::Props),
            0,
            1,
        );
        self.roundtrip(&format!(
            "source {source_name}.{}",
            pw::fits::COMPLETED_PROPERTY_NAME
        ))?;
        let completed = result
            .borrow_mut()
            .take()
            .ok_or_else(|| {
                ScientificDiagnostic::new(
                    format!("source {source_name}.{}", pw::fits::COMPLETED_PROPERTY_NAME),
                    "FITS source did not return its completion parameter",
                )
            })?
            .map_err(|message| {
                ScientificDiagnostic::new(
                    format!("source {source_name}.{}", pw::fits::COMPLETED_PROPERTY_NAME),
                    message,
                )
            })?;
        Ok(completed)
    }

    fn discard_buffer_counts_for(
        &self,
        sink_names: &[String],
    ) -> Result<BTreeMap<String, u64>, ScientificDiagnostic> {
        sink_names
            .iter()
            .map(|sink_name| {
                self.discard_counter(sink_name, pw::discard::DiscardMetric::Buffers)
                    .map(|value| (sink_name.clone(), value))
            })
            .collect()
    }

    fn discard_counter(
        &self,
        sink_name: &str,
        metric: pw::discard::DiscardMetric,
    ) -> Result<u64, ScientificDiagnostic> {
        let value = self.discard_metric_long(sink_name, metric)?;
        u64::try_from(value).map_err(|_| {
            ScientificDiagnostic::new(
                format!("sink {sink_name}.{}", metric.name()),
                format!("discard counter is negative: {value}"),
            )
        })
    }

    fn discard_metric_long(
        &self,
        sink_name: &str,
        metric: pw::discard::DiscardMetric,
    ) -> Result<i64, ScientificDiagnostic> {
        let property_id = metric.property_id();
        let metric_name = metric.name().to_owned();
        let callback_metric_name = metric_name.clone();
        let global = self.node_global(sink_name)?;
        let node = self
            .registry
            .bind::<pw::node::Node, _>(&global)
            .map_err(|error| {
                ScientificDiagnostic::new(
                    format!("sink {sink_name}.{metric_name}"),
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
        self.roundtrip(&format!("sink {sink_name}.{metric_name}"))?;
        let result = result.borrow_mut().take().ok_or_else(|| {
            ScientificDiagnostic::new(
                format!("sink {sink_name}.{metric_name}"),
                format!(
                    "discard sink did not return its metrics parameter; parameter events {:?}",
                    events.borrow()
                ),
            )
        })?;
        result.map_err(|message| {
            ScientificDiagnostic::new(format!("sink {sink_name}.{metric_name}"), message)
        })
    }

    fn wait_for_discarded_buffers(
        &self,
        previous: &BTreeMap<String, u64>,
    ) -> Result<BTreeMap<String, u64>, ScientificDiagnostic> {
        let mut observed;
        let deadline = Instant::now() + CALLBACK_TIMEOUT;
        let _deadline = self.scoped_deadline(deadline);
        loop {
            observed = self.discard_buffer_counts()?;
            if previous
                .iter()
                .all(|(sink, before)| observed.get(sink).is_some_and(|after| after > before))
            {
                return Ok(observed);
            }
            if !self.wait_for_callbacks(deadline, "discard buffer progress")? {
                break;
            }
        }
        let stalled = previous
            .iter()
            .filter(|(sink, before)| observed.get(*sink).map_or(true, |after| after <= *before))
            .map(|(sink, before)| {
                let process_calls = self
                    .discard_counter(sink, pw::discard::DiscardMetric::ProcessCalls)
                    .unwrap_or(0);
                format!("{sink} remained at {before} after {process_calls} process calls")
            })
            .collect::<Vec<_>>();
        Err(ScientificDiagnostic::new(
            "sinks.discard.buffers",
            format!(
                "no complete buffer reached every discard sink after start: {}",
                stalled.join("; ")
            ),
        ))
    }

    fn wait_for_discard_quiescence(&self) -> Result<BTreeMap<String, u64>, ScientificDiagnostic> {
        self.wait_for_discard_quiescence_for(&self.sink_names)
    }

    fn wait_for_discard_quiescence_for(
        &self,
        sink_names: &[String],
    ) -> Result<BTreeMap<String, u64>, ScientificDiagnostic> {
        let deadline = Instant::now() + Duration::from_millis(500);
        let _deadline = self.scoped_deadline(deadline);
        let mut previous = self.discard_buffer_counts_for(sink_names)?;
        let mut stable_samples = 0;
        while Instant::now() < deadline {
            // Stability samples retain their 5 ms spacing while callbacks
            // continue to run between observations.
            let sample_deadline = Instant::now() + Duration::from_millis(5);
            if sample_deadline > deadline {
                break;
            }
            while self.wait_for_callbacks(sample_deadline, "discard quiescence")? {}
            let observed = self.discard_buffer_counts_for(sink_names)?;
            if observed == previous {
                stable_samples += 1;
                if stable_samples == 3 {
                    return Ok(observed);
                }
            } else {
                stable_samples = 0;
                previous = observed;
            }
        }
        Err(ScientificDiagnostic::new(
            "stop",
            format!("discard counters did not quiesce after PAUSE; last counts {previous:?}"),
        ))
    }

    fn validate_live_ports(&self, config: &DevelopmentConfig) -> Result<(), ScientificDiagnostic> {
        let expected = config
            .sources
            .iter()
            .map(|object| (ObjectRole::Source, &object.node_name, &object.ports))
            .chain(
                config
                    .graphs
                    .iter()
                    .map(|object| (ObjectRole::Graph, &object.node_name, &object.ports)),
            )
            .chain(
                config
                    .sinks
                    .iter()
                    .map(|object| (ObjectRole::Sink, &object.node_name, &object.ports)),
            );
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
                let is_discard_sink = role == ObjectRole::Sink
                    && config.sinks.iter().any(|sink| {
                        sink.node_name == *node_name && !sink.realization.is_external()
                    });
                if is_discard_sink {
                    validate_discard_wildcard(&format, role, &port.name)?;
                } else {
                    validate_ndarray_port(
                        &format,
                        role,
                        port,
                        configured_port_rate(config, port)?,
                    )?;
                }
            }
        }
        Ok(())
    }

    fn capture_required_external_objects(
        &self,
        config: &DevelopmentConfig,
    ) -> Result<Vec<RequiredExternalObject>, ScientificDiagnostic> {
        let expected = config
            .sources
            .iter()
            .filter(|object| object.realization.is_external())
            .map(|object| (ObjectRole::Source, &object.node_name, &object.ports))
            .chain(
                config
                    .graphs
                    .iter()
                    .filter(|object| object.realization.is_external())
                    .map(|object| (ObjectRole::Graph, &object.node_name, &object.ports)),
            )
            .chain(
                config
                    .sinks
                    .iter()
                    .filter(|object| object.realization.is_external())
                    .map(|object| (ObjectRole::Sink, &object.node_name, &object.ports)),
            );
        expected
            .map(|(role, node_name, ports)| {
                let node = self.node_global(node_name)?;
                let ports = ports
                    .iter()
                    .map(|specification| {
                        let port = self.port_global(
                            node.id,
                            &specification.name,
                            specification.direction,
                        )?;
                        Ok(RequiredExternalPort {
                            global_id: port.id,
                            specification: specification.clone(),
                            expected_rate: configured_port_rate(config, specification)?,
                        })
                    })
                    .collect::<Result<Vec<_>, ScientificDiagnostic>>()?;
                Ok(RequiredExternalObject {
                    role,
                    node_name: node_name.clone(),
                    global_id: node.id,
                    ports,
                })
            })
            .collect()
    }

    fn check_external_object_contracts(&mut self) -> Result<(), ScientificDiagnostic> {
        if self.required_external_objects.is_empty() {
            return Ok(());
        }
        self.clear_errors();
        let synchronization_error = self.roundtrip("required external object monitor").err();
        for object in &self.required_external_objects {
            let node = self
                .globals
                .borrow()
                .get(&object.global_id)
                .map(GlobalObject::to_owned)
                .filter(|global| is_node_named(global, &object.node_name))
                .ok_or_else(|| {
                    ScientificDiagnostic::new(
                        format!("{} {}.node.name", object.role.name(), object.node_name),
                        format!(
                            "required external node {} disappeared or was replaced",
                            object.global_id
                        ),
                    )
                })?;
            for required_port in &object.ports {
                let specification = &required_port.specification;
                let port = self
                    .globals
                    .borrow()
                    .get(&required_port.global_id)
                    .map(GlobalObject::to_owned)
                    .filter(|global| {
                        if global.type_ != ObjectType::Port {
                            return false;
                        }
                        let Some(properties) = global.props.as_ref() else {
                            return false;
                        };
                        let direction = match specification.direction {
                            PortDirection::Input => "in",
                            PortDirection::Output => "out",
                        };
                        properties.get("node.id") == Some(node.id.to_string().as_str())
                            && properties.get("port.direction") == Some(direction)
                            && properties.get("port.name").is_some_and(|name| {
                                name == specification.name
                                    || name.ends_with(&format!(":{}", specification.name))
                            })
                    })
                    .ok_or_else(|| {
                        ScientificDiagnostic::new(
                            format!(
                                "{} {}.ports.{}",
                                object.role.name(),
                                object.node_name,
                                specification.name
                            ),
                            format!(
                                "required external port {} disappeared, was replaced, or changed identity",
                                required_port.global_id
                            ),
                        )
                    })?;
                let format = self.enumerate_port_format(object.role, &specification.name, &port)?;
                validate_ndarray_port(
                    &format,
                    object.role,
                    specification,
                    required_port.expected_rate,
                )?;
            }
        }
        match synchronization_error {
            Some(error) => Err(error),
            None => Ok(()),
        }
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
        let observed = formats.borrow_mut().drain(..).collect();
        select_ndarray_format(observed, &field)
    }

    fn create_link(
        &mut self,
        index: usize,
        output: &str,
        input: &str,
        passive: bool,
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
        let mut properties = [
            ("link.output.node", output_node_id.to_string()),
            ("link.output.port", output_port_id.to_string()),
            ("link.input.node", input_node_id.to_string()),
            ("link.input.port", input_port_id.to_string()),
        ]
        .into_iter()
        .collect::<PropertiesBox>();
        if passive {
            properties.insert("link.passive", "true");
        }

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
        let observed_passive = Rc::new(RefCell::new(None));
        let callback_passive = Rc::clone(&observed_passive);
        let listener = link
            .add_listener_local()
            .info(move |info| {
                if let Some(value) = info
                    .props()
                    .and_then(|properties| properties.get("link.passive"))
                {
                    *callback_passive.borrow_mut() = Some(value.to_owned());
                }
                *observed.borrow_mut() = match info.state() {
                    pw::link::LinkState::Error(error) => {
                        LinkAdmissionState::Failed(error.to_owned())
                    }
                    pw::link::LinkState::Unlinked => {
                        LinkAdmissionState::Failed("link became unlinked".to_owned())
                    }
                    pw::link::LinkState::Paused => LinkAdmissionState::Paused,
                    pw::link::LinkState::Active => LinkAdmissionState::Active,
                    pending => LinkAdmissionState::Pending(format!("{pending:?}")),
                };
            })
            .register();
        self.links.push(LiveLink {
            listener,
            proxy: link,
            state: Rc::clone(&state),
        });

        let label = format!("links[{index}] {output} -> {input}");
        let deadline = Instant::now() + Duration::from_millis(500);
        let _deadline = self.scoped_deadline(deadline);
        loop {
            self.roundtrip(&label)?;
            match state.borrow().clone() {
                LinkAdmissionState::Paused | LinkAdmissionState::Active => {
                    let retained_passive = observed_passive.borrow().as_deref() == Some("true");
                    if retained_passive != passive {
                        return Err(ScientificDiagnostic::new(
                            format!("links[{index}].passive"),
                            format!(
                                "configured link.passive={passive}, but the public PipeWire link reports {:?}",
                                observed_passive.borrow().as_deref()
                            ),
                        ));
                    }
                    return Ok(());
                }
                LinkAdmissionState::Failed(error) => {
                    return Err(ScientificDiagnostic::new(label, error));
                }
                LinkAdmissionState::Unknown | LinkAdmissionState::Pending(_) => {}
            }
            if !self.wait_for_callbacks(deadline, &label)? {
                break;
            }
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

    /// Waits for callback activity or the next 5 ms condition check.
    /// Returns false once the wall-clock deadline has expired.
    fn wait_for_callbacks(
        &self,
        deadline: Instant,
        field: &str,
    ) -> Result<bool, ScientificDiagnostic> {
        let deadline = self
            .callback_deadline
            .lock()
            .expect("control deadline poisoned")
            .effective()
            .map_or(deadline, |outer| outer.min(deadline));
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Ok(false);
        }
        iterate_callbacks(
            self.main_loop.loop_(),
            remaining.min(Duration::from_millis(5)),
            field,
        )?;
        Ok(true)
    }

    fn roundtrip(&self, field: &str) -> Result<(), ScientificDiagnostic> {
        self.roundtrip_until(Instant::now() + CALLBACK_TIMEOUT, field)
    }

    fn scoped_deadline(&self, deadline: Instant) -> DeadlineGuard {
        DeadlineGuard::new(Arc::clone(&self.callback_deadline), deadline)
    }

    fn roundtrip_until(&self, deadline: Instant, field: &str) -> Result<(), ScientificDiagnostic> {
        let _deadline = self.scoped_deadline(deadline);
        let deadline = self
            .callback_deadline
            .lock()
            .expect("control deadline poisoned")
            .effective()
            .expect("deadline scope installed");
        if Instant::now() >= deadline {
            return Err(ScientificDiagnostic::new(
                field,
                "PipeWire synchronization deadline expired before submission",
            ));
        }
        let completed = Rc::new(Cell::new(false));
        let observed = Rc::clone(&completed);
        let pending = self.core.sync(0).map_err(|error| {
            ScientificDiagnostic::new(field, format!("PipeWire sync failed: {error}"))
        })?;
        let _listener = self
            .core
            .add_listener_local()
            .done(move |id, sequence| {
                if id == pw::core::PW_ID_CORE && sequence == pending {
                    observed.set(true);
                }
            })
            .register();
        loop {
            // Admission during iterate_callbacks can shorten the shared scope.
            // Re-read it instead of retaining a five-second entry snapshot.
            let deadline = self
                .callback_deadline
                .lock()
                .expect("control deadline poisoned")
                .effective()
                .map_or(deadline, |active| active.min(deadline));
            let errors = std::mem::take(&mut *self.errors.borrow_mut());
            if !errors.is_empty() {
                return Err(ScientificDiagnostic::new(
                    field,
                    format!("PipeWire operation failed: {}", errors.join("; ")),
                ));
            }
            if Instant::now() >= deadline {
                return Err(ScientificDiagnostic::new(
                    field,
                    "PipeWire synchronization deadline expired; completion is unknown",
                ));
            }
            if completed.get() {
                return Ok(());
            }
            if !self.wait_for_callbacks(deadline, field)? {
                return Err(ScientificDiagnostic::new(
                    field,
                    "PipeWire synchronization deadline expired; completion is unknown",
                ));
            }
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

    fn count_required_nodes(&self) -> usize {
        let globals = self.globals.borrow();
        self.required_node_names
            .iter()
            .filter(|node_name| {
                globals
                    .values()
                    .filter(|global| is_node_named(global, node_name))
                    .count()
                    == 1
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

fn validate_node_factory_identity(
    field: &str,
    observed: Option<&str>,
    expected: &str,
) -> Result<(), ScientificDiagnostic> {
    if observed == Some(expected) {
        Ok(())
    } else {
        Err(ScientificDiagnostic::new(
            format!("{field}.factory"),
            format!("expected realized factory {expected:?}, observed {observed:?}"),
        ))
    }
}

fn fractions_equivalent(left: Fraction, right: Fraction) -> bool {
    u64::from(left.num) * u64::from(right.denom) == u64::from(right.num) * u64::from(left.denom)
}

/// Ports may offer unrelated media alternatives (e.g. FITS also offers video).
/// Retain exactly one ndarray declaration or the discard sink's wildcard;
/// the caller then validates its complete scientific contract.
fn select_ndarray_format(
    formats: Vec<Result<PodObject, String>>,
    field: &str,
) -> Result<PodObject, ScientificDiagnostic> {
    let mut candidates = Vec::new();
    for format in formats {
        let object = format.map_err(|message| ScientificDiagnostic::new(field, message))?;
        validate_format_object(&object, ObjectRole::Source, "output")
            .map_err(|error| ScientificDiagnostic::new(field, error.message().to_owned()))?;
        let ndarray = object.properties.iter().any(|property| {
            property.key == pw::spa::sys::SPA_FORMAT_mediaSubtype
                && property.value == Value::Id(Id(pw::spa::sys::SPA_MEDIA_SUBTYPE_ndarray))
        });
        if object.properties.is_empty() || ndarray {
            candidates.push(object);
        }
    }
    if candidates.len() != 1 {
        return Err(ScientificDiagnostic::new(
            field,
            format!(
                "expected exactly one ndarray or wildcard EnumFormat, observed {}",
                candidates.len()
            ),
        ));
    }
    Ok(candidates.pop().expect("one matching format was observed"))
}

fn validate_ndarray_port(
    object: &PodObject,
    role: ObjectRole,
    port: &PortSpec,
    expected_rate: Fraction,
) -> Result<(), ScientificDiagnostic> {
    validate_format_object(object, role, &port.name)?;
    let observed =
        NdArrayFormat::<Vec<u32>>::from_properties(&object.properties).map_err(|error| {
            ScientificDiagnostic::new(
                format!("{}.ports.{}.format", role.name(), port.name),
                format!("invalid ndarray EnumFormat: {error}"),
            )
        })?;
    let expected_element_type = match port.element_type.as_str() {
        "F32_LE" => ElementType::F32Le,
        "U16_LE" => ElementType::U16Le,
        "BOOL8" => ElementType::Bool8,
        _ => unreachable!("port element type was validated before realization"),
    };
    if observed.element_type() != expected_element_type {
        return Err(ScientificDiagnostic::new(
            format!("{}.ports.{}.element-type", role.name(), port.name),
            format!(
                "expected {}, observed {:?}",
                port.element_type,
                observed.element_type()
            ),
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
    if !port.parameter
        && !observed
            .rate()
            .is_some_and(|rate| fractions_equivalent(rate, expected_rate))
    {
        return Err(ScientificDiagnostic::new(
            format!("{}.ports.{}.rate", role.name(), port.name),
            format!(
                "expected {}/{} complete frames per second, observed {:?}",
                expected_rate.num,
                expected_rate.denom,
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
    Ok(())
}

fn configured_port_rate(
    config: &DevelopmentConfig,
    port: &PortSpec,
) -> Result<Fraction, ScientificDiagnostic> {
    configured_rate(
        &format!("port {}.rate", port.name),
        port.rate.as_deref().unwrap_or(&config.rate),
    )
}

fn configured_rate(field: &str, rate: &str) -> Result<Fraction, ScientificDiagnostic> {
    let (numerator, denominator) = rate
        .split_once('/')
        .ok_or_else(|| ScientificDiagnostic::new(field, "invalid configured frame rate"))?;
    Ok(Fraction {
        num: numerator
            .parse()
            .map_err(|_| ScientificDiagnostic::new(field, "invalid rate numerator"))?,
        denom: denominator
            .parse()
            .map_err(|_| ScientificDiagnostic::new(field, "invalid rate denominator"))?,
    })
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
    fn execute(
        &mut self,
        effect: &LifecycleEffect,
    ) -> Result<LifecycleEffectSuccess, ScientificDiagnostic> {
        match effect {
            LifecycleEffect::Realize { token, config, .. } => {
                let resolved = match config {
                    ConfigurationInput::Resolved(config) => (**config).clone(),
                    ConfigurationInput::File(path) => DevelopmentConfig::load(path)?,
                };
                self.realize(&resolved, *token)?;
                Ok(LifecycleEffectSuccess::Realized {
                    execution_groups: resolved.execution_group_names(),
                })
            }
            LifecycleEffect::Start { token, .. } => {
                self.start(*token)?;
                Ok(LifecycleEffectSuccess::Completed)
            }
            LifecycleEffect::Stop { token, .. } => {
                self.stop(*token)?;
                Ok(LifecycleEffectSuccess::Completed)
            }
            LifecycleEffect::StartExecutionGroup { token, name, .. } => {
                self.start_execution_group(name, *token)?;
                Ok(LifecycleEffectSuccess::Completed)
            }
            LifecycleEffect::StopExecutionGroup { token, name, .. } => {
                self.stop_execution_group(name, *token)?;
                Ok(LifecycleEffectSuccess::Completed)
            }
            LifecycleEffect::Reset { token, .. } => {
                self.reset(*token)?;
                Ok(LifecycleEffectSuccess::Completed)
            }
            LifecycleEffect::UpdateProperties { graph, values, .. } => {
                match self.update_properties(graph, values)? {
                    PropertyUpdateOutcome::Submitted => {
                        Ok(LifecycleEffectSuccess::PropertiesSubmitted {
                            graph: graph.clone(),
                        })
                    }
                    PropertyUpdateOutcome::Active(generations) => {
                        Ok(LifecycleEffectSuccess::PropertiesUpdated {
                            graph: graph.clone(),
                            generations,
                        })
                    }
                }
            }
            LifecycleEffect::UpdateParameter {
                graph,
                parameter,
                value,
                ..
            } => {
                self.update_parameter(graph, parameter, value)?;
                Ok(LifecycleEffectSuccess::ParameterSubmitted {
                    graph: graph.clone(),
                    parameter: parameter.clone(),
                })
            }
            LifecycleEffect::Cleanup { token, .. } => {
                self.cleanup(Some(*token))?;
                Ok(LifecycleEffectSuccess::Completed)
            }
        }
    }

    fn check_required_objects(&mut self) -> Result<RequiredObjectStatus, ScientificDiagnostic> {
        self.check_external_object_contracts()?;
        for publisher in &self.parameter_publishers {
            if let Some(error) = &publisher.state.borrow().failure {
                return Err(ScientificDiagnostic::new(
                    format!(
                        "source {}.ports.{}",
                        publisher.node_name, publisher.port.name
                    ),
                    error.clone(),
                ));
            }
        }
        if !self.finite_source_names.is_empty()
            && self
                .finite_source_names
                .iter()
                .map(|name| self.fits_source_completed(name))
                .collect::<Result<Vec<_>, _>>()?
                .into_iter()
                .all(|completed| completed)
        {
            Ok(RequiredObjectStatus::FiniteSourceCompleted)
        } else {
            Ok(RequiredObjectStatus::Present)
        }
    }
}

impl Drop for LiveGraphAdapter {
    fn drop(&mut self) {
        // Explicit cleanup already released these local handles even when
        // remote removal could not be confirmed. Do not start a fresh sync
        // budget after the caller's Stop/Unload cleanup scope has ended.
        if !self.links.is_empty()
            || !self.controlled_graphs.is_empty()
            || !self.latest_hold_nodes.is_empty()
            || !self.spa_nodes.is_empty()
            || !self.parameter_publishers.is_empty()
            || !self.modules.is_empty()
        {
            let _ = self.cleanup(None);
        }
    }
}

fn iterate_callbacks(
    loop_: &pw::loop_::Loop,
    timeout: Duration,
    field: &str,
) -> Result<(), ScientificDiagnostic> {
    let result = loop_.iterate(pw::loop_::Timeout::Finite(timeout));
    if result < 0 {
        let error = std::io::Error::from_raw_os_error(-result);
        if error.kind() != std::io::ErrorKind::Interrupted {
            return Err(ScientificDiagnostic::new(
                field,
                format!("PipeWire loop iteration failed: {error}"),
            ));
        }
    }
    Ok(())
}

fn parse_property_info(pod: &pw::spa::pod::Pod) -> Result<(String, bool, Value), String> {
    let (_, value) = PodDeserializer::deserialize_from::<Value>(pod.as_bytes())
        .map_err(|error| format!("cannot decode SPA_PARAM_PropInfo: {error:?}"))?;
    let Value::Object(object) = value else {
        return Err("SPA_PARAM_PropInfo is not an object".to_owned());
    };
    if object.type_ != SpaTypes::ObjectParamPropInfo.as_raw()
        || object.id != pw::spa::param::ParamType::PropInfo.as_raw()
    {
        return Err("scientific SPA_PARAM_PropInfo has an invalid envelope".to_owned());
    }
    let name = object
        .properties
        .iter()
        .find(|property| property.key == pw::spa::sys::SPA_PROP_INFO_name)
        .and_then(|property| match &property.value {
            Value::String(name) => Some(name.clone()),
            _ => None,
        })
        .ok_or_else(|| "scientific SPA_PARAM_PropInfo has no String name".to_owned())?;
    let type_property = object
        .properties
        .iter()
        .find(|property| property.key == pw::spa::sys::SPA_PROP_INFO_type)
        .ok_or_else(|| format!("scientific property {name:?} has no type declaration"))?;
    Ok((
        name,
        !type_property.flags.contains(PropertyFlags::READONLY),
        type_property.value.clone(),
    ))
}

fn property_type_accepts(declared: &Value, value: &ScalarValue) -> bool {
    matches!(
        (declared, value),
        (
            Value::Bool(_) | Value::Choice(ChoiceValue::Bool(_)),
            ScalarValue::Bool(_)
        ) | (
            Value::Int(_) | Value::Choice(ChoiceValue::Int(_)),
            ScalarValue::Int(_)
        ) | (
            Value::Long(_) | Value::Choice(ChoiceValue::Long(_)),
            ScalarValue::Long(_)
        ) | (
            Value::Float(_) | Value::Choice(ChoiceValue::Float(_)),
            ScalarValue::Float(_)
        ) | (
            Value::Double(_) | Value::Choice(ChoiceValue::Double(_)),
            ScalarValue::Double(_)
        ) | (
            Value::Id(_) | Value::Choice(ChoiceValue::Id(_)),
            ScalarValue::Id(_)
        ) | (Value::String(_), ScalarValue::String(_))
    )
}

fn validate_property_declarations(
    graph_name: &str,
    values: &BTreeMap<String, ScalarValue>,
    declarations: &[Result<(String, bool, Value), String>],
) -> Result<(), ScientificDiagnostic> {
    for declaration in declarations {
        if let Err(error) = declaration {
            return Err(ScientificDiagnostic::new(
                format!("graph {graph_name}.properties"),
                format!("invalid host property declaration: {error}"),
            ));
        }
    }
    for (name, value) in values {
        let declared = declarations
            .iter()
            .filter_map(|declaration| declaration.as_ref().ok())
            .find(|(declared_name, _, _)| declared_name == name);
        match declared {
            Some((_, true, declared_type)) => {
                if !property_type_accepts(declared_type, value) {
                    return Err(ScientificDiagnostic::new(
                        format!("graph {graph_name}.properties.{name}"),
                        format!(
                            "value {value:?} does not match declared SPA type {declared_type:?}"
                        ),
                    ));
                }
            }
            Some((_, false, _)) => {
                return Err(ScientificDiagnostic::new(
                    format!("graph {graph_name}.properties.{name}"),
                    "property is read-only",
                ));
            }
            None => {
                return Err(ScientificDiagnostic::new(
                    format!("graph {graph_name}.properties.{name}"),
                    "property is not declared by the graph owner",
                ));
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod property_validation_tests {
    use super::*;
    use pw::spa::utils::{Choice, ChoiceEnum, ChoiceFlags};

    #[test]
    fn property_admission_requires_the_declared_scalar_type() {
        let types = [
            Value::Bool(false),
            Value::Int(0),
            Value::Long(0),
            Value::Float(0.0),
            Value::Double(0.0),
            Value::Id(Id(0)),
            Value::String(String::new()),
        ];
        let values = [
            ScalarValue::Bool(true),
            ScalarValue::Int(1),
            ScalarValue::Long(1),
            ScalarValue::float(0.2),
            ScalarValue::double(0.2),
            ScalarValue::Id(1),
            ScalarValue::String("value".to_owned()),
        ];
        for (index, declared) in types.iter().enumerate() {
            let declarations = [Ok(("node:value".to_owned(), true, declared.clone()))];
            for (value_index, value) in values.iter().enumerate() {
                let transaction = BTreeMap::from([("node:value".to_owned(), value.clone())]);
                assert_eq!(
                    validate_property_declarations("graph", &transaction, &declarations).is_ok(),
                    index == value_index,
                    "declared {declared:?}, submitted {value:?}"
                );
            }
        }
    }

    #[test]
    fn property_info_preserves_choice_type_and_read_only_flag() {
        let declared_type = Value::Choice(ChoiceValue::Float(Choice(
            ChoiceFlags::empty(),
            ChoiceEnum::Range {
                default: 0.5,
                min: -1.0,
                max: 1.0,
            },
        )));
        for writable in [false, true] {
            let mut type_property =
                PodProperty::new(pw::spa::sys::SPA_PROP_INFO_type, declared_type.clone());
            if !writable {
                type_property.flags = PropertyFlags::READONLY;
            }
            let value = Value::Object(PodObject {
                type_: SpaTypes::ObjectParamPropInfo.as_raw(),
                id: pw::spa::param::ParamType::PropInfo.as_raw(),
                properties: vec![
                    PodProperty::new(
                        pw::spa::sys::SPA_PROP_INFO_name,
                        Value::String("node:gain".to_owned()),
                    ),
                    type_property,
                ],
            });
            let bytes = PodSerializer::serialize(Cursor::new(Vec::new()), &value)
                .unwrap()
                .0
                .into_inner();
            let declaration =
                parse_property_info(pw::spa::pod::Pod::from_bytes(&bytes).unwrap()).unwrap();
            assert_eq!(
                declaration,
                ("node:gain".to_owned(), writable, declared_type.clone())
            );
            let declarations = [Ok(declaration)];
            let valid = BTreeMap::from([("node:gain".to_owned(), ScalarValue::float(0.2))]);
            assert_eq!(
                validate_property_declarations("graph", &valid, &declarations).is_ok(),
                writable
            );
            let wrong_type = BTreeMap::from([("node:gain".to_owned(), ScalarValue::Int(1))]);
            assert!(validate_property_declarations("graph", &wrong_type, &declarations).is_err());
            let unknown = BTreeMap::from([("node:unknown".to_owned(), ScalarValue::float(0.2))]);
            assert!(validate_property_declarations("graph", &unknown, &declarations).is_err());
        }
    }
}

fn parse_property_snapshot(
    pod: &pw::spa::pod::Pod,
) -> Result<BTreeMap<String, ScalarValue>, String> {
    let (_, value) = PodDeserializer::deserialize_from::<Value>(pod.as_bytes())
        .map_err(|error| format!("cannot decode SPA_PARAM_Props: {error:?}"))?;
    let Value::Object(object) = value else {
        return Err("SPA_PARAM_Props is not an object".to_owned());
    };
    if object.type_ != SpaTypes::ObjectParamProps.as_raw()
        || object.id != pw::spa::param::ParamType::Props.as_raw()
        || object.properties.len() != 1
        || object.properties[0].key != pw::spa::sys::SPA_PROP_params
    {
        return Err("scientific SPA_PARAM_Props object has an invalid envelope".to_owned());
    }
    let Value::Struct(fields) = object
        .properties
        .into_iter()
        .next()
        .expect("one property was checked")
        .value
    else {
        return Err("scientific SPA_PARAM_Props payload is not a Struct".to_owned());
    };
    if fields.len() % 2 != 0 {
        return Err("scientific SPA_PARAM_Props has an unmatched name or value".to_owned());
    }
    fields
        .chunks_exact(2)
        .map(|pair| {
            let Value::String(name) = &pair[0] else {
                return Err("scientific SPA_PARAM_Props name is not a String".to_owned());
            };
            let value = match &pair[1] {
                Value::Bool(value) => ScalarValue::Bool(*value),
                Value::Int(value) => ScalarValue::Int(*value),
                Value::Long(value) => ScalarValue::Long(*value),
                Value::Float(value) => ScalarValue::float(*value),
                Value::Double(value) => ScalarValue::double(*value),
                Value::Id(value) => ScalarValue::Id(value.0),
                Value::String(value) => ScalarValue::String(value.clone()),
                other => {
                    return Err(format!(
                        "scientific property {name:?} has unsupported value {other:?}"
                    ))
                }
            };
            Ok((name.clone(), value))
        })
        .collect()
}

fn latest_property_snapshot(
    graph: &ControlledGraph,
) -> Result<BTreeMap<String, ScalarValue>, ScientificDiagnostic> {
    graph
        .property_events
        .borrow()
        .last()
        .ok_or_else(|| {
            ScientificDiagnostic::new(
                format!("graph {}.properties", graph.name),
                "owner did not publish a scientific property snapshot",
            )
        })?
        .clone()
        .map_err(|error| {
            ScientificDiagnostic::new(format!("graph {}.properties", graph.name), error.clone())
        })
}

fn property_generation(
    snapshot: &BTreeMap<String, ScalarValue>,
    node: &str,
) -> Result<PropertyGeneration, ScientificDiagnostic> {
    let requested_name = format!("{node}:requested-generation");
    let active_name = format!("{node}:active-generation");
    let requested = match snapshot.get(&requested_name) {
        Some(ScalarValue::Long(value)) => *value,
        Some(value) => {
            return Err(ScientificDiagnostic::new(
                requested_name,
                format!("expected Long, observed {value:?}"),
            ))
        }
        None => {
            return Err(ScientificDiagnostic::new(
                requested_name,
                "required requested-generation observation is missing",
            ))
        }
    };
    let active = match snapshot.get(&active_name) {
        Some(ScalarValue::Long(value)) => *value,
        Some(value) => {
            return Err(ScientificDiagnostic::new(
                active_name,
                format!("expected Long, observed {value:?}"),
            ))
        }
        None => {
            return Err(ScientificDiagnostic::new(
                active_name,
                "required active-generation observation is missing",
            ))
        }
    };
    Ok(PropertyGeneration {
        requested,
        active: Some(active),
    })
}

fn parameter_generation(
    snapshot: &BTreeMap<String, ScalarValue>,
    node: &str,
) -> Result<ParameterGeneration, ScientificDiagnostic> {
    let requested_name = format!("{node}:requested-parameter-sequence");
    let active_name = format!("{node}:active-parameter-sequence");
    let value = |name: &str| match snapshot.get(name) {
        Some(ScalarValue::Long(value)) => Ok(*value),
        Some(value) => Err(ScientificDiagnostic::new(
            name,
            format!("expected Long, observed {value:?}"),
        )),
        None => Err(ScientificDiagnostic::new(
            name,
            "required parameter-sequence observation is missing",
        )),
    };
    Ok(ParameterGeneration {
        requested: value(&requested_name)?,
        active: value(&active_name)?,
    })
}

fn build_property_update(values: &BTreeMap<String, ScalarValue>) -> Result<Vec<u8>, String> {
    let mut fields = Vec::with_capacity(values.len() * 2);
    for (name, value) in values {
        if name.split_once(':').is_none() {
            return Err(format!(
                "scientific property {name:?} must use the qualified node:property name"
            ));
        }
        fields.push(Value::String(name.clone()));
        fields.push(match value {
            ScalarValue::Bool(value) => Value::Bool(*value),
            ScalarValue::Int(value) => Value::Int(*value),
            ScalarValue::Long(value) => Value::Long(*value),
            ScalarValue::Float(bits) => Value::Float(f32::from_bits(*bits)),
            ScalarValue::Double(bits) => Value::Double(f64::from_bits(*bits)),
            ScalarValue::Id(value) => Value::Id(Id(*value)),
            ScalarValue::String(value) => Value::String(value.clone()),
        });
    }
    let value = Value::Object(PodObject {
        type_: SpaTypes::ObjectParamProps.as_raw(),
        id: pw::spa::param::ParamType::Props.as_raw(),
        properties: vec![PodProperty::new(
            pw::spa::sys::SPA_PROP_params,
            Value::Struct(fields),
        )],
    });
    PodSerializer::serialize(Cursor::new(Vec::new()), &value)
        .map(|result| result.0.into_inner())
        .map_err(|error| format!("cannot serialize SPA_PARAM_Props: {error:?}"))
}

fn parameter_stride(port: &PortSpec) -> Result<i32, String> {
    let columns = port
        .shape
        .last()
        .copied()
        .ok_or_else(|| "parameter shape is empty".to_owned())?;
    let bytes = usize::try_from(columns)
        .ok()
        .and_then(|columns| columns.checked_mul(size_of::<f32>()))
        .ok_or_else(|| "parameter row stride exceeds addressable storage".to_owned())?;
    i32::try_from(bytes).map_err(|_| "parameter row stride exceeds SPA Int".to_owned())
}

fn parameter_stream_parameters(port: &PortSpec) -> Result<Parameters, String> {
    let format = NdArrayFormat::new(
        ElementType::F32Le,
        port.shape.clone(),
        NdArrayLayout::RowMajor,
        None,
    )
    .map_err(|error| format!("invalid ndarray parameter format: {error}"))?;
    let mut format_properties = format.properties();
    format_properties.push(PodProperty::new(
        pw::spa::sys::SPA_FORMAT_NDARRAY_schema,
        Value::String(port.schema.clone()),
    ));
    let byte_count = i32::try_from(format.byte_count())
        .map_err(|_| "parameter payload exceeds SPA Int".to_owned())?;
    let stride = parameter_stride(port)?;
    let memory_types =
        (1_i32 << pw::spa::sys::SPA_DATA_MemPtr) | (1_i32 << pw::spa::sys::SPA_DATA_MemFd);
    Ok(Parameters::new([
        Value::Object(PodObject {
            type_: SpaTypes::ObjectParamFormat.as_raw(),
            id: pw::spa::param::ParamType::EnumFormat.as_raw(),
            properties: format_properties,
        }),
        Value::Object(PodObject {
            type_: SpaTypes::ObjectParamBuffers.as_raw(),
            id: pw::spa::param::ParamType::Buffers.as_raw(),
            properties: vec![
                PodProperty::new(
                    pw::spa::param::BufferProperties::Buffers.as_raw(),
                    Value::Int(2),
                ),
                PodProperty::new(
                    pw::spa::param::BufferProperties::Blocks.as_raw(),
                    Value::Int(1),
                ),
                PodProperty::new(
                    pw::spa::param::BufferProperties::Size.as_raw(),
                    Value::Int(byte_count),
                ),
                PodProperty::new(
                    pw::spa::param::BufferProperties::Stride.as_raw(),
                    Value::Int(stride),
                ),
                PodProperty::new(
                    pw::spa::param::BufferProperties::DataType.as_raw(),
                    Value::Int(memory_types),
                ),
            ],
        }),
    ]))
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

fn resolve_file_reference(field: &str, configured: &str) -> Result<PathBuf, ScientificDiagnostic> {
    let environment_name = configured
        .strip_prefix("${")
        .and_then(|value| value.strip_suffix('}'))
        .ok_or_else(|| {
            ScientificDiagnostic::new(field, "expected an explicit environment file reference")
        })?;
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

fn read_module_arguments(field: &str, configured: &str) -> Result<String, ScientificDiagnostic> {
    let path = resolve_file_reference(field, configured)?;
    std::fs::read_to_string(&path).map_err(|error| {
        ScientificDiagnostic::new(
            field,
            format!(
                "cannot read delegated PipeWire module arguments {} as UTF-8: {error}",
                path.display()
            ),
        )
    })
}

#[cfg(test)]
mod callback_wait_tests {
    use super::iterate_callbacks;
    use std::cell::Cell;
    use std::rc::Rc;
    use std::sync::Arc;
    use std::time::{Duration, Instant};

    fn format(subtype: u32) -> super::PodObject {
        super::PodObject {
            type_: pipewire::spa::utils::SpaTypes::ObjectParamFormat.as_raw(),
            id: pipewire::spa::param::ParamType::EnumFormat.as_raw(),
            properties: vec![super::PodProperty::new(
                pipewire::spa::sys::SPA_FORMAT_mediaSubtype,
                super::Value::Id(pipewire::spa::utils::Id(subtype)),
            )],
        }
    }

    #[test]
    fn ndarray_format_allows_unrelated_video_alternative() {
        let ndarray = format(pipewire::spa::sys::SPA_MEDIA_SUBTYPE_ndarray);
        let video = format(pipewire::spa::sys::SPA_MEDIA_SUBTYPE_raw);
        assert_eq!(
            super::select_ndarray_format(vec![Ok(video), Ok(ndarray.clone())], "source.format")
                .unwrap(),
            ndarray
        );
    }

    #[test]
    fn ndarray_format_rejects_missing_duplicate_and_malformed_offers() {
        let ndarray = format(pipewire::spa::sys::SPA_MEDIA_SUBTYPE_ndarray);
        assert!(super::select_ndarray_format(
            vec![Ok(format(pipewire::spa::sys::SPA_MEDIA_SUBTYPE_raw))],
            "format"
        )
        .is_err());
        assert!(
            super::select_ndarray_format(vec![Ok(ndarray.clone()), Ok(ndarray)], "format").is_err()
        );
        assert!(super::select_ndarray_format(vec![Err("invalid pod".into())], "format").is_err());
        let mut wildcard = format(0);
        wildcard.properties.clear();
        assert_eq!(
            super::select_ndarray_format(vec![Ok(wildcard.clone())], "sink.format").unwrap(),
            wildcard
        );
    }

    #[test]
    fn parameter_pending_publication_and_retry_share_payload() {
        let payload = Arc::new(vec![0; 16]);
        let mut state = super::ParameterProcessState {
            failure: Some("previous failure".to_owned()),
            ..super::ParameterProcessState::default()
        };
        state.queue_payload(&payload).unwrap();
        assert!(state.failure.is_none());
        assert!(Arc::ptr_eq(&payload, state.pending.as_ref().unwrap()));
        let replacement = Arc::new(vec![1; 16]);
        assert_eq!(
            state.queue_payload(&replacement),
            Err("a parameter value is already pending")
        );
        // A callback without an available SPA buffer retains the same allocation.
        let pending = state.pending.take().unwrap();
        state.pending = Some(pending);
        assert!(Arc::ptr_eq(&payload, state.pending.as_ref().unwrap()));
    }

    #[test]
    fn control_wait_services_pending_owner_thread_callback() {
        let main_loop = pipewire::main_loop::MainLoopRc::new(None).unwrap();
        let completed = Rc::new(Cell::new(false));
        let callback_completed = Rc::clone(&completed);
        let timer = main_loop.loop_().add_timer(move |_| {
            callback_completed.set(true);
        });
        timer
            .update_timer(Some(Duration::from_millis(1)), None)
            .into_result()
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(1);
        while !completed.get() && Instant::now() < deadline {
            iterate_callbacks(main_loop.loop_(), Duration::from_millis(5), "control wait").unwrap();
        }
        assert!(
            completed.get(),
            "owner-thread callback stalled during control wait"
        );
    }
}
