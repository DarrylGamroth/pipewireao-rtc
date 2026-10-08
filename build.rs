fn main() {
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
}
