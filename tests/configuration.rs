use pipewireao_rtc::{DevelopmentConfig, ObjectRealization, RunControl};

const MINIMAL: &str = include_str!("../fixtures/minimal-development.conf");
const SERIAL: &str = include_str!("../fixtures/serial-development.conf");
const FORK: &str = include_str!("../fixtures/fork-development.conf");
const INDEPENDENT: &str = include_str!("../fixtures/independent-development.conf");
const EXTERNAL: &str = include_str!("../fixtures/external-development.conf");
const AOS_HIL: &str = include_str!("../fixtures/aos-hil-development.conf");
const AOS_HIL_ATMOSPHERE: &str = include_str!("../fixtures/aos-hil-atmosphere-development.conf");
const EXTERNAL_GRAPH: &str = include_str!("../fixtures/external-graph-development.conf");
const REVOLT_NATIVE: &str = include_str!("../fixtures/revolt-classic-native-development.conf");
const REVOLT_JULIA: &str = include_str!("../fixtures/revolt-classic-julia-development.conf");
const COPPER_NATIVE: &str = include_str!("../fixtures/revolt-copper-native-development.conf");
const COPPER_JULIA: &str = include_str!("../fixtures/revolt-copper-julia-development.conf");
const LATEST_HOLD_LIVE: &str = include_str!("../fixtures/latest-hold-live.conf");
const LATEST_HOLD_JULIA_LIVE: &str = include_str!("../fixtures/latest-hold-julia-live.conf");

const LATEST_HOLD: &str = r#"
{
    profile = development execution = complete-frame authority = none
    claim = development-characterization rate = 1000/1
    sources = [ {
        factory = api.fits.source module = libpipewire-module-spa-node-factory
        node.name = slow-source plugin.path = "${PIPEWIREAO_FITS_PLUGIN}"
        args = {
            api.fits.path = "${PIPEWIREAO_RTC_FITS_PATH_HOLD}"
            api.fits.hdu = 1 api.fits.sample-rank = 1 api.fits.rate = 100/1
            api.fits.schema = org.pipewireao.rtc.slow.f32/1
            api.fits.io-mode = file api.fits.prefault = false api.fits.loop = true
            api.fits.readiness = timerfd api.fits.output-mode = frame
        }
        ports = [ { name = output direction = output element-type = F32_LE shape = [ 2 ] schema = org.pipewireao.rtc.slow.f32/1 rate = 100/1 } ]
    } ]
    graphs = [
        {
            factory = api.ndarray.latest-hold module = libpipewire-module-spa-node-factory
            node.name = slow-hold plugin.path = "${PIPEWIREAO_NDARRAY_PLUGIN}"
            args = {
                api.ndarray.element-type = F32_LE api.ndarray.shape = [ 2 ]
                api.ndarray.layout = row-major api.ndarray.schema = org.pipewireao.rtc.slow.f32/1
                api.ndarray.input-rate = 100/1 api.ndarray.output-rate = 1000/1
                api.ndarray.max-hold-cycles = 10
            }
            ports = [
                { name = input direction = input element-type = F32_LE shape = [ 2 ] schema = org.pipewireao.rtc.slow.f32/1 rate = 100/1 }
                { name = output direction = output element-type = F32_LE shape = [ 2 ] schema = org.pipewireao.rtc.slow.f32/1 }
            ]
        }
        {
            factory = pipewireao.fgn-native module = libpipewire-module-ndarray-filter-chain
            node.name = graph config.path = "${PIPEWIREAO_RTC_GRAPH_MINIMAL}"
            ports = [
                { name = input direction = input element-type = F32_LE shape = [ 2 ] schema = org.pipewireao.rtc.slow.f32/1 }
                { name = output direction = output element-type = F32_LE shape = [ 2 ] schema = org.pipewireao.rtc.command.f32/1 }
            ]
        }
    ]
    sinks = [ {
        factory = api.pipewireao.discard module = libpipewire-module-spa-node-factory
        node.name = sink plugin.path = "${PIPEWIREAO_DISCARD_PLUGIN}"
        ports = [ { name = input direction = input element-type = F32_LE shape = [ 2 ] schema = org.pipewireao.rtc.command.f32/1 } ]
    } ]
    execution-groups = [ { name = main nodes = [ slow-source slow-hold graph sink ] } ]
    properties = {} parameters = {} observations = []
    links = [
        { output = "slow-source:output" input = "slow-hold:input" passive = false }
        { output = "slow-hold:output" input = "graph:input" passive = false }
        { output = "graph:output" input = "sink:input" passive = false }
    ]
}
"#;

fn replace_once(document: &str, before: &str, after: &str) -> String {
    assert!(
        document.contains(before),
        "fixture does not contain {before:?}"
    );
    document.replacen(before, after, 1)
}

#[test]
fn maintained_session_topologies_are_resolved() {
    let cases = [
        (MINIMAL, 3, 2, 1, 1),
        (SERIAL, 4, 3, 1, 0),
        (FORK, 5, 4, 2, 0),
        (INDEPENDENT, 6, 4, 2, 0),
    ];
    for (document, objects, links, execution_groups, observations) in cases {
        let config = DevelopmentConfig::parse(document).expect("maintained topology");
        assert_eq!(config.object_count(), objects);
        assert_eq!(config.links.len(), links);
        assert_eq!(config.execution_groups.len(), execution_groups);
        assert_eq!(config.topological_node_names().len(), objects);
        assert!(config.properties.is_empty());
        assert!(config.parameters.is_empty());
        assert_eq!(config.observations.len(), observations);
        for port in config.sources.iter().flat_map(|object| &object.ports) {
            assert_eq!(port.rate, None);
        }
        for port in config.graphs.iter().flat_map(|object| &object.ports) {
            assert_eq!(port.rate, None);
        }
        for port in config.sinks.iter().flat_map(|object| &object.ports) {
            assert_eq!(port.rate, None);
        }
    }

    let external = DevelopmentConfig::parse(EXTERNAL).expect("external topology");
    assert_eq!(external.object_count(), 3);
    assert_eq!(external.owned_object_count(), 1);
    assert_eq!(external.links.len(), 2);

    let atmosphere =
        DevelopmentConfig::parse(AOS_HIL_ATMOSPHERE).expect("atmospheric HIL topology");
    assert_eq!(atmosphere.object_count(), 3);
    assert_eq!(atmosphere.owned_object_count(), 1);
    assert_eq!(atmosphere.links.len(), 2);
}

