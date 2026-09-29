use crate::{DevelopmentConfig, ScientificDiagnostic};
use statig::blocking::IntoStateMachineExt;
use statig::prelude::{state_machine, Handled, Outcome, Super, Transition};
use std::collections::BTreeMap;
use std::fmt;
use std::path::PathBuf;
use std::sync::Arc;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ConfigurationInput {
    Resolved(Box<DevelopmentConfig>),
    File(PathBuf),
}

impl From<DevelopmentConfig> for ConfigurationInput {
    fn from(config: DevelopmentConfig) -> Self {
        Self::Resolved(Box::new(config))
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LifecycleState {
    Offline,
    Configuring,
    Ready,
    Running,
    Fault,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ExecutionGroupState {
    Stopped,
    Running,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct EffectToken(u64);

impl EffectToken {
    #[must_use]
    pub const fn value(self) -> u64 {
        self.0
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EffectKind {
    Realize,
    Start,
    Stop,
    StartExecutionGroup,
    StopExecutionGroup,
    Reset,
    UpdateProperties,
    UpdateParameter,
    Cleanup,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EffectOrigin {
    OfflineLoad,
    ReadyReload,
    FaultRetry,
    ReadyStart,
    RunningStop,
    RunningExecutionGroupStart,
    RunningExecutionGroupStop,
    ReadyReset,
    ReadyPropertyUpdate,
    RunningPropertyUpdate,
    ReadyParameterUpdate,
    RunningParameterUpdate,
    FiniteSourceCompletion,
    ConfiguringUnload,
    ReadyUnload,
    RunningUnload,
    FaultUnload,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum EffectTarget {
    Session,
    ExecutionGroup(String),
    Graph(String),
    GraphParameter { graph: String, parameter: String },
}

/// One scalar value admitted to a graph's standard `SPA_PARAM_Props` surface.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ScalarValue {
    Bool(bool),
    Int(i32),
    Long(i64),
    Float(u32),
    Double(u64),
    Id(u32),
    String(String),
}

impl ScalarValue {
    #[must_use]
    pub fn float(value: f32) -> Self {
        Self::Float(value.to_bits())
    }

    #[must_use]
    pub fn double(value: f64) -> Self {
        Self::Double(value.to_bits())
    }

    #[must_use]
    pub fn as_float(&self) -> Option<f32> {
        match self {
            Self::Float(bits) => Some(f32::from_bits(*bits)),
            _ => None,
        }
    }

    #[must_use]
    pub fn as_double(&self) -> Option<f64> {
        match self {
            Self::Double(bits) => Some(f64::from_bits(*bits)),
            _ => None,
        }
    }
}

/// One complete ndarray value for a declared graph parameter input.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NdArrayParameterValue {
    pub element_type: String,
    pub shape: Vec<u32>,
    pub schema: String,
    /// Owned payload shared without byte copies across lifecycle effects and
    /// pending publication. Construct from a prepared `Vec` before owner-thread
    /// dispatch; treat the bytes as immutable. Publication copies them into SPA
    /// storage, whose lifetime is independent of this value.
    pub bytes: Arc<Vec<u8>>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum LifecycleEffectSuccess {
    Completed,
    Realized {
        execution_groups: Vec<String>,
    },
    PropertiesUpdated {
        graph: String,
        generations: BTreeMap<String, PropertyGeneration>,
    },
    PropertiesSubmitted {
        graph: String,
    },
    ParameterSubmitted {
        graph: String,
        parameter: String,
    },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct PropertyGeneration {
    pub requested: i64,
    pub active: Option<i64>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ParameterGeneration {
    pub requested: i64,
    pub active: i64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum LifecycleEffect {
    Realize {
        token: EffectToken,
        origin: EffectOrigin,
        config: ConfigurationInput,
    },
    Start {
        token: EffectToken,
        origin: EffectOrigin,
    },
    Stop {
        token: EffectToken,
        origin: EffectOrigin,
    },
    StartExecutionGroup {
        token: EffectToken,
        origin: EffectOrigin,
        name: String,
    },
    StopExecutionGroup {
        token: EffectToken,
        origin: EffectOrigin,
        name: String,
    },
    Reset {
        token: EffectToken,
        origin: EffectOrigin,
    },
    UpdateProperties {
        token: EffectToken,
        origin: EffectOrigin,
        graph: String,
        values: BTreeMap<String, ScalarValue>,
    },
    UpdateParameter {
        token: EffectToken,
        origin: EffectOrigin,
        graph: String,
        parameter: String,
        value: NdArrayParameterValue,
    },
    Cleanup {
        token: EffectToken,
        origin: EffectOrigin,
    },
}

impl LifecycleEffect {
    #[must_use]
    pub const fn token(&self) -> EffectToken {
        match self {
            Self::Realize { token, .. }
            | Self::Start { token, .. }
            | Self::Stop { token, .. }
            | Self::StartExecutionGroup { token, .. }
            | Self::StopExecutionGroup { token, .. }
            | Self::Reset { token, .. }
            | Self::UpdateProperties { token, .. }
            | Self::UpdateParameter { token, .. }
            | Self::Cleanup { token, .. } => *token,
        }
    }

    #[must_use]
    pub const fn kind(&self) -> EffectKind {
        match self {
            Self::Realize { .. } => EffectKind::Realize,
            Self::Start { .. } => EffectKind::Start,
            Self::Stop { .. } => EffectKind::Stop,
            Self::StartExecutionGroup { .. } => EffectKind::StartExecutionGroup,
            Self::StopExecutionGroup { .. } => EffectKind::StopExecutionGroup,
            Self::Reset { .. } => EffectKind::Reset,
            Self::UpdateProperties { .. } => EffectKind::UpdateProperties,
            Self::UpdateParameter { .. } => EffectKind::UpdateParameter,
            Self::Cleanup { .. } => EffectKind::Cleanup,
        }
    }

    #[must_use]
    pub const fn origin(&self) -> EffectOrigin {
        match self {
            Self::Realize { origin, .. }
            | Self::Start { origin, .. }
            | Self::Stop { origin, .. }
            | Self::StartExecutionGroup { origin, .. }
            | Self::StopExecutionGroup { origin, .. }
            | Self::Reset { origin, .. }
            | Self::UpdateProperties { origin, .. }
            | Self::UpdateParameter { origin, .. }
            | Self::Cleanup { origin, .. } => *origin,
        }
    }

    #[must_use]
    pub fn target(&self) -> EffectTarget {
        match self {
            Self::StartExecutionGroup { name, .. } | Self::StopExecutionGroup { name, .. } => {
                EffectTarget::ExecutionGroup(name.clone())
            }
            Self::UpdateProperties { graph, .. } => EffectTarget::Graph(graph.clone()),
            Self::UpdateParameter {
                graph, parameter, ..
            } => EffectTarget::GraphParameter {
                graph: graph.clone(),
                parameter: parameter.clone(),
            },
            Self::Realize { .. }
            | Self::Start { .. }
            | Self::Stop { .. }
            | Self::Reset { .. }
            | Self::Cleanup { .. } => EffectTarget::Session,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LifecycleEffectResult {
    pub token: EffectToken,
    pub kind: EffectKind,
    pub origin: EffectOrigin,
    pub target: EffectTarget,
    pub result: Result<LifecycleEffectSuccess, ScientificDiagnostic>,
}

impl LifecycleEffectResult {
    #[must_use]
    pub fn from_effect(effect: &LifecycleEffect, result: Result<(), ScientificDiagnostic>) -> Self {
        Self::from_output(effect, result.map(|()| LifecycleEffectSuccess::Completed))
    }

    #[must_use]
    pub fn from_output(
        effect: &LifecycleEffect,
        result: Result<LifecycleEffectSuccess, ScientificDiagnostic>,
    ) -> Self {
        Self {
            token: effect.token(),
            kind: effect.kind(),
            origin: effect.origin(),
            target: effect.target(),
            result,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum LifecycleEvent {
    Load(ConfigurationInput),
    Start,
    Stop,
    StartExecutionGroup(String),
    StopExecutionGroup(String),
    Reset,
    UpdateProperties {
        graph: String,
        values: BTreeMap<String, ScalarValue>,
    },
    UpdateParameter {
        graph: String,
        parameter: String,
        value: NdArrayParameterValue,
    },
    Reload(ConfigurationInput),
    Retry,
    Unload,
    RequiredObjectFailed(ScientificDiagnostic),
    FiniteSourceCompleted,
    EffectCompleted(LifecycleEffectResult),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DispatchOutcome {
    pub state: LifecycleState,
    pub effect: Option<LifecycleEffect>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DispatchError(String);

impl fmt::Display for DispatchError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for DispatchError {}

#[derive(Clone, Debug)]
enum MachineEvent {
    Load(LifecycleEffect),
    Start(LifecycleEffect),
    Stop(LifecycleEffect),
    StartExecutionGroup(LifecycleEffect),
    StopExecutionGroup(LifecycleEffect),
    Reset(LifecycleEffect),
    UpdateProperties(LifecycleEffect),
    UpdateParameter(LifecycleEffect),
    Reload(LifecycleEffect),
    Retry(LifecycleEffect),
    Unload(LifecycleEffect),
    RequiredObjectFailed(ScientificDiagnostic),
    FiniteSourceCompleted(LifecycleEffect),
    EffectCompleted(LifecycleEffectResult),
}

#[derive(Default)]
struct LifecycleMachine {
    emitted: Option<LifecycleEffect>,
    rejected: bool,
    diagnostic: Option<ScientificDiagnostic>,
}

#[state_machine(
    initial = "State::offline()",
    state(derive(Debug, Eq, PartialEq)),
    superstate(derive(Debug, Eq, PartialEq))
)]
impl LifecycleMachine {
    #[state]
    fn offline(&mut self, event: &MachineEvent) -> Outcome<State> {
        match event {
            MachineEvent::Load(effect) => {
                self.emit(effect);
                Transition(State::configuring())
            }
            _ => self.reject(),
        }
    }

    #[state(superstate = "managed")]
    fn configuring(&mut self, event: &MachineEvent) -> Outcome<State> {
        match event {
            MachineEvent::EffectCompleted(result) if result.kind == EffectKind::Realize => {
                self.accept();
                match &result.result {
                    Ok(_) => Transition(State::ready()),
                    Err(diagnostic) => {
                        self.diagnostic = Some(diagnostic.clone());
                        Transition(State::fault())
                    }
                }
            }
            _ => Super,
        }
    }

    #[state(superstate = "managed")]
    fn ready(&mut self, event: &MachineEvent) -> Outcome<State> {
        match event {
            MachineEvent::Start(effect)
            | MachineEvent::Reset(effect)
            | MachineEvent::UpdateProperties(effect)
            | MachineEvent::UpdateParameter(effect) => {
                self.emit(effect);
                Handled
            }
            MachineEvent::Reload(effect) => {
                self.emit(effect);
                Transition(State::configuring())
            }
            MachineEvent::RequiredObjectFailed(diagnostic) => {
                self.accept();
                self.diagnostic = Some(diagnostic.clone());
                Transition(State::fault())
            }
            MachineEvent::EffectCompleted(result) if result.kind == EffectKind::Start => {
                self.accept();
                match &result.result {
                    Ok(_) => Transition(State::running()),
                    Err(diagnostic) => {
                        self.diagnostic = Some(diagnostic.clone());
                        Transition(State::fault())
                    }
                }
            }
            MachineEvent::EffectCompleted(result)
                if matches!(
                    result.kind,
                    EffectKind::Reset | EffectKind::UpdateProperties | EffectKind::UpdateParameter
                ) =>
            {
                self.accept();
                match &result.result {
                    Ok(_) => Handled,
                    Err(diagnostic) => {
                        self.diagnostic = Some(diagnostic.clone());
                        Transition(State::fault())
                    }
                }
            }
            _ => Super,
        }
    }

    #[state(superstate = "managed")]
    fn running(&mut self, event: &MachineEvent) -> Outcome<State> {
        match event {
            MachineEvent::Stop(effect)
            | MachineEvent::FiniteSourceCompleted(effect)
            | MachineEvent::StartExecutionGroup(effect)
            | MachineEvent::StopExecutionGroup(effect)
            | MachineEvent::UpdateProperties(effect)
            | MachineEvent::UpdateParameter(effect) => {
                self.emit(effect);
                Handled
            }
            MachineEvent::RequiredObjectFailed(diagnostic) => {
                self.accept();
                self.diagnostic = Some(diagnostic.clone());
                Transition(State::fault())
            }
            MachineEvent::EffectCompleted(result) if result.kind == EffectKind::Stop => {
                self.accept();
                match &result.result {
                    Ok(_) => Transition(State::ready()),
                    Err(diagnostic) => {
                        self.diagnostic = Some(diagnostic.clone());
                        Transition(State::fault())
                    }
                }
            }
            MachineEvent::EffectCompleted(result)
                if matches!(
                    result.kind,
                    EffectKind::StartExecutionGroup
                        | EffectKind::StopExecutionGroup
                        | EffectKind::UpdateProperties
                        | EffectKind::UpdateParameter
                ) =>
            {
                self.accept();
                match &result.result {
                    Ok(_) => Handled,
                    Err(diagnostic) => {
                        self.diagnostic = Some(diagnostic.clone());
                        Transition(State::fault())
                    }
                }
            }
            _ => Super,
        }
    }

    #[state(superstate = "managed")]
    fn fault(&mut self, event: &MachineEvent) -> Outcome<State> {
        match event {
            MachineEvent::Retry(effect) => {
                self.emit(effect);
                Transition(State::configuring())
            }
            _ => Super,
        }
    }

    #[superstate]
    fn managed(&mut self, event: &MachineEvent) -> Outcome<State> {
        match event {
            MachineEvent::Unload(effect) => {
                self.emit(effect);
                Handled
            }
            MachineEvent::EffectCompleted(result) if result.kind == EffectKind::Cleanup => {
                self.accept();
                match &result.result {
                    Ok(_) => {
                        self.diagnostic = None;
                        Transition(State::offline())
                    }
                    Err(diagnostic) => {
                        self.diagnostic = Some(diagnostic.clone());
                        Transition(State::fault())
                    }
                }
            }
            _ => self.reject(),
        }
    }
}

impl LifecycleMachine {
    fn accept(&mut self) {
        self.emitted = None;
        self.rejected = false;
    }

    fn emit(&mut self, effect: &LifecycleEffect) {
        self.emitted = Some(effect.clone());
        self.rejected = false;
    }

    fn reject(&mut self) -> Outcome<State> {
        self.emitted = None;
        self.rejected = true;
        Handled
    }
}

impl MachineEvent {
    const fn name(&self) -> &'static str {
        match self {
            Self::Load(_) => "load",
            Self::Start(_) => "start",
            Self::Stop(_) => "stop",
            Self::StartExecutionGroup(_) => "start-execution-group",
            Self::StopExecutionGroup(_) => "stop-execution-group",
            Self::Reset(_) => "reset",
            Self::UpdateProperties(_) => "update-properties",
            Self::UpdateParameter(_) => "update-parameter",
            Self::Reload(_) => "reload",
            Self::Retry(_) => "retry",
            Self::Unload(_) => "unload",
            Self::RequiredObjectFailed(_) => "required-object-failed",
            Self::FiniteSourceCompleted(_) => "finite-source-completed",
            Self::EffectCompleted(_) => "effect-completed",
        }
    }
}

/// The only owner allowed to dispatch events into the private Statig machine.
pub struct LifecycleDispatcher {
    machine: statig::blocking::StateMachine<LifecycleMachine>,
    next_token: u64,
    pending: Option<LifecycleEffect>,
    last_config: Option<ConfigurationInput>,
    execution_groups: BTreeMap<String, ExecutionGroupState>,
}

impl Default for LifecycleDispatcher {
    fn default() -> Self {
        Self::new()
    }
}

impl LifecycleDispatcher {
    #[must_use]
    pub fn new() -> Self {
        Self {
            machine: LifecycleMachine::default().state_machine(),
            next_token: 1,
            pending: None,
            last_config: None,
            execution_groups: BTreeMap::new(),
        }
    }

    #[must_use]
    pub fn state(&self) -> LifecycleState {
        public_state(self.machine.state())
    }

    #[must_use]
    pub fn pending_effect(&self) -> Option<&LifecycleEffect> {
        self.pending.as_ref()
    }

    #[must_use]
    pub fn diagnostic(&self) -> Option<&ScientificDiagnostic> {
        self.machine.inner().diagnostic.as_ref()
    }

    #[must_use]
    pub fn execution_group_states(&self) -> &BTreeMap<String, ExecutionGroupState> {
        &self.execution_groups
    }

    /// Serializes one RTC-domain event through the private Statig machine.
    ///
    /// # Errors
    ///
    /// Rejects invalid events, concurrent effects, exhausted tokens, and
    /// stale, duplicate, wrong-kind, or wrong-origin completions.
    pub fn dispatch(&mut self, event: LifecycleEvent) -> Result<DispatchOutcome, DispatchError> {
        if let LifecycleEvent::EffectCompleted(completion) = event {
            return self.complete(completion);
        }

        if let Some(pending) = self.pending.as_ref() {
            let group_effect = matches!(
                pending.kind(),
                EffectKind::StartExecutionGroup | EffectKind::StopExecutionGroup
            );
            let supersedes = matches!(&event, LifecycleEvent::Unload)
                || matches!(
                    (&event, self.state()),
                    (
                        LifecycleEvent::RequiredObjectFailed(_),
                        LifecycleState::Ready | LifecycleState::Running
                    )
                )
                || (group_effect
                    && self.state() == LifecycleState::Running
                    && matches!(&event, LifecycleEvent::Stop));
            if supersedes {
                self.pending = None;
            } else {
                return Err(DispatchError(format!(
                    "event {} rejected while {:?} effect is pending",
                    event_name(&event),
                    self.pending.as_ref().map(LifecycleEffect::kind)
                )));
            }
        }

        let machine_event = self.prepare(event)?;
        self.machine.handle(&machine_event);
        if self.machine.inner().rejected {
            return Err(DispatchError(format!(
                "event {} is invalid in {:?}",
                machine_event.name(),
                self.state()
            )));
        }
        let effect = self.machine.inner().emitted.clone();
        if let Some(LifecycleEffect::Realize { config, .. }) = &effect {
            self.last_config = Some(config.clone());
        }
        self.pending.clone_from(&effect);
        Ok(DispatchOutcome {
            state: self.state(),
            effect,
        })
    }

    fn complete(
        &mut self,
        completion: LifecycleEffectResult,
    ) -> Result<DispatchOutcome, DispatchError> {
        let pending = self.pending.as_ref().ok_or_else(|| {
            DispatchError(format!(
                "stale or duplicate completion token {} has no pending effect",
                completion.token.value()
            ))
        })?;
        if completion.token != pending.token() {
            return Err(DispatchError(format!(
                "stale completion token {}, expected {}",
                completion.token.value(),
                pending.token().value()
            )));
        }
        if completion.kind != pending.kind() {
            return Err(DispatchError(format!(
                "completion kind {:?} does not match pending {:?}",
                completion.kind,
                pending.kind()
            )));
        }
        if completion.origin != pending.origin() {
            return Err(DispatchError(format!(
                "completion origin {:?} does not match pending {:?}",
                completion.origin,
                pending.origin()
            )));
        }
        if completion.target != pending.target() {
            return Err(DispatchError(format!(
                "completion target {:?} does not match pending {:?}",
                completion.target,
                pending.target()
            )));
        }

        let realized_groups = self.realized_groups(&completion)?;
        let kind = completion.kind;
        let target = completion.target.clone();
        let succeeded = completion.result.is_ok();

        self.pending = None;
        self.machine
            .handle(&MachineEvent::EffectCompleted(completion));
        if self.machine.inner().rejected {
            return Err(DispatchError(
                "validated completion was not accepted by the originating transition".to_owned(),
            ));
        }
        if kind == EffectKind::Realize {
            self.execution_groups.clear();
            if let Some(groups) = realized_groups {
                self.execution_groups.extend(
                    groups
                        .into_iter()
                        .map(|name| (name, ExecutionGroupState::Stopped)),
                );
            }
        } else if succeeded {
            match (kind, target) {
                (EffectKind::Start, EffectTarget::Session) => {
                    for state in self.execution_groups.values_mut() {
                        *state = ExecutionGroupState::Running;
                    }
                }
                (EffectKind::Stop, EffectTarget::Session) => {
                    for state in self.execution_groups.values_mut() {
                        *state = ExecutionGroupState::Stopped;
                    }
                }
                (EffectKind::StartExecutionGroup, EffectTarget::ExecutionGroup(name)) => {
                    if let Some(state) = self.execution_groups.get_mut(&name) {
                        *state = ExecutionGroupState::Running;
                    }
                }
                (EffectKind::StopExecutionGroup, EffectTarget::ExecutionGroup(name)) => {
                    if let Some(state) = self.execution_groups.get_mut(&name) {
                        *state = ExecutionGroupState::Stopped;
                    }
                }
                (EffectKind::Cleanup, EffectTarget::Session) => {
                    self.execution_groups.clear();
                }
                _ => {}
            }
        }
        Ok(DispatchOutcome {
            state: self.state(),
            effect: None,
        })
    }

    #[allow(clippy::too_many_lines)]
    fn prepare(&mut self, event: LifecycleEvent) -> Result<MachineEvent, DispatchError> {
        match event {
            LifecycleEvent::Load(config) => {
                let token = self.allocate_token()?;
                Ok(MachineEvent::Load(LifecycleEffect::Realize {
                    token,
                    origin: EffectOrigin::OfflineLoad,
                    config,
                }))
            }
            LifecycleEvent::Start => {
                let token = self.allocate_token()?;
                Ok(MachineEvent::Start(LifecycleEffect::Start {
                    token,
                    origin: EffectOrigin::ReadyStart,
                }))
            }
            LifecycleEvent::Stop => {
                let token = self.allocate_token()?;
                Ok(MachineEvent::Stop(LifecycleEffect::Stop {
                    token,
                    origin: EffectOrigin::RunningStop,
                }))
            }
            LifecycleEvent::StartExecutionGroup(name) => self.prepare_execution_group(name, true),
            LifecycleEvent::StopExecutionGroup(name) => self.prepare_execution_group(name, false),
            LifecycleEvent::Reset => {
                let token = self.allocate_token()?;
                Ok(MachineEvent::Reset(LifecycleEffect::Reset {
                    token,
                    origin: EffectOrigin::ReadyReset,
                }))
            }
            LifecycleEvent::UpdateProperties { graph, values } => {
                if graph.is_empty() || values.is_empty() || values.keys().any(String::is_empty) {
                    return Err(DispatchError(
                        "property update requires a graph and at least one named value".to_owned(),
                    ));
                }
                let origin = match self.state() {
                    LifecycleState::Ready => EffectOrigin::ReadyPropertyUpdate,
                    LifecycleState::Running => EffectOrigin::RunningPropertyUpdate,
                    state => {
                        return Err(DispatchError(format!(
                            "event update-properties is invalid in {state:?}"
                        )))
                    }
                };
                let token = self.allocate_token()?;
                Ok(MachineEvent::UpdateProperties(
                    LifecycleEffect::UpdateProperties {
                        token,
                        origin,
                        graph,
                        values,
                    },
                ))
            }
            LifecycleEvent::UpdateParameter {
                graph,
                parameter,
                value,
            } => {
                if graph.is_empty()
                    || parameter.is_empty()
                    || value.element_type.is_empty()
                    || value.shape.is_empty()
                    || value.shape.contains(&0)
                    || value.schema.is_empty()
                    || value.bytes.is_empty()
                {
                    return Err(DispatchError(
                        "parameter update requires a graph, parameter, element type, non-zero shape, schema, and payload"
                            .to_owned(),
                    ));
                }
                let origin = match self.state() {
                    LifecycleState::Ready => EffectOrigin::ReadyParameterUpdate,
                    LifecycleState::Running => EffectOrigin::RunningParameterUpdate,
                    state => {
                        return Err(DispatchError(format!(
                            "event update-parameter is invalid in {state:?}"
                        )))
                    }
                };
                let token = self.allocate_token()?;
                Ok(MachineEvent::UpdateParameter(
                    LifecycleEffect::UpdateParameter {
                        token,
                        origin,
                        graph,
                        parameter,
                        value,
                    },
                ))
            }
            LifecycleEvent::Reload(config) => {
                let token = self.allocate_token()?;
                Ok(MachineEvent::Reload(LifecycleEffect::Realize {
                    token,
                    origin: EffectOrigin::ReadyReload,
                    config,
                }))
            }
            LifecycleEvent::Retry => {
                let config = self.last_config.clone().ok_or_else(|| {
                    DispatchError(
                        "retry rejected because no configuration has been loaded".to_owned(),
                    )
                })?;
                let token = self.allocate_token()?;
                Ok(MachineEvent::Retry(LifecycleEffect::Realize {
                    token,
                    origin: EffectOrigin::FaultRetry,
                    config,
                }))
            }
            LifecycleEvent::Unload => {
                let origin = match self.state() {
                    LifecycleState::Configuring | LifecycleState::Offline => {
                        EffectOrigin::ConfiguringUnload
                    }
                    LifecycleState::Ready => EffectOrigin::ReadyUnload,
                    LifecycleState::Running => EffectOrigin::RunningUnload,
                    LifecycleState::Fault => EffectOrigin::FaultUnload,
                };
                let token = self.allocate_token()?;
                Ok(MachineEvent::Unload(LifecycleEffect::Cleanup {
                    token,
                    origin,
                }))
            }
            LifecycleEvent::RequiredObjectFailed(diagnostic) => {
                Ok(MachineEvent::RequiredObjectFailed(diagnostic))
            }
            LifecycleEvent::FiniteSourceCompleted => {
                let token = self.allocate_token()?;
                Ok(MachineEvent::FiniteSourceCompleted(LifecycleEffect::Stop {
                    token,
                    origin: EffectOrigin::FiniteSourceCompletion,
                }))
            }
            LifecycleEvent::EffectCompleted(_) => unreachable!("completions are handled first"),
        }
    }

    fn prepare_execution_group(
        &mut self,
        name: String,
        start: bool,
    ) -> Result<MachineEvent, DispatchError> {
        if self.state() != LifecycleState::Running {
            return Err(DispatchError(format!(
                "event {} is invalid in {:?}",
                if start {
                    "start-execution-group"
                } else {
                    "stop-execution-group"
                },
                self.state()
            )));
        }
        let current = self
            .execution_groups
            .get(&name)
            .ok_or_else(|| DispatchError(format!("execution group {name:?} is not configured")))?;
        let expected = if start {
            ExecutionGroupState::Stopped
        } else {
            ExecutionGroupState::Running
        };
        if *current != expected {
            return Err(DispatchError(format!(
                "execution group {name:?} cannot {} while {current:?}",
                if start { "start" } else { "stop" }
            )));
        }
        let token = self.allocate_token()?;
        if start {
            Ok(MachineEvent::StartExecutionGroup(
                LifecycleEffect::StartExecutionGroup {
                    token,
                    origin: EffectOrigin::RunningExecutionGroupStart,
                    name,
                },
            ))
        } else {
            Ok(MachineEvent::StopExecutionGroup(
                LifecycleEffect::StopExecutionGroup {
                    token,
                    origin: EffectOrigin::RunningExecutionGroupStop,
                    name,
                },
            ))
        }
    }

    fn realized_groups(
        &self,
        completion: &LifecycleEffectResult,
    ) -> Result<Option<Vec<String>>, DispatchError> {
        match (&completion.result, completion.kind) {
            (Ok(LifecycleEffectSuccess::Realized { execution_groups }), EffectKind::Realize) => {
                let groups = execution_groups
                    .iter()
                    .collect::<std::collections::BTreeSet<_>>();
                if groups.len() != execution_groups.len()
                    || execution_groups.iter().any(String::is_empty)
                {
                    return Err(DispatchError(
                        "realize completion contains an empty or duplicate execution-group name"
                            .to_owned(),
                    ));
                }
                Ok(Some(execution_groups.clone()))
            }
            (Ok(LifecycleEffectSuccess::Completed), EffectKind::Realize) => {
                let ConfigurationInput::Resolved(config) =
                    self.last_config.as_ref().ok_or_else(|| {
                        DispatchError("realize completion has no configuration".into())
                    })?
                else {
                    return Err(DispatchError(
                        "file realization must return configured execution-group names".to_owned(),
                    ));
                };
                Ok(Some(config.execution_group_names()))
            }
            (Ok(LifecycleEffectSuccess::PropertiesUpdated { .. }), EffectKind::Realize) => Err(
                DispatchError("realize completion returned property-update evidence".to_owned()),
            ),
            (Ok(LifecycleEffectSuccess::PropertiesSubmitted { .. }), EffectKind::Realize) => {
                Err(DispatchError(
                    "realize completion returned property-submission evidence".to_owned(),
                ))
            }
            (Ok(LifecycleEffectSuccess::ParameterSubmitted { .. }), EffectKind::Realize) => Err(
                DispatchError("realize completion returned parameter-update evidence".to_owned()),
            ),
            (Ok(LifecycleEffectSuccess::Realized { .. }), _) => Err(DispatchError(
                "non-realize completion returned realized execution groups".to_owned(),
            )),
            _ => Ok(None),
        }
    }

    fn allocate_token(&mut self) -> Result<EffectToken, DispatchError> {
        let token = EffectToken(self.next_token);
        self.next_token = self.next_token.checked_add(1).ok_or_else(|| {
            DispatchError(
                "lifecycle effect token space exhausted; tokens cannot be reused".to_owned(),
            )
        })?;
        Ok(token)
    }
}

fn public_state(state: &State) -> LifecycleState {
    match state {
        State::Offline {} => LifecycleState::Offline,
        State::Configuring {} => LifecycleState::Configuring,
        State::Ready {} => LifecycleState::Ready,
        State::Running {} => LifecycleState::Running,
        State::Fault {} => LifecycleState::Fault,
    }
}

const fn event_name(event: &LifecycleEvent) -> &'static str {
    match event {
        LifecycleEvent::Load(_) => "load",
        LifecycleEvent::Start => "start",
        LifecycleEvent::Stop => "stop",
        LifecycleEvent::StartExecutionGroup(_) => "start-execution-group",
        LifecycleEvent::StopExecutionGroup(_) => "stop-execution-group",
        LifecycleEvent::Reset => "reset",
        LifecycleEvent::UpdateProperties { .. } => "update-properties",
        LifecycleEvent::UpdateParameter { .. } => "update-parameter",
        LifecycleEvent::Reload(_) => "reload",
        LifecycleEvent::Retry => "retry",
        LifecycleEvent::Unload => "unload",
        LifecycleEvent::RequiredObjectFailed(_) => "required-object-failed",
        LifecycleEvent::FiniteSourceCompleted => "finite-source-completed",
        LifecycleEvent::EffectCompleted(_) => "effect-completed",
    }
}

#[cfg(test)]
mod hierarchy_tests {
    use super::{State, Superstate};
    use statig::blocking::State as _;

    #[test]
    fn every_managed_leaf_declares_the_managed_superstate() {
        for mut state in [
            State::configuring(),
            State::ready(),
            State::running(),
            State::fault(),
        ] {
            assert!(matches!(state.superstate(), Some(Superstate::Managed {})));
        }
        let mut offline = State::offline();
        assert!(offline.superstate().is_none());
    }
}
