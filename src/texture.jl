abstract type DepthFormat end

struct Depth{DT} <: DepthFormat
    depth::DT
end

# TODO maybe we should implement this as a 32 bit wide primitive type
# and overload getproperty (getfield on 0.7) to implement depthstencil.depth with masking
# since you almost always want to have depthstencil.depth::Float32
struct DepthStencil{DT,ST} <: DepthFormat
    depth::DT
    stencil::ST
end
#0.7: Base.getproperty(x::DepthStencil, field::Symbol) = field == :depth ? Float32(x.depth) : x.stencil #I actually do want to support v0.6 for now

"""
Float24 storage type for depth
"""
primitive type Float24 <: AbstractFloat 24 end

gl_internal_format(::Type{Depth{Float32}})::GLenum = GL_DEPTH_COMPONENT32F
gl_internal_format(::Type{DepthStencil{Float24,N0f8}})::GLenum = GL_DEPTH24_STENCIL8

function gl_internal_format(::Type{T}) where {T<:Colorant}
    textureformat_internal_from_type(T)
end

function gl_internal_format(::T) where {T}
    error("$T doesn't have a valid mapping to an OpenGL internal format enum. Please use DepthStencil/Depth/Color, or overload `gl_internal_format(x::$T)`
    to return the correct OpenGL format enum.
    ")
end

gl_attachment(::Type{<:Depth}) = GL_DEPTH_ATTACHMENT
gl_attachment(::Type{<:DepthStencil}) = GL_DEPTH_STENCIL_ATTACHMENT
# gl_attachment(::Type{<:Colorant}) = GL_COLOR_ATTACHMENT0

function gl_attachment(::T) where {T}
    error("$T doesn't have a valid mapping to an OpenGL attachment enum. Please use DepthStencil/Depth, or overload `gl_attachment(x::$T)`
    to return the correct OpenGL depth attachment.
    ")
end

const GL_TEXTURE_MAX_ANISOTROPY_EXT = GLenum(0x84FE)

colordim(::Type{T}) where {T} = cardinality(T)
colordim(::Type{T}) where {T<:Real} = 1

#Supported texture modes/dimensions
function texturetype_from_dimensions(ndim::Integer)
    ndim == 1 && return GL_TEXTURE_1D
    ndim == 2 && return GL_TEXTURE_2D
    ndim == 3 && return GL_TEXTURE_3D
    @error "Dimensionality: $(ndim), not supported for OpenGL texture"
end

function textureformat_internal_from_type(::Type{T}) where {T}
    glasserteltype(T)
    if T <: Depth{Float32}
        return GL_DEPTH_COMPONENT32F
    elseif T <: DepthStencil{Float24,N0f8}
        return GL_DEPTH24_STENCIL8
    end
    return textureformat_internal_from_type(Val{length(T)}(), eltype(T))
end

@generated function textureformat_internal_from_type(::Val{dim}, ::Type{eltyp}) where {dim,eltyp}
    @assert (dim <= 4 && dim >= 1) "No Textureformat that fits $dim-dimensional eltypes."
    sym = "GL_"
    sym *= "RGBA"[1:dim]
    bits = sizeof(eltyp) * 8
    @assert bits <= 32 "Type has too many bits ($bits)"
    sym *= string(bits)

    if eltyp <: AbstractFloat
        sym *= "F"
    elseif eltyp <: FixedPoint
        sym *= eltyp <: Normed ? "" : "_SNORM"
    elseif eltyp <: Signed
        sym *= "I"
    elseif eltyp <: Unsigned
        sym *= "UI"
    end
    glenumsym = Symbol(sym)
    @assert isdefined(ModernGL, glenumsym) "Type doesn't have a proper mapping to an OpenGL format."
    return :($glenumsym)
end

function textureformat_from_type_sym(dim::Integer, isinteger::Bool, order::AbstractString)
    @assert dim <= 4 "no colors with dimension > 4 allowed. Dimension given: $dim"
    sym = "GL_"
    # Handle that colordim == 1 => RED instead of R
    color = dim == 1 ? "RED" : order[1:dim]
    # Handle gray value
    integer = isinteger ? "_INTEGER" : ""
    sym *= color * integer
    glenumsym = Symbol(sym)
    @assert isdefined(ModernGL, glenumsym) "Type doesn't have a proper mapping to an OpenGL format"
    return glenumsym
end

@generated textureformat_from_type_sym(::Type{T}, ::Val{dim} where {dim}, ::Val{isinteger}) where {T<:Real,isinteger} =
    :($(textureformat_from_type_sym(1, isinteger, "RED")))
@generated textureformat_from_type_sym(::Type{T}, ::Val{dim}, ::Val{isinteger}) where {T<:AbstractArray,dim,isinteger} =
    :($(textureformat_from_type_sym(dim, isinteger, "RGBA")))

@generated function textureformat_from_type_sym(::Type{T}, ::Val{dim}, ::Val{isinteger}) where {T,dim,isinteger}
    typenamestring = string(Base.typename(T).name)
    if typenamestring ∉ ("RGB", "BGR", "RGBA", "ARGB", "ABGR", "RGBA", "BGRA")
        typenamestring = "RGBA"
    end
    return :($(textureformat_from_type_sym(dim, isinteger, typenamestring)))
end

textureformat_from_type(::Type{<:DepthFormat}) = GL_DEPTH_COMPONENT

function textureformat_from_type(::Type{T}) where {T}
    return textureformat_from_type_sym(T, Val{length(T)}(), Val{eltype(T)<:Integer}())
end

struct TextureParameters{NDim}
    minfilter::Symbol
    magfilter::Symbol # magnification
    repeat::NTuple{NDim,Symbol}
    anisotropic::Float32
    swizzle_mask::Vector{GLenum}
end
function TextureParameters(T, NDim;
    minfilter=T <: Integer ? :nearest : :linear,
    magfilter=minfilter, # magnification
    x_repeat=:clamp_to_edge, #wrap_s
    y_repeat=x_repeat, #wrap_t
    z_repeat=x_repeat, #wrap_r
    anisotropic=1.0f0
)
    T <: Integer && (minfilter == :linear || magfilter == :linear) && (@error "Wrong Texture Parameter: Integer texture can't interpolate. Try :nearest")
    repeat = (x_repeat, y_repeat, z_repeat)
    dim = T <: DepthFormat ? 1 : length(T)
    swizzle_mask = if dim == 3 #<: Gray
        GLenum[GL_RED, GL_GREEN, GL_BLUE, GL_ONE]
    elseif dim == 4 #<: GrayA
        GLenum[GL_RED, GL_GREEN, GL_BLUE, GL_ALPHA]
    else
        GLenum[]
    end
    TextureParameters(
        minfilter, magfilter, ntuple(i -> repeat[i], NDim),
        anisotropic, swizzle_mask
    )
end

map_texture_paramers(s::NTuple{N,Symbol}) where {N} = map(map_texture_paramers, s)

function map_texture_paramers(s::Symbol)
    s == :clamp_to_edge && return GL_CLAMP_TO_EDGE
    s == :mirrored_repeat && return GL_MIRRORED_REPEAT
    s == :repeat && return GL_REPEAT
    s == :linear && return GL_LINEAR
    s == :nearest && return GL_NEAREST
    s == :nearest_mipmap_nearest && return GL_NEAREST_MIPMAP_NEAREST
    s == :linear_mipmap_nearest && return GL_LINEAR_MIPMAP_NEAREST
    s == :nearest_mipmap_linear && return GL_NEAREST_MIPMAP_LINEAR
    s == :linear_mipmap_linear && return GL_LINEAR_MIPMAP_LINEAR

    @error "$s is not a valid texture parameter"
end

#This is used in the construction of Textures
function set_packing_alignment(a) # at some point we should specialize to array/ptr a
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1)
    glPixelStorei(GL_UNPACK_ROW_LENGTH, 0)
    glPixelStorei(GL_UNPACK_SKIP_PIXELS, 0)
    glPixelStorei(GL_UNPACK_SKIP_ROWS, 0)
end

mutable struct Texture{T,NDIM}
    id::GLuint
    texturetype::GLenum
    pixeltype::GLenum
    internalformat::GLenum
    format::GLenum
    parameters::TextureParameters{NDIM}
    size::NTuple{NDIM,Int}
    context::Context
    function Texture{T,NDIM}(
        id::GLuint,
        texturetype::GLenum,
        pixeltype::GLenum,
        internalformat::GLenum,
        format::GLenum,
        parameters::TextureParameters{NDIM},
        size::NTuple{NDIM,Int}
    ) where {T,NDIM}
        tex = new(
            id,
            texturetype,
            pixeltype,
            internalformat,
            format,
            parameters,
            size,
            current_context()
        )
        finalizer(free!, tex)
        tex
    end
end

function Texture(
    data::Ptr{T}, dims::NTuple{NDim,Int};
    internalformat::GLenum=textureformat_internal_from_type(T),
    texturetype::GLenum=texturetype_from_dimensions(NDim),
    format::GLenum=textureformat_from_type(T),
    mipmap=false,
    parameters... # rest should be texture parameters
) where {T,NDim}
    glasserteltype(T)
    texparams = TextureParameters(T, NDim; parameters...)
    id = glGenTextures()
    glBindTexture(texturetype, id)
    set_packing_alignment(data)
    if T <: DepthFormat
        numbertype = GL_FLOAT
    else
        numbertype = julia2glenum(eltype(T))
    end
    glTexImage(texturetype, 0, internalformat, dims..., 0, format, numbertype, data)
    mipmap && glGenerateMipmap(texturetype)
    texture = Texture{T,NDim}(
        id, texturetype, numbertype, internalformat, format,
        texparams,
        dims
    )
    set_parameters(texture)
    texture::Texture{T,NDim}
end

"""
Constructor for Array Texture
"""
function Texture(
    data::Vector{Array{T,2}};
    internalformat::GLenum=textureformat_internal_from_type(T),
    texturetype::GLenum=GL_TEXTURE_2D_ARRAY,
    format::GLenum=textureformat_from_type(T),
    parameters...
) where {T}
    glasserteltype(T)
    texparams = TextureParameters(T, 2; parameters...)
    id = glGenTextures()

    glBindTexture(texturetype, id)

    numbertype = julia2glenum(eltype(T))

    layers = length(data)
    dims = map(size, data)
    maxdims = foldl((0, 0), dims) do v0, x
        a = max(v0[1], x[1])
        b = max(v0[2], x[2])
        (a, b)
    end
    set_packing_alignment(data)
    glTexStorage3D(GL_TEXTURE_2D_ARRAY, 1, internalformat, maxdims..., layers)
    for (layer, texel) in enumerate(data)
        width, height = size(texel)
        glTexSubImage3D(GL_TEXTURE_2D_ARRAY, 0, 0, 0, layer - 1, width, height, 1, format, numbertype, texel)
    end

    texture = Texture{T,2}(
        id, texturetype, numbertype,
        internalformat, format, texparams,
        tuple(maxdims...)
    )
    set_parameters(texture)
    texture
end

"""
Constructor for empty initialization with NULL pointer instead of an array with data.
You just need to pass the wanted color/vector type and the dimensions.
To which values the texture gets initialized is driver dependent
"""
function Texture(::Type{T}, dims::NTuple{N,Int}; kw_args...) where {T,N}
    glasserteltype(T)
    Texture(convert(Ptr{T}, C_NULL), dims; kw_args...)::Texture{T,N}
end

"""
Constructor for a normal array, with color or Abstract Arrays as elements.
So Array{Real, 2} == Texture2D with 1D Colorant dimension
Array{Vec1/2/3/4, 2} == Texture2D with 1/2/3/4D Colorant dimension
Colors from Colors.jl should mostly work as well
"""
function Texture(image::Array{T,NDim}; kw_args...) where {T,NDim}
    glasserteltype(T)
    Texture(pointer(image), size(image); kw_args...)::Texture{T,NDim}
end

function set_parameters(t::Texture{T,N}, params::TextureParameters=t.parameters) where {T,N}
    fnames = (:minfilter, :magfilter, :repeat)
    data = Dict([(name, map_texture_paramers(getfield(params, name))) for name in fnames])
    result = Tuple{GLenum,Any}[]
    push!(result, (GL_TEXTURE_MIN_FILTER, data[:minfilter]))
    push!(result, (GL_TEXTURE_MAG_FILTER, data[:magfilter]))
    push!(result, (GL_TEXTURE_WRAP_S, data[:repeat][1]))
    if !isempty(params.swizzle_mask)
        push!(result, (GL_TEXTURE_SWIZZLE_RGBA, params.swizzle_mask))
    end
    N >= 2 && push!(result, (GL_TEXTURE_WRAP_T, data[:repeat][2]))
    if N >= 3 && !is_texturearray(t) # for texture arrays, third dimension can not be set
        push!(result, (GL_TEXTURE_WRAP_R, data[:repeat][3]))
    end
    t.parameters = params
    set_parameters(t, result)
end

function texparameter(t::Texture, key::GLenum, val::GLenum)
    glTexParameteri(t.texturetype, key, val)
end

function texparameter(t::Texture, key::GLenum, val::Vector)
    glTexParameteriv(t.texturetype, key, val)
end

function texparameter(t::Texture, key::GLenum, val::Float32)
    glTexParameterf(t.texturetype, key, val)
end

function set_parameters(t::Texture, parameters::Vector{Tuple{GLenum,Any}})
    bind(t)
    for elem in parameters
        texparameter(t, elem...)
    end
    bind(t, 0)
end

free!(x::Texture) = context_command(() -> glDeleteTextures(x.id), x.context)

Base.size(t::Texture) = t.size
Base.eltype(::Texture{T}) where {T} = T
width(t::Texture) = size(t, 1)
height(t::Texture) = size(t, 2)
depth(t::Texture) = size(t, 3)
id(t::Texture) = t.id

function Base.show(io::IO, t::Texture{T,D}) where {T,D}
    println(io, "Texture$(D)D: ")
    println(io, "                  ID: ", t.id)
    println(io, "                  Size: Dimensions: $(size(t))")
    println(io, "    Julia pixel type: ", T)
    println(io, "   OpenGL pixel type: ", GLENUM(t.pixeltype).name)
    println(io, "              Format: ", GLENUM(t.format).name)
    println(io, "     Internal format: ", GLENUM(t.internalformat).name)
    println(io, "          Parameters: ", t.parameters)
end
Base.display(t::GLAbstraction.Texture{T,D}) where {T,D} = Base.show(stdout, t)

is_texturearray(t::Texture) = t.texturetype == GL_TEXTURE_2D_ARRAY
is_texturebuffer(t::Texture) = t.texturetype == GL_TEXTURE_BUFFER

bind(t::Texture) = glBindTexture(t.texturetype, t.id)
bind(t::Texture, id) = glBindTexture(t.texturetype, id)

function resize_nocopy!(t::Texture{T,ND}, newdims::NTuple{ND,Int}) where {T,ND}
    bind(t)
    glTexImage(t.texturetype, 0, t.internalformat, newdims..., 0, t.format, t.pixeltype, C_NULL)
    t.size = newdims
    bind(t, 0)
    t
end

# Resize Texture
function gpu_resize!(t::Texture{T,ND}, newdims::NTuple{ND,Int}) where {T,ND}
    # dangerous code right here...Better write a few tests for this
    newtex = similar(t, newdims)
    old_size = size(t)
    gpu_setindex!(newtex, t)
    t.size = newdims
    free(t)
    t.id = newtex.id
    return t
end
function gpu_setindex!(t::Texture{T,1}, newvalue::Array{T,1}, indexes::UnitRange{I}) where {T,I<:Integer}
    glBindTexture(t.texturetype, t.id)
    texsubimage(t, newvalue, indexes)
    glBindTexture(t.texturetype, 0)
end
function gpu_setindex!(t::Texture{T,N}, newvalue::Array{T,N}, indexes::Union{UnitRange,Integer}...) where {T,N}
    glBindTexture(t.texturetype, t.id)
    texsubimage(t, newvalue, indexes...)
    glBindTexture(t.texturetype, 0)
end

function gpu_setindex!(target::Texture{T,2}, source::Texture{T,2}, fbo=glGenFramebuffers()) where {T}
    glBindFramebuffer(GL_FRAMEBUFFER, fbo)
    glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
        GL_TEXTURE_2D, source.id, 0)
    glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT1,
        GL_TEXTURE_2D, target.id, 0)
    glDrawBuffer(GL_COLOR_ATTACHMENT1)
    w, h = map(minimum, zip(size(target), size(source)))
    glBlitFramebuffer(0, 0, w, h, 0, 0, w, h,
        GL_COLOR_BUFFER_BIT, GL_NEAREST)
