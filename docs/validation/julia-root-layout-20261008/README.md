# Julia root layout — 2026-10-08

Baseline `4bc5c5d`; branch `codex/julia-package-root-20261008`.
This first extraction increment moves the named Julia package to the repository
root and retires its Rust crate after the calibration and GUI client migrations.
The independent REVOLT project is being prepared separately; instrument modules
and resources remain in the shared package in this increment.

## Software checks

- Root package loading and precompilation pass with Julia 1.12.7.
- Full Julia tooling suite: **2,985 assertions in 105 testsets pass**.
- Package tests retain installed export, relocation/re-export, source containment,
  unsupported identity/version rejection and sealed-source preservation checks.
- All **97 native test-data files**, **20 development configuration files** and
  **four PipeWire templates** remain byte-identical; hashes are in the receipt.
- Three cold HIL native bridges load from package resources, preserving their
  separate top-level SDK layout. Loading failed before the path repair and passes
  after it. Six loading assertions now cover this case in the package suite.
- `git diff --check` passes. No services were started or old sealed SDKs modified.

The final test log retains expected caught Git-provenance diagnostics for copied
non-Git inputs and the duplicate-key YAML rejection diagnostic. These did not
fail the suite. Logs are under `~/.cache/rtc-julia-package-20261008`.

This establishes package/software behavior, not live bootstrap, scientific
acceptance, steady-state allocation, timing or hardware qualification. Instrument
separation and affected installed-profile checks remain required.

See [independent review](REVIEW.md) and [receipt](receipt.json).
