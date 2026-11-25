# Cold owner control envelope, version 1

Selected by RTC-ARCH-024 / RTC-DEV-030. This is the common fixed header for
new cold lifecycle and calibration endpoints; it does not replace the prepared
scientific source codecs. Owner-specific payloads and effect boundaries remain
separate exact schemas. The header alone confers no command authority.

## Wire representation

Use one standard `SPA_PARAM_Props` / `SPA_TYPE_OBJECT_Props` object with exactly
one flags-zero `SPA_PROP_params` property. Its value is a Struct of exactly four
children, in this order:

1. String naming the record header.
2. Struct containing the fixed header below.
3. String naming the record payload.
4. Struct containing the owner's exact payload.

| Record | Header name | Payload name | Bound including outer POD |
| --- | --- | --- | ---: |
| Request | `pipewireao.rtc.control.request.header` | `pipewireao.rtc.control.request.payload` | 16 KiB |
| Completion | `pipewireao.rtc.control.completion.header` | `pipewireao.rtc.control.completion.payload` | 64 KiB lifecycle; 128 KiB calibration |
| Rejection | `pipewireao.rtc.control.rejection.header` | `pipewireao.rtc.control.rejection.payload` | Same endpoint reply bound |

No JSON string, Bytes containing JSON, recursive map codec or runtime schema
registry is defined. The payload Struct is decoded by its owner-specific
operation schema after bounded envelope validation. Exact arity, scalar sizes,
child types, dimensions, counts and finite scientific values are required.
The common payload grammar permits None, Bool, Id, Int, Long, Float, Double,
String, Bytes, arrays of fixed scalar types, and nested Structs. Payload Struct
depth is at most eight, counting the payload root as one. Other Object, Pointer,
Fd, Choice and Sequence payloads are not in this version. Validate the byte bound
and structural depth before any recursive generic native deserializer runs.
The owner additionally enforces its exact operation-specific grammar and counts.

Named properties and fixed header children reject duplicates, extras and
reordering. Native serializers provide alignment; clients do not cast pointers.

### Request header (eight children)

| Position | Meaning | Exact SPA type / range |
| ---: | --- | --- |
| 1 | Version | Int = 1 |
| 2 | Endpoint instance | Long > 0 |
| 3 | Controller registry global ID | Id, neither 0 nor `SPA_ID_INVALID` |
| 4 | Controller object.serial | Long containing UInt64 bit pattern; decoded UInt64 > 0 |
| 5 | Controller instance | Long > 0 |
| 6 | Request token | Long > 0 |
| 7 | Operation | Id > 0; owner-specific known operation |
| 8 | Relative remaining budget in ns | Long > 0; owner further caps its allowed budget |

### Completion/rejection header (eight children)

Positions 1–7 echo the request's exact version, endpoint instance, controller
identity, token and operation. Position 8 is Int: 0 means successful completion;
negative values are documented owner errors. Rejections require a negative
value and preserve the last terminal completion.

An initial completion sentinel has endpoint/version set, controller global ID,
serial, controller instance, token and operation all zero, and result zero.
An uncorrelated malformed-input rejection may use the same zero identity with
a negative result. Neither sentinel can satisfy a fresh query. Partial zero
identities are invalid. A decoder must not manufacture a correlated rejection
from an unvalidated request header.

## Ownership and correlation

POD decoding returns owned header values and an owned payload POD. Borrowed
callback storage must never escape. One accepted request remains pending through
outside-callback application and successful completion publication. Retain its
full controller identity, token, operation and canonical payload for duplicate
comparison. Tokens advance globally within the endpoint incarnation. A different
controller using the same token is rejected; neither client automatically retries.
Every completion and correlated rejection includes the controller identity.

The owner validates the controller's actual registry incarnation. A caller marker
may be an inactive no-port Filter, scoped to the calibration run, with its actual
object.serial and advertised instance. This records lifetime, not a new science
or lifecycle owner. The private core's owning-user access remains the authority
boundary; claimed metadata alone is not authentication against that same user.

Owner metadata advertises protocol `pipewireao.rtc-control/1`, an exact profile,
owner PID and endpoint instance. A client binds exactly one node on the explicit
private remote, verifies process and registry incarnation, then validates retained
capabilities and the initial/current snapshot. Enumeration sequences are not
request tokens. Fresh status requires a newly applied query completion.

The callback validates bounded input, copies/stages and returns. The existing
serialized owner checks expiry/lifetime, decodes the operation-specific payload,
performs effects outside the callback and publishes afterward. One absolute
client deadline spans submission and observation; the relative owner budget
cannot extend it. Calibration additionally retains its next-request inactivity
deadline at request acceptance. Unknown outcome must not release held authority.

## Integer representation and tests

SPA Long is signed; UInt64 serials and calibration identity fields use explicit
bit-preserving `reinterpret(Int64, value)` / inverse in Julia, and native-endian
byte reinterpretation in Rust. Unsigned comparisons happen after decoding. Values
0, 2⁶³−1, 2⁶³, and 2⁶⁴−1 are mandatory codec boundary tests; zero remains invalid
where the schema requires a positive identity. Model time, budget, instance and
token retain their specified signed ranges.

The initial cross-language fixture uses a diagnostic profile and diagnostic
operation IDs only. Its APPLY operation is not a production lifecycle command.
A production owner must advertise its own reviewed profile and reject unknown
operations. Codec tests, a native private-core fixture, owner integration,
installed scientific/allocation checks and real-time qualification are separate
levels of evidence.
