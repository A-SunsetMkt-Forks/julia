# This file is a part of Julia. License is MIT: https://julialang.org/license

# Uniform random generation

# This file contains the creation of Sampler objects and the associated generation of
# random values from them. More specifically, given the specification S of a set
# of values to pick from (e.g. 1:10, or "a string"), we define
#
# 1) Sampler(rng, S, ::Repetition) -> sampler
# 2) rand(rng, sampler) -> random value
#
# Note that the 1) is automated when the sampler is not intended to carry information,
# i.e. the default fall-backs SamplerType and SamplerTrivial are used.

## from types: rand(::Type, [dims...])

### random floats

Sampler(::Type{RNG}, ::Type{T}, n::Repetition) where {RNG<:AbstractRNG,T<:AbstractFloat} =
    Sampler(RNG, CloseOpen01(T), n)

# generic random generation function which can be used by RNG implementers
# it is not defined as a fallback rand method as this could create ambiguities

rand(r::AbstractRNG, ::SamplerTrivial{CloseOpen01{Float16}}) =
    Float16(reinterpret(Float32,
                        (rand(r, UInt10(UInt32)) << 13)  | 0x3f800000) - 1)

rand(r::AbstractRNG, ::SamplerTrivial{CloseOpen01{Float32}}) =
    reinterpret(Float32, rand(r, UInt23()) | 0x3f800000) - 1

rand(r::AbstractRNG, ::SamplerTrivial{CloseOpen12_64}) =
    reinterpret(Float64, 0x3ff0000000000000 | rand(r, UInt52()))

rand(r::AbstractRNG, ::SamplerTrivial{CloseOpen01_64}) = rand(r, CloseOpen12()) - 1.0

#### BigFloat

const bits_in_Limb = sizeof(Limb) << 3
const Limb_high_bit = one(Limb) << (bits_in_Limb-1)

struct SamplerBigFloat{I<:FloatInterval{BigFloat}} <: Sampler{BigFloat}
    prec::Int
    nlimbs::Int
    limbs::Vector{Limb}
    shift::UInt

    function SamplerBigFloat{I}(prec::Int) where I<:FloatInterval{BigFloat}
        nlimbs = (prec-1) ÷ bits_in_Limb + 1
        limbs = Vector{Limb}(undef, nlimbs)
        shift = nlimbs * bits_in_Limb - prec
        new(prec, nlimbs, limbs, shift)
    end
end

Sampler(::Type{<:AbstractRNG}, I::FloatInterval{BigFloat}, ::Repetition) =
    SamplerBigFloat{typeof(I)}(precision(BigFloat))

function _rand!(rng::AbstractRNG, z::BigFloat, sp::SamplerBigFloat)
    precision(z) == sp.prec || _throw_argerror("incompatible BigFloat precision")
    limbs = sp.limbs
    rand!(rng, limbs)
    @inbounds begin
        limbs[1] <<= sp.shift
        randbool = iszero(limbs[end] & Limb_high_bit)
        limbs[end] |= Limb_high_bit
    end
    z.sign = 1
    copyto!(z.d, limbs)
    randbool
end

function _rand!(rng::AbstractRNG, z::BigFloat, sp::SamplerBigFloat, ::CloseOpen12{BigFloat})
    _rand!(rng, z, sp)
    z.exp = 1
    z
end

function _rand!(rng::AbstractRNG, z::BigFloat, sp::SamplerBigFloat, ::CloseOpen01{BigFloat})
    randbool = _rand!(rng, z, sp)
    z.exp = 0
    randbool &&
        ccall((:mpfr_sub_d, :libmpfr), Int32,
              (Ref{BigFloat}, Ref{BigFloat}, Cdouble, Base.MPFR.MPFRRoundingMode),
              z, z, 0.5, Base.MPFR.ROUNDING_MODE[])
    z
end

