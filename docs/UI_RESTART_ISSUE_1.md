# Recorded FITS restart investigation — issue #1

Status: discard-counter cache mechanism confirmed; focused correction reviewed
and Classic/Copper functional regressions pass.

Date: 2026-10-03. [Issue #1](https://github.com/DarrylGamroth/pipewireao-rtc/issues/1).
This record is software integration evidence under RTC-DEV-004,
RTC-DEV-011, RTC-DEV-022 and RTC-DEV-023. The active
[architecture](architecture.md), [operations](operations.md) and
[roadmap](roadmap.md) retain authority. The
[independent review](UI_RESTART_REVIEW.md) records investigative adjudication.

## Sources and isolated artifacts

The RTC worktree started clean at
`2f62fd582be3a6e0b5fc2dcb7af4a7b77426d698`, branch
`work/rtc-ui-restart-issue-1-20261003`, path
`/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-ui-restart`.
The clean GUI baseline is
`43a17be` in the companion worktree
`/home/dgamroth/workspaces/codex/pipewire/pipewireao-gui-rtc-restart`.
No existing operator deployment or unrelated worktree was modified.

Fresh release build used `--locked --features live`, one build job,
`PKG_CONFIG_PATH=/opt/pipewireao/lib/x86_64-linux-gnu/pkgconfig`, CPU 6 and
nice level 10. The owner exporter and installer created new temporary Classic
and Copper FGN complete-frame packages under
`/tmp/rtc-ui-restart-issue-1-20261003/installed-{classic,copper}`.
They reuse the historical recorded FITS and scientific calibration artifacts.
Compared with the refreshed `gui-test-*-2e0d26d` manifests, only the RTC binary
and provenance changed; scientific arrays, graph/session files and native bundle
have identical hashes. Existing installed packages remain immutable.

| Artifact | SHA-256 |
| --- | --- |
| Fresh RTC binary, revision `2f62fd5` | `3b3234f1a68f1f3218317f146d5afc3ed253cf6611c4c2d9f0878e412952597e` |
| Historical RTC binary, revision `50dc370` | `1a32b6f6b86e81fb942c87de7f8f870a42ccbef4ed27ad208fce9a9db985f78c` |
| Scientific bundle, owner revision `518a578` | `462af3d4d9b66a902b8c2cd19acf795114206acb0850f94356fe1a7f0077268c` |
| Installed PipeWireAO core library | `083da9b7c347a40e8ce03cc1332c06774cbf766fdd71fe36010233e6d9096387` |
| Installed ndarray filter-chain module | `ebcc06b2537c97d1d0199f0cf64b4dae3c9d5126247b428d31eb776bd279f76e` |
| Installed FITS plugin | `3f3fb042201afb2cf646fd76a468103d8f57609e0630eef065b332fe03e14e2a` |
| Installed discard plugin | `5ffcb1339e65e3eee48597b62bb42843b22ab8b293f65736aaa57074d50338b0` |

`baseline.json` and `native-artifacts.json` under the issue cache retain full
paths, revisions and identities. The core and filter module have symbol tables
but no debug information. The core Build ID is
`4c4765657fbfa8726d729722af47057d05a150dd`; a local debug build has a different
Build ID and supplies neither layouts nor symbols for the installed process.

Every launch uses a generated transient user unit, a private core and a fresh
owned runtime. Effective source/processing/sink/housekeeping CPU declarations
remain 12/2/8/14, excluding CPUs 0 and 1. Temporary fixtures change only
`api.fits.loop=true` and their copied session checksum except where an explicit
investigative topology discriminator is recorded. Debuggers attach only to the
new test-owned process identified by its deployment record. Calibration live
windows are serialized with these tests.

## Fail-before observations

| Check | Observation and local evidence |
| --- | --- |
| Fresh Classic GUI lifecycle | Failed `start controller`: discard buffers 2, process calls 2, session Fault. `/tmp/pipewireao-gui-rtc-evidence-pnytgt28/{result.json,client-failure.log}` |
| Fresh Copper GUI lifecycle | Same failure at buffers/process calls 2. `/tmp/pipewireao-gui-rtc-evidence-vv_7_jul/{result.json,client-failure.log}` |
| Fresh Classic and Copper maintained owner property checks | Both passed group stop/start, session stop, stopped reset, stopped scalar submission, adoption after restart and owned shutdown. `classic-owner.json` and `copper-owner.json` in the issue cache |
| Fresh Classic CLI only | Status/groups/stop/status/start, with public topology dumps before stop and restart; restart failed at 2. `owner-probe-classic-d188594fa96c` in the issue cache |
| Steady state before any stop | Independent public sink Props reads one second apart both report buffers/process calls 3 while source, graph and sink public states are Running. `owner-probe-classic-c705e13b2eb0/{before-stop-dump.json,before-stop-later-dump.json}` |
| Source publication during failed restart | FITS `process_source` repeatedly returns HAVE_DATA (2); the core accepts `node_ready(2)` with result 0. Subsequent source processing returns and reuses all four producer buffers. More than 40 source sequences advance. `owner-probe-classic-fd2892b3a01f/source-debugger.log` |
| Native module callback | The RTC-owned module callback executes 50 times during a failed restart. `owner-probe-classic-d46099f46db9/rtc-debugger.log` |
| Native public buffer dequeue | Ordinary input and output dequeues return rotating buffers during the failed restart; parameter dequeue returns NULL, which the module excludes from ordinary readiness. `owner-probe-classic-3a41814e7483/rtc-debugger.log` |
| Parameter-route discriminator | Removing the unused runtime parameter source/link and the corresponding session port declaration, while retaining scientific owner preload, still fails CLI restart at 2. `owner-probe-classic-301265058bf9` |

The property harness publishes an equal-value reconstructor while stopped and
performs several scalar operations before its lifecycle checks. That difference
is a discriminator, not an established remedy. The current failure does not
depend on the historical RTC binary or GUI mutations. The unchanged public
counter is visible before group stop, but it does not yet establish stopped
sink processing: the daemon can cache the Props snapshots used by these reads.

Source inspection identified a narrower hypothesis. The native core enables
node parameter caching by default; a broad Node Props query can populate that
cache, and subsequent narrow queries can reuse it. `pwao-dump` performs the broad
query used by the GUI topology check and every investigative probe. The passing
owner property check does not call it. RTC's owned latest/hold nodes already set
`node.cache-params=false` for live counters, while owned discard sinks do not.
A trace of the installed discard process callback and Props enumeration will
distinguish stale snapshots from lost sink processing before any correction.

The source publication trace contradicts a permanently held source HAVE_DATA
loan and source-pool exhaustion for the traced run. Repeated native callbacks
contradict missing core-to-runner callback activation. Actual graph-processing
return values, output chunk sizes, queue outcomes and subsequent transport to
the sink remain to be discriminated. No production root cause or workaround is
promoted from these observations.

The exact owner CLI probe and debugger command files remain in the issue cache.
Public SPA/PipeWire buffer offsets used in further tracing are derived from the
installed headers and checked with `abi_layout.c`; no daemon-private layouts
from another build are used. Debugger runs are functional investigations and
provide no timing evidence.

## Confirmed mechanism and correction

The installed discard trace in `owner-probe-classic-6dcf57a02456` records
50 process entries and 50 NEED_DATA (1) returns during the same failed
restart, but zero calls to the sink's underlying `enum_params`. The public
process counter remains 2. Each process entry increments that atomic counter,
so the returned public value is stale. The installed symbols and mapped
addresses are recorded in `core-maps.txt` and `source.gdb`; no private layout
was imported. The corresponding no-topology, no-write owner CLI sequence in
`owner-probe-classic-a44bc4e7680b` passes and advances the sink from 2 to 3.
This retires a current-build failure of the pure CLI sequence without a broad
Props observer; the historical issue's installed binary remains unchanged.

The confirmed boundary is RTC creation of its owned discard node. The core's
normal parameter cache is suitable for values with invalidation notifications;
the discard plugin exposes atomic live counters without notifying every frame.
A broad topology query caches the snapshot, and later bound-one progress
queries reuse it. `src/live.rs:create_owned_spa_sink` now sets the public
`node.cache-params=false` property, following the existing latest/hold pattern.
The strict later-buffer gate, run-control protocol, transport, graph, scientific
parameters and timeouts are unchanged. No native sibling edit is needed.

The rebuilt release binary is
`7b37da2f558ae37f3139aa6db58ead7f8950dee38508003decb53e747b85b47f`.
`fixed-provenance.json` records starting HEAD, the uncommitted source patch
SHA-256 and both fixed exports. Their artifact maps differ from the fail-before
packages only in `bin/pipewireao-rtc`; scientific arrays, sessions, graph and
bundle are identical. The owner exporter and installer create separate
`installed-fixed-classic` and `installed-fixed-copper` packages.

The unchanged broad-topology Classic probe now passes in
`owner-probe-classic-2cac39b3b58b`: public complete-buffer/process counters
advance 3 → 13 before stop, remain 13 while Stopped, reach 14 after restart
and 23 at the later snapshot; protocol errors remain zero. Its owned service
is terminal and its runtime removed. This contradicts the earlier
transport-stall inference and demonstrates pass-after for the cached-counter
failure. The independent review in `UI_RESTART_REVIEW.md` confirms this
mechanism and retracts the earlier inference.

## Test harness cleanup correction

The Copper failure exposed a separate GUI harness defect: its faulted deployment
exited and systemd `--collect` unloaded the unit before `systemctl stop`, which
returned exit 5. The unit was inactive and its runtime absent, but the harness
reported cleanup incomplete. The companion GUI change checks the terminal state
before stop and after a rejected stop. A rejection while still active remains
an error. Thirteen Python harness tests pass, including collection during stop
and a rejected stop with a still-running unit. Lifecycle assertions remain
unchanged and the restart fault remains visible.

The same three cleanup tests run against the original GUI `HEAD` harness
produce one assertion failure and one error; the active-unit rejection test
already passes. `gui-cleanup-fail-before.log` retains this comparison.
The corrected companion worktree also passes formatting, 183 library and
71 binary Rust tests (10 opt-in tests ignored), all-target Clippy with
`-D warnings`, the WASM build and normal dependency inspection, and 117 Julia
script assertions. Checks use the README's absolute native build paths,
locked Rust dependencies and CPU 6. Existing SPA unused-parameter warnings
remain. These checks validate the harness correction, not the restart fault.
Cargo metadata resolved the companion GUI target inside its own worktree;
`cargo clean --target-dir` removed that local build cache after validation.
The RTC release target remains available for the next isolated trace.

## Acceptance results

| Fresh scenario | Passing evidence |
| --- | --- |
| Classic maintained owner property/lifecycle regression | `classic-owner-fixed.json` in the issue cache |
| Copper maintained owner property/lifecycle regression | `copper-owner-fixed.json` in the issue cache |
| Classic GUI update/reconnect | `/tmp/pipewireao-gui-rtc-evidence-ql042g8f` |
| Classic GUI immediate lifecycle | `/tmp/pipewireao-gui-rtc-evidence-lw45_olq` |
| Copper GUI update/reconnect | `/tmp/pipewireao-gui-rtc-evidence-6o6fxzh4` |
| Copper GUI immediate lifecycle | `/tmp/pipewireao-gui-rtc-evidence-jlh6ivyj` |

The existing GUI lifecycle and update/reconnect tests are unchanged. The
lifecycle logs show later complete buffers after group restart (Classic
4 → 5, Copper 3 → 4), session stop/start, stopped reset, stopped scalar
submission and adoption after restart. Every GUI scenario retains all eight
observed node/link global IDs and serials and leaves the installed test package
unchanged. All six generated GUI/owner services are independently checked
inactive and their runtimes absent. `fixed-validation-summary.json` records
these assertions; the parent also independently inspected the four GUI results.

RTC formatting, all 133 ordinary workspace tests with the live feature
(three opt-in tests ignored) and all-target Clippy with `-D warnings` pass.
The release build passes. Logs retain existing native SPA unused-parameter
warnings and the `proc-macro-error2` future-compatibility notice. CPU 6 and one
Cargo job are used for builds and software checks. The broad-topology probe and
maintained regressions above provide explicit live software evidence separately
from ordinary tests.

After the final GUI live rebuild, Cargo metadata again resolves its own local
target (2.3 GiB on disk). `cargo clean --target-dir` removes 3,437 files
(2.6 GiB logical size); the target is absent and available volume space returns
to 29 GiB. The RTC target is retained for the parent's immediate integration.
Preserved fail-before/pass-after binary copies bind the evidence independently
of subsequent build outputs. The parent and independent reviewer inspected the source correction and
acceptance evidence before delivery.

No scientific equivalence, observer non-gating, rendered GUI interaction, HIL,
hardware safety, wall cadence or real-time qualification is claimed.

## SHA-256 evidence ledger

Paths without a leading slash are relative to
`/tmp/rtc-ui-restart-issue-1-20261003`. The preserved binaries and source snapshot
are independent copies; later rebuilds cannot change this evidence identity.
`evidence-sha256.json` retains the same mapping locally.

| Artifact | SHA-256 |
| --- | --- |
| `baseline.json` | `7e0aea6b5b7f83949fee63fcc1927c82e22d6e0ccc67c81992b4f9fdc7602889` |
| `native-artifacts.json` | `25beae42045834faa8b9b55203221938faca2adee6d6d60a817e71949f0dc93e` |
| `fixed-provenance.json` | `ea81f91b1bcbbf163108f9cac463fcff330a39335f65cd56c63250c39ee24775` |
| `sink-cache-fix.patch` | `9052b6294d1617c2f013815a8458e6d01b00f922cc59e03360e0a75118507392` |
| `preserved/fail-before-pipewireao-rtc` | `3b3234f1a68f1f3218317f146d5afc3ed253cf6611c4c2d9f0878e412952597e` |
| `preserved/pass-after-pipewireao-rtc` | `7b37da2f558ae37f3139aa6db58ead7f8950dee38508003decb53e747b85b47f` |
| `preserved/pass-after-live.rs` | `a62824c9ef983ee9bfab31bd98ee357d5797ed990223916d40c263a5ba6af893` |
| `fixed-validation-summary.json` | `d1d75d8027c2629878723c5fa7b183e6a431f75d8b8ce6c7156f00895020dbc7` |
| `discard-process-disassembly.txt` | `6792e8596d44881ec230fd1a3d7a93accbff39a9a768ec60dc0c078c66728d92` |
| `owner-probe-classic-6dcf57a02456/core-debugger.log` | `4e0103b2a2d3aeaed94d07bfc146a442dc01b7990ec1c35f1d0c5527923f064d` |
| `owner-probe-classic-6dcf57a02456/source.gdb` | `0e3d7ce3061542509771872c2b465c209b99a7ea07a24e8a3ecb071fbcb97d6b` |
| `owner-probe-classic-6dcf57a02456/core-maps.txt` | `2c425f69070e547eb8f8ecd112f9f3452f7f581b54993d3ff7c74ffd534b9c2d` |
| `owner-probe-classic-6dcf57a02456/result.json` | `ed3d379691b9eda6d98083b3eec4afa63bcdcbe6bd8d3cca4b84295c6d382fce` |
| `owner-probe-classic-a44bc4e7680b/result.json` | `0debbedde6710e5563aeb07fe2f3051591db3bc02c87c0da18400dc302e84784` |
| `owner-probe-classic-2cac39b3b58b/result.json` | `0435ad1d8cac112b6cf2e50e2ca3c6a1dddb750f696033950b5b5f20a9e86930` |
| `classic-owner-fixed.json` | `a7c2759ad7a1348aa807c86e1d2802ca0fdfd9c4b38677a9fbf118933e6be80a` |
| `copper-owner-fixed.json` | `5320eee22e45a480b3f770c60075e7786209f6c695fd03053682cac8d7ffa38c` |
| `gui-cleanup-fail-before.log` | `efd01a9461d302270c673d19164cf8c6777dccff6ad504d5ce5a938d410dfd3b` |
| `rtc-cargo-test.log` | `488dbf7ca9573cb2d0ba3e5f34a17e665045dc1c34123360972696f63b699988` |
| `rtc-clippy.log` | `643b984e2442c3256e4772cae2cd67aaabfde6e010e55f45cf28265c3353a042` |
| `gui-cargo-test.log` | `f498868c64f75836f15afe533cdfdd84e574c5df7c35d39c9b5ebcf1da4cf95f` |
| `gui-clippy.log` | `cfc0bc2a42d83faebe8b64058aa4383a1e421dede5e80f1c7b10be7e38c275a9` |
| `gui-julia-tests.log` | `d17492609be16042a87a7a43bf2dfeb25c47f0663de87724d79a2250feaa81e1` |
| `gui-wasm-check.log` | `be3e1f5b54482caf063e2fb13efd3bf5a0f093699192ef9a60d6f7effe1928ba` |
| `gui-wasm-dependencies.log` | `a24a47c4bb9b3ba0166e660a0f706226e029f45112c5adb1872aae05e97e60da` |
| `owner-probe-classic-0f356cf9a770/source-debugger.log` | `2d37ac7eae710f8b45c7168af4b25722be07e434c26d2cc3365202582812f554` |
| `owner-probe-classic-3a41814e7483/rtc-debugger.log` | `fb3bf608f0d8e4a6f511aa347c23dd6ee1c7c859ae923c98e22cd05383f8a51a` |
| `owner-probe-classic-4714db0366d5/source-debugger.log` | `d38a984048cb78474579e8b8dd2c180d550a214f53ba1e4c676f70d92432a9ce` |
| `owner-probe-classic-a74941eaa2ea/source-debugger.log` | `33dcada954037c2395e84b42fb97965a24391d94e15600e90a397b6baafdfe4f` |
| `owner-probe-classic-d46099f46db9/rtc-debugger.log` | `7b82a1c39f1249682d71444fd3bd4bc60f002b3cf2c4050d29fe574ff76b1f9e` |
| `owner-probe-classic-fd2892b3a01f/source-debugger.log` | `6c0b882156c91b505ad7e4489f7761922093161ad5687d936dd5404815b7938d` |
| `/tmp/pipewireao-gui-rtc-evidence-pnytgt28/result.json` | `2b9e4fad5ffdbde906742e97a47ead0b317f7a51c94ed62bca53c9de60c94e1d` |
| `/tmp/pipewireao-gui-rtc-evidence-pnytgt28/client-failure.log` | `d6701b73c1af0bbf05e3cb7c42ae99fdd038af7cbd6d306e76beeb1e30166ddc` |
| `/tmp/pipewireao-gui-rtc-evidence-vv_7_jul/result.json` | `c20179b85fba346d7c29ce1acea3e992bb363705b5807cc28fc6adbb4767316b` |
| `/tmp/pipewireao-gui-rtc-evidence-vv_7_jul/client-failure.log` | `893c4ca020639827f94ad5e6a52ef169169ffd91f317d0024c400feab7b0f5c2` |
| `/tmp/pipewireao-gui-rtc-evidence-ql042g8f/result.json` | `45d6dc73732e5c8baa8d4a98b31f4fc2d75d5669c80d752a80ad61073412310f` |
| `/tmp/pipewireao-gui-rtc-evidence-ql042g8f/client.log` | `f9e3ab46db900fa7f4d4877a08e363683c05198679a72128dd31e12c8240c292` |
| `/tmp/pipewireao-gui-rtc-evidence-lw45_olq/result.json` | `e4369669a7030ddd281ea0c931ed907f4e19f51dca408377359a2ab96466889a` |
| `/tmp/pipewireao-gui-rtc-evidence-lw45_olq/client.log` | `af653d399db65440cca6b4983c66db20946566749471f3f1b5082a128bc0d55a` |
| `/tmp/pipewireao-gui-rtc-evidence-6o6fxzh4/result.json` | `57f128afb83803093bc1b9f51f72dc47bfedf89d978844f583ee51baa85c3b15` |
| `/tmp/pipewireao-gui-rtc-evidence-6o6fxzh4/client.log` | `66ff3b76adee213348775159c078cff723c027c599c45c6b4a6a5f48eb87c690` |
| `/tmp/pipewireao-gui-rtc-evidence-jlh6ivyj/result.json` | `e654ffe2764c8b74e84cc7138656d72e52ecb700d5a15167f519fbbe1659ee10` |
| `/tmp/pipewireao-gui-rtc-evidence-jlh6ivyj/client.log` | `de0ea5af783ec61824eb4559d9ef8748994fbca08c43ff5734eaba1089eddf2e` |