#[test]
fn latest_hold_is_admitted_as_an_ordinary_multirate_topology_node() {
    let config = DevelopmentConfig::parse(LATEST_HOLD).expect("100 Hz to 1000 Hz latest/hold");
    assert_eq!(config.object_count(), 4);
    assert_eq!(config.graphs[0].ports[0].rate.as_deref(), Some("100/1"));
    assert_eq!(config.graphs[0].ports[1].rate, None);
    assert_eq!(config.session_controlled_graph_names(), ["graph"]);
    assert_eq!(
        config.execution_group_graph_names("main"),
        Some(vec!["graph".to_owned()])
    );
    assert_eq!(
        config.execution_group_node_names("main"),
        Some(vec![
            "slow-source".to_owned(),
            "slow-hold".to_owned(),
            "graph".to_owned(),
            "sink".to_owned(),
        ])
    );

    let error = DevelopmentConfig::parse(&replace_once(
        LATEST_HOLD,
        "slow-source slow-hold graph sink",
        "slow-source graph sink",
    ))
    .expect_err("latest/hold remains a required group topology member");
    assert_eq!(error.field(), "graph slow-hold.execution-group");
}

#[test]
fn latest_hold_live_fixture_declares_primary_and_held_native_inputs() {
    let config = DevelopmentConfig::parse(LATEST_HOLD_LIVE)
        .expect("two-input native latest/hold live fixture");
    assert_eq!(config.sources.len(), 2);
    assert_eq!(config.graphs.len(), 2);
    assert_eq!(config.sinks.len(), 2);
    assert_eq!(config.owned_object_count(), 2);
    assert_eq!(config.links.len(), 5);
    assert_eq!(
        config.execution_group_node_names("hold"),
        Some(vec![
            "pipewireao-rtc-latest-hold".to_owned(),
            "pipewireao-rtc-latest-hold-graph".to_owned(),
        ])
    );
}

#[test]
fn latest_hold_julia_live_fixture_substitutes_only_the_processing_owner() {
    let native = DevelopmentConfig::parse(LATEST_HOLD_LIVE)
        .expect("two-input native latest/hold live fixture");
    let julia = DevelopmentConfig::parse(LATEST_HOLD_JULIA_LIVE)
        .expect("two-input Julia latest/hold live fixture");

    assert_eq!(julia.sources, native.sources);
    assert_eq!(julia.sinks, native.sinks);
    assert_eq!(julia.links.len(), native.links.len());
    assert_eq!(julia.owned_object_count(), 1);
    assert_eq!(
        julia.graphs[1].realization,
        ObjectRealization::External {
            run_control: RunControl::Session,
        }
    );
    assert_eq!(
        julia.execution_group_node_names("hold"),
        Some(vec![
            "pipewireao-rtc-latest-hold".to_owned(),
            "pipewireao-rtc-latest-hold-graph".to_owned(),
        ])
    );
}

#[test]
fn latest_hold_rejects_each_factory_contract_violation() {
    let cases = [
        ("api.ndarray.latest-hold", "api.ndarray.unknown", "graphs[0].factory"),
        (
            "factory = api.ndarray.latest-hold module = libpipewire-module-spa-node-factory",
            "factory = api.ndarray.latest-hold module = wrong",
            "graphs[0].module",
        ),
        ("${PIPEWIREAO_NDARRAY_PLUGIN}", "${PIPEWIREAO_WRONG_PLUGIN}", "graphs[0].plugin.path"),
        ("node.name = slow-hold plugin.path", "node.name = slow-hold config.path = \"${PIPEWIREAO_RTC_GRAPH_MINIMAL}\" plugin.path", "graphs[0].config.path"),
        ("api.ndarray.layout = row-major", "api.ndarray.layout = column-major", "graphs[0].args.api.ndarray.layout"),
        ("api.ndarray.element-type = F32_LE", "api.ndarray.element-type = U16_LE", "graphs[0].args.api.ndarray.element-type"),
        ("api.ndarray.shape = [ 2 ]", "api.ndarray.shape = [ 3 ]", "graphs[0].args.api.ndarray.shape"),
        ("api.ndarray.schema = org.pipewireao.rtc.slow.f32/1", "api.ndarray.schema = org.pipewireao.rtc.other.f32/1", "graphs[0].args.api.ndarray.schema"),
        ("api.ndarray.input-rate = 100/1", "api.ndarray.input-rate = 0/1", "graphs[0].args.api.ndarray.input-rate"),
        ("api.ndarray.output-rate = 1000/1", "api.ndarray.output-rate = 100/1", "graphs[0].args.api.ndarray.output-rate"),
        ("api.ndarray.max-hold-cycles = 10", "api.ndarray.max-hold-cycles = 0", "graphs[0].args.api.ndarray.max-hold-cycles"),
        ("api.ndarray.max-hold-cycles = 10", "api.ndarray.max-hold-cycles = 2147483648", "graphs[0].args.api.ndarray.max-hold-cycles"),
        ("name = input direction = input", "name = input direction = output", "graphs[0].ports.input.direction"),
        (
            "ports = [\n                { name = input direction = input element-type = F32_LE shape = [ 2 ] schema = org.pipewireao.rtc.slow.f32/1 rate = 100/1 }\n                { name = output direction = output",
            "ports = [\n                { name = input direction = input element-type = F32_LE shape = [ 2 ] schema = org.pipewireao.rtc.slow.f32/1 rate = 100/1 }\n                { name = output direction = input",
            "graphs[0].ports.output.direction",
        ),
        (
            "ports = [\n                { name = input direction = input element-type = F32_LE shape = [ 2 ] schema = org.pipewireao.rtc.slow.f32/1 rate = 100/1 }\n                { name = output direction = output element-type = F32_LE shape = [ 2 ] schema = org.pipewireao.rtc.slow.f32/1",
            "ports = [\n                { name = input direction = input element-type = F32_LE shape = [ 2 ] schema = org.pipewireao.rtc.slow.f32/1 rate = 100/1 }\n                { name = output direction = output element-type = F32_LE shape = [ 3 ] schema = org.pipewireao.rtc.slow.f32/1",
            "graphs[0].ports.output.shape",
        ),
        (
            "name = input direction = input element-type = F32_LE shape = [ 2 ] schema = org.pipewireao.rtc.slow.f32/1 rate = 100/1",
            "name = input direction = input parameter = true element-type = F32_LE shape = [ 2 ] schema = org.pipewireao.rtc.slow.f32/1",
            "graphs[0].ports.input.parameter",
        ),
        (
            "rate = 100/1 }\n                { name = output",
            "rate = 100/1 }\n                { name = extra direction = output element-type = F32_LE shape = [ 2 ] schema = org.pipewireao.rtc.slow.f32/1 }\n                { name = output",
            "graphs[0].ports",
        ),
        ("rate = 100/1 }\n                { name = output", "rate = 200/1 }\n                { name = output", "graphs[0].ports.input.rate"),
    ];
    for (before, after, field) in cases {
        let error = DevelopmentConfig::parse(&replace_once(LATEST_HOLD, before, after))
            .expect_err("invalid latest/hold factory declaration");
        assert_eq!(error.field(), field, "mutation {after:?}");
    }
}