# alternative, with 1 bit less of precision
# TODO: make an API for requesting full or not-full precision
function _rand!(rng::AbstractRNG, z::BigFloat, sp::SamplerBigFloat, ::CloseOpen01{BigFloat},
                ::Nothing)
    _rand!(rng, z, sp, CloseOpen12(BigFloat))
    ccall((:mpfr_sub_ui, :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, Culong, Base.MPFR.MPFRRoundingMode),
          z, z, 1, Base.MPFR.ROUNDING_MODE[])
    z
end

rand!(rng::AbstractRNG, z::BigFloat, sp::SamplerBigFloat{T}
      ) where {T<:FloatInterval{BigFloat}} =
          _rand!(rng, z, sp, T())

rand(rng::AbstractRNG, sp::SamplerBigFloat{T}) where {T<:FloatInterval{BigFloat}} =
    rand!(rng, BigFloat(; precision=sp.prec), sp)


### random integers

#### UniformBits

rand(r::AbstractRNG, ::SamplerTrivial{UInt10Raw{UInt16}}) = rand(r, UInt16)
rand(r::AbstractRNG, ::SamplerTrivial{UInt23Raw{UInt32}}) = rand(r, UInt32)

rand(r::AbstractRNG, ::SamplerTrivial{UInt52Raw{UInt64}}) =
    _rand52(r, rng_native_52(r))

_rand52(r::AbstractRNG, ::Type{Float64}) = reinterpret(UInt64, rand(r, CloseOpen12()))
_rand52(r::AbstractRNG, ::Type{UInt64})  = rand(r, UInt64)

rand(r::AbstractRNG, ::SamplerTrivial{UInt104Raw{UInt128}}) =
    rand(r, UInt52Raw(UInt128)) << 52 ⊻ rand(r, UInt52Raw(UInt128))

rand(r::AbstractRNG, ::SamplerTrivial{UInt10{UInt16}})   = rand(r, UInt10Raw())  & 0x03ff
rand(r::AbstractRNG, ::SamplerTrivial{UInt23{UInt32}})   = rand(r, UInt23Raw())  & 0x007fffff
rand(r::AbstractRNG, ::SamplerTrivial{UInt52{UInt64}})   = rand(r, UInt52Raw())  & 0x000fffffffffffff
rand(r::AbstractRNG, ::SamplerTrivial{UInt104{UInt128}}) = rand(r, UInt104Raw()) & 0x000000ffffffffffffffffffffffffff

rand(r::AbstractRNG, sp::SamplerTrivial{<:UniformBits{T}}) where {T} =
        rand(r, uint_default(sp[])) % T

#### BitInteger

# rand_generic methods are intended to help RNG implementers with common operations
# we don't call them simply `rand` as this can easily contribute to create
# ambiguities with user-side methods (forcing the user to resort to @eval)

rand_generic(r::AbstractRNG, T::Union{Bool,Int8,UInt8,Int16,UInt16,Int32,UInt32}) =
    rand(r, UInt52Raw()) % T[]

rand_generic(r::AbstractRNG, ::Type{UInt64}) =
    rand(r, UInt52Raw()) << 32 ⊻ rand(r, UInt52Raw())

rand_generic(r::AbstractRNG, ::Type{UInt128}) = _rand128(r, rng_native_52(r))

_rand128(r::AbstractRNG, ::Type{UInt64}) =
    ((rand(r, UInt64) % UInt128) << 64) ⊻ rand(r, UInt64)

function _rand128(r::AbstractRNG, ::Type{Float64})
    xor(rand(r, UInt52Raw(UInt128))  << 96,
        rand(r, UInt52Raw(UInt128))  << 48,
        rand(r, UInt52Raw(UInt128)))
end

rand_generic(r::AbstractRNG, ::Type{Int128}) = rand(r, UInt128) % Int128
rand_generic(r::AbstractRNG, ::Type{Int64})  = rand(r, UInt64) % Int64

### random complex numbers

rand(r::AbstractRNG, ::SamplerType{Complex{T}}) where {T<:Real} =
    complex(rand(r, T), rand(r, T))

### random characters

# returns a random valid Unicode scalar value (i.e. 0 - 0xd7ff, 0xe000 - # 0x10ffff)
function rand(r::AbstractRNG, ::SamplerType{T}) where {T<:AbstractChar}
    c = rand(r, 0x00000000:0x0010f7ff)
    (c < 0xd800) ? T(c) : T(c+0x800)
