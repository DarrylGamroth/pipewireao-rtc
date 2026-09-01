use pipewireao_rtc::{
    ConfigurationInput, DevelopmentConfig, EffectExecutor, LifecycleEffect, LifecycleEffectSuccess,
    LifecycleEvent, LifecycleState, Runner, ScientificDiagnostic,
};
use std::collections::{BTreeMap, BTreeSet};

const MINIMAL: &str = include_str!("../fixtures/minimal-development.conf");
const SERIAL: &str = include_str!("../fixtures/serial-development.conf");
const FORK: &str = include_str!("../fixtures/fork-development.conf");
const INDEPENDENT: &str = include_str!("../fixtures/independent-development.conf");

#[derive(Debug)]
struct FakeGraphAdapter {
    owned: Vec<String>,
    unrelated: BTreeSet<&'static str>,
    fail_after: Option<usize>,
    running: bool,
    execution_groups: BTreeMap<String, bool>,
    observer_attached: bool,
}

impl FakeGraphAdapter {
    fn new(fail_after: Option<usize>) -> Self {
        Self {
            owned: Vec::new(),
            unrelated: BTreeSet::from(["unrelated-fixture-node"]),
            fail_after,
            running: false,
            execution_groups: BTreeMap::new(),
            observer_attached: false,
        }
    }

    fn create(&mut self, object: String) -> Result<(), ScientificDiagnostic> {
        self.owned.push(object.clone());
        if self.fail_after == Some(self.owned.len()) {
            return Err(ScientificDiagnostic::new(
                object,
                format!("injected failure after creation point {}", self.owned.len()),
            ));
        }
        Ok(())
    }

    fn realize(&mut self, config: &DevelopmentConfig) -> Result<(), ScientificDiagnostic> {
        config.validate()?;
        self.cleanup();
        let result = (|| {
            for node in config.node_names() {
                self.create(format!("node:{node}"))?;
            }
            for (index, link) in config.links_downstream_first() {
                self.create(format!("link[{index}]:{}->{}", link.output, link.input))?;
            }
            Ok(())
        })();
        if result.is_err() {
            self.cleanup();
        } else {
            self.execution_groups = config
                .execution_group_names()
                .into_iter()
                .map(|name| (name, false))
                .collect();
        }
        result
    }

    fn cleanup(&mut self) {
        self.running = false;
        self.execution_groups.clear();
        self.owned.clear();
    }
}

impl EffectExecutor for FakeGraphAdapter {
    fn execute(
        &mut self,
        effect: &LifecycleEffect,
    ) -> Result<LifecycleEffectSuccess, ScientificDiagnostic> {
        match effect {
            LifecycleEffect::Realize { config, .. } => match config {
                ConfigurationInput::Resolved(config) => {
                    self.realize(config)?;
                    Ok(LifecycleEffectSuccess::Realized {
                        execution_groups: config.execution_group_names(),
                    })
                }
                ConfigurationInput::File(_) => Err(ScientificDiagnostic::new(
                    "configuration",
                    "fake adapter accepts only resolved test configurations",
                )),
            },
            LifecycleEffect::Start { .. } => {
                if self.owned.is_empty() {
                    return Err(ScientificDiagnostic::new(
                        "topology",
                        "all declared objects and links must exist before start",
                    ));
                }
                self.running = true;
                for running in self.execution_groups.values_mut() {
                    *running = true;
                }
                Ok(LifecycleEffectSuccess::Completed)
            }
            LifecycleEffect::Stop { .. } => {
                self.running = false;
                for running in self.execution_groups.values_mut() {
                    *running = false;
                }
                Ok(LifecycleEffectSuccess::Completed)
            }
            LifecycleEffect::StartExecutionGroup { name, .. } => {
                let running = self.execution_groups.get_mut(name).ok_or_else(|| {
                    ScientificDiagnostic::new(
                        format!("execution-group {name}"),
                        "group is not realized",
                    )
                })?;
                *running = true;
                Ok(LifecycleEffectSuccess::Completed)
            }
            LifecycleEffect::StopExecutionGroup { name, .. } => {
                let running = self.execution_groups.get_mut(name).ok_or_else(|| {
                    ScientificDiagnostic::new(
                        format!("execution-group {name}"),
                        "group is not realized",
                    )
                })?;
                *running = false;
                Ok(LifecycleEffectSuccess::Completed)
            }
            LifecycleEffect::Cleanup { .. } => {
                self.cleanup();
                Ok(LifecycleEffectSuccess::Completed)
            }
        }
    }
}

