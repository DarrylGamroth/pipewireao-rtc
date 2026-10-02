use pipewireao_rtc::{
    DevelopmentConfig, EndpointFactory, ExecutionMode, ObjectRealization, RunControl,
};

const TRANSPORT: &str = r#"
profile = development execution = external-rtc authority = none
claim = development-characterization rate = 100/1
sources = [
    { ownership = external run-control = application node.name = plant-frame
      ports = [ { name = frame direction = output element-type = U16_LE shape = [ 352 352 ] schema = org.test.frame/1 } ] }
    { ownership = external node.name = controller-command
      ports = [ { name = command direction = output element-type = F32_LE shape = [ 277 ] schema = org.test.command/1 } ] }
]
graphs = []
sinks = [
    { ownership = external node.name = controller-frame
      ports = [ { name = frame direction = input element-type = U16_LE shape = [ 352 352 ] schema = org.test.frame/1 } ] }
    { ownership = external node.name = plant-command
      ports = [ { name = command direction = input element-type = F32_LE shape = [ 277 ] schema = org.test.command/1 } ] }
]
execution-groups = [] properties = {} parameters = {} observations = []
links = [
    { output = "plant-frame:frame" input = "controller-frame:frame" passive = false }
    { output = "controller-command:command" input = "plant-command:command" passive = false }
]
"#;

fn rejected(before: &str, after: &str, field: &str) {
    assert!(TRANSPORT.contains(before));
    let document = TRANSPORT.replacen(before, after, 1);
    let error = DevelopmentConfig::parse(&document).expect_err("invalid transport configuration");
    assert_eq!(error.field(), field, "{error}");
}

#[test]
fn external_rtc_resolves_two_disconnected_transport_legs() {
    let config = DevelopmentConfig::parse(TRANSPORT).expect("external RTC transport");
    assert_eq!(config.execution, ExecutionMode::ExternalRtc);
    assert_eq!(config.object_count(), 4);
    assert_eq!(config.owned_object_count(), 0);
    assert!(config.owned_node_names().is_empty());
    assert!(config.session_controlled_graph_names().is_empty());
    assert!(config.execution_group_names().is_empty());
    assert_eq!(config.topological_node_names().len(), 4);
    assert_eq!(config.links_downstream_first().len(), 2);
    for endpoint in config.sources.iter().chain(&config.sinks) {
        assert_eq!(
            endpoint.realization,
            ObjectRealization::External {
                run_control: RunControl::Application,
            }
        );
    }
}

#[test]
fn external_rtc_rejects_graphs_and_session_features() {
    rejected(
        "graphs = []",
        r"graphs = [ { ownership = external run-control = application node.name = graph
            ports = [ { name = input direction = input element-type = F32_LE shape = [ 277 ] schema = org.test.command/1 }
                      { name = output direction = output element-type = F32_LE shape = [ 277 ] schema = org.test.command/1 } ] } ]",
        "graphs",
    );
    for (before, after, field) in [
        (
            "execution-groups = []",
            "execution-groups = [ { name = main nodes = [ plant-frame ] } ]",
            "execution-groups",
        ),
        (
            "properties = {}",
            "properties = { gain = 0.2 }",
            "properties",
        ),
        (
            "parameters = {}",
            "parameters = { matrix = [ 1 2 ] }",
            "parameters",
        ),
        (
            "observations = []",
            r#"observations = [ "plant-frame:frame" ]"#,
            "observations",
        ),
        (
            "run-control = application",
            "run-control = session",
            "sources[0].run-control",
        ),
        (
            "name = frame direction = output",
            "name = frame direction = output parameter = true",
            "sources[0].ports.frame.parameter",
        ),
        (
            "name = frame direction = input",
            "name = frame direction = input parameter = true",
            "sinks[0].ports.frame.parameter",
        ),
        (
            "ownership = external run-control = application",
            "factory = pipewireao.simulated-complete-frame",
            "sources[0].ownership",
        ),
        (
            "ownership = external node.name = controller-frame",
            "factory = api.pipewireao.discard node.name = controller-frame",
            "sinks[0].ownership",
        ),
        (
            "ownership = external run-control = application",
            "factory = pipewireao.runtime-parameter",
            "sources[0].ownership",
        ),
    ] {
        rejected(before, after, field);
    }
}