end

### random tuples

function Sampler(::Type{RNG}, ::Type{T}, n::Repetition) where {T<:Tuple, RNG<:AbstractRNG}
    tail_sp_ = Sampler(RNG, Tuple{Base.tail(fieldtypes(T))...}, n)
    SamplerTag{Ref{T}}((Sampler(RNG, fieldtype(T, 1), n), tail_sp_.data...))
    # Ref so that the gentype is `T` in SamplerTag's constructor
end

function Sampler(::Type{RNG}, ::Type{Tuple{Vararg{T, N}}}, n::Repetition) where {T, N, RNG<:AbstractRNG}
    if N > 0
        SamplerTag{Ref{Tuple{Vararg{T, N}}}}((Sampler(RNG, T, n),))
    else
        SamplerTag{Ref{Tuple{}}}(())
    end
end

function rand(rng::AbstractRNG, sp::SamplerTag{Ref{T}}) where T<:Tuple
    ntuple(i -> rand(rng, sp.data[min(i, length(sp.data))]), Val{fieldcount(T)}())::T
end

### random pairs

function Sampler(::Type{RNG}, ::Type{Pair{A, B}}, n::Repetition) where {RNG<:AbstractRNG, A, B}
    sp1 = Sampler(RNG, A, n)
    sp2 = A === B ? sp1 : Sampler(RNG, B, n)
    SamplerTag{Ref{Pair{A,B}}}(sp1 => sp2) # Ref so that the gentype is Pair{A, B}
                                           # in SamplerTag's constructor
end

rand(rng::AbstractRNG, sp::SamplerTag{<:Ref{<:Pair}}) =
    rand(rng, sp.data.first) => rand(rng, sp.data.second)


## Generate random integer within a range

### BitInteger

# there are three implemented samplers for unit ranges, the second one
# assumes that Float64 (i.e. 52 random bits) is the native type for the RNG:
# 1) "Fast" (SamplerRangeFast), which is most efficient when the range length is close
#    (or equal) to a power of 2 from below.
#    The tradeoff is faster creation of the sampler, but more consumption of entropy bits.
# 2) "Slow" (SamplerRangeInt) which tries to use as few entropy bits as possible, at the
#    cost of a bigger upfront price associated with the creation of the sampler.
#    This sampler is most appropriate for slower random generators.
# 3) "Nearly Division Less" (NDL) which is generally the fastest algorithm for types of size
#    up to 64 bits. This is the default for these types since Julia 1.5.
#    The "Fast" algorithm can be faster than NDL when the length of the range is
#    less than and close to a power of 2.

Sampler(::Type{<:AbstractRNG}, r::AbstractUnitRange{T},
        ::Repetition) where {T<:Base.BitInteger64} = SamplerRangeNDL(r)

Sampler(::Type{<:AbstractRNG}, r::AbstractUnitRange{T},
        ::Repetition) where {T<:Union{Int128,UInt128}} = SamplerRangeFast(r)

#### helper functions

uint_sup(::Type{<:Base.BitInteger32}) = UInt32
uint_sup(::Type{<:Union{Int64,UInt64}}) = UInt64
uint_sup(::Type{<:Union{Int128,UInt128}}) = UInt128

@noinline empty_collection_error() = throw(ArgumentError("collection must be non-empty"))


#### Fast

struct SamplerRangeFast{U<:BitUnsigned,T<:BitInteger} <: Sampler{T}
    a::T      # first element of the range
    bw::UInt  # bit width
    m::U      # range length - 1
    mask::U   # mask generated values before threshold rejection
end

SamplerRangeFast(r::AbstractUnitRange{T}) where T<:BitInteger =
    SamplerRangeFast(r, uint_sup(T))

