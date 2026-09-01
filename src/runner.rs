use crate::{
    DispatchError, DispatchOutcome, LifecycleDispatcher, LifecycleEffect, LifecycleEffectResult,
    LifecycleEvent, LifecycleState, ScientificDiagnostic,
};

/// Executes blocking graph work after the Statig handler has returned.
pub trait EffectExecutor {
    /// Performs one typed blocking effect outside the lifecycle handler.
    ///
    /// # Errors
    ///
    /// Returns a scientific diagnostic that is sent back as a typed lifecycle
    /// completion event.
    fn execute(&mut self, effect: &LifecycleEffect) -> Result<(), ScientificDiagnostic>;
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

    /// Dispatches an event and synchronously executes any emitted effect.
    ///
    /// # Errors
    ///
    /// Returns a dispatcher error if the event or typed completion is invalid.
    pub fn dispatch(&mut self, event: LifecycleEvent) -> Result<LifecycleState, DispatchError> {
        let DispatchOutcome { effect, .. } = self.dispatcher.dispatch(event)?;
        if let Some(effect) = effect {
            let result = self.executor.execute(&effect);
            let completion = LifecycleEffectResult::from_effect(&effect, result);
            self.dispatcher
                .dispatch(LifecycleEvent::EffectCompleted(completion))?;
        }
        Ok(self.state())
    }

    #[must_use]
    pub fn into_executor(self) -> E {
        self.executor
    }
}
