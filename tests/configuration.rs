use pipewireao_rtc::DevelopmentConfig;

const VALID: &str = include_str!("../fixtures/minimal-development.conf");

fn replace_once(before: &str, after: &str) -> String {
    assert!(
        VALID.contains(before),
        "fixture does not contain {before:?}"
    );
    VALID.replacen(before, after, 1)
}

#[test]
fn valid_minimal_development_configuration_is_resolved() {
    let config = DevelopmentConfig::parse(VALID).expect("valid development fixture");
    assert_eq!(config.object_count(), 3);
    assert_eq!(config.links.len(), 2);
    assert!(config.observations.is_empty());
    assert!(config.parameters.is_empty());
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
            "claim = development-characterization",
            "claim = deadline-qualified",
            "claim",
        ),
        (
            "claim = development-characterization",
            "claim = safety-qualified",
            "claim",
        ),
        (
            "api.fits.source",
            "pipewireao.physical-camera",
            "source.factory",
        ),
        (
            "api.fits.source",
            "pipewireao.unlisted-source",
            "source.factory",
        ),
        (
            "api.pipewireao.discard",
            "pipewireao.physical-deformable-mirror",
            "sink.factory",
        ),
        (
            "api.pipewireao.discard",
            "pipewireao.actuating-sink",
            "sink.factory",
        ),
        (
            "api.pipewireao.discard",
            "pipewireao.unlisted-sink",
            "sink.factory",
        ),
    ];

    for (before, after, field) in cases {
        let error = DevelopmentConfig::parse(&replace_once(before, after))
            .expect_err("unsafe or unlisted case must be rejected");
        assert_eq!(error.field(), field, "case {after}");
    }
}

#[test]
fn invalid_fields_report_scientific_names() {
    let cases = [
        (
            "node.name = pipewireao-rtc-source",
            "node.name = \"\"",
            "source.node.name",
        ),
        (
            "node.name = pipewireao-rtc-source",
            "node.name = \"pipewireao-rtc-source\\u0000hidden\"",
            "source.node.name",
        ),
        (
            "${PIPEWIREAO_FITS_PLUGIN}",
            "/usr/lib/unreviewed-source.so",
            "source.plugin.path",
        ),
        (
            "module = libpipewire-module-spa-node-factory",
            "module = private-module",
            "source.module",
        ),
        (
            "module = libpipewire-module-spa-node-factory\n        node.name = pipewireao-rtc-sink",
            "module = private-module\n        node.name = pipewireao-rtc-sink",
            "sink.module",
        ),
        (
            "${PIPEWIREAO_DISCARD_PLUGIN}",
            "/usr/lib/unreviewed-discard.so",
            "sink.plugin.path",
        ),
        ("name = output", "name = image", "source.ports.image.name"),
        (
            "direction = output",
            "direction = input",
            "source.ports.output.direction",
        ),
        (
            "element-type = F32_LE",
            "element-type = U16_LE",
            "source.ports.output.element-type",
        ),
        (
            "shape = [ 2 ]",
            "shape = [ 3 ]",
            "source.ports.output.shape",
        ),
        (
            "schema = org.calculon.ao.docrime-excitation/1",
            "schema = wrong.image/1",
            "source.args.api.fits.schema",
        ),
        (
            "element-type = F32_LE\n                shape = [ 2 ]\n                schema = org.calculon.ao.docrime-excitation/1",
            "element-type = F32_LE\n                shape = [ 2 ]\n                schema = wrong.image/1",
            "source.ports.output.schema",
        ),
        (
            "api.fits.rate = 1000/1",
            "api.fits.rate = 0/1",
            "source.args.api.fits.rate",
        ),
        ("graph.gain = 0.5", "graph.unknown = 0.5", "properties"),
        ("graph.pole = 0.75", "graph.pole = nan", "graph.pole"),
        (
            "parameters = {}",
            "parameters = { graph.matrix = matrix.npy }",
            "parameters",
        ),
        (
            "observations = []",
            "observations = [ graph.output ]",
            "observations",
        ),
        (
            "pipewireao-rtc-graph:input",
            "pipewireao-rtc-sink:in",
            "links",
        ),
    ];

    for (before, after, field) in cases {
        let error = DevelopmentConfig::parse(&replace_once(before, after))
            .expect_err("mutated field must fail validation");
        assert_eq!(error.field(), field, "mutation {before:?} -> {after:?}");
    }
}