function SamplerRangeFast(r::AbstractUnitRange{T}, ::Type{U}) where {T,U}
    isempty(r) && empty_collection_error()
    m = (last(r) - first(r)) % unsigned(T) % U # % unsigned(T) to not propagate sign bit
    bw = (Base.top_set_bit(m)) % UInt # bit-width
    mask = ((1 % U) << bw) - (1 % U)
    SamplerRangeFast{U,T}(first(r), bw, m, mask)
end

function rand(rng::AbstractRNG, sp::SamplerRangeFast{UInt32,T}) where T
    a, bw, m, mask = sp.a, sp.bw, sp.m, sp.mask
    # below, we don't use UInt32, to get reproducible values, whether Int is Int64 or Int32
    x = rand(rng, LessThan(m, Masked(mask, UInt52Raw(UInt32))))
    (x + a % UInt32) % T
end

has_fast_64(rng::AbstractRNG) = rng_native_52(rng) != Float64
# for MersenneTwister, both options have very similar performance

function rand(rng::AbstractRNG, sp::SamplerRangeFast{UInt64,T}) where T
    a, bw, m, mask = sp.a, sp.bw, sp.m, sp.mask
    if !has_fast_64(rng) && bw <= 52
        x = rand(rng, LessThan(m, Masked(mask, UInt52Raw())))
    else
        x = rand(rng, LessThan(m, Masked(mask, uniform(UInt64))))
    end
    (x + a % UInt64) % T
end

function rand(rng::AbstractRNG, sp::SamplerRangeFast{UInt128,T}) where T
    a, bw, m, mask = sp.a, sp.bw, sp.m, sp.mask
    if has_fast_64(rng)
        x = bw <= 64 ?
            rand(rng, LessThan(m % UInt64, Masked(mask % UInt64, uniform(UInt64)))) % UInt128 :
            rand(rng, LessThan(m, Masked(mask, uniform(UInt128))))
    else
        x = bw <= 52  ?
            rand(rng, LessThan(m % UInt64, Masked(mask % UInt64, UInt52Raw()))) % UInt128 :
        bw <= 104 ?
            rand(rng, LessThan(m, Masked(mask, UInt104Raw()))) :
            rand(rng, LessThan(m, Masked(mask, uniform(UInt128))))
    end
    x % T + a
end

#### "Slow" / SamplerRangeInt

# remainder function according to Knuth, where rem_knuth(a, 0) = a
rem_knuth(a::UInt, b::UInt) = a % (b + (b == 0)) + a * (b == 0)
rem_knuth(a::T, b::T) where {T<:Unsigned} = b != 0 ? a % b : a

# maximum multiple of k <= sup decremented by one,
# that is 0xFFFF...FFFF if k = (typemax(T) - typemin(T)) + 1 and sup == typemax(T) - 1
# with intentional underflow
# see https://stackoverflow.com/questions/29182036/integer-arithmetic-add-1-to-uint-max-and-divide-by-n-without-overflow

# sup == 0 means typemax(T) + 1
maxmultiple(k::T, sup::T=zero(T)) where {T<:Unsigned} =
    (div(sup - k, k + (k == 0))*k + k - one(k))::T

# similar but sup must not be equal to typemax(T)
unsafe_maxmultiple(k::T, sup::T) where {T<:Unsigned} =
    div(sup, k + (k == 0))*k - one(k)

struct SamplerRangeInt{T<:Integer,U<:Unsigned} <: Sampler{T}
    a::T      # first element of the range
    bw::Int   # bit width
    k::U      # range length or zero for full range
    u::U      # rejection threshold
end


SamplerRangeInt(r::AbstractUnitRange{T}) where T<:BitInteger =
    SamplerRangeInt(r, uint_sup(T))

function SamplerRangeInt(r::AbstractUnitRange{T}, ::Type{U}) where {T,U}
    isempty(r) && empty_collection_error()
    a = first(r)
    m = (last(r) - first(r)) % unsigned(T) % U
    k = m + one(U)
    bw = (Base.top_set_bit(m)) % Int
    mult = if U === UInt32
        maxmultiple(k)
    elseif U === UInt64
        bw <= 52 ? unsafe_maxmultiple(k, one(UInt64) << 52) :
                   maxmultiple(k)
    else # U === UInt128
        bw <= 52  ? unsafe_maxmultiple(k, one(UInt128) << 52) :
        bw <= 104 ? unsafe_maxmultiple(k, one(UInt128) << 104) :
                    maxmultiple(k)
    end

    SamplerRangeInt{T,U}(a, bw, k, mult) # overflow ok
