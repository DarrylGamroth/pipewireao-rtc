use pipewireao_rtc::{
    ConfigurationInput, DevelopmentConfig, EffectExecutor, LifecycleEffect, LifecycleEvent,
    LifecycleState, Runner, ScientificDiagnostic,
};
use std::collections::BTreeSet;

const VALID: &str = include_str!("../fixtures/minimal-development.conf");

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum CreationPoint {
    Source,
    Graph,
    Sink,
    SourceGraphLink,
    GraphSinkLink,
}

#[derive(Debug)]
struct FakeGraphAdapter {
    owned: Vec<&'static str>,
    unrelated: BTreeSet<&'static str>,
    fail_at: Option<CreationPoint>,
    running: bool,
    observer_attached: bool,
}

impl FakeGraphAdapter {
    fn new(fail_at: Option<CreationPoint>) -> Self {
        Self {
            owned: Vec::new(),
            unrelated: BTreeSet::from(["unrelated-fixture-node"]),
            fail_at,
            running: false,
            observer_attached: false,
        }
    }

    fn create(
        &mut self,
        point: CreationPoint,
        object: &'static str,
    ) -> Result<(), ScientificDiagnostic> {
        self.owned.push(object);
        if self.fail_at == Some(point) {
            return Err(ScientificDiagnostic::new(
                object,
                format!("injected failure after {point:?} creation"),
            ));
        }
        Ok(())
    }

    fn realize(&mut self, config: &DevelopmentConfig) -> Result<(), ScientificDiagnostic> {
        config.validate()?;
        self.cleanup();
        let result = self
            .create(CreationPoint::Source, "node:source")
            .and_then(|()| self.create(CreationPoint::Graph, "node:graph"))
            .and_then(|()| self.create(CreationPoint::Sink, "node:sink"))
            .and_then(|()| self.create(CreationPoint::SourceGraphLink, "link:source->graph"))
            .and_then(|()| self.create(CreationPoint::GraphSinkLink, "link:graph->sink"));
        if result.is_err() {
            self.cleanup();
        }
        result
    }

    fn cleanup(&mut self) {
        self.running = false;
        self.owned.clear();
    }
}

impl EffectExecutor for FakeGraphAdapter {
    fn execute(&mut self, effect: &LifecycleEffect) -> Result<(), ScientificDiagnostic> {
        match effect {
            LifecycleEffect::Realize { config, .. } => match config {
                ConfigurationInput::Resolved(config) => self.realize(config),
                ConfigurationInput::File(_) => Err(ScientificDiagnostic::new(
                    "configuration",
                    "fake adapter accepts only resolved test configurations",
                )),
            },
            LifecycleEffect::Start { .. } => {
                if self.owned.len() != 5 {
                    return Err(ScientificDiagnostic::new(
                        "topology",
                        "exact source -> graph -> sink topology is incomplete",
                    ));
                }
                self.running = true;
                Ok(())
            }
            LifecycleEffect::Stop { .. } => {
                self.running = false;
                Ok(())
            }
            LifecycleEffect::Cleanup { .. } => {
                self.cleanup();
                Ok(())
            }
        }
    }
}

fn config() -> DevelopmentConfig {
    DevelopmentConfig::parse(VALID).expect("valid test configuration")
}

#[test]
fn exact_topology_operates_without_gui_or_observer() {
    let mut runner = Runner::new(FakeGraphAdapter::new(None));
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::Load(config().into()))
            .unwrap(),
        LifecycleState::Ready
    );
    assert_eq!(
        runner.executor().owned,
        [
            "node:source",
            "node:graph",
            "node:sink",
            "link:source->graph",
            "link:graph->sink",
        ]
    );
    assert!(!runner.executor().observer_attached);
    assert_eq!(
        runner.dispatch(LifecycleEvent::Start).unwrap(),
        LifecycleState::Running
    );
    assert!(runner.executor().running);
}

#[test]
fn every_creation_failure_cleans_only_owned_objects_and_retry_works() {
    for point in [
        CreationPoint::Source,
        CreationPoint::Graph,
        CreationPoint::Sink,
        CreationPoint::SourceGraphLink,
        CreationPoint::GraphSinkLink,
    ] {
        let mut runner = Runner::new(FakeGraphAdapter::new(Some(point)));
        assert_eq!(
            runner
                .dispatch(LifecycleEvent::Load(config().into()))
                .unwrap(),
            LifecycleState::Fault,
            "failure point {point:?}"
        );
        assert!(runner.executor().owned.is_empty());
        assert!(runner
            .executor()
            .unrelated
            .contains("unrelated-fixture-node"));

        runner.executor_mut().fail_at = None;
        assert_eq!(
            runner.dispatch(LifecycleEvent::Retry).unwrap(),
            LifecycleState::Ready
        );
        assert_eq!(runner.executor().owned.len(), 5);
        assert_eq!(
            runner.dispatch(LifecycleEvent::Unload).unwrap(),
            LifecycleState::Offline
        );
        assert!(runner.executor().owned.is_empty());
        assert!(runner
            .executor()
            .unrelated
            .contains("unrelated-fixture-node"));
    }
}

#[test]
fn runtime_failure_then_unload_preserves_unrelated_objects() {
    let mut runner = Runner::new(FakeGraphAdapter::new(None));
    runner
        .dispatch(LifecycleEvent::Load(config().into()))
        .unwrap();
    runner.dispatch(LifecycleEvent::Start).unwrap();
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::RequiredObjectFailed(
                ScientificDiagnostic::new("graph.output", "required port disappeared"),
            ))
            .unwrap(),
        LifecycleState::Fault
    );
    assert_eq!(
        runner.dispatch(LifecycleEvent::Unload).unwrap(),
        LifecycleState::Offline
    );
    assert!(runner.executor().owned.is_empty());
    assert_eq!(
        runner.executor().unrelated,
        BTreeSet::from(["unrelated-fixture-node"])
    );
}
