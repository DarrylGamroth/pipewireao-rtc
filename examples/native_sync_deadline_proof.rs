//! Finite diagnostic for `PipeWire` callback synchronization deadlines.
//! This process creates no graph nodes, ports, or scientific objects.

#[cfg(feature = "live")]
mod proof {
    use pipewireao_rtc::LiveGraphAdapter;
    use std::error::Error;
    use std::path::{Path, PathBuf};
    use std::time::{Duration, Instant};

    fn wait_marker(directory: &Path, name: &str) -> Result<(), Box<dyn Error>> {
        let marker = directory.join(name);
        let deadline = Instant::now() + Duration::from_secs(30);
        while !marker.is_file() {
            if Instant::now() >= deadline {
                return Err(format!("finite synchronization proof wait expired: {name}").into());
            }
            std::thread::sleep(Duration::from_millis(2));
        }
        Ok(())
    }

    fn result(
        directory: &Path,
        stage: &str,
        started: Instant,
        value: impl std::fmt::Debug,
    ) -> Result<(), Box<dyn Error>> {
        std::fs::write(
            directory.join(format!("result-{stage}")),
            format!(
                "elapsed_ns={} result={value:?}\n",
                started.elapsed().as_nanos()
            ),
        )?;
        wait_marker(directory, &format!("release-{stage}"))
    }

    pub fn run() -> Result<(), Box<dyn Error>> {
        let mut args = std::env::args().skip(1);
        let remote = args.next().ok_or("missing absolute private remote")?;
        let directory = PathBuf::from(args.next().ok_or("missing fixture directory")?);
        let mode = args.next().ok_or("missing proof mode")?;
        if args.next().is_some() || !Path::new(&remote).is_absolute() {
            return Err("expected absolute remote, fixture directory, and proof mode".into());
        }
        let adapter = LiveGraphAdapter::connect(&remote)?;
        std::fs::write(directory.join("ready"), "")?;

        match mode.as_str() {
            "stopped" => {
                // This deadline is already expired and must be rejected before
                // submitting a core sync, even though the private daemon is live.
                let started = Instant::now();
                let expired = adapter.progress_until(Instant::now());
                result(&directory, "expired", started, expired)?;
                wait_marker(&directory, "go-budget")?;
                let started = Instant::now();
                let bounded = adapter.progress_until(Instant::now() + Duration::from_millis(250));
                result(&directory, "budget", started, bounded)?;
                let started = Instant::now();
                let default = adapter.progress();
                result(&directory, "default", started, default)?;
                wait_marker(&directory, "go-stale")?;
                let started = Instant::now();
                let stale = adapter.progress_until(Instant::now() + Duration::from_millis(250));
                result(&directory, "stale", started, stale)?;
                wait_marker(&directory, "go-fresh")?;
                let started = Instant::now();
                let fresh = adapter.progress();
                result(&directory, "fresh", started, fresh)?;
            }
            "termination" => {
                wait_marker(&directory, "go-termination")?;
                std::fs::write(directory.join("sync-entered"), "")?;
                let started = Instant::now();
                let terminated = adapter.progress();
                result(&directory, "termination", started, terminated)?;
            }
            _ => return Err(format!("unknown synchronization proof mode: {mode}").into()),
        }
        drop(adapter);
        Ok(())
    }
}

#[cfg(feature = "live")]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    proof::run()
}

#[cfg(not(feature = "live"))]
fn main() {
    eprintln!("native_sync_deadline_proof requires --features live");
    std::process::exit(2);
}
