fn main() {
    println!("cargo:rerun-if-changed=src/ffi/spa_json.c");
    println!("cargo:rerun-if-changed=src/ffi/module.c");

    let spa = pkg_config::Config::new()
        .atleast_version("0.2")
        .probe("libspa-0.2")
        .expect("configuration parsing requires the public SPA headers");
    let mut spa_json = cc::Build::new();
    spa_json
        .file("src/ffi/spa_json.c")
        .warnings(true)
        .extra_warnings(true);
    for include in &spa.include_paths {
        spa_json.include(include);
    }
    spa_json.compile("pipewireao_rtc_spa_json_shim");

    if std::env::var_os("CARGO_FEATURE_LIVE").is_none() {
        return;
    }

    let library = pkg_config::Config::new()
        .atleast_version("1.7.0")
        .probe("libpipewire-ao-0.3")
        .expect("the live adapter requires a PipeWireAO build tree");
    for link_path in &library.link_paths {
        println!("cargo:rustc-link-arg=-Wl,-rpath,{}", link_path.display());
    }
    let mut build = cc::Build::new();
    build
        .file("src/ffi/module.c")
        .warnings(true)
        .extra_warnings(true);
    for include in library.include_paths {
        build.include(include);
    }
    build.compile("pipewireao_rtc_module_shim");
}