#[test]
fn repeated_links_require_rationally_equivalent_effective_rates() {
    DevelopmentConfig::parse(&replace_once(
        LATEST_HOLD,
        "{ name = input direction = input element-type = F32_LE shape = [ 2 ] schema = org.pipewireao.rtc.slow.f32/1 }\n                { name = output direction = output element-type = F32_LE shape = [ 2 ] schema = org.pipewireao.rtc.command.f32/1 }",
        "{ name = input direction = input element-type = F32_LE shape = [ 2 ] schema = org.pipewireao.rtc.slow.f32/1 rate = 2000/2 }\n                { name = output direction = output element-type = F32_LE shape = [ 2 ] schema = org.pipewireao.rtc.command.f32/1 }",
    ))
    .expect("equivalent declared port rate");

    let error = DevelopmentConfig::parse(&LATEST_HOLD.replace(
        "{ name = input direction = input element-type = F32_LE shape = [ 2 ] schema = org.pipewireao.rtc.slow.f32/1 }\n                { name = output direction = output element-type = F32_LE shape = [ 2 ] schema = org.pipewireao.rtc.command.f32/1 }",
        "{ name = input direction = input element-type = F32_LE shape = [ 2 ] schema = org.pipewireao.rtc.slow.f32/1 rate = 500/1 }\n                { name = output direction = output element-type = F32_LE shape = [ 2 ] schema = org.pipewireao.rtc.command.f32/1 }",
    ))
    .expect_err("mismatched link rates");
    assert_eq!(error.field(), "links[1].rate");
}

#[test]
fn external_endpoints_are_selected_by_pipewire_contract_not_implementation() {
    let config = DevelopmentConfig::parse(AOS_HIL).expect("AOS HIL configuration");
    assert_eq!(config.object_count(), 3);
    assert_eq!(config.owned_object_count(), 1);
    assert_eq!(
        config.externally_owned_node_names(),
        ["pipewireao-aos-hil-wfs", "pipewireao-aos-hil-command"]
    );
    assert_eq!(config.owned_node_names(), ["pipewireao-rtc-aos-controller"]);
    assert_eq!(config.execution_groups[0].nodes.len(), 1);

    let cases = [
        (
            "ownership = external",
            "ownership = mystery",
            "sources[0].ownership",
        ),
        (
            "ownership = external",
            "ownership = external\n            factory = pipewireao.simulated-complete-frame",
            "sources[0].factory",
        ),
        (
            "node.name = pipewireao-aos-hil-wfs",
            "module = should-not-load\n            node.name = pipewireao-aos-hil-wfs",
            "sources[0].module",
        ),
        (
            "shape = [ 64 64 ]",
            "shape = [ 64 0 ]",
            "sources[0].ports.output_1.shape",
        ),
        (
            "org.adaptiveopticssim.hil-reference.shack-hartmann-frame.f32/1",
            "\"\"",
            "sources[0].ports.output_1.schema",
        ),
        (
            "name = input_1 direction = input element-type = F32_LE shape = [ 25 ]",
            "name = command direction = input element-type = F32_LE shape = [ 25 ]",
            "links[1].input",
        ),
        (
            "nodes = [ pipewireao-rtc-aos-controller ]",
            "nodes = [ pipewireao-aos-hil-wfs pipewireao-rtc-aos-controller ]",
            "execution-groups[0].nodes[0]",
        ),
    ];
    for (before, after, field) in cases {
        let error = DevelopmentConfig::parse(&replace_once(AOS_HIL, before, after))
            .expect_err("invalid external HIL endpoint");
        assert_eq!(error.field(), field, "configuration mutation: {after}");
    }

    let implementation_specific = replace_once(
        AOS_HIL,
        "ownership = external",
        "ownership = external\n            adapter = adaptive-optics-sim-pipewire-hil/1",
    );
    let error = DevelopmentConfig::parse(&implementation_specific)
        .expect_err("implementation identity is not part of the RTC contract");
    assert_eq!(error.field(), "sources[0].adapter");
}

#[test]
fn external_processing_graph_requires_explicit_ownership_and_run_control() {
    let config = DevelopmentConfig::parse(EXTERNAL_GRAPH).expect("external processing graph");
    assert_eq!(config.object_count(), 3);
    assert_eq!(config.owned_object_count(), 2);
    assert_eq!(
        config.externally_owned_node_names(),
        ["pipewireao-rtc-external-graph"]
    );
    assert_eq!(
        config.session_controlled_topological_node_names(),
        [
            "pipewireao-rtc-source",
            "pipewireao-rtc-external-graph",
            "pipewireao-rtc-sink"
        ]
    );
    assert_eq!(
        config.session_controlled_graph_names(),
        ["pipewireao-rtc-external-graph"]
    );

    for (before, after, field) in [
        (
            "run-control = session",
            "run-control = inherited",
            "graphs[0].run-control",
        ),
        (
            "            run-control = session\n",
            "",
            "graphs[0].run-control",
        ),
        (
            "run-control = session",
            "run-control = session\n            factory = pipewireao.fgn-native",
            "graphs[0].factory",
        ),
        (
            "node.name = pipewireao-rtc-external-graph",
            "implementation = JuliaFilterGraph\n            node.name = pipewireao-rtc-external-graph",
            "graphs[0].implementation",
        ),
        (
            "node.name = pipewireao-rtc-external-graph",
            "module = should-not-load\n            node.name = pipewireao-rtc-external-graph",
            "graphs[0].module",
        ),
    ] {
        let error = DevelopmentConfig::parse(&replace_once(EXTERNAL_GRAPH, before, after))
            .expect_err("invalid external graph declaration");
        assert_eq!(error.field(), field, "configuration mutation: {after}");
    }

    let application_controlled = replace_once(
        &replace_once(EXTERNAL_GRAPH, "run-control = session", "run-control = application"),
        "execution-groups = [\n        {\n            name = main\n            nodes = [ pipewireao-rtc-source pipewireao-rtc-external-graph pipewireao-rtc-sink ]\n        }\n    ]",
        "execution-groups = []",
    );
    let config = DevelopmentConfig::parse(&application_controlled)
        .expect("application-controlled external graph");
    assert_eq!(
        config.session_controlled_topological_node_names(),
        ["pipewireao-rtc-source", "pipewireao-rtc-sink"]
    );
    assert!(config.session_controlled_graph_names().is_empty());
    assert!(config.execution_groups.is_empty());

    let grouped_application_control = replace_once(
        EXTERNAL_GRAPH,
        "run-control = session",
        "run-control = application",
    );
    let error = DevelopmentConfig::parse(&grouped_application_control)
        .expect_err("application-controlled graph in execution group");
    assert_eq!(error.field(), "execution-groups");
}

