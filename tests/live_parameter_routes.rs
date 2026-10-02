#![cfg(feature = "live")]

use pipewireao_rtc::{
    DevelopmentConfig, LifecycleEvent, LifecycleState, LiveGraphAdapter, NdArrayParameterValue,
    Runner,
};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

#[test]
#[ignore = "requires a private core and a preloaded looping scientific graph"]
fn runtime_parameter_route_without_initial_file_supports_later_replacement() {
    let remote = std::env::var("PIPEWIREAO_RTC_CONTROL_TEST_REMOTE").unwrap();
    let path = PathBuf::from(std::env::var_os("PIPEWIREAO_RTC_CONTROL_TEST_CONFIG").unwrap());
    let graph_name = std::env::var("PIPEWIREAO_RTC_CONTROL_TEST_GRAPH").unwrap();
    let payload =
        PathBuf::from(std::env::var_os("PIPEWIREAO_RTC_CONTROL_TEST_PARAMETER_PAYLOAD").unwrap());
    let mut config = DevelopmentConfig::load(&path).unwrap();
    let graph = config
        .graphs
        .iter()
        .find(|graph| graph.node_name == graph_name)
        .unwrap();
    let port = graph
        .ports
        .iter()
        .find(|port| port.parameter)
        .unwrap()
        .clone();
    let parameter_node = port.name.split(':').next().unwrap().to_owned();
    let value = NdArrayParameterValue {
        element_type: port.element_type.clone(),
        shape: port.shape.clone(),
        schema: port.schema.clone(),
        bytes: Arc::new(std::fs::read(payload).unwrap()),
    };
    config.parameters.clear();
    config.validate().expect("live-update-only route");
    let mut runner = Runner::new(LiveGraphAdapter::connect(remote).unwrap());
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::Load(config.into()))
            .unwrap(),
        LifecycleState::Ready
    );
    assert_eq!(discarded_buffers(runner.executor_mut()), 0);
    runner
        .executor()
        .validate_parameter_update(&graph_name, &port.name, &value)
        .expect("route exists without a queued initial value");
    assert_eq!(
        runner.dispatch(LifecycleEvent::Start).unwrap(),
        LifecycleState::Running,
        "preloaded owner start: {:?}",
        runner.diagnostic()
    );
    assert!(discarded_buffers(runner.executor_mut()) > 0);
    let before = runner
        .executor()
        .observe_parameter_generation(&graph_name, &parameter_node)
        .unwrap();
    assert_eq!(
        runner
            .dispatch(LifecycleEvent::UpdateParameter {
                graph: graph_name.clone(),
                parameter: port.name,
                value,
            })
            .unwrap(),
        LifecycleState::Running,
        "live replacement: {:?}",
        runner.diagnostic()
    );
    let adopted = await_parameter_adoption(
        runner.executor(),
        &graph_name,
        &parameter_node,
        before.requested,
    );
    await_output_progress(runner.executor_mut(), &graph_name, &parameter_node, adopted);
    assert!(runner.diagnostic().is_none());
    assert_eq!(
        runner.dispatch(LifecycleEvent::Stop).unwrap(),
        LifecycleState::Ready
    );
    assert_eq!(
        runner.dispatch(LifecycleEvent::Unload).unwrap(),
        LifecycleState::Offline
    );
}

fn await_parameter_adoption(
    adapter: &LiveGraphAdapter,
    graph: &str,
    node: &str,
    previous: i64,
) -> i64 {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let observed = adapter.observe_parameter_generation(graph, node).unwrap();
        if observed.requested > previous && observed.active == observed.requested {
            return observed.active;
        }
        assert!(
            Instant::now() < deadline,
            "later parameter was not published and adopted: {observed:?}"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn discarded_buffers(adapter: &mut LiveGraphAdapter) -> u64 {
    adapter.observe_discarded_buffers().unwrap().values().sum()
}

fn await_output_progress(adapter: &mut LiveGraphAdapter, graph: &str, node: &str, adopted: i64) {
    let before = discarded_buffers(adapter);
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let observed = adapter.observe_parameter_generation(graph, node).unwrap();
        assert_eq!(observed.requested, adopted, "submitted generation changed");
        assert_eq!(observed.active, adopted, "adopted generation changed");
        let current = discarded_buffers(adapter);
        if current > before {
            eprintln!(
                "{graph}:{node}: generation {adopted} active; output count {before} -> {current}"
            );
            return;
        }
        assert!(
            Instant::now() < deadline,
            "output did not advance after parameter adoption: {observed:?}, count {current}"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
}
