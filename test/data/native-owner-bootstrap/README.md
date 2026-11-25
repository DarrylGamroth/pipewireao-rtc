# Native owner bootstrap Connect exchange

`connect.pod` and `connected.pod` are the request and successful reply for
one `pipewireao.rtc.owner-bootstrap/1` Connect. These are native SPA POD bytes
captured on a little-endian x86-64 host. A C or Rust implementation can decode
them and compare its serializer with the reference exchange.

Both records use version 1, controller global ID 7, controller serial
`0xffffffffffffffff`, controller instance 9, endpoint instance
`0x7fffffffffffffff`, token 2 and operation 2. The request carries a 1,000,000 ns
budget and an empty operation payload. The reply has result 0, lifecycle
Connected (3) and an empty message. Neither record conveys permission to close
an integrator.

Regenerate the records with
`julia --startup-file=no --project=. test/test_owner_bootstrap_codec.jl --write-golden`.
The [graph service contract](../../../docs/OWNER_BOOTSTRAP_DESIGN.md#graph-service-lifetime-across-rtc-sessions)
defines the lifecycle checks that supplement byte compatibility.
