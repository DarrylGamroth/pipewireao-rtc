# Native GUI client boundary — 2026-10-08

RTC baseline: `2e49b6e4deb621051f6ac27f1d98e59f0e11f314`, initially clean.
Branch: `codex/native-client-split-20261008`.

The GUI migrated its used native Rust client closure from that revision into
its native adapter and removed the headless RTC Cargo dependency. The complete
[GUI source/test receipt and independent review](https://github.com/DarrylGamroth/pipewireao-gui/blob/d193254fb5044b84ede83b65a8849da6f115ae7f/docs/validation/native-client-20261008/README.md)
record 447 GUI tests, 57 retained native client tests, Clippy, WASM and 117 Julia
script assertions. The former GUI pin and relocated client preserve production
behavior; public v1 POD records and ownership are unchanged.

The relocation exposed an inherited test defect in this repository:
`src/tests/connection.rs` invoked its child with the deleted inline module's
name. The child ran zero tests and exited successfully. The selector now derives
from its actual `module_path!()`; the same correction is present in the GUI.
This is a test-only change. Production socket code is unchanged.

## Focused donor validation

```sh
env PKG_CONFIG_PATH=/opt/pipewireao/lib/x86_64-linux-gnu/pkgconfig \
    LD_LIBRARY_PATH=/opt/pipewireao/lib/x86_64-linux-gnu \
    CARGO_BUILD_JOBS=1 CARGO_INCREMENTAL=0 \
    CARGO_PROFILE_DEV_DEBUG=0 CARGO_PROFILE_TEST_DEBUG=0 \
    taskset -c 14 cargo test --offline --locked --features live --lib \
    connection::tests::explicit_socket_ignores_environment_in_owned_child \
    --target-dir /tmp/native-client-rtc-target -- --nocapture
```

Exit 0; one parent and its actual child pass. The child reports
`EXPLICIT_SOCKET requested_accepted=true environment_accepted=false`.
The retained log and exact corrected source hash are in [the receipt](receipt.json).
Formatting and diff whitespace pass. Rust/Cargo 1.97.1; CPU 0/1 excluded.
The temporary owned build tree is removed after delivery.

These checks do not rerun installed session controls, scientific graphs,
observer effects, real-time or hardware qualification. Existing SDKs/services
and the GUI checkout's pre-existing user edit remain untouched. Shared Julia
package relocation and independent instrument projects remain in
[the current roadmap](../../roadmap.md#current-work).