end

rand(rng::AbstractRNG, sp::SamplerRangeInt{T,UInt32}) where {T<:BitInteger} =
    (unsigned(sp.a) + rem_knuth(rand(rng, LessThan(sp.u, UInt52Raw(UInt32))), sp.k)) % T

# this function uses 52 bit entropy for small ranges of length <= 2^52
function rand(rng::AbstractRNG, sp::SamplerRangeInt{T,UInt64}) where T<:BitInteger
    x = sp.bw <= 52 ? rand(rng, LessThan(sp.u, UInt52())) :
                      rand(rng, LessThan(sp.u, uniform(UInt64)))
    return ((sp.a % UInt64) + rem_knuth(x, sp.k)) % T
end

function rand(rng::AbstractRNG, sp::SamplerRangeInt{T,UInt128}) where T<:BitInteger
    x = sp.bw <= 52  ? rand(rng, LessThan(sp.u, UInt52(UInt128))) :
        sp.bw <= 104 ? rand(rng, LessThan(sp.u, UInt104(UInt128))) :
                       rand(rng, LessThan(sp.u, uniform(UInt128)))
    return ((sp.a % UInt128) + rem_knuth(x, sp.k)) % T
end

#### Nearly Division Less

# cf. https://arxiv.org/abs/1805.10941 (algorithm 5)

struct SamplerRangeNDL{U<:Unsigned,T} <: Sampler{T}
    a::T  # first element of the range
    s::U  # range length or zero for full range
end

function SamplerRangeNDL(r::AbstractUnitRange{T}) where {T}
    isempty(r) && empty_collection_error()
    a = first(r)
    U = uint_sup(T)
    s = (last(r) - first(r)) % unsigned(T) % U + one(U) # overflow ok
    # mod(-s, s) could be put in the Sampler object for repeated calls, but
    # this would be an advantage only for very big s and number of calls
    SamplerRangeNDL(a, s)
end

function rand(rng::AbstractRNG, sp::SamplerRangeNDL{U,T}) where {U,T}
    s = sp.s
    x = widen(rand(rng, U))
    m = x * s
    r::T = (m % U) < s ? rand_unlikely(rng, s, m) % T :
           iszero(s)   ? x % T :
                         (m >> (8*sizeof(U))) % T
    r + sp.a
end

# similar to `randn_unlikely` : splitting this unlikely path out results in faster code
@noinline function rand_unlikely(rng, s::U, m)::U where {U}
    t = mod(-s, s) # as s is unsigned, -s is equal to 2^L - s in the paper
    while (m % U) < t
        x = widen(rand(rng, U))
        m = x * s
    end
    (m >> (8*sizeof(U))) % U
end


### BigInt

struct SamplerBigInt{SP<:Sampler{Limb}} <: Sampler{BigInt}
    a::BigInt         # first
    m::BigInt         # range length - 1
    nlimbs::Int       # number of limbs in generated BigInt's (z ∈ [0, m])
    nlimbsmax::Int    # max number of limbs for z+a
    highsp::SP        # sampler for the highest limb of z
end

function SamplerBigInt(::Type{RNG}, r::AbstractUnitRange{BigInt}, N::Repetition=Val(Inf)
                       ) where {RNG<:AbstractRNG}
    m = last(r) - first(r)
    m.size < 0 && empty_collection_error()
    nlimbs = Int(m.size)
    hm = nlimbs == 0 ? Limb(0) : GC.@preserve m unsafe_load(m.d, nlimbs)
    highsp = Sampler(RNG, Limb(0):hm, N)
    nlimbsmax = max(nlimbs, abs(last(r).size), abs(first(r).size))
    return SamplerBigInt(first(r), m, nlimbs, nlimbsmax, highsp)
end