end

# Implementing the GPUArray interface
# To CPU
"""
    gpu_data(t)
Create a new CPU array with the size of the texture and copy the data from the gpu to it
"""
function gpu_data(t::Texture{T,ND}) where {T,ND}
    result = Array{T}(undef, size(t)...)
    unsafe_copyto!(result, t)
    return result
end

"""
    unsafe_copyto!(dest, source, x, y, z)
Copy the 3D data from the texture to the CPU using glGetTextureSubImage.
Allows specifying the upper left corner (Julia: starting at 1).
The size is inferred form dest.
"""
function Base.unsafe_copyto!(dest::Array{T,3}, source::Texture{T,3}, x::Integer=1, y::Integer=1, z::Integer=1) where {T}
    width, height, depth = size(dest)
    buf_size = width * height * depth * sizeof(T)
    glGetTextureSubImage(source.id, 0, x - 1, y - 1, z - 1, width, height, depth, source.format, source.pixeltype, buf_size, dest)
    nothing
end

"""
    unsafe_copyto!(dest, source, x, y)
Copy the 2D data from the texture to the CPU using glGetTextureSubImage.
Allows specifying the upper left corner (Julia: starting at 1).
The size is inferred form dest.
"""
function Base.unsafe_copyto!(dest::Array{T,2}, source::Texture{T,2}, x::Integer=1, y::Integer=1) where {T}
    width, height = size(dest)
    depth = 1
    buf_size = width * height * depth * sizeof(T)
    glGetTextureSubImage(source.id, 0, x - 1, y - 1, 0, width, height, depth, source.format, source.pixeltype, buf_size, dest)
    nothing