#[test]
fn revolt_classic_variants_share_the_exact_external_plant_contract() {
    let native = DevelopmentConfig::parse(REVOLT_NATIVE).expect("native REVOLT topology");
    let julia = DevelopmentConfig::parse(REVOLT_JULIA).expect("Julia REVOLT topology");

    assert_eq!(native.object_count(), 4);
    assert_eq!(native.owned_object_count(), 2);
    assert_eq!(julia.object_count(), 4);
    assert_eq!(julia.owned_object_count(), 1);
    assert_eq!(native.links.len(), 3);
    assert_eq!(julia.links.len(), 3);
    assert_eq!(
        native.externally_owned_node_names(),
        [
            "revolt-classic-sim-wfs",
            "revolt-classic-sim-hsdm277-command"
        ]
    );
    assert_eq!(
        julia.externally_owned_node_names(),
        [
            "revolt-classic-sim-wfs",
            "pipewireao-rtc-revolt-controller",
            "revolt-classic-sim-hsdm277-command"
        ]
    );
    assert_eq!(
        julia.session_controlled_graph_names(),
        ["pipewireao-rtc-revolt-controller"]
    );

    for config in [&native, &julia] {
        assert_eq!(config.parameters.len(), 1);
        assert_eq!(config.graphs[0].ports.len(), 3);
        assert_eq!(config.sources[0].ports[0].shape, [352, 352]);
        assert!(!config.sources[0].ports[0].parameter);
        assert_eq!(
            config.sources[0].ports[0].schema,
            "org.revolt.classic.shwfs-frame.f32/1"
        );
        assert!(config.sources[1].ports[0].parameter);
        assert!(config.graphs[0].ports[1].parameter);
        assert_eq!(config.sinks[0].ports[0].shape, [277]);
        assert!(!config.sinks[0].ports[0].parameter);
        assert_eq!(
            config.sinks[0].ports[0].schema,
            "org.revolt.hsdm277.actuator-surface-opd-m.f32/1"
        );
    }

    let no_graph_input = REVOLT_NATIVE
        .replace(
            "name = \"measure:image\" direction = input",
            "name = \"measure:image\" direction = output",
        )
        .replace(
            "name = \"reconstruct:reconstructor\" direction = input parameter = true",
            "name = \"reconstruct:reconstructor\" direction = output",
        );
    let error = DevelopmentConfig::parse(&no_graph_input)
        .expect_err("processing graph without an input port");
    assert_eq!(error.field(), "graphs[0].ports");

    let no_graph_output = replace_once(
        REVOLT_NATIVE,
        "name = \"integrate:output\" direction = output",
        "name = \"integrate:output\" direction = input",
    );
    let error = DevelopmentConfig::parse(&no_graph_output)
        .expect_err("processing graph without an output port");
    assert_eq!(error.field(), "graphs[0].ports");

    let parameter_output = replace_once(
        REVOLT_NATIVE,
        "name = \"integrate:output\" direction = output",
        "name = \"integrate:output\" direction = output parameter = true",
    );
    let error =
        DevelopmentConfig::parse(&parameter_output).expect_err("processing graph parameter output");
    assert_eq!(error.field(), "graphs[0].ports.integrate:output.parameter");

    let rated_parameter = replace_once(
        REVOLT_NATIVE,
        "name = \"reconstruct:reconstructor\" direction = input parameter = true",
        "name = \"reconstruct:reconstructor\" direction = input parameter = true rate = 1000/1",
    );
    let error = DevelopmentConfig::parse(&rated_parameter)
        .expect_err("sparse parameter with repeated-data rate");
    assert_eq!(
        error.field(),
        "graphs[0].ports.reconstruct:reconstructor.rate"
    );

    let parameter_sink = replace_once(
        REVOLT_NATIVE,
        "name = input_1 direction = input element-type",
        "name = input_1 direction = input parameter = true element-type",
    );
    let error = DevelopmentConfig::parse(&parameter_sink).expect_err("parameter sink port");
    assert_eq!(error.field(), "sinks[0].ports.input_1.parameter");
}

#[test]
fn revolt_copper_preserves_raw_detector_and_demanded_command_contracts() {
    let copper = DevelopmentConfig::parse(COPPER_NATIVE).expect("Copper full-frame topology");
    let julia = DevelopmentConfig::parse(COPPER_JULIA).expect("Julia Copper full-frame topology");
    for config in [&copper, &julia] {
        assert_eq!(config.object_count(), 4);
        assert_eq!(config.links.len(), 3);
        assert_eq!(config.parameters.len(), 1);
        assert_eq!(config.sources[1].node_name, "rtc-copper-reconstructor");
        assert!(config.sources[1].ports[0].parameter);
        assert!(config.graphs[0].ports[1].parameter);
    }
    assert_eq!(copper.owned_object_count(), 2);
    assert_eq!(julia.owned_object_count(), 1);
    assert_eq!(copper.sources[0].ports[0].element_type, "U16_LE");
    assert_eq!(copper.sources[0].ports[0].shape, [64, 64]);
    assert_eq!(copper.graphs[0].ports[0].element_type, "U16_LE");
    assert_eq!(copper.graphs[0].ports[0].shape, [64, 64]);
    assert_eq!(
        copper.graphs[0].ports[0].schema,
        "org.calculon.ao.raw-detector-pixels/1"
    );
    assert_eq!(copper.sinks[0].ports[0].element_type, "F32_LE");
    assert_eq!(copper.sinks[0].ports[0].shape, [277]);
    assert_eq!(
        copper.sinks[0].ports[0].schema,
        "org.calculon.ao.demanded-pdm-command/1"
    );
    assert_eq!(
        copper.session_controlled_graph_names(),
        ["calculon-revolt-copper-fullframe"]
    );

    let wrong_type = replace_once(
        COPPER_NATIVE,
        "name = \"calibrate:raw\" direction = input element-type = U16_LE",
        "name = \"calibrate:raw\" direction = input element-type = F32_LE",
    );
    assert_eq!(
        DevelopmentConfig::parse(&wrong_type)
            .expect_err("detector element type mismatch")
            .field(),
        "links[1].element-type"
    );

    let wrong_units_schema = replace_once(
        COPPER_NATIVE,
        "name = input_1 direction = input element-type = F32_LE shape = [ 277 ] schema = org.calculon.ao.demanded-pdm-command/1",
        "name = input_1 direction = input element-type = F32_LE shape = [ 277 ] schema = org.revolt.hsdm277.actuator-surface-opd-m.f32/1",
    );
    assert_eq!(
        DevelopmentConfig::parse(&wrong_units_schema)
            .expect_err("micrometre command cannot link to metre sink")
            .field(),
        "links[2].schema"
    );
}

#[test]
fn runtime_parameter_routes_reject_missing_or_misidentified_scientific_inputs() {
    for (before, after, field) in [
        (
            "pipewireao-rtc-revolt-controller:reconstruct:reconstructor\" =",
            "missing-graph:reconstruct:reconstructor\" =",
            "parameters.missing-graph:reconstruct:reconstructor",
        ),
        (
            "pipewireao-rtc-revolt-controller:reconstruct:reconstructor\" =",
            "pipewireao-rtc-revolt-controller:measure:image\" =",
            "parameters.pipewireao-rtc-revolt-controller:measure:image",
        ),
        (
            "${PIPEWIREAO_RTC_PARAMETER_REVOLT}",
            "${UNSCOPED_PARAMETER_REVOLT}",
            "parameters.pipewireao-rtc-revolt-controller:reconstruct:reconstructor",
        ),
        (
            "name = output_1 direction = output parameter = true element-type",
            "name = output_1 direction = output parameter = false element-type",
            "sources[1].ports.output_1.parameter",
        ),
        (
            "name = \"reconstruct:reconstructor\" direction = input parameter = true",
            "name = \"reconstruct:reconstructor\" direction = input parameter = false",
            "parameters.pipewireao-rtc-revolt-controller:reconstruct:reconstructor",
        ),
    ] {
        let mutation = replace_once(REVOLT_NATIVE, before, after);
        let error = DevelopmentConfig::parse(&mutation).expect_err("invalid parameter route");
        assert_eq!(error.field(), field, "configuration mutation: {after}");
    }
}