#[test]
fn fits_factory_arguments_report_each_invalid_field() {
    let cases = [
        (
            "${PIPEWIREAO_RTC_FITS_PATH}",
            "/tmp/unreviewed.fits",
            "source.args.api.fits.path",
        ),
        (
            "api.fits.hdu = 1",
            "api.fits.hdu = 2",
            "source.args.api.fits.hdu",
        ),
        (
            "api.fits.sample-rank = 1",
            "api.fits.sample-rank = 2",
            "source.args.api.fits.sample-rank",
        ),
        (
            "api.fits.io-mode = file",
            "api.fits.io-mode = stream",
            "source.args.api.fits.io-mode",
        ),
        (
            "api.fits.prefault = false",
            "api.fits.prefault = true",
            "source.args.api.fits.prefault",
        ),
        (
            "api.fits.loop = true",
            "api.fits.loop = false",
            "source.args.api.fits.loop",
        ),
        (
            "api.fits.readiness = timerfd",
            "api.fits.readiness = poll",
            "source.args.api.fits.readiness",
        ),
        (
            "api.fits.output-mode = frame",
            "api.fits.output-mode = row-block",
            "source.args.api.fits.output-mode",
        ),
    ];

    for (before, after, field) in cases {
        let error = DevelopmentConfig::parse(&replace_once(before, after))
            .expect_err("invalid FITS argument must be rejected");
        assert_eq!(error.field(), field, "argument {before}");
    }

    let unknown = replace_once(
        "api.fits.hdu = 1",
        "api.fits.hdu = 1\n            api.fits.unknown = value",
    );
    let error = DevelopmentConfig::parse(&unknown).expect_err("unknown FITS argument");
    assert_eq!(error.field(), "source.args.api.fits.unknown");
}

#[test]
fn graph_construction_values_report_each_invalid_field() {
    let cases = [
        ("extent = 2", "extent = 3", "graph.algorithm.config.extent"),
        (
            "initial_state = 0.0",
            "initial_state = 1.0",
            "graph.algorithm.config.initial_state",
        ),
        (
            "input_schema = org.calculon.ao.docrime-excitation/1",
            "input_schema = wrong.input/1",
            "graph.algorithm.config.input_schema",
        ),
        (
            "output_schema = org.calculon.ao.controller-command/1",
            "output_schema = wrong.output/1",
            "graph.algorithm.config.output_schema",
        ),
        (
            "rate = [ 1000 1 ]",
            "rate = [ 100 1 ]",
            "graph.algorithm.config.rate",
        ),
    ];

    for (before, after, field) in cases {
        let error = DevelopmentConfig::parse(&replace_once(before, after))
            .expect_err("invalid graph construction value must be rejected");
        assert_eq!(error.field(), field, "construction value {before}");
    }

    let unknown = replace_once("extent = 2", "extent = 2\n            invented = 1");
    let error = DevelopmentConfig::parse(&unknown).expect_err("unknown construction value");
    assert_eq!(error.field(), "graph.algorithm.config.invented");

    let missing = replace_once("            extent = 2\n", "");
    let error = DevelopmentConfig::parse(&missing).expect_err("missing construction value");
    assert_eq!(error.field(), "graph.algorithm.config.extent");
}

