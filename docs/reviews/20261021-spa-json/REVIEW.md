# Standard SPA-JSON generation review — 2026-10-21

Disposition: independent source and focused parser verification pass. No blocking
serializer or component-loader-removal finding remains. The production probe
inspection below establishes generated-configuration startup through native
Configuring on clean stock libwireplumber; it does not establish scientific
readiness or completed lifecycle behavior.

## Scope and identities

RTC worktree: `/home/dgamroth/workspaces/codex/worktrees/rtc-spa-json-20261021`,
branch `codex/spa-json`, baseline `c868e9189268e70cd307fdd8d2e316b99425bdb5`.
WirePlumber worktree: `wireplumber-spa-json-20261021`, baseline `9575d852`.
Both were clean when this review began. Implementation and integration changes
belong to the coordinator and implementation worker; this reviewer owns only
this review document and temporary investigative probes.

Authorities inspected: both repository instruction files; RTC task index,
configuration boundary and current roadmap; upstream PipeWire
[configuration format](https://docs.pipewire.org/page_man_pipewire_conf_5.html);
`spa/utils/json-core.h`, `json.h`, `json-builder.h` and `spa/tools/spa-json-dump.c`.
Local parser sources were clean at PipeWire revision
`e641c398a32ad7c77613592fbb43805430ef42ec`.

Scope: `ScienceExport.write_spa_config`, its maintained tests and the four
component-dependency parsing reversions. No GPU, active instrument, physical
actuation, timing or scientific fidelity qualification was performed.

## Findings and adjudication

### SPA-001 — Standard JSON remains valid; dependency interpretation differs

- **Classification / severity / confidence:** observed upstream behavior,
  P2 compatibility constraint, high.
- **Evidence:** the format documentation accepts standard JSON and relaxed
  `key = value` declarations with whitespace-separated arrays. Upstream
  `component_data_new_from_json` stores dependency values with
  `wp_spa_json_to_string`; quoted feature tokens therefore include quotation
  marks while parsed provider names do not. This affects requires, wants,
  before and after arrays. The former generated JSON was syntactically valid.
- **Remediation:** generate conventional SPA-JSON with bare safe feature names,
  including `support.lua-scripting`, `ao.lua` and the production session feature
  names. Retain quoting for strings whose meaning would change without it.
- **Validation / disposition:** source review confirms all current production
  dependency names fit the conservative bare subset. The restored
  `lib/wp/private/internal-comp-loader.c` has no difference from upstream tag
  `0.5.18`. Closed for the generated configuration contract; this does not claim
  the stock loader can resolve arbitrary quoted feature names.

### SPA-002 — Native formatter alone retains quoted values

- **Classification / severity / confidence:** observed tool limitation,
  P2 design constraint, high.
- **Evidence:** both the installed PipeWireAO tool and the current Julia artifact
  tool retain `"support.lua-scripting"` when invoked with `-N -s` on standard
  JSON. The upstream builder's quoted-string branch forwards that raw token;
  simplified keys do not imply simplified string values. Artifact identity:
  `3c63168ffd94740be1e2ea34c1eaf12a9468622a`.
- **Remediation:** a small typed writer owns emission; JSON3 owns scalar JSON
  escaping and numeric representation. The upstream CLI remains the final
  parser/normalization oracle. No replacement parser or post-generation regex
  transformation is introduced.
- **Validation / disposition:** direct tool experiment and source agree.
  Closed; the initially considered formatter-only approach was not accepted.

### SPA-003 — String identity and file preservation require validation

- **Classification / severity / confidence:** derived implementation constraint,
  P1 if violated, high; no unresolved implementation defect.
- **Evidence:** upstream token boundaries include whitespace, quote, comment
  marker, braces/brackets, colon, comma and equals; bare backslash and non-ASCII
  bytes are rejected. Native numeric recognition also accepts non-JSON numeric
  spellings. Removing quotation marks indiscriminately changes string types or
  structure. Native object-key decoding also has a bounded key buffer.
- **Remediation:** bare strings use the conservative letter/underscore-led
  ASCII subset, excluding boolean/null and case-insensitive NaN/Inf/Infinity.
  JSON3 quotes and escapes other strings. Invalid UTF-8 and NUL fail explicitly.
  The entire document is buffered and normalized by the existing upstream CLI;
  `isequal` compares values before the destination is touched. Unsupported
  nested values and nonfinite/out-of-range numbers fail before writing.
- **Validation / disposition:** independent native-parser tests cover all
  non-NUL ASCII control characters, delimiters, comments, escapes, Unicode,
  empty strings, deterministic randomized inputs, Int64/UInt64 extrema,
  integers above 2⁵³, signed zero, large/small finite numbers and nonnumbers.
  Maintained tests additionally cover nested arrays/objects, hostile keys,
  overlong keys and unchanged destination contents. Closed.

## Independent verification

An investigative C shared library in `/tmp/rtc-spa-independent.c` directly uses
upstream `spa_json_begin_object_relax`, `spa_json_object_next` and
`spa_json_parse_stringn`. It returns the raw scalar token and decoded bytes;
there is no independently invented SPA parser. The Julia harness
`/tmp/rtc-spa-independent.jl` compares decoded bytes and exact integer tokens
against original input and exercises rejection without replacing a sentinel
file. Its deterministic string corpus includes 128 randomized examples.

Commands and results on Julia 1.13.2:

```sh
julia --project=. --startup-file=no /tmp/rtc-spa-independent.jl
# 925 assertions passed
julia --project=. --startup-file=no test/test_spa_config.jl
# 80 assertions passed (50 roundtrip/format, 30 rejection/preservation)
git diff --check
# passed
```

An exploratory `Float32(0.1)` case failed the existing exact JSON semantic guard:
its decimal token parsed as Float64 is unequal to the original Float32 value.
This behavior already existed at the baseline and is outside this formatting
change. The final probe verifies exact representable Float32/Float16 values and
unchanged-file rejection for their inexact `0.1` cases; it does not claim support
for all finite Julia numeric representations.

The component-loader removal leaves the separately reviewed dynamic POD-filter
allocation fix and Lua event-properties lookup fix unchanged. Retained
WirePlumberAO policy files are outside this upstream-library source claim;
restoring this file is not a claim that the entire policy fork is upstream.

## Production configuration evidence inspected

The unchanged maintained `generated-configuration-probe.jl` invokes the actual
`SessionConfiguration.write_session_config` and launches the installed RTC
against the clean stock prefix
`/home/dgamroth/.local/opt/pipewireao-wp-upstream-stock-20261021`. This reviewer
inspected the coordinator's new configuration, receipt and log (now preserved
in [the validation receipt](../../validation/spa-json-20261021/README.md) and
its `generated-stock` directory), the probe's assertions, and the historical
[generated-stock evidence](../../validation/upstream-bindings-20261021/generated-stock/receipt.json).

The historical JSON configuration exits 78: no component provides the dependency
whose stored name includes quotes around `support.lua-scripting`. The new actual
production configuration emits bare dependency tokens; the unchanged probe
receives a native Status reply with lifecycle `configuring`, asserts that the
RTC remains running, and subsequently records orderly child exit 0. Both runs
identify the same clean stock library and installed RTC prefixes.

This observed result closes the generated-configuration dependency on the
component-loader patch. It supersedes only that limitation in prior ULB-005
and generated-stock evidence. Owners are absent in this probe, so it does not
establish admission, Running, scientific execution or lifecycle completion.
The new log retains `Session control publication failed` during teardown; the
passing Configuring assertion does not erase or qualify that warning.
