fn main() {
    let mut arguments = std::env::args().skip(1);
    match arguments.next().as_deref() {
        Some("session") => {
            if let Err(error) = pipewireao_rtc::session_cli::run(&arguments.collect::<Vec<_>>()) {
                eprintln!("pipewireao-rtc: {error}");
                std::process::exit(1);
            }
        }
        Some("--help" | "-h") | None => {
            println!("pipewireao-rtc session --list");
            println!(
                "pipewireao-rtc session --session UUID [--timeout SECONDS] -- COMMAND [ARG ...]"
            );
        }
        Some(command) => {
            eprintln!("pipewireao-rtc: unknown command {command:?}; use --help");
            std::process::exit(2);
        }
    }
}
