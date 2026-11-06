# RTC streamlining — 2026-11-06

Started at clean `463e39c`, branch `codex/julia-session-policy-20261104`, dedicated
worktree `pipewireao-rtc-cleanup`. The user approved the remaining cleanup review.
Optional workstation feature retirement remains a separate scope choice; current
features and active scientific/instrument contracts are preserved.

## Legacy export-input retirement and current guidance

Removed `legacy_export_input` from deployment validation together with the
marker-only owner shapes, marker-name validation, conflict sets and request-file
staging checks used only by that mode. Every new application must declare its
current native owner protocols. Exact protocol identities and required native
bootstrap/source checks remain. Earlier conversion evidence and old sealed
applications retain their original scope and tools.

The root version guard and deployment guide now require Julia 1.13, matching
Project compatibility. Current README ownership/installation text describes
Julia MediaSession, public PipeWireAO interfaces and registered application
dependencies; the resource docstring describes package-relative lookup.

Verified with Julia 1.13.3 and the explicitly selected PipeWireAO artifact prefix:
556 assertions in 37 testsets pass in
`/tmp/rtc-streamline-admission-20261106.log` (exit 0). Selectors cover auxiliary
sources, registered applications, instrument export/profiles, session
configuration and package entrypoints. The auxiliary-source suite includes
rejection of each old marker field and a complete old marker-only declaration.
JuliaFormatter 2.14.8 preserves syntax/literals and is idempotent for all three
changed Julia files (`/tmp/rtc-streamline-format-20261106.log`). No core, owner or
service was launched. No deployment or instrument source was rewritten.

## Scientific transfers in progress

Measured-influence resampling and detector layout are being transferred to AOS
through its public scientific interfaces. RTC retains input admission and
provenance. Measured influence preparation must explicitly select AOS rather than
leave a numerical fallback in RTC; ordinary RTC loading remains independent of
optional science packages. Receiving source, compatibility and numerical evidence
will be recorded with each verified transfer. No receiving API or release is
claimed complete by the initial retirement changeset.