Sampler(::Type{RNG}, r::AbstractUnitRange{BigInt}, N::Repetition) where {RNG<:AbstractRNG} =
    SamplerBigInt(RNG, r, N)

rand(rng::AbstractRNG, sp::SamplerBigInt) =
    rand!(rng, BigInt(nbits = sp.nlimbsmax*8*sizeof(Limb)), sp)

function rand!(rng::AbstractRNG, x::BigInt, sp::SamplerBigInt)
    nlimbs = sp.nlimbs
    nlimbs == 0 && return MPZ.set!(x, sp.a)
    MPZ.realloc2!(x, sp.nlimbsmax*8*sizeof(Limb))
    @assert x.alloc >= nlimbs
    # we randomize x ∈ [0, m] with rejection sampling:
    # 1. the first nlimbs-1 limbs of x are uniformly randomized
    # 2. the high limb hx of x is sampled from 0:hm where hm is the
    #    high limb of m
    # We repeat 1. and 2. until x <= m
    hm = GC.@preserve sp unsafe_load(sp.m.d, nlimbs)
    GC.@preserve x begin
        limbs = UnsafeView(x.d, nlimbs-1)
        while true
            rand!(rng, limbs)
            hx = limbs[nlimbs] = rand(rng, sp.highsp)
            hx < hm && break # avoid calling mpn_cmp most of the time
            MPZ.mpn_cmp(x, sp.m, nlimbs) <= 0 && break
        end
        # adjust x.size (normally done by mpz_limbs_finish, in GMP version >= 6)
        while nlimbs > 0
            limbs[nlimbs] != 0 && break
            nlimbs -= 1
        end
        x.size = nlimbs
    end
    MPZ.add!(x, sp.a)
end


## random values from AbstractArray

Sampler(::Type{RNG}, r::AbstractArray, n::Repetition) where {RNG<:AbstractRNG} =
    SamplerSimple(r, Sampler(RNG, firstindex(r):lastindex(r), n))

rand(rng::AbstractRNG, sp::SamplerSimple{<:AbstractArray,<:Sampler}) =
    @inbounds return sp[][rand(rng, sp.data)]


## random values from Dict

function Sampler(::Type{RNG}, t::Dict, ::Repetition) where RNG<:AbstractRNG
    isempty(t) && empty_collection_error()
    # we use Val(Inf) below as rand is called repeatedly internally
    # even for generating only one random value from t
    SamplerSimple(t, Sampler(RNG, LinearIndices(t.slots), Val(Inf)))
end

function rand(rng::AbstractRNG, sp::SamplerSimple{<:Dict,<:Sampler})
    while true
        i = rand(rng, sp.data)
        Base.isslotfilled(sp[], i) && @inbounds return (sp[].keys[i] => sp[].vals[i])
    end
end

rand(rng::AbstractRNG, sp::SamplerTrivial{<:Base.KeySet{<:Any,<:Dict}}) =
    rand(rng, sp[].dict).first

rand(rng::AbstractRNG, sp::SamplerTrivial{<:Base.ValueIterator{<:Dict}}) =
    rand(rng, sp[].dict).second

## random values from Set

Sampler(::Type{RNG}, t::Set{T}, n::Repetition) where {RNG<:AbstractRNG,T} =
    SamplerTag{Set{T}}(Sampler(RNG, t.dict, n))

rand(rng::AbstractRNG, sp::SamplerTag{<:Set,<:Sampler}) = rand(rng, sp.data).first

## random values from BitSet

function Sampler(RNG::Type{<:AbstractRNG}, t::BitSet, n::Repetition)
    isempty(t) && empty_collection_error()
    SamplerSimple(t, Sampler(RNG, minimum(t):maximum(t), Val(Inf)))
end

function rand(rng::AbstractRNG, sp::SamplerSimple{BitSet,<:Sampler})
    while true
        n = rand(rng, sp.data)
        n in sp[] && return n
    end
end

## random values from AbstractDict/AbstractSet