#[test]
fn runtime_parameter_routes_accept_optional_initial_values() {
    for document in [REVOLT_NATIVE, REVOLT_JULIA, COPPER_NATIVE, COPPER_JULIA] {
        let mut config = DevelopmentConfig::parse(document).unwrap();
        config.parameters.clear();
        config
            .validate()
            .expect("preloaded owner with live-update-only parameter source");
        assert!(config.parameters.is_empty());
    }
    let mut config = DevelopmentConfig::parse(REVOLT_NATIVE).unwrap();
    let mut source = config.sources[1].clone();
    source.node_name = "second-runtime-parameter".to_owned();
    let mut input = config.graphs[0].ports[1].clone();
    input.name = "reconstruct:second-reconstructor".to_owned();
    config.graphs[0].ports.push(input.clone());
    config.links.push(pipewireao_rtc::LinkSpec {
        output: format!("{}:{}", source.node_name, source.ports[0].name),
        input: format!("{}:{}", config.graphs[0].node_name, input.name),
        passive: true,
    });
    config.sources.push(source);
    config
        .validate()
        .expect("one initial value among two declared runtime routes");
    config.parameters.clear();
    config
        .validate()
        .expect("both declared routes support later replacement without initial files");
}

#[test]
fn runtime_parameter_links_are_validated_even_without_initial_values() {
    let mut baseline = DevelopmentConfig::parse(REVOLT_NATIVE).unwrap();
    baseline.parameters.clear();
    baseline
        .validate()
        .expect("valid live-update-only parameter route");
    let parameter_link = baseline
        .links
        .iter()
        .position(|link| {
            link.output
                == format!(
                    "{}:{}",
                    baseline.sources[1].node_name, baseline.sources[1].ports[0].name
                )
        })
        .unwrap();
    let cases = [
        "unlinked",
        "duplicate",
        "fanout",
        "two-publishers",
        "wrong-graph",
        "wrong-port",
        "data-input",
        "non-passive",
        "wrong-type",
        "wrong-shape",
        "wrong-schema",
    ];
    for case in cases {
        let mut config = baseline.clone();
        match case {
            "unlinked" => {
                config.links.remove(parameter_link);
            }
            "duplicate" => config.links.push(config.links[parameter_link].clone()),
            "fanout" => {
                let mut input = config.graphs[0].ports[1].clone();
                input.name = "reconstruct:other".to_owned();
                config.links.push(pipewireao_rtc::LinkSpec {
                    input: format!("{}:{}", config.graphs[0].node_name, input.name),
                    ..config.links[parameter_link].clone()
                });
                config.graphs[0].ports.push(input);
            }
            "two-publishers" => {
                let mut source = config.sources[1].clone();
                source.node_name = "second-runtime-parameter".to_owned();
                config.links.push(pipewireao_rtc::LinkSpec {
                    output: format!("{}:{}", source.node_name, source.ports[0].name),
                    ..config.links[parameter_link].clone()
                });
                config.sources.push(source);
            }
            "wrong-graph" => {
                config.links[parameter_link].input = "missing:reconstruct:reconstructor".to_owned();
            }
            "wrong-port" => {
                config.links[parameter_link].input =
                    "pipewireao-rtc-revolt-controller:missing".to_owned();
            }
            "data-input" => {
                config.links[parameter_link].input =
                    "pipewireao-rtc-revolt-controller:measure:image".to_owned();
            }
            "non-passive" => config.links[parameter_link].passive = false,
            "wrong-type" => config.sources[1].ports[0].element_type = "F64_LE".to_owned(),
            "wrong-shape" => config.sources[1].ports[0].shape[0] -= 1,
            "wrong-schema" => config.sources[1].ports[0].schema = "org.calculon.wrong/1".to_owned(),
            _ => unreachable!(),
        }
        config
            .validate()
            .expect_err(&format!("invalid live-update-only route: {case}"));
    }
}

#[test]
fn runtime_parameter_passive_route_supports_an_ungrouped_application_graph() {
    let mut config = DevelopmentConfig::parse(REVOLT_JULIA).unwrap();
    config.parameters.clear();
    config.graphs[0].realization = ObjectRealization::External {
        run_control: RunControl::Application,
    };
    config.execution_groups.clear();
    config.links[1].passive = false;
    config
        .validate()
        .expect("passive parameter route does not acquire graph run-control authority");
}

#[test]
fn typed_configuration_cannot_grant_session_control_to_external_endpoints() {
    let mut config = DevelopmentConfig::parse(AOS_HIL).expect("AOS HIL configuration");
    config.sources[0].realization = ObjectRealization::External {
        run_control: RunControl::Session,
    };
    let error = config
        .validate()
        .expect_err("external source remains application-controlled");
    assert_eq!(error.field(), "sources[0].run-control");

    let mut config = DevelopmentConfig::parse(AOS_HIL).expect("AOS HIL configuration");
    config.sinks[0].realization = ObjectRealization::External {
        run_control: RunControl::Session,
    };
    let error = config
        .validate()
        .expect_err("external sink remains application-controlled");
    assert_eq!(error.field(), "sinks[0].run-control");
}

