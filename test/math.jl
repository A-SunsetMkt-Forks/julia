# This file is a part of Julia. License is MIT: https://julialang.org/license

include("testhelpers/EvenIntegers.jl")
using .EvenIntegers

using Random
using LinearAlgebra
using Base.Experimental: @force_compile

function isnan_type(::Type{T}, x) where T
    isa(x, T) && isnan(x)
end

# has_fma has no runtime support.
# So we need function wrappers to make this work.
has_fma_Int() = Core.Compiler.have_fma(Int)
has_fma_Float32() = Core.Compiler.have_fma(Float32)
has_fma_Float64() = Core.Compiler.have_fma(Float64)

has_fma = Dict(
    Int => has_fma_Int(),
    Rational{Int} => has_fma_Int(),
    Float32 => has_fma_Float32(),
    Float64 => has_fma_Float64(),
    BigFloat => true,
)

@testset "clamp" begin
    let
        @test clamp(0, 1, 3) == 1
        @test clamp(1, 1, 3) == 1
        @test clamp(2, 1, 3) == 2
        @test clamp(3, 1, 3) == 3
        @test clamp(4, 1, 3) == 3

        @test clamp(0.0, 1, 3) == 1.0
        @test clamp(1.0, 1, 3) == 1.0
        @test clamp(2.0, 1, 3) == 2.0
        @test clamp(3.0, 1, 3) == 3.0
        @test clamp(4.0, 1, 3) == 3.0

        @test clamp.([0, 1, 2, 3, 4], 1.0, 3.0) == [1.0, 1.0, 2.0, 3.0, 3.0]
        @test clamp.([0 1; 2 3], 1.0, 3.0) == [1.0 1.0; 2.0 3.0]

        @test clamp(-200, Int8) === typemin(Int8)
        @test clamp(100, Int8) === Int8(100)
        @test clamp(200, Int8) === typemax(Int8)

        let x = [0.0, 1.0, 2.0, 3.0, 4.0]
            clamp!(x, 1, 3)
            @test x == [1.0, 1.0, 2.0, 3.0, 3.0]
        end

        @test clamp(typemax(UInt64), Int64) === typemax(Int64)
        @test clamp(typemin(Int), UInt64) === typemin(UInt64)
        @test clamp(Int16(-1), UInt16) === UInt16(0)
        @test clamp(-1, 2, UInt(0)) === UInt(2)
        @test clamp(typemax(UInt16), Int16) === Int16(32767)

        # clamp should not allocate a BigInt for typemax(Int16)
        let x = big(2) ^ 100
            @test (@allocated clamp(x, Int16)) == 0
        end

        let x = clamp(2.0, BigInt)
            @test x isa BigInt
            @test x == big(2)
        end
    end
end

