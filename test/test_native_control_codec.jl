using Test
using PipeWireAO

using PipeWireAODeployment.NativeControlCodec

const SPA = PipeWireAO.SPA

const _header_name = "pipewireao.rtc.control.request.header"
const _payload_name = "pipewireao.rtc.control.request.payload"

function test_request(; serial=UInt64(5), payload=SPA.Struct(PipeWireAO.Pod(7)))
    controller = ControllerIdentity(UInt32(42), serial, Int64(9))
    RequestHeader(controller, Int64(17), Int64(23), UInt32(3), Int64(100_000)), payload
end

function raw_envelope(kind::Symbol, header::Vector{PipeWireAO.Pod}, payload::SPA.Struct;
        names=nothing, properties=nothing)
    hname, pname = names === nothing ?
        ("pipewireao.rtc.control.$(kind).header", "pipewireao.rtc.control.$(kind).payload") : names
    inner = SPA.Struct(PipeWireAO.Pod[
        PipeWireAO.Pod(hname), PipeWireAO.Pod(SPA.Struct(header)),
        PipeWireAO.Pod(pname), PipeWireAO.Pod(payload),
    ])
    param = SPA.Parameter(SPA.OBJECT_PROPS, SPA.PARAM_PROPS,
        SPA.Property(SPA.PROP_PARAMS, PipeWireAO.Pod(inner)))
    if properties !== nothing
        param = SPA.Parameter(SPA.OBJECT_PROPS, SPA.PARAM_PROPS, properties)
    end
    PipeWireAO.Pod(param)
end

function request_children(header)
    c = header.controller
    PipeWireAO.Pod[
        PipeWireAO.Pod(Int32(1)), PipeWireAO.Pod(Int64(17)),
        PipeWireAO.Pod(SPA.Id(c.global_id)), PipeWireAO.Pod(reinterpret(Int64, c.serial)),
        PipeWireAO.Pod(c.instance), PipeWireAO.Pod(header.token),
        PipeWireAO.Pod(SPA.Id(header.operation)), PipeWireAO.Pod(header.budget_ns),
    ]
end