fn config(document: &str) -> DevelopmentConfig {
    DevelopmentConfig::parse(document).expect("valid test configuration")
}

#[test]
fn serial_forked_and_independent_topologies_operate_without_gui_or_observer() {
    for document in [MINIMAL, SERIAL, FORK, INDEPENDENT] {
        let config = config(document);
        let expected_owned = config.object_count() + config.links.len();
        let mut runner = Runner::new(FakeGraphAdapter::new(None));
        assert_eq!(
            runner
                .dispatch(LifecycleEvent::Load(config.into()))
                .unwrap(),
            LifecycleState::Ready
        );
        assert_eq!(runner.executor().owned.len(), expected_owned);
        assert!(!runner.executor().observer_attached);
        assert_eq!(
            runner.dispatch(LifecycleEvent::Start).unwrap(),
            LifecycleState::Running
        );
        assert!(runner.executor().running);
        assert_eq!(
            runner.dispatch(LifecycleEvent::Stop).unwrap(),
            LifecycleState::Ready
        );
        assert_eq!(
            runner.dispatch(LifecycleEvent::Unload).unwrap(),
            LifecycleState::Offline
        );
        assert!(runner.executor().owned.is_empty());
    }
}

#[test]
fn fork_uses_two_ordinary_declared_links_from_one_source_output() {
    let config = config(FORK);
    let mut runner = Runner::new(FakeGraphAdapter::new(None));
    runner
        .dispatch(LifecycleEvent::Load(config.into()))
        .unwrap();
    let source_links = runner
        .executor()
        .owned
        .iter()
        .filter(|object| object.contains("pipewireao-rtc-fork-source:output->"))
        .collect::<Vec<_>>();
    assert_eq!(source_links.len(), 2);
    assert_ne!(source_links[0], source_links[1]);
}

#[test]
fn selective_group_control_preserves_session_objects_and_other_groups() {
    for (document, first, second) in [
        (FORK, "branch-a", "branch-b"),
        (INDEPENDENT, "path-a", "path-b"),
    ] {
        let config = config(document);
        let expected_owned = config.object_count() + config.links.len();
        let mut runner = Runner::new(FakeGraphAdapter::new(None));
        runner
            .dispatch(LifecycleEvent::Load(config.into()))
            .unwrap();
        runner.dispatch(LifecycleEvent::Start).unwrap();

        assert_eq!(
            runner
                .dispatch(LifecycleEvent::StopExecutionGroup(first.to_owned()))
                .unwrap(),
            LifecycleState::Running
        );
        assert!(!runner.executor().execution_groups[first]);
        assert!(runner.executor().execution_groups[second]);
        assert_eq!(runner.executor().owned.len(), expected_owned);

        runner
            .dispatch(LifecycleEvent::StartExecutionGroup(first.to_owned()))
            .unwrap();
        assert!(runner.executor().execution_groups[first]);
        assert!(runner.executor().execution_groups[second]);

        runner.dispatch(LifecycleEvent::Stop).unwrap();
        assert!(runner
            .executor()
            .execution_groups
            .values()
            .all(|running| !running));
        runner.dispatch(LifecycleEvent::Unload).unwrap();
        assert!(runner.executor().owned.is_empty());
    }
}

#[test]
fn every_creation_failure_cleans_only_owned_objects_and_retry_works() {
    for document in [MINIMAL, SERIAL, FORK, INDEPENDENT] {
        let config = config(document);
        let creation_points = config.object_count() + config.links.len();
        for point in 1..=creation_points {
            let mut runner = Runner::new(FakeGraphAdapter::new(Some(point)));
            assert_eq!(
                runner
                    .dispatch(LifecycleEvent::Load(config.clone().into()))
                    .unwrap(),
                LifecycleState::Fault,
                "failure point {point}"
            );
            assert!(runner.executor().owned.is_empty());
            assert!(runner
                .executor()
                .unrelated
                .contains("unrelated-fixture-node"));

            runner.executor_mut().fail_after = None;
            assert_eq!(
                runner.dispatch(LifecycleEvent::Retry).unwrap(),
                LifecycleState::Ready
            );
            assert_eq!(runner.executor().owned.len(), creation_points);
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
}

#[test]
fn runtime_failure_then_unload_preserves_unrelated_objects() {
    let mut runner = Runner::new(FakeGraphAdapter::new(None));
    runner
        .dispatch(LifecycleEvent::Load(config(FORK).into()))
        .unwrap();
    runner.dispatch(LifecycleEvent::Start).unwrap();
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::RequiredObjectFailed(
                ScientificDiagnostic::new("graph A.output", "required port disappeared"),
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