@testset "constants" begin
    @test pi != ℯ
    @test ℯ != 1//2
    @test 1//2 <= ℯ
    @test ℯ <= 15//3
    @test big(1//2) < ℯ
    @test ℯ < big(20//6)
    @test ℯ^pi == exp(pi)
    @test ℯ^2 == exp(2)
    @test ℯ^2.4 == exp(2.4)
    @test ℯ^(2//3) == exp(2//3)

    @test Float16(3.0) < pi
    @test pi < Float16(4.0)
    @test widen(pi) === pi

    @test occursin("3.14159", sprint(show, MIME"text/plain"(), π))
    @test repr(Any[pi ℯ; ℯ pi]) == "Any[π ℯ; ℯ π]"
    @test string(pi) == "π"

    @test sin(π) == sind(180) === sinpi(1) === sinpi(1//1) == tan(π) == 0
    @test tan(π) == tand(180) === tanpi(1) === tanpi(1//1) === -0.0
    @test cos(π) == cosd(180) === cospi(1) === cospi(1//1) == sec(π) == -1
    @test csc(π) == 1/0 && cot(π) == -1/0
    @test sincos(π) === sincospi(1) == (0, -1)
end

@testset "frexp,ldexp,significand,exponent" begin
    @testset "$T" for T in (Float16,Float32,Float64)
        for z in (zero(T),-zero(T))
            frexp(z) === (z,0)
            significand(z) === z
            @test_throws DomainError exponent(z)
        end

        for (a,b) in [(T(12.8),T(0.8)),
                      (prevfloat(floatmin(T)), prevfloat(one(T), 2)),
                      (prevfloat(floatmin(T)), prevfloat(one(T), 2)),
                      (prevfloat(floatmin(T)), nextfloat(one(T), -2)),
                      (nextfloat(zero(T), 3), T(0.75)),
                      (prevfloat(zero(T), -3), T(0.75)),
                      (nextfloat(zero(T)), T(0.5))]

            n = Int(log2(a/b))
            @test frexp(a) == (b,n)
            @test ldexp(b,n) == a
            @test ldexp(a,-n) == b
            @test significand(a) == 2b
            @test exponent(a) == n-1

            @test frexp(-a) == (-b,n)
            @test ldexp(-b,n) == -a
            @test ldexp(-a,-n) == -b
            @test significand(-a) == -2b
            @test exponent(-a) == n-1
        end
        @test_throws DomainError exponent(convert(T,NaN))
        @test isnan_type(T, significand(convert(T,NaN)))
        x,y = frexp(convert(T,NaN))
        @test isnan_type(T, x)
        @test y == 0

        @testset "ldexp function" begin
            @test ldexp(T(0.0), 0) === T(0.0)
            @test ldexp(T(-0.0), 0) === T(-0.0)
            @test ldexp(T(Inf), 1) === T(Inf)
            @test ldexp(T(Inf), 10000) === T(Inf)
            @test ldexp(T(-Inf), 1) === T(-Inf)
            @test isnan_type(T, ldexp(T(NaN), 10))
            @test ldexp(T(1.0), 0) === T(1.0)
            @test ldexp(T(0.8), 4) === T(12.8)
            @test ldexp(T(-0.854375), 5) === T(-27.34)
            @test ldexp(T(1.0), typemax(Int)) === T(Inf)
            @test ldexp(T(1.0), typemin(Int)) === T(0.0)
            @test ldexp(prevfloat(floatmin(T)), typemax(Int)) === T(Inf)
            @test ldexp(prevfloat(floatmin(T)), typemin(Int)) === T(0.0)

            @test ldexp(T(0.0), Int128(0)) === T(0.0)
            @test ldexp(T(-0.0), Int128(0)) === T(-0.0)
            @test ldexp(T(1.0), Int128(0)) === T(1.0)
            @test ldexp(T(0.8), Int128(4)) === T(12.8)
            @test ldexp(T(-0.854375), Int128(5)) === T(-27.34)
            @test ldexp(T(1.0), typemax(Int128)) === T(Inf)
            @test ldexp(T(1.0), typemin(Int128)) === T(0.0)
            @test ldexp(prevfloat(floatmin(T)), typemax(Int128)) === T(Inf)
            @test ldexp(prevfloat(floatmin(T)), typemin(Int128)) === T(0.0)

            @test ldexp(T(0.0), BigInt(0)) === T(0.0)
            @test ldexp(T(-0.0), BigInt(0)) === T(-0.0)
            @test ldexp(T(1.0), BigInt(0)) === T(1.0)
            @test ldexp(T(0.8), BigInt(4)) === T(12.8)
            @test ldexp(T(-0.854375), BigInt(5)) === T(-27.34)
            @test ldexp(T(1.0), BigInt(typemax(Int128))) === T(Inf)
            @test ldexp(T(1.0), BigInt(typemin(Int128))) === T(0.0)
            @test ldexp(prevfloat(floatmin(T)), BigInt(typemax(Int128))) === T(Inf)
            @test ldexp(prevfloat(floatmin(T)), BigInt(typemin(Int128))) === T(0.0)

            # Test also against BigFloat reference. Needs to be exactly rounded.
            @test ldexp(floatmin(T), -1) == T(ldexp(big(floatmin(T)), -1))
            @test ldexp(floatmin(T), -2) == T(ldexp(big(floatmin(T)), -2))
            @test ldexp(floatmin(T)/2, 0) == T(ldexp(big(floatmin(T)/2), 0))
            @test ldexp(floatmin(T)/3, 0) == T(ldexp(big(floatmin(T)/3), 0))
            @test ldexp(floatmin(T)/3, -1) == T(ldexp(big(floatmin(T)/3), -1))
            @test ldexp(floatmin(T)/3, 11) == T(ldexp(big(floatmin(T)/3), 11))
            @test ldexp(floatmin(T)/11, -10) == T(ldexp(big(floatmin(T)/11), -10))
            @test ldexp(-floatmin(T)/11, -10) == T(ldexp(big(-floatmin(T)/11), -10))
        end
    end
end

# We compare to BigFloat instead of hard-coding
# values, assuming that BigFloat has an independently tested implementation.
@testset "basic math functions" begin
    @testset "$T" for T in (Float16, Float32, Float64)
        x = T(1//3)
        y = T(1//2)
        yi = 4
        @testset "Random values" begin
            @test x^y === T(big(x)^big(y))
            @test x^1 === x
            @test x^yi === T(big(x)^yi)
            @test (-x)^yi == x^yi
            @test (-x)^(yi+1) == -(x^(yi+1))
            @test acos(x) ≈ acos(big(x))
            @test acosh(1+x) ≈ acosh(big(1+x))
            @test asin(x) ≈ asin(big(x))
            @test asinh(x) ≈ asinh(big(x))
            @test atan(x) ≈ atan(big(x))
            @test atan(x,y) ≈ atan(big(x),big(y))
            @test atanh(x) ≈ atanh(big(x))
            @test cbrt(x) ≈ cbrt(big(x))
            @test fourthroot(x) ≈ fourthroot(big(x))
            @test cos(x) ≈ cos(big(x))
            @test cosh(x) ≈ cosh(big(x))
            @test cospi(x) ≈ cospi(big(x))
            @test exp(x) ≈ exp(big(x))
            @test exp10(x) ≈ exp10(big(x))
            @test exp2(x) ≈ exp2(big(x))
            @test expm1(x) ≈ expm1(big(x))
            @test expm1(T(-1.1)) ≈ expm1(big(T(-1.1)))
            @test hypot(x,y) ≈ hypot(big(x),big(y))
            @test hypot(x,x,y) ≈ hypot(hypot(big(x),big(x)),big(y))
            @test hypot(x,x,y,y) ≈ hypot(hypot(big(x),big(x)),hypot(big(y),big(y)))
            @test log(x) ≈ log(big(x))
            @test log10(x) ≈ log10(big(x))
            @test log1p(x) ≈ log1p(big(x))
            @test log2(x) ≈ log2(big(x))
            @test sin(x) ≈ sin(big(x))
            @test sinh(x) ≈ sinh(big(x))
            @test sinpi(x) ≈ sinpi(big(x))
            @test sqrt(x) ≈ sqrt(big(x))
            @test tan(x) ≈ tan(big(x))
            @test tanh(x) ≈ tanh(big(x))
            @test tanpi(x) ≈ tanpi(big(x))
            @test sec(x) ≈ sec(big(x))
            @test csc(x) ≈ csc(big(x))
            @test secd(x) ≈ secd(big(x))
            @test cscd(x) ≈ cscd(big(x))
            @test sech(x) ≈ sech(big(x))
            @test csch(x) ≈ csch(big(x))
        end
        @testset "Special values" begin
            @test isequal(T(1//4)^T(1//2), T(1//2))
            @test isequal(T(1//4)^2, T(1//16))
            @test isequal(acos(T(1)), T(0))
            @test isequal(acosh(T(1)), T(0))
            @test asin(T(1)) ≈ T(pi)/2 atol=eps(T)
            @test atan(T(1)) ≈ T(pi)/4 atol=eps(T)
            @test atan(T(1),T(1)) ≈ T(pi)/4 atol=eps(T)
            @test isequal(cbrt(T(0)), T(0))
            @test isequal(cbrt(T(1)), T(1))
            @test isequal(cbrt(T(1000000000))^3, T(1000)^3)
            @test isequal(fourthroot(T(0)), T(0))
            @test isequal(fourthroot(T(1)), T(1))
            @test isequal(fourthroot(T(100000000))^4, T(100)^4)
            @test isequal(cos(T(0)), T(1))
            @test cos(T(pi)/2) ≈ T(0) atol=eps(T)
            @test isequal(cos(T(pi)), T(-1))
            @test exp(T(1)) ≈ T(ℯ) atol=2*eps(T)
            @test isequal(exp10(T(1)), T(10))
            @test isequal(exp2(T(1)), T(2))
            @test isequal(expm1(T(0)), T(0))
            @test isequal(expm1(-floatmax(T)), -one(T))
            @test isequal(expm1(floatmax(T)), T(Inf))
            @test expm1(T(1)) ≈ T(ℯ)-1 atol=2*eps(T)
            @test isequal(hypot(T(3),T(4)), T(5))
            @test isequal(hypot(floatmax(T),T(1)),floatmax(T))
            @test isequal(hypot(floatmin(T)*sqrt(eps(T)),T(0)),floatmin(T)*sqrt(eps(T)))
            @test isequal(floatmin(T)*hypot(1.368423059742933,1.3510496552495361),hypot(floatmin(T)*1.368423059742933,floatmin(T)*1.3510496552495361))
            @test isequal(log(T(1)), T(0))
            @test isequal(log(ℯ,T(1)), T(0))
            @test log(T(ℯ)) ≈ T(1) atol=eps(T)
            @test isequal(log10(T(1)), T(0))
            @test isequal(log10(T(10)), T(1))
            @test isequal(log1p(T(0)), T(0))
            @test log1p(T(ℯ)-1) ≈ T(1) atol=eps(T)
            @test isequal(log2(T(1)), T(0))
            @test isequal(log2(T(2)), T(1))
            @test isequal(sin(T(0)), T(0))
            @test isequal(sin(T(pi)/2), T(1))
            @test sin(T(pi)) ≈ T(0) atol=eps(T)
            @test isequal(sqrt(T(0)), T(0))
            @test isequal(sqrt(T(1)), T(1))
            @test isequal(sqrt(T(100000000))^2, T(10000)^2)
            @test isequal(tan(T(0)), T(0))
            @test tan(T(pi)/4) ≈ T(1) atol=eps(T)
            @test isequal(sec(T(pi)), -one(T))
            @test isequal(csc(T(pi)/2), one(T))
            @test isequal(secd(T(180)), -one(T))
            @test isequal(cscd(T(90)), one(T))
            @test isequal(sech(log(one(T))), one(T))
            @test isequal(csch(zero(T)), T(Inf))
            @test zero(T)^y === zero(T)
            @test zero(T)^zero(T) === one(T)
            @test zero(T)^(-y) === T(Inf)
            @test zero(T)^T(NaN) === T(NaN)
            @test one(T)^y === one(T)
            @test one(T)^zero(T) === one(T)
            @test one(T)^T(NaN) === one(T)
            @test isnan(T(NaN)^T(-.5))
        end
        @testset "Inverses" begin
            @test acos(cos(x)) ≈ x
            @test acosh(cosh(x)) ≈ x
            @test asin(sin(x)) ≈ x
            @test cbrt(x)^3 ≈ x
            @test cbrt(x^3) ≈ x
            @test fourthroot(x)^4 ≈ x
            @test fourthroot(x^4) ≈ x
            @test asinh(sinh(x)) ≈ x
            @test atan(tan(x)) ≈ x
            @test atan(x,y) ≈ atan(x/y)
            @test atanh(tanh(x)) ≈ x
            @test cos(acos(x)) ≈ x
            @test cosh(acosh(1+x)) ≈ 1+x
            @test exp(log(x)) ≈ x
            @test exp10(log10(x)) ≈ x
            @test exp2(log2(x)) ≈ x
            @test expm1(log1p(x)) ≈ x
            @test log(exp(x)) ≈ x
            @test log10(exp10(x)) ≈ x
            @test log1p(expm1(x)) ≈ x
            @test log2(exp2(x)) ≈ x
            @test sin(asin(x)) ≈ x
            @test sinh(asinh(x)) ≈ x
            @test sqrt(x)^2 ≈ x
            @test sqrt(x^2) ≈ x
            @test tan(atan(x)) ≈ x
            @test tanh(atanh(x)) ≈ x
        end
        @testset "Relations between functions" begin
            @test cosh(x) ≈ (exp(x)+exp(-x))/2
            @test cosh(x)^2-sinh(x)^2 ≈ 1
            @test hypot(x,y) ≈ sqrt(x^2+y^2)
            @test sin(x)^2+cos(x)^2 ≈ 1
            @test sinh(x) ≈ (exp(x)-exp(-x))/2
            @test tan(x) ≈ sin(x)/cos(x)
            @test tanh(x) ≈ sinh(x)/cosh(x)
            @test sec(x) ≈ inv(cos(x))
            @test csc(x) ≈ inv(sin(x))
            @test secd(x) ≈ inv(cosd(x))
            @test cscd(x) ≈ inv(sind(x))
            @test sech(x) ≈ inv(cosh(x))
            @test csch(x) ≈ inv(sinh(x))
        end
        @testset "Edge cases" begin
            @test isinf(log(zero(T)))
            @test isnan_type(T, log(convert(T,NaN)))
            @test_throws DomainError log(-one(T))
            @test isinf(log1p(-one(T)))
            @test isnan_type(T, log1p(convert(T,NaN)))
            @test_throws DomainError log1p(convert(T,-2.0))
            @test hypot(T(0), T(0)) === T(0)
            @test hypot(T(Inf), T(Inf)) === T(Inf)
            @test hypot(T(Inf), T(x)) === T(Inf)
            @test hypot(T(Inf), T(NaN)) === T(Inf)
            @test isnan_type(T, hypot(T(x), T(NaN)))
            @test tanh(T(Inf)) === T(1)
        end
    end
    @testset "Float16 expm1" begin
        T=Float16
        @test isequal(expm1(T(0)), T(0))
        @test isequal(expm1(-floatmax(T)), -one(T))
        @test isequal(expm1(floatmax(T)), T(Inf))
        @test expm1(T(1)) ≈ T(ℯ)-1 atol=2*eps(T)
    end
end

@testset "exponential functions" for T in (Float64, Float32, Float16)
    for (func, invfunc) in ((exp2, log2), (exp, log), (exp10, log10))
        @testset "$T $func accuracy" begin
            minval, maxval = invfunc(floatmin(T)),prevfloat(invfunc(floatmax(T)))
            # Test range and extensively test numbers near 0.
            X = Iterators.flatten((minval:T(.1):maxval,
                                   minval/100:T(.0021):maxval/100,
                                   minval/10000:T(.000021):maxval/10000,
                                   nextfloat(zero(T)),
                                   T(-100):T(1):T(100) ))
            for x in X
                y, yb = func(x), func(widen(x))
                if isfinite(eps(T(yb)))
                    @test abs(y-yb) <= 1.2*eps(T(yb))
                end
            end
        end
        @testset "$T $func edge cases" begin
            @test func(T(-Inf)) === T(0.0)
            @test func(T(Inf)) === T(Inf)
            @test func(T(NaN)) === T(NaN)
            @test func(T(0.0)) === T(1.0) # exact
            @test func(T(5000.0)) === T(Inf)
            @test func(T(-5000.0)) === T(0.0)
        end
    end
end

@testset "https://github.com/JuliaLang/julia/issues/56782" begin
    @test isnan(exp(reinterpret(Float64, 0x7ffbb14880000000)))
end

@testset "test abstractarray trig functions" begin
    TAA = rand(2,2)
    TAA = (TAA + TAA')/2.
    STAA = Symmetric(TAA)
    @test Array(atanh.(STAA)) == atanh.(TAA)
    @test Array(asinh.(STAA)) == asinh.(TAA)
    TAA .+= 1
    @test Array(acosh.(STAA)) == acosh.(TAA)
    @test Array(acsch.(STAA)) == acsch.(TAA)
    @test Array(acoth.(STAA)) == acoth.(TAA)
    @test sind(TAA) == sin(deg2rad.(TAA))
    @test cosd(TAA) == cos(deg2rad.(TAA))
    @test tand(TAA) == tan(deg2rad.(TAA))
    @test asind(TAA) == rad2deg.(asin(TAA))
    @test acosd(TAA) == rad2deg.(acos(TAA))
    @test atand(TAA) == rad2deg.(atan(TAA))
    @test asecd(TAA) == rad2deg.(asec(TAA))
    @test acscd(TAA) == rad2deg.(acsc(TAA))
    @test acotd(TAA) == rad2deg.(acot(TAA))

    m = rand(3,2) # not square matrix
    ex = @test_throws DimensionMismatch sind(m)
    @test startswith(ex.value.msg, "matrix is not square")
    ex = @test_throws DimensionMismatch cosd(m)
    @test startswith(ex.value.msg, "matrix is not square")
    ex = @test_throws DimensionMismatch tand(m)
    @test startswith(ex.value.msg, "matrix is not square")
    ex = @test_throws DimensionMismatch asind(m)
    @test startswith(ex.value.msg, "matrix is not square")
    ex = @test_throws DimensionMismatch acosd(m)
    @test startswith(ex.value.msg, "matrix is not square")
    ex = @test_throws DimensionMismatch atand(m)
    @test startswith(ex.value.msg, "matrix is not square")
    ex = @test_throws DimensionMismatch asecd(m)
    @test startswith(ex.value.msg, "matrix is not square")
    ex = @test_throws DimensionMismatch acscd(m)
    @test startswith(ex.value.msg, "matrix is not square")
    ex = @test_throws DimensionMismatch acotd(m)
    @test startswith(ex.value.msg, "matrix is not square")
end

@testset "check exp2(::Integer) matches exp2(::Float)" begin
    for ii in -2048:2048
        expected = exp2(float(ii))
        @test exp2(Int16(ii)) == expected
        @test exp2(Int32(ii)) == expected
        @test exp2(Int64(ii)) == expected
        @test exp2(Int128(ii)) == expected
        if ii >= 0
            @test exp2(UInt16(ii)) == expected
            @test exp2(UInt32(ii)) == expected
            @test exp2(UInt64(ii)) == expected
            @test exp2(UInt128(ii)) == expected
        end
    end
end

@testset "deg2rad/rad2deg" begin
    @testset "$T" for T in (Int, Float16, Float32, Float64, BigFloat)
        @test deg2rad(T(180)) ≈ 1pi
        @test deg2rad.(T[45, 60]) ≈ [pi/T(4), pi/T(3)]
        @test rad2deg.([pi/T(4), pi/T(3)]) ≈ [45, 60]
        @test rad2deg(T(1)*pi) ≈ 180
        @test rad2deg(T(1)) ≈ rad2deg(true)
        @test deg2rad(T(1)) ≈ deg2rad(true)
    end
    @testset "accuracy" begin
        @testset "$T" for T in (Float16, Float32, Float64)
            @test rad2deg(T(1)) === setprecision(BigFloat, 500) do
                T(180 / BigFloat(pi))
            end
            @test deg2rad(T(1)) === setprecision(BigFloat, 500) do
                T(BigFloat(pi) / 180)
            end
        end
    end
    @test deg2rad(180 + 60im) ≈ pi + (pi/3)*im
    @test rad2deg(pi + (pi/3)*im) ≈ 180 + 60im
end

# ensure zeros are signed the same
⩲(x,y) = typeof(x) == typeof(y) && x == y && signbit(x) == signbit(y)
⩲(x::Tuple, y::Tuple) = length(x) == length(y) && all(map(⩲,x,y))

@testset "degree-based trig functions" begin
    @testset "$T" for T = (Float32,Float64,Rational{Int},BigFloat)
        fT = typeof(float(one(T)))
        fTsc = typeof( (float(one(T)), float(one(T))) )
        for x = -400:40:400
            @test sind(convert(T,x))::fT ≈ sin(pi*convert(fT,x)/180) atol=eps(deg2rad(convert(fT,x)))
            @test cosd(convert(T,x))::fT ≈ cos(pi*convert(fT,x)/180) atol=eps(deg2rad(convert(fT,x)))

            s,c = sincosd(convert(T,x))
            @test s::fT ≈ sin(pi*convert(fT,x)/180) atol=eps(deg2rad(convert(fT,x)))
            @test c::fT ≈ cos(pi*convert(fT,x)/180) atol=eps(deg2rad(convert(fT,x)))
        end
        @testset "sind" begin
            @test sind(convert(T,0.0))::fT ⩲ zero(fT)
            @test sind(convert(T,180.0))::fT ⩲ zero(fT)
            @test sind(convert(T,360.0))::fT ⩲ zero(fT)
            T != Rational{Int} && @test sind(convert(T,-0.0))::fT ⩲ -zero(fT)
            @test sind(convert(T,-180.0))::fT ⩲ -zero(fT)
            @test sind(convert(T,-360.0))::fT ⩲ -zero(fT)
            if T <: AbstractFloat
                @test isnan(sind(T(NaN)))
            end
        end
        @testset "cosd" begin
            @test cosd(convert(T,90))::fT ⩲ zero(fT)
            @test cosd(convert(T,270))::fT ⩲ zero(fT)
            @test cosd(convert(T,-90))::fT ⩲ zero(fT)
            @test cosd(convert(T,-270))::fT ⩲ zero(fT)
            if T <: AbstractFloat
                @test isnan(cosd(T(NaN)))
            end
        end
        @testset "sincosd" begin
            @test sincosd(convert(T,-360))::fTsc ⩲ ( -zero(fT),  one(fT) )
            @test sincosd(convert(T,-270))::fTsc ⩲ (   one(fT), zero(fT) )
            @test sincosd(convert(T,-180))::fTsc ⩲ ( -zero(fT), -one(fT) )
            @test sincosd(convert(T, -90))::fTsc ⩲ (  -one(fT), zero(fT) )
            @test sincosd(convert(T,   0))::fTsc ⩲ (  zero(fT),  one(fT) )
            @test sincosd(convert(T,  90))::fTsc ⩲ (   one(fT), zero(fT) )
            @test sincosd(convert(T, 180))::fTsc ⩲ (  zero(fT), -one(fT) )
            @test sincosd(convert(T, 270))::fTsc ⩲ (  -one(fT), zero(fT) )
            if T <: AbstractFloat
                @test_throws DomainError sincosd(T(Inf))
                @test all(isnan.(sincosd(T(NaN))))
            end
        end

        @testset "$name" for (name, (sinpi, cospi)) in (
            "sinpi and cospi" => (sinpi, cospi),
            "sincospi" => (x->sincospi(x)[1], x->sincospi(x)[2])
        )
            @testset "pi * $x" for x = -3:0.3:3
                @test sinpi(convert(T,x))::fT ≈ sin(pi*convert(fT,x)) atol=eps(pi*convert(fT,x))
                @test cospi(convert(T,x))::fT ≈ cos(pi*convert(fT,x)) atol=eps(pi*convert(fT,x))
            end

            @test sinpi(convert(T,0.0))::fT ⩲ zero(fT)
            @test sinpi(convert(T,1.0))::fT ⩲ zero(fT)
            @test sinpi(convert(T,2.0))::fT ⩲ zero(fT)
            T != Rational{Int} && @test sinpi(convert(T,-0.0))::fT ⩲ -zero(fT)
            @test sinpi(convert(T,-1.0))::fT ⩲ -zero(fT)
            @test sinpi(convert(T,-2.0))::fT ⩲ -zero(fT)
            @test_throws DomainError sinpi(convert(T,Inf))

            @test cospi(convert(T,0.5))::fT ⩲ zero(fT)
            @test cospi(convert(T,1.5))::fT ⩲ zero(fT)
            @test cospi(convert(T,-0.5))::fT ⩲ zero(fT)
            @test cospi(convert(T,-1.5))::fT ⩲ zero(fT)
            @test_throws DomainError cospi(convert(T,Inf))
        end
        @testset "trig pi functions accuracy" for numerator in -20:1:20
            for func in (sinpi, cospi, tanpi,
                         x -> sincospi(x)[1],
                         x -> sincospi(x)[2])
                x = numerator // 20
                # Check that rational function works
                @test func(x) ≈ func(BigFloat(x))
                # Use short value so that wider values will be exactly equal
                shortx = Float16(x)
                # Compare to BigFloat value
                bigvalue = func(BigFloat(shortx))
                for T in (Float16,Float32,Float64)
                    @test func(T(shortx)) ≈ T(bigvalue)
                end
            end
        end
        @testset begin
            # If the machine supports fma (fused multiply add), we require exact equality.
            # Otherwise, we only require approximate equality.
            if has_fma[T]
                my_eq = (==)
                @debug "On this machine, FMA is supported for $(T), so we will test for exact equality" my_eq
            else
                my_eq = isapprox
                @debug "On this machine, FMA is not supported for $(T), so we will test for approximate equality" my_eq
            end
            @testset let context=(T, has_fma[T], my_eq)
                @test sind(convert(T,30)) == 0.5
                @test cosd(convert(T,60)) == 0.5
                @test sind(convert(T,150)) == 0.5
                @test my_eq(sinpi(one(T)/convert(T,6)), 0.5)
                @test my_eq(sincospi(one(T)/convert(T,6))[1], 0.5)
                @test_throws DomainError sind(convert(T,Inf))
                @test_throws DomainError cosd(convert(T,Inf))
                fT == Float64 && @test my_eq(cospi(one(T)/convert(T,3)), 0.5)
                fT == Float64 && @test my_eq(sincospi(one(T)/convert(T,3))[2], 0.5)
                T == Rational{Int} && @test my_eq(sinpi(5//6), 0.5)
                T == Rational{Int} && @test my_eq(sincospi(5//6)[1], 0.5)
            end
        end
    end
    scdm = sincosd(missing)
    @test ismissing(scdm[1])
    @test ismissing(scdm[2])
end

@testset "Integer and Inf args for sinpi/cospi/tanpi/sinc/cosc" begin
    for (sinpi, cospi) in ((sinpi, cospi), (x->sincospi(x)[1], x->sincospi(x)[2]))
        @test sinpi(1) === 0.0
        @test sinpi(-1) === -0.0
        @test cospi(1) == -1
        @test cospi(2) == 1
    end

    @test tanpi(1) === -0.0
    @test tanpi(-1) === 0.0
    @test tanpi(2) === 0.0
    @test tanpi(-2) === -0.0
    @test sinc(1) == 0
    @test sinc(complex(1,0)) == 0
    @test sinc(0) == 1
    @test sinc(Inf) == 0
    @test cosc(1) == -1
    @test cosc(0) == 0
    @test cosc(complex(1,0)) == -1
    @test cosc(Inf) == 0

    @test sinc(Inf + 3im) == 0
    @test cosc(Inf + 3im) == 0

    @test isequal(sinc(Inf + Inf*im), NaN + NaN*im)
    @test isequal(cosc(Inf + Inf*im), NaN + NaN*im)
end

# issue #37227
@testset "sinc/cosc accuracy" begin
    setprecision(256) do
        for R in (BigFloat, Float16, Float32, Float64)
            for T in (R, Complex{R})
                for x in (0, 1e-5, 1e-20, 1e-30, 1e-40, 1e-50, 1e-60, 1e-70, 5.07138898934e-313)
                    if x < eps(R)
                        @test sinc(T(x)) == 1
                    end
                    @test cosc(T(x)) ≈ pi*(-R(x)*pi)/3 rtol=max(eps(R)*100, (pi*R(x))^2)
                end
            end
        end
    end
    @test @inferred(sinc(0//1)) ⩲ 1.0
    @test @inferred(cosc(0//1)) ⩲ -0.0

    # test right before/after thresholds of Taylor series
    @test sinc(0.001) ≈ 0.999998355066745 rtol=1e-15
    @test sinc(0.00099) ≈ 0.9999983878009009 rtol=1e-15
    @test sinc(0.05f0) ≈ 0.9958927352435614 rtol=1e-7
    @test sinc(0.0499f0) ≈ 0.9959091277049384 rtol=1e-7
    if has_fma[Float64]
        @test cosc(0.14) ≈ -0.4517331883801308 rtol=1e-15
    else
        @test cosc(0.14) ≈ -0.4517331883801308 rtol=1e-14
    end
    @test cosc(0.1399) ≈ -0.45142306168781854 rtol=1e-14
    @test cosc(0.26f0) ≈ -0.7996401373462212 rtol=5e-7
    @test cosc(0.2599f0) ≈ -0.7993744054401625 rtol=5e-7
    setprecision(256) do
        @test cosc(big"0.5") ≈ big"-1.273239544735162686151070106980114896275677165923651589981338752471174381073817" rtol=1e-76
        @test cosc(big"0.499") ≈ big"-1.272045747741181369948389133250213864178198918667041860771078493955590574971317" rtol=1e-76
    end
end

@testset "Irrational args to sinpi/cospi/tanpi/sinc/cosc" begin
    for x in (pi, ℯ, Base.MathConstants.golden)
        for (sinpi, cospi) in ((sinpi, cospi), (x->sincospi(x)[1], x->sincospi(x)[2]))
            @test sinpi(x) ≈ Float64(sinpi(big(x)))
            @test cospi(x) ≈ Float64(cospi(big(x)))
            @test sinpi(complex(x, x)) ≈ ComplexF64(sinpi(complex(big(x), big(x))))
            @test cospi(complex(x, x)) ≈ ComplexF64(cospi(complex(big(x), big(x))))
        end
        @test tanpi(x) ≈ Float64(tanpi(big(x)))
        @test sinc(x)  ≈ Float64(sinc(big(x)))
        @test cosc(x)  ≈ Float64(cosc(big(x)))
        @test sinc(complex(x, x))  ≈ ComplexF64(sinc(complex(big(x),  big(x))))
        @test cosc(complex(x, x))  ≈ ComplexF64(cosc(complex(big(x),  big(x))))
    end
end

@testset "half-integer and nan/infs for sincospi,sinpi,cospi" begin
    @testset for T in (ComplexF32, ComplexF64)
        @test sincospi(T(0.5, 0.0)) == (T(1.0,0.0), T(0.0, -0.0))
        @test sincospi(T(1.5, 0.0)) == (T(-1.0,0.0), T(0.0, 0.0))
        @test sinpi(T(1.5, 1.5)) ≈ T(-cosh(3*π/2), 0.0)
        @test cospi(T(0.5, 0.5)) ≈ T(0.0, -sinh(π/2))
        s, c = sincospi(T(Inf64, 0.0))
        @test isnan(real(s)) && imag(s) == zero(real(T))
        @test isnan(real(c)) && imag(c) == -zero(real(T))
        s, c = sincospi(T(NaN, 0.0))
        @test isnan(real(s)) && imag(s) == zero(real(T))
        @test isnan(real(c)) && imag(c) == zero(real(T))
        s, c = sincospi(T(NaN, Inf64))
        @test isnan(real(s)) && isinf(imag(s))
        @test isinf(real(c)) && isnan(imag(c))
        s, c = sincospi(T(NaN, 2))
        @test isnan(real(s)) && isnan(imag(s))
        @test isnan(real(c)) && isnan(imag(c))
    end
end

@testset "trig function type stability" begin
    @testset "$T $f" for T = (Float32,Float64,BigFloat,Rational{Int16},Complex{Int32},ComplexF16), f = (sind,cosd,sinpi,cospi,tanpi)
        @test Base.return_types(f,Tuple{T}) == [float(T)]
    end
    @testset "$T sincospi" for T = (Float32,Float64,BigFloat,Rational{Int16},Complex{Int32},ComplexF16)
        @test Base.return_types(sincospi,Tuple{T}) == [Tuple{float(T),float(T)}]
    end
end

# useful test functions for relative error, which differ from isapprox (≈)
# in that relerrc separately looks at the real and imaginary parts
relerr(z, x) = z == x ? 0.0 : abs(z - x) / abs(x)
relerrc(z, x) = max(relerr(real(z),real(x)), relerr(imag(z),imag(x)))
≅(a,b) = relerrc(a,b) ≤ 1e-13

@testset "subnormal flags" begin
    # Ensure subnormal flags functions don't segfault
    @test any(set_zero_subnormals(true) .== [false,true])
    @test any(get_zero_subnormals() .== [false,true])
    @test set_zero_subnormals(false)
    @test !get_zero_subnormals()
end

@testset "evalpoly" begin
    @test @evalpoly(2,3,4,5,6) == 3+2*(4+2*(5+2*6)) == @evalpoly(2+0im,3,4,5,6)
    a0 = 1
    a1 = 2
    c = 3
    @test @evalpoly(c, a0, a1) == 7
    @test @evalpoly(1, 2) == 2
end

@testset "evalpoly real" begin
    for x in -1.0:2.0, p1 in -3.0:3.0, p2 in -3.0:3.0, p3 in -3.0:3.0
        evpm = @evalpoly(x, p1, p2, p3)
        @test evalpoly(x, (p1, p2, p3)) == evpm
        @test evalpoly(x, [p1, p2, p3]) == evpm
    end
end

@testset "evalpoly complex" begin
    for x in -1.0:2.0, y in -1.0:2.0, p1 in -3.0:3.0, p2 in -3.0:3.0, p3 in -3.0:3.0
        z = x + im * y
        evpm = @evalpoly(z, p1, p2, p3)
        @test evalpoly(z, (p1, p2, p3)) == evpm
        @test evalpoly(z, [p1, p2, p3]) == evpm
    end
    @test evalpoly(1+im, (2,)) == 2
    @test evalpoly(1+im, [2,]) == 2
end

@testset "cis" begin
    for z in (1.234, 1.234 + 5.678im)
        @test cis(z) ≈ exp(im*z)
    end
    let z = [1.234, 5.678]
        @test cis.(z) ≈ exp.(im*z)
    end
end

@testset "modf" begin
    @testset "$T" for T in (Float16, Float32, Float64)
        @test modf(T(1.25)) === (T(0.25), T(1.0))
        @test modf(T(1.0))  === (T(0.0), T(1.0))
        @test modf(T(-Inf)) === (T(-0.0), T(-Inf))
        @test modf(T(Inf))  === (T(0.0), T(Inf))
        @test modf(T(NaN))  === (T(NaN), T(NaN))
        @test modf(T(-0.0)) === (T(-0.0), T(-0.0))
        @test modf(T(-1.0)) === (T(-0.0), T(-1.0))
    end
end

@testset "frexp" begin
    @testset "$elty" for elty in (Float16, Float32, Float64)
        @test frexp( convert(elty,0.5) ) == (0.5, 0)
        @test frexp( convert(elty,4.0) ) == (0.5, 3)
        @test frexp( convert(elty,10.5) ) == (0.65625, 4)
    end
end

@testset "log/log1p" begin
    # using Tang's algorithm, should be accurate to within 0.56 ulps
    X = rand(100)
    for x in X
        for n = -5:5
            xn = ldexp(x,n)

            for T in (Float32,Float64)
                xt = T(x)

                y = log(xt)
                yb = log(big(xt))
                @test abs(y-yb) <= 0.56*eps(T(yb))

                y = log1p(xt)
                yb = log1p(big(xt))
                @test abs(y-yb) <= 0.56*eps(T(yb))

                if n <= 0
                    y = log1p(-xt)
                    yb = log1p(big(-xt))
                    @test abs(y-yb) <= 0.56*eps(T(yb))
                end
            end
        end
    end

    for n = 0:28
        @test log(2,2^n) == n
    end
    setprecision(10_000) do
        @test log(2,big(2)^100) == 100
        @test log(2,big(2)^200) == 200
        @test log(2,big(2)^300) == 300
        @test log(2,big(2)^400) == 400
    end

    for T in (Float32,Float64)
        @test log(zero(T)) == -Inf
        @test isnan_type(T, log(T(NaN)))
        @test_throws DomainError log(-one(T))
        @test log1p(-one(T)) == -Inf
        @test isnan_type(T, log1p(T(NaN)))
        @test_throws DomainError log1p(-2*one(T))
    end
    @testset "log of subnormals" begin
        # checked results with WolframAlpha
        for (T, lr) in ((Float32, LinRange(2.f0^(-129), 2.f0^(-128), 1000)),
                        (Float64, LinRange(2.0^(-1025), 2.0^(-1024), 1000)))
            for x in lr
                @test log(x)   ≈ T(log(widen(x))) rtol=2eps(T)
                @test log2(x)  ≈ T(log2(widen(x))) rtol=2eps(T)
                @test log10(x) ≈ T(log10(widen(x))) rtol=2eps(T)
            end
        end
    end
end

@testset "vectorization of 2-arg functions" begin
    binary_math_functions = [
        copysign, flipsign, log, atan, hypot, max, min,
    ]
    @testset "$f" for f in binary_math_functions
        x = y = 2
        v = [f(x,y)]
        @test f.([x],y) == v
        @test f.(x,[y]) == v
        @test f.([x],[y]) == v
    end
end

@testset "issues #3024, #12822, #24240" begin
    p2 = -2
    p3 = -3
    @test_throws DomainError 2 ^ p2
    @test 2 ^ -2 == 0.25 == (2^-1)^2
    @test_throws DomainError (-2)^(2.2)
    @test_throws DomainError (-2.0)^(2.2)
    @test_throws DomainError false ^ p2
    @test false ^ -2 == Inf
    @test 1 ^ -2 === (-1) ^ -2 == 1 ^ p2 === (-1) ^ p2 === 1
    @test (-1) ^ -1 === (-1) ^ -3 == (-1) ^ p3 === -1
    @test true ^ -2 == true ^ p2 === true
end

@testset "issue #13748" begin
    let A = [1 2; 3 4]; B = [5 6; 7 8]; C = [9 10; 11 12]
        @test muladd(A,B,C) == A*B + C
    end
end

@testset "issue #19872" begin
    f19872a(x) = x ^ 5
    f19872b(x) = x ^ (-1024)
    @test 0 < f19872b(2.0) < 1e-300
    @test issubnormal(2.0 ^ (-1024))
    @test issubnormal(f19872b(2.0))
    @test !issubnormal(f19872b(0.0))
    @test f19872a(2.0) === 32.0
    @test !issubnormal(f19872a(2.0))
    @test !issubnormal(0.0)
end

# no domain error is thrown for negative values
@test invoke(cbrt, Tuple{AbstractFloat}, -1.0) == -1.0

@testset "promote Float16 irrational #15359" begin
    @test typeof(Float16(.5) * pi) == Float16
end

@testset "sincos" begin
    @test sincos(1.0) === (sin(1.0), cos(1.0))
    @test sincos(1f0) === (sin(1f0), cos(1f0))
    @test sincos(Float16(1)) === (sin(Float16(1)), cos(Float16(1)))
    @test sincos(1) === (sin(1), cos(1))
    @test sincos(big(1)) == (sin(big(1)), cos(big(1)))
    @test sincos(big(1.0)) == (sin(big(1.0)), cos(big(1.0)))
    @test sincos(NaN) === (NaN, NaN)
    @test sincos(NaN32) === (NaN32, NaN32)
    @test_throws DomainError sincos(Inf32)
    @test_throws DomainError sincos(Inf64)
end

@testset "test fallback definitions" begin
    @test exp10(5) ≈ exp10(5.0)
    @test exp10(50//10) ≈ exp10(5.0)
    @test log10(exp10(ℯ)) ≈ ℯ
    @test log(ℯ) === 1
    @test exp2(Float16(2.0)) ≈ exp2(2.0)
    @test exp2(Float16(1.0)) === Float16(exp2(1.0))
    @test exp10(Float16(1.0)) === Float16(exp10(1.0))
end

@testset "isapprox" begin
    # #22742: updated isapprox semantics
    @test !isapprox(1.0, 1.0+1e-12, atol=1e-14)
    @test isapprox(1.0, 1.0+0.5*sqrt(eps(1.0)))
    @test !isapprox(1.0, 1.0+1.5*sqrt(eps(1.0)), atol=sqrt(eps(1.0)))

    # #13132: Use of `norm` kwarg for scalar arguments
    @test isapprox(1, 1+1.0e-12, norm=abs)
    @test !isapprox(1, 1+1.0e-12, norm=x->1)
end

# test AbstractFloat fallback pr22716
struct Float22716{T<:AbstractFloat} <: AbstractFloat
    x::T
end
Base.:^(x::Number, y::Float22716) = x^(y.x)
let x = 2.0
    @test exp2(Float22716(x)) === 2^x
    @test exp10(Float22716(x)) === 10^x
end

@testset "asin #23088" begin
    for T in (Float32, Float64)
        @test asin(zero(T)) === zero(T)
        @test asin(-zero(T)) === -zero(T)
        @test asin(nextfloat(zero(T))) === nextfloat(zero(T))
        @test asin(prevfloat(zero(T))) === prevfloat(zero(T))
        @test asin(one(T)) === T(pi)/2
        @test asin(-one(T)) === -T(pi)/2
        for x in (0.45, 0.6, 0.98)
            by = asin(big(T(x)))
            @test T(abs(asin(T(x)) - by))/eps(T(abs(by))) <= 1
            bym = asin(big(T(-x)))
            @test T(abs(asin(T(-x)) - bym))/eps(T(abs(bym))) <= 1
        end
        @test_throws DomainError asin(-T(Inf))
        @test_throws DomainError asin(T(Inf))
        @test isnan_type(T, asin(T(NaN)))
    end
end

@testset "sin, cos, sincos, tan #23088" begin
    for T in (Float32, Float64)
        @test sin(zero(T)) === zero(T)
        @test sin(-zero(T)) === -zero(T)
        @test cos(zero(T)) === T(1.0)
        @test cos(-zero(T)) === T(1.0)
        @test sin(nextfloat(zero(T))) === nextfloat(zero(T))
        @test sin(prevfloat(zero(T))) === prevfloat(zero(T))
        @test cos(nextfloat(zero(T))) === T(1.0)
        @test cos(prevfloat(zero(T))) === T(1.0)
        for x in (0.1, 0.45, 0.6, 0.75, 0.79, 0.98)
            for op in (sin, cos, tan)
                by = T(op(big(x)))
                @test abs(op(T(x)) - by)/eps(by) <= one(T)
                bym = T(op(big(-x)))
                @test abs(op(T(-x)) - bym)/eps(bym) <= one(T)
            end
        end
        @test_throws DomainError sin(-T(Inf))
        @test_throws DomainError sin(T(Inf))
        @test_throws DomainError cos(-T(Inf))
        @test_throws DomainError cos(T(Inf))
        @test_throws DomainError tan(-T(Inf))
        @test_throws DomainError tan(T(Inf))
        @test sin(T(NaN)) === T(NaN)
        @test cos(T(NaN)) === T(NaN)
        @test tan(T(NaN)) === T(NaN)
    end
end

@testset "rem_pio2 #23088" begin
    vals = (2.356194490192345f0, 3.9269908169872414f0, 7.0685834705770345f0,
              5.497787143782138f0, 4.216574282663131f8, 4.216574282663131f12)
    for (i, x) in enumerate(vals)
        for op in (prevfloat, nextfloat)
            Ty = Float32(Base.Math.rem_pio2_kernel(op(vals[i]))[2].hi)
            By = Float32(rem(big(op(x)), pi/2))
            @test Ty ≈ By || Ty ≈ By-Float32(pi)/2
        end
    end
end

@testset "atan #23383" begin
    for T in (Float32, Float64)
        @test atan(T(NaN)) === T(NaN)
        @test atan(-T(Inf)) === -T(pi)/2
        @test atan(T(Inf)) === T(pi)/2
        # no reduction needed |x| < 7/16
        @test atan(zero(T)) === zero(T)
        @test atan(prevfloat(zero(T))) === prevfloat(zero(T))
        @test atan(nextfloat(zero(T))) === nextfloat(zero(T))
        for x in (T(7/16), (T(7/16)+T(11/16))/2, T(11/16),
                  (T(11/16)+T(19/16))/2, T(19/16),
                  (T(19/16)+T(39/16))/2, T(39/16),
                  (T(39/16)+T(2)^23)/2, T(2)^23)
            x = T(7/16)
            by = T(atan(big(x)))
            @test abs(atan(x) - by)/eps(by) <= one(T)
            x = prevfloat(T(7/16))
            by = T(atan(big(x)))
            @test abs(atan(x) - by)/eps(by) <= one(T)
            x = nextfloat(T(7/16))
            by = T(atan(big(x)))
            @test abs(atan(x) - by)/eps(by) <= one(T)
        end
        # This case was used to find a bug, but it isn't special in itself
        @test atan(1.7581305072934137) ≈ 1.053644580517088
    end
end
@testset "atan" begin
    for T in (Float32, Float64)
        @test isnan_type(T, atan(T(NaN), T(NaN)))
        @test isnan_type(T, atan(T(NaN), T(0.1)))
        @test isnan_type(T, atan(T(0.1), T(NaN)))
        r = T(randn())
        absr = abs(r)
        # y zero
        @test atan(T(r), one(T)) === atan(T(r))
        @test atan(zero(T), absr) === zero(T)
        @test atan(-zero(T), absr) === -zero(T)
        @test atan(zero(T), -absr) === T(pi)
        @test atan(-zero(T), -absr) === -T(pi)
        # x zero and y not zero
        @test atan(one(T), zero(T)) === T(pi)/2
        @test atan(-one(T), zero(T)) === -T(pi)/2
        # isinf(x) == true && isinf(y) == true
        @test atan(T(Inf), T(Inf)) === T(pi)/4 # m == 0 (see atan code)
        @test atan(-T(Inf), T(Inf)) === -T(pi)/4 # m == 1
        @test atan(T(Inf), -T(Inf)) === 3*T(pi)/4 # m == 2
        @test atan(-T(Inf), -T(Inf)) === -3*T(pi)/4 # m == 3
        # isinf(x) == true && isinf(y) == false
        @test atan(absr, T(Inf)) === zero(T) # m == 0
        @test atan(-absr, T(Inf)) === -zero(T) # m == 1
        @test atan(absr, -T(Inf)) === T(pi) # m == 2
        @test atan(-absr, -T(Inf)) === -T(pi) # m == 3
        # isinf(y) == true && isinf(x) == false
        @test atan(T(Inf), absr) === T(pi)/2
        @test atan(-T(Inf), absr) === -T(pi)/2
        @test atan(T(Inf), -absr) === T(pi)/2
        @test atan(-T(Inf), -absr) === -T(pi)/2
        # |y/x| above high threshold
        atanpi = T(1.5707963267948966)
        @test atan(T(2.0^61), T(1.0)) === atanpi # m==0
        @test atan(-T(2.0^61), T(1.0)) === -atanpi # m==1
        @test atan(T(2.0^61), -T(1.0)) === atanpi # m==2
        @test atan(-T(2.0^61), -T(1.0)) === -atanpi # m==3
        @test atan(-T(Inf), -absr) === -T(pi)/2
        # |y|/x between 0 and low threshold
        @test atan(T(2.0^-61), -T(1.0)) === T(pi) # m==2
        @test atan(-T(2.0^-61), -T(1.0)) === -T(pi) # m==3
        # y/x is "safe" ("arbitrary values", just need to hit the branch)
        _ATAN_PI_LO(::Type{Float32}) = -8.7422776573f-08
        _ATAN_PI_LO(::Type{Float64}) = 1.2246467991473531772E-16
        @test atan(T(5.0), T(2.5)) === atan(abs(T(5.0)/T(2.5)))
        @test atan(-T(5.0), T(2.5)) === -atan(abs(-T(5.0)/T(2.5)))
        @test atan(T(5.0), -T(2.5)) === T(pi)-(atan(abs(T(5.0)/-T(2.5)))-_ATAN_PI_LO(T))
        @test atan(-T(5.0), -T(2.5)) === -(T(pi)-atan(abs(-T(5.0)/-T(2.5)))-_ATAN_PI_LO(T))
        @test atan(T(1235.2341234), T(2.5)) === atan(abs(T(1235.2341234)/T(2.5)))
        @test atan(-T(1235.2341234), T(2.5)) === -atan(abs(-T(1235.2341234)/T(2.5)))
        @test atan(T(1235.2341234), -T(2.5)) === T(pi)-(atan(abs(T(1235.2341234)/-T(2.5)))-_ATAN_PI_LO(T))
        @test atan(-T(1235.2341234), -T(2.5)) === -(T(pi)-(atan(abs(-T(1235.2341234)/T(2.5)))-_ATAN_PI_LO(T)))
    end
end

@testset "atand" begin
    for T in (Float32, Float64)
        r = T(randn())
        absr = abs(r)

        # Tests related to the 1-argument version of `atan`.
        # ==================================================

        @test atand(T(Inf))  === T(90.0)
        @test atand(-T(Inf)) === -T(90.0)
        @test atand(zero(T)) === T(0.0)
        @test atand(one(T))  === T(45.0)
        @test atand(-one(T)) === -T(45.0)

        # Tests related to the 2-argument version of `atan`.
        # ==================================================

        # If `x` is one, then `atand(y,x)` must be equal to `atand(y)`.
        @test atand(T(r), one(T))    === atand(T(r))

        # `y` zero.
        @test atand(zero(T), absr)   === zero(T)
        @test atand(-zero(T), absr)  === -zero(T)
        @test atand(zero(T), -absr)  === T(180.0)
        @test atand(-zero(T), -absr) === -T(180.0)

        # `x` zero and `y` not zero.
        @test atand(one(T), zero(T))  === T(90.0)
        @test atand(-one(T), zero(T)) === -T(90.0)

        # `x` and `y` equal for each quadrant.
        @test atand(+absr, +absr) === T(45.0)
        @test atand(-absr, +absr) === -T(45.0)
        @test atand(+absr, -absr) === T(135.0)
        @test atand(-absr, -absr) === -T(135.0)
    end
end

@testset "acos #23283" begin
    for T in (Float32, Float64)
        @test acos(zero(T)) === T(pi)/2
        @test acos(-zero(T)) === T(pi)/2
        @test acos(nextfloat(zero(T))) === T(pi)/2
        @test acos(prevfloat(zero(T))) === T(pi)/2
        @test acos(one(T)) === T(0.0)
        @test acos(-one(T)) === T(pi)
        for x in (0.45, 0.6, 0.98)
            by = acos(big(T(x)))
            @test T((acos(T(x)) - by))/eps(abs(T(by))) <= 1
            bym = acos(big(T(-x)))
            @test T(abs(acos(T(-x)) - bym))/eps(abs(T(bym))) <= 1
        end
        @test_throws DomainError acos(-T(Inf))
        @test_throws DomainError acos(T(Inf))
        @test isnan_type(T, acos(T(NaN)))
    end
end

#prev, current, next float
pcnfloat(x) = prevfloat(x), x, nextfloat(x)
import Base.Math: COSH_SMALL_X, H_SMALL_X, H_MEDIUM_X, H_LARGE_X

@testset "sinh" begin
    for T in (Float16, Float32, Float64)
        @test sinh(zero(T)) === zero(T)
        @test sinh(-zero(T)) === -zero(T)
        @test sinh(nextfloat(zero(T))) === nextfloat(zero(T))
        @test sinh(prevfloat(zero(T))) === prevfloat(zero(T))
        @test sinh(T(1000)) === T(Inf)
        @test sinh(-T(1000)) === -T(Inf)
        @test isnan_type(T, sinh(T(NaN)))
        if T ∈ (Float32, Float64)
            for x in Iterators.flatten(pcnfloat.([H_SMALL_X(T), H_MEDIUM_X(T), H_LARGE_X(T)]))
                @test sinh(x) ≈ sinh(big(x)) rtol=eps(T)
                @test sinh(-x) ≈ sinh(big(-x)) rtol=eps(T)
            end
        end
    end
end

@testset "cosh" begin
    for T in (Float16, Float32, Float64)
        @test cosh(zero(T)) === one(T)
        @test cosh(-zero(T)) === one(T)
        @test cosh(nextfloat(zero(T))) === one(T)
        @test cosh(prevfloat(zero(T))) === one(T)
        @test cosh(T(1000)) === T(Inf)
        @test cosh(-T(1000)) === T(Inf)
        @test isnan_type(T, cosh(T(NaN)))
        if T ∈ (Float32, Float64)
            for x in Iterators.flatten(pcnfloat.([COSH_SMALL_X(T), H_MEDIUM_X(T), H_LARGE_X(T)]))
                @test cosh(x) ≈ cosh(big(x)) rtol=eps(T)
                @test cosh(-x) ≈ cosh(big(-x)) rtol=eps(T)
            end
        end
    end
end

@testset "tanh" begin
    for T in (Float16, Float32, Float64)
        @test tanh(zero(T)) === zero(T)
        @test tanh(-zero(T)) === -zero(T)
        @test tanh(nextfloat(zero(T))) === nextfloat(zero(T))
        @test tanh(prevfloat(zero(T))) === prevfloat(zero(T))
        @test tanh(T(1000)) === one(T)
        @test tanh(-T(1000)) === -one(T)
        @test isnan_type(T, tanh(T(NaN)))
        if T ∈ (Float32, Float64)
            for x in Iterators.flatten(pcnfloat.([H_SMALL_X(T), T(1.0), H_MEDIUM_X(T)]))
                @test tanh(x) ≈ tanh(big(x)) rtol=eps(T)
                @test tanh(-x) ≈ -tanh(big(x)) rtol=eps(T)
            end
        end
    end
    @test tanh(18.0) ≈ tanh(big(18.0)) rtol=eps(Float64)
    @test tanh(8.0) ≈ tanh(big(8.0)) rtol=eps(Float32)
end

@testset "asinh" begin
    for T in (Float16, Float32, Float64)
        @test asinh(zero(T)) === zero(T)
        @test asinh(-zero(T)) === -zero(T)
        @test asinh(nextfloat(zero(T))) === nextfloat(zero(T))
        @test asinh(prevfloat(zero(T))) === prevfloat(zero(T))
        @test isnan_type(T, asinh(T(NaN)))
        for x in Iterators.flatten(pcnfloat.([T(2)^-28,T(2),T(2)^28]))
            @test asinh(x) ≈ asinh(big(x)) rtol=eps(T)
            @test asinh(-x) ≈ asinh(big(-x)) rtol=eps(T)
        end
    end
end

@testset "acosh" begin
    for T in (Float16, Float32, Float64)
        @test_throws DomainError acosh(T(0.1))
        @test acosh(one(T)) === zero(T)
        @test isnan_type(T, acosh(T(NaN)))
        for x in Iterators.flatten(pcnfloat.([nextfloat(T(1.0)), T(2), T(2)^28]))
            @test acosh(x) ≈ acosh(big(x)) rtol=eps(T)
        end
    end
end

@testset "atanh" begin
    for T in (Float16, Float32, Float64)
        @test_throws DomainError atanh(T(1.1))
        @test atanh(zero(T)) === zero(T)
        @test atanh(-zero(T)) === -zero(T)
        @test atanh(one(T)) === T(Inf)
        @test atanh(-one(T)) === -T(Inf)
        @test atanh(nextfloat(zero(T))) === nextfloat(zero(T))
        @test atanh(prevfloat(zero(T))) === prevfloat(zero(T))
        @test isnan_type(T, atanh(T(NaN)))
        for x in Iterators.flatten(pcnfloat.([T(2.0)^-28, T(0.5)]))
            @test atanh(x) ≈ atanh(big(x)) rtol=eps(T)
            @test atanh(-x) ≈ atanh(big(-x)) rtol=eps(T)
        end
    end
end

# Define simple wrapper of a Float type:
struct FloatWrapper <: Real
    x::Float64
end

import Base: +, -, *, /, ^, sin, cos, exp, sinh, cosh, convert, isfinite, float, promote_rule

for op in (:+, :-, :*, :/, :^)
    @eval $op(x::FloatWrapper, y::FloatWrapper) = FloatWrapper($op(x.x, y.x))
end

for op in (:sin, :cos, :exp, :sinh, :cosh, :-)
    @eval $op(x::FloatWrapper) = FloatWrapper($op(x.x))
end

for op in (:isfinite,)
    @eval $op(x::FloatWrapper) = $op(x.x)
end

convert(::Type{FloatWrapper}, x::Int) = FloatWrapper(float(x))
promote_rule(::Type{FloatWrapper}, ::Type{Int}) = FloatWrapper

float(x::FloatWrapper) = x

@testset "exp(Complex(a, b)) for a and b of non-standard real type #25292" begin

    x = FloatWrapper(3.1)
    y = FloatWrapper(4.1)

    @test sincos(x) == (sin(x), cos(x))

    z = Complex(x, y)

    @test isa(exp(z), Complex)
    @test isa(sin(z), Complex)
    @test isa(cos(z), Complex)
end

# Define simple wrapper of a Float type:
struct FloatWrapper2 <: Real
    x::Float64
end

float(x::FloatWrapper2) = x.x
@testset "inverse hyperbolic trig functions of non-standard float" begin
    x = FloatWrapper2(3.1)
    @test asinh(sinh(x)) == asinh(sinh(3.1))
    @test acosh(cosh(x)) == acosh(cosh(3.1))
    @test atanh(tanh(x)) == atanh(tanh(3.1))
end

@testset "cbrt" begin
    for T in (Float32, Float64)
        @test cbrt(zero(T)) === zero(T)
        @test cbrt(-zero(T)) === -zero(T)
        @test cbrt(one(T)) === one(T)
        @test cbrt(-one(T)) === -one(T)
        @test cbrt(T(Inf)) === T(Inf)
        @test cbrt(-T(Inf)) === -T(Inf)
        @test isnan_type(T, cbrt(T(NaN)))
        for x in (pcnfloat(nextfloat(nextfloat(zero(T))))...,
                  pcnfloat(prevfloat(prevfloat(zero(T))))...,
                  0.45, 0.6, 0.98,
                  map(x->x^3, 1.0:1.0:1024.0)...,
                  nextfloat(-T(Inf)), prevfloat(T(Inf)))
            by = cbrt(big(T(x)))
            @test cbrt(T(x)) ≈ by rtol=eps(T)
            bym = cbrt(big(T(-x)))
            @test cbrt(T(-x)) ≈ bym rtol=eps(T)
        end
    end
end

@testset "fourthroot" begin
    for T in (Float32, Float64)
        @test fourthroot(zero(T)) === zero(T)
        @test fourthroot(one(T)) === one(T)
        @test fourthroot(T(Inf)) === T(Inf)
        @test isnan_type(T, fourthroot(T(NaN)))
        for x in (pcnfloat(nextfloat(nextfloat(zero(T))))...,
                  0.45, 0.6, 0.98,
                  map(x->x^3, 1.0:1.0:1024.0)...,
                  prevfloat(T(Inf)))
            by = fourthroot(big(T(x)))
            @test fourthroot(T(x)) ≈ by rtol=eps(T)
        end
    end
end

@testset "hypot" begin
    @test hypot(0, 0) == 0.0
    @test hypot(3, 4) == 5.0
    @test hypot(NaN, Inf) == Inf
    @test hypot(Inf, NaN) == Inf
    @test hypot(Inf, Inf) == Inf

    isdefined(Main, :Furlongs) || @eval Main include("testhelpers/Furlongs.jl")
    using .Main.Furlongs
    @test (@inferred hypot(Furlong(0), Furlong(0))) == Furlong(0.0)
    @test (@inferred hypot(Furlong(3), Furlong(4))) == Furlong(5.0)
    @test (@inferred hypot(Furlong(NaN), Furlong(Inf))) == Furlong(Inf)
    @test (@inferred hypot(Furlong(Inf), Furlong(NaN))) == Furlong(Inf)
    @test (@inferred hypot(Furlong(0), Furlong(0), Furlong(0))) == Furlong(0.0)
    @test (@inferred hypot(Furlong(Inf), Furlong(Inf))) == Furlong(Inf)
    @test (@inferred hypot(Furlong(1), Furlong(1), Furlong(1))) == Furlong(sqrt(3))
    @test (@inferred hypot(Furlong(Inf), Furlong(NaN), Furlong(0))) == Furlong(Inf)
    @test (@inferred hypot(Furlong(Inf), Furlong(Inf), Furlong(Inf))) == Furlong(Inf)
    @test isnan(hypot(Furlong(NaN), Furlong(0), Furlong(1)))
    ex = @test_throws ErrorException hypot(Furlong(1), 1)
    @test startswith(ex.value.msg, "promotion of types ")

    @test_throws MethodError hypot()
    @test (@inferred hypot(floatmax())) == floatmax()
    @test (@inferred hypot(floatmax(), floatmax())) == Inf
    @test (@inferred hypot(floatmin(), floatmin())) == √2floatmin()
    @test (@inferred hypot(floatmin(), floatmin(), floatmin())) == √3floatmin()
    @test (@inferred hypot(1e-162)) ≈ 1e-162
    @test (@inferred hypot(2e-162, 1e-162, 1e-162)) ≈ hypot(2, 1, 1)*1e-162
    @test (@inferred hypot(1e162)) ≈ 1e162
    @test hypot(-2) === 2.0
    @test hypot(-2, 0) === 2.0
    let i = typemax(Int)
        @test (@inferred hypot(i, i)) ≈ i * √2
        @test (@inferred hypot(i, i, i)) ≈ i * √3
        @test (@inferred hypot(i, i, i, i)) ≈ 2.0i
        @test (@inferred hypot(i//1, 1//i, 1//i)) ≈ i
    end
    let i = typemin(Int)
        @test (@inferred hypot(i, i)) ≈ -√2i
        @test (@inferred hypot(i, i, i)) ≈ -√3i
        @test (@inferred hypot(i, i, i, i)) ≈ -2.0i
    end
    @testset "$T" for T in (Float32, Float64)
        @test (@inferred hypot(T(Inf), T(NaN))) == T(Inf) # IEEE754 says so
        @test (@inferred hypot(T(Inf), T(3//2), T(NaN))) == T(Inf)
        @test (@inferred hypot(T(1e10), T(1e10), T(1e10), T(1e10))) ≈ 2e10
        @test isnan_type(T, hypot(T(3), T(3//4), T(NaN)))
        @test hypot(T(1), T(0)) === T(1)
        @test hypot(T(1), T(0), T(0)) === T(1)
        @test (@inferred hypot(T(Inf), T(Inf), T(Inf))) == T(Inf)
        for s in (zero(T), floatmin(T)*1e3, floatmax(T)*1e-3, T(Inf))
            @test hypot(1s, 2s)     ≈ s * hypot(1, 2)   rtol=8eps(T)
            @test hypot(1s, 2s, 3s) ≈ s * hypot(1, 2, 3) rtol=8eps(T)
        end
    end
    @testset "$T" for T in (Float16, Float32, Float64, BigFloat)
        let x = 1.1sqrt(floatmin(T))
            @test (@inferred hypot(x, x/4)) ≈ x * sqrt(17/BigFloat(16))
            @test (@inferred hypot(x, x/4, x/4)) ≈ x * sqrt(9/BigFloat(8))
        end
        let x = 2sqrt(nextfloat(zero(T)))
            @test (@inferred hypot(x, x/4)) ≈ x * sqrt(17/BigFloat(16))
            @test (@inferred hypot(x, x/4, x/4)) ≈ x * sqrt(9/BigFloat(8))
        end
        let x = sqrt(nextfloat(zero(T))/eps(T))/8, f = sqrt(4eps(T))
            @test hypot(x, x*f) ≈ x * hypot(one(f), f) rtol=eps(T)
            @test hypot(x, x*f, x*f) ≈ x * hypot(one(f), f, f) rtol=eps(T)
        end
        let x = floatmax(T)/2
            @test (@inferred hypot(x, x/4)) ≈ x * sqrt(17/BigFloat(16))
            @test (@inferred hypot(x, x/4, x/4)) ≈ x * sqrt(9/BigFloat(8))
        end
    end
    # hypot on Complex returns Real
    @test (@inferred hypot(3, 4im)) === 5.0
    @test (@inferred hypot(3, 4im, 12)) === 13.0
    @testset "promotion, issue #53505" begin
        @testset "Int,$T" for T in (Float16, Float32, Float64, BigFloat)
            for args in ((3, 4), (3, 4, 12))
                for i in eachindex(args)
                    targs = ntuple(j -> (j == i) ? T(args[j]) : args[j], length(args))
                    @test (@inferred hypot(targs...)) isa float(eltype(promote(targs...)))
                end
            end
        end
    end
end

struct BadFloatWrapper <: AbstractFloat
    x::Float64
end

@testset "not implemented errors" begin
    x = BadFloatWrapper(1.9)
    for f in (sin, cos, tan, sinh, cosh, tanh, atan, acos, asin, asinh, acosh, atanh, exp, log1p, expm1, log) #exp2, exp10 broken for now
        @test_throws MethodError f(x)
    end
end

@testset "fma" begin
    fma_list = (fma, Base.fma_emulated)
    if !(Sys.islinux() && Int == Int32) # test runtime fma (skip linux32)
        fma_list = (fma_list..., Base.fma_float)
    end
    for func in fma_list
        @test func(nextfloat(1.),nextfloat(1.),-1.0) === 4.440892098500626e-16
        @test func(nextfloat(1f0),nextfloat(1f0),-1f0) === 2.3841858f-7
        @testset "$T" for T in (Float32, Float64)
            @test func(floatmax(T), T(2), -floatmax(T)) === floatmax(T)
            @test func(floatmax(T), T(1), eps(floatmax((T)))) === T(Inf)
            @test func(T(Inf), T(Inf), T(Inf)) === T(Inf)
            @test func(floatmax(T), floatmax(T), -T(Inf)) === -T(Inf)
            @test func(floatmax(T), -floatmax(T), T(Inf)) === T(Inf)
            @test isnan_type(T, func(T(Inf), T(1), -T(Inf)))
            @test isnan_type(T, func(T(Inf), T(0), -T(0)))
            @test func(-zero(T), zero(T), -zero(T)) === -zero(T)
            for _ in 1:2^18
                a, b, c = reinterpret.(T, rand(Base.uinttype(T), 3))
                @test isequal(func(a, b, c), fma(a, b, c)) || (a,b,c)
            end
        end
        @test func(floatmax(Float64), nextfloat(1.0), -floatmax(Float64)) === 3.991680619069439e292
        @test func(floatmax(Float32), nextfloat(1f0), -floatmax(Float32)) === 4.0564817f31
        @test func(1.6341681540852291e308, -2., floatmax(Float64)) == -1.4706431733081426e308 # case where inv(a)*c*a == Inf
        @test func(-2., 1.6341681540852291e308, floatmax(Float64)) == -1.4706431733081426e308 # case where inv(b)*c*b == Inf
        @test func(-1.9369631f13, 2.1513551f-7, -1.7354427f-24) == -4.1670958f6
    end
end

@testset "pow" begin
    # tolerance by type for regular powers
    POW_TOLS = Dict(Float16=>[.51, .51, .51, 2.0, 1.5],
                    Float32=>[.51, .51, .51, 2.0, 1.5],
                    Float64=>[.55, 0.8, 1.5, 2.0, 1.5])
    for T in (Float16, Float32, Float64)
        @inferred T T(1.1)^T(1.1) #test that we always return the right type
        for x in (0.0, -0.0, 1.0, 10.0, 2.0, Inf, NaN, -Inf, -NaN)
            for y in (0.0, -0.0, 1.0, -3.0,-10.0 , Inf, NaN, -Inf, -NaN)
                got, expected = T(x)^T(y), T(big(x)^T(y))
                if isnan(expected)
                    @test isnan_type(T, got) || T.((x,y))
                else
                    @test got == expected || T.((x,y))
                end
            end
        end
        for _ in 1:2^16
            # note x won't be subnormal here
            x=rand(T)*100; y=rand(T)*200-100
            got, expected = x^y, widen(x)^y
            if isfinite(eps(T(expected)))
                if y == T(-2) # unfortunately x^-2 is less accurate for performance reasons.
                    @test abs(expected-got) <= POW_TOLS[T][4]*eps(T(expected)) || (x,y)
                elseif y == T(3) # unfortunately x^3 is less accurate for performance reasons.
                    @test abs(expected-got) <= POW_TOLS[T][5]*eps(T(expected)) || (x,y)
                elseif issubnormal(got)
                    @test abs(expected-got) <= POW_TOLS[T][2]*eps(T(expected)) || (x,y)
                else
                    @test abs(expected-got) <= POW_TOLS[T][1]*eps(T(expected)) || (x,y)
                end
            end
        end
        for _ in 1:2^14
            # test subnormal(x), y in -1.2, 1.8 since anything larger just overflows.
            x=rand(T)*floatmin(T); y=rand(T)*3-T(1.2)
            got, expected = x^y, widen(x)^y
            if isfinite(eps(T(expected)))
                @test abs(expected-got) <= POW_TOLS[T][3]*eps(T(expected)) || (x,y)
            end
        end
        # test (-x)^y for y larger than typemax(Int)
        @test T(-1)^floatmax(T) === T(1)
        @test prevfloat(T(-1))^floatmax(T) === T(Inf)
        @test nextfloat(T(-1))^floatmax(T) === T(0.0)
    end
    # test for large negative exponent where error compensation matters
    @test 0.9999999955206014^-1.0e8 == 1.565084574870928
    @test 3e18^20 == Inf
    # two cases where we have observed > 1 ULP in the past
    @test 0.0013653274095082324^-97.60372292227069 == 4.088393948750035e279
    @test 8.758520413376658e-5^70.55863059215994 == 5.052076767078296e-287

    # issue #53881
    c53881 = 2.2844135865398217e222 # check correctness within 2 ULPs
    @test prevfloat(1.0) ^ -Int64(2)^62 ≈ c53881 atol=2eps(c53881)
    @test 2.0 ^ typemin(Int) == 0.0
    @test (-1.0) ^ typemin(Int) == 1.0
    Z = Int64(2)
    E = prevfloat(1.0)
    @test E ^ (-Z^54) ≈ 7.38905609893065
    @test E ^ (-Z^62) ≈ 2.2844135865231613e222
    @test E ^ (-Z^63) == Inf
    @test abs(E ^ (Z^62-1) * E ^ (-Z^62+1) - 1) <= eps(1.0)
    n, x = -1065564664, 0.9999997040311492
    @test abs(x^n - Float64(big(x)^n)) / eps(x^n) == 0 # ULPs
    @test E ^ (big(2)^100 + 1) == 0
    @test E ^ 6705320061009595392 == nextfloat(0.0)
    n = Int64(1024 / log2(E))
    @test E^n == Inf
    @test E^float(n) == Inf

    # issue #55831
    @testset "literal pow zero sign" begin
        @testset "T: $T" for T ∈ (Float16, Float32, Float64, BigFloat)
            @testset "literal `-1`" begin
                @test -0.0 === Float64(T(-Inf)^-1)
            end
            @testset "`Int(-1)`" begin
                @test -0.0 === Float64(T(-Inf)^Int(-1))
            end
        end
    end

    # issue #55633
    struct Issue55633_1 <: Number end
    struct Issue55633_3 <: Number end
    struct Issue55633_9 <: Number end
    Base.one(::Issue55633_3) = Issue55633_1()
    Base.:(*)(::Issue55633_3, ::Issue55633_3) = Issue55633_9()
    Base.promote_rule(::Type{Issue55633_1}, ::Type{Issue55633_3}) = Int
    Base.promote_rule(::Type{Issue55633_3}, ::Type{Issue55633_9}) = Int
    Base.promote_rule(::Type{Issue55633_1}, ::Type{Issue55633_9}) = Int
    Base.promote_rule(::Type{Issue55633_1}, ::Type{Int}) = Int
    Base.promote_rule(::Type{Issue55633_3}, ::Type{Int}) = Int
    Base.promote_rule(::Type{Issue55633_9}, ::Type{Int}) = Int
    Base.convert(::Type{Int}, ::Issue55633_1) = 1
    Base.convert(::Type{Int}, ::Issue55633_3) = 3
    Base.convert(::Type{Int}, ::Issue55633_9) = 9
    for x ∈ (im, pi, Issue55633_3())
        p = promote(one(x), x, x*x)
        for y ∈ 0:2
            @test all((t -> ===(t...)), zip(x^y, p[y + 1]))
        end
    end

    @testset "rng exponentiation, issue #57590" begin
        @test EvenInteger(16) === @inferred EvenInteger(2)^4
        @test EvenInteger(16) === @inferred EvenInteger(2)^Int(4)  # avoid `literal_pow`
        @test EvenInteger(16) === @inferred EvenInteger(2)^EvenInteger(4)
    end

    # issue #57464
    @test Float32(1.1)^typemin(Int) == Float32(0.0)
    @test Float16(1.1)^typemin(Int) == Float16(0.0)
    @test Float32(1.1)^unsigned(0) === Float32(1.0)
    @test Float32(1.1)^big(0) === Float32(1.0)

    # By using a limited-precision integer (3 bits) we can trigger issue 57464
    # for a case where the answer isn't zero.
    struct Int3 <: Integer
        x::Int8
        function Int3(x::Integer)
            if x < -4 || x > 3
                Core.throw_inexacterror(:Int3, Int3, x)
            end
            return new(x)
        end
    end
    Base.typemin(::Type{Int3}) = Int3(-4)
    Base.promote_rule(::Type{Int3}, ::Type{T}) where {T<:Integer} = T
    Base.convert(::Type{T}, x::Int3) where {T<:Integer} = convert(T, x.x)
    Base.:-(x::Int3) = x.x == -4 ? x : Int3(-x.x)
    Base.trailing_zeros(x::Int3) = trailing_zeros(x.x)
    Base.:>>(x::Int3, n::UInt64) = Int3(x.x>>n)

    @test 1.001f0^-3 == 1.001f0^Int3(-3)
    @test 1.001f0^-4 == 1.001f0^typemin(Int3)
end

@testset "special function `::Real` fallback shouldn't recur without bound, issue #57789" begin
    mutable struct Issue57789 <: Real end
    Base.float(::Issue57789) = Issue57789()
    for f ∈ (sin, sinpi, log, exp)
        @test_throws MethodError f(Issue57789())
    end
end

# Test that sqrt behaves correctly and doesn't exhibit fp80 double rounding.
# This happened on old glibc versions.
# Test case from https://sourceware.org/bugzilla/show_bug.cgi?id=14032.
@testset "sqrt double rounding" begin
    testdata = [
        (0x1.fffffffffffffp+1023, 0x1.fffffffffffffp+511),
        (0x1.ffffffffffffbp+1023, 0x1.ffffffffffffdp+511),
        (0x1.ffffffffffff7p+1023, 0x1.ffffffffffffbp+511),
        (0x1.ffffffffffff3p+1023, 0x1.ffffffffffff9p+511),
        (0x1.fffffffffffefp+1023, 0x1.ffffffffffff7p+511),
        (0x1.fffffffffffebp+1023, 0x1.ffffffffffff5p+511),
        (0x1.fffffffffffe7p+1023, 0x1.ffffffffffff3p+511),
        (0x1.fffffffffffe3p+1023, 0x1.ffffffffffff1p+511),
        (0x1.fffffffffffdfp+1023, 0x1.fffffffffffefp+511),
        (0x1.fffffffffffdbp+1023, 0x1.fffffffffffedp+511),
        (0x1.fffffffffffd7p+1023, 0x1.fffffffffffebp+511),
        (0x1.0000000000003p-1022, 0x1.0000000000001p-511),
        (0x1.0000000000007p-1022, 0x1.0000000000003p-511),
        (0x1.000000000000bp-1022, 0x1.0000000000005p-511),
        (0x1.000000000000fp-1022, 0x1.0000000000007p-511),
        (0x1.0000000000013p-1022, 0x1.0000000000009p-511),
        (0x1.0000000000017p-1022, 0x1.000000000000bp-511),
        (0x1.000000000001bp-1022, 0x1.000000000000dp-511),
        (0x1.000000000001fp-1022, 0x1.000000000000fp-511),
        (0x1.0000000000023p-1022, 0x1.0000000000011p-511),
        (0x1.0000000000027p-1022, 0x1.0000000000013p-511),
        (0x1.000000000002bp-1022, 0x1.0000000000015p-511),
        (0x1.000000000002fp-1022, 0x1.0000000000017p-511),
        (0x1.0000000000033p-1022, 0x1.0000000000019p-511),
        (0x1.0000000000037p-1022, 0x1.000000000001bp-511),
        (0x1.7167bc36eaa3bp+6, 0x1.3384c7db650cdp+3),
        (0x1.7570994273ad7p+6, 0x1.353186e89b8ffp+3),
        (0x1.7dae969442fe6p+6, 0x1.389640fb18b75p+3),
        (0x1.7f8444fcf67e5p+6, 0x1.395659e94669fp+3),
        (0x1.8364650e63a54p+6, 0x1.3aea9efe1a3d7p+3),
        (0x1.85bedd274edd8p+6, 0x1.3bdf20c867057p+3),
        (0x1.8609cf496ab77p+6, 0x1.3bfd7e14b5eabp+3),
        (0x1.873849c70a375p+6, 0x1.3c77ed341d27fp+3),
        (0x1.8919c962cbaaep+6, 0x1.3d3a7113ee82fp+3),
        (0x1.8de4493e22dc6p+6, 0x1.3f27d448220c3p+3),
        (0x1.924829a17a288p+6, 0x1.40e9552eec28fp+3),
        (0x1.92702cd992f12p+6, 0x1.40f94a6fdfddfp+3),
        (0x1.92b763a8311fdp+6, 0x1.4115af614695fp+3),
        (0x1.947da013c7293p+6, 0x1.41ca91102940fp+3),
        (0x1.9536091c494d2p+6, 0x1.4213e334c77adp+3),
        (0x1.61b04c6p-1019, 0x1.a98b88f18b46dp-510),
        (0x1.93789f1p-1018, 0x1.4162ae43d5821p-509),
        (0x1.a1989b4p-1018, 0x1.46f6736eb44bbp-509),
        (0x1.f93bc9p-1018, 0x1.67a36ec403bafp-509),
        (0x1.2f675e3p-1017, 0x1.8a22ab6dcfee1p-509),
        (0x1.a158508p-1017, 0x1.ce418a96cf589p-509),
        (0x1.cd31f078p-1017, 0x1.e5ef1c65dccebp-509),
        (0x1.33b43b08p-1016, 0x1.18a9f607e1701p-508),
        (0x1.6e66a858p-1016, 0x1.324402a00b45fp-508),
        (0x1.8661cbf8p-1016, 0x1.3c212046bfdffp-508),
        (0x1.bbb221b4p-1016, 0x1.510681b939931p-508),
        (0x1.c4942f3cp-1016, 0x1.5461e59227ab5p-508),
        (0x1.dbb258c8p-1016, 0x1.5cf7b0f78d3afp-508),
        (0x1.57103ea4p-1015, 0x1.a31ab946d340bp-508),
        (0x1.9b294f88p-1015, 0x1.cad197e28e85bp-508),
        (0x1.0000000000001p+0, 0x1p+0),
        (0x1.fffffffffffffp-1, 0x1.fffffffffffffp-1),
    ]
    for (x,y) in testdata
        # Runtime version
        @test sqrt(x) === y
        # Interpreter compile-time version
        @test Base.invokelatest((@eval ()->sqrt(Base.inferencebarrier($x)))) == y
        # Inference const-prop version
        @test Base.invokelatest((@eval ()->sqrt($x))) == y
        # LLVM constant folding version
        @test Base.invokelatest((@eval ()->(@force_compile; sqrt(Base.inferencebarrier($x))))) == y
    end
end

# Test inference of x^0.0 (tested here because
# it requires annotations in the math code. If
# the compiler ever gets good enough to figure
# that out by itself, move this to inference).
@test code_typed(x->Val{x^0.0}(), Tuple{Float64})[1][2] == Val{1.0}

function f44336()
    as = ntuple(_ -> rand(), Val(32))
    @inline hypot(as...)
end
@testset "Issue #44336" begin
    let
        f44336()
        @test (@allocated f44336()) == 0
    end
end

@testset "constant-foldability of core math functions" begin
    for T = Any[Float16, Float32, Float64]
        @testset let T = T
            for f = Any[sin, cos, tan, log, log2, log10, log1p, exponent, sqrt, cbrt, fourthroot,
                        asin, atan, acos, sinh, cosh, tanh, asinh, acosh, atanh, exp, exp2, exp10, expm1]
                @testset let f = f,
                             rt = Base.infer_return_type(f, (T,)),
                             effects = Base.infer_effects(f, (T,))
                    @test rt != Union{}
                    @test Core.Compiler.is_foldable(effects)
                end
            end
            @testset let effects = Base.infer_effects(^, (T,Int))
                @test Core.Compiler.is_foldable(effects)
            end
            @testset let effects = Base.infer_effects(^, (T,T))
                @test Core.Compiler.is_foldable(effects)
            end
        end
    end
end;
@testset "removability of core math functions" begin
    for T = Any[Float16, Float32, Float64]
        @testset let T = T
            for f = Any[exp, exp2, exp10, expm1]
                @testset let f = f
                    @test Core.Compiler.is_removable_if_unused(Base.infer_effects(f, (T,)))
                end
            end
        end
    end
end;
@testset "exception type inference of core math functions" begin
    MathErrorT = Union{DomainError, InexactError}
    for T = (Float16, Float32, Float64)
        @testset let T = T
            for f = Any[sin, cos, tan, log, log2, log10, log1p, exponent, sqrt, cbrt, fourthroot,
                        asin, atan, acos, sinh, cosh, tanh, asinh, acosh, atanh, exp, exp2, exp10, expm1]
                @testset let f = f
                    @test Base.infer_exception_type(f, (T,)) <: MathErrorT
                end
            end
            @test Base.infer_exception_type(^, (T,Int)) <: MathErrorT
            @test Base.infer_exception_type(^, (T,T)) <: MathErrorT
        end
    end
end;
@test Base.infer_return_type((Int,)) do x
    local r = nothing
    try
        r = sin(x)
    catch err
        if err isa DomainError
            r = 0.0
        end
    end
    return r
end === Float64

@testset "BigInt Rationals with special funcs" begin
    @test sinpi(big(1//1)) == big(0.0)
    @test tanpi(big(1//1)) == big(0.0)
    @test cospi(big(1//1)) == big(-1.0)
end

@testset "Docstrings" begin
    @test isempty(Docs.undocumented_names(MathConstants))
end