#[test]
fn external_rtc_retains_exact_link_contracts() {
    for (before, after, field) in [
        ("input = \"controller-frame:frame\"", "input = \"controller-frame:missing\"", "links[0].input"),
        ("output = \"plant-frame:frame\"", "output = \"missing:frame\"", "links[0].output"),
        ("direction = input element-type = U16_LE", "direction = input element-type = F32_LE", "links[0].element-type"),
        ("direction = input element-type = U16_LE shape = [ 352 352 ]", "direction = input element-type = U16_LE shape = [ 352 351 ]", "links[0].shape"),
        ("direction = input element-type = U16_LE shape = [ 352 352 ] schema = org.test.frame/1", "direction = input element-type = U16_LE shape = [ 352 352 ] schema = org.test.other/1", "links[0].schema"),
        ("direction = input element-type = U16_LE", "direction = input rate = 50/1 element-type = U16_LE", "links[0].rate"),
        ("passive = false", "passive = true", "links[0].passive"),
        ("{ output = \"controller-command:command\" input = \"plant-command:command\" passive = false }", "", "port plant-command:command"),
        ("{ output = \"plant-frame:frame\" input = \"controller-frame:frame\" passive = false }", "{ output = \"controller-command:command\" input = \"plant-command:command\" passive = false }", "links[1]"),
    ] {
        rejected(before, after, field);
    }
}

#[test]
fn external_rtc_validation_rejects_programmatic_ownership_changes() {
    let mut config = DevelopmentConfig::parse(TRANSPORT).unwrap();
    config.sources[0].realization = ObjectRealization::External {
        run_control: RunControl::Session,
    };
    assert_eq!(
        config.validate().unwrap_err().field(),
        "sources[0].run-control"
    );
    config.sources[0].realization =
        ObjectRealization::Factory(EndpointFactory::RuntimeParameterSource);
    assert_eq!(
        config.validate().unwrap_err().field(),
        "sources[0].ownership"
    );
}

#[test]
fn existing_modes_still_require_processing_graphs() {
    // Endpoint run-control omission preserves the pre-existing endpoint syntax.
    let document = TRANSPORT.replace("run-control = application", "");
    for mode in ["complete-frame", "row-block"] {
        let document = document.replace("external-rtc", mode);
        assert_eq!(
            DevelopmentConfig::parse(&document).unwrap_err().field(),
            "graphs"
        );
    }
}

#[test]
fn external_rtc_lifecycle_accepts_empty_execution_groups() {
    use pipewireao_rtc::{
        LifecycleDispatcher, LifecycleEffectResult, LifecycleEvent, LifecycleState,
    };
    let config = DevelopmentConfig::parse(TRANSPORT).unwrap();
    let mut dispatcher = LifecycleDispatcher::new();
    for (event, expected) in [
        (LifecycleEvent::Load(config.into()), LifecycleState::Ready),
        (LifecycleEvent::Start, LifecycleState::Running),
        (LifecycleEvent::Stop, LifecycleState::Ready),
        (LifecycleEvent::Start, LifecycleState::Running),
        (LifecycleEvent::Stop, LifecycleState::Ready),
        (LifecycleEvent::Unload, LifecycleState::Offline),
    ] {
        let effect = dispatcher.dispatch(event).unwrap().effect.unwrap();
        let result = LifecycleEffectResult::from_effect(&effect, Ok(()));
        assert_eq!(
            dispatcher
                .dispatch(LifecycleEvent::EffectCompleted(result))
                .unwrap()
                .state,
            expected
        );
        assert!(dispatcher.execution_group_states().is_empty());
    }
}

#[test]
fn existing_modes_still_forbid_direct_source_sink_links() {
    use pipewireao_rtc::LinkSpec;
    let document = include_str!("../fixtures/minimal-development.conf");
    for execution in [ExecutionMode::CompleteFrame, ExecutionMode::RowBlock] {
        let mut config = DevelopmentConfig::parse(document).unwrap();
        config.execution = execution;
        config.links = vec![LinkSpec {
            output: format!(
                "{}:{}",
                config.sources[0].node_name, config.sources[0].ports[0].name
            ),
            input: format!(
                "{}:{}",
                config.sinks[0].node_name, config.sinks[0].ports[0].name
            ),
            passive: false,
        }];
        assert_eq!(config.validate().unwrap_err().field(), "links[0]");
    }
}
