use crate::{DevelopmentConfig, ScientificDiagnostic};
use statig::blocking::IntoStateMachineExt;
use statig::prelude::{state_machine, Handled, Outcome, Super, Transition};
use std::fmt;
use std::path::PathBuf;

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
    Cleanup,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EffectOrigin {
    OfflineLoad,
    ReadyReload,
    FaultRetry,
    ReadyStart,
    RunningStop,
    FiniteSourceCompletion,
    ConfiguringUnload,
    ReadyUnload,
    RunningUnload,
    FaultUnload,
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
            | Self::Cleanup { token, .. } => *token,
        }
    }

    #[must_use]
    pub const fn kind(&self) -> EffectKind {
        match self {
            Self::Realize { .. } => EffectKind::Realize,
            Self::Start { .. } => EffectKind::Start,
            Self::Stop { .. } => EffectKind::Stop,
            Self::Cleanup { .. } => EffectKind::Cleanup,
        }
    }

    #[must_use]
    pub const fn origin(&self) -> EffectOrigin {
        match self {
            Self::Realize { origin, .. }
            | Self::Start { origin, .. }
            | Self::Stop { origin, .. }
            | Self::Cleanup { origin, .. } => *origin,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LifecycleEffectResult {
    pub token: EffectToken,
    pub kind: EffectKind,
    pub origin: EffectOrigin,
    pub result: Result<(), ScientificDiagnostic>,
}

impl LifecycleEffectResult {
    #[must_use]
    pub fn from_effect(effect: &LifecycleEffect, result: Result<(), ScientificDiagnostic>) -> Self {
        Self {
            token: effect.token(),
            kind: effect.kind(),
            origin: effect.origin(),
            result,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum LifecycleEvent {
    Load(ConfigurationInput),
    Start,
    Stop,
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
                    Ok(()) => Transition(State::ready()),
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
            MachineEvent::Start(effect) => {
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
                    Ok(()) => Transition(State::running()),
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
            MachineEvent::Stop(effect) | MachineEvent::FiniteSourceCompleted(effect) => {
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
                    Ok(()) => Transition(State::ready()),
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
                    Ok(()) => {
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

        if self.pending.is_some() {
            match (&event, self.state()) {
                (LifecycleEvent::Unload, _)
                | (
                    LifecycleEvent::RequiredObjectFailed(_),
                    LifecycleState::Ready | LifecycleState::Running,
                ) => {
                    self.pending = None;
                }
                _ => {
                    return Err(DispatchError(format!(
                        "event {} rejected while {:?} effect is pending",
                        event_name(&event),
                        self.pending.as_ref().map(LifecycleEffect::kind)
                    )));
                }
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

        self.pending = None;
        self.machine
            .handle(&MachineEvent::EffectCompleted(completion));
        if self.machine.inner().rejected {
            return Err(DispatchError(
                "validated completion was not accepted by the originating transition".to_owned(),
            ));
        }
        Ok(DispatchOutcome {
            state: self.state(),
            effect: None,
        })
    }

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