#[test]
fn execution_group_membership_and_boundary_links_are_validated() {
    let cases = [
        (
            replace_once(
                FORK,
                "nodes = [ pipewireao-rtc-fork-graph-a pipewireao-rtc-fork-sink-a ]",
                "nodes = [ missing-node pipewireao-rtc-fork-sink-a ]",
            ),
            "execution-groups[0].nodes[0]",
        ),
        (
            replace_once(FORK, "name = branch-b", "name = branch-a"),
            "execution-groups[1].name",
        ),
        (
            replace_once(
                FORK,
                "nodes = [ pipewireao-rtc-fork-graph-a pipewireao-rtc-fork-sink-a ]",
                "nodes = []",
            ),
            "execution-groups[0].nodes",
        ),
        (
            replace_once(
                FORK,
                "nodes = [ pipewireao-rtc-fork-graph-b pipewireao-rtc-fork-sink-b ]",
                "nodes = [ pipewireao-rtc-fork-graph-a pipewireao-rtc-fork-graph-b pipewireao-rtc-fork-sink-b ]",
            ),
            "execution-groups[1].nodes[0]",
        ),
        (
            replace_once(
                FORK,
                "nodes = [ pipewireao-rtc-fork-graph-a pipewireao-rtc-fork-sink-a ]",
                "nodes = [ pipewireao-rtc-fork-sink-a ]",
            ),
            "execution-groups[0].nodes",
        ),
        (
            replace_once(
                FORK,
                "nodes = [ pipewireao-rtc-fork-graph-a pipewireao-rtc-fork-sink-a ]",
                "nodes = [ pipewireao-rtc-fork-graph-a ]",
            ),
            "sink pipewireao-rtc-fork-sink-a.execution-group",
        ),
        (
            SERIAL.replace(
                "execution-groups = [\n        {\n            name = chain\n            nodes = [\n                pipewireao-rtc-serial-source\n                pipewireao-rtc-serial-graph-a\n                pipewireao-rtc-serial-graph-b\n                pipewireao-rtc-serial-sink\n            ]\n        }\n    ]",
                "execution-groups = [\n        { name = upstream nodes = [ pipewireao-rtc-serial-source pipewireao-rtc-serial-graph-a ] }\n        { name = downstream nodes = [ pipewireao-rtc-serial-graph-b pipewireao-rtc-serial-sink ] }\n    ]",
            ),
            "links[1].execution-group",
        ),
        (
            replace_once(
                FORK,
                "pipewireao-rtc-fork-graph-a:input\" passive = true",
                "pipewireao-rtc-fork-graph-a:input\" passive = false",
            ),
            "links[0].passive",
        ),
        (
            replace_once(MINIMAL, "passive = false", "passive = true"),
            "links[0].passive",
        ),
    ];

    for (document, field) in cases {
        let error = DevelopmentConfig::parse(&document).expect_err("invalid execution group");
        assert_eq!(error.field(), field, "configuration mutation:\n{document}");
    }
}

#[test]
fn graph_bodies_are_delegated_as_opaque_pipewire_module_files() {
    let config = DevelopmentConfig::parse(MINIMAL).unwrap();
    let graph = &config.graphs[0];
    assert_eq!(
        graph.configuration_path.as_deref(),
        Some("${PIPEWIREAO_RTC_GRAPH_MINIMAL}")
    );
    assert!(graph.plugin_path.is_none());
    assert!(graph.arguments.is_empty());

    for (field, insertion) in [
        (
            "graphs[0].filter.graph",
            "filter.graph = { nodes = [] }\n            ",
        ),
        (
            "graphs[0].algorithm.label",
            "algorithm.label = leaky-integrator-f32\n            ",
        ),
        (
            "graphs[0].plugin.path",
            "plugin.path = \"${PIPEWIREAO_RTC_FGN_BUNDLE}\"\n            ",
        ),
    ] {
        let mutated = replace_once(
            MINIMAL,
            "ports = [\n                { name = input",
            &format!("{insertion}ports = [\n                {{ name = input"),
        );
        let error = DevelopmentConfig::parse(&mutated).expect_err("runner-private graph field");
        assert_eq!(error.field(), field);
    }
}

#[test]
fn serial_forked_and_independent_links_are_exactly_declared() {
    let serial = DevelopmentConfig::parse(SERIAL).unwrap();
    assert_eq!(serial.sources.len(), 1);
    assert_eq!(serial.graphs.len(), 2);
    assert_eq!(serial.sinks.len(), 1);

    let fork = DevelopmentConfig::parse(FORK).unwrap();
    assert_eq!(fork.sources.len(), 1);
    assert_eq!(fork.graphs.len(), 2);
    assert_eq!(fork.sinks.len(), 2);
    assert_eq!(fork.links[0].output, fork.links[1].output);
    assert_ne!(fork.links[0].input, fork.links[1].input);

    let independent = DevelopmentConfig::parse(INDEPENDENT).unwrap();
    assert_eq!(independent.sources.len(), 2);
    assert_eq!(independent.graphs.len(), 2);
    assert_eq!(independent.sinks.len(), 2);
}

#[test]
fn endpoint_and_scope_admission_is_an_explicit_negative_matrix() {
    let cases = [
        ("profile = development", "profile = operational", "profile"),
        (
            "execution = complete-frame",
            "execution = progressive",
            "execution",
        ),
        ("authority = none", "authority = correction", "authority"),
        (
            "claim = development-characterization",
            "claim = real-time-qualified",
            "claim",
        ),
        (
            "factory = api.fits.source",
            "factory = pipewireao.physical-camera",
            "sources[0].factory",
        ),
        (
            "factory = api.pipewireao.discard",
            "factory = pipewireao.physical-deformable-mirror",
            "sinks[0].factory",
        ),
        (
            "factory = api.pipewireao.discard",
            "factory = pipewireao.unlisted-sink",
            "sinks[0].factory",
        ),
        (
            "factory = pipewireao.fgn-native",
            "factory = pipewireao.calculon-fgn-native",
            "graphs[0].factory",
        ),
    ];
    for (before, after, field) in cases {
        let error = DevelopmentConfig::parse(&replace_once(MINIMAL, before, after))
            .expect_err("unsafe or unlisted configuration");
        assert_eq!(error.field(), field, "case {after}");
    }
}

#[test]
fn object_port_and_file_fields_report_scientific_names() {
    let cases = [
        (
            "node.name = pipewireao-rtc-source",
            "node.name = \"\"",
            "sources[0].node.name",
        ),
        (
            "${PIPEWIREAO_FITS_PLUGIN}",
            "/usr/lib/unreviewed-source.so",
            "sources[0].plugin.path",
        ),
        (
            "${PIPEWIREAO_RTC_GRAPH_MINIMAL}",
            "/tmp/generated-by-the-runner.conf",
            "graphs[0].config.path",
        ),
        (
            "${PIPEWIREAO_DISCARD_PLUGIN}",
            "/usr/lib/actuating.so",
            "sinks[0].plugin.path",
        ),
        (
            "name = output direction = output",
            "name = output direction = input",
            "sources[0].ports.output.direction",
        ),
        (
            "element-type = F32_LE shape = [ 2 ] schema = org.calculon.ao.docrime-excitation/1",
            "element-type = F64_LE shape = [ 2 ] schema = org.calculon.ao.docrime-excitation/1",
            "sources[0].ports.output.element-type",
        ),
        (
            "shape = [ 2 ] schema = org.calculon.ao.docrime-excitation/1",
            "shape = [ 0 ] schema = org.calculon.ao.docrime-excitation/1",
            "sources[0].ports.output.shape",
        ),
    ];
    for (before, after, field) in cases {
        let error = DevelopmentConfig::parse(&replace_once(MINIMAL, before, after))
            .expect_err("invalid scientific field");
        assert_eq!(error.field(), field, "mutation {before:?}");
    }
}

#[test]
fn fits_factory_arguments_are_validated_field_by_field() {
    let cases = [
        (
            "${PIPEWIREAO_RTC_FITS_PATH}",
            "/tmp/unreviewed.fits",
            "sources[0].args.api.fits.path",
        ),
        (
            "api.fits.hdu = 1",
            "api.fits.hdu = 2",
            "sources[0].args.api.fits.hdu",
        ),
        (
            "api.fits.rate = 1000/1",
            "api.fits.rate = 0/1",
            "sources[0].args.api.fits.rate",
        ),
        (
            "api.fits.output-mode = frame",
            "api.fits.output-mode = progressive",
            "sources[0].args.api.fits.output-mode",
        ),
        (
            "api.fits.output-mode = frame",
            "api.fits.output-mode = row-block",
            "sources[0].args.api.fits.sample-rank",
        ),
    ];
    for (before, after, field) in cases {
        let error = DevelopmentConfig::parse(&replace_once(MINIMAL, before, after))
            .expect_err("invalid FITS field");
        assert_eq!(error.field(), field);
    }
}

