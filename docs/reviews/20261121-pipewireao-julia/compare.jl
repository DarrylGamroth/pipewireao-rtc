# Characterize the reviewed releases. These differences are expected on 0.9.3.
using Libdl
using PipeWireAO
using Test

const L = PipeWireAO.LibPipeWire
const JLL = L.PipeWireAO_jll
const SPA_LIBRARY = JLL.libspa_ao

# spa/param/ndarray.h, default ABI from the JLL's installed headers.
struct NativeNdArrayInfo
    element_type::UInt32
    layout::UInt32
    rate::L.spa_fraction
    n_dimensions::UInt32
    shape::NTuple{64,UInt32}
end

println("Julia ", VERSION, ", PipeWireAO.jl ", pkgversion(PipeWireAO),
        ", PipeWireAO_jll ", pkgversion(JLL))
@testset "Symbols in the installed client and SPA libraries" begin
    for (product, symbols) in (
        (JLL.libpipewire_ao, (:pw_node_info_merge, :pw_port_info_merge, :pw_device_info_merge,
            :pw_link_info_merge, :pw_client_info_merge, :pw_factory_info_merge,
            :pw_ao_run_control_build_request, :pw_ndarray_filter_get_loop)),
        (SPA_LIBRARY, (:spa_hook_remove, :spa_pod_builder_int, :spa_pod_parser_get_int,
            :spa_pod_fixate, :spa_format_ndarray_ext_parse, :spa_format_ndarray_parse_string)),
    )
        Libdl.dlopen(product) do handle
            for symbol in symbols
                @test Libdl.dlsym_e(handle, symbol) != C_NULL
            end
        end
    end
end

@testset "One negotiated format, two parsers" begin
    selected = NdArrayFormat(NdArray.U8, (3,); layout = NdArray.ROW_MAJOR)
    offer = NdArrayEnumFormat(selected; element_type_alternatives = [NdArray.I8])
    format = ndarray_format(offer; id = SPA.PARAM_FORMAT)
    result = Ref{NativeNdArrayInfo}()
    GC.@preserve format begin
        pod = Ptr{L.spa_pod}(pointer(format.data))
        @test ccall((:spa_pod_fixate, SPA_LIBRARY), Cint, (Ptr{L.spa_pod},), pod) == 0
        @test ccall((:spa_format_ndarray_parse, SPA_LIBRARY), Cint,
                    (Ptr{L.spa_pod}, Ref{NativeNdArrayInfo}), pod, result) == 0
    end
    @test result[].element_type == UInt32(NdArray.U8)
    @test result[].n_dimensions == 1 && result[].shape[1] == 3
    @test_throws ArgumentError NdArrayFormat(format)
end

@testset "Duplicate metadata requirements" begin
    optical = MetadataRequirement(SPA.META_OPTICAL_CHOPPING)
    records = metadata_records(MetadataSnapshot((optical,)))
    @test metadata_records_valid(records, (optical,))
    @test metadata_records_valid(records, [optical])
    @test !metadata_records_valid(records, (optical, optical))
    @test metadata_records_valid(records, [optical, optical])
end