@testset "native control envelope v1" begin
    @testset "requests and UInt64 serial preservation" begin
        for serial in (UInt64(1), UInt64(typemax(Int64)), UInt64(1) << 63, typemax(UInt64))
            header, payload = test_request(serial=serial)
            encoded = encode_request(header, payload)
            decoded, decoded_payload = decode_request(encoded)
            @test decoded == header
            @test decoded.controller.serial === serial
            @test decoded_payload == payload
            @test decode_request(copy(encoded.data))[1] == header
        end
    end

    @testset "reply success, error and sentinels" begin
        payload = SPA.Struct(PipeWireAO.Pod(nothing))
        identity = ControllerIdentity(UInt32(15), UInt64(1) << 63, Int64(4))
        for result in (Int32(0), Int32(-5))
            header = ReplyHeader(identity, Int64(8), Int64(10), UInt32(2), result)
            pod = encode_completion(header, payload; endpoint=:lifecycle)
            decoded, got = decode_completion(pod; endpoint=:lifecycle)
            @test decoded == header && got == payload
        end
        sentinel = ReplyHeader(Int64(8), Int32(0))
        initial = encode_completion(sentinel, payload; endpoint=:lifecycle)
        @test decode_completion(initial; endpoint=:lifecycle)[1] == sentinel
        rejection = ReplyHeader(Int64(8), Int32(-22))
        reject_pod = encode_rejection(rejection, payload; endpoint=:calibration)
        @test decode_rejection(reject_pod; endpoint=:calibration)[1] == rejection
        correlated = ReplyHeader(identity, Int64(8), Int64(10), UInt32(2), Int32(-3))
        @test decode_rejection(encode_rejection(correlated, payload; endpoint=:lifecycle);
            endpoint=:lifecycle)[1] == correlated
    end

    @testset "exact names, arity, ordering, flags and scalar widths" begin
        header, payload = test_request()
        children = request_children(header)
        good = raw_envelope(:request, children, payload)
        @test decode_request(good)[1] == header
        @test_throws ArgumentError decode_request(raw_envelope(:request, children, payload;
            names=("wrong", _payload_name)))
        @test_throws ArgumentError decode_request(raw_envelope(:request, children[2:end], payload))
        reordered = copy(children); reordered[1], reordered[2] = reordered[2], reordered[1]
        @test_throws ArgumentError decode_request(raw_envelope(:request, reordered, payload))
        duplicate = copy(children); duplicate[8] = duplicate[7]
        @test_throws ArgumentError decode_request(raw_envelope(:request, duplicate, payload))

        nested = SPA.Struct(PipeWireAO.Pod("inner"))
        outer = SPA.Struct(PipeWireAO.Pod[
            PipeWireAO.Pod(_header_name), PipeWireAO.Pod(SPA.Struct(children)),
            PipeWireAO.Pod(_payload_name), PipeWireAO.Pod(nested),
        ])
        nonzero_flags = SPA.Property(SPA.PROP_PARAMS, PipeWireAO.Pod(outer); flags=1)
        @test_throws ArgumentError decode_request(raw_envelope(:request, children, payload;
            properties=nonzero_flags))
        duplicate_properties = SPA.Property[
            SPA.Property(SPA.PROP_PARAMS, PipeWireAO.Pod(outer)),
            SPA.Property(SPA.PROP_PARAMS, PipeWireAO.Pod(outer)),
        ]
        @test_throws ArgumentError decode_request(raw_envelope(:request, children, payload;
            properties=duplicate_properties))

        short_int = PipeWireAO.Pod(UInt8[0x01, 0x00, 0x00, 0x00, UInt8(SPA.POD_INT), 0, 0, 0, 0x01])
        wrongwidth = copy(children); wrongwidth[1] = short_int
        @test_throws ArgumentError decode_request(raw_envelope(:request, wrongwidth, payload))
    end

    @testset "identity and result validation" begin
        header, payload = test_request()
        @test_throws ArgumentError ControllerIdentity(UInt32(0), UInt64(1), Int64(1))
        @test_throws ArgumentError ControllerIdentity(UInt32(typemax(UInt32)), UInt64(1), Int64(1))
        @test_throws ArgumentError ControllerIdentity(UInt32(1), UInt64(0), Int64(1))
        @test_throws ArgumentError ControllerIdentity(UInt32(1), UInt64(1), Int64(0))
        @test_throws ArgumentError RequestHeader(header.controller, Int64(1), Int64(0), UInt32(1), Int64(1))

        children = request_children(header)
        for index in (2, 4, 5, 6, 8)
            partial = copy(children)
            partial[index] = PipeWireAO.Pod(Int64(0))
            @test_throws ArgumentError decode_request(raw_envelope(:request, partial, payload))
        end
        partial_id = copy(children); partial_id[3] = PipeWireAO.Pod(SPA.Id(0))
        @test_throws ArgumentError decode_request(raw_envelope(:request, partial_id, payload))
        @test_throws ArgumentError decode_request(raw_envelope(:request,
            [children[1:3]; PipeWireAO.Pod(Int64(0)); children[5:8]], payload))

        sent = ReplyHeader(Int64(5), Int32(0))
        @test_throws ArgumentError encode_completion(ReplyHeader(Int64(5), Int32(-1)), payload;
            endpoint=:lifecycle)
        @test_throws ArgumentError encode_rejection(sent, payload; endpoint=:lifecycle)
        @test_throws ArgumentError encode_completion(
            ReplyHeader(header.controller, Int64(5), Int64(7), UInt32(2), Int32(1)), payload;
            endpoint=:lifecycle)
    end

    @testset "payload grammar and depth" begin
        allowed = SPA.Struct(
            PipeWireAO.Pod(nothing), PipeWireAO.Pod(true), PipeWireAO.Pod(SPA.Id(9)),
            PipeWireAO.Pod(Int32(4)), PipeWireAO.Pod(Int64(-7)), PipeWireAO.Pod(Float32(1)),
            PipeWireAO.Pod(Float64(2)), PipeWireAO.Pod("text"),
            PipeWireAO.Pod(SPA.Bytes(UInt8[1, 2])),
            PipeWireAO.Pod(SPA.Array(Int32[1, 2, 3])),
            PipeWireAO.Pod(SPA.Struct(PipeWireAO.Pod("nested"))),
        )
        hdr, _ = test_request(payload=allowed)
        @test decode_request(encode_request(hdr, allowed))[2] == allowed

        nested = SPA.Struct(PipeWireAO.Pod("end"))
        for _ in 1:7
            nested = SPA.Struct(PipeWireAO.Pod(nested))
        end
        @test_nowarn encode_request(hdr, nested)
        too_deep = SPA.Struct(PipeWireAO.Pod(nested))
        @test_throws ArgumentError encode_request(hdr, too_deep)
        too_deep_pod = raw_envelope(:request, request_children(hdr), too_deep)
        @test_throws ArgumentError decode_request(too_deep_pod)

        unsupported = PipeWireAO.Pod(SPA.Object(SPA.OBJECT_PROPS, SPA.PARAM_PROPS, SPA.Property[]))
        @test_throws ArgumentError encode_request(hdr, SPA.Struct(unsupported))
        @test_throws ArgumentError encode_request(hdr, SPA.Struct(PipeWireAO.Pod(SPA.Fd(3))))
        choice = SPA.Choice(SPA.CHOICE_NONE, Int32[1])
        @test_throws ArgumentError encode_request(hdr, SPA.Struct(PipeWireAO.Pod(choice)))
        @test_throws ArgumentError encode_request(hdr, SPA.Struct(PipeWireAO.Pod(SPA.Pointer(1, Ptr{Cvoid}(C_NULL)))))
        @test_throws ArgumentError encode_request(hdr, SPA.Struct(PipeWireAO.Pod(SPA.Sequence(0))))

        bad_utf8 = PipeWireAO.Pod(UInt8[0x02, 0, 0, 0, UInt8(SPA.POD_STRING), 0, 0, 0, 0xff, 0])
        embedded_null = PipeWireAO.Pod(UInt8[0x03, 0, 0, 0, UInt8(SPA.POD_STRING), 0, 0, 0, 0x61, 0, 0])
        @test_throws ArgumentError encode_request(hdr, SPA.Struct(bad_utf8))
        @test_throws ArgumentError encode_request(hdr, SPA.Struct(embedded_null))
    end

    @testset "exact byte bounds and trailing input" begin
        hdr, _ = test_request()
        under = SPA.Struct(PipeWireAO.Pod(SPA.Bytes(fill(UInt8(0x5a), 15_000))))
        @test sizeof(encode_request(hdr, under)) <= 16 * 1024
        over = SPA.Struct(PipeWireAO.Pod(SPA.Bytes(fill(UInt8(0x5a), 16_384))))
        @test_throws ArgumentError encode_request(hdr, over)
        oversized_array = SPA.Struct(PipeWireAO.Pod(SPA.Array(collect(Int32, 1:5_000))))
        @test_throws ArgumentError encode_request(hdr, oversized_array)

        lifecycle = ReplyHeader(hdr.controller, hdr.endpoint_instance, hdr.token,
            hdr.operation, Int32(0))
        lifecycle_payload = SPA.Struct(PipeWireAO.Pod(SPA.Bytes(fill(UInt8(0x44), 63_000))))
        @test sizeof(encode_completion(lifecycle, lifecycle_payload; endpoint=:lifecycle)) <= 64 * 1024
        @test_throws ArgumentError encode_completion(
            lifecycle, SPA.Struct(PipeWireAO.Pod(SPA.Bytes(fill(UInt8(0x44), 65_536))));
            endpoint=:lifecycle)

        calibration_payload = SPA.Struct(PipeWireAO.Pod(SPA.Bytes(fill(UInt8(0x44), 127_000))))
        @test sizeof(encode_completion(lifecycle, calibration_payload; endpoint=:calibration)) <= 128 * 1024
        @test_throws ArgumentError encode_completion(
            lifecycle, SPA.Struct(PipeWireAO.Pod(SPA.Bytes(fill(UInt8(0x44), 131_072))));
            endpoint=:calibration)
        @test_throws ArgumentError encode_completion(lifecycle, SPA.Struct(); endpoint=:other)

        good = encode_request(hdr, SPA.Struct())
        @test_throws ArgumentError decode_request([good.data; UInt8(0)])
        @test_throws ArgumentError decode_request(good.data[1:end-1])
        malformed_array = PipeWireAO.Pod(SPA.Array(Int32[1, 2]))
        push!(malformed_array.data, 0x00)
        @test_throws ArgumentError encode_request(hdr, SPA.Struct(malformed_array))
    end
end
