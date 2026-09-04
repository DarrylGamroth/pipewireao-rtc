use crate::{
    DispatchError, DispatchOutcome, LifecycleDispatcher, LifecycleEffect, LifecycleEffectResult,
    LifecycleEffectSuccess, LifecycleEvent, LifecycleState, ScientificDiagnostic,
};
use std::collections::BTreeMap;

/// Executes blocking graph work after the Statig handler has returned.
pub trait EffectExecutor {
    /// Performs one typed blocking effect outside the lifecycle handler.
    ///
    /// # Errors
    ///
    /// Returns a scientific diagnostic that is sent back as a typed lifecycle
    /// completion event.
    fn execute(
        &mut self,
        effect: &LifecycleEffect,
    ) -> Result<LifecycleEffectSuccess, ScientificDiagnostic>;

    /// Revalidates required objects while a realized session is idle or running.
    ///
    /// Potentially blocking adapter work remains outside the lifecycle handler.
    /// Executors without externally owned objects need no monitoring work.
    ///
    /// # Errors
    ///
    /// Returns the scientific diagnostic to dispatch when a required object is
    /// lost or no longer satisfies its admitted contract.
    fn check_required_objects(&mut self) -> Result<(), ScientificDiagnostic> {
        Ok(())
    }
}

/// One lifecycle owner combining the serialized dispatcher with one graph adapter.
pub struct Runner<E> {
    dispatcher: LifecycleDispatcher,
    executor: E,
}

impl<E: EffectExecutor> Runner<E> {
    #[must_use]
    pub fn new(executor: E) -> Self {
        Self {
            dispatcher: LifecycleDispatcher::new(),
            executor,
        }
    }

    #[must_use]
    pub fn state(&self) -> LifecycleState {
        self.dispatcher.state()
    }

    #[must_use]
    pub fn executor(&self) -> &E {
        &self.executor
    }

    pub fn executor_mut(&mut self) -> &mut E {
        &mut self.executor
    }

    #[must_use]
    pub fn diagnostic(&self) -> Option<&ScientificDiagnostic> {
        self.dispatcher.diagnostic()
    }

    #[must_use]
    pub fn execution_group_states(&self) -> &BTreeMap<String, crate::ExecutionGroupState> {
        self.dispatcher.execution_group_states()
    }

    /// Dispatches an event and synchronously executes any emitted effect.
    ///
    /// # Errors
    ///
    /// Returns a dispatcher error if the event or typed completion is invalid.
    pub fn dispatch(&mut self, event: LifecycleEvent) -> Result<LifecycleState, DispatchError> {
        let DispatchOutcome { effect, .. } = self.dispatcher.dispatch(event)?;
        if let Some(effect) = effect {
            let result = self.executor.execute(&effect);
            let completion = LifecycleEffectResult::from_output(&effect, result);
            self.dispatcher
                .dispatch(LifecycleEvent::EffectCompleted(completion))?;
        }
        Ok(self.state())
    }

    /// Checks required objects and serializes any failure through the lifecycle.
    ///
    /// # Errors
    ///
    /// Returns a dispatcher error if the required-object failure event cannot
    /// be accepted by the current lifecycle state.
    pub fn poll_required_objects(&mut self) -> Result<LifecycleState, DispatchError> {
        if !matches!(
            self.state(),
            LifecycleState::Ready | LifecycleState::Running
        ) {
            return Ok(self.state());
        }
        if let Err(diagnostic) = self.executor.check_required_objects() {
            return self.dispatch(LifecycleEvent::RequiredObjectFailed(diagnostic));
        }
        Ok(self.state())
    }

    #[must_use]
    pub fn into_executor(self) -> E {
        self.executor
    }
}
