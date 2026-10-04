using Test
include("heart_calibration_coordinates.jl")
const Coordinates=HeartCalibrationCoordinates

function synthetic_fits(path,values;scale="1")
    T=eltype(values);rows,columns=size(values)
    cards=[rpad("SIMPLE  = T",80),rpad("BITPIX  = $(T==Float32 ? -32 : -64)",80),
        rpad("NAXIS   = 2",80),rpad("NAXIS1  = $columns",80),rpad("NAXIS2  = $rows",80),
        rpad("BSCALE  = $scale",80),rpad("END",80)]
    header=rpad(join(cards),2880)
    integers=reinterpret(T==Float32 ? UInt32 : UInt64,vec(permutedims(values)))
    open(path,"w") do io
        write(io,header);write(io,hton.(integers))
    end
end

@testset "native FITS projections preserve their Float32 row representation" begin
    mktempdir() do directory
        path=joinpath(directory,"projection.fits")
        for T in (Float32,Float64)
            values=T[1 2 3;4 5 6]
            synthetic_fits(path,values)
            @test Coordinates.floating_matrix(path;shape=(2,3))==Float32.(values)
            @test_throws DimensionMismatch Coordinates.floating_matrix(path;shape=(3,2))
        end
        synthetic_fits(path,Float64[1 2;3 4];scale="2")
        @test_throws ArgumentError Coordinates.floating_matrix(path;shape=(2,2))
        synthetic_fits(path,Float32[1 NaN;3 4])
        @test_throws ArgumentError Coordinates.floating_matrix(path;shape=(2,2))
        synthetic_fits(path,Float32[1 2;3 4])
        bytes=read(path);write(path,bytes[1:end-1])
        @test_throws ArgumentError Coordinates.floating_matrix(path;shape=(2,2))
        write(path,bytes);link=joinpath(directory,"linked.fits");symlink(path,link)
        @test_throws ArgumentError Coordinates.floating_matrix(link;shape=(2,2))
    end
end
