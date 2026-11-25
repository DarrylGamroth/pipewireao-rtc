# Installed management rollout — 2026-11-04 UTC

RTC `8bfd4ed96f25b3ffa26d6203f0672effd840f3c2` and GUI
`de8b776bfc40590f6bcff70f6f220ac78506dc32` were fast-forwarded into local main.
The standalone release companion and complete declared RTC runtime export were
installed under `~/.local/lib/pipewireao/management/8bfd4ed`. Existing SDK libraries
are referenced through a separate prefix overlay; the running application's
installed files were not modified. No remote push or registry publication occurred.

`ManagementCLI.install` generated the per-user service/socket units. Unit
verification, socket enablement/activation, installed-project loading and a
correlated receipt query passed. Socket mode is 0600 in a 0700 directory. The
service uses the existing `~/.local/state/pipewireao/configuration` and
`~/.local/state/pipewireao/simulator-settings` roots. The web GUI was rebuilt and
its service alone restarted; its launcher now selects the owner socket.

Before/after SHA-256 checks preserved all 127 configuration-store files, all 297
simulator-job files and all 20 files in the old empty GUI store. SQL comparisons
also preserved 19 artifact identities, 7 materializations and all 1,884 raw
journal events: 942 requested, 937 completed and 5 Unknown. Four existing job
results remain (three complete, one failed). No migration, recovery, replay or
storage cleanup was performed. The absent old GUI simulator root remains absent.

The deployed browser loaded the same 19 artifact IDs and described startup
settings for session `97840a2a-6233-49f4-b90c-7d77ff0f1c8a`. Catalog and Describe
were read-only. All native controls stayed on their existing interface; zero
native mutations were observed. The session remained Running. Its session/core/
Julia/parameters/simulator PIDs (1786367/1786195/1786228/1786229/1786230), start
ticks, executable hashes and systemd invocation IDs matched the initial baseline.

Fourteen browser phase records verified Header-backed freshness, panel closure,
reopening and reconnect. The bridge spawned zero children. Management retained
one cached Julia worker and, during startup description, the existing temporary
reader for the pinned application. The reader exited on completion; approximately
60 seconds after the last request, cache expiry left only the native companion
at 1.58 MiB PSS while observation continued. The sampled management-family peak,
including that reader, was 1,221.1 MiB. This migration changes ownership and idle
retention; it does not remove the transient Julia cost.

The [GUI rollout record](../../../../pipewireao-gui/docs/RTC_MANAGEMENT_ROLLOUT.md)
retains build/check commands, source/storage digests, memory and freshness
results, environment limits and the measurement-harness correction. Runtime
installation/deployment receipts retain package/unit/binary/asset hashes. Raw
outputs are temporary. The [source evidence](../management-endpoint-20261103/README.md)
remains distinct from these installed application observations. No scientific
replacement, physical-device, frame-cadence or tail-latency qualification is
claimed; browser cross-connection receipt recovery remains deferred.