end

"""
    unsafe_copyto!(dest, source, x)
Copy the 2D data from the texture to the CPU using glGetTextureSubImage.
Allows specifying the upper left corner (Julia: starting at 1).
The size is inferred form dest.
"""
function Base.unsafe_copyto!(dest::Array{T,1}, source::Texture{T,1}, x::Integer=1) where {T}
    width, height = size(dest)
    depth = height = 1
    buf_size = width * height * depth * sizeof(T)
    glGetTextureSubImage(source.id, 0, x - 1, 0, 0, width, height, depth, source.format, source.pixeltype, buf_size, dest)
    nothing
end

similar(t::Texture{T,NDim}, newdims::Int...) where {T,NDim} = similar(t, newdims)

# To GPU
texsubimage(t::Texture{T,1}, newvalue::Array{T,1}, xrange::UnitRange, level=0) where {T} = glTexSubImage1D(
    t.texturetype, level, first(xrange) - 1, length(xrange), t.format, t.pixeltype, newvalue
)
function texsubimage(t::Texture{T,2}, newvalue::Array{T,2}, xrange::UnitRange, yrange::UnitRange, level=0) where {T}
    glTexSubImage2D(
        t.texturetype, level,
        first(xrange) - 1, first(yrange) - 1, length(xrange), length(yrange),
        t.format, t.pixeltype, newvalue
    )
end
texsubimage(t::Texture{T,3}, newvalue::Array{T,3}, xrange::UnitRange, yrange::UnitRange, zrange::UnitRange, level=0) where {T} = glTexSubImage3D(
    t.texturetype, level,
    first(xrange) - 1, first(yrange) - 1, first(zrange) - 1, length(xrange), length(yrange), length(zrange),
    t.format, t.pixeltype, newvalue
)

function similar(t::Texture{T,NDim}, newdims::NTuple{NDim,Int}) where {T,NDim}
    Texture(
        Ptr{T}(C_NULL),
        newdims, t.texturetype,
        t.pixeltype,
        t.internalformat,
        t.format,
        t.parameters
    )
end