#[test]
fn session_rate_is_validated_and_must_match_fits_sources() {
    let invalid = replace_once(MINIMAL, "rate = 1000/1", "rate = 0/1");
    let error = DevelopmentConfig::parse(&invalid).expect_err("invalid session rate");
    assert_eq!(error.field(), "rate");

    let mismatched = replace_once(MINIMAL, "api.fits.rate = 1000/1", "api.fits.rate = 500/1");
    let error = DevelopmentConfig::parse(&mismatched).expect_err("mismatched FITS rate");
    assert_eq!(error.field(), "sources[0].args.api.fits.rate");
}

#[test]
fn links_validate_ports_directions_shapes_schemas_and_producers() {
    let cases = [
        (
            "element-type = F32_LE shape = [ 2 ] schema = org.calculon.ao.docrime-excitation/1",
            "element-type = U16_LE shape = [ 2 ] schema = org.calculon.ao.docrime-excitation/1",
            "links[0].element-type",
        ),
        (
            "shape = [ 2 ] schema = org.calculon.ao.docrime-excitation/1",
            "shape = [ 3 ] schema = org.calculon.ao.docrime-excitation/1",
            "links[0].shape",
        ),
        (
            "output = \"pipewireao-rtc-source:output\"",
            "output = \"pipewireao-rtc-source:missing\"",
            "links[0].output",
        ),
        (
            "pipewireao-rtc-graph:input",
            "pipewireao-rtc-graph:output",
            "links[0].input",
        ),
        (
            "schema = org.calculon.ao.controller-command/1",
            "schema = org.pipewireao.rtc.wrong/1",
            "links[1].schema",
        ),
    ];
    for (before, after, field) in cases {
        let error = DevelopmentConfig::parse(&replace_once(MINIMAL, before, after))
            .expect_err("invalid declared link");
        assert_eq!(error.field(), field, "link mutation {before:?}");
    }

    let duplicate = replace_once(
        FORK,
        "pipewireao-rtc-fork-graph-b:input",
        "pipewireao-rtc-fork-graph-a:input",
    );
    let error = DevelopmentConfig::parse(&duplicate).expect_err("duplicate fork link");
    assert_eq!(error.field(), "links[1]");
}

#[test]
fn optional_observation_surfaces_are_declared_source_or_graph_outputs() {
    let config = DevelopmentConfig::parse(MINIMAL).expect("declared graph output");
    assert_eq!(config.observations, ["pipewireao-rtc-source:output"]);

    for endpoint in [
        "graph.output",
        "pipewireao-rtc-graph:input",
        "pipewireao-rtc-graph:missing",
        "pipewireao-rtc-sink:in",
    ] {
        let error = DevelopmentConfig::parse(&replace_once(
            MINIMAL,
            "observations = [ \"pipewireao-rtc-source:output\" ]",
            &format!("observations = [ \"{endpoint}\" ]"),
        ))
        .expect_err("invalid observation surface");
        assert_eq!(error.field(), "observations[0]", "endpoint {endpoint}");
    }

    let duplicate = replace_once(
        MINIMAL,
        "observations = [ \"pipewireao-rtc-source:output\" ]",
        "observations = [ \"pipewireao-rtc-source:output\" \"pipewireao-rtc-source:output\" ]",
    );
    let error = DevelopmentConfig::parse(&duplicate).expect_err("duplicate observation");
    assert_eq!(error.field(), "observations[1]");
}

#[test]
fn pipewire_relaxed_spa_json_comments_and_optional_separators_are_accepted() {
    let with_comments = MINIMAL.replace(
        "profile = development",
        "# PipeWire line comment\n    profile = development,",
    );
    DevelopmentConfig::parse(&with_comments).expect("public relaxed SPA-JSON syntax");
}

#[test]
fn runner_does_not_extend_or_reinterpret_pipewire_spa_json_syntax() {
    let error = DevelopmentConfig::parse(
        "{ profile = development execution = complete-frame authority = none claim = development-characterization rate = 1000/1 sources = [ @include foo ] }",
    )
    .expect_err("runner-specific include syntax must not be accepted");
    assert!(error.message().contains("relaxed SPA-JSON"));
}

fn fits_science_config(height: u32, width: u32, rows: Option<u32>) -> String {
    let schema = if rows.is_some() {
        "org.calculon.ao.raw-pixel-row-block/1"
    } else {
        "org.calculon.ao.raw-pixels/1"
    };
    let shape = format!("[ {} {width} ]", rows.unwrap_or(height));
    let block_rate = format!("{}/1", 1000 * height / rows.unwrap_or(height));
    let mut document = MINIMAL
        .replace("api.fits.sample-rank = 1", "api.fits.sample-rank = 2")
        .replace("org.calculon.ao.docrime-excitation/1", schema)
        .replace(
            &format!("element-type = F32_LE shape = [ 2 ] schema = {schema}"),
            &format!("element-type = U16_LE shape = {shape} schema = {schema} rate = {block_rate}"),
        )
        .replace(
            "shape = [ 2 ] schema = org.calculon.ao.controller-command/1",
            "shape = [ 277 ] schema = org.calculon.ao.controller-command/1",
        );
    if let Some(rows) = rows {
        document = document
            .replace("execution = complete-frame", "execution = row-block")
            .replace(
                "api.fits.output-mode = frame",
                &format!("api.fits.output-mode = row-block\n                api.fits.row-block-rows = {rows}\n                api.fits.simulated-readout-time-ns = 800000\n                api.fits.profile = recorded-science"),
            );
    }
    document
}

#[test]
fn recorded_fits_science_frames_and_row_blocks_are_admitted() {
    for (height, width, rows) in [
        (352, 352, None),
        (64, 64, None),
        (352, 352, Some(11)),
        (64, 64, Some(32)),
    ] {
        let config = DevelopmentConfig::parse(&fits_science_config(height, width, rows))
            .expect("maintained recorded FITS transport");
        assert_eq!(config.sources[0].ports[0].element_type, "U16_LE");
        assert_eq!(
            config.sources[0].ports[0].shape,
            [rows.unwrap_or(height), width]
        );
        assert_eq!(config.sinks[0].ports[0].shape, [277]);
        assert_eq!(
            format!("{:?}", config.execution),
            if rows.is_some() {
                "RowBlock"
            } else {
                "CompleteFrame"
            }
        );
    }
}