#[test]
fn simulated_and_recorded_sources_are_both_explicitly_admitted() {
    let source_start = VALID.find("    source = {").unwrap();
    let source_end = VALID.find("\n\n    graph = {").unwrap();
    let simulated_source = r#"    source = {
        factory = pipewireao.simulated-complete-frame
        module = libpipewire-module-ndarray-filter-chain
        node.name = pipewireao-rtc-source
        plugin.path = "${CALCULON_FGN_BUNDLE}"
        algorithm.label = docrime-excitation-f32
        algorithm.config = {
            amplitudes = [ 1.0 2.0 ]
            seed = 0
        }
        ports = [
            {
                name = excitation
                direction = output
                element-type = F32_LE
                shape = [ 2 ]
                schema = org.calculon.ao.docrime-excitation/1
            }
        ]
    }"#;
    let mut simulated = format!(
        "{}{}{}",
        &VALID[..source_start],
        simulated_source,
        &VALID[source_end..]
    );
    simulated = simulated.replacen(
        "pipewireao-rtc-source:output",
        "pipewireao-rtc-source:excitation",
        1,
    );
    DevelopmentConfig::parse(&simulated).expect("simulated source allowlist entry");
    DevelopmentConfig::parse(VALID).expect("recorded FITS source allowlist entry");
}

#[test]
fn discard_sink_rejects_a_fake_algorithm_layer() {
    let mutated = VALID.replacen(
        "        plugin.path = \"${PIPEWIREAO_DISCARD_PLUGIN}\"",
        "        plugin.path = \"${PIPEWIREAO_DISCARD_PLUGIN}\"\n        algorithm.label = scale-f32\n        algorithm.config = {}",
        1,
    );
    let error = DevelopmentConfig::parse(&mutated).expect_err("discard sink has no algorithm");
    assert_eq!(error.field(), "sink.algorithm.label");
}

#[test]
fn pipewire_relaxed_spa_json_comments_and_optional_separators_are_accepted() {
    let with_hash_comment = VALID.replacen(
        "profile = development",
        "# Standard SPA line comment\n    profile: development,",
        1,
    );
    DevelopmentConfig::parse(&with_hash_comment).expect("relaxed SPA-JSON syntax");

    let opening = VALID.find('{').expect("fixture root object");
    let closing = VALID.rfind('}').expect("fixture root object");
    let without_root_braces = format!("{}{}", &VALID[..opening], &VALID[opening + 1..closing]);
    DevelopmentConfig::parse(&without_root_braces).expect("relaxed root object");

    let with_unicode_name = VALID
        .replacen(
            "node.name = pipewireao-rtc-source",
            "node.name = \"pipewireao-rtc-sourc\\u00e9\"",
            1,
        )
        .replacen(
            "pipewireao-rtc-source:output",
            "pipewireao-rtc-sourcé:output",
            1,
        );
    DevelopmentConfig::parse(&with_unicode_name).expect("quoted UTF-8 is accepted");
}

#[test]
fn runner_does_not_extend_or_reinterpret_pipewire_spa_json_syntax() {
    let block_comment = VALID.replacen(
        "profile = development",
        "/* not a SPA comment */ profile = development",
        1,
    );
    let error = DevelopmentConfig::parse(&block_comment)
        .expect_err("C block comments are not SPA-JSON comments");
    assert_eq!(error.field(), "configuration./*");

    let duplicate = VALID.replacen(
        "profile = development",
        "profile = development\n    profile = development",
        1,
    );
    let error = DevelopmentConfig::parse(&duplicate).expect_err("duplicate field");
    assert_eq!(error.field(), "profile");
    assert!(error.message().contains("duplicated"));

    let trailing = format!("{VALID}\nunexpected");
    let error = DevelopmentConfig::parse(&trailing).expect_err("trailing token");
    assert_eq!(error.field(), "configuration");
    assert!(error.message().contains("invalid relaxed SPA-JSON"));

    let invalid_array = replace_once("shape = [ 2 ]", "shape = [ 2 = 3 ]");
    let error = DevelopmentConfig::parse(&invalid_array).expect_err("invalid array separator");
    assert_eq!(error.field(), "configuration");
    assert!(error.message().contains("Invalid array separator"));
}