# we defer to _Sampler to avoid ambiguities with a call like Sampler(rng, Set(1), Val(1))
Sampler(RNG::Type{<:AbstractRNG}, t::Union{AbstractDict,AbstractSet}, n::Repetition) =
    _Sampler(RNG, t, n)

# avoid linear complexity for repeated calls
_Sampler(RNG::Type{<:AbstractRNG}, t::Union{AbstractDict,AbstractSet}, n::Val{Inf}) =
    Sampler(RNG, collect(t), n)

# when generating only one element, avoid the call to collect
_Sampler(::Type{<:AbstractRNG}, t::Union{AbstractDict,AbstractSet}, ::Val{1}) =
    SamplerTrivial(t)

function nth(iter, n::Integer)::eltype(iter)
    for (i, x) in enumerate(iter)
        i == n && return x
    end
end

rand(rng::AbstractRNG, sp::SamplerTrivial{<:Union{AbstractDict,AbstractSet}}) =
    nth(sp[], rand(rng, 1:length(sp[])))


## random characters from a string

# we use collect(str), which is most of the time more efficient than specialized methods
# (except maybe for very small arrays)
Sampler(RNG::Type{<:AbstractRNG}, str::AbstractString, n::Val{Inf}) = Sampler(RNG, collect(str), n)

# when generating only one char from a string, the specialized method below
# is usually more efficient
Sampler(RNG::Type{<:AbstractRNG}, str::AbstractString, ::Val{1}) =
    SamplerSimple(str, Sampler(RNG, 1:_lastindex(str), Val(Inf)))

isvalid_unsafe(s::String, i) = !Base.is_valid_continuation(GC.@preserve s unsafe_load(pointer(s), i))
isvalid_unsafe(s::AbstractString, i) = isvalid(s, i)
_lastindex(s::String) = sizeof(s)
_lastindex(s::AbstractString) = lastindex(s)

function rand(rng::AbstractRNG, sp::SamplerSimple{<:AbstractString,<:Sampler})::Char
    str = sp[]
    while true
        pos = rand(rng, sp.data)
        isvalid_unsafe(str, pos) && return str[pos]
    end
end


## random elements from tuples

### 1

Sampler(::Type{<:AbstractRNG}, t::Tuple{A}, ::Repetition) where {A} =
    SamplerTrivial(t)

rand(rng::AbstractRNG, sp::SamplerTrivial{Tuple{A}}) where {A} =
    @inbounds return sp[][1]

### 2

Sampler(RNG::Type{<:AbstractRNG}, t::Tuple{A,B}, n::Repetition) where {A,B} =
    SamplerSimple(t, Sampler(RNG, Bool, n))

rand(rng::AbstractRNG, sp::SamplerSimple{Tuple{A,B}}) where {A,B} =
    @inbounds return sp[][1 + rand(rng, sp.data)]

### 3

Sampler(RNG::Type{<:AbstractRNG}, t::Tuple{A,B,C}, n::Repetition) where {A,B,C} =
    SamplerSimple(t, Sampler(RNG, UInt52(), n))

function rand(rng::AbstractRNG, sp::SamplerSimple{Tuple{A,B,C}}) where {A,B,C}
    local r
    while true
        r = rand(rng, sp.data)
        r != 0x000fffffffffffff && break # _very_ likely
    end
    @inbounds return sp[][1 + r ÷ 0x0005555555555555]
end

### n

@generated function Sampler(RNG::Type{<:AbstractRNG}, t::Tuple, n::Repetition)
    l = fieldcount(t)
    if l < typemax(UInt32) && ispow2(l)
        :(SamplerSimple(t, Sampler(RNG, UInt32, n)))
    else
        :(SamplerSimple(t, Sampler(RNG, Base.OneTo(length(t)), n)))
    end
end

@generated function rand(rng::AbstractRNG, sp::SamplerSimple{T}) where T<:Tuple
    l = fieldcount(T)
    if l < typemax(UInt32) && ispow2(l)
        quote
            r = rand(rng, sp.data) & ($l-1)
            @inbounds return sp[][1 + r]
        end
    else
        :(@inbounds return sp[][rand(rng, sp.data)])
    end
end