#[test]
fn recorded_fits_rank_one_and_f32_images_accept_authored_shapes() {
    let rank_one = MINIMAL.replace(
        "shape = [ 2 ] schema = org.calculon.ao.docrime-excitation/1",
        "shape = [ 17 ] schema = org.calculon.ao.docrime-excitation/1",
    );
    DevelopmentConfig::parse(&rank_one).expect("rank-one recorded F32 sample");
    let image = fits_science_config(64, 64, None).replace("U16_LE", "F32_LE");
    DevelopmentConfig::parse(&image).expect("rank-two recorded F32 sample");
}

#[test]
fn recorded_fits_row_arguments_reject_invalid_rank_rows_readout_and_metadata() {
    let row = fits_science_config(352, 352, Some(11));
    let cases = [
        (
            "api.fits.sample-rank = 2",
            "api.fits.sample-rank = 1",
            "api.fits.sample-rank",
        ),
        (
            "api.fits.sample-rank = 2",
            "api.fits.sample-rank = 3",
            "api.fits.sample-rank",
        ),
        (
            "api.fits.row-block-rows = 11",
            "api.fits.row-block-rows = 0",
            "api.fits.row-block-rows",
        ),
        (
            "api.fits.row-block-rows = 11",
            "api.fits.row-block-rows = -1",
            "api.fits.row-block-rows",
        ),
        (
            "api.fits.row-block-rows = 11",
            "api.fits.row-block-rows = 1.5",
            "api.fits.row-block-rows",
        ),
        (
            "api.fits.row-block-rows = 11",
            "api.fits.row-block-rows = 12",
            "api.fits.row-block-rows",
        ),
        (
            "api.fits.row-block-rows = 11",
            "",
            "api.fits.row-block-rows",
        ),
    ];
    for (before, after, field) in cases {
        let error = DevelopmentConfig::parse(&replace_once(&row, before, after))
            .expect_err("invalid row arguments");
        assert!(error.field().contains(field), "{error}");
    }
}

#[test]
fn recorded_fits_row_arguments_reject_invalid_readout_and_metadata() {
    let row = fits_science_config(352, 352, Some(11));
    let cases = [
        (
            "api.fits.simulated-readout-time-ns = 800000",
            "api.fits.simulated-readout-time-ns = 0",
            "api.fits.simulated-readout-time-ns",
        ),
        (
            "api.fits.simulated-readout-time-ns = 800000",
            "api.fits.simulated-readout-time-ns = 1000000",
            "api.fits.simulated-readout-time-ns",
        ),
        (
            "api.fits.simulated-readout-time-ns = 800000",
            "api.fits.simulated-readout-time-ns = 18446744073709551615",
            "api.fits.simulated-readout-time-ns",
        ),
        (
            "api.fits.simulated-readout-time-ns = 800000",
            "api.fits.simulated-readout-time-ns = 18446744073709551616",
            "api.fits.simulated-readout-time-ns",
        ),
        (
            "api.fits.simulated-readout-time-ns = 800000",
            "api.fits.simulated-readout-time-ns = 12.5",
            "api.fits.simulated-readout-time-ns",
        ),
        (
            "api.fits.simulated-readout-time-ns = 800000",
            "",
            "api.fits.simulated-readout-time-ns",
        ),
        (
            "api.fits.profile = recorded-science",
            "",
            "api.fits.profile",
        ),
        (
            "api.fits.profile = recorded-science",
            "api.fits.profile = \"\"",
            "api.fits.profile",
        ),
        (
            "org.calculon.ao.raw-pixel-row-block/1",
            "org.calculon.ao.wrong/1",
            "api.fits.schema",
        ),
    ];
    for (before, after, field) in cases {
        let error = DevelopmentConfig::parse(&replace_once(&row, before, after))
            .expect_err("invalid row argument");
        assert_eq!(
            error.field(),
            format!("sources[0].args.{field}"),
            "mutation {after:?}"
        );
    }
    for (before, after, field) in [
        ("shape = [ 11 352 ]", "shape = [ 11 352 1 ]", "shape"),
        (
            "element-type = U16_LE",
            "element-type = F64_LE",
            "element-type",
        ),
    ] {
        let error = DevelopmentConfig::parse(&replace_once(&row, before, after))
            .expect_err("invalid row port");
        assert_eq!(error.field(), format!("sources[0].ports.output.{field}"));
    }
}

#[test]
fn recorded_fits_file_mmap_prefault_and_loop_placement_stay_explicit() {
    let image = fits_science_config(64, 64, None);
    let prefault = image
        .replace("api.fits.io-mode = file", "api.fits.io-mode = mmap")
        .replace("api.fits.prefault = false", "api.fits.prefault = true")
        .replace(
            "api.fits.hdu = 1",
            "api.fits.hdu = 1 node.loop.name = science-loop",
        )
        .replace(
            "node.name = pipewireao-rtc-sink",
            "node.name = pipewireao-rtc-sink args = { node.loop.name = science-loop }",
        );
    let config = DevelopmentConfig::parse(&prefault)
        .expect("recorded mmap with explicit prefault and loop placement");
    assert_eq!(
        config.sources[0].arguments["node.loop.name"],
        "science-loop"
    );
    assert_eq!(config.sinks[0].arguments["node.loop.name"], "science-loop");
    for (before, after, field) in [
        (
            "api.fits.prefault = false",
            "api.fits.prefault = true",
            "sources[0].args.api.fits.prefault",
        ),
        (
            "api.fits.prefault = false",
            "api.fits.prefault = yes",
            "sources[0].args.api.fits.prefault",
        ),
        (
            "api.fits.prefault = false",
            "",
            "sources[0].args.api.fits.prefault",
        ),
        (
            "api.fits.io-mode = file",
            "api.fits.io-mode = preload",
            "sources[0].args.api.fits.io-mode",
        ),
        (
            "api.fits.readiness = timerfd",
            "api.fits.readiness = poll",
            "sources[0].args.api.fits.readiness",
        ),
        (
            "api.fits.hdu = 1",
            "api.fits.hdu = 1 node.driver = true",
            "sources[0].args.node.driver",
        ),
        (
            "api.fits.hdu = 1",
            "api.fits.hdu = 1 node.loop.name = \"\"",
            "sources[0].args.node.loop.name",
        ),
        (
            "api.fits.hdu = 1",
            "api.fits.hdu = 1 node.loop.name = [ science-loop ]",
            "sources[0].args.node.loop.name",
        ),
        (
            "api.fits.output-mode = frame",
            "api.fits.output-mode = frame api.fits.row-block-rows = 1",
            "sources[0].args.api.fits.row-block-rows",
        ),
        (
            "api.fits.output-mode = frame",
            "api.fits.output-mode = frame api.fits.simulated-readout-time-ns = 1",
            "sources[0].args.api.fits.simulated-readout-time-ns",
        ),
        (
            "node.name = pipewireao-rtc-sink",
            "node.name = pipewireao-rtc-sink args = { node.driver = true }",
            "sinks[0].args.node.driver",
        ),
    ] {
        let error = DevelopmentConfig::parse(&replace_once(&image, before, after))
            .expect_err("unsupported endpoint argument");
        assert_eq!(error.field(), field, "mutation {after:?}");
    }
}
